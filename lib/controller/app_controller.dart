import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drivers/audio_player.dart';
import '../drivers/ble_transport.dart';
import '../drivers/file_store.dart';
import '../drivers/platform_settings.dart';
import '../model/audio_codec.dart';
import '../model/battery_bars.dart';
import '../model/battery_status.dart';
import '../model/device_state.dart';
import '../model/device_test_aggregate.dart';
import '../model/device_test_result.dart';
import '../model/die_temperature.dart';
import '../model/level_reading.dart';
import '../model/link_health.dart';
import '../model/recording_info.dart';
import '../model/recording_metadata.dart';
import '../model/stream_info.dart';
import '../services/device_test_service.dart';
import '../services/device_test_store.dart';
import '../services/link_monitor.dart';
import '../services/library_service.dart';
import '../services/recording_service.dart';

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
    required this._recordingsDirectory,
    RecordingService? recordingService,
    LibraryService? libraryService,
    DeviceTestService? deviceTestService,
    LinkMonitor? linkMonitor,
    AudioPlayer? audioPlayer,
    PlatformSettings? platformSettings,
    AudioCodec preferredCodec = AudioCodec.imaAdpcm,
    // The public parameter name `preferredCodec:` is part of the existing API,
    // while the field behind it is private because it is now reached through a
    // notifying setter - so an initializing formal is not available here.
    // ignore: prefer_initializing_formals
  })  : _preferredCodec = preferredCodec,
        _injectedTests = deviceTestService,
        _injectedLinkMonitor = linkMonitor,
        _transport = transport,
        _fileStore = fileStore,
        _player = audioPlayer,
        _settings = platformSettings,
        _library = libraryService ??
            LibraryService(
              fileStore: fileStore,
              directory: _recordingsDirectory,
            ),
        _recorder = recordingService ??
            RecordingService(transport: transport, fileStore: fileStore);

  final BleTransport _transport;
  final FileStore _fileStore;
  final String _recordingsDirectory;
  final RecordingService _recorder;
  final LibraryService _library;

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
  /// connected, the read failed, or the firmware predates `fe04`.
  ///
  /// Null is a third state on purpose. The device persists this flag in
  /// flash, so a default of "off" would be a guess about a setting that can
  /// put the recorder to sleep - and a wrong guess is worse than no answer.
  bool? _autoSleep;

  /// The device's battery reading, or null when it is unknown: nothing is
  /// connected, the read failed, or the firmware predates `fe05`.
  ///
  /// Null is the same kind of third state [_autoSleep] is, and for the same
  /// reason: there is no honest default for a measurement only the device can
  /// take. Note the SECOND unknown nested inside it - a [BatteryStatus] whose
  /// `percent` is null is a device that has the characteristic but no reading
  /// (`0xFF` on the wire). Neither may ever be rendered as 0%.
  BatteryStatus? _battery;

  /// The device's die temperature, or null when it is unknown: nothing is
  /// connected, the read failed, or the firmware predates `fe07`.
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
  /// Held HERE and not in the playback screen, because a rate that lives in
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
  bool get autoSleepEnabled => _autoSleep ?? false;

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

  /// Runs in the saved file this build does not read - see
  /// [DeviceTestStore.retiredKinds]. They are kept in the file untouched.
  ///
  /// Surfaced so a screen showing twelve runs out of a file of fifteen can
  /// account for the other three rather than looking as though it lost them.
  int get unreadDeviceTestRunCount => _tests.unreadRunCount;

  /// How many of [unreadDeviceTestRunCount] are runs of a retired measurement,
  /// as against rows a newer build wrote.
  int get retiredDeviceTestRunCount => _tests.retiredRunCount;

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
    notifyListeners();
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
  /// The reverse - Bluetooth coming back - deliberately does NOT reconnect. The
  /// link was dropped, nothing is holding it, and claiming otherwise is the bug
  /// this method exists to prevent. The screen returns to the scan control, which
  /// is something the user can act on.
  void _onAvailabilityChanged(BleAvailability state) {
    final previous = _availability;
    _availability = state;
    if (state != previous && state != BleAvailability.poweredOn) {
      unawaited(_adapterLost());
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
        if (!_devices.contains(device)) {
          _devices.add(device);
          notifyListeners();
        }
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
    await stopScan();
    // Remembered before the attempt, so "Try again" has something to try even
    // when the attempt is what failed.
    _lastDevice = device;
    _linkOutcome = LinkOutcome.none;
    _setPhase(AppPhase.connecting);
    try {
      await _transport.connect(device.id);
    } on BleTransportException catch (e) {
      // The recorder was found and the handshake did not complete. That is a
      // different fact from a link dropping later, and from nothing being
      // there at all.
      _linkOutcome = LinkOutcome.connectFailed;
      _fail(e.message);
      return;
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
    await _linkMonitor.start(deviceId);
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
  /// control unavailable, which is all older firmware without `fe04` can
  /// honestly be reported as.
  Future<void> _readAutoSleep(String deviceId) async {
    try {
      _autoSleep = await _transport.readAutoSleep(deviceId);
    } on BleTransportException {
      _autoSleep = null;
    }
    notifyListeners();
  }

  /// Writes the auto-sleep flag to the connected device.
  ///
  /// Does nothing unless the device reported the setting in the first place:
  /// a write to firmware that has no `fe04` would fail anyway, and writing a
  /// value the app never read would be writing a guess.
  Future<void> setAutoSleep(bool enabled) async {
    final device = _connectedDevice;
    if (device == null || !autoSleepAvailable || enabled == _autoSleep) return;
    try {
      await _transport.setAutoSleep(device.id, enabled);
    } on BleTransportException catch (e) {
      // The device kept its old setting, so the app keeps showing it. This is
      // not a phase change: the link is fine and the recorder still works.
      _errorMessage = e.message;
      notifyListeners();
      return;
    }
    _autoSleep = enabled;
    notifyListeners();
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
  Future<void> disconnect() => _releaseLink(_LinkEnding.userAsked);

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
    _autoSleep = null;
    // These readings described a link that is gone; keeping the last percentage
    // or the last temperature on screen would be showing a stale measurement as
    // a live one.
    _setBattery(null);
    _temperature = null;
    // A dropped link leaves whatever message was already on screen: it explains
    // the last thing the user did, and `ConnectionLostView` supplies the reason
    // for the drop itself.
    if (ending != _LinkEnding.peripheralGone) _errorMessage = failure;
    // Only an unsolicited drop is worth explaining and offering a retry for. The
    // user asking needs neither, and the adapter going off has a screen of its
    // own - the Bluetooth-off edge state, which is reached by leaving the
    // outcome at `none`.
    _linkOutcome = ending == _LinkEnding.peripheralGone
        ? LinkOutcome.connectionLost
        : LinkOutcome.none;
    _setPhase(AppPhase.idle);
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

  Future<void> startRecording() async {
    final device = _connectedDevice;
    if (device == null || isRecording) return;
    _errorMessage = null;
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
  /// The app keeps no sidecar metadata - a recording's name, timestamp and
  /// length are read back from the file name and its own WAV header - so
  /// "delete the metadata too" means dropping the in-memory references:
  /// [nowPlaying], [lastRecording] and the published list. Any one of them
  /// left pointing at a deleted path is the orphan entry.
  Future<void> deleteRecording(RecordingInfo recording) async {
    if (_nowPlaying?.path == recording.path) {
      await stopPlayback();
      _nowPlaying = null;
      _playback = PlaybackState.idle;
      _playbackError = null;
    }
    if (_lastRecording?.path == recording.path) _lastRecording = null;
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
