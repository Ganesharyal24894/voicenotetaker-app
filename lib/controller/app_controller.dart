import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drivers/audio_player.dart';
import '../drivers/ble_transport.dart';
import '../drivers/file_store.dart';
import '../drivers/platform_settings.dart';
import '../model/audio_codec.dart';
import '../model/battery_status.dart';
import '../model/device_state.dart';
import '../model/level_reading.dart';
import '../model/recording_info.dart';
import '../model/recording_metadata.dart';
import '../model/stream_info.dart';
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
    AudioPlayer? audioPlayer,
    PlatformSettings? platformSettings,
    AudioCodec preferredCodec = AudioCodec.imaAdpcm,
    // The public parameter name `preferredCodec:` is part of the existing API,
    // while the field behind it is private because it is now reached through a
    // notifying setter - so an initializing formal is not available here.
    // ignore: prefer_initializing_formals
  })  : _preferredCodec = preferredCodec,
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

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<BatteryStatus>? _batterySubscription;
  StreamSubscription<BleConnectionStatus>? _connectionSubscription;
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
    await refreshLibrary();
    try {
      _availability = await _transport.currentAvailability();
    } on BleTransportException catch (e) {
      _fail(e.message);
      return;
    }
    _transport.availability.listen((state) {
      _availability = state;
      notifyListeners();
    });
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
        // Nobody asked for this: a working link went away. `disconnect()`
        // cancels this subscription before it ends the link, so a deliberate
        // disconnect never arrives here.
        _linkOutcome = LinkOutcome.connectionLost;
        _connectedDevice = null;
        _autoSleep = null;
        // The reading described a link that is gone; keeping the last
        // percentage on screen would be showing a stale measurement as live.
        _battery = null;
        unawaited(_stopBattery(device.id));
        _setPhase(AppPhase.idle);
      }
    });
    _setPhase(AppPhase.connected);
    // Read rather than assumed: the flag lives in the device's flash and
    // survives reboots, so only the device knows what it is.
    await _readAutoSleep(device.id);
    // Read once so there is something on screen immediately, then follow the
    // notifications so it stays live.
    await _readBattery(device.id);
    _followBattery(device.id);
  }

  /// Reads the battery status from the connected device.
  ///
  /// A failure is not an app error: it leaves the battery unknown and the
  /// readout unavailable, which is all firmware without `fe05` can honestly
  /// be reported as.
  Future<void> _readBattery(String deviceId) async {
    try {
      _battery = await _transport.readBattery(deviceId);
    } on BleTransportException {
      _battery = null;
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
          _battery = status;
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
  Future<void> disconnect() async {
    final device = _connectedDevice;
    if (device == null) return;
    if (isRecording) await stopRecording();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    // Stop following the battery before the link goes, so the last thing the
    // radio does is not delivering a notification into a torn-down listener.
    await _stopBattery(device.id);
    String? failure;
    try {
      await _transport.disconnect(device.id);
    } on BleTransportException catch (e) {
      failure = e.message;
    }
    _connectedDevice = null;
    _autoSleep = null;
    _battery = null;
    _errorMessage = failure;
    // The user ended this, so there is nothing to explain and nothing to
    // offer a retry for.
    _linkOutcome = LinkOutcome.none;
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
    await _batterySubscription?.cancel();
    _batterySubscription = null;
    await _statsSubscription?.cancel();
    _statsSubscription = null;
    await _levelSubscription?.cancel();
    _levelSubscription = null;
    await _librarySubscription?.cancel();
    _librarySubscription = null;
    await _playbackSubscription?.cancel();
    _playbackSubscription = null;
    await _recorder.dispose();
    await _library.dispose();
    await _player?.dispose();
    await _transport.dispose();
  }
}
