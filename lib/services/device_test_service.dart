import 'dart:async';
import 'dart:typed_data';

import '../drivers/ble_transport.dart';
import '../model/audio_codec.dart';
import '../model/device_test_aggregate.dart';
import '../model/device_test_result.dart';
import '../model/recording_metadata.dart';
import '../model/stream_info.dart';
import 'codec/frame_decoder.dart';
import 'codec/stream_decoder.dart';
import 'device_test_store.dart';
import 'frame_reassembler.dart';
import 'level_meter.dart';

/// Runs the mic check and saves what it measured.
///
/// WHY THIS IS A SERVICE. A check is a sequence - write a characteristic, open a
/// notify stream, measure a level for ten seconds, save - and none of that
/// belongs in a widget. `view/` renders [phase], [elapsed] and the saved
/// [DeviceTestResult]s and calls the methods here; it never sees a UUID and
/// never touches BLE.
///
/// WHAT IS LEFT, AND WHY IT IS ONLY TWO THINGS. The noise floor and the
/// sensitivity are the two measurements the enclosure can hurt SILENTLY: nothing
/// fails, the recording just gets harder to make out. Everything the link does
/// is observable live, which is what `services/link_monitor.dart` now does, so
/// the range walk and the link soak are gone. So is wake-on-motion - see the
/// library comment of `model/device_test_result.dart` for why none of the three
/// earned its place.
///
/// EVERY CHECK ENDS IN A SAVED RESULT, including one that failed or was
/// cancelled. See `model/device_test_result.dart` for why.
///
/// THE FRAME SUBSCRIPTION IS EXCLUSIVE. `BleTransport.subscribeFrames` allows
/// one subscriber, so a check cannot run while a recording is in progress, or
/// while the live link view holds it. The caller checks the first (see
/// `AppController.testBlocker`) and stands the second down before starting;
/// this class reports a failure rather than crashing if it is called anyway.
///
/// EVERY CHECK IS RUN MORE THAN ONCE. Both measurements are noisy, so one
/// reading before the enclosure and one after cannot be compared - see
/// `model/device_test_aggregate.dart`. Each `run…` method therefore takes a
/// `repeats` count and collects a BATCH of samples under one
/// [DeviceTestResult.batchId] - the counts the app actually uses, and why they
/// differ per check, are in [DeviceTestSampling]. The noise floor repeats
/// unattended; sensitivity
/// needs somebody to speak, so it waits between samples in
/// [DeviceTestPhase.awaitingNextSample] for [continueBatch] - or [endBatch],
/// which keeps every sample taken so far.
class DeviceTestService {
  /// Private initializing formals keep the public parameter names
  /// (`transport:`, `store:`) while assigning the private fields - the same
  /// shape [RecordingService] uses.
  DeviceTestService({
    required this._transport,
    required this._store,
    DateTime Function()? clock,
    this.noiseFloorWindow = const Duration(seconds: 10),
    this.sensitivityWindow = const Duration(seconds: 10),
    this.tick = const Duration(milliseconds: 250),
    this._decoders = const FrameDecoders(),
  }) : _clock = clock ?? DateTime.now;

  final BleTransport _transport;
  final DeviceTestStore _store;
  final DateTime Function() _clock;

  /// Where a decoder for the stream's codec comes from. Each `_Capture` owns
  /// one and closes it, so a check that runs Opus does not leave native state
  /// behind between samples.
  final FrameDecoders _decoders;

  final Duration noiseFloorWindow;
  final Duration sensitivityWindow;

  /// How often [elapsed] is republished while a check runs.
  final Duration tick;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Fires whenever anything a screen renders changes.
  Stream<void> get changes => _changes.stream;

  DeviceTestKind? _running;
  DeviceTestPhase _phase = DeviceTestPhase.idle;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  CaptureStats _liveStats = const CaptureStats();
  String? _saveFailure;
  Timer? _ticker;
  Completer<void>? _cancelled;

  /// Which check is running, or `null`.
  DeviceTestKind? get running => _running;

  /// What the running check is waiting for.
  DeviceTestPhase get phase => _phase;

  /// How long the running check has been going.
  Duration get elapsed => _elapsed;

  /// Link counters accumulated by the running check.
  CaptureStats get liveStats => _liveStats;

  /// Why the last result could not be written to disk, or `null`.
  ///
  /// Surfaced rather than swallowed: a check whose number was not saved has
  /// failed at the one thing the saved history is for.
  String? get saveFailure => _saveFailure;

  bool get isRunning => _running != null;

  /// True once the saved history has been read.
  bool get isLoaded => _store.isLoaded;

  /// Every saved run this build can read, newest first.
  List<DeviceTestResult> get history => _store.results;

