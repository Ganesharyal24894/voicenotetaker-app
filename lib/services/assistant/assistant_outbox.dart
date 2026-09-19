import 'dart:async';
import 'dart:convert';

import '../../drivers/email_sender.dart';
import '../../drivers/file_store.dart';
import '../../drivers/network_status.dart';
import '../../model/assistant/assistant_message.dart';
import '../../model/assistant/assistant_send.dart';
import 'assistant_account_store.dart';

/// The queue every spoken instruction passes through, and the ONLY caller of
/// [EmailSender] in the app.
///
/// WHAT IT GUARANTEES
///
///   * NOTHING GOES DURING THE UNDO WINDOW. A new entry is
///     [AssistantSendStatus.pendingUndo] for five seconds and [send] will not
///     look at it; an undo inside that window removes it, and a removed entry
///     has no way back.
///   * ONE NOTE, ONE SEND. [enqueue] refuses a note id the outbox has seen
///     before - queued, sending, sent, undone or failed. Re-transcribing a
///     note, reopening the app, or a second wake phrase in the same note
///     cannot produce a second email.
///   * IT SURVIVES BEING KILLED. Every change is written to one JSON file
///     before the next step runs, so an instruction queued in a pocket is
///     still there after the system reclaims the app.
///   * IT GIVES UP HONESTLY. A transient failure is retried on
///     [OutboxPolicy.backoff] and then becomes a failure with a sentence the
///     UI can show. A permanent one - a refused password, a refused address -
///     is not retried at all.
///   * OFFLINE COSTS NOTHING. With no connection the entry stays queued and NO
///     attempt is spent; the controller pumps again when the radio comes back.
///
/// THE ONE THING IT CANNOT PROMISE. A process killed between "the server took
/// it" and "the file says sent" leaves an entry that will be tried again, and
/// the assistant may see the instruction twice. The alternative - writing
/// "sent" before sending - loses instructions instead, which is worse. The
/// window is milliseconds wide and the document says so.
class AssistantOutbox {
  AssistantOutbox({
    required FileStore fileStore,
    required String directory,
    required EmailSender sender,
    required AssistantAccountStore accounts,
    required Future<String> Function() assistantAddress,
    NetworkStatus? network,
    // Four plain fields behind public names: the parameters are part of the
    // API and the fields are private, so an initializing formal is not
    // available for any of them.
    // ignore_for_file: prefer_initializing_formals
    this.policy = const OutboxPolicy(),
    DateTime Function()? clock,
    this.historyLimit = defaultHistoryLimit,
  })  : _fileStore = fileStore,
        path = fileStore.join(directory, fileName),
        _sender = sender,
        _accounts = accounts,
        _assistantAddress = assistantAddress,
        _network = network,
        _now = clock ?? DateTime.now;

  static const String fileName = 'assistant-outbox.json';

  /// How many finished entries are kept. They are the dedupe memory as much as
  /// they are a history: a note whose entry has been pruned could be sent
  /// again if it were transcribed again, so this is generous. The settings
  /// screen shows only the newest handful of them.
  static const int defaultHistoryLimit = 200;

  final FileStore _fileStore;
  final String path;
  final EmailSender _sender;
  final AssistantAccountStore _accounts;

  /// Where instructions go. A callback rather than a string: the address is a
  /// setting the user can change while an entry is still waiting, and the one
  /// that counts is the one in force when it actually goes.
  final Future<String> Function() _assistantAddress;

  final NetworkStatus? _network;
  final OutboxPolicy policy;
  final DateTime Function() _now;
  final int historyLimit;

  /// Newest first. The whole outbox: waiting, sending and finished.
  final List<AssistantSend> _entries = <AssistantSend>[];

  /// Called after anything changes, so a controller can rebuild. Set by the
  /// controller; null in a test that only asserts on state.
  void Function()? onChanged;

  /// Serialises writes, so two changes in the same tick cannot interleave into
  /// a half-written file.
  Future<void> _writes = Future<void>.value();

  bool _loaded = false;
  bool _sending = false;

  bool get isLoaded => _loaded;

  /// Everything the outbox holds, newest first.
  List<AssistantSend> get entries => List<AssistantSend>.unmodifiable(_entries);

  /// The newest [limit] entries, for the settings screen's list.
  List<AssistantSend> recent([int limit = 20]) =>
      List<AssistantSend>.unmodifiable(_entries.take(limit));

  /// True when something is waiting to go out.
  bool get hasPending => _entries.any((entry) => !entry.isSettled);

  AssistantSend? entryFor(String noteId) {
    for (final entry in _entries) {
      if (entry.noteId == noteId) return entry;
    }
    return null;
  }

