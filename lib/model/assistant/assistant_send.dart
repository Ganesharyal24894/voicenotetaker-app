/// One instruction on its way to the assistant, and the rules that move it
/// along.
///
/// PURE: JSON in and out, a clock passed in, no I/O. The outbox service owns
/// the file and the timers; everything about WHEN a send may go, how long it
/// waits after a failure and when it gives up is decided here, where a test
/// can wind the clock by hand.
library;

/// Where one note's instruction has got to.
///
/// The UI shows exactly these six. [notSent] is the absence of an entry - a
/// note nobody addressed to the assistant, or one whose send was undone.
enum AssistantSendStatus {
  /// Not going anywhere. No wake phrase, or the user undid it.
  notSent,

  /// Recognised, and the Undo button is on screen. NOTHING HAS BEEN SENT and
  /// nothing will be until this window closes.
  pendingUndo,

  /// Waiting: for the network, for its turn, or for a backoff to expire.
  queued,

  /// On the wire right now.
  sending,

  /// The assistant's mail server accepted it.
  sent,

  /// It did not go, and the outbox has stopped trying. [AssistantSend.failure]
  /// says why in words a screen can show.
  failed,
}

/// Why a send did not happen, in the terms the user can act on.
enum AssistantFailure {
  /// No sending account is set up yet, or it was cleared.
  notConfigured,

  /// The mail server refused the sender's password. Retrying cannot help -
  /// Gmail has invalidated the app password, or it was typed wrong.
  signIn,

  /// The mail server refused the assistant's address. Also permanent.
  address,

  /// No connection, or the connection broke. Worth trying again.
  network,

  /// The mail server said "not now" - rate limit, greylisting, a 4xx. Worth
  /// trying again.
  server,

  /// Tried for the whole retry window and never got through.
  gaveUp,
}

extension AssistantFailureMessage on AssistantFailure {
  /// One plain sentence for a screen. No error codes, no host names.
  String get message => switch (this) {
        AssistantFailure.notConfigured =>
          'Set up the sending account before speaking to your assistant.',
        AssistantFailure.signIn =>
          "Gmail didn't accept the app password. Add it again in Settings.",
        AssistantFailure.address =>
          "The assistant's email address was refused. Check it in Settings.",
        AssistantFailure.network =>
          'No connection. This will go as soon as you are back online.',
        AssistantFailure.server =>
          'The mail server would not take it just now. Trying again.',
        AssistantFailure.gaveUp =>
          "This didn't get through. Tap to try again.",
      };

  /// Whether waiting and trying again could change the answer.
  bool get isWorthRetrying =>
      this == AssistantFailure.network || this == AssistantFailure.server;
}

/// The timings the outbox runs on. One place, so the undo window on screen and
/// the undo window in the queue cannot drift apart.
///
/// WHY NOT `DownloadRetryPolicy` (`lib/model/model_download.dart`). That one
/// was looked at first and does not fit: three of its five fields are about
/// HTTP - `transientStatuses` is a set of status codes, `maxServerDelay`
/// bounds a `Retry-After` header, and neither exists in SMTP - and its waits
/// are jittered by `Random`, which a queue that writes `readyAt` to disk and
/// is read back after a restart cannot use. The shapes differ too: a download
/// is a foreground bar somebody is watching, so it doubles from one second and
/// caps at twenty; an instruction in a pocket should wait minutes rather than
/// burn its attempts in the first half-minute underground. What is shared -
/// "a transient failure waits and tries again, a permanent one does not" -
/// lives in [AssistantFailure.isWorthRetrying] here and in
/// `DownloadRetryPolicy.shouldRetry` there, each in the vocabulary of its own
/// protocol. Reusing one class for both would mean an SMTP queue carrying a
/// list of HTTP status codes it can never see.
class OutboxPolicy {
  const OutboxPolicy({
    this.undoWindow = defaultUndoWindow,
    this.backoff = defaultBackoff,
  });