  /// Rows in the saved file this build does not read - runs of a retired
  /// measurement, and anything a newer build wrote.
  ///
  /// They are kept in the file untouched. Surfaced so the screen can account for
  /// the difference between the file's size and the history it shows, rather than
  /// looking as though runs were thrown away.
  int get unreadRunCount => _store.unreadRunCount;

  /// Every saved batch of [kind], newest first - what the screen compares.
  List<DeviceTestBatch> batchesOf(DeviceTestKind kind) =>
      _store.batchesOf(kind);

  // -------------------------------------------------------------------------
  // The running batch.
  // -------------------------------------------------------------------------

  String? _batchId;
  DeviceTestKind? _batchKind;
  int _batchTarget = 1;
  int _batchDone = 0;
  bool _batchStopped = false;
  String? _batchDeviceId;
  AudioCodec? _batchCodec;

  /// Distinguishes two batches started in the same microsecond, which only an
  /// injected clock can manage but a test WILL.
  int _batchSequence = 0;

  /// True from the first sample of a batch until the last one is saved -
  /// INCLUDING while a prompted batch waits for the operator, when [running] is
  /// null. The caller uses it to keep the other check out; see
  /// `AppController.testBlocker`.
  bool get isBatchActive => _batchKind != null;

  /// Which check the running batch belongs to, or null.
  DeviceTestKind? get batchKind => _batchKind;

  /// Samples the running batch was asked for.
  int get batchTarget => _batchTarget;

  /// Samples of the running batch that are saved. NEVER discarded when a batch
  /// ends early: three samples labelled n=3 beat five samples thrown away.
  int get samplesTaken => _batchDone;

  /// 1-based number of the sample now running, or of the one next up.
  int get sampleNumber => _batchDone + 1;

  /// True when a batch is between samples, waiting for the operator to be ready
  /// for the next one.
  bool get awaitingNextSample =>
      _batchKind != null && _phase == DeviceTestPhase.awaitingNextSample;

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
  ///
  /// In a batch it stops the BATCH as well as the sample: the operator pressed
  /// stop, and starting the next sample of five would ignore them. Everything
  /// already saved stays saved.
  void cancel() {
    if (_batchKind != null) _batchStopped = true;
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    // A batch waiting for the operator has no sample to cancel, so there is
    // nothing that will come back and end it. Ended here, or the screen sits
    // asking for a sample nobody is going to give it.
    if (_running == null && _batchKind != null) _endBatch();
  }

  /// Abandons the samples a batch has not taken yet and keeps the ones it has.
  ///
  /// This is "stop at three of five" and it is a FIRST-CLASS OUTCOME, not a
  /// failure: the batch is saved as n=3 of 5 and the screen says it was stopped
  /// early. Nothing measured is thrown away.
  void endBatch() {
    if (_batchKind == null) return;
    _batchStopped = true;
    if (_running != null) {
      cancel();
      return;
    }
    _endBatch();
  }

  /// The operator is ready for the next sample of a prompted batch.
  ///
  /// Does nothing unless a batch is actually waiting - a double tap cannot start
  /// two samples, and this is never the way to start a batch.
  Future<DeviceTestResult?> continueBatch() async {
    if (_batchKind == null ||
        _running != null ||
        _phase != DeviceTestPhase.awaitingNextSample) {
      return null;
    }
    final result = await _runSample();
    _afterSample(failed: _endsTheBatch(result));
    return result;
  }

  // -------------------------------------------------------------------------
  // THE MIC CHECK
  //
  // The enclosure puts plastic between a voice and a MEMS microphone, and a bad
  // port degrades a recording quietly - nothing fails, the words just get harder
  // to make out. Two numbers catch it:
  //
  //   * the noise floor, which is where a rattle, a resonance, or the case
  //     coupling vibration into the microphone shows up, and
  //   * the sensitivity, which is what the port itself costs.
  //
  // Both are measured over the WHOLE window in the linear domain - see
  // `LevelWindow` for why averaging dBFS would under-report a transient.
  // -------------------------------------------------------------------------

  static const String _noiseFloorNote =
      'Recorded in a quiet room with nothing touching the device. A '
      'noise floor that rose after the enclosure went on is the case '
      'itself - a rattle, a resonance, or vibration coupling into the '
      'microphone.';

  static const String _sensitivityNote =
      'Spoken at ${DeviceTestReadings.sensitivityDistanceCm} cm from the '
      'microphone port, '
      'at a normal speaking level. Comparable between runs only because '
      'the distance is fixed - move it and the numbers mean nothing.';

  /// Ten seconds of a quiet room, [repeats] times over.
  ///
  /// Repeats UNATTENDED: the operator's only job is to leave the room alone, and
  /// they can do that for fifty seconds as easily as ten.
  Future<DeviceTestResult?> runNoiseFloor({
    required String deviceId,
    required AudioCodec requestCodec,
    int repeats = 1,
  }) async {
    if (isRunning || isBatchActive) return null;
    _beginBatch(
      DeviceTestKind.noiseFloor,
      repeats,
      deviceId: deviceId,
      requestCodec: requestCodec,
    );
    return _runAutomaticBatch();
  }

