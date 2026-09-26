import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drivers/email_sender.dart';
import '../drivers/file_store.dart';
import '../drivers/haptics.dart';
import '../drivers/network_status.dart';
import '../drivers/secret_store.dart';
import '../model/assistant/assistant_message.dart';
import '../model/assistant/assistant_send.dart';
import '../model/assistant/assistant_settings.dart';
import '../model/assistant/wake_phrase.dart';
import '../services/assistant/assistant_account_store.dart';
import '../services/assistant/assistant_outbox.dart';
import '../services/assistant/assistant_settings_store.dart';

/// How the "send a test email" button is getting on.
enum AssistantTestState {
  /// Nothing tried yet, or the form has been edited since.
  idle,

  /// On the wire.
  sending,

  /// The mail server took it. The user should now look in their assistant's
  /// chat for the reply.
  sent,

  /// It did not go. [AssistantController.testFailure] says why.
  failed,
}

/// "Speak to your assistant": the whole feature, in one controller.
///
/// SEPARATE FROM `AppController`, like `SummaryController` and
/// `ExportController`. Nothing here touches the radio or the recorder; it is
/// handed a finished transcript and decides whether the user was addressing
/// their assistant.
///
/// OFF UNTIL SET UP. [enabled] is false on a fresh install and there is no
/// account; in that state [noteTranscribed] does nothing at all and no code
/// path in this feature can reach the network.
///
/// OFF ALSO MEANS INERT. With the switch off, starting up reads ONE small JSON
/// file - the settings, which is how it learns the switch is off - and stops
/// there: no keystore read, no outbox file, no connectivity subscription, no
/// timer. [setEnabled] does that deferred work the moment the user turns it on,
/// and undoes it when they turn it off, so a feature nobody uses costs a file
/// read per launch and nothing else.
///
/// THE ONE OUTBOUND PATH. Everything that leaves goes through
/// [AssistantOutbox], which is the only caller of [EmailSender]. What leaves is
/// one plain-text email per note, holding the instruction the user spoke with
/// the wake phrase stripped - no audio, no other note, no identifiers.
class AssistantController extends ChangeNotifier {
  AssistantController({
    required FileStore fileStore,
    required String directory,
    required EmailSender sender,
    SecretStore? secrets,
    NetworkStatus? network,
    Haptics? haptics,
    OutboxPolicy policy = const OutboxPolicy(),
    DateTime Function()? clock,
    AssistantOutbox? outbox,
  })  : _now = clock ?? DateTime.now,
        // A plain field behind a public name: the parameter is part of the
        // API and the field is private, so an initializing formal is not
        // available.
        // ignore: prefer_initializing_formals
        _haptics = haptics,
        _network = network,
        _policy = policy,
        _settingsStore = AssistantSettingsStore(
          fileStore: fileStore,
          directory: directory,
        ),
        _accounts = AssistantAccountStore(
          secrets: secrets ?? MemorySecretStore(),
        ) {
    _outbox = outbox ??
        AssistantOutbox(
          fileStore: fileStore,
          directory: directory,
          sender: sender,
          accounts: _accounts,
          assistantAddress: () async => _settings.assistantAddress,
          network: network,
          policy: policy,
          clock: _now,
        );
    _outbox.onChanged = _onOutboxChanged;
  }

  /// What the setup screen prefills. The user confirmed both by test; either
  /// can be typed over.
  static const String defaultAssistantAddress =
      AssistantSettings.defaultAssistantAddress;
  static const String defaultSenderAddress =
      AssistantSettings.defaultSenderAddress;
  static const String defaultWakePhrase = WakePhraseDetector.defaultPhrase;
  static const String defaultSmtpHost = SmtpAccount.defaultHost;
  static const int defaultSmtpPort = SmtpAccount.defaultPort;

  /// What the test email says, so the user can recognise it in the reply.
  static const String testInstruction =
      'This is a test from my voice notes app. Please reply so I know it '
      'arrived.';

  final DateTime Function() _now;
  final Haptics? _haptics;
  final NetworkStatus? _network;
  final OutboxPolicy _policy;
  final AssistantSettingsStore _settingsStore;
  final AssistantAccountStore _accounts;
  late final AssistantOutbox _outbox;