  /// Five seconds of "Undo" before anything is sent. Long enough to catch a
  /// note that was not meant for the assistant, short enough that the user is
  /// not left watching a countdown.
  static const Duration defaultUndoWindow = Duration(seconds: 5);

  /// What to wait before attempt 2, 3, 4, 5 and 6. Doubling from ten seconds
  /// to five minutes, which covers a lift, a tunnel and a flaky café Wi-Fi
  /// without holding a socket open through any of it. Running out of this list
  /// is what "gave up" means.
  static const List<Duration> defaultBackoff = <Duration>[
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 5),
  ];

  final Duration undoWindow;
  final List<Duration> backoff;

  /// How many times a send is tried in all: the first go plus one per backoff.
  int get maxAttempts => backoff.length + 1;

  /// The longest an instruction can sit in the outbox before it is called a
  /// failure, for the document and for a test that asserts the bound.
  Duration get retryWindow =>
      backoff.fold(Duration.zero, (total, wait) => total + wait);

  /// How long to wait after [attempts] failed tries, or null when there is
  /// nothing left to wait for.
  Duration? waitAfter(int attempts) {
    if (attempts < 1 || attempts > backoff.length) return null;
    return backoff[attempts - 1];
  }
}

/// One note's instruction in the outbox.
///
/// Immutable; every transition returns a new one, so a half-applied change
/// cannot be written to disk.
class AssistantSend {
  const AssistantSend({
    required this.noteId,
    required this.instruction,
    required this.spokenAt,
    required this.status,
    required this.readyAt,
    this.attempts = 0,
    this.failure,
    this.sentAt,
  });

  /// Which note this came from - the recording's absolute path, the same id
  /// the rest of the app uses. THE DEDUPE KEY: one note is one send, for the
  /// life of the outbox.
  final String noteId;

  /// The transcript with the wake phrase stripped. The entire outbound
  /// payload.
  final String instruction;

  /// When the note was spoken, which is what the subject line says.
  final DateTime spokenAt;

  final AssistantSendStatus status;

  /// The earliest moment this may go: the end of the undo window, then the end
  /// of each backoff.
  final DateTime readyAt;

  /// How many times the mail server has been asked.
  final int attempts;

  /// Why it is not going, or why the last try did not work. Kept on a
  /// [AssistantSendStatus.queued] entry too, so a screen can say "no
  /// connection" while it waits.
  final AssistantFailure? failure;

  final DateTime? sentAt;

  /// A brand-new entry: the undo window opens now.
  factory AssistantSend.pending({
    required String noteId,
    required String instruction,
    required DateTime spokenAt,
    required DateTime now,
    required OutboxPolicy policy,
  }) =>
      AssistantSend(
        noteId: noteId,
        instruction: instruction,
        spokenAt: spokenAt,
        status: AssistantSendStatus.pendingUndo,
        readyAt: now.add(policy.undoWindow),
        attempts: 0,
      );

  /// Whether this entry is finished with, one way or the other.
  bool get isSettled =>
      status == AssistantSendStatus.sent || status == AssistantSendStatus.failed;

  /// Whether the undo window is still open at [now]. The outbox refuses to
  /// send while this is true, and [undo] only works while it is.
  bool undoOpen(DateTime now) =>
      status == AssistantSendStatus.pendingUndo && now.isBefore(readyAt);

  /// Whether this entry is due to be attempted at [now].
  bool isDue(DateTime now) =>
      status == AssistantSendStatus.queued && !now.isBefore(readyAt);

  /// The undo window has closed with no undo: it joins the queue.
  AssistantSend release() => copyWith(
        status: AssistantSendStatus.queued,
        clearFailure: true,
      );

  AssistantSend startSending() => copyWith(status: AssistantSendStatus.sending);

  AssistantSend succeeded(DateTime now) => copyWith(
        status: AssistantSendStatus.sent,
        attempts: attempts + 1,
        sentAt: now,
        clearFailure: true,
      );