  /// A voice at [DeviceTestReadings.sensitivityDistanceCm], [repeats] times.
  ///
  /// Each sample is PROMPTED, because each one needs somebody to be there
  /// speaking at the marked distance. Looping this unattended would record
  /// silence and report it as a quiet voice.
  Future<DeviceTestResult?> runSensitivity({
    required String deviceId,
    required AudioCodec requestCodec,
    int repeats = 1,
  }) async {
    if (isRunning || isBatchActive) return null;
    _beginBatch(
      DeviceTestKind.sensitivity,
      repeats,
      deviceId: deviceId,
      requestCodec: requestCodec,
    );
    final result = await _runSample();
    _afterSample(failed: _endsTheBatch(result));
    return result;
  }

  Future<DeviceTestResult?> _runAcoustic({
    required DeviceTestKind kind,
    required String deviceId,
    required AudioCodec requestCodec,
    required Duration window,
    required String note,
  }) async {
    _begin(kind, DeviceTestPhase.measuring);
    final capture = await _openCapture(
      deviceId: deviceId,
      requestCodec: requestCodec,
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
    final measured = level.hasAudio;
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
            value: level.rmsDbfs,
            unit: 'dBFS',
          ),
          DeviceTestReading(
            label: DeviceTestReadings.peak,
            value: level.peakDbfs,
            unit: 'dBFS',
          ),
          DeviceTestReading(
            label: DeviceTestReadings.audioMeasured,
            value: level.sampleCount / capture.info.sampleRateHz,
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
  // Batch machinery.
  //
  // A batch is n samples of one check saved under one id. The two rules it keeps
  // are: NOTHING MEASURED IS DISCARDED, whether the batch finished or not; and a
  // batch stops asking for more samples the moment the answer stopped being
  // measurable.
  // -------------------------------------------------------------------------

  void _beginBatch(
    DeviceTestKind kind,
    int repeats, {
    required String deviceId,
    required AudioCodec requestCodec,
  }) {
    _batchKind = kind;
    _batchTarget = repeats < 1 ? 1 : repeats;
    _batchDone = 0;
    _batchStopped = false;
    _batchDeviceId = deviceId;
    _batchCodec = requestCodec;
    _batchId = '${kind.wireName}-'
        '${_clock().microsecondsSinceEpoch}-${_batchSequence++}';
    _notify();
  }

  void _endBatch() {
    if (_batchKind == null) return;
    _batchKind = null;
    _batchId = null;
    _batchDeviceId = null;
    _batchCodec = null;
    _batchStopped = false;
    if (_phase == DeviceTestPhase.awaitingNextSample) {
      _phase = DeviceTestPhase.idle;
    }
    _notify();
  }

  /// Whether [result] means the batch should stop asking for samples.
  ///
  /// A FAILED OR UNAVAILABLE SAMPLE ENDS THE BATCH, and deliberately: those two
  /// outcomes mean the conditions the check needs have gone - the link went
  /// away, the firmware cannot say what it is streaming - and four more attempts
  /// would fill the history with identical non-measurements. What is already
  /// collected is kept and labelled partial, and the failure is one of the saved
  /// samples, so the reason is not lost.
  bool _endsTheBatch(DeviceTestResult? result) =>
      result == null ||
      result.outcome == DeviceTestOutcome.failed ||
      result.outcome == DeviceTestOutcome.unavailable;

  /// Counts a finished sample and decides what happens next.
  void _afterSample({required bool failed}) {
    if (_batchKind == null) return;
    _batchDone++;
    if (failed || _batchStopped || _batchDone >= _batchTarget) {
      _endBatch();
      return;
    }
    _setPhase(DeviceTestPhase.awaitingNextSample);
  }

  /// Takes every sample of a batch that needs nobody present.
  Future<DeviceTestResult?> _runAutomaticBatch() async {
    DeviceTestResult? last;
    while (true) {
      last = await _runSample();
      // Counted AFTER the sample is saved: `_finish` stamps the sample number
      // from this field.
      _batchDone++;
      if (_endsTheBatch(last) || _batchStopped || _batchDone >= _batchTarget) {
        break;
      }
    }
    _endBatch();
    return last;
  }

  /// One sample of the running batch, whichever check it is.
  Future<DeviceTestResult?> _runSample() async {
    final kind = _batchKind!;
    final deviceId = _batchDeviceId!;
    return switch (kind) {
      DeviceTestKind.noiseFloor => _runAcoustic(
          kind: kind,
          deviceId: deviceId,
          requestCodec: _batchCodec!,
          window: noiseFloorWindow,
          note: _noiseFloorNote,
        ),
      DeviceTestKind.sensitivity => _runAcoustic(
          kind: kind,
          deviceId: deviceId,
          requestCodec: _batchCodec!,
          window: sensitivityWindow,
          note: _sensitivityNote,
        ),
    };
  }

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
    _saveFailure = null;
    _openFailure = null;
    _openWasUnavailable = false;
    _cancelled = Completer<void>();
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
    // Stamped with its place in the batch on the way to disk, so the places that
    // build a result do not each have to carry the batch fields - and so a
    // sample can never be saved without them.
    final finished = result.inBatch(
      batchId: _batchId,
      repeatIndex: _batchDone + 1,
      repeatTarget: _batchTarget,
      duration: result.duration == Duration.zero && started != null
          ? _clock().difference(started)
          : result.duration,
    );

    await _closeCapture();
    _ticker?.cancel();
    _ticker = null;

    try {
      await _store.append(finished);
    } on Object catch (error) {
      // The measurement happened; the record of it did not. Said out loud,
      // because a check whose numbers vanish is worse than no check.
      _saveFailure = 'the result could not be saved: $error';
    }

    _running = null;
    _phase = DeviceTestPhase.idle;
    _startedAt = null;
    _cancelled = null;
    _notify();
    return finished;
  }

  /// The die temperature right now, as a reading.
  ///
  /// STAMPED ON EVERY RUN, and not because anyone asked for a thermometer: the
  /// enclosure puts a LiPo cell under the board and plastic around both, and
  /// the chip that measures this is the one doing the work. A noise floor that
  /// got worse is worth a great deal more when the die temperature it was taken
  /// at is written next to it.
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
      // A level computed from bytes decoded as the wrong codec is not a quiet
      // number, it is a WRONG one, and it would be compared against next week's
      // run as though it meant something. Refused instead.
      _openWasUnavailable = true;
      _openFailure = 'the device did not report its stream format, so the '
          'audio cannot be decoded and any level from it would be invented';
      return null;
    }
    if (info.codec == null ||
        info.bitsPerSample != 16 ||
        !_decoders.supports(info.codec!)) {
      _openWasUnavailable = true;
      _openFailure = 'the device reported a format this build cannot decode '
          '(${info.toString()})';
      return null;
    }