  AssistantSettings _settings = const AssistantSettings();
  SmtpAccount? _account;
  bool _loaded = false;

  /// Whether the account and the saved outbox have been read. False on a
  /// disabled launch until something asks - see [prepare].
  bool _prepared = false;

  /// Memoised, so two screens asking at once do not read the keystore twice.
  Future<void>? _preparing;

  /// Whether the machinery that can actually send is running: the connectivity
  /// subscription and the outbox timer. Only ever true while [enabled].
  bool _active = false;
  bool _disposed = false;
  AssistantTestState _testState = AssistantTestState.idle;
  AssistantFailure? _testFailure;
  Timer? _tick;
  StreamSubscription<NetworkKind>? _networkWatch;

  // ---------------------------------------------------------------- lifecycle

  /// Reads the settings and, ONLY IF THE FEATURE IS ON, the account, the saved
  /// outbox and the connection - then moves anything that was waiting when the
  /// app was last killed.
  ///
  /// Called once at startup. Safe to call again; the second call does nothing.
  ///
  /// WITH THE SWITCH OFF THIS STOPS AFTER THE SETTINGS FILE. Reading it is
  /// unavoidable: it is how the switch is known. Nothing else is touched - the
  /// keystore is not opened, the outbox file is not read, no connectivity
  /// stream is subscribed to and no timer is set. [prepare] is how the
  /// feature's own screens get the rest when the user looks at them, and
  /// [setEnabled] is what starts the machinery.
  Future<void> initialise() async {
    if (_loaded) return;
    _settings = await _settingsStore.load();
    _loaded = true;
    if (!_settings.enabled) {
      _emit();
      return;
    }
    await _activate();
  }

  /// Reads the account and the saved outbox WITHOUT starting anything.
  ///
  /// For the feature's own screens, and for them only. With the switch off
  /// nothing about the feature is read at launch, but the row in Recorder
  /// settings still has to tell "Off" apart from "Not set up", and the setup
  /// screen still has to show the address that is saved. So the row asks for
  /// this when it appears - see `view/assistant/assistant_settings_row.dart`.
  ///
  /// It subscribes to nothing and sends nothing: looking at the settings of a
  /// feature that is off is not turning it on.
  Future<void> prepare() => _preparing ??= _prepare();

  Future<void> _prepare() async {
    if (!_loaded) {
      _settings = await _settingsStore.load();
      _loaded = true;
    }
    _account = await _accounts.load();
    await _outbox.load();
    _prepared = true;
    _emit();
  }

  /// Everything [prepare] does, plus the parts that can make a send happen:
  /// the connectivity subscription and the timer.
  Future<void> _activate() async {
    await prepare();
    if (_disposed || _active) return;
    _active = true;
    _watchNetwork();
    _emit();
    // A note that was queued and then had the app killed under it goes now.
    unawaited(_pump());
  }

  /// Stops the machinery. What is on disk is NOT touched: an instruction that
  /// was queued is still queued, and goes when the feature is on again.
  void _deactivate() {
    _active = false;
    _tick?.cancel();
    _tick = null;
    final watch = _networkWatch;
    _networkWatch = null;
    unawaited(watch?.cancel());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _deactivate();
    _outbox.onChanged = null;
    super.dispose();
  }

  // ----------------------------------------------------------------- settings

  /// False until the settings have been read. A screen shows its own
  /// placeholder rather than "off" while this is false.
  bool get isLoaded => _loaded;

  /// False until the account and the saved outbox have been read as well -
  /// which, with the feature off, does not happen until [prepare] is called.
  /// [hasAccount], [statusFor] and [recentSends] are only meaningful once this
  /// is true.
  bool get isReady => _loaded && _prepared;

  /// Whether a note beginning with the wake phrase is emailed.
  ///
  /// Off on a fresh install. Turning it on without an account does nothing
  /// useful, which is what [needsSetup] is for.
  bool get enabled => _settings.enabled;

