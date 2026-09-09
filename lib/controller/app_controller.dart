import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drivers/ble_transport.dart';
import '../drivers/file_store.dart';
import '../model/audio_codec.dart';
import '../model/device_state.dart';
import '../model/recording_metadata.dart';
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
    this.preferredCodec = AudioCodec.imaAdpcm,
  })  : _transport = transport,
        _fileStore = fileStore,
        _recorder = recordingService ??
            RecordingService(transport: transport, fileStore: fileStore);

  final BleTransport _transport;
  final FileStore _fileStore;
  final String _recordingsDirectory;
  final RecordingService _recorder;

  /// Codec requested from the device when a recording starts.
  final AudioCodec preferredCodec;

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<BleConnectionStatus>? _connectionSubscription;
  StreamSubscription<CaptureStats>? _statsSubscription;

  AppPhase _phase = AppPhase.idle;
  BleAvailability _availability = BleAvailability.unknown;
  final List<DiscoveredDevice> _devices = <DiscoveredDevice>[];
  DiscoveredDevice? _connectedDevice;
  CaptureStats _stats = const CaptureStats();
  RecordingMetadata? _lastRecording;
  String? _errorMessage;

  AppPhase get phase => _phase;
  BleAvailability get availability => _availability;
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices);
  DiscoveredDevice? get connectedDevice => _connectedDevice;
  CaptureStats get stats => _stats;
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
    final path = _fileStore.join(_recordingsDirectory, _newFileName());
    try {
      await _recorder.start(
        deviceId: device.id,
        path: path,
        requestCodec: preferredCodec,
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
      _fail(e.message);
      return;
    }
    _setPhase(_connectedDevice == null ? AppPhase.idle : AppPhase.connected);
  }

  /// Sortable, collision-free filename: `voicenote-20260910-143005.wav`.
  String _newFileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'voicenote-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.wav';
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
    await _recorder.dispose();
    await _transport.dispose();
  }
}