    final StreamDecoder decoder;
    try {
      decoder = _decoders.open(
        codec: info.codec!,
        sampleRateHz: info.sampleRateHz,
        channels: info.channels,
      );
    } on Object catch (e) {
      _openWasUnavailable = true;
      _openFailure =
          'the device reported a format this build cannot decode '
          '(${info.toString()}): $e';
      return null;
    }
    final capture = _Capture(deviceId: deviceId, info: info, decoder: decoder);
    try {
      capture.frames = _transport.subscribeFrames(deviceId).listen(
            capture.accept,
            onError: (Object error) => capture.error ??= error,
          );
    } on BleTransportException catch (e) {
      // The exclusive frame subscription - a capture, or the live link view.
      capture.decoder.dispose();
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
    capture.decoder.dispose();
    try {
      await _transport.unsubscribeFrames(capture.deviceId);
    } on BleTransportException {
      // The notifications have stopped either way.
    }
  }

  /// Waits [window], or until the check is cancelled.
  ///
  /// The timer is ALWAYS cancelled on the way out. A pending timer outliving
  /// the run is how a cancelled window keeps a screen awake.
  Future<void> _wait(Duration window) async {
    final done = Completer<void>();
    final timer = Timer(window, () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _either(done.future);
    } finally {
      timer.cancel();
    }
  }

  /// Waits for the first of [first] or cancellation.
  Future<void> _either(Future<void> first) {
    final cancelled = _cancelled;
    return Future.any(<Future<void>>[first, ?cancelled?.future]);
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    cancel();
    _endBatch();
    _ticker?.cancel();
    _ticker = null;
    await _closeCapture();
    await _changes.close();
  }
}

/// One open audio stream, with the counters and the level window that read it.
class _Capture {
  _Capture({required this.deviceId, required this.info, required this.decoder});

  final String deviceId;
  final StreamInfo info;

  /// This stream's decoder, disposed by `_closeCapture`.
  final StreamDecoder decoder;

  final FrameReassembler reassembler = FrameReassembler();
  StreamSubscription<Uint8List>? frames;
  Object? error;

  final LevelWindow level = LevelWindow();

  CaptureStats get stats => reassembler.stats;

  void accept(Uint8List notification) {
    final frame = reassembler.accept(notification);
    if (frame == null) return;
    final Uint8List pcm;
    try {
      pcm = decoder.decode(frame);
    } on Object {
      // One block this build cannot decode costs that block, not the check.
      return;
    }
    level.addPcmS16le(pcm);
  }
}
