import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart' as ub;

import '../model/audio_codec.dart';
import '../model/device_profile.dart';
import '../model/device_state.dart';
import '../model/stream_info.dart';
import 'ble_transport.dart';

/// [BleTransport] backed by the `universal_ble` package.
///
/// This file is the ONLY place in the app allowed to import `universal_ble`.
/// Everything it exposes is expressed in `lib/model/` types, so swapping the
/// package means writing a sibling of this file and changing one line in
/// `main.dart`.
class UniversalBleTransport implements BleTransport {
  UniversalBleTransport();

  /// Guarded so `connect` does not rediscover services on every call.
  final Set<String> _servicesDiscovered = <String>{};

  /// 247 carries our 244-byte notification value plus the 3-byte ATT header.
  /// Android 14+ forces 517 on the first request and ignores later ones, so
  /// asking for exactly what we need is not a limitation in practice.
  static const int desiredMtu = 247;

  @override
  int? negotiatedMtu;

  void _log(String message) =>
      developer.log(message, name: 'BleTransport');

  StreamSubscription<Uint8List>? _frameSubscription;
  StreamController<Uint8List>? _frameController;
  String? _frameDeviceId;

  bool _scanning = false;
  bool _disposed = false;

  @override
  Stream<BleAvailability> get availability =>
      ub.UniversalBle.availabilityStream.map(_mapAvailability);

  @override
  Future<BleAvailability> currentAvailability() async {
    try {
      return _mapAvailability(
        await ub.UniversalBle.getBluetoothAvailabilityState(),
      );
    } catch (e) {
      throw BleTransportException('could not read adapter state', e);
    }
  }

  @override
  Future<bool> ensurePermissions() async {
    try {
      if (await ub.UniversalBle.hasPermissions()) return true;
      await ub.UniversalBle.requestPermissions();
      return await ub.UniversalBle.hasPermissions();
    } catch (e) {
      throw BleTransportException('permission request failed', e);
    }
  }