  /// True when the switch is on but there is no sending account yet - the one
  /// state where the feature looks on and cannot work.
  bool get needsSetup => _settings.enabled && !hasAccount;

  /// Whether a sending account is saved. The password itself is never
  /// readable from here.
  bool get hasAccount => _account != null;

  /// The address mail is sent FROM, for the settings screen to show. Null when
  /// no account is set up. The password has no getter, by design.
  String? get senderAddress => _account?.address;

  /// The SMTP host and port in use, for the settings screen's advanced row.
  String get smtpHost => _account?.host ?? defaultSmtpHost;
  int get smtpPort => _account?.port ?? defaultSmtpPort;
  bool get smtpUsesSsl => _account?.useSsl ?? SmtpAccount.defaultUseSsl;

  /// What the user says to address the assistant.
  String get wakePhrase => _settings.wakePhrase;

  /// Where instructions go.
  String get assistantAddress => _settings.assistantAddress;

  /// Whether the phone can buzz when the wake phrase is heard. FALSE ON iOS,
  /// where an app in the background cannot vibrate on its own - the settings
  /// screen should say so plainly rather than offer a toggle that lies.
  bool get canVibrate => _haptics != null;

  /// How long the Undo button stays up.
  Duration get undoWindow => _policy.undoWindow;

  /// Turns the feature on or off.
  ///
  /// TURNING IT ON does the work a disabled launch skipped: the account, the
  /// saved outbox, the connectivity subscription and a first pump. So the first
  /// note after the switch goes on behaves exactly as it would have if the
  /// feature had been on all along - including sending anything that was left
  /// queued from last time.
  ///
  /// TURNING IT OFF stops all of that: the subscription is cancelled and the
  /// timer is dropped, so an app the user has switched off holds nothing open.
  /// WHAT IS QUEUED IS KEPT, NOT SENT. The outbox file is left exactly as it
  /// is - nothing is dropped - and those entries go out when the feature is
  /// switched on again. Off has to mean nothing leaves the phone; finishing a
  /// queue after the user has said stop would be worse than a late
  /// instruction. Use [forgetEverything] to throw them away instead.
  Future<void> setEnabled(bool value) async {
    if (_settings.enabled == value) return;
    _settings = _settings.copyWith(enabled: value);
    await _settingsStore.save(_settings);
    if (value) {
      await _activate();
    } else {
      _deactivate();
    }
    _emit();
  }

  /// Changes the wake phrase. An empty or too-short phrase is refused - it
  /// would make every note an instruction - and false comes back so the screen
  /// can say why.
  Future<bool> setWakePhrase(String phrase) async {
    final trimmed = phrase.trim();
    if (!WakePhraseDetector(phrase: trimmed).isUsable) return false;
    _settings = _settings.copyWith(wakePhrase: trimmed);
    await _settingsStore.save(_settings);
    _emit();
    return true;
  }

  /// Changes the assistant's address. Refused, with false, when it is not an
  /// address.
  Future<bool> setAssistantAddress(String address) async {
    final trimmed = address.trim();
    if (!trimmed.contains('@')) return false;
    _settings = _settings.copyWith(assistantAddress: trimmed);
    await _settingsStore.save(_settings);
    _emit();
    return true;
  }

  /// Saves the sending account into the platform keystore.
  ///
  /// [password] is a Gmail app password. It is written straight to the
  /// keystore, is never held in a settings file, and is never returned by
  /// anything on this controller. False when the details are incomplete.
  Future<bool> saveAccount({
    required String address,
    required String password,
    String host = defaultSmtpHost,
    int port = defaultSmtpPort,
    bool useSsl = SmtpAccount.defaultUseSsl,
  }) async {
    final account = SmtpAccount(
      address: address.trim(),
      password: password,
      host: host.trim().isEmpty ? defaultSmtpHost : host.trim(),
      port: port,
      useSsl: useSsl,
    );
    if (!account.isComplete) return false;
    await _accounts.save(account);
    _account = account;
    _testState = AssistantTestState.idle;
    _testFailure = null;
    _emit();
    return true;
  }

