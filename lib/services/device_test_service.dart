import 'dart:async';
import 'dart:typed_data';

import '../drivers/ble_transport.dart';
import '../model/audio_codec.dart';
import '../model/device_state.dart';
import '../model/device_test_result.dart';
import '../model/recording_metadata.dart';
import '../model/stream_info.dart';
import 'codec/adpcm_decoder.dart';
import 'device_test_store.dart';
import 'frame_reassembler.dart';
import 'level_meter.dart';

/// Runs the five enclosure tests and saves what they measured.
///
/// WHY THIS IS A SERVICE. The tests are sequences - write a characteristic,
/// open a notify stream, count for three minutes, watch an advertising gap -
/// and none of that belongs in a widget. `view/` renders [phase], [elapsed] and
/// the saved [DeviceTestResult]s and calls the methods here; it never sees a
/// UUID and never touches BLE.
///
/// EVERY TEST ENDS IN A SAVED RESULT, including one that failed or was
/// cancelled. See `model/device_test_result.dart` for why.
///
/// THE FRAME SUBSCRIPTION IS EXCLUSIVE. `BleTransport.subscribeFrames` allows
/// one subscriber, so a test that streams cannot run while a recording is in
/// progress. The caller checks that (see `AppController.testBlocker`); this
/// class reports a failure rather than crashing if it is called anyway.
class DeviceTestService {
  /// Private initializing formals keep the public parameter names
  /// (`transport:`, `store:`) while assigning the private fields - the same
  /// shape [RecordingService] uses.
  DeviceTestService({
    required this._transport,
    required this._store,
    DateTime Function()? clock,
    Future<void> Function()? disconnectLink,
    this.noiseFloorWindow = const Duration(seconds: 10),
    this.sensitivityWindow = const Duration(seconds: 10),
    this.linkSoakWindow = const Duration(minutes: 3),
    this.advertisingPollWindow = const Duration(seconds: 8),
    this.systemOffConfirm = const Duration(seconds: 6),
    this.systemOffTimeout = const Duration(seconds: 90),
    this.wakeTimeout = const Duration(seconds: 30),
    this.tick = const Duration(milliseconds: 250),
  })  : _clock = clock ?? DateTime.now,
        // Cannot be `this._disconnectLink`: the parameter is optional and the
        // field is final, so the default has to be applied here.
        // ignore: prefer_initializing_formals
        _disconnectLink = disconnectLink;

  final BleTransport _transport;
  final DeviceTestStore _store;
  final DateTime Function() _clock;

  /// Ends the app's link. Supplied by the controller, because the link belongs
  /// to the controller: a service that disconnected behind its back would leave
  /// the rest of the app rendering a connection that is gone.
  ///
  /// Null means the wake test cannot run - it needs the device asleep, and the
  /// device will not sleep while the app is connected.
  final Future<void> Function()? _disconnectLink;

  final Duration noiseFloorWindow;
  final Duration sensitivityWindow;
  final Duration linkSoakWindow;

  /// How long one advertising poll listens before starting another.
  ///
  /// EIGHT SECONDS, NOT ONE, and the number is load-bearing twice over.
  ///
  /// Too short and the watch restarts the radio scan over and over: Android
  /// quietly throttles an app that calls `startScan` more than about five times
  /// in thirty seconds, and a throttled scan reports NOTHING - which this test
  /// would read as "the device has gone to sleep". A false System OFF is the
  /// worst failure available here, because everything after it is timed against
  /// a device that was never asleep.
  ///
  /// It is also kept just under `BleTransport.scanWindow`, so a poll never sits
  /// waiting on a scan stream that has already closed itself.
  final Duration advertisingPollWindow;

  /// How long the device must go unseen before it counts as asleep.
  ///
  /// One missed advertising packet is not sleep - the phone coalesces
  /// duplicates, the OS throttles background scans, and a packet can simply be
  /// lost. Several seconds of silence is the weakest claim worth making.
  final Duration systemOffConfirm;

  final Duration systemOffTimeout;
  final Duration wakeTimeout;

  /// How often [elapsed] is republished while a test runs.
  final Duration tick;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Fires whenever anything a screen renders changes.
  Stream<void> get changes => _changes.stream;

