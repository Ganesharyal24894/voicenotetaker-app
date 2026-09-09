import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drivers/audio_player.dart';
import '../drivers/ble_transport.dart';
import '../drivers/file_store.dart';
import '../model/audio_codec.dart';
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
    AudioCodec preferredCodec = AudioCodec.imaAdpcm,
    // The public parameter name `preferredCodec:` is part of the existing API,
    // while the field behind it is private because it is now reached through a
    // notifying setter - so an initializing formal is not available here.
    // ignore: prefer_initializing_formals
  })  : _preferredCodec = preferredCodec,
        _transport = transport,
        _fileStore = fileStore,
        _player = audioPlayer,
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

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
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

  AppPhase get phase => _phase;
  BleAvailability get availability => _availability;
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
    _devices.clear();

    try {
      if (!await _transport.ensurePermissions()) {
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
      onError: (Object e) => _fail('$e'),
    );
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
    _setPhase(AppPhase.connecting);
    try {
      await _transport.connect(device.id);
    } on BleTransportException catch (e) {
      _fail(e.message);
      return;
    }
    _connectedDevice = device;
    _connectionSubscription =
        _transport.connectionState(device.id).listen((status) {
      if (status == BleConnectionStatus.disconnected) {
        _connectedDevice = null;
        _setPhase(AppPhase.idle);
      }
    });
    _setPhase(AppPhase.connected);
  }

  Future<void> disconnect() async {
    final device = _connectedDevice;
    if (device == null) return;
    if (isRecording) await stopRecording();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    try {
      await _transport.disconnect(device.id);
    } on BleTransportException catch (e) {
      _fail(e.message);
      return;
    }
    _connectedDevice = null;
    _setPhase(AppPhase.idle);
  }

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

  /// Deletes [recording] and refreshes the list.
  Future<void> deleteRecording(RecordingInfo recording) async {
    if (_nowPlaying?.path == recording.path) await stopPlayback();
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