  /// Forgets the sending account. The feature cannot send anything afterwards.
  Future<void> clearAccount() async {
    await _accounts.clear();
    _account = null;
    _testState = AssistantTestState.idle;
    _testFailure = null;
    _emit();
  }

  /// Off, account forgotten, outbox emptied. For "remove this from my phone".
  Future<void> forgetEverything() async {
    _settings = const AssistantSettings();
    await _settingsStore.save(_settings);
    // Off, and so inert: no subscription and no timer left behind.
    _deactivate();
    await _accounts.clear();
    _account = null;
    await _outbox.clear();
    _testState = AssistantTestState.idle;
    _testFailure = null;
    _emit();
  }

  // ---------------------------------------------------------------- test send

  AssistantTestState get testState => _testState;

  /// Why the last test did not go. `AssistantFailureMessage.message`, in the
  /// view's own copy, is the sentence to show.
  AssistantFailure? get testFailure => _testFailure;

  /// Sends one email to the assistant, right now, with no undo window and
  /// without touching the outbox.
  ///
  /// This is the setup screen's "send a test email". It is the ONE send that
  /// does not come from a note, and it says so in its own text. True when the
  /// mail server took it.
  Future<bool> sendTestEmail() async {
    final account = _account;
    if (account == null) {
      _testState = AssistantTestState.failed;
      _testFailure = AssistantFailure.notConfigured;
      _emit();
      return false;
    }
    if (!_settings.assistantAddress.contains('@')) {
      _testState = AssistantTestState.failed;
      _testFailure = AssistantFailure.address;
      _emit();
      return false;
    }
    _testState = AssistantTestState.sending;
    _testFailure = null;
    _emit();

    final network = _network;
    if (network != null && await network.current() == NetworkKind.none) {
      _testState = AssistantTestState.failed;
      _testFailure = AssistantFailure.network;
      _emit();
      return false;
    }

    final result = await _outbox.sendOnce(
      AssistantMessage.forInstruction(
        instruction: testInstruction,
        spokenAt: _now(),
        from: account.address,
        to: _settings.assistantAddress,
      ),
      account,
    );
    if (_disposed) return result.ok;
    _testState =
        result.ok ? AssistantTestState.sent : AssistantTestState.failed;
    _testFailure = result.ok ? null : AssistantOutbox.reasonFor(result.failure);
    _emit();
    return result.ok;
  }

  // -------------------------------------------------------------------- notes

  /// The wake phrase in [transcript], or null when there is none.
  ///
  /// PURE and cheap - no I/O, nothing queued. For a note screen that wants to
  /// show the instruction without the wake phrase in front of it, and for the
  /// Notes list's title.
  WakePhraseMatch? matchIn(String transcript) =>
      _settings.detector.match(transcript);

  /// [transcript] as a title should show it: the wake phrase stripped when
  /// there is one, the text unchanged when there is not.
  ///
  /// THE RAW TRANSCRIPT ON DISK IS NOT TOUCHED. This is a display decision
  /// only; the note keeps every word that was said.
  String titleFor(String transcript) {
    final match = matchIn(transcript);
    if (match == null || !match.hasInstruction) return transcript;
    return match.instruction;
  }

  /// Offers a finished transcript to the assistant.
  ///
  /// Called once per note, when its transcript is saved. Returns the new
  /// outbox entry when the note was an instruction, and null otherwise - which
  /// covers all of: the feature off, no account, no wake phrase, nothing after
  /// the wake phrase, and a note already in the outbox.
  ///
  /// SAFE TO CALL TWICE. The outbox dedupes on [noteId], so re-transcribing a
  /// note cannot send it again.
  ///
  /// [noteId] is the recording's path, the id the rest of the app uses.
  Future<AssistantSend?> noteTranscribed({
    required String noteId,
    required String transcript,
    required DateTime spokenAt,
  }) async {
    // A note can be transcribed before the app has finished starting. Waiting
    // for the settings here is the difference between an instruction being
    // acted on and being silently dropped.
    if (!_loaded) await initialise();
    if (!_settings.enabled || _account == null) return null;
    final match = matchIn(transcript);
    if (match == null || !match.hasInstruction) return null;
    final entry = await _outbox.enqueue(
      noteId: noteId,
      instruction: match.instruction,
      spokenAt: spokenAt,
    );
    if (entry == null) return null;
    // One short buzz, so the user knows without looking. Android only; on iOS
    // [canVibrate] is false and the Undo banner is the whole feedback.
    unawaited(_haptics?.buzz(BuzzPattern.confirm) ?? Future<void>.value());
    _emit();
    // The five-second undo starts now; this wakes up when it ends.
    _schedule();
    return entry;
  }

