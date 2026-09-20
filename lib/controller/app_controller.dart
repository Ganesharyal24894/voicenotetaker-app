import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drivers/audio_player.dart';
import '../drivers/background_mode.dart';
import '../drivers/ble_pairing.dart';
import '../drivers/ble_transport.dart';
import '../drivers/file_store.dart';
import '../drivers/haptics.dart';
import '../drivers/phone_power.dart';
import '../drivers/platform_settings.dart';
import '../model/audio_codec.dart';
import '../model/auto_sleep.dart';
import '../model/background_task_plan.dart';
import '../model/background_transcription_policy.dart';
import '../model/battery_anchor.dart';
import '../model/battery_bars.dart';
import '../model/battery_history.dart';
import '../model/battery_report.dart';
import '../model/battery_status.dart';
import '../model/capture_flags.dart';
import '../model/continuous_status.dart';
import '../model/device_state.dart';
import '../model/device_test_aggregate.dart';
import '../model/device_test_result.dart';
import '../model/die_temperature.dart';
import '../model/level_reading.dart';
import '../model/link_health.dart';
import '../model/model_download.dart';
import '../model/not_saving_alert.dart';
import '../model/notes_saving.dart';
import '../model/pairing_outcome.dart';
import '../model/device_profile.dart';
import '../model/recorder_pairing.dart';
import '../model/recorder_sleep.dart';
import '../model/phone_power.dart';
import '../model/recording_info.dart';
import '../model/reconnect_backoff.dart';
import '../model/recording_metadata.dart';
import '../model/speaker_names.dart';
import '../model/speaker_settings.dart';
import '../model/stream_info.dart';
import '../model/language_router.dart';
import '../model/transcript.dart';
import '../model/transcript_paragraphs.dart';
import '../model/transcription.dart';
import '../services/audio_retention_service.dart';
import '../services/battery_anchor_store.dart';
import '../services/empty_note_service.dart';
import '../services/continuous/continuous_session.dart';
import '../services/continuous/continuous_settings_store.dart';
import '../services/continuous/note_writer.dart';
import '../services/device_test_service.dart';
import '../services/device_test_store.dart';
import '../services/link_monitor.dart';
import '../services/pairing/pairing_service.dart';
import '../services/pairing/pairing_store.dart';
import '../services/library_service.dart';
import '../services/recording_service.dart';
import '../services/transcription/model_download_service.dart';
import '../services/transcription/model_download_settings_store.dart';
import '../services/transcription/speaker_names_store.dart';
import '../services/transcription/speaker_settings_store.dart';
import '../services/transcription/transcript_store.dart';
import '../services/transcription/transcription_queue.dart';
import '../services/transcription/transcription_service.dart';
import '../services/transcription/transcription_settings_store.dart';
import '../services/wav_repair.dart';

/// What the app is doing right now, as one flat enum the placeholder view can
/// render without any further interpretation.
enum AppPhase {
  idle,
  scanning,
  connecting,
  connected,
  recording,
  stopping,
  error,
}

/// Where the battery history stands on this link.
enum BatteryHistoryStatus {
  /// Not read yet, or nothing connected.
  unknown,

  /// Read and decoded; [AppController.batteryReport] has it.
  ready,

  /// The recorder did not answer `fe09`.
  notSupported,

  /// The recorder answered with a layout this build cannot read.
  unreadable,
}

/// Why a link is ending.
///
/// The three ways it can happen differ in only a handful of details, and those
/// details live in one place - see `AppController._releaseLink` - rather than in
/// three teardowns that can drift apart.
enum _LinkEnding {
  /// The user asked, by tapping Disconnect.
  userAsked,

  /// The radio reported the peripheral gone while the adapter was still up.
  peripheralGone,

  /// The adapter itself went away - switched off, resetting, or the permission
  /// withdrawn - so there is no radio left to report anything at all.
  adapterLost,
}

/// Owns app state and sequences the drivers and services.
///
/// It depends only on the driver interfaces, so the same controller runs
/// against the real radio or against a fake in tests.
class AppController extends ChangeNotifier {
  AppController({
    required BleTransport transport,
    required FileStore fileStore,
    BlePairing? pairing,
    required this._recordingsDirectory,
    RecordingService? recordingService,
    LibraryService? libraryService,
    DeviceTestService? deviceTestService,
    LinkMonitor? linkMonitor,
    AudioPlayer? audioPlayer,
    PlatformSettings? platformSettings,
    TranscriptionService? transcriptionService,
    ModelDownloadService? modelDownloads,
    TranscriptStore? transcriptStore,
    BackgroundMode? backgroundMode,
    PhonePower? phonePower,
    this._haptics,
    this._onTranscriptSaved,
    NotSavingAlertPolicy? notSavingAlert,
    this._backgroundTranscription = false,
    this._powerRecheckInterval = BackgroundTranscriptionPolicy.recheckInterval,
    DateTime Function()? clock,
    String? settingsDirectory,
    this._continuousKeepalive = ContinuousSession.defaultKeepaliveInterval,
    this._asleepRetryDelay = ReconnectBackoff.asleepDelay,
    AudioCodec preferredCodec = AudioCodec.imaAdpcm,
    // The public parameter name `preferredCodec:` is part of the existing API,
    // while the field behind it is private because it is now reached through a
    // notifying setter - so an initializing formal is not available here.
    // ignore: prefer_initializing_formals
  })  : _preferredCodec = preferredCodec,
        _injectedTests = deviceTestService,
        _injectedLinkMonitor = linkMonitor,
        _transport = transport,
        _pairingService = pairing == null
            ? null
            : PairingService(
                driver: pairing,
                store: PairingStore(
                  fileStore: fileStore,
                  directory: settingsDirectory ?? _recordingsDirectory,
                ),
                clock: clock,
              ),
        _fileStore = fileStore,
        _player = audioPlayer,
        _settings = platformSettings,
        _transcription = transcriptionService,
        // ignore: prefer_initializing_formals
        _modelDownloads = modelDownloads,
        _background = backgroundMode,
        _power = phonePower,
        _savingAlert = notSavingAlert ?? NotSavingAlertPolicy(),
        _now = clock ?? DateTime.now,
        _retentionSettings = AudioRetentionSettingsStore(
          fileStore: fileStore,
          directory: settingsDirectory ?? _recordingsDirectory,
        ),
        _anchorStore = BatteryAnchorStore(
          fileStore: fileStore,
          directory: settingsDirectory ?? _recordingsDirectory,
        ),
        _settingsDirectory = settingsDirectory ?? _recordingsDirectory,
        _modelDownloadSettings = ModelDownloadSettingsStore(
          fileStore: fileStore,
          directory: settingsDirectory ?? _recordingsDirectory,
        ),
        _settingsStore = ContinuousSettingsStore(
          fileStore: fileStore,
          // Beside the recordings when no other place is given, as the mic
          // check's history already is; `main.dart` passes the support
          // directory.
          directory: settingsDirectory ?? _recordingsDirectory,
        ),
        _transcripts =
            transcriptStore ?? TranscriptStore(fileStore: fileStore),
        _library = libraryService ??
            LibraryService(
              fileStore: fileStore,
              directory: _recordingsDirectory,
            ),
        _recorder = recordingService ??
            RecordingService(transport: transport, fileStore: fileStore);

  /// Told about a transcript the moment it is saved: the path, when the note
  /// was recorded, and the words. The ONLY way anything in this app learns
  /// that a note is finished, and the only reason `AppController` and the
  /// assistant feature touch at all.
  final void Function(String path, DateTime recordedAt, Transcript transcript)?
      _onTranscriptSaved;

  final BleTransport _transport;
  final FileStore _fileStore;

  /// Pairing to one phone. Null in a build without it - every test that is
  /// not about pairing - which connects exactly as the app did before.
  final PairingService? _pairingService;
  final String _recordingsDirectory;
  final RecordingService _recorder;
  final LibraryService _library;

  /// Where app settings live: the support directory from `main.dart`, beside
  /// the recordings otherwise.
  final String _settingsDirectory;

  /// Supplied by tests that need shorter measurement windows than ten seconds.
  final DeviceTestService? _injectedTests;

  /// Supplied by tests that need the signal polled faster than once a second.
  final LinkMonitor? _injectedLinkMonitor;

  /// The mic check and its saved history.
  ///
  /// `late final` rather than an initializing formal because it needs
  /// [_fileStore] and [_recordingsDirectory], which are not available in an
  /// initializer list that also has to fall back to [_injectedTests].
  late final DeviceTestService _tests = _injectedTests ??
      DeviceTestService(
        transport: _transport,
        store: DeviceTestStore(
          fileStore: _fileStore,
          directory: _recordingsDirectory,
        ),
      );

  /// The live link watcher - the signal, and the frames the phone received.
  ///
  /// NOTHING RUNS UNLESS REQUIRED: it is started by [openDiagnostics] and
  /// stopped by [closeDiagnostics], because subscribing to `fe01` is what makes
  /// the recorder stream and nothing outside that screen renders these numbers.
  late final LinkMonitor _linkMonitor =
      _injectedLinkMonitor ?? LinkMonitor(transport: _transport);

  /// The mic check, for the diagnostics screen to render and drive.
  ///
  /// Subscribing HERE rather than in [initialise] on purpose: the screen renders
  /// a running check's elapsed time and live counters, and those arrive on the
  /// service's own stream. A subscription set up in `initialise` would be
  /// missing in every test that builds a screen without starting the app, and
  /// the readout would sit frozen while the check ran.
  DeviceTestService get deviceTests {
    _testSubscription ??= _tests.changes.listen((_) => notifyListeners());
    return _tests;
  }

  /// Offline speech-to-text. Null when the app was built without an engine;
  /// every transcription member then reports it as unavailable.
  ///
  /// NOTHING RUNS UNLESS THERE IS WORK. The model is loaded for a run of jobs
  /// and freed after it - see BACKGROUND TRANSCRIPTION - so holding this
  /// reference costs nothing between runs.
  final TranscriptionService? _transcription;

  /// The saved transcripts, beside the recordings.
  final TranscriptStore _transcripts;

  /// CPU threads for a job. 2 is as fast as 4 on the owner's phone (2 big + 6
  /// little cores) and should cost less battery.
  static const int transcriptionThreads = 2;

  /// The recording being transcribed now; null when nothing is running. There
  /// is only ever one - the service refuses a second.
  String? _transcribingPath;
  int _transcriptionDone = 0;
  int _transcriptionTotal = 0;

  /// Saved transcripts that have been looked for, by recording path. A path
  /// that is present with a null value has been checked and has none.
  final Map<String, Transcript?> _transcriptCache = <String, Transcript?>{};

  /// Why the last attempt at a recording did not produce a transcript, by
  /// path. Cleared when that recording is tried again.
  final Map<String, TranscriptStatus> _transcriptFailures =
      <String, TranscriptStatus>{};

  TranscriptionResult? _lastTranscription;

  bool get transcriptionAvailable => _transcription != null;

  bool get isTranscribing => _transcribingPath != null;

  /// The recording being transcribed, if any.
  String? get transcribingPath => _transcribingPath;

  /// Windows decoded so far, and of how many, for the job in progress. The
  /// total is 0 until the recording has been measured.
  int get transcriptionDone => _transcriptionDone;
  int get transcriptionTotal => _transcriptionTotal;

  /// How far the job on the note at [path] has got, 0..1, or null when that
  /// note is not the one running.
  ///
  /// ONE FIGURE FOR BOTH PASSES: separating the speakers and decoding the
  /// words report through the same progress callback (the separation pass is
  /// the first tenth or so of the total), so this is as true of a re-run
  /// started from the Speakers sheet as it is of a first transcription. 0
  /// until the recording has been measured, rather than null, because the job
  /// IS running - it just has nothing to say yet.
  double? transcriptionProgressFor(String path) {
    if (_transcribingPath != path) return null;
    if (_transcriptionTotal <= 0) return 0;
    return (_transcriptionDone / _transcriptionTotal).clamp(0.0, 1.0);
  }

  /// The last finished job's timings and memory, for Developer options.
  TranscriptionResult? get lastTranscription => _lastTranscription;

  /// The saved transcript of [recording], once [loadTranscript] has run.
  Transcript? transcriptFor(RecordingInfo recording) =>
      _transcriptCache[recording.path];

  /// What the note screen should show for [recording]'s transcript.
  TranscriptStatus transcriptStatusFor(RecordingInfo recording) {
    final path = recording.path;
    if (_transcribingPath == path) return TranscriptStatus.running;
    if (_queue.contains(path)) return TranscriptStatus.queued;
    final failure = _transcriptFailures[path];
    if (failure != null) return failure;
    if (!_transcriptCache.containsKey(path)) return TranscriptStatus.checking;
    final transcript = _transcriptCache[path];
    if (transcript == null) return TranscriptStatus.none;
    return transcript.hasSpeech
        ? TranscriptStatus.done
        : TranscriptStatus.noSpeech;
  }

  /// Reads [recording]'s saved transcript, if it has one. Cheap: one `stat`,
  /// and one small read when there is a file.
  Future<void> loadTranscript(RecordingInfo recording) async {
    final transcript = await _transcripts.load(recording.path);
    _transcriptCache[recording.path] = transcript;
    // The speaker count the user chose has to be known before this note is
    // transcribed again, which the background queue may do at any moment.
    _speakerSettings[recording.path] ??=
        await _speakerSettingsStore.load(recording.path);
    // A failure saved on an earlier launch is what the card should explain,
    // rather than offering a Transcribe button as though nothing had been
    // tried.
    if (transcript == null && !_transcriptFailures.containsKey(recording.path)) {
      final failure = await _transcripts.loadFailure(recording.path);
      if (failure != null) _transcriptFailures[recording.path] = failure;
    }
    notifyListeners();
  }

  /// What the recordings list should say about [recording]'s transcript.
  ///
  /// Unlike [transcriptStatusFor] it never answers "checking": the list knows
  /// from its own directory listing whether a transcript or a saved failure
  /// sits beside the file, so it needs no per-row read.
  TranscriptStatus listTranscriptStatusFor(RecordingInfo recording) {
    final status = transcriptStatusFor(recording);
    if (status != TranscriptStatus.checking) return status;
    if (recording.hasTranscript) return TranscriptStatus.done;
    if (recording.transcriptFailed) return TranscriptStatus.failed;
    return TranscriptStatus.none;
  }

  /// The user opened [recording]: if it is waiting in the background queue,
  /// it goes next. A job already running is not interrupted - its model is
  /// loaded, and throwing that away would cost more than the wait.
  void prioritiseTranscription(RecordingInfo recording) {
    _queue.prioritise(recording.path);
  }

  /// Transcribes [recording] and saves the transcript beside it.
  ///
  /// Does nothing while another transcription is running: one at a time.
  /// Outcomes land in [transcriptStatusFor] rather than being thrown, because
  /// this is driven straight from a button.
  Future<void> transcribe(RecordingInfo recording) async {
    final service = _transcription;
    if (service == null || _transcribingPath != null) return;
    final path = recording.path;
    // A note still being written would be transcribed with its end missing.
    if (path == writingNotePath) return;
    // Its audio was removed after 24 h; the transcript is all there is.
    if (!recording.hasAudio) return;
    _queue.remove(path);
    _transcribingPath = path;
    _transcriptionDone = 0;
    _transcriptionTotal = 0;
    _transcriptFailures.remove(path);
    notifyListeners();
    var succeeded = false;
    try {
      final result = await service.transcribe(
        path,
        numThreads: transcriptionThreads,
        language: _transcriptionLanguage,
        speakerCount: speakerCountFor(path),
        onProgress: (done, total) {
          _transcriptionDone = done;
          _transcriptionTotal = total;
          notifyListeners();
        },
      );
      _lastTranscription = result;
      // Logged whole, so a measurement taken on a phone can be read back over
      // adb without transcribing it off the screen.
      debugPrint('STT $result');
      // The merges the user already made are kept across a new transcript:
      // they are the user's answer about who is who, not the engine's.
      final transcript = _withMerges(
        path,
        Transcript.fromResult(result, createdAt: DateTime.now()),
      );
      _transcriptCache[path] = transcript;
      try {
        await _transcripts.save(path, transcript);
        succeeded = true;
        await _transcripts.clearFailure(path);
        // One hook, for the one feature that reads a finished note: speaking
        // to the assistant. This controller knows nothing about what happens
        // next - whether a note is an instruction, and whether anything is
        // sent, is entirely `AssistantController`'s business, and on a build
        // where `main.dart` passes nothing this line does nothing.
        _onTranscriptSaved?.call(path, recording.recordedAt, transcript);
        // Nothing said in any window: the note goes, once nothing uses it.
        if (!transcript.hasSpeech) await _markEmptyNote(path);
      } on Object catch (error) {
        // The words are still on screen for this session; they are simply
        // worked out again next time.
        debugPrint('STT could not save the transcript: $error');
      }
    } on TranscriptionException catch (error) {
      debugPrint('STT failed: $error');
      final status = switch (error.failure) {
        TranscriptionFailure.cancelled => null,
        TranscriptionFailure.modelMissing ||
        TranscriptionFailure.modelIncomplete =>
          TranscriptStatus.modelMissing,
        TranscriptionFailure.unreadableAudio ||
        TranscriptionFailure.unsupportedAudio =>
          TranscriptStatus.unsupported,
        TranscriptionFailure.busy ||
        TranscriptionFailure.recognizerFailed =>
          TranscriptStatus.failed,
      };
      if (status != null) _transcriptFailures[path] = status;
      // SAVED ONLY WHERE TRYING AGAIN WOULD FAIL AGAIN, so the background queue
      // does not spend a model load on the same file every launch. A missing
      // model is not about the file, and a cancel is not a failure at all.
      if (status == TranscriptStatus.unsupported ||
          status == TranscriptStatus.failed) {
        try {
          await _transcripts.saveFailure(path, status!);
        } on Object catch (error) {
          debugPrint('STT could not save the failure: $error');
        }
      }
    } finally {
      _transcribingPath = null;
      notifyListeners();
    }
    // A transcript just landed, which is what can make an old recording's
    // audio removable.
    if (succeeded) unawaited(_sweepAudio());
    unawaited(_sweepEmptyNotesIfPending());
    if (_pumpDone == null) unawaited(_pumpTranscriptions());
  }