  DeviceTestKind? _running;
  DeviceTestPhase _phase = DeviceTestPhase.idle;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  CaptureStats _liveStats = const CaptureStats();
  List<DeviceTestStep> _steps = const <DeviceTestStep>[];
  String? _saveFailure;
  Timer? _ticker;
  Completer<void>? _cancelled;
  Completer<void>? _shaken;

  /// Which test is running, or `null`.
  DeviceTestKind? get running => _running;

  /// What the running test is waiting for.
  DeviceTestPhase get phase => _phase;

  /// How long the running test has been going.
  Duration get elapsed => _elapsed;

  /// Link counters accumulated by the running test.
  CaptureStats get liveStats => _liveStats;

  /// Stops taken so far in a range walk.
  List<DeviceTestStep> get steps => List.unmodifiable(_steps);

  /// Why the last result could not be written to disk, or `null`.
  ///
  /// Surfaced rather than swallowed: a test whose number was not saved has
  /// failed at the one thing this harness is for.
  String? get saveFailure => _saveFailure;

  bool get isRunning => _running != null;

  /// True once the saved history has been read.
  bool get isLoaded => _store.isLoaded;

  /// Every saved run, newest first.
  List<DeviceTestResult> get history => _store.results;

  /// Name of the file the history is kept in, for the screen to name it. The
  /// view asks the service rather than the store, so `view/` does not have to
  /// know how persistence is arranged.
  String get resultsFileName => _store.fileName;

  /// The most recent run of [kind], or `null` when there has never been one.
  DeviceTestResult? latestOf(DeviceTestKind kind) => _store.latestOf(kind);

  /// Reads the saved history. Safe to call more than once.
  Future<void> load() async {
    await _store.load();
    _notify();
  }

  /// Stops whatever is running. The partial readings are kept and saved.
  void cancel() {
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
  }

  /// The operator says they have just shaken the device. Starts the wake clock.
  void confirmShaken() {
    final shaken = _shaken;
    if (shaken != null && !shaken.isCompleted) shaken.complete();
  }

  /// Records a stop on the range walk: the live RSSI, and what the link
  /// delivered since the previous stop.
  Future<void> markRangeStep() async {
    if (_running != DeviceTestKind.range) return;
    final capture = _capture;
    if (capture == null) return;
    final previous = _steps.isEmpty
        ? const CaptureStats()
        : CaptureStats(
            framesReceived: _steps.fold(0, (a, s) => a + s.framesReceived),
            framesLost: _steps.fold(0, (a, s) => a + s.framesLost),
          );
    final now = capture.reassembler.stats;
    int? rssi;
    try {
      rssi = await _transport.readRssi(capture.deviceId);
    } on BleTransportException {
      // No reading is not a reading of zero. The stop is still worth having:
      // the frame counts are the half that cannot be argued with.
      rssi = null;
    }
    _steps = <DeviceTestStep>[
      ..._steps,
      DeviceTestStep(
        index: _steps.length + 1,
        rssiDbm: rssi,
        framesReceived: now.framesReceived - previous.framesReceived,
        framesLost: now.framesLost - previous.framesLost,
      ),
    ];
    _notify();
  }

  // -------------------------------------------------------------------------
  // 1 - RANGE
  //
  // RSSI ALONE MISLEADS. A link at -75 dBm can be flawless and a link at
  // -70 dBm can be shedding one frame in twenty, because what costs a notify
  // stream its packets is retries in a crowded band, not path loss alone. So
  // the walk records both at every stop, and the headline number is the signal
  // at the stop where frames FIRST went missing.
  // -------------------------------------------------------------------------

  /// Starts the range walk: opens the stream and begins counting.
  ///
  /// It does not finish on its own. The operator walks away in steps, tapping
  /// [markRangeStep] at each, and ends it with [finishRangeWalk] - which is the
  /// only shape that lets one person carry the phone and leave the device
  /// behind.
  Future<bool> beginRangeWalk({
    required String deviceId,
    required AudioCodec requestCodec,
  }) async {
    if (isRunning) return false;
    _begin(DeviceTestKind.range, DeviceTestPhase.walking);
    final capture = await _openCapture(
      deviceId: deviceId,
      requestCodec: requestCodec,
      measureAudio: false,
    );
    if (capture == null) {
      await _finish(
        DeviceTestResult(
          kind: DeviceTestKind.range,
          outcome: DeviceTestOutcome.failed,
          startedAt: _startedAt!,
          duration: _elapsed,
          note: _openFailure ?? 'the audio stream could not be started',
        ),
      );
      return false;
    }
    return true;
  }