  /// A failed attempt: queued again after the next backoff, or failed for good
  /// when the failure is permanent or the backoffs have run out.
  AssistantSend afterFailure(
    AssistantFailure reason, {
    required DateTime now,
    required OutboxPolicy policy,
  }) {
    final tried = attempts + 1;
    if (!reason.isWorthRetrying) {
      return copyWith(
        status: AssistantSendStatus.failed,
        attempts: tried,
        failure: reason,
      );
    }
    final wait = policy.waitAfter(tried);
    if (wait == null) {
      return copyWith(
        status: AssistantSendStatus.failed,
        attempts: tried,
        failure: AssistantFailure.gaveUp,
      );
    }
    return copyWith(
      status: AssistantSendStatus.queued,
      attempts: tried,
      readyAt: now.add(wait),
      failure: reason,
    );
  }

  /// The user asked for it again after it failed. The attempt count starts
  /// over: this is a new decision, not a continuation of the old backoff.
  AssistantSend retried(DateTime now) => copyWith(
        status: AssistantSendStatus.queued,
        attempts: 0,
        readyAt: now,
        clearFailure: true,
      );

  AssistantSend copyWith({
    AssistantSendStatus? status,
    DateTime? readyAt,
    int? attempts,
    AssistantFailure? failure,
    bool clearFailure = false,
    DateTime? sentAt,
  }) =>
      AssistantSend(
        noteId: noteId,
        instruction: instruction,
        spokenAt: spokenAt,
        status: status ?? this.status,
        readyAt: readyAt ?? this.readyAt,
        attempts: attempts ?? this.attempts,
        failure: clearFailure ? null : (failure ?? this.failure),
        sentAt: sentAt ?? this.sentAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'noteId': noteId,
        'instruction': instruction,
        'spokenAt': spokenAt.toIso8601String(),
        'status': status.name,
        'readyAt': readyAt.toIso8601String(),
        'attempts': attempts,
        if (failure != null) 'failure': failure!.name,
        if (sentAt != null) 'sentAt': sentAt!.toIso8601String(),
      };

  /// The entry in [json], or null when it is not one this build can read.
  /// Never throws: a damaged outbox file must not stop the app starting, and
  /// it must never be guessed at - a half-read entry could be sent twice.
  static AssistantSend? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final noteId = json['noteId'];
    final instruction = json['instruction'];
    final spokenAt = json['spokenAt'];
    final readyAt = json['readyAt'];
    if (noteId is! String ||
        noteId.isEmpty ||
        instruction is! String ||
        spokenAt is! String ||
        readyAt is! String) {
      return null;
    }
    final spoken = DateTime.tryParse(spokenAt);
    final ready = DateTime.tryParse(readyAt);
    if (spoken == null || ready == null) return null;
    final status = _statusNamed(json['status']);
    if (status == null) return null;
    final attempts = json['attempts'];
    final sentAt = json['sentAt'];
    return AssistantSend(
      noteId: noteId,
      instruction: instruction,
      spokenAt: spoken,
      // A process killed mid-send left "sending" on disk. It is NOT resumed as
      // sending: the send either reached the server or it did not, and the
      // outbox cannot know which. It goes back in the queue, which is why the
      // server-side duplicate is the one risk this design accepts and the
      // document says so.
      status: status == AssistantSendStatus.sending
          ? AssistantSendStatus.queued
          : status,
      readyAt: ready,
      attempts: attempts is int ? attempts : 0,
      failure: _failureNamed(json['failure']),
      sentAt: sentAt is String ? DateTime.tryParse(sentAt) : null,
    );
  }

  static AssistantSendStatus? _statusNamed(Object? name) {
    for (final value in AssistantSendStatus.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static AssistantFailure? _failureNamed(Object? name) {
    for (final value in AssistantFailure.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  /// Never prints [instruction].
  @override
  String toString() => 'AssistantSend(${status.name}, attempts: $attempts, '
      '${instruction.length} chars)';
}