  // Which language transcription listens for. Auto unless changed; nothing
  // on screen changes it yet (the picker waits for a design).
  late final TranscriptionSettingsStore _transcriptionSettings =
      TranscriptionSettingsStore(
    fileStore: _fileStore,
    directory: _settingsDirectory,
  );
  TranscriptionLanguage _transcriptionLanguage = TranscriptionLanguage.auto;

  /// The transcription language. Persisted; applies to the next job, and
  /// does not transcribe existing notes again.
  TranscriptionLanguage get transcriptionLanguage => _transcriptionLanguage;

  Future<void> setTranscriptionLanguage(TranscriptionLanguage language) async {
    if (language == _transcriptionLanguage) return;
    _transcriptionLanguage = language;
    try {
      await _transcriptionSettings.saveLanguage(language);
    } on Object catch (error) {
      // Applies for this run; it is only forgotten across a restart.
      debugPrint('Could not save the transcription language: $error');
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // BACKGROUND TRANSCRIPTION
  //
  // Recordings without a transcript are transcribed one at a time, newest
  // first, as soon as they are finished - on screen always, and OFF SCREEN
  // ONLY WHERE THE PROCESS IS KEPT ALIVE AND THE PHONE CAN AFFORD IT:
  //
  //   * `backgroundTranscription` (Android, from `main.dart`) AND
  //     always-listening on - its foreground service is what keeps the
  //     process, and this isolate, running with the screen off;
  //   * OR iOS has granted a `BGProcessingTask` window, which is the one way
  //     an iPhone lends an app minutes of CPU off screen. The app asks for one
  //     whenever it leaves the screen with notes still to transcribe - see
  //     `BackgroundTaskPlan` - and iOS picks its own moment, while the phone
  //     is idle and on a charger. It ends the moment the user picks the phone
  //     up. Nothing depends on the window arriving: the queue is still there
  //     on the next foreground either way, which is what the user is told;
  //   * and [BackgroundTranscriptionPolicy] says yes: on a charger, or at 30%
  //     battery or more with battery saver off - never when the phone is hot.
  //
  // It is asked before every job and every [_powerRecheckInterval] while one
  // runs off screen. A "no" puts the running job back at the front, frees the
  // model, and waits for a charger event, the next finished note or the app
  // being opened. iOS gives no background guarantee, so there going to the
  // background pauses as it always did.
  //
  // The model is loaded once for a run of jobs. On screen the recognizer frees
  // it 30 s after the last one; off screen it is freed as soon as the queue
  // drains or pauses, because a timer is not to be trusted while the CPU
  // sleeps.
  //
  // Nothing runs until [appForegrounded] is first called, unless background
  // transcription is enabled - which is what keeps tests that never call it
  // exactly as they were.
  // -------------------------------------------------------------------------

  final TranscriptionQueue _queue = TranscriptionQueue();
  bool _inForeground = false;

  /// The run of jobs now going, so a second caller joins it rather than
  /// starting another - and so an iOS window can wait for it to finish before
  /// telling the system the task is done.
  Future<void>? _pumpDone;

  bool _initialised = false;

  /// Null in builds and tests without a battery reader; background
  /// transcription is then never allowed (power unknown).
  final PhonePower? _power;

  /// Whether this platform keeps the process alive off screen while
  /// always-listening runs. True on Android only.
  final bool _backgroundTranscription;

  final Duration _powerRecheckInterval;

  /// The last answer to "may transcription run now?".
  TranscriptionPermit? _permit;

  Timer? _powerRecheck;
  StreamSubscription<void>? _powerChanges;

  /// True only while iOS has granted a `BGProcessingTask` window. For that
  /// window - and no longer - the process is kept alive off screen exactly as
  /// Android's foreground service keeps it, so the same policy applies.
  bool _backgroundWindow = false;

  /// Set when iOS says the window is about to end. Every loop below checks it
  /// and stops; an app that overruns its window is killed.
  bool _windowExpiring = false;

  /// Recordings waiting for the background queue, front first.
  List<String> get transcriptionQueue => _queue.pending;

  /// Why the queue is running or paused, as last decided; null before the
  /// first decision. For a future status line ("Waiting for charger").
  TranscriptionPermit? get transcriptionPermit => _permit;

  /// Whether the process is being kept alive off screen at this moment - so
  /// whether a charger could change anything.
  bool get _keepAlive =>
      _backgroundWindow || (_backgroundTranscription && _continuous.enabled);

  /// Whether queued work can be looked at with the app off screen. Android
  /// always (its service holds the process); iOS only inside a granted
  /// window.
  bool get _worksOffScreen => _backgroundTranscription || _backgroundWindow;

  /// The app is on screen: re-read the adapter, reach for the device if
  /// always-listening wants it, run the audio sweep and start the
  /// transcription queue.
  Future<void> appForegrounded() async {
    _inForeground = true;
    _stopPowerRecheck();
    _stopWaitingForPower();
    if (!_initialised) return;
    // Before anything else: a keep-alive the OS refused while the app was off
    // screen is asked for again here, with an activity on screen, which is the
    // one moment Android is most likely to say yes.
    _syncBackground();
    await refreshAvailability();
    _ensureContinuousLink();
    if (_batteryHistoryDue()) await refreshBatteryHistory();
    await _sweepAudio();
    await _sweepEmptyNotesIfPending();
    // A download that stopped when the app left the screen carries on from
    // where it stopped. Nothing starts that the user did not start.
    unawaited(_modelDownloads?.resumeAll());
    await _planTranscriptions();
  }

  /// The app left the screen. Always-listening carries on; transcription
  /// carries on only where [BackgroundTranscriptionPolicy] allows it.
  Future<void> appBackgrounded() async {
    if (!_inForeground) return;
    _inForeground = false;
    // Model downloads do not run off screen on either platform - see
    // `ModelDownloadService.pauseAll`.
    _modelDownloads?.pauseAll();
    final allowed = await _mayTranscribe();
    if (_inForeground) return;
    final running = _transcribingPath;
    if (allowed) {
      if (running != null) {
        _startPowerRecheck();
      } else if (_queue.isEmpty) {
        await _releaseIdleEngine();
      }
      await _syncBackgroundWork();
      return;
    }
    if (running != null) _queue.addFront(running);
    // Cancels the job and frees the model: nothing will use it off screen.
    await _transcription?.releaseEngine();
    _waitForPower();
    // iOS: ask for a window for what is left. Android has its service and
    // this is a no-op there.
    await _syncBackgroundWork();
  }

  /// Whether a job may start or continue now, recording the answer.
  Future<bool> _mayTranscribe() async {
    TranscriptionPermit permit;
    if (_inForeground) {
      permit = TranscriptionPermit.foreground;
    } else {
      PhonePowerState? power;
      if (_keepAlive) {
        try {
          power = await _power?.read();
        } on Object {
          power = null;
        }
      }
      permit = BackgroundTranscriptionPolicy.decide(
        foreground: _inForeground,
        keepAlive: _keepAlive,
        power: power,
      );
    }
    if (permit != _permit) {
      _permit = permit;
      debugPrint('STT queue: ${permit.name}');
      notifyListeners();
    }
    return permit.allowed;
  }

  Future<void> _planTranscriptions() async {
    final service = _transcription;
    if (service == null) return;
    // Off screen where nothing keeps the process: do not even look.
    if (!_inForeground && !_worksOffScreen) return;
    try {
      if (!(await service.modelStatus()).isReady) return;
    } on Object {
      return;
    }
    await refreshLibrary();
    _queue.replace(
      TranscriptionQueue.plan(
        recordings: _recordings,
        failed: <String>{
          for (final entry in _transcriptFailures.entries)
            if (entry.value == TranscriptStatus.unsupported ||
                entry.value == TranscriptStatus.failed)
              entry.key,
        },
        writing: writingNotePath,
        running: _transcribingPath,
      ),
    );
    notifyListeners();
    unawaited(_pumpTranscriptions());
  }

  /// Runs queued jobs one after another until the queue is empty, the policy
  /// says stop, or something else is already transcribing.
  ///
  /// A second caller while a run is going joins that run rather than starting
  /// another, and gets the same future - which is what lets an iOS window wait
  /// for the work to finish before telling the system the task is done.
  Future<void> _pumpTranscriptions() {
    final running = _pumpDone;
    if (running != null) return running;
    final service = _transcription;
    if (service == null) return Future<void>.value();
    final done = _pumpLoop().whenComplete(() => _pumpDone = null);
    _pumpDone = done;
    return done;
  }

  Future<void> _pumpLoop() async {
    // Taken when the first job starts off screen, released when the run ends.
    // Never while the app is on screen, and never while the queue is idle.
    var holdingCpu = false;
    try {
      while (_transcribingPath == null && !_queue.isEmpty) {
        // iOS is taking its window back. Stop cleanly rather than be killed
        // for overrunning it; the queue is untouched and waits for the next
        // window or the next time the app is opened.
        if (_windowExpiring) break;
        if (!await _mayTranscribe()) {
          _waitForPower();
          break;
        }
        if (_transcribingPath != null) break;
        final path = _queue.takeNext(skip: writingNotePath);
        if (path == null) break;
        RecordingInfo? recording;
        for (final info in _recordings) {
          if (info.path == path) recording = info;
        }
        if (recording == null ||
            !recording.hasAudio ||
            _transcriptCache[path] != null) {
          continue;
        }
        _stopWaitingForPower();
        if (!_inForeground) {
          _startPowerRecheck();
          if (!holdingCpu) {
            holdingCpu = true;
            await _background?.holdCpu();
          }
        }
        await transcribe(recording);
      }
    } finally {
      _stopPowerRecheck();
      if (holdingCpu) await _background?.releaseCpu();
    }
    if (!_inForeground && _transcribingPath == null) {
      await _releaseIdleEngine();
    }
  }

  /// Frees the model when no job holds it. Off screen only: on screen the
  /// recognizer's own idle timeout carries a queue from job to job.
  Future<void> _releaseIdleEngine() async {
    final service = _transcription;
    if (service == null || service.isBusy || _transcribingPath != null) return;
    await service.releaseEngine();
  }

  /// A recording has just been finished: it goes first, and the queue runs if
  /// it may.
  Future<void> _enqueueFinished(String path) async {
    final service = _transcription;
    if (service == null) return;
    if (!_inForeground && !_worksOffScreen) return;
    try {
      if (!(await service.modelStatus()).isReady) return;
    } on Object {
      return;
    }
    _queue.addFront(path);
    notifyListeners();
    unawaited(_pumpTranscriptions());
  }

  /// Re-reads the phone every [_powerRecheckInterval] while a job runs off
  /// screen, and pauses it when the policy stops allowing it.
  void _startPowerRecheck() {
    if (_powerRecheck != null) return;
    _powerRecheck = Timer.periodic(_powerRecheckInterval, (_) {
      unawaited(_recheckPower());
    });
  }

  void _stopPowerRecheck() {
    _powerRecheck?.cancel();
    _powerRecheck = null;
  }

  Future<void> _recheckPower() async {
    if (_inForeground || _transcribingPath == null) {
      _stopPowerRecheck();
      return;
    }
    if (await _mayTranscribe()) return;
    final running = _transcribingPath;
    if (_inForeground || running == null) return;
    _stopPowerRecheck();
    _queue.addFront(running);
    await _transcription?.releaseEngine();
    _waitForPower();
  }

  /// Listens for the charger while work waits off screen for power. Only
  /// then, and only where a charger could change the answer.
  void _waitForPower() {
    final power = _power;
    if (power == null ||
        _inForeground ||
        !_keepAlive ||
        _queue.isEmpty ||
        _powerChanges != null) {
      return;
    }
    _powerChanges = power.changes.listen(
      (_) => unawaited(_pumpTranscriptions()),
      onError: (Object _) {},
    );
  }

  void _stopWaitingForPower() {
    final changes = _powerChanges;
    _powerChanges = null;
    if (changes != null) unawaited(changes.cancel());
  }

  // -------------------------------------------------------------------------
  // iOS BACKGROUND WINDOWS
  //
  // An iPhone keeps this app's process alive off screen for Bluetooth, and
  // only for Bluetooth: it is woken for each characteristic notification, the
  // note is written to disk in that wake-up, and it goes straight back to
  // sleep. Apple's own guidance is that a wake-up is about ten seconds and
  // that nothing unrelated to the wake-up belongs in it, so minutes of speech
  // inference cannot ride on it.
  //
  // `BGProcessingTask` is the sanctioned way to ask for that time instead:
  // "Although processing tasks can run for minutes, the system can interrupt
  // the process"; "Processing tasks run only when the device is idle. The
  // system terminates any background processing tasks running when the user
  // starts using the device."
  //
  // So the app asks whenever it goes off screen with notes still to
  // transcribe, iOS picks its own moment, and the window is spent running the
  // same queue under the same policy Android's service runs it under. Nothing
  // anywhere depends on a window arriving - it may never come, and on a phone
  // with Background App Refresh off it never will. The queue is still there
  // the next time the app is opened, which is what the screen says.
  // -------------------------------------------------------------------------

  /// iOS granted a window. Runs the queue until it drains, the policy pauses
  /// it, or iOS asks for the window back; completes when there is no more to
  /// do, which is when native tells the system the task finished.
  Future<void> _runBackgroundWindow() async {
    // The user picked the phone up between the grant and this call. iOS ends
    // a processing task then anyway, and the foreground queue is about to run
    // the same jobs.
    if (_inForeground || _backgroundWindow) return;
    _backgroundWindow = true;
    _windowExpiring = false;
    try {
      await _planTranscriptions();
      await _pumpTranscriptions();
    } on Object catch (error) {
      debugPrint('Background window failed: $error');
    } finally {
      _backgroundWindow = false;
      _windowExpiring = false;
      _stopPowerRecheck();
      _stopWaitingForPower();
      // The window is over: nothing off screen will use the model, and a
      // timer is not to be trusted while the CPU sleeps.
      await _transcription?.releaseEngine();
    }
    // Work left over asks for another window; a drained queue withdraws the
    // request so the phone is not woken for nothing.
    await _syncBackgroundWork();
  }

  /// Android's foreground service is not running after all. Forgetting the
  /// text it was started with is what makes the next change ask again - and
  /// nothing asks from here, because an OS that just refused would refuse a
  /// retry in the same breath and the two would chase each other.
  void _keepAliveStopped() {
    _backgroundText = null;
  }

  /// iOS is about to take the window back. The running job stops at its next
  /// check and goes back to the front of the queue.
  void _expireBackgroundWindow() {
    if (!_backgroundWindow) return;
    _windowExpiring = true;
    unawaited(cancelTranscription());
  }

  /// Asks iOS for a window when there is work for one, and withdraws the
  /// request when there is not. A no-op where the process is kept alive
  /// anyway - Android - and where there is no platform to ask.
  Future<void> _syncBackgroundWork() async {
    final background = _background;
    if (background == null || _backgroundTranscription) return;
    final service = _transcription;
    var modelReady = false;
    if (service != null) {
      try {
        modelReady = (await service.modelStatus()).isReady;
      } on Object {
        modelReady = false;
      }
    }
    final request = BackgroundTaskPlan.plan(
      pending: _queue.pending.length + (_transcribingPath == null ? 0 : 1),
      modelReady: modelReady,
    );
    try {
      if (request == null) {
        await background.cancelWork();
      } else {
        await background.scheduleWork(request);
      }
    } on Object catch (error) {
      // A refused request changes nothing the user can see: the queue still
      // runs the next time the app is opened.
      debugPrint('Could not ask for a background window: $error');
    }
  }

  /// Stops the running transcription. Completes once the model is released.
  Future<void> cancelTranscription() async {
    await _transcription?.cancel();
  }

  // -------------------------------------------------------------------------
  // SPEECH MODELS: installing them on a phone nobody can reach with `adb`
  //
  // The engine is useless without its model files. On Android they can be
  // pushed over a cable during development; on an iPhone there is no cable to
  // push them down, so the downloader below is the only way transcription and
  // speaker detection exist there at all. Everything a screen needs is here,
  // per FEATURE - see `ModelsController`.
  // -------------------------------------------------------------------------

  /// Null in a build without downloads - every test that is not about them -
  /// which behaves exactly as the app did when models arrived by cable.
  final ModelDownloadService? _modelDownloads;

  final ModelDownloadSettingsStore _modelDownloadSettings;

  StreamSubscription<ModelInstallStatus>? _modelDownloadSubscription;

  bool _downloadOnMobileData = false;

  /// Every model set, in the order to list them. Empty in a build with no
  /// downloader.
  List<ModelInstallStatus> get modelStatuses =>
      _modelDownloads?.statuses ?? const <ModelInstallStatus>[];

  /// Where one feature's model stands. With no downloader wired in this
  /// reports the catalogue entry as not installed, which is what a phone with
  /// no model files is.
  ModelInstallStatus modelStatusFor(ModelFeature feature) =>
      _modelDownloads?.statusFor(feature) ??
      ModelInstallStatus.unknown(ModelCatalogue.forFeature(feature));

  /// Bytes the installed models take up on this phone.
  int get installedModelBytes => _modelDownloads?.installedBytes ?? 0;

  /// Whether models may download on mobile data. False until the user says
  /// otherwise; remembered across restarts.
  bool get downloadOnMobileData => _downloadOnMobileData;

  Future<void> setDownloadOnMobileData(bool allowed) async {
    if (_downloadOnMobileData == allowed) return;
    _downloadOnMobileData = allowed;
    notifyListeners();
    try {
      await _modelDownloadSettings.saveAllowMobileData(allowed);
    } on Object {
      // The choice still holds for this run; it is one flag, not a note.
    }
  }

  /// Installs one feature's model, resuming whatever already arrived.
  Future<void> downloadModel(ModelFeature feature) async {
    final downloads = _modelDownloads;
    if (downloads == null) return;
    await downloads.download(
      downloads.releaseFor(feature),
      allowMobileData: _downloadOnMobileData,
    );
  }

  Future<void> cancelModelDownload(ModelFeature feature) async {
    final downloads = _modelDownloads;
    if (downloads == null) return;
    await downloads.cancel(downloads.releaseFor(feature));
  }

  /// Removes the set and frees its bytes. A feature whose model is gone goes
  /// back to reporting "not installed", exactly as it did before it was ever
  /// downloaded.
  Future<void> deleteModel(ModelFeature feature) async {
    final downloads = _modelDownloads;
    if (downloads == null) return;
    await downloads.remove(downloads.releaseFor(feature));
    notifyListeners();
  }

  Future<void> refreshModels() async {
    await _modelDownloads?.refresh();
    notifyListeners();
  }

  /// Watches the downloader so a screen redraws, and so WORK THAT WAS BLOCKED
  /// RESUMES: notes pile up unqueued while the speech model is missing, and
  /// the moment it lands the queue is planned again and starts running.
  void _watchModelDownloads() {
    final downloads = _modelDownloads;
    if (downloads == null || _modelDownloadSubscription != null) return;
    _modelDownloadSubscription = downloads.changes.listen(
      (status) {
        notifyListeners();
        if (status.isInstalled) {
          debugPrint('STT model installed: ${status.id}');
          unawaited(_planTranscriptions());
        }
      },
      onError: (Object _) {},
    );
  }

  // -------------------------------------------------------------------------
  // NOTES: transcripts for the list, and speaker names
  //
  // The notes list shows a line of each transcript and searches all of them,
  // so it asks for every saved transcript once; the rest of the time they
  // are read one at a time as a note is opened. Speaker names are the user's,
  // kept beside the recording so transcribing again does not lose them.
  // -------------------------------------------------------------------------

  late final SpeakerNamesStore _speakerNamesStore =
      SpeakerNamesStore(fileStore: _fileStore);
  final Map<String, SpeakerNames> _speakerNames = <String, SpeakerNames>{};
  late final SpeakerSettingsStore _speakerSettingsStore =
      SpeakerSettingsStore(fileStore: _fileStore);
  final Map<String, SpeakerSettings> _speakerSettings =
      <String, SpeakerSettings>{};
  bool _loadingTranscripts = false;

  /// Reads the saved transcript of every recording in [recordings] that has
  /// one and has not been read yet. Notifies once, and only when something
  /// was read - so a listener may call this on every change.
  Future<void> loadTranscripts(Iterable<RecordingInfo> recordings) async {
    if (_loadingTranscripts) return;
    final missing = <RecordingInfo>[
      for (final recording in recordings)
        if (recording.hasTranscript &&
            !_transcriptCache.containsKey(recording.path))
          recording,
    ];
    if (missing.isEmpty) return;
    _loadingTranscripts = true;
    try {
      for (final recording in missing) {
        _transcriptCache[recording.path] =
            await _transcripts.load(recording.path);
      }
    } finally {
      _loadingTranscripts = false;
    }
    notifyListeners();
  }

  /// The names given to the speakers of the note at [path]; empty until
  /// [loadSpeakerNames] has run or when none were given.
  SpeakerNames speakerNamesFor(String path) =>
      _speakerNames[path] ?? SpeakerNames.empty;

  /// Reads the note's speaker names AND its speaker settings - the count the
  /// user chose and the merges they made - so one call from the note screen is
  /// enough for the whole speakers sheet.
  Future<void> loadSpeakerNames(String path) async {
    _speakerNames[path] = await _speakerNamesStore.load(path);
    _speakerSettings[path] = await _speakerSettingsStore.load(path);
    notifyListeners();
  }

  /// Renames speakers of the note at [path] - label to name, blank to clear -
  /// and saves the result. Shown at once; a failed save is said, not thrown.
  Future<void> renameSpeakers(String path, Map<String, String> names) async {
    final next = speakerNamesFor(path).withChanges(names);
    _speakerNames[path] = next;
    notifyListeners();
    try {
      await _speakerNamesStore.save(path, next);
    } on Object catch (error) {
      _errorMessage = 'Could not save the speaker names: $error';
      notifyListeners();
    }
  }

  // -------------------------------------------------------------------------
  // SPEAKERS: how many, and which of them are the same person
  //
  // Separation is the engine's guess. These four are the user's corrections,
  // and they outlive a transcript being made again: both are kept in
  // `voicenote-X.speaker-settings.json` beside the recording, and
  // [transcribe] reads them back.
  // -------------------------------------------------------------------------

  /// The speaker count the user chose for the note at [path], or null for Auto
  /// (the clustering decides). Known once [loadSpeakerNames] or
  /// [loadTranscript] has run for that note.
  int? speakerCountFor(String path) => _speakerSettings[path]?.speakerCount;

  /// The merges the user made in the note at [path]: a label, and the label it
  /// now reads as.
  Map<String, String> speakerMergesFor(String path) =>
      _speakerSettings[path]?.merges ?? const <String, String>{};

  /// The speaker labels of the note at [path], in the order they first speak.
  ///
  /// Empty when the note has no speakers - nobody has transcribed it yet, the
  /// separation models are not installed, or only one person spoke, which is
  /// deliberately not labelled at all.
  List<String> speakerLabels(String path) {
    final transcript = _transcriptCache[path];
    if (transcript == null) return const <String>[];
    return TranscriptLayout.speakers(transcript);
  }

  /// [speakerLabels], under the name the rest of this controller uses for
  /// "the value for one note".
  List<String> speakerLabelsFor(String path) => speakerLabels(path);

  /// Says how many people are in the note at [path] - null is Auto, 2, 3 or 4,
  /// where 4 means "four or more" - and works the note out again with it.
  ///
  /// RE-TRANSCRIBES. The turn boundaries move when the count changes, so the
  /// windows move, so the words have to be decoded again: there is nothing
  /// safe to reuse. It costs what transcribing the note cost the first time,
  /// and it runs through [transcribe], so it is refused while another note is
  /// being transcribed and it saves the new transcript the same way.
  ///
  /// The choice is saved either way. A note whose audio has been swept (24 h)
  /// cannot be worked out again: the choice is remembered and nothing else
  /// happens.
  Future<void> setSpeakerCount(String path, int? count) async {
    final current = _speakerSettings[path] ??
        await _speakerSettingsStore.load(path);
    if (current.speakerCount == count) return;
    final next = current.withCount(count);
    _speakerSettings[path] = next;
    notifyListeners();
    try {
      await _speakerSettingsStore.save(path, next);
    } on Object catch (error) {
      _errorMessage = 'Could not save the speaker count: $error';
      notifyListeners();
    }
    final recording = _recordingAt(path);
    if (recording == null || !recording.hasAudio) return;
    await transcribe(recording);
  }

  /// Says that [from] and [into] are the same person in the note at [path].
  ///
  /// Applied to the saved transcript at once - no audio is touched - and
  /// remembered, so a transcript made again (a different speaker count, a
  /// re-run) comes back merged the same way. Merging into a label that was
  /// itself merged away follows the chain.
  ///
  /// A merge that leaves ONE speaker leaves the note with no labels at all,
  /// the same as a note where the engine only ever heard one person.
  Future<void> mergeSpeakers(String path, String from, String into) async {
    if (from == into) return;
    final current = _speakerSettings[path] ??
        await _speakerSettingsStore.load(path);
    final next = current.withMerge(from, into);
    if (next == current) return;
    _speakerSettings[path] = next;
    final transcript = _transcriptCache[path] ?? await _transcripts.load(path);
    if (transcript != null) {
      final merged = _relabel(transcript, next.resolve);
      _transcriptCache[path] = merged;
      try {
        await _transcripts.save(path, merged);
      } on Object catch (error) {
        // Shown for this session; worked out again next time.
        debugPrint('Could not save the merged transcript: $error');
      }
    }
    notifyListeners();
    try {
      await _speakerSettingsStore.save(path, next);
    } on Object catch (error) {
      _errorMessage = 'Could not save the speaker merge: $error';
      notifyListeners();
    }
  }

  RecordingInfo? _recordingAt(String path) {
    for (final recording in recordings) {
      if (recording.path == path) return recording;
    }
    return null;
  }

  /// [transcript] with the user's merges applied, or unchanged when there are
  /// none.
  Transcript _withMerges(String path, Transcript transcript) {
    final settings = _speakerSettings[path];
    if (settings == null || settings.merges.isEmpty) return transcript;
    return _relabel(transcript, settings.resolve);
  }

  /// [transcript] with every speaker label put through [resolve]; labels are
  /// dropped altogether when that leaves one speaker.
  static Transcript _relabel(
    Transcript transcript,
    String Function(String label) resolve,
  ) {
    final labels = <String>{};
    for (final segment in transcript.segments) {
      final speaker = segment.speaker;
      if (speaker != null && segment.text.trim().isNotEmpty) {
        labels.add(resolve(speaker));
      }
    }
    final plain = labels.length < 2;
    return Transcript(
      languageCode: transcript.languageCode,
      modelId: transcript.modelId,
      createdAt: transcript.createdAt,
      audioDuration: transcript.audioDuration,
      englishModelMissing: transcript.englishModelMissing,
      segments: <TranscriptSegment>[
        for (final segment in transcript.segments)
          TranscriptSegment(
            start: segment.start,
            end: segment.end,
            text: segment.text,
            speaker: plain || segment.speaker == null
                ? null
                : resolve(segment.speaker!),
            languageCode: segment.languageCode,
            modelId: segment.modelId,
          ),
      ],
    );
  }

  /// Null when the app was built without a playback driver; every playback
  /// method is then a no-op rather than a crash.
  final AudioPlayer? _player;

  /// Null when the app was built without a way into the OS settings pages;
  /// [openBluetoothSettings] and [openAppSettings] then answer false rather
  /// than pretending, and the screen says so.
  final PlatformSettings? _settings;

  AudioCodec _preferredCodec;

  /// Codec requested from the device when a recording starts.
  AudioCodec get preferredCodec => _preferredCodec;

  /// Changes the codec the next capture will ask the device for.
  ///
  /// Settable so the debug-only developer screen can drive it; it takes effect
  /// on the next [startRecording], because the device is told which codec to
  /// use as a capture begins.
  set preferredCodec(AudioCodec codec) {
    if (codec == _preferredCodec) return;
    _preferredCodec = codec;
    notifyListeners();
  }

  /// The device's auto-sleep flag, or null when it is unknown: nothing is
  /// connected, or the read failed.
  ///
  /// Null is a third state on purpose. The device persists this flag in
  /// flash, so a default of "off" would be a guess about a setting that can
  /// put the recorder to sleep - and a wrong guess is worse than no answer.
  AutoSleepSetting? _autoSleep;

  /// The device's battery reading, or null when it is unknown: nothing is
  /// connected, or the read failed.
  ///
  /// Null is the same kind of third state [_autoSleep] is, and for the same
  /// reason: there is no honest default for a measurement only the device can
  /// take. Note the SECOND unknown nested inside it - a [BatteryStatus] whose
  /// `percent` is null is a device that has the characteristic but no reading
  /// (`0xFF` on the wire). Neither may ever be rendered as 0%.
  BatteryStatus? _battery;

  /// The device's die temperature, or null when it is unknown: nothing is
  /// connected, or the read failed.
  ///
  /// The same third state [_autoSleep] and [_battery] have, for the same
  /// reason. And the same SECOND unknown nested inside it: a [DieTemperature]
  /// whose `deciCelsius` is null is a device that has the characteristic but no
  /// reading (`0x8000` on the wire). Neither may ever be rendered as 0 \u00B0C,
  /// which would read as a freezing room.
  DieTemperature? _temperature;

  /// The bucketed view of [_battery], and the ONLY place the hysteresis state
  /// lives.
  ///
  /// It is held here rather than in the widget on purpose. The dead-band in
  /// [BatteryBars.forPercent] is a function of the PREVIOUS answer, so
  /// whichever object keeps that answer owns the display. A `StatefulWidget`
  /// would lose it to any rebuild that replaced the element - a route change,
  /// a reparent, a hot reload - and the bars would snap to whatever the raw
  /// reading says the moment the user navigated, which is the flicker the
  /// dead-band exists to prevent.
  BatteryBars _batteryBars = BatteryBars.unknown;

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<BatteryStatus>? _batterySubscription;
  StreamSubscription<DieTemperature>? _temperatureSubscription;
  StreamSubscription<void>? _testSubscription;
  StreamSubscription<void>? _linkSubscription;
  StreamSubscription<BleConnectionStatus>? _connectionSubscription;
  StreamSubscription<BleAvailability>? _availabilitySubscription;
  StreamSubscription<CaptureStats>? _statsSubscription;
  StreamSubscription<LevelReading>? _levelSubscription;
  StreamSubscription<List<RecordingInfo>>? _librarySubscription;
  StreamSubscription<PlaybackState>? _playbackSubscription;

  AppPhase _phase = AppPhase.idle;
  BleAvailability _availability = BleAvailability.unknown;
  final List<DiscoveredDevice> _devices = <DiscoveredDevice>[];
  DiscoveredDevice? _connectedDevice;
  CaptureStats _stats = const CaptureStats();
  RecordingMetadata? _lastRecording;
  String? _errorMessage;
  LevelReading? _level;
  List<RecordingInfo> _recordings = const <RecordingInfo>[];
  PlaybackState _playback = PlaybackState.idle;
  double _playbackSpeed = 1.0;
  RecordingInfo? _nowPlaying;
  String? _playbackError;
  ScanOutcome _scanOutcome = ScanOutcome.pending;
  LinkOutcome _linkOutcome = LinkOutcome.none;
  bool _permissionDenied = false;
  DiscoveredDevice? _lastDevice;

  AppPhase get phase => _phase;
  BleAvailability get availability => _availability;

  /// What became of the last scan window - see [ScanOutcome]. This is how
  /// "finished, nothing there" is told apart from "still looking".
  ScanOutcome get scanOutcome => _scanOutcome;

  /// Why there is no link, when the reason is worth telling the user - see
  /// [LinkOutcome]. A failed handshake and a dropped link are separate values
  /// because they are separate situations.
  LinkOutcome get linkOutcome => _linkOutcome;

  /// True when the OS refused the permissions a scan needs.
  ///
  /// Separate from [availability] on purpose: the adapter can be powered on
  /// and perfectly healthy while this app is not allowed to use it, which is
  /// exactly what a denied Android runtime permission looks like.
  bool get permissionDenied => _permissionDenied;

  /// The recorder the app last connected to, or last tried to. This is what
  /// "Try again" and "Reconnect" act on.
  DiscoveredDevice? get lastDevice => _lastDevice;
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices);
  DiscoveredDevice? get connectedDevice => _connectedDevice;
  CaptureStats get stats => _stats;

  /// Loudness of the block being recorded right now, `null` when nothing is
  /// being recorded or no audio has arrived yet.
  LevelReading? get level => _level;

  /// Peak of the current block in whole dBFS, for the recording screen's
  /// readout. `null` means there is nothing to show.
  int? get peakDbfs => _level?.peakDbfs.round();

  /// Saved recordings, newest first.
  List<RecordingInfo> get recordings => _recordings;

  /// Whether a playback driver was supplied at all.
  bool get canPlay => _player != null;

  /// Position, duration and playing/paused of the loaded recording.
  PlaybackState get playbackState => _playback;

  /// Playback rate, `1.0` being normal speed.
  ///
  /// Held HERE and not in the note screen, because a rate that lives in
  /// view state is lost the moment the screen is popped -- and a listener who
  /// chose 1.5x means it for the next recording too. The screen renders this
  /// rather than remembering its own.
  double get playbackSpeed => _playbackSpeed;

  /// The recording [playbackState] describes, when it was opened through
  /// [playRecording].
  RecordingInfo? get nowPlaying => _nowPlaying;

  /// Last playback failure, cleared when playback is next started.
  String? get playbackError => _playbackError;

  bool get isPlaying => _playback.isPlaying;

  /// Stream info the device reported for the capture in progress, or the last
  /// one. Null before the first recording starts.
  StreamInfo? get streamInfo => _recorder.streamInfo;
  RecordingMetadata? get lastRecording => _lastRecording;
  String? get errorMessage => _errorMessage;

  /// Whether the connected device actually reported its auto-sleep setting.
  /// False means the control has nothing truthful to show and must be
  /// presented as unavailable.
  bool get autoSleepAvailable => _autoSleep != null;

  /// The device's auto-sleep flag as last read from, or written to, the
  /// recorder. Meaningless unless [autoSleepAvailable] is true.
  bool get autoSleepEnabled => _autoSleep?.enabled ?? false;

  /// The duration in force, or null while nothing has been read.
  AutoSleepDuration? get autoSleepDuration => _autoSleep?.duration;

  /// The last duration auto-sleep was actually SET to on this link, so that
  /// the developer screen's ON button restores the user's own choice rather
  /// than the shortest option. `fe04` reports code 0 while off, so the
  /// recorder's stored duration is not readable back; this is the app's own
  /// memory of it and is dropped with the link.
  AutoSleepDuration? _chosenSleepDuration;

  /// Whether the connected device reported a battery status at all.
  ///
  /// False means the control has nothing truthful to show and must be
  /// presented as unavailable - not as an empty battery.
  bool get batteryAvailable => _battery != null;

  /// Charge in percent, or null when there is no reading to show.
  ///
  /// Null covers both unknowns: no `fe05` on this firmware, and `fe05`
  /// reporting `0xFF`. A caller that renders null as "0%" is a bug - the
  /// whole point of the nullability is that 0% is a real, different fact.
  int? get batteryPercent => _battery?.percent;

  /// Whether the recorder is charging. False when unknown, because "not
  /// charging" is what the absence of a charge signal looks like - and unlike
  /// the percentage it is not a number put in front of the user.
  bool get batteryCharging => _battery?.charging ?? false;

  /// The reading itself, for callers that want both halves at once.
  BatteryStatus? get batteryStatus => _battery;

  /// How many bars to draw, with full and critical called out.
  ///
  /// This is what the main UI renders; [batteryPercent] stays available for
  /// the developer screen and the diagnostics report, where a precise figure
  /// is worth more than an honest one. Recomputed as readings arrive, each
  /// time from the previous answer, so the bars do not flicker on a reading
  /// sitting astride a boundary.
  BatteryBars get batteryBars => _batteryBars;

  /// Whether the connected device reported a die temperature at all.
  ///
  /// False means the readout has nothing truthful to show and must be
  /// presented as unavailable - not as 0 °C. Firmware without `fe07`
  /// looks exactly like this.
  bool get temperatureAvailable => _temperature != null;

  /// The nRF52840's DIE temperature in °C, or null when there is no
  /// reading.
  ///
  /// Null covers both unknowns: no `fe07` on this firmware, and `fe07`
  /// reporting `0x8000`.
  ///
  /// A DIE temperature. The sensor shares a package with the CPU and the radio,
  /// so it sits well above the room - and further above it again inside a
  /// plastic case with a cell underneath, which is exactly why it is worth
  /// measuring before and after. Anything that labels this as ambient is wrong.
  double? get dieTemperatureCelsius => _temperature?.celsius;

  /// The reading itself, for callers that want the raw decidegrees.
  DieTemperature? get dieTemperature => _temperature;

  /// Runs in the saved file this build does not read. They are kept in the
  /// file untouched.
  ///
  /// Surfaced so a screen showing twelve runs out of a file of fifteen can
  /// account for the other three rather than looking as though it lost them.
  int get unreadDeviceTestRunCount => _tests.unreadRunCount;

  /// Why the mic check cannot run right now, or null when it can.
  ///
  /// The three-state discipline the auto-sleep and battery readouts follow: a
  /// check with nothing truthful behind it is offered as unavailable WITH A
  /// REASON, never as a control that produces a default result.
  DeviceTestBlocker? get testBlocker {
    // A BATCH COUNTS AS RUNNING even between its samples, when nothing is
    // streaming: the operator is getting ready to speak again, and starting the
    // other check then would take the frame subscription out from under the
    // batch and abandon it half-collected.
    if (_tests.isRunning || _tests.isBatchActive) {
      return DeviceTestBlocker.testRunning;
    }
    if (!isConnected) return DeviceTestBlocker.notConnected;
    // Always-listening owns the frame subscription for as long as it runs.
    if (_session != null) return DeviceTestBlocker.recording;
    // `subscribeFrames` takes one subscriber, so a capture in progress owns it.
    if (isRecording || _recorder.isRecording) {
      return DeviceTestBlocker.recording;
    }
    return null;
  }

  bool get isScanning => _phase == AppPhase.scanning;
  bool get isConnected =>
      _connectedDevice != null && _phase != AppPhase.connecting;
  bool get isRecording => _phase == AppPhase.recording;

  /// Reads the adapter state and starts following it.
  Future<void> initialise() async {
    _continuous = await _settingsStore.load();
    await _pairingService?.load();
    _autoDeleteAudio = await _retentionSettings.loadAutoDeleteAudio();
    _transcriptionLanguage = await _transcriptionSettings.loadLanguage();
    // BEFORE the library is read: a note or a capture the app was killed in
    // the middle of must be listed, played and transcribed at its real length.
    // Nothing is writing yet, so no header here can be one still in use.
    final repaired =
        await WavRepair.repairDirectory(_fileStore, _recordingsDirectory);
    if (repaired.isNotEmpty) debugPrint('Repaired WAV headers: $repaired');
    _statsSubscription = _recorder.stats.listen((stats) {
      _stats = stats;
      notifyListeners();
    });
    _levelSubscription = _recorder.levels.listen((reading) {
      _level = reading;
      notifyListeners();
    });
    _librarySubscription = _library.recordings.listen((recordings) {
      _recordings = recordings;
      notifyListeners();
    });
    _playbackSubscription = _player?.state.listen(
      (state) {
        _playback = state;
        notifyListeners();
      },
      onError: (Object error) {
        _playbackError = '$error';
        notifyListeners();
      },
    );
    // Read once at startup, so the developer screen has yesterday's numbers to
    // compare against the moment it is opened rather than after a first run.
    await deviceTests.load();
    await refreshLibrary();
    try {
      _availability = await _transport.currentAvailability();
    } on BleTransportException catch (e) {
      _fail(e.message);
      return;
    }
    _availabilitySubscription =
        _transport.availability.listen(_onAvailabilityChanged);
    _downloadOnMobileData = await _modelDownloadSettings.loadAllowMobileData();
    _watchModelDownloads();
    await _modelDownloads?.refresh();
    // Registered once, at startup, because iOS may hand a window to a process
    // it woke for Bluetooth at any moment after this.
    _background?.listen(
      onGranted: _runBackgroundWindow,
      onExpiring: _expireBackgroundWindow,
      onKeepAliveStopped: _keepAliveStopped,
    );
    _initialised = true;
    _syncBackground();
    _ensureContinuousLink();
    notifyListeners();
    await _sweepAudio();
    await _sweepEmptyNotes();
    // Off screen too where the platform keeps the process alive - a process
    // Android restarted headless for always-listening picks its queue back
    // up, as the policy allows.
    if (_inForeground || _worksOffScreen) await _planTranscriptions();
  }

  /// The adapter changed state. THE STALE-CONNECTED BUG LIVES HERE.
  ///
  /// Turning Bluetooth off does not reliably produce a disconnect: on Android the
  /// GATT callback that reports a dropped link is delivered BY the stack that has
  /// just been shut down, and there is no radio left to notice the peripheral is
  /// gone. So an app that waits for [BleConnectionStatus.disconnected] waits for
  /// an event that can never arrive, and goes on showing a device name, a battery
  /// percentage and the word "Connected" that nothing is refreshing.
  ///
  /// ANYTHING BUT [BleAvailability.poweredOn] THEREFORE TEARS THE LINK DOWN, not
  /// [BleAvailability.poweredOff] alone. `unauthorized` is the same fact arriving
  /// through a revoked permission, and `unknown` is what the stack reports while
  /// it is resetting or mid-way through turning off - on Android
  /// `STATE_TURNING_OFF` arrives before `STATE_OFF`, which means tearing down on
  /// "not powered on" acts one event EARLIER than watching for "powered off"
  /// would.
  ///
  /// The reverse - Bluetooth coming back - does NOT reconnect by itself. The
  /// link was dropped, nothing is holding it, and claiming otherwise is the bug
  /// this method exists to prevent. The screen returns to the scan control, which
  /// is something the user can act on.
  ///
  /// THE ONE EXCEPTION is always-listening, where the user asked for the link
  /// to be kept: the radio coming back starts a fresh reconnect, and the home
  /// screen says "Device not connected" until it succeeds.
  void _onAvailabilityChanged(BleAvailability state) {
    final previous = _availability;
    _availability = state;
    if (state != previous && state != BleAvailability.poweredOn) {
      unawaited(_adapterLost());
    }
    if (state != previous && state == BleAvailability.poweredOn) {
      _reconnectAttempt = 0;
      _ensureContinuousLink();
    }
    notifyListeners();
  }

  /// Re-reads the adapter state and acts on it, for callers that cannot assume
  /// they were listening.
  ///
  /// A BACKSTOP AND NOT THE FIX. The availability stream is what carries this
  /// (see [_onAvailabilityChanged]); this exists because a screen becoming
  /// visible is the one moment where a missed event is both plausible and cheap
  /// to correct - the user may have gone to the system Bluetooth panel, switched
  /// the radio off there and come back. One platform read, on resume, is a
  /// smaller price than a screen that lies.
  ///
  /// A failure is swallowed: the last known state is still the best answer, and
  /// a resume must not be able to put the app into an error phase.
  Future<void> refreshAvailability() async {
    BleAvailability state;
    try {
      state = await _transport.currentAvailability();
    } on BleTransportException {
      return;
    }
    _onAvailabilityChanged(state);
  }

  /// The radio went away underneath us: drop everything that described it.
  ///
  /// The scan and the device list go too. A list of peripherals found by a radio
  /// that is now off is not a list of peripherals in range, and leaving it there
  /// means the user sees stale cards the moment Bluetooth comes back.
  Future<void> _adapterLost() async {
    // Cancelling the subscription is what ends the scan: the transport stops the
    // radio and cancels the window timer from its own `onCancel`. It is wrapped
    // because THIS is the case where telling the radio to stop scanning fails -
    // it is already off - and a throw here must not stop the teardown below,
    // which is the part the user can see.
    try {
      await _scanSubscription?.cancel();
    } on BleTransportException {
      // The scan has stopped either way: there is no radio running it.
    }
    _scanSubscription = null;
    _devices.clear();
    // Neither "found some" nor "found none" is true of a window the radio never
    // finished, so the outcome goes back to saying nothing.
    _scanOutcome = ScanOutcome.pending;
    // A denied permission is NOT cleared: it is a separate fact that outlives
    // the toggle, and the screen picks it over this one on purpose.
    _errorMessage = null;
    await _releaseLink(_LinkEnding.adapterLost);
    if (_phase != AppPhase.idle) _setPhase(AppPhase.idle);
    notifyListeners();
  }

  Future<void> startScan() async {
    if (_phase == AppPhase.scanning) return;
    _errorMessage = null;
    _permissionDenied = false;
    // A new scan supersedes whatever the last link did; the user is starting
    // over, and the failure screen must not outlive the attempt it described.
    _linkOutcome = LinkOutcome.none;
    _scanOutcome = ScanOutcome.pending;
    _devices.clear();

    try {
      if (!await _transport.ensurePermissions()) {
        _permissionDenied = true;
        _fail('Bluetooth permission was denied.');
        return;
      }
    } on BleTransportException catch (e) {
      _fail(e.message);
      return;
    }

    _setPhase(AppPhase.scanning);
    _scanSubscription = _transport.scan().listen(
      (device) {
        // A later result for the same recorder can add its scan response - the
        // pairing status - so it replaces the card rather than being dropped.
        final index = _devices.indexOf(device);
        if (index < 0) {
          _devices.add(device);
          notifyListeners();
        } else {
          final merged = _devices[index].mergedWith(device);
          if (merged.differsFrom(_devices[index])) {
            _devices[index] = merged;
            notifyListeners();
          }
          device = merged;
        }
        _connectIfPairingWindowOpen(device);
      },
      // The stream closing IS the end of the scan window - the transport owns
      // the clock, see `BleTransport.scanWindow`. The controller therefore
      // holds no timer of its own, and there is nothing here to leave pending.
      onDone: () => unawaited(_closeScanWindow()),
      onError: (Object e) => _fail('$e'),
    );
  }

  /// The scan window ended by itself; records what it found.
  ///
  /// Only a window that ran to its end may conclude "nothing answered". A scan
  /// the user cut short says nothing either way, so [stopScan] leaves the
  /// outcome [ScanOutcome.pending].
  Future<void> _closeScanWindow() async {
    if (_phase != AppPhase.scanning) return;
    if (_lookingForPairingWindow) {
      // "I've done that", and no recorder in range showed its window open.
      _lookingForPairingWindow = false;
      _pairingWindowMissed = true;
    }
    final foundNothing = _devices.isEmpty;
    await stopScan();
    _scanOutcome =
        foundNothing ? ScanOutcome.nothingFound : ScanOutcome.devicesFound;
    notifyListeners();
  }

  Future<void> stopScan() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await _transport.stopScan();
    } on BleTransportException catch (e) {
      _fail(e.message);
      return;
    }
    if (_phase == AppPhase.scanning) {
      _setPhase(_connectedDevice == null ? AppPhase.idle : AppPhase.connected);
    }
  }

  Future<void> connect(DiscoveredDevice device) async {
    // Android knows its own bonds, so a recorder paired to another phone needs
    // no radio time to say so: straight to the charger instructions. iOS
    // cannot know (a reinstalled app on the owner's phone looks the same), so
    // it tries once - the recorder refuses a stranger within milliseconds.
    if (device.bonded != null &&
        pairingOf(device) == RecorderPairing.pairedToAnother) {
      await stopScan();
      _lastDevice = device;
      _showPairingProblem(device, PairingOutcome.notOwner);
      return;
    }
    await _connect(device);
  }

  /// [automatic] is always-listening reaching for the remembered device: a
  /// failure then is not an error screen, only the next attempt scheduled.
  Future<void> _connect(
    DiscoveredDevice device, {
    bool automatic = false,
    bool waitForAdvertisement = false,
  }) async {
    if (!automatic) await stopScan();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    // Remembered before the attempt, so "Try again" has something to try even
    // when the attempt is what failed.
    _lastDevice = device;
    _linkOutcome = LinkOutcome.none;
    _pairingProblem = null;
    _lookingForPairingWindow = false;
    _pairingWindowMissed = false;
    _setPhase(AppPhase.connecting);
    final attempt = await _pairingService?.begin(device);
    try {
      if (automatic && waitForAdvertisement) {
        // The recorder is believed asleep: arm a standing wait rather than
        // driving the radio at something that cannot answer. See
        // [ReconnectBackoff.asleepAttemptTimeout].
        await _transport.connect(
          device.id,
          timeout: ReconnectBackoff.asleepAttemptTimeout,
          waitForAdvertisement: true,
        );
      } else if (automatic) {
        await _transport.connect(
          device.id,
          timeout: ReconnectBackoff.attemptTimeout,
        );
      } else {
        await _transport.connect(device.id);
      }
    } on BleTransportException catch (e) {
      final outcome = await attempt?.connectFailed(e);
      if (automatic) {
        _automaticAttemptFailed(outcome);
        return;
      }
      if (outcome != null && outcome.isPairingProblem) {
        _showPairingProblem(device, outcome);
        return;
      }
      // The recorder was found and the handshake did not complete. That is a
      // different fact from a link dropping later, and from nothing being
      // there at all.
      _linkOutcome = LinkOutcome.connectFailed;
      _fail(e.message);
      return;
    }
    // A STANDING attempt stays armed for minutes, and the wearer may turn
    // always-listening off while it waits. A link that arrives after that is
    // nobody's: let it go rather than quietly holding the recorder open - and
    // holding it open is also what would keep the recorder from sleeping
    // again.
    if (waitForAdvertisement && !_continuous.enabled) {
      try {
        await _transport.disconnect(device.id);
      } on BleTransportException {
        // Already gone; there is nothing to release.
      }
      _setPhase(AppPhase.idle);
      return;
    }
    if (attempt != null) {
      // Bond (Android) and read `fe02` before anything else touches the
      // recorder: every value needs encryption, so this is where a stranger,
      // a stale key or a cancelled prompt shows up - once, and classified.
      final outcome = await attempt.afterConnect();
      if (outcome != PairingOutcome.success) {
        try {
          await _transport.disconnect(device.id);
        } on BleTransportException {
          // The recorder has usually dropped the link already.
        }
        if (automatic) {
          _automaticAttemptFailed(outcome);
          return;
        }
        if (outcome.isPairingProblem) {
          _showPairingProblem(device, outcome);
          return;
        }
        _linkOutcome = LinkOutcome.connectFailed;
        _fail("Couldn't pair with the recorder.");
        return;
      }
      _refusedIds.remove(device.id.toLowerCase());
      _pairingRefusals = 0;
      _refusal = null;
    }
    _connectedDevice = device;
    _connectionSubscription =
        _transport.connectionState(device.id).listen((status) {
      if (status == BleConnectionStatus.disconnected) {
        // Nobody asked for this: a working link went away while the adapter was
        // still up. `disconnect()` cancels this subscription before it ends the
        // link, so a deliberate disconnect never arrives here.
        unawaited(_releaseLink(_LinkEnding.peripheralGone));
      }
    });
    _setPhase(AppPhase.connected);
    _reconnectAttempt = 0;
    // Whatever the app believed about a sleep, the recorder is plainly awake.
    _sleepWatch.linked(_now());
    final ownerId = attempt?.ownerId;
    await _rememberDevice(
      ownerId == null
          ? device
          : DiscoveredDevice(id: ownerId, name: device.name),
    );
    // From the discovery the connect already did - no radio time. This is what
    // tells a board with no fe08 ("needs an update") from a read that failed.
    try {
      _captureSupported = await _transport.supportsCapture(device.id);
    } on BleTransportException {
      _captureSupported = false;
    }
    // Read rather than assumed: the flag lives in the device's flash and
    // survives reboots, so only the device knows what it is.
    await _readAutoSleep(device.id);
    // Read once so there is something on screen immediately, then follow the
    // notifications so it stays live. The battery is on the HOME screen, so it
    // is followed for as long as the link lasts.
    await _readBattery(device.id);
    _followBattery(device.id);
    // THE DIE TEMPERATURE IS NOT FOLLOWED HERE, and that is the power rule
    // rather than an omission: subscribing to `fe07` is what makes the firmware
    // sample the sensor, and the only screen that renders the figure is
    // diagnostics. It is read and followed by [openDiagnostics] and dropped
    // again by [closeDiagnostics].
    if (_diagnosticsOpen) await _startDiagnostics(device.id);
    if (_continuous.enabled) await _startContinuousSession(device.id);
    _syncBackground();
    notifyListeners();
    // Every read is an anchor the phone's clock gives meaning to, so one is
    // taken at every connect - after listening has started, so notes never
    // wait on it.
    await refreshBatteryHistory();
  }

  // -------------------------------------------------------------------------
  // THE DIAGNOSTICS SCREEN'S SUBSCRIPTIONS
  //
  // NOTHING RUNS UNLESS REQUIRED. Two subscriptions exist only for that screen:
  // `fe01`, because counting frames means receiving them, and `fe07`, because
  // subscribing is what makes the firmware sample the die at all. Both cost the
  // device power for as long as they are open, so both are owned by the screen's
  // visibility rather than by the link:
  //
  //   * the screen calls [openDiagnostics] when it becomes visible - on push,
  //     and again when the app is resumed - and [closeDiagnostics] when it stops
  //     being visible: popped, or the app backgrounded.
  //   * a link that drops takes them down with it, and a link that comes back
  //     brings them back only if the screen is still open. That is what the
  //     [_diagnosticsOpen] check in [connect] is doing.
  //
  // The screen is also the only thing that renders them, so nothing else goes
  // stale when they are off.
  // -------------------------------------------------------------------------

  /// True while the diagnostics screen is visible and wants live readings.
  bool _diagnosticsOpen = false;

  /// Whether the diagnostics screen currently holds the live subscriptions.
  bool get diagnosticsOpen => _diagnosticsOpen;

  /// What the live link is doing - signal, frames received, frames lost.
  ///
  /// [LinkHealth.watching] is false when nothing is subscribed, which is what
  /// separates "no frames lost" from "nothing is counting". The screen must
  /// render the difference rather than a row of zeroes.
  LinkHealth get linkHealth =>
      _diagnosticsOpen ? _linkMonitor.health : LinkHealth.idle;

  /// Why the live link counters are not running, or null when they are.
  String? get linkFailure => _diagnosticsOpen ? _linkMonitor.failure : null;

  /// The diagnostics screen has become visible: start the live readings.
  ///
  /// Idempotent, because it is called on push AND on every resume from the
  /// background, and a second call must not open a second subscription.
  Future<void> openDiagnostics() async {
    _diagnosticsOpen = true;
    _linkSubscription ??= _linkMonitor.changes.listen((_) => notifyListeners());
    final device = _connectedDevice;
    // NOTHING IS NOTIFIED SYNCHRONOUSLY HERE, and that is load-bearing: this is
    // called from a `State.initState`, which runs inside a build, and notifying
    // a listener that rebuilds an ancestor during a build is an error the
    // framework asserts on. With no device there is nothing to report anyway -
    // [linkHealth] reads as idle either way - and with one, every notification
    // below happens after an await.
    if (device == null) return;
    await _startDiagnostics(device.id);
    await refreshBatteryHistory();
  }

  /// The diagnostics screen has stopped being visible: stop everything it
  /// started.
  ///
  /// Called on pop and on the app going to the background. It must leave nothing
  /// behind - a user who parks on this screen and locks the phone must not leave
  /// the recorder streaming and sampling for hours.
  ///
  /// Does nothing when it was not open, so a teardown that calls it
  /// unconditionally cannot cancel something it did not start.
  Future<void> closeDiagnostics() async {
    if (!_diagnosticsOpen) return;
    _diagnosticsOpen = false;
    // A CHECK THE USER CANNOT SEE IS STILL STREAMING, so it stops too. The
    // samples already taken are saved and the batch is labelled as stopped
    // early - see `DeviceTestService.cancel` - which is the honest outcome:
    // nothing measured is lost, and the radio is not left running behind a
    // screen that is gone.
    _tests.cancel();
    await _linkSubscription?.cancel();
    _linkSubscription = null;
    await _linkMonitor.stop();
    final device = _connectedDevice;
    if (device != null) await _stopTemperature(device.id);
    // The reading described a subscription that is gone; keeping the last figure
    // on screen would be showing a stale measurement as a live one.
    _temperature = null;
    notifyListeners();
  }

  Future<void> _startDiagnostics(String deviceId) async {
    await _readTemperature(deviceId);
    _followTemperature(deviceId);
    // Always-listening holds the one frame subscription; the link view's
    // counters stay idle rather than taking it away.
    if (_session == null) await _linkMonitor.start(deviceId);
    notifyListeners();
  }

  /// Records a battery reading - or its absence - and rebuckets the bars.
  ///
  /// The single writer for [_battery]: assigning the field directly would
  /// leave [_batteryBars] describing a reading that is no longer current.
  /// Note that a null reading rebuckets to [BatteryBars.unknown], which also
  /// clears the hysteresis - there is no previous answer to hold once the
  /// device stops answering.
  void _setBattery(BatteryStatus? status) {
    _battery = status;
    _batteryBars =
        BatteryBars.forPercent(status?.percent, previous: _batteryBars);
  }

  /// Reads the battery status from the connected device.
  ///
  /// A failure is not an app error: it leaves the battery unknown and the
  /// readout unavailable, which is all firmware without `fe05` can honestly
  /// be reported as.
  Future<void> _readBattery(String deviceId) async {
    try {
      _setBattery(await _transport.readBattery(deviceId));
    } on BleTransportException {
      _setBattery(null);
    }
    notifyListeners();
  }

  /// Follows `fe05` notifications so the readout tracks the device.
  ///
  /// An error on the stream - a malformed value, or firmware with no `fe05` at
  /// all - leaves whatever the one-shot read established rather than inventing
  /// a reading, and is not an app failure.
  void _followBattery(String deviceId) {
    unawaited(_batterySubscription?.cancel());
    try {
      _batterySubscription = _transport.subscribeBattery(deviceId).listen(
        (status) {
          _setBattery(status);
          notifyListeners();
          // A battery change is the cheap moment to take a fresh anchor, at
          // most every [batteryAnchorInterval]: no timer of its own.
          if (_batteryHistoryDue()) unawaited(refreshBatteryHistory());
        },
        onError: (Object _) {},
      );
    } on BleTransportException {
      // A transport that refuses to subscribe at all - no `fe05`, or a
      // subscription already open - leaves whatever the one-shot read
      // established. It must never take the connection down with it.
      _batterySubscription = null;
    }
  }

  /// Ends the `fe05` subscription, best effort.
  Future<void> _stopBattery(String deviceId) async {
    await _batterySubscription?.cancel();
    _batterySubscription = null;
    try {
      await _transport.unsubscribeBattery(deviceId);
    } on BleTransportException {
      // The notifications have stopped either way.
    }
  }

  /// Reads the die temperature from the connected device.
  ///
  /// A failure is not an app error: it leaves the temperature unknown and the
  /// readout unavailable, which is all firmware without `fe07` can honestly be
  /// reported as. Mirrors [_readBattery] deliberately - a second way of doing
  /// the same thing is a second way to get it wrong.
  Future<void> _readTemperature(String deviceId) async {
    try {
      _temperature = await _transport.readDieTemperature(deviceId);
    } on BleTransportException {
      _temperature = null;
    }
    notifyListeners();
  }

  /// Follows `fe07` notifications so the readout tracks the die.
  ///
  /// An error on the stream - a malformed value, or firmware with no `fe07` at
  /// all - leaves whatever the one-shot read established rather than inventing
  /// a reading, and is not an app failure.
  void _followTemperature(String deviceId) {
    unawaited(_temperatureSubscription?.cancel());
    try {
      _temperatureSubscription =
          _transport.subscribeDieTemperature(deviceId).listen(
        (reading) {
          _temperature = reading;
          notifyListeners();
        },
        onError: (Object _) {},
      );
    } on BleTransportException {
      _temperatureSubscription = null;
    }
  }

  /// Reads `fe07` once, WITHOUT subscribing.
  ///
  /// For a screen that wants a figure in a report rather than a live readout:
  /// one read costs the device one sample, where a subscription makes it sample
  /// continuously for as long as the subscription is open.
  Future<void> refreshTemperature() async {
    final device = _connectedDevice;
    if (device == null) return;
    await _readTemperature(device.id);
  }

  /// Ends the `fe07` subscription, best effort.
  Future<void> _stopTemperature(String deviceId) async {
    await _temperatureSubscription?.cancel();
    _temperatureSubscription = null;
    try {
      await _transport.unsubscribeDieTemperature(deviceId);
    } on BleTransportException {
      // The notifications have stopped either way.
    }
  }

  // -------------------------------------------------------------------------
  // BATTERY HISTORY (`fe09`)
  //
  // The recorder has no clock, so it counts awake seconds, sleeps and boots
  // since the last plug or unplug, and the PHONE supplies the time: every read
  // is stored as an anchor (phone time + those counters) in the support
  // directory. [BatteryReport] turns the latest read and the anchors into
  // "unplugged at", "on battery for" and an honest runtime estimate - see the
  // firmware's doc/battery-history.md, "What the app must compute".
  //
  // READ AT CONNECT, WHEN DIAGNOSTICS OPENS, AND AT MOST EVERY 30 MIN while
  // connected - on a battery notification or a return to the app, never on a
  // timer of its own. One read is one long ATT read; it costs the recorder
  // nothing it was not already doing.
  // -------------------------------------------------------------------------

  /// Fresh anchors are taken no more often than this, except at connect and
  /// when Diagnostics opens.
  static const Duration batteryAnchorInterval = Duration(minutes: 30);

  final BatteryAnchorStore _anchorStore;
  BatteryHistory? _batteryHistory;
  BatteryReport? _batteryReport;
  BatteryHistoryStatus _batteryHistoryStatus = BatteryHistoryStatus.unknown;
  DateTime? _lastBatteryHistoryRead;
  bool _readingBatteryHistory = false;

  /// The latest decoded `fe09`, or null.
  BatteryHistory? get batteryHistory => _batteryHistory;

  /// What the Diagnostics battery card shows; null until a read succeeded on
  /// this link.
  BatteryReport? get batteryReport => _batteryReport;

  /// Why there is no [batteryReport], when there is none.
  BatteryHistoryStatus get batteryHistoryStatus => _batteryHistoryStatus;

  bool _batteryHistoryDue() {
    final last = _lastBatteryHistoryRead;
    return _connectedDevice != null &&
        (last == null || _now().difference(last) >= batteryAnchorInterval);
  }

  /// Reads `fe09`, stores the anchor and recomputes the report.
  ///
  /// Never throws: firmware without `fe09`, a layout this build cannot read
  /// and a failed save each leave an honest state behind rather than an error.
  Future<void> refreshBatteryHistory() async {
    final device = _connectedDevice;
    if (device == null || _readingBatteryHistory) return;
    _readingBatteryHistory = true;
    // Stamped before the read, so firmware without `fe09` is asked again only
    // on the next interval, not on every battery notification.
    _lastBatteryHistoryRead = _now();
    try {
      final Uint8List bytes;
      try {
        bytes = await _transport.readBatteryHistory(device.id);
      } on BleTransportException {
        if (_connectedDevice?.id == device.id && _batteryHistory == null) {
          _batteryHistoryStatus = BatteryHistoryStatus.notSupported;
        }
        return;
      }
      final now = _now();
      final BatteryHistory history;
      try {
        history = BatteryHistory.fromBytes(bytes);
      } on FormatException catch (error) {
        debugPrint('Battery history unreadable: $error');
        _batteryHistoryStatus = BatteryHistoryStatus.unreadable;
        return;
      }
      if (_connectedDevice?.id != device.id) return;
      List<BatteryAnchor> anchors;
      final anchor = BatteryAnchor.fromHistory(history, now.toUtc());
      try {
        anchors = await _anchorStore.add(anchor);
      } on Object catch (error) {
        // Still useful for this run; only the phone time is forgotten.
        debugPrint('Could not save the battery anchor: $error');
        anchors = <BatteryAnchor>[...await _anchorStore.load(), anchor];
      }
      _batteryHistory = history;
      _batteryHistoryStatus = BatteryHistoryStatus.ready;
      _batteryReport = BatteryReport.compute(
        history: history,
        anchors: anchors,
        now: now.toUtc(),
      );
    } finally {
      _readingBatteryHistory = false;
      notifyListeners();
    }
  }

  // -------------------------------------------------------------------------
  // THE MIC CHECK
  //
  // The controller's job here is the same as everywhere else: supply the
  // device id and the codec, refuse to start a check that cannot honestly run,
  // and let `services/device_test_service.dart` do the measuring. Nothing in
  // these methods knows what a UUID is.
  //
  // IT ALSO ARBITRATES THE ONE FRAME SUBSCRIPTION. `subscribeFrames` takes a
  // single subscriber, and on the diagnostics screen the live link view is
  // normally holding it. So a check stands the live view down before it starts
  // and brings it back when the whole BATCH is over - not after each sample, or
  // the next sample of five would find the subscription taken by the view that
  // was just restarted for it.
  // -------------------------------------------------------------------------

  /// Ten seconds of a quiet room, reported as RMS dBFS.
  ///
  /// THE SAMPLE COUNT IS NOT A PARAMETER HERE and there is no setter for it: it
  /// belongs to the measurement, not to the person taking it, and it differs per
  /// check. See [DeviceTestSampling].
  Future<void> runNoiseFloorTest() => _micCheck(
        (device) => _tests.runNoiseFloor(
          deviceId: device.id,
          requestCodec: _preferredCodec,
          repeats: DeviceTestSampling.samplesFor(DeviceTestKind.noiseFloor),
        ),
      );

  /// A voice at the marked distance, reported as peak and RMS dBFS.
  Future<void> runSensitivityTest() => _micCheck(
        (device) => _tests.runSensitivity(
          deviceId: device.id,
          requestCodec: _preferredCodec,
          repeats: DeviceTestSampling.samplesFor(DeviceTestKind.sensitivity),
        ),
      );

  /// Takes the next sample of a batch that is waiting for the operator.
  Future<void> continueDeviceTestBatch() => _micCheck(
        (_) => _tests.continueBatch(),
        // Needs no connection check of its own: the batch has the device id it
        // started with. It still needs the live view stood down, because ending
        // the previous sample brought it back.
        requireIdle: false,
      );

  /// Runs one mic-check action with the live link view stood down around it.
  Future<void> _micCheck(
    Future<Object?> Function(DiscoveredDevice device) run, {
    bool requireIdle = true,
  }) async {
    final device = _connectedDevice;
    if (device == null) return;
    if (requireIdle && testBlocker != null) return;
    await _linkMonitor.stop();
    notifyListeners();
    try {
      await run(device);
    } finally {
      await _resumeLinkWatch();
    }
  }

  /// Brings the live link view back, unless something still needs the stream.
  ///
  /// Called on every path out of a check, including the failures: a link view
  /// that stayed dark after a check went wrong would look like a dead link.
  Future<void> _resumeLinkWatch() async {
    final device = _connectedDevice;
    if (!_diagnosticsOpen ||
        device == null ||
        _session != null ||
        _tests.isRunning ||
        _tests.isBatchActive) {
      notifyListeners();
      return;
    }
    await _linkMonitor.start(device.id);
    notifyListeners();
  }

  /// Stops the running check. Its partial readings are still saved.
  void cancelDeviceTest() {
    _tests.cancel();
    unawaited(_resumeLinkWatch());
  }

  /// Stops asking for more samples and keeps the ones already taken.
  void endDeviceTestBatch() {
    _tests.endBatch();
    unawaited(_resumeLinkWatch());
  }

  /// Re-reads the auto-sleep flag from the connected device.
  ///
  /// A failure is not an app error: it leaves the setting unknown and the
  /// control unavailable, which is the only honest thing to show when the
  /// recorder did not answer.
  Future<void> _readAutoSleep(String deviceId) async {
    try {
      _autoSleep = await _transport.readAutoSleep(deviceId);
      final read = _autoSleep?.duration;
      if (read != null && read != AutoSleepDuration.off) {
        _chosenSleepDuration = read;
      }
    } on BleTransportException {
      _autoSleep = null;
    }
    notifyListeners();
  }

  /// Turns auto-sleep on or off without choosing a duration. The developer
  /// screen's two buttons; the settings screen picks a duration directly.
  ///
  /// Turning it ON has to name a duration, because `fe04` takes one: the one
  /// in force if there is one, otherwise the shortest option, which is also
  /// what the recorder itself defaults to. Turning it OFF writes code 0, and
  /// the recorder keeps the duration the user chose.
  ///
  /// Does nothing unless the device reported the setting in the first place:
  /// writing a value the app never read would be writing a guess.
  Future<void> setAutoSleep(bool enabled) async {
    final current = _autoSleep;
    if (_connectedDevice == null || current == null ||
        enabled == current.enabled) {
      return;
    }
    final wanted = enabled
        ? (_chosenSleepDuration ?? AutoSleepDuration.seconds30)
        : AutoSleepDuration.off;
    if (!await setAutoSleepDuration(wanted)) {
      // These two buttons have no plain-words slot of their own, so the
      // refusal goes in the error message. setAutoSleepDuration has already
      // put the shown state back.
      _errorMessage = 'Could not change auto-sleep.';
      notifyListeners();
    }
  }

  /// Sets how long the recorder waits, still, before it sleeps.
  ///
  /// OPTIMISTIC: the choice shows at once and is put back if the write fails.
  /// Returns false when nothing was changed - no link, firmware without
  /// durations, or a refused write - so the screen can say so in plain words.
  Future<bool> setAutoSleepDuration(AutoSleepDuration duration) async {
    final device = _connectedDevice;
    final previous = _autoSleep;
    if (device == null || previous == null) {
      return false;
    }
    if (previous.duration == duration) return true;
    if (duration != AutoSleepDuration.off) _chosenSleepDuration = duration;
    _autoSleep = AutoSleepSetting(
      enabled: duration != AutoSleepDuration.off,
      duration: duration,
    );
    notifyListeners();
    try {
      await _transport.setAutoSleepDuration(device.id, duration);
    } on BleTransportException {
      // Put back only on the same link: a link that dropped meanwhile has
      // already cleared the setting to unknown, which is the truth now.
      if (_connectedDevice?.id == device.id) _autoSleep = previous;
      notifyListeners();
      return false;
    }
    return true;
  }

  /// Ends the link the user asked to end.
  ///
  /// A capture in progress is stopped first, so the file is closed and its WAV
  /// header patched rather than truncated by the link going away.
  ///
  /// A FAILING `disconnect` STILL DROPS THE LOCAL STATE. The alternative -
  /// keeping [connectedDevice] because the platform call threw - leaves the UI
  /// claiming a connection the user has already dismissed, with a device name
  /// and a battery percentage that nothing is refreshing. The failure is
  /// reported instead, on the screen the app returns to; reconnecting is one
  /// tap from there.
  ///
  /// Always-listening is turned off first: a user ending the link has said
  /// they do not want it kept.
  Future<void> disconnect() async {
    if (_continuous.enabled) await setContinuousEnabled(false);
    await _releaseLink(_LinkEnding.userAsked);
  }

  /// Drops every trace of the current link. THE ONE TEARDOWN.
  ///
  /// Three things end a link and all three arrive here:
  ///
  ///   * the user asking ([_LinkEnding.userAsked]),
  ///   * the radio reporting the peripheral gone ([_LinkEnding.peripheralGone]),
  ///   * and the adapter itself going away ([_LinkEnding.adapterLost]).
  ///
  /// ONE METHOD BECAUSE THREE COPIES DRIFT, and the stale-"Connected" bug is
  /// exactly what that drift looks like: a second teardown written for the
  /// adapter case would sooner or later forget the die temperature, or the
  /// diagnostics subscriptions, or a check still streaming. Whatever
  /// "disconnected" means, it means the same thing three times.
  ///
  /// The differences between the three are small, named, and all in this method
  /// rather than spread across its callers.
  Future<void> _releaseLink(_LinkEnding ending) async {
    final device = _connectedDevice;
    if (device == null) return;
    // WHY THE LINK ENDED, FIRST, BEFORE THE TEARDOWN SPENDS ANY TIME. A
    // recorder that let go itself with `0x13` and then stopped advertising has
    // gone to sleep, which is not a fault and must not buzz the wearer at
    // 02:00; a supervision timeout is a real drop and still does. The
    // platform's own record of the reason is short-lived, and only an
    // unsolicited drop can be a sleep at all - see [RecorderSleepWatch].
    if (ending == _LinkEnding.peripheralGone) {
      _sleepWatch.dropped(
        reason: _transport.lastDropReason(device.id) ?? LinkDropReason.unknown,
        now: _now(),
      );
    } else {
      _sleepWatch.reset();
    }
    // The open note is closed and kept, whatever ended the link. The device is
    // only told to stop gating when it can still hear us.
    await _stopContinuousSession(linkUp: ending == _LinkEnding.userAsked);
    // The capture is finished properly rather than truncated: `stopRecording`
    // patches the WAV header, and a link that has already gone does not stop it
    // from doing that to the bytes already on disk.
    if (isRecording) await stopRecording();
    // A CHECK CANNOT OUTLIVE THE LINK IT IS MEASURING. Its samples are kept and
    // the batch is labelled stopped early - see `DeviceTestService.cancel` -
    // which is the honest outcome, and it also stops the service holding the
    // frame subscription open against a radio that is not there.
    _tests.cancel();
    // Cancelled in every case, including the one that arrives ON it: there is
    // nothing further to hear about this link, and `connect` installs a fresh
    // subscription rather than reusing this one.
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    // Stop following the battery, the die temperature and the frame stream
    // before the link goes, so the last thing the radio does is not delivering a
    // notification into a torn-down listener.
    //
    // `_diagnosticsOpen` is deliberately NOT cleared. The screen may still be on
    // top, and a reconnect should bring its readings back without the user
    // leaving and returning - see [connect]. What matters for the power rule is
    // that the SUBSCRIPTIONS are down, and these two lines are what puts them
    // down; `_linkSubscription` carries no device state and is left for
    // [closeDiagnostics] to drop when the screen actually goes away.
    await _stopBattery(device.id);
    await _stopTemperature(device.id);
    await _linkMonitor.stop();
    String? failure;
    if (ending != _LinkEnding.peripheralGone) {
      // The peripheral is already gone in that case, and the existing behaviour
      // is to say nothing to a stack that has nothing to close. The other two
      // still ask, so the platform releases its GATT client.
      try {
        await _transport.disconnect(device.id);
      } on BleTransportException catch (e) {
        // Reported only when the USER asked: they are owed an explanation for an
        // action they took. With the adapter gone the call was never going to
        // succeed, there is nothing the user could do about it, and the
        // Bluetooth-off screen is the whole message.
        if (ending == _LinkEnding.userAsked) failure = e.message;
      }
    }
    _connectedDevice = null;
    _captureSupported = null;
    _autoSleep = null;
    _chosenSleepDuration = null;
    // These readings described a link that is gone; keeping the last percentage
    // or the last temperature on screen would be showing a stale measurement as
    // a live one.
    _setBattery(null);
    _temperature = null;
    _batteryHistory = null;
    _batteryHistoryStatus = BatteryHistoryStatus.unknown;
    _batteryReport = null;
    _lastBatteryHistoryRead = null;
    // A dropped link leaves whatever message was already on screen: it explains
    // the last thing the user did, and `ConnectionLostView` supplies the reason
    // for the drop itself.
    if (ending != _LinkEnding.peripheralGone) _errorMessage = failure;
    // Only an unsolicited drop is worth explaining and offering a retry for. The
    // user asking needs neither, and the adapter going off has a screen of its
    // own - the Bluetooth-off edge state, which is reached by leaving the
    // outcome at `none`.
    //
    // Always-listening explains nothing either: it is already reaching for the
    // device again, and the home screen says so.
    _linkOutcome =
        ending == _LinkEnding.peripheralGone && !_continuous.enabled
            ? LinkOutcome.connectionLost
            : LinkOutcome.none;
    _setPhase(AppPhase.idle);
    if (ending != _LinkEnding.userAsked) _scheduleReconnect();
    _watchForSleep();
    _syncBackground();
  }

  /// Connects to [lastDevice] again - the action behind both "Try again" after
  /// a failed handshake and "Reconnect" after a dropped link.
  ///
  /// One method for two screens because the ACTION is the same one; the two
  /// situations stay distinct in [linkOutcome], which is what the screens are
  /// chosen by. With no device to return to it falls back to a fresh scan,
  /// which is the only honest thing left to do.
  Future<void> retryConnection() {
    final device = _lastDevice;
    if (device == null) return startScan();
    return connect(device);
  }

  /// Clears a link failure the user has acknowledged - "Choose another device".
  ///
  /// It drops the explanation, not the discovered devices, so the screen it
  /// returns to is the list the user was choosing from.
  void dismissLinkFailure() {
    if (_linkOutcome == LinkOutcome.none) return;
    _linkOutcome = LinkOutcome.none;
    _errorMessage = null;
    _setPhase(_connectedDevice == null ? AppPhase.idle : AppPhase.connected);
  }

  /// Opens the system Bluetooth settings. False when the platform has no such
  /// destination - see [PlatformSettings], which documents what each platform
  /// can actually reach.
  Future<bool> openBluetoothSettings() async =>
      await _settings?.openBluetoothSettings() ?? false;

  /// Opens this app's own settings page, where its permissions live.
  Future<bool> openAppSettings() async =>
      await _settings?.openAppSettings() ?? false;

  // -------------------------------------------------------------------------
  // PAIRING TO ONE PHONE
  //
  // The recorder bonds with one phone. Its scan response says whether it has
  // an owner and whether its pairing window is open; a phone that is not the
  // owner is refused right after connecting. The flow itself is
  // [PairingService] and `model/pairing_flow.dart`; this keeps what the
  // screens show and what always-listening does about a refusal.
  //
  // Without a pairing driver none of this runs and every recorder is
  // [RecorderPairing.unknown].
  // -------------------------------------------------------------------------

  /// The pairing problem the scan screen is showing, or null.
  PairingOutcome? _pairingProblem;

  /// "I've done that" was tapped: the scan is looking for a recorder whose
  /// pairing window is open.
  bool _lookingForPairingWindow = false;

  /// The last such scan ended without seeing one.
  bool _pairingWindowMissed = false;

  /// Recorders that refused this phone since the app started (lower-cased).
  /// Outranks a stale bond the OS still lists.
  final Set<String> _refusedIds = <String>{};

  /// Automatic attempts in a row that ended in a pairing problem.
  int _pairingRefusals = 0;

  /// What always-listening says while the recorder keeps refusing.
  ContinuousStatus? _refusal;

  /// Why the scan screen shows the pairing instructions or the Bluetooth
  /// settings advice instead of the list; null when it does not. Only ever
  /// [PairingOutcome.notOwner], [PairingOutcome.needsPairingWindow] or
  /// [PairingOutcome.staleBond].
  PairingOutcome? get pairingProblem => _pairingProblem;

  /// True while "I've done that" is scanning for the open window.
  bool get lookingForPairingWindow => _lookingForPairingWindow;

  /// True when that scan ended without finding it.
  bool get pairingWindowMissed => _pairingWindowMissed;

  /// Whether this app supports pairing at all (a pairing driver was given).
  bool get pairingSupported => _pairingService != null;

  /// How [device] stands with this phone, for its card.
  RecorderPairing pairingOf(DiscoveredDevice device) =>
      _pairingService?.stateOf(
        device,
        refusedHere: _refusedIds.contains(device.id.toLowerCase()),
      ) ??
      RecorderPairing.unknown;

  /// The recorder Settings is about: the one connected, else the remembered
  /// one.
  String? get _settingsRecorderId =>
      _connectedDevice?.id ?? _continuous.deviceId;

  /// Whether this phone is the recorder's owner, as far as the app knows.
  bool get pairedToThisPhone {
    final id = _settingsRecorderId;
    return id != null && (_pairingService?.isOwner(id) ?? false);
  }

  /// When this phone paired with that recorder, if known.
  DateTime? get pairedSince {
    final id = _settingsRecorderId;
    return id == null ? null : _pairingService?.pairedSince(id);
  }

  void _showPairingProblem(DiscoveredDevice device, PairingOutcome outcome) {
    if (outcome.needsCharger) _refusedIds.add(device.id.toLowerCase());
    _pairingProblem = outcome;
    _errorMessage = null;
    _setPhase(AppPhase.idle);
  }

  /// An automatic (always-listening) attempt failed with [outcome]; null when
  /// no pairing driver classified it.
  void _automaticAttemptFailed(PairingOutcome? outcome) {
    if (outcome != null && outcome.isPairingProblem) {
      _pairingRefusals++;
      _refusal = outcome.needsCharger
          ? ContinuousStatus.pairedToAnother
          : ContinuousStatus.oldPairing;
      // A recorder that refuses this phone is awake and advertising: it is
      // not asleep, whatever the last disconnect looked like.
      _sleepWatch.heard(_now());
      _syncBackground();
    } else {
      // Nothing answered. On a link that ended cleanly that is the other half
      // of "asleep": a recorder that had merely rebooted would be advertising
      // by now and this attempt would have found it.
      _sleepWatch.foundNothing(_now());
    }
    _setPhase(AppPhase.idle);
    _watchForSleep();
    _scheduleReconnect();
    _syncBackground();
  }

  /// Keeps the header and the notification honest while a clean drop is still
  /// settling: when the quiet window runs out the answer becomes "asleep" with
  /// nothing else having happened, so something has to ask again.
  ///
  /// NOTHING RUNS UNLESS A DECISION IS PENDING - one timer, and only while
  /// [RecorderSleepWatch] says a check is due.
  void _watchForSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final next = _sleepWatch.nextCheck();
    if (next == null) return;
    final wait = next.difference(_now());
    _sleepTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _sleepTimer = null;
      _syncBackground();
      notifyListeners();
    });
  }

  /// "I've done that": scans for a recorder with its pairing window open and
  /// connects to it as soon as one shows up.
  Future<void> retryPairing() async {
    _pairingWindowMissed = false;
    _lookingForPairingWindow = true;
    notifyListeners();
    await startScan();
    if (!isScanning) {
      _lookingForPairingWindow = false;
      notifyListeners();
    }
  }

  /// The user left the pairing screen - "Not now".
  Future<void> dismissPairingProblem() async {
    final looking = _lookingForPairingWindow;
    _pairingProblem = null;
    _lookingForPairingWindow = false;
    _pairingWindowMissed = false;
    if (looking) {
      await stopScan();
    } else {
      notifyListeners();
    }
  }

  void _connectIfPairingWindowOpen(DiscoveredDevice device) {
    if (!_lookingForPairingWindow) return;
    if (device.name != DeviceProfile.advertisedName) return;
    if (device.pairing?.windowOpen != true) return;
    _lookingForPairingWindow = false;
    unawaited(_connect(device));
  }

  // -------------------------------------------------------------------------
  // ALWAYS LISTENING
  //
  // The user wears the device all day and notes appear by themselves. The
  // device streams only speech (`fe08` = speech only); a [ContinuousSession]
  // turns that stream into ordinary recordings; this controller keeps the link
  // up - reconnecting with backoff after a drop, after Bluetooth comes back and
  // after a restart - and keeps the Android foreground service's notification
  // saying what is happening.
  //
  // WHEN IT IS OFF, NOTHING HERE RUNS: no session, no timer, no service. The
  // app behaves exactly as it did before the mode existed.
  // -------------------------------------------------------------------------

  final BackgroundMode? _background;
  final ContinuousSettingsStore _settingsStore;
  final Duration _continuousKeepalive;
  ContinuousSettings _continuous = const ContinuousSettings();
  ContinuousSession? _session;
  StreamSubscription<void>? _sessionChanges;
  StreamSubscription<NoteChange>? _sessionNotes;

  /// Whether the connected firmware has `fe08`; null with no link.
  bool? _captureSupported;

  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// The gap between standing "wait for it to advertise" attempts at a
  /// sleeping recorder. Injected so tests do not have to wait it out.
  final Duration _asleepRetryDelay;

  /// Asleep or gone? The one place that decides - see [RecorderSleepWatch].
  final RecorderSleepWatch _sleepWatch = RecorderSleepWatch();

  /// Fires when a settling drop has been quiet long enough to count as sleep,
  /// so the header and the notification change without waiting for the next
  /// thing to happen on the link.
  Timer? _sleepTimer;

  Duration? _scheduledReconnectDelay;

  /// The wait before the reconnect attempt most recently scheduled.
  @visibleForTesting
  Duration? get scheduledReconnectDelay => _scheduledReconnectDelay;

  /// What the notification says now; null while the service is not running.
  String? _backgroundText;

  /// Whether the user turned always-listening on. Persisted.
  bool get continuousEnabled => _continuous.enabled;

  /// Whether notes are being made right now - on, connected, and supported.
  bool get continuousActive => _session != null;

  /// Whether there is a device to listen through: one connected now, or one
  /// remembered from before.
  bool get canUseContinuous =>
      _connectedDevice != null || _continuous.deviceId != null;

  /// The one status the home screen and the notification both show.
  ContinuousStatus get continuousStatus => ContinuousStatus.resolve(
        enabled: _continuous.enabled,
        connected: isConnected,
        captureSupported: _captureSupported,
        flags: _session?.flags,
        refused: _refusal,
        asleep: recorderAsleep,
      );

  /// Whether the recorder is believed to be asleep - it let the link go and
  /// has not been heard from since. See [RecorderSleepWatch].
  bool get recorderAsleep =>
      _sleepWatch.update(_now()) == RecorderPresence.asleep;

  /// Where this recorder can keep audio by itself. Every recorder today has
  /// no storage; an SD-card one would answer [RecorderStorage.card], and a lost
  /// link then reads "Saving on recorder" instead of an alarm.
  RecorderStorage get recorderStorage => RecorderStorage.none;

  /// Are notes being saved right now - the header, the settings screen and
  /// the not-saving alert all read this.
  NotesSaving get notesSaving =>
      NotesSaving.from(continuousStatus, storage: recorderStorage);

  /// Whether the not-saving alert is showing (notification and buzz sent).
  bool get notSavingAlerting => _savingAlert.alerting;

  /// The note being written, which the library marks and nothing transcribes.
  String? get writingNotePath => _session?.currentNotePath;

  /// Turns always-listening on or off, and remembers the choice.
  ///
  /// On with a link up starts listening at once; on without one starts
  /// reaching for the remembered device. Off stops everything and tells the
  /// device to stream normally again.
  Future<void> setContinuousEnabled(bool enabled) async {
    if (enabled == _continuous.enabled) return;
    if (enabled && !canUseContinuous) return;
    final device = _connectedDevice;
    _continuous = _continuous.copyWith(
      enabled: enabled,
      deviceId: device?.id,
      deviceName: device?.name,
    );
    await _saveContinuous();
    _pairingRefusals = 0;
    _refusal = null;
    if (enabled) {
      if (device != null) {
        await _startContinuousSession(device.id);
      } else {
        _reconnectAttempt = 0;
        _ensureContinuousLink();
      }
    } else {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempt = 0;
      _sleepTimer?.cancel();
      _sleepTimer = null;
      _sleepWatch.reset();
      await _stopContinuousSession(linkUp: _connectedDevice != null);
    }
    _syncBackground();
    notifyListeners();
  }

  /// Whether the phone will let always-listening survive the screen going off:
  /// notifications allowed and battery optimisation lifted. True where the
  /// platform has nothing to grant.
  Future<bool> backgroundPermissionsGranted() async {
    final background = _background;
    if (background == null) return true;
    return await background.notificationsAllowed() &&
        await background.backgroundWorkAllowed();
  }

  /// Asks for what [backgroundPermissionsGranted] checks, one at a time.
  ///
  /// THE SECOND ASK WAITS FOR THE FIRST. Both are system UI over this app -
  /// a permission dialog on Android, a Settings page on iOS - and raising them
  /// together stacks two dialogs, or loses the second to the background
  /// activity-start rules. [BackgroundMode.requestNotifications] does not
  /// return until the user has answered, which is what makes this safe; a
  /// "no" there does not stop the other being asked.
  Future<void> requestBackgroundPermissions() async {
    final background = _background;
    if (background == null) return;
    if (!await background.notificationsAllowed()) {
      await background.requestNotifications();
    }
    if (!await background.backgroundWorkAllowed()) {
      await background.requestBackgroundWork();
    }
  }

  /// Whether this phone has a vendor autostart switch worth pointing at.
  Future<bool> hasAutostartSettings() async =>
      await _background?.hasAutostartSettings() ?? false;

  Future<bool> openAutostartSettings() async =>
      await _background?.openAutostartSettings() ?? false;

  Future<void> _saveContinuous() async {
    try {
      await _settingsStore.save(_continuous);
    } on Object catch (error) {
      // Still on for this run; it is only forgotten across a restart.
      debugPrint('Could not save the always-listening setting: $error');
    }
  }

  /// Remembers [device] as the one to reach after a restart.
  ///
  /// Only while always-listening is on: nothing else reconnects by itself, and
  /// turning it on records the device connected at that moment anyway.
  Future<void> _rememberDevice(DiscoveredDevice device) async {
    if (!_continuous.enabled) return;
    if (_continuous.deviceId == device.id &&
        (device.name == null || _continuous.deviceName == device.name)) {
      return;
    }
    _continuous = _continuous.copyWith(
      deviceId: device.id,
      deviceName: device.name,
    );
    await _saveContinuous();
  }

  /// Makes the link always-listening wants, if it is not there: a session on a
  /// link that is up, or a reconnect attempt when there is none.
  void _ensureContinuousLink() {
    if (!_continuous.enabled || !_initialised) return;
    final device = _connectedDevice;
    if (device != null) {
      if (_session == null && _phase != AppPhase.connecting) {
        unawaited(_startContinuousSession(device.id));
      }
      return;
    }
    if (_reconnectTimer == null && _phase != AppPhase.connecting) {
      _scheduleReconnect();
    }
  }

  /// Schedules the next attempt to reach the remembered device - see
  /// [ReconnectBackoff] for the waits and why.
  ///
  /// Only while it can succeed: on, a device remembered, no link and none
  /// being made, and the radio on. Bluetooth coming back calls this again.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (!_continuous.enabled ||
        _continuous.deviceId == null ||
        _connectedDevice != null ||
        _phase == AppPhase.connecting ||
        _availability != BleAvailability.poweredOn) {
      return;
    }
    final asleep = recorderAsleep;
    final delay = asleep
        ? _asleepRetryDelay
        : ReconnectBackoff.delayFor(
            _reconnectAttempt++,
            refusals: _pairingRefusals,
          );
    _scheduledReconnectDelay = delay;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_reconnect());
    });
  }

  Future<void> _reconnect() async {
    final id = _continuous.deviceId;
    if (!_continuous.enabled ||
        id == null ||
        _connectedDevice != null ||
        _phase == AppPhase.connecting ||
        _availability != BleAvailability.poweredOn) {
      return;
    }
    try {
      // Without the permission there is nothing to retry: the next time the
      // app is opened, [appForegrounded] tries again and the OS can ask.
      if (!await _transport.ensurePermissions()) return;
    } on BleTransportException {
      _scheduleReconnect();
      return;
    }
    // A recorder this phone owns is reached through its bonded identity
    // address on Android, not a private address a scan once saw.
    final target = await _pairingService?.reconnectId(id) ?? id;
    await _connect(
      DiscoveredDevice(id: target, name: _continuous.deviceName),
      automatic: true,
      waitForAdvertisement: recorderAsleep,
    );
  }

  Future<void> _startContinuousSession(String deviceId) async {
    if (!_continuous.enabled ||
        _session != null ||
        _captureSupported != true ||
        _recorder.isRecording) {
      _syncBackground();
      notifyListeners();
      return;
    }
    // THE FRAME SUBSCRIPTION IS EXCLUSIVE. A mic check and the diagnostics link
    // view stand down; the session is what the user asked for.
    _tests.cancel();
    await _linkMonitor.stop();
    final session = ContinuousSession(
      transport: _transport,
      fileStore: _fileStore,
      directory: _recordingsDirectory,
      keepaliveInterval: _continuousKeepalive,
    );
    _session = session;
    _sessionChanges = session.changes.listen((_) {
      _syncBackground();
      notifyListeners();
    });
    _sessionNotes = session.notes.listen(_onNoteChange);
    try {
      await session.start(deviceId, requestCodec: _preferredCodec);
    } on ContinuousSessionException catch (error) {
      debugPrint('Always listening could not start: $error');
      if (identical(_session, session)) await _stopContinuousSession(linkUp: true);
      return;
    }
    // Stopped while it was starting - the link dropped, or the user turned it
    // off - so this one must not be left running.
    if (!identical(_session, session)) {
      await session.stop(linkUp: false);
      await session.dispose();
      return;
    }
    _syncBackground();
    notifyListeners();
  }

  /// Ends the session, closing and keeping its open note. [linkUp] as in
  /// [ContinuousSession.stop].
  Future<void> _stopContinuousSession({required bool linkUp}) async {
    final session = _session;
    if (session == null) return;
    _session = null;
    // Stopped BEFORE the listeners go, so the note it closes still reaches the
    // library and the transcription queue.
    await session.stop(linkUp: linkUp);
    await _sessionChanges?.cancel();
    _sessionChanges = null;
    await _sessionNotes?.cancel();
    _sessionNotes = null;
    await session.dispose();
    notifyListeners();
  }

  void _onNoteChange(NoteChange change) {
    switch (change.kind) {
      case NoteChangeKind.started:
      case NoteChangeKind.discarded:
        unawaited(refreshLibrary());
      case NoteChangeKind.finished:
        unawaited(
          refreshLibrary().then((_) => _enqueueFinished(change.path)),
        );
    }
  }

  /// Keeps the keep-alive in step with [continuousStatus]: running exactly
  /// while always-listening is on, and saying what it is doing. The platform
  /// is only called when the text actually changes, OR when the last call
  /// failed - a foreground service that was refused has to be asked again, and
  /// the text is often the same when it is.
  ///
  /// On Android that is the service notification; on iOS only the `alert`
  /// flag means anything, and an ordinary status line does nothing at all.
  ///
  /// It is also where the NOT-SAVING ALERT is asked: every change that can
  /// start or stop notes being saved already passes through here.
  void _syncBackground() {
    _checkNotesSaving();
    final background = _background;
    if (background == null) return;
    if (!_continuous.enabled) {
      if (_backgroundText != null) {
        _backgroundText = null;
        unawaited(background.stop());
      }
      return;
    }
    final alerting = _savingAlert.alerting;
    final title = alerting ? notSavingTitle : 'voiceNotetaker';
    final text = alerting ? _notSavingReason(notesSaving) : continuousStatus.label;
    final key = '$title\n$text';
    if (key == _backgroundText) return;
    _backgroundText = key;
    unawaited(_startBackground(title: title, text: text, alert: alerting));
  }

  /// Starts or updates the keep-alive, and FORGETS THE TEXT IF IT FAILED.
  ///
  /// A foreground service can be refused - Android 14 with the Bluetooth
  /// permission revoked, or a background start with no exemption - and a
  /// refusal that is remembered as done is never retried, because the text
  /// rarely changes twice. Clearing the key instead means the next thing that
  /// happens on the link asks again.
  Future<void> _startBackground({
    required String title,
    required String text,
    required bool alert,
  }) async {
    var running = true;
    try {
      running = await _background?.start(
            title: title,
            text: text,
            alert: alert,
          ) ??
          true;
    } on Object catch (error) {
      debugPrint('Could not start the keep-alive: $error');
      running = false;
    }
    if (!running && _backgroundText == '$title\n$text') _backgroundText = null;
  }

  // -------------------------------------------------------------------------
  // NOT-SAVING ALERT
  //
  // While always-listening is on and notes have not been saved for 30 s, the
  // phone buzzes once and the listening notification says "Notes not saving".
  // When saving resumes, one short buzz and the notification goes back. The
  // rules - grace, one buzz per 10 min, never for privacy mode, a sleeping
  // recorder or off - are
  // [NotSavingAlertPolicy]'s. This only runs the one timer and the drivers.
  //
  // NOTHING RUNS UNLESS REQUIRED: the timer exists only while notes are being
  // lost and the grace period has not run out.
  // -------------------------------------------------------------------------

  final Haptics? _haptics;
  final NotSavingAlertPolicy _savingAlert;
  Timer? _savingTimer;

  /// The notification title while the alert shows.
  static const String notSavingTitle = 'Notes not saving';

  static String _notSavingReason(NotesSaving saving) => switch (saving) {
        NotesSaving.micOff => 'Mic off to save battery',
        NotesSaving.needsUpdate => 'Recorder needs an update',
        NotesSaving.pairedToAnother => 'Recorder paired to another phone',
        NotesSaving.oldPairing => 'Pairing needs a reset',
        _ => 'Recorder disconnected',
      };

  void _checkNotesSaving() {
    _savingTimer?.cancel();
    _savingTimer = null;
    // Nobody to tell: a build without a notification or a vibrator.
    if (_background == null && _haptics == null) return;
    final now = _now();
    // A recorder that let the link go itself is not a failure to report - and
    // while a clean drop is still being decided, neither is that. See
    // [RecorderSleepWatch].
    final atRest = _sleepWatch.update(now).isRestful;
    switch (_savingAlert.update(notesSaving, now, atRest: atRest)) {
      case NotSavingAction.alert:
        unawaited(_haptics?.buzz(BuzzPattern.notSaving));
      case NotSavingAction.resumed:
        unawaited(_haptics?.buzz(BuzzPattern.resumed));
      case NotSavingAction.alertSilently:
      case NotSavingAction.cleared:
      case NotSavingAction.none:
        break;
    }
    final next = _savingAlert.nextCheck();
    if (next == null) return;
    final wait = next.difference(now);
    _savingTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _savingTimer = null;
      _syncBackground();
      notifyListeners();
    });
  }

  // -------------------------------------------------------------------------
  // AUDIO RETENTION
  //
  // With `autoDeleteAudio` on, a recording's WAV is removed 24 h after it was
  // made - only once it has a transcript with words in it, never while it is
  // written, played or transcribed, and never when the user marked it kept.
  // The transcript stays and the library still lists the note, with
  // `hasAudio` false. The rules are [AudioRetention]'s.
  //
  // OFF BY DEFAULT, and nothing on screen turns it on yet: the Keep control
  // needs a design first. Off, no sweep runs and nothing here touches a file.
  // On, a sweep runs at start, on every return to the app, and after every
  // transcript is saved.
  // -------------------------------------------------------------------------

  final AudioRetentionSettingsStore _retentionSettings;
  late final AudioRetentionService _retention = AudioRetentionService(
    fileStore: _fileStore,
    directory: _recordingsDirectory,
    transcripts: _transcripts,
  );
  final DateTime Function() _now;
  bool _autoDeleteAudio = false;
  bool _sweeping = false;
  RetentionSweepReport? _lastAudioSweep;

  /// Whether audio is removed 24 h after recording. Persisted; false unless
  /// turned on.
  bool get autoDeleteAudio => _autoDeleteAudio;

  /// What the last sweep did, for Developer options; null before one ran.
  RetentionSweepReport? get lastAudioSweep => _lastAudioSweep;

  /// Whether the user marked the recording at [path] to keep its audio.
  bool keepAudioFor(String path) {
    for (final recording in _recordings) {
      if (recording.path == path) return recording.keepAudio;
    }
    return false;
  }

  /// Turns automatic audio removal on or off, and remembers the choice.
  /// Turning it on sweeps at once.
  Future<void> setAutoDeleteAudio(bool enabled) async {
    if (enabled == _autoDeleteAudio) return;
    _autoDeleteAudio = enabled;
    try {
      await _retentionSettings.saveAutoDeleteAudio(enabled);
    } on Object catch (error) {
      // Applies for this run; it is only forgotten across a restart.
      debugPrint('Could not save the audio retention setting: $error');
    }
    notifyListeners();
    if (enabled) await _sweepAudio();
  }

  /// Marks the recording at [path] to keep its audio past 24 h, or not.
  /// Survives restarts. Does not bring back audio already removed.
  Future<void> setKeepAudio(String path, bool keep) async {
    try {
      await _retention.setKeep(path, keep: keep);
    } on Object catch (error) {
      _errorMessage = 'Could not change whether this audio is kept: $error';
      notifyListeners();
      return;
    }
    await refreshLibrary();
  }

  /// Runs one retention sweep if the setting is on and none is running.
  Future<void> _sweepAudio() async {
    if (!_autoDeleteAudio || _sweeping) return;
    // A manual capture has an open file; it is young, but nothing is removed
    // while one is being written.
    if (_recorder.isRecording) return;
    _sweeping = true;
    try {
      final report = await _retention.sweep(
        now: _now(),
        isInUse: (path) =>
            _recorder.isRecording ||
            path == writingNotePath ||
            path == _transcribingPath ||
            path == _nowPlaying?.path,
      );
      _lastAudioSweep = report;
      if (report.removed.isNotEmpty || report.failed.isNotEmpty) {
        debugPrint('Audio retention: $report');
      }
      if (report.removed.isNotEmpty) await refreshLibrary();
    } on Object catch (error) {
      debugPrint('Audio retention sweep failed: $error');
    } finally {
      _sweeping = false;
    }
  }

  // -------------------------------------------------------------------------
  // EMPTY NOTES
  //
  // A note whose transcription SUCCEEDED and found nothing in any window is
  // deleted - WAV, transcript and sidecars - unless the user marked it Keep.
  // Never while it is written, while a manual recording runs, while it is open
  // in the note screen (or playing), or while it is transcribed: deferred,
  // and tried again when that ends. The rules are [EmptyNotePolicy]'s; the
  // marker-first deletion is [EmptyNoteService]'s. Marked notes are swept at
  // every start, and again whenever one stops being in use.
  // -------------------------------------------------------------------------

  late final EmptyNoteService _emptyNotes = EmptyNoteService(
    fileStore: _fileStore,
    directory: _recordingsDirectory,
    transcripts: _transcripts,
  );

  /// How many note screens show each recording, by path.
  final Map<String, int> _openNotes = <String, int>{};

  bool _emptySweeping = false;
  bool _emptySweepAgain = false;

  /// A note was marked empty, or the last sweep deferred or failed one.
  bool _emptyNotesPending = false;

  EmptyNoteSweepReport? _lastEmptyNoteSweep;

  /// What the last empty-note sweep did; null before one ran.
  EmptyNoteSweepReport? get lastEmptyNoteSweep => _lastEmptyNoteSweep;

  /// The note screen is showing [path]: it is not deleted meanwhile.
  void noteOpened(String path) {
    _openNotes[path] = (_openNotes[path] ?? 0) + 1;
  }

  /// A note screen showing [path] closed. A deferred deletion runs now.
  void noteClosed(String path) {
    final count = (_openNotes[path] ?? 0) - 1;
    if (count > 0) {
      _openNotes[path] = count;
      return;
    }
    _openNotes.remove(path);
    unawaited(_sweepEmptyNotesIfPending());
  }

  Future<void> _markEmptyNote(String path) async {
    try {
      await _emptyNotes.markEmpty(path, now: _now());
      _emptyNotesPending = true;
    } on Object catch (error) {
      debugPrint('Could not mark an empty note: $error');
    }
  }

  Future<void> _sweepEmptyNotesIfPending() async {
    if (_emptyNotesPending) await _sweepEmptyNotes();
  }

  Future<void> _sweepEmptyNotes() async {
    if (_emptySweeping) {
      _emptySweepAgain = true;
      return;
    }
    _emptySweeping = true;
    try {
      do {
        _emptySweepAgain = false;
        final report = await _emptyNotes.sweep(
          now: _now(),
          useOf: (path) => (
            writing: path == writingNotePath,
            // The capture's own path is not known here, so every note waits
            // for it; stopping the recording sweeps again.
            capturing: _recorder.isRecording,
            open: _openNotes.containsKey(path) ||
                (path == _nowPlaying?.path && _playback.isPlaying),
            transcribing: path == _transcribingPath,
          ),
        );
        _lastEmptyNoteSweep = report;
        _emptyNotesPending =
            report.deferred.isNotEmpty || report.failed.isNotEmpty;
        if (report.deleted.isEmpty) continue;
        debugPrint('Empty notes: $report');
        for (final path in report.deleted) {
          _queue.remove(path);
          _transcriptCache.remove(path);
          _transcriptFailures.remove(path);
          _speakerNames.remove(path);
          _speakerSettings.remove(path);
          if (_lastRecording?.path == path) _lastRecording = null;
          // Stopped when its screen closed; the player lets go of it.
          if (_nowPlaying?.path == path) {
            _nowPlaying = null;
            _playback = PlaybackState.idle;
          }
        }
        await refreshLibrary();
      } while (_emptySweepAgain);
    } on Object catch (error) {
      debugPrint('Empty note sweep failed: $error');
    } finally {
      _emptySweeping = false;
    }
  }

  Future<void> startRecording() async {
    final device = _connectedDevice;
    // Not while always-listening: notes are already being made, from the same
    // single frame subscription.
    if (device == null || isRecording || _session != null) return;
    _errorMessage = null;
    // The recorder's default is speech only, so a recording the user started
    // has to ask for everything.
    if (_captureSupported == true) {
      try {
        await _transport.writeCapture(device.id, CaptureCommand.gateDisabled);
      } on BleTransportException {
        // The gate stays where it was. The recording still happens; if the
        // gate was shut, what arrives is speech rather than everything -
        // worse than asked for, and better than refusing to record.
      }
    }
    _level = null;
    final path = _fileStore.join(
      _recordingsDirectory,
      RecordingNaming.fileName(DateTime.now()),
    );
    try {
      await _recorder.start(
        deviceId: device.id,
        path: path,
        requestCodec: _preferredCodec,
      );
    } on RecordingException catch (e) {
      _fail(e.message);
      return;
    } on BleTransportException catch (e) {
      _fail(e.message);
      return;
    }
    _stats = const CaptureStats();
    _setPhase(AppPhase.recording);
  }

  Future<void> stopRecording() async {
    if (!_recorder.isRecording) return;
    _setPhase(AppPhase.stopping);
    try {
      _lastRecording = await _recorder.stop();
      _stats = _lastRecording!.stats;
    } on RecordingException catch (e) {
      _level = null;
      _fail(e.message);
      return;
    }
    _level = null;
    // The file only exists once the header has been patched and the sink
    // closed, so the library is re-read here rather than when the capture
    // started.
    await refreshLibrary();
    _setPhase(_connectedDevice == null ? AppPhase.idle : AppPhase.connected);
    unawaited(_enqueueFinished(_lastRecording!.path));
    unawaited(_sweepEmptyNotesIfPending());
  }

  /// Re-reads the recordings directory.
  Future<void> refreshLibrary() async {
    try {
      _recordings = await _library.refresh();
    } on Object catch (error) {
      // A library that cannot be listed is not a reason to break the app; the
      // message is surfaced and the previous list is kept.
      _errorMessage = 'Could not read the recordings folder: $error';
    }
    notifyListeners();
  }

  /// Deletes [recording]: the file, and every reference the app still holds
  /// to it.
  ///
  /// Playback stops FIRST when this is the recording being played. Deleting a
  /// file out from under an open player is a platform-level crash, not a
  /// tidy-up problem, so the order here is load-bearing.
  ///
  /// A recording's name, timestamp and length are read back from the file
  /// name and its own WAV header. The one file kept beside it is its saved
  /// transcript, which `LibraryService.delete` removes with it. Everything
  /// else is in-memory references - [nowPlaying], [lastRecording], the
  /// transcript caches and the published list - and any one of them left
  /// pointing at a deleted path is the orphan entry.
  Future<void> deleteRecording(RecordingInfo recording) async {
    // The note always-listening is writing has an open file behind it; it can
    // be deleted once it is finished.
    if (recording.path == writingNotePath) {
      _errorMessage = 'This note is still being written.';
      notifyListeners();
      return;
    }
    _queue.remove(recording.path);
    if (_nowPlaying?.path == recording.path) {
      await stopPlayback();
      _nowPlaying = null;
      _playback = PlaybackState.idle;
      _playbackError = null;
    }
    if (_lastRecording?.path == recording.path) _lastRecording = null;
    // A transcription of this file stops first, for the same reason playback
    // does: the engine reads the file as it goes.
    if (_transcribingPath == recording.path) await cancelTranscription();
    _transcriptCache.remove(recording.path);
    _transcriptFailures.remove(recording.path);
    try {
      // The service re-lists the directory itself, so the deletion and the
      // list can never disagree.
      await _library.delete(recording.path);
      _recordings = _library.current;
    } on Object catch (error) {
      _errorMessage = 'Could not delete ${recording.name}: $error';
    }
    notifyListeners();
  }

  /// Loads [recording] into the player and starts it.
  Future<void> playRecording(RecordingInfo recording) async {
    final player = _player;
    if (player == null) return;
    if (!recording.hasAudio) {
      _playbackError = 'The audio of this recording was removed; '
          'its transcript is kept.';
      notifyListeners();
      return;
    }
    _playbackError = null;
    try {
      if (_nowPlaying?.path != recording.path) {
        await player.load(recording.path);
        // Re-applied rather than assumed: the interface promises the rate
        // survives a load, but a future implementation that resets it would
        // otherwise silently drop the listener's choice.
        await player.setSpeed(_playbackSpeed);
        _nowPlaying = recording;
      }
      await player.play();
    } on AudioPlayerException catch (e) {
      _nowPlaying = null;
      _playbackError = e.message;
    }
    notifyListeners();
  }

  /// Resumes what is loaded; does nothing when nothing is.
  Future<void> resumePlayback() async {
    final player = _player;
    if (player == null || _nowPlaying == null) return;
    try {
      await player.play();
    } on AudioPlayerException catch (e) {
      _playbackError = e.message;
    }
    notifyListeners();
  }

  Future<void> pausePlayback() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.pause();
    } on AudioPlayerException catch (e) {
      _playbackError = e.message;
    }
    notifyListeners();
  }

  Future<void> stopPlayback() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.stop();
    } on AudioPlayerException catch (e) {
      _playbackError = e.message;
    }
    _playback = PlaybackState(
      isPlaying: false,
      position: Duration.zero,
      duration: _playback.duration,
      path: _playback.path,
    );
    notifyListeners();
  }

  /// Play/pause on whatever is loaded, loading [recording] first if needed.
  Future<void> togglePlayback(RecordingInfo recording) {
    if (_nowPlaying?.path == recording.path && _playback.isPlaying) {
      return pausePlayback();
    }
    return playRecording(recording);
  }

  /// Changes the playback rate and keeps it for later recordings.
  ///
  /// Applied to the player immediately when one exists, and re-applied after
  /// every load, so the rate is not silently reset by opening another note.
  Future<void> setPlaybackSpeed(double speed) async {
    if (speed <= 0) return;
    _playbackSpeed = speed;
    notifyListeners();
    final player = _player;
    if (player == null) return;
    try {
      await player.setSpeed(speed);
    } on AudioPlayerException catch (e) {
      _playbackError = e.message;
      notifyListeners();
    }
  }

  Future<void> seekPlayback(Duration position) async {
    final player = _player;
    if (player == null || _nowPlaying == null) return;
    try {
      await player.seek(position < Duration.zero ? Duration.zero : position);
    } on AudioPlayerException catch (e) {
      _playbackError = e.message;
    }
    notifyListeners();
  }

  void _setPhase(AppPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    _setPhase(AppPhase.error);
  }

  /// Releases subscriptions, the recorder and the transport.
  ///
  /// `ChangeNotifier.dispose` is synchronous, so the async teardown is started
  /// here and awaited by [teardown] for callers (tests) that need to know when
  /// it finished.
  @override
  void dispose() {
    unawaited(teardown());
    super.dispose();
  }

  /// The awaitable half of [dispose].
  Future<void> teardown() async {
    _savingTimer?.cancel();
    _savingTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    await _stopContinuousSession(linkUp: false);
    _stopPowerRecheck();
    _stopWaitingForPower();
    await _transcription?.releaseEngine();
    await _modelDownloadSubscription?.cancel();
    _modelDownloadSubscription = null;
    _modelDownloads?.dispose();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await _availabilitySubscription?.cancel();
    _availabilitySubscription = null;
    await _batterySubscription?.cancel();
    _batterySubscription = null;
    await _temperatureSubscription?.cancel();
    _temperatureSubscription = null;
    await _testSubscription?.cancel();
    _testSubscription = null;
    await _linkSubscription?.cancel();
    _linkSubscription = null;
    await _statsSubscription?.cancel();
    _statsSubscription = null;
    await _levelSubscription?.cancel();
    _levelSubscription = null;
    await _librarySubscription?.cancel();
    _librarySubscription = null;
    await _playbackSubscription?.cancel();
    _playbackSubscription = null;
    await _linkMonitor.dispose();
    await _tests.dispose();
    await _recorder.dispose();
    await _library.dispose();
    await _player?.dispose();
    await _transport.dispose();
  }
}