  /// Ends the range walk and saves what the stops recorded.
  Future<DeviceTestResult?> finishRangeWalk() async {
    if (_running != DeviceTestKind.range) return null;
    // A final stop, so the last leg of the walk is measured too rather than
    // being thrown away with the subscription.
    await markRangeStep();
    final capture = _capture;
    final stats = capture?.reassembler.stats ?? const CaptureStats();
    final steps = _steps;
    final firstDrop = steps.where((s) => s.dropped).toList();
    final rssis = steps
        .map((s) => s.rssiDbm)
        .whereType<int>()
        .toList(growable: false);
    // Read at the END of the walk: the radio has been transmitting throughout,
    // so this is the die temperature the measurement was actually taken at.
    // With no capture there is nothing to ask, which is a null reading rather
    // than a guessed one.
    final die = capture == null
        ? const DeviceTestReading(
            label: DeviceTestReadings.dieTemperature,
            value: null,
            unit: '°C',
          )
        : await _dieReading(capture.deviceId);
    return _finish(
      DeviceTestResult(
        kind: DeviceTestKind.range,
        outcome: _wasCancelled
            ? DeviceTestOutcome.cancelled
            : DeviceTestOutcome.completed,
        startedAt: _startedAt!,
        duration: _elapsed,
        steps: steps,
        readings: <DeviceTestReading>[
          DeviceTestReading(
            label: DeviceTestReadings.stops,
            value: steps.length,
          ),
          DeviceTestReading(
            label: DeviceTestReadings.strongestRssi,
            value: rssis.isEmpty
                ? null
                : rssis.reduce((a, b) => a > b ? a : b),
            unit: 'dBm',
          ),
          DeviceTestReading(
            label: DeviceTestReadings.weakestRssi,
            value: rssis.isEmpty
                ? null
                : rssis.reduce((a, b) => a < b ? a : b),
            unit: 'dBm',
          ),
          // Null when nothing dropped - the best possible outcome, and it must
          // not render as 0 dBm.
          DeviceTestReading(
            label: DeviceTestReadings.rssiAtFirstDrop,
            value: firstDrop.isEmpty ? null : firstDrop.first.rssiDbm,
            unit: 'dBm',
          ),
          DeviceTestReading(
            label: DeviceTestReadings.framesReceived,
            value: stats.framesReceived,
          ),
          DeviceTestReading(
            label: DeviceTestReadings.framesLost,
            value: stats.framesLost,
          ),
          DeviceTestReading(
            label: DeviceTestReadings.lossPercent,
            value: stats.lossRatio * 100,
            unit: '%',
          ),
          die,
        ],
        note: firstDrop.isEmpty
            ? 'No frames went missing at any stop, so there is no range limit '
                'in this walk - only a floor on it.'
            : 'Frames first went missing at stop ${firstDrop.first.index}.',
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 2 - ACOUSTIC
  //
  // THE ONE THAT MATTERS MOST. The enclosure puts plastic between a voice and
  // a MEMS microphone, and a bad port degrades a recording quietly - nothing
  // fails, the words just get harder to make out. Two numbers catch it:
  //
  //   * the noise floor, which is where a rattle, a resonance, or the case
  //     coupling vibration into the microphone shows up, and
  //   * the sensitivity, which is what the port itself costs.
  //
  // Both are measured over the WHOLE window in the linear domain - see
  // `LevelWindow` for why averaging dBFS would under-report a transient.
  // -------------------------------------------------------------------------

  /// Ten seconds of a quiet room.
  Future<DeviceTestResult?> runNoiseFloor({
    required String deviceId,
    required AudioCodec requestCodec,
  }) =>
      _runAcoustic(
        kind: DeviceTestKind.noiseFloor,
        deviceId: deviceId,
        requestCodec: requestCodec,
        window: noiseFloorWindow,
        note: 'Recorded in a quiet room with nothing touching the device. A '
            'noise floor that rose after the enclosure went on is the case '
            'itself - a rattle, a resonance, or vibration coupling into the '
            'microphone.',
      );

  /// A voice at [sensitivityDistanceCm], which is what the port costs.
  Future<DeviceTestResult?> runSensitivity({
    required String deviceId,
    required AudioCodec requestCodec,
  }) =>
      _runAcoustic(
        kind: DeviceTestKind.sensitivity,
        deviceId: deviceId,
        requestCodec: requestCodec,
        window: sensitivityWindow,
        note: 'Spoken at ${DeviceTestReadings.sensitivityDistanceCm} cm from the '
            'microphone port, '
            'at a normal speaking level. Comparable between runs only because '
            'the distance is fixed - move it and the numbers mean nothing.',
      );

  Future<DeviceTestResult?> _runAcoustic({
    required DeviceTestKind kind,
    required String deviceId,
    required AudioCodec requestCodec,
    required Duration window,
    required String note,
  }) async {
    if (isRunning) return null;
    _begin(kind, DeviceTestPhase.measuring);
    final capture = await _openCapture(
      deviceId: deviceId,
      requestCodec: requestCodec,
      measureAudio: true,
    );
    if (capture == null) {
      return _finish(
        DeviceTestResult(
          kind: kind,
          outcome: _openWasUnavailable
              ? DeviceTestOutcome.unavailable
              : DeviceTestOutcome.failed,
          startedAt: _startedAt!,
          duration: _elapsed,
          note: _openFailure ?? 'the audio stream could not be started',
        ),
      );
    }

    await _wait(window);

    final level = capture.level;
    final measured = level != null && level.hasAudio;
    final die = await _dieReading(deviceId);
    return _finish(
      DeviceTestResult(
        kind: kind,
        outcome: !measured
            ? DeviceTestOutcome.failed
            : _wasCancelled
                ? DeviceTestOutcome.cancelled
                : DeviceTestOutcome.completed,
        startedAt: _startedAt!,
        duration: _elapsed,
        readings: <DeviceTestReading>[
          DeviceTestReading(
            label: kind == DeviceTestKind.noiseFloor
                ? DeviceTestReadings.noiseFloorRms
                : DeviceTestReadings.rms,
            value: level?.rmsDbfs,
            unit: 'dBFS',
          ),
          DeviceTestReading(
            label: DeviceTestReadings.peak,
            value: level?.peakDbfs,
            unit: 'dBFS',
          ),
          DeviceTestReading(
            label: DeviceTestReadings.audioMeasured,
            value: level == null
                ? null
                : level.sampleCount / capture.info.sampleRateHz,
            unit: 's',
          ),
          DeviceTestReading(
            label: DeviceTestReadings.framesLost,
            value: capture.stats.framesLost,
          ),
          die,
        ],
        note: measured
            ? note
            : 'No audio arrived in ${window.inSeconds} s, so there is no '
                'level to report. A silent stream is not a quiet room.',
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 3 - LINK SOAK
  //
  // Enclosure RF problems are usually intermittent, not absolute: the link
  // comes up, works, and then sheds a burst of frames when a hand moves or the
  // band gets busy. An instant reading cannot see that, so this one runs for
  // minutes and counts both the frames that went missing and the times the
  // link went away entirely.
  // -------------------------------------------------------------------------

  Future<DeviceTestResult?> runLinkSoak({
    required String deviceId,
    required AudioCodec requestCodec,
    Duration? window,
  }) async {
    if (isRunning) return null;
    final soak = window ?? linkSoakWindow;
    _begin(DeviceTestKind.linkSoak, DeviceTestPhase.measuring);
    final capture = await _openCapture(
      deviceId: deviceId,
      requestCodec: requestCodec,
      measureAudio: false,
    );
    if (capture == null) {
      return _finish(
        DeviceTestResult(
          kind: DeviceTestKind.linkSoak,
          outcome: DeviceTestOutcome.failed,
          startedAt: _startedAt!,
          duration: _elapsed,
          note: _openFailure ?? 'the audio stream could not be started',
        ),
      );
    }

    var drops = 0;
    StreamSubscription<BleConnectionStatus>? link;
    final lost = Completer<void>();
    try {
      link = _transport.connectionState(deviceId).listen((status) {
        if (status != BleConnectionStatus.disconnected) return;
        drops++;
        // The app does not reconnect by itself, so the soak cannot continue -
        // and stopping here is the honest thing: a run that spent two of its
        // three minutes disconnected is not a three-minute soak.
        if (!lost.isCompleted) lost.complete();
      });
    } on Object {
      // A transport that will not report link state still lets the soak count
      // frames; it just cannot count disconnections. Reported as unknown below.
      link = null;
    }

    await _wait(soak, alsoEndOn: link == null ? null : lost.future);
    await link?.cancel();

    final stats = capture.stats;
    final endedEarly = drops > 0;
    // Minutes of notify traffic is the hottest this device gets, so this is the
    // figure worth comparing before and after the case went on.
    final die = await _dieReading(deviceId);
    return _finish(
      DeviceTestResult(
        kind: DeviceTestKind.linkSoak,
        outcome: endedEarly
            ? DeviceTestOutcome.failed
            : _wasCancelled
                ? DeviceTestOutcome.cancelled
                : DeviceTestOutcome.completed,
        startedAt: _startedAt!,
        duration: _elapsed,
        readings: <DeviceTestReading>[
          DeviceTestReading(
            label: DeviceTestReadings.soaked,
            value: _elapsed.inMilliseconds / 1000,
            unit: 's',
          ),
          DeviceTestReading(
            label: DeviceTestReadings.framesReceived,
            value: stats.framesReceived,
          ),
          DeviceTestReading(
            label: DeviceTestReadings.framesLost,
            value: stats.framesLost,
          ),
          DeviceTestReading(
            label: DeviceTestReadings.lossPercent,
            value: stats.lossRatio * 100,
            unit: '%',
          ),
          // Null, not zero, when the platform would not report link state:
          // "no disconnections" and "we could not tell" are different facts.
          DeviceTestReading(
            label: DeviceTestReadings.disconnections,
            value: link == null ? null : drops,
          ),
          DeviceTestReading(
            label: DeviceTestReadings.malformedFrames,
            value: stats.malformedFrames,
          ),
          die,
        ],
        note: endedEarly
            ? 'The link went away after ${_elapsed.inSeconds} s of a '
                '${soak.inSeconds} s soak. That is the result: an enclosure '
                'that drops the link intermittently is what this test looks '
                'for.'
            : 'Streamed for ${_elapsed.inSeconds} s without the link going '
                'away. Frames lost are counted from gaps in the fe01 sequence '
                'number, so they are frames the device sent and the phone '
                'never received.',
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 4 - WAKE ON MOTION
  //
  // The enclosure adds mass and damping, so a shake that used to cross the
  // IMU's threshold may no longer. The sequence is: enable auto-sleep, drop the
  // link (the device will not sleep while the app is connected), watch it stop
  // advertising - which is System OFF - then time from the operator's shake to
  // the next advertising packet.
  //
  // WHAT THE NUMBER IS AND IS NOT. It includes the phone's own scan-discovery
  // latency, which is not small and not constant, so it is not a measurement of
  // IMU latency. Treat it as a coarse figure and a yes/no: did a shake wake it
  // at all, and did that get dramatically worse once the case went on. The
  // caveat travels with the result rather than living only in this comment.
  // -------------------------------------------------------------------------

  /// Runs the wake test end to end. Needs [confirmShaken] partway through.
  Future<DeviceTestResult?> runWakeOnMotion({required String deviceId}) async {
    if (isRunning) return null;
    final disconnect = _disconnectLink;
    _begin(DeviceTestKind.wakeOnMotion, DeviceTestPhase.waitingForSystemOff);
    if (disconnect == null) {
      return _finish(
        DeviceTestResult.unavailable(
          kind: DeviceTestKind.wakeOnMotion,
          at: _startedAt!,
          because: 'this build cannot end the link, and the device will not '
              'sleep while the app is connected',
        ),
      );
    }

    try {
      await _transport.setAutoSleep(deviceId, true);
    } on BleTransportException catch (e) {
      return _finish(
        DeviceTestResult.unavailable(
          kind: DeviceTestKind.wakeOnMotion,
          at: _startedAt!,
          because: 'auto-sleep could not be enabled: ${e.message}',
        ),
      );
    }

    // Read BEFORE the link goes. Afterwards the device is asleep and then
    // freshly awake, and there is no characteristic to read either way.
    final die = await _dieReading(deviceId);

    // The link is the thing keeping it awake, so it goes first.
    await disconnect();

    final asleep = await _watchAdvertising(
      deviceId: deviceId,
      untilSeen: false,
      timeout: systemOffTimeout,
    );
    if (_wasCancelled) return _finishCancelledWake();
    if (!asleep) {
      return _finish(
        DeviceTestResult(
          kind: DeviceTestKind.wakeOnMotion,
          outcome: DeviceTestOutcome.failed,
          startedAt: _startedAt!,
          duration: _elapsed,
          note: 'The device was still advertising after '
              '${systemOffTimeout.inSeconds} s, so it never reached System '
              'OFF and there was nothing to wake. Check that auto-sleep is '
              'enabled and that nothing is moving it.',
        ),
      );
    }

    _setPhase(DeviceTestPhase.waitingForShake);
    final shaken = Completer<void>();
    _shaken = shaken;
    await _either(shaken.future);
    if (_wasCancelled) return _finishCancelledWake();

    // The clock starts at the operator's tap, not at the prompt: a prompt-based
    // clock measures their reaction time as well as the device's.
    final shookAt = _clock();
    _setPhase(DeviceTestPhase.waitingForWake);
    final woke = await _watchAdvertising(
      deviceId: deviceId,
      untilSeen: true,
      timeout: wakeTimeout,
    );
    final took = _clock().difference(shookAt);

    return _finish(
      DeviceTestResult(
        kind: DeviceTestKind.wakeOnMotion,
        outcome: _wasCancelled
            ? DeviceTestOutcome.cancelled
            : woke
                ? DeviceTestOutcome.completed
                : DeviceTestOutcome.failed,
        startedAt: _startedAt!,
        duration: _elapsed,
        readings: <DeviceTestReading>[
          // Null when it never woke. A timeout is not a wake time.
          DeviceTestReading(
            label: DeviceTestReadings.wakeDelay,
            value: woke ? took.inMilliseconds / 1000 : null,
            unit: 's',
          ),
          die,
        ],
        note: woke
            ? 'Advertising again ${(took.inMilliseconds / 1000).toStringAsFixed(1)} s '
                'after the shake. This figure includes the phone’s own '
                'scan-discovery latency, which is neither small nor constant, '
                'so compare orders of magnitude and not tenths of a second.'
            : 'A shake did NOT bring it back inside ${wakeTimeout.inSeconds} s. '
                'If an identical shake woke it before the enclosure went on, '
                'the case’s mass and damping are keeping the IMU below '
                'its threshold.',
      ),
    );
  }

  Future<DeviceTestResult?> _finishCancelledWake() => _finish(
        DeviceTestResult(
          kind: DeviceTestKind.wakeOnMotion,
          outcome: DeviceTestOutcome.cancelled,
          startedAt: _startedAt!,
          duration: _elapsed,
          note: 'Stopped before the device had woken. Auto-sleep was left '
              'enabled on the device - it is kept in flash, so reconnect and '
              'turn it off if that is not wanted.',
        ),
      );

  // -------------------------------------------------------------------------
  // Machinery.
  // -------------------------------------------------------------------------

  _Capture? _capture;
  String? _openFailure;

  /// True when [_openFailure] means "this device cannot answer the question",
  /// as against "something went wrong". Firmware with no `fe02` is the first;
  /// a capture already holding the exclusive frame subscription is the second,
  /// and they are different results.
  bool _openWasUnavailable = false;

  void _begin(DeviceTestKind kind, DeviceTestPhase phase) {
    _running = kind;
    _phase = phase;
    _startedAt = _clock();
    _elapsed = Duration.zero;
    _liveStats = const CaptureStats();
    _steps = const <DeviceTestStep>[];
    _saveFailure = null;
    _openFailure = null;
    _openWasUnavailable = false;
    _cancelled = Completer<void>();
    _shaken = null;
    _ticker?.cancel();
    _ticker = Timer.periodic(tick, (_) {
      final started = _startedAt;
      if (started == null) return;
      _elapsed = _clock().difference(started);
      _liveStats = _capture?.reassembler.stats ?? _liveStats;
      _notify();
    });
    _notify();
  }

  void _setPhase(DeviceTestPhase phase) {
    _phase = phase;
    _notify();
  }

  bool get _wasCancelled => _cancelled?.isCompleted ?? false;

  /// Saves [result], clears the running state and returns what was saved.
  Future<DeviceTestResult> _finish(DeviceTestResult result) async {
    _setPhase(DeviceTestPhase.saving);
    final started = _startedAt;
    final finished = result.duration == Duration.zero && started != null
        ? DeviceTestResult(
            kind: result.kind,
            outcome: result.outcome,
            startedAt: result.startedAt,
            duration: _clock().difference(started),
            readings: result.readings,
            steps: result.steps,
            note: result.note,
          )
        : result;

    await _closeCapture();
    _ticker?.cancel();
    _ticker = null;

    try {
      await _store.append(finished);
    } on Object catch (error) {
      // The measurement happened; the record of it did not. Said out loud,
      // because a harness whose numbers vanish is worse than no harness.
      _saveFailure = 'the result could not be saved: $error';
    }

    _running = null;
    _phase = DeviceTestPhase.idle;
    _startedAt = null;
    _cancelled = null;
    _shaken = null;
    _notify();
    return finished;
  }

  /// The die temperature right now, as a reading.
  ///
  /// STAMPED ON EVERY RUN, and not because anyone asked for a thermometer: the
  /// enclosure puts a LiPo cell under the board and plastic around both, and
  /// the chip that measures this is the one doing the work. A noise floor or a
  /// loss figure that got worse is worth a great deal more when the die
  /// temperature it was taken at is written next to it.
  ///
  /// Null value, never zero, when the device has no `fe07` or reports
  /// `0x8000` - a reading of 0 °C on a self-heating die would be absurd, and
  /// absurd numbers get averaged into real ones.
  Future<DeviceTestReading> _dieReading(String deviceId) async {
    double? celsius;
    try {
      celsius = (await _transport.readDieTemperature(deviceId)).celsius;
    } on BleTransportException {
      celsius = null;
    }
    return DeviceTestReading(
      label: DeviceTestReadings.dieTemperature,
      value: celsius,
      unit: '°C',
    );
  }

  /// Opens the audio stream, or returns null having set [_openFailure].
  Future<_Capture?> _openCapture({
    required String deviceId,
    required AudioCodec requestCodec,
    required bool measureAudio,
  }) async {
    try {
      await _transport.selectCodec(deviceId, requestCodec);
    } on BleTransportException catch (e) {
      _openFailure = 'the codec could not be selected: ${e.message}';
      return null;
    }

    StreamInfo info;
    try {
      info = await _transport.readStreamInfo(deviceId);
    } on BleTransportException {
      if (measureAudio) {
        // A level computed from bytes decoded as the wrong codec is not a
        // quiet number, it is a WRONG one, and it would be compared against
        // next week's run as though it meant something. Refused instead.
        _openWasUnavailable = true;
        _openFailure = 'the device did not report its stream format, so the '
            'audio cannot be decoded and any level from it would be invented';
        return null;
      }
      // Counting frames needs no codec at all.
      info = StreamInfo.fallback;
    }
    if (measureAudio && (info.codec == null || info.bitsPerSample != 16)) {
      _openWasUnavailable = true;
      _openFailure = 'the device reported a format this build cannot decode '
          '(${info.toString()})';
      return null;
    }

    final capture = _Capture(
      deviceId: deviceId,
      info: info,
      measureAudio: measureAudio,
    );
    try {
      capture.frames = _transport.subscribeFrames(deviceId).listen(
            capture.accept,
            onError: (Object error) => capture.error ??= error,
          );
    } on BleTransportException catch (e) {
      // The exclusive frame subscription - a capture is already running.
      _openFailure = e.message;
      return null;
    }
    _capture = capture;
    return capture;
  }

  Future<void> _closeCapture() async {
    final capture = _capture;
    _capture = null;
    if (capture == null) return;
    _liveStats = capture.reassembler.stats;
    await capture.frames?.cancel();
    try {
      await _transport.unsubscribeFrames(capture.deviceId);
    } on BleTransportException {
      // The notifications have stopped either way.
    }
  }

  /// Waits [window], or until the test is cancelled, or until [alsoEndOn].
  ///
  /// The timer is ALWAYS cancelled on the way out. A pending timer outliving
  /// the test is how a cancelled soak keeps a screen awake for three minutes.
  Future<void> _wait(Duration window, {Future<void>? alsoEndOn}) async {
    final done = Completer<void>();
    final timer = Timer(window, () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _either(done.future, alsoEndOn);
    } finally {
      timer.cancel();
    }
  }

  /// Waits for the first of [first], [second] or cancellation.
  Future<void> _either(Future<void> first, [Future<void>? second]) {
    final cancelled = _cancelled;
    return Future.any(<Future<void>>[first, ?second, ?cancelled?.future]);
  }

  /// Polls advertising until [deviceId] is seen ([untilSeen] true) or has been
  /// unseen for [systemOffConfirm] ([untilSeen] false).
  ///
  /// ABSENCE IS WEAK EVIDENCE, which is why the not-seen case needs several
  /// seconds of silence rather than one empty poll: the phone coalesces
  /// duplicate advertising packets, the OS throttles scanning, and a single
  /// packet can simply be lost. This is the strongest claim the radio allows.
  Future<bool> _watchAdvertising({
    required String deviceId,
    required bool untilSeen,
    required Duration timeout,
  }) async {
    final deadline = _clock().add(timeout);
    var lastSeen = _clock();
    while (true) {
      if (_wasCancelled) return false;
      if (!_clock().isBefore(deadline)) return false;
      // NOT `returnOnSight` while waiting for silence. Ending the poll the
      // instant the device is seen turns this loop into a spin that restarts
      // the radio scan thousands of times a second - which is both the busiest
      // possible way to wait and the fastest way to get the scan throttled.
      final seen = await _pollAdvertising(deviceId, returnOnSight: untilSeen);
      if (_wasCancelled) return false;
      if (seen) {
        if (untilSeen) return true;
        lastSeen = _clock();
      } else if (!untilSeen &&
          _clock().difference(lastSeen) >= systemOffConfirm) {
        return true;
      }
    }
  }

  /// One scan window: true when [deviceId] advertised inside it.
  ///
  /// The window is bounded by [advertisingPollWindow] and by nothing else - a
  /// scan stream that closes or errors early does NOT shorten it, because a
  /// poll that can return instantly is a poll that can be called in a tight
  /// loop. With [returnOnSight] the poll ends the moment the device is seen,
  /// which is what the wake measurement wants and the silence watch must not
  /// have.
  Future<bool> _pollAdvertising(
    String deviceId, {
    required bool returnOnSight,
  }) async {
    var seen = false;
    final sighted = Completer<void>();
    final windowOver = Completer<void>();
    StreamSubscription<DiscoveredDevice>? subscription;
    try {
      subscription = _transport.scan().listen(
        (device) {
          if (device.id != deviceId) return;
          seen = true;
          if (!sighted.isCompleted) sighted.complete();
        },
        // A scan that fails is not a sighting. It is also not proof of absence,
        // which is why the caller needs several empty windows in a row.
        onError: (Object _) {},
      );
    } on Object {
      return false;
    }
    final timer = Timer(advertisingPollWindow, () {
      if (!windowOver.isCompleted) windowOver.complete();
    });
    final cancelled = _cancelled;
    try {
      await Future.any<void>(<Future<void>>[
        windowOver.future,
        if (returnOnSight) sighted.future,
        ?cancelled?.future,
      ]);
    } finally {
      timer.cancel();
      await subscription.cancel();
      try {
        await _transport.stopScan();
      } on BleTransportException {
        // The window is over whether or not the radio agreed to stop.
      }
    }
    return seen;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    cancel();
    _ticker?.cancel();
    _ticker = null;
    await _closeCapture();
    await _changes.close();
  }
}

/// One open audio stream, with the counters and the level window that read it.
class _Capture {
  _Capture({
    required this.deviceId,
    required this.info,
    required this.measureAudio,
  });

  final String deviceId;
  final StreamInfo info;

  /// False for the link tests, which count frames and never decode them - so
  /// they work whatever codec the device is in, and cost nothing per frame.
  final bool measureAudio;

  final FrameReassembler reassembler = FrameReassembler();
  StreamSubscription<Uint8List>? frames;
  Object? error;

  late final LevelWindow? _window = measureAudio ? LevelWindow() : null;

  LevelWindow? get level => _window;

  CaptureStats get stats => reassembler.stats;

  void accept(Uint8List notification) {
    final frame = reassembler.accept(notification);
    if (frame == null || !measureAudio) return;
    final codec = info.codec;
    if (codec == null) return;
    final pcm = switch (codec) {
      AudioCodec.pcmS16le => frame.payload,
      AudioCodec.imaAdpcm =>
        AdpcmDecoder.decodeBlockToPcmBytes(frame.payload),
    };
    _window?.addPcmS16le(pcm);
  }
}