  /// What the note screen shows for [noteId]. [AssistantSendStatus.notSent]
  /// for a note the outbox has never heard of.
  AssistantSendStatus statusFor(String noteId) =>
      entryFor(noteId)?.status ?? AssistantSendStatus.notSent;

  /// The earliest moment [pump] would have something to do, or null when it
  /// would not. The controller sets its timer by this instead of polling.
  DateTime? get nextDue {
    DateTime? soonest;
    for (final entry in _entries) {
      if (entry.isSettled) continue;
      if (soonest == null || entry.readyAt.isBefore(soonest)) {
        soonest = entry.readyAt;
      }
    }
    return soonest;
  }

  /// Reads the saved queue. Called once at startup, before anything is
  /// enqueued.
  Future<void> load() async {
    if (_loaded) return;
    _entries
      ..clear()
      ..addAll(await _read());
    _loaded = true;
    onChanged?.call();
  }

  Future<List<AssistantSend>> _read() async {
    try {
      if (await _fileStore.stat(path) == null) return const <AssistantSend>[];
      final json = jsonDecode(utf8.decode(await _fileStore.read(path)));
      if (json is! Map<String, Object?> || json['version'] != 1) {
        return const <AssistantSend>[];
      }
      final raw = json['entries'];
      if (raw is! List<Object?>) return const <AssistantSend>[];
      final entries = <AssistantSend>[];
      for (final item in raw) {
        // A damaged entry is DROPPED, never guessed at: a half-read entry is
        // an instruction nobody can vouch for, and this is the one place in
        // the app that talks to the outside world.
        final entry = AssistantSend.fromJson(item);
        if (entry != null) entries.add(entry);
      }
      return entries;
    } on Object {
      return const <AssistantSend>[];
    }
  }

  /// Puts one instruction in the outbox, with the undo window open.
  ///
  /// Returns the new entry, or null when this note is already known (the
  /// dedupe) or the instruction is empty. The caller does NOT need to check
  /// first: asking twice is safe and is what makes a re-transcription
  /// harmless.
  Future<AssistantSend?> enqueue({
    required String noteId,
    required String instruction,
    required DateTime spokenAt,
  }) async {
    // Before anything else: an outbox that has not read its file yet does not
    // know which notes have already been sent, and the dedupe is the whole
    // guarantee.
    if (!_loaded) await load();
    final text = instruction.trim();
    if (text.isEmpty) return null;
    if (entryFor(noteId) != null) return null;
    final entry = AssistantSend.pending(
      noteId: noteId,
      instruction: text,
      spokenAt: spokenAt,
      now: _now(),
      policy: policy,
    );
    _entries.insert(0, entry);
    await _persist();
    return entry;
  }

  /// Takes [noteId] out of the outbox while the undo window is open.
  ///
  /// True when it was undone. False when the window had closed, when the note
  /// is not here, or when it has already gone - and in those cases nothing is
  /// changed, because "undo" cannot mean "unsend".
  Future<bool> undo(String noteId) async {
    if (!_loaded) await load();
    final entry = entryFor(noteId);
    if (entry == null || !entry.undoOpen(_now())) return false;
    _entries.remove(entry);
    await _persist();
    return true;
  }

  /// Puts a failed [noteId] back in the queue, at the front of the backoff.
  /// True when there was something to retry.
  Future<bool> retry(String noteId) async {
    if (!_loaded) await load();
    final entry = entryFor(noteId);
    if (entry == null || entry.status != AssistantSendStatus.failed) {
      return false;
    }
    _replace(entry.retried(_now()));
    await _persist();
    return true;
  }

  /// Forgets everything. For "turn this off and clear it out".
  Future<void> clear() async {
    _loaded = true;
    _entries.clear();
    await _persist();
  }

  /// Moves the queue on as far as it can right now: closes undo windows that
  /// have expired, and sends the oldest due entry.
  ///
  /// Safe to call at any time and from anywhere - a second call while one is
  /// sending returns at once.
  Future<void> pump() async {
    if (!_loaded) await load();
    var changed = false;
    final now = _now();
    for (final entry in List<AssistantSend>.of(_entries)) {
      if (entry.status == AssistantSendStatus.pendingUndo &&
          !entry.undoOpen(now)) {
        _replace(entry.release());
        changed = true;
      }
    }
    if (changed) await _persist();
    if (_sending) return;

    _sending = true;
    try {
      // One at a time, oldest first, until nothing is due. A LOOP AND NOT
      // RECURSION: an entry that is due and cannot progress - the phone is
      // offline - leaves the queue exactly as it was, and a pump that called
      // itself again would spin on it forever.
      while (true) {
        final due = _oldestDue();
        if (due == null) break;
        if (!await _deliver(due)) break;
      }
    } finally {
      _sending = false;
    }
  }