  /// What the note screen shows for [noteId]:
  /// `notSent / pendingUndo / queued / sending / sent / failed`.
  AssistantSendStatus statusFor(String noteId) => _outbox.statusFor(noteId);

  /// The whole outbox entry for [noteId], for a screen that wants the failure
  /// reason or the time it went. Null when there is none.
  AssistantSend? entryFor(String noteId) => _outbox.entryFor(noteId);

  /// What to tell the user about [noteId], or null when there is nothing to
  /// say. `AssistantFailureMessage.message` turns it into the sentence - the
  /// words live in the view, not here.
  AssistantFailure? failureFor(String noteId) {
    final entry = _outbox.entryFor(noteId);
    final failure = entry?.failure;
    if (entry == null || failure == null) return null;
    if (entry.status == AssistantSendStatus.sent) return null;
    return failure;
  }

  /// How much of the undo window is left for [noteId] - [Duration.zero] when
  /// it has closed or there is nothing to undo. For a countdown ring.
  Duration undoRemaining(String noteId) {
    final entry = _outbox.entryFor(noteId);
    if (entry == null) return Duration.zero;
    final left = entry.readyAt.difference(_now());
    if (!entry.undoOpen(_now()) || left.isNegative) return Duration.zero;
    return left;
  }

  /// Stops [noteId] being sent, while the undo window is open. True when it
  /// was stopped; false means it had already gone, and the UI should say so
  /// rather than claim otherwise.
  Future<bool> undo(String noteId) async {
    final undone = await _outbox.undo(noteId);
    if (undone) _emit();
    return undone;
  }

  /// Tries a failed [noteId] again, from the top of the backoff. True when
  /// there was something to retry.
  Future<bool> retry(String noteId) async {
    final retried = await _outbox.retry(noteId);
    if (!retried) return false;
    _emit();
    unawaited(_pump());
    return true;
  }

  /// The newest sends, for the settings screen's list. Newest first, and it
  /// includes the ones that failed.
  List<AssistantSend> recentSends([int limit = 20]) => _outbox.recent(limit);

  /// True while anything is waiting, sending or backing off - for a "1 waiting
  /// to send" line.
  bool get hasPending => _outbox.hasPending;

  // ------------------------------------------------------------------ private

  void _onOutboxChanged() {
    _emit();
    _schedule();
  }

  /// A single timer, set to the next moment the outbox has something to do -
  /// the end of an undo window, or the end of a backoff. No polling: an app
  /// that wakes every second to find nothing to do is a battery cost for
  /// nothing.
  void _schedule() {
    // Not while the feature is off: a switched-off feature sets no timers.
    if (_disposed || !_active) return;
    _tick?.cancel();
    _tick = null;
    final due = _outbox.nextDue;
    if (due == null) return;
    final wait = due.difference(_now());
    _tick = Timer(wait.isNegative ? Duration.zero : wait, () {
      _tick = null;
      unawaited(_pump());
    });
  }

  Future<void> _pump() async {
    // THE ONE GATE THE OUTBOUND PATH GOES THROUGH. Nothing leaves the phone
    // while the feature is off, whoever asked.
    if (_disposed || !_active) return;
    await _outbox.pump();
    if (_disposed) return;
    _schedule();
  }

  /// Sends what is waiting the moment a connection comes back, instead of
  /// making the user wait out a backoff they did not cause.
  void _watchNetwork() {
    final network = _network;
    if (network == null) return;
    _networkWatch = network.changes.listen((kind) {
      if (kind == NetworkKind.none) return;
      unawaited(_pump());
    });
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }
}