  @override
  Stream<DiscoveredDevice> scan() {
    late final StreamController<DiscoveredDevice> controller;
    StreamSubscription<ub.BleDevice>? subscription;

    Future<void> stop() async {
      await subscription?.cancel();
      subscription = null;
      await stopScan();
    }

    controller = StreamController<DiscoveredDevice>(
      onListen: () async {
        subscription = ub.UniversalBle.scanStream.listen(
          (device) => controller.add(_mapDevice(device)),
          onError: controller.addError,
        );
        try {
          await ub.UniversalBle.startScan(
            // These filters are OR'd by universal_ble: the peripheral is
            // accepted on either its advertised service or its local name,
            // because not every platform surfaces both.
            scanFilter: ub.ScanFilter(
              withServices: [DeviceProfile.serviceUuid],
              withNamePrefix: [DeviceProfile.advertisedName],
            ),
          );
          _scanning = true;
        } catch (e) {
          controller.addError(BleTransportException('scan failed', e));
          await controller.close();
        }
      },
      onCancel: stop,
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    if (!_scanning) return;
    _scanning = false;
    try {
      await ub.UniversalBle.stopScan();
    } catch (e) {
      throw BleTransportException('could not stop scan', e);
    }
  }

  @override
  Stream<BleConnectionStatus> connectionState(String deviceId) =>
      ub.UniversalBle.connectionStream(deviceId).map(
        (connected) => connected
            ? BleConnectionStatus.connected
            : BleConnectionStatus.disconnected,
      );

  @override
  Future<void> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      await ub.UniversalBle.connect(deviceId, timeout: timeout);
      // Several platforms require an explicit discovery pass before any
      // read/write/subscribe on a custom service will resolve.
      await ub.UniversalBle.discoverServices(deviceId);
      _servicesDiscovered.add(deviceId);

      // Negotiate up from the 23-byte default ATT MTU, which leaves only
      // 20 bytes of notification payload -- far too small for a 166-byte
      // ADPCM frame. Without this the device correctly refuses to send and
      // every frame is dropped, producing a WAV containing only its header.
      //
      // Android honours this; on iOS Core Bluetooth negotiates on its own
      // and the call is a no-op. Neither is fatal if it fails: the device
      // reports the size it can actually carry, so we log and continue
      // rather than refusing an otherwise healthy connection.
      try {
        negotiatedMtu = await ub.UniversalBle.requestMtu(deviceId, desiredMtu);
      } on Exception catch (e) {
        negotiatedMtu = null;
        _log('MTU request failed, continuing with the platform default: $e');
      }

      // Shorter connection interval, which is what actually buys throughput
      // for a sustained notify stream. Android-only; elsewhere it is ignored.
      try {
        await ub.UniversalBle.requestConnectionPriority(
          deviceId,
          ub.BleConnectionPriority.highPerformance,
        );
      } on Exception catch (e) {
        _log('connection priority request failed: $e');
      }
    } catch (e) {
      throw BleTransportException('could not connect to $deviceId', e);
    }
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _servicesDiscovered.remove(deviceId);
    if (_frameDeviceId == deviceId) {
      await unsubscribeFrames(deviceId);
    }
    try {
      await ub.UniversalBle.disconnect(deviceId);
    } catch (e) {
      throw BleTransportException('could not disconnect $deviceId', e);
    }
  }

  @override
  Future<StreamInfo> readStreamInfo(String deviceId) async {
    try {
      final bytes = await ub.UniversalBle.read(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.infoCharacteristicUuid,
      );
      return StreamInfo.fromBytes(bytes);
    } on FormatException catch (e) {
      throw BleTransportException('malformed stream info', e);
    } catch (e) {
      throw BleTransportException('could not read stream info', e);
    }
  }

  @override
  Future<void> selectCodec(String deviceId, AudioCodec codec) async {
    try {
      await ub.UniversalBle.write(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.controlCharacteristicUuid,
        Uint8List.fromList([codec.wireValue]),
      );
    } catch (e) {
      throw BleTransportException('could not select codec ${codec.name}', e);
    }
  }

  @override
  Stream<Uint8List> subscribeFrames(String deviceId) {
    if (_frameController != null) {
      throw const BleTransportException('already subscribed to frames');
    }

    final controller = StreamController<Uint8List>(
      onCancel: () => unsubscribeFrames(deviceId),
    );
    _frameController = controller;
    _frameDeviceId = deviceId;

    _frameSubscription = ub.UniversalBle.characteristicValueStream(
      deviceId,
      DeviceProfile.dataCharacteristicUuid,
    ).listen(controller.add, onError: controller.addError);

    unawaited(() async {
      try {
        await ub.UniversalBle.subscribeNotifications(
          deviceId,
          DeviceProfile.serviceUuid,
          DeviceProfile.dataCharacteristicUuid,
        );
      } catch (e) {
        if (!controller.isClosed) {
          controller.addError(
            BleTransportException('could not subscribe to audio frames', e),
          );
          await controller.close();
        }
      }
    }());

    return controller.stream;
  }

  @override
  Future<void> unsubscribeFrames(String deviceId) async {
    final subscription = _frameSubscription;
    final controller = _frameController;
    _frameSubscription = null;
    _frameController = null;
    _frameDeviceId = null;

    await subscription?.cancel();
    try {
      await ub.UniversalBle.unsubscribe(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.dataCharacteristicUuid,
      );
    } catch (_) {
      // Unsubscribing a link that has already dropped is not an error worth
      // propagating: the notifications have stopped either way.
    }
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final deviceId = _frameDeviceId;
    if (deviceId != null) await unsubscribeFrames(deviceId);
    if (_scanning) {
      try {
        await stopScan();
      } catch (_) {
        // Best effort during teardown.
      }
    }
  }

  static DiscoveredDevice _mapDevice(ub.BleDevice device) => DiscoveredDevice(
        id: device.deviceId,
        name: device.name,
        rssi: device.rssi,
      );

  static BleAvailability _mapAvailability(ub.AvailabilityState state) =>
      switch (state) {
        ub.AvailabilityState.poweredOn => BleAvailability.poweredOn,
        ub.AvailabilityState.poweredOff => BleAvailability.poweredOff,
        ub.AvailabilityState.unauthorized => BleAvailability.unauthorized,
        ub.AvailabilityState.unsupported => BleAvailability.unsupported,
        ub.AvailabilityState.resetting => BleAvailability.unknown,
        ub.AvailabilityState.unknown => BleAvailability.unknown,
      };
}