  /// The entry that should go next: the oldest one whose time has come.
  /// Instructions are said in an order and should arrive in one, and the list
  /// is newest first, so this walks it backwards.
  AssistantSend? _oldestDue() {
    final now = _now();
    for (final entry in _entries.reversed) {
      if (entry.isDue(now)) return entry;
    }
    return null;
  }

  /// THE SEND. The only place in this app that hands anything to
  /// [EmailSender], and the only place that builds an [AssistantMessage].
  ///
  /// True when the queue moved - the entry was sent, failed, or backed off.
  /// FALSE when nothing can move at all (no connection), which is what stops
  /// [pump] from looping.
  Future<bool> _deliver(AssistantSend entry) async {
    final account = await _accounts.load();
    if (account == null) {
      _replace(entry.afterFailure(
        AssistantFailure.notConfigured,
        now: _now(),
        policy: policy,
      ));
      await _persist();
      return true;
    }

    // Offline: the entry waits, and the attempt is NOT spent. Sitting in a
    // tunnel must not use up the retry budget the user needs when they come
    // out of it.
    final network = _network;
    if (network != null && await network.current() == NetworkKind.none) {
      _replace(entry.copyWith(failure: AssistantFailure.network));
      await _persist();
      return false;
    }

    final to = (await _assistantAddress()).trim();
    if (!to.contains('@')) {
      _replace(entry.afterFailure(
        AssistantFailure.address,
        now: _now(),
        policy: policy,
      ));
      await _persist();
      return true;
    }

    _replace(entry.startSending());
    await _persist();

    final result = await _sender.send(
      AssistantMessage.forInstruction(
        // The stripped instruction, and nothing else. Not the raw transcript,
        // not the note id, not the file, not another note.
        instruction: entry.instruction,
        spokenAt: entry.spokenAt,
        from: account.address,
        to: to,
      ),
      account,
    );

    // The entry may have been rewritten while the socket was open.
    final current = entryFor(entry.noteId) ?? entry;
    if (result.ok) {
      _replace(current.succeeded(_now()));
    } else {
      _replace(current.afterFailure(
        reasonFor(result.failure),
        now: _now(),
        policy: policy,
      ));
    }
    await _persist();
    return true;
  }

  /// One email, now: no queue, no undo window, no retry. The setup screen's
  /// "send a test email" and nothing else.
  ///
  /// It goes through this class rather than round it so that [EmailSender]
  /// keeps exactly one caller in the whole app - which is what makes "here is
  /// every byte that leaves the phone" a thing anyone can check.
  Future<EmailResult> sendOnce(AssistantMessage message, SmtpAccount account) =>
      _sender.send(message, account);

  /// What an [EmailFailure] means to the queue. Public because the test send
  /// needs the same translation.
  static AssistantFailure reasonFor(EmailFailure? failure) => switch (failure) {
        EmailFailure.signIn => AssistantFailure.signIn,
        EmailFailure.recipient => AssistantFailure.address,
        EmailFailure.connection => AssistantFailure.network,
        EmailFailure.server => AssistantFailure.server,
        EmailFailure.unknown || null => AssistantFailure.server,
      };

  void _replace(AssistantSend entry) {
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].noteId == entry.noteId) {
        _entries[i] = entry;
        return;
      }
    }
    _entries.insert(0, entry);
  }

  /// Trims finished entries down to [historyLimit], writes the file, and tells
  /// the controller. Awaited by every mutator, so what is in memory and what is
  /// on disk cannot disagree across a suspend.
  Future<void> _persist() {
    _prune();
    onChanged?.call();
    final write = _writes.then((_) async {
      try {
        await _fileStore.writeBytes(
          path,
          utf8.encode(jsonEncode(<String, Object?>{
            'version': 1,
            'entries': <Map<String, Object?>>[
              for (final entry in _entries) entry.toJson(),
            ],
          })),
        );
      } on Object {
        // A queue that cannot be written still works for this session. It is
        // not worth taking the app down, and the instruction itself must not
        // be logged.
      }
    });
    _writes = write;
    return write;
  }

  void _prune() {
    var settled = 0;
    // Newest first, so the ones past the limit are the oldest.
    _entries.removeWhere((entry) {
      if (!entry.isSettled) return false;
      settled++;
      return settled > historyLimit;
    });
  }
}
