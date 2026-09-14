import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart' as ub;

import '../model/audio_codec.dart';
import '../model/auto_sleep.dart';
import '../model/battery_status.dart';
import '../model/capture_flags.dart';
import '../model/device_profile.dart';
import '../model/device_state.dart';
import '../model/die_temperature.dart';
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

  /// Characteristic UUIDs, lower case, found by the discovery pass in
  /// [connect], per device. What [supportsCapture] answers from.
  final Map<String, Set<String>> _characteristics = <String, Set<String>>{};

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

  /// Battery notifications are a second, independent subscription: they must
  /// keep arriving whether or not a capture is running, so they cannot share
  /// the frame plumbing above.
  StreamSubscription<Uint8List>? _batterySubscription;
  StreamController<BatteryStatus>? _batteryController;
  String? _batteryDeviceId;

  /// Die-temperature notifications are a third, independent subscription, for
  /// the same reason the battery's is separate from the frames': it must keep
  /// arriving whether or not a capture is running.
  StreamSubscription<Uint8List>? _temperatureSubscription;
  StreamController<DieTemperature>? _temperatureController;
  String? _temperatureDeviceId;

  /// Capture-state notifications, a fourth independent subscription: they
  /// report the mute and the speech gate whether or not audio is flowing.
  StreamSubscription<Uint8List>? _captureSubscription;
  StreamController<CaptureFlags>? _captureController;
  String? _captureDeviceId;

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
    Timer? window;

    Future<void> stop() async {
      window?.cancel();
      window = null;
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
          // `UniversalBle.scanStream` runs until it is told to stop, so the
          // window is imposed here. Closing the controller is what tells the
          // caller the scan FINISHED - see `BleTransport.scan`.
          window = Timer(BleTransport.scanWindow, () async {
            try {
              await stop();
            } on BleTransportException {
              // The radio refusing to stop does not change the fact that the
              // window is over, and a throw out of a timer callback has
              // nowhere to go. Closing the stream is what the caller needs.
            }
            if (!controller.isClosed) await controller.close();
          });
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
      final services = await ub.UniversalBle.discoverServices(deviceId);
      _servicesDiscovered.add(deviceId);
      _characteristics[deviceId] = <String>{
        for (final service in services)
          for (final characteristic in service.characteristics)
            characteristic.uuid.toLowerCase(),
      };

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
    _characteristics.remove(deviceId);
    if (_captureDeviceId == deviceId) {
      await unsubscribeCapture(deviceId);
    }
    if (_frameDeviceId == deviceId) {
      await unsubscribeFrames(deviceId);
    }
    if (_batteryDeviceId == deviceId) {
      await unsubscribeBattery(deviceId);
    }
    if (_temperatureDeviceId == deviceId) {
      await unsubscribeDieTemperature(deviceId);
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
  Future<bool> readAutoSleep(String deviceId) async {
    try {
      final bytes = await ub.UniversalBle.read(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.autoSleepCharacteristicUuid,
      );
      return AutoSleep.fromBytes(bytes);
    } on FormatException catch (e) {
      throw BleTransportException('malformed auto-sleep setting', e);
    } catch (e) {
      // Firmware without `fe04` fails here, and so does a link that dropped
      // mid-read. Neither is worth telling apart: the setting is unknown.
      throw BleTransportException('could not read the auto-sleep setting', e);
    }
  }

  @override
  Future<void> setAutoSleep(String deviceId, bool enabled) async {
    try {
      await ub.UniversalBle.write(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.autoSleepCharacteristicUuid,
        AutoSleep.toBytes(enabled),
      );
    } catch (e) {
      throw BleTransportException(
        'could not ${enabled ? 'enable' : 'disable'} auto-sleep',
        e,
      );
    }
  }

  @override
  Future<BatteryStatus> readBattery(String deviceId) async {
    try {
      final bytes = await ub.UniversalBle.read(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.batteryCharacteristicUuid,
      );
      return BatteryStatus.fromBytes(bytes);
    } on FormatException catch (e) {
      throw BleTransportException('malformed battery status', e);
    } catch (e) {
      // Firmware without `fe05` fails here, and so does a link that dropped
      // mid-read. Neither is worth telling apart: the battery is unknown.
      throw BleTransportException('could not read the battery status', e);
    }
  }

  @override
  Stream<BatteryStatus> subscribeBattery(String deviceId) {
    if (_batteryController != null) {
      throw const BleTransportException('already subscribed to the battery');
    }

    final controller = StreamController<BatteryStatus>(
      onCancel: () => unsubscribeBattery(deviceId),
    );
    _batteryController = controller;
    _batteryDeviceId = deviceId;

    _batterySubscription = ub.UniversalBle.characteristicValueStream(
      deviceId,
      DeviceProfile.batteryCharacteristicUuid,
    ).listen(
      (bytes) {
        try {
          controller.add(BatteryStatus.fromBytes(bytes));
        } on FormatException catch (e) {
          // A value this build cannot read is reported as such, never
          // rounded into a number to show.
          controller.addError(
            BleTransportException('malformed battery notification', e),
          );
        }
      },
      onError: controller.addError,
    );

    unawaited(() async {
      try {
        await ub.UniversalBle.subscribeNotifications(
          deviceId,
          DeviceProfile.serviceUuid,
          DeviceProfile.batteryCharacteristicUuid,
        );
      } catch (e) {
        // Firmware without `fe05` lands here. The one-shot read has already
        // failed for the same reason, so this is not a second failure worth
        // escalating - the stream simply ends.
        if (!controller.isClosed) {
          controller.addError(
            BleTransportException('could not subscribe to the battery', e),
          );
        }
        // Through `unsubscribeBattery` rather than a bare `close`, so the
        // fields are cleared too: a later reconnect must be able to subscribe
        // again instead of being told it already has.
        await unsubscribeBattery(deviceId);
      }
    }());

    return controller.stream;
  }

  @override
  Future<void> unsubscribeBattery(String deviceId) async {
    final subscription = _batterySubscription;
    final controller = _batteryController;
    _batterySubscription = null;
    _batteryController = null;
    _batteryDeviceId = null;

    await subscription?.cancel();
    try {
      await ub.UniversalBle.unsubscribe(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.batteryCharacteristicUuid,
      );
    } catch (_) {
      // Unsubscribing a link that has already dropped, or a characteristic
      // that was never there, is not an error worth propagating.
    }
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  @override
  Future<DieTemperature> readDieTemperature(String deviceId) async {
    try {
      final bytes = await ub.UniversalBle.read(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.temperatureCharacteristicUuid,
      );
      return DieTemperature.fromBytes(bytes);
    } on FormatException catch (e) {
      throw BleTransportException('malformed die temperature', e);
    } catch (e) {
      // Firmware without `fe07` fails here, and so does a link that dropped
      // mid-read. Neither is worth telling apart: the temperature is unknown.
      throw BleTransportException('could not read the die temperature', e);
    }
  }

  @override
  Stream<DieTemperature> subscribeDieTemperature(String deviceId) {
    if (_temperatureController != null) {
      throw const BleTransportException(
        'already subscribed to the die temperature',
      );
    }

    final controller = StreamController<DieTemperature>(
      onCancel: () => unsubscribeDieTemperature(deviceId),
    );
    _temperatureController = controller;
    _temperatureDeviceId = deviceId;

    _temperatureSubscription = ub.UniversalBle.characteristicValueStream(
      deviceId,
      DeviceProfile.temperatureCharacteristicUuid,
    ).listen(
      (bytes) {
        try {
          controller.add(DieTemperature.fromBytes(bytes));
        } on FormatException catch (e) {
          // Reported as unreadable, never rounded into a number to show.
          controller.addError(
            BleTransportException('malformed temperature notification', e),
          );
        }
      },
      onError: controller.addError,
    );

    unawaited(() async {
      try {
        await ub.UniversalBle.subscribeNotifications(
          deviceId,
          DeviceProfile.serviceUuid,
          DeviceProfile.temperatureCharacteristicUuid,
        );
      } catch (e) {
        // Firmware without `fe07` lands here. The one-shot read has already
        // failed for the same reason, so this is not a second failure worth
        // escalating - the stream simply ends.
        if (!controller.isClosed) {
          controller.addError(
            BleTransportException(
              'could not subscribe to the die temperature',
              e,
            ),
          );
        }
        // Through `unsubscribeDieTemperature` rather than a bare `close`, so
        // the fields are cleared too: a later reconnect must be able to
        // subscribe again instead of being told it already has.
        await unsubscribeDieTemperature(deviceId);
      }
    }());

    return controller.stream;
  }

  @override
  Future<void> unsubscribeDieTemperature(String deviceId) async {
    final subscription = _temperatureSubscription;
    final controller = _temperatureController;
    _temperatureSubscription = null;
    _temperatureController = null;
    _temperatureDeviceId = null;

    await subscription?.cancel();
    try {
      await ub.UniversalBle.unsubscribe(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.temperatureCharacteristicUuid,
      );
    } catch (_) {
      // Unsubscribing a link that has already dropped, or a characteristic
      // that was never there, is not an error worth propagating.
    }
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  @override
  Future<bool> supportsCapture(String deviceId) async =>
      _characteristics[deviceId]
          ?.contains(DeviceProfile.captureCharacteristicUuid.toLowerCase()) ??
      false;

  @override
  Future<CaptureFlags> readCapture(String deviceId) async {
    try {
      final bytes = await ub.UniversalBle.read(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.captureCharacteristicUuid,
      );
      return CaptureFlags.fromBytes(bytes);
    } on FormatException catch (e) {
      throw BleTransportException('malformed capture state', e);
    } catch (e) {
      // Firmware without `fe08` fails here, and so does a link that dropped
      // mid-read. `supportsCapture` is what tells the two apart.
      throw BleTransportException('could not read the capture state', e);
    }
  }

  @override
  Future<void> writeCapture(String deviceId, CaptureCommand command) async {
    try {
      await ub.UniversalBle.write(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.captureCharacteristicUuid,
        command.toBytes(),
      );
    } catch (e) {
      throw BleTransportException('could not send ${command.name}', e);
    }
  }

  @override
  Stream<CaptureFlags> subscribeCapture(String deviceId) {
    if (_captureController != null) {
      throw const BleTransportException(
        'already subscribed to the capture state',
      );
    }

    final controller = StreamController<CaptureFlags>(
      onCancel: () => unsubscribeCapture(deviceId),
    );
    _captureController = controller;
    _captureDeviceId = deviceId;

    _captureSubscription = ub.UniversalBle.characteristicValueStream(
      deviceId,
      DeviceProfile.captureCharacteristicUuid,
    ).listen(
      (bytes) {
        try {
          controller.add(CaptureFlags.fromBytes(bytes));
        } on FormatException catch (e) {
          controller.addError(
            BleTransportException('malformed capture notification', e),
          );
        }
      },
      onError: controller.addError,
    );

    unawaited(() async {
      try {
        await ub.UniversalBle.subscribeNotifications(
          deviceId,
          DeviceProfile.serviceUuid,
          DeviceProfile.captureCharacteristicUuid,
        );
      } catch (e) {
        if (!controller.isClosed) {
          controller.addError(
            BleTransportException('could not subscribe to the capture state', e),
          );
        }
        // Through `unsubscribeCapture`, so a reconnect can subscribe again.
        await unsubscribeCapture(deviceId);
      }
    }());

    return controller.stream;
  }

  @override
  Future<void> unsubscribeCapture(String deviceId) async {
    final subscription = _captureSubscription;
    final controller = _captureController;
    _captureSubscription = null;
    _captureController = null;
    _captureDeviceId = null;

    await subscription?.cancel();
    try {
      await ub.UniversalBle.unsubscribe(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.captureCharacteristicUuid,
      );
    } catch (_) {
      // A link that has already dropped has nothing left to unsubscribe.
    }
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  @override
  Future<int> readRssi(String deviceId) async {
    try {
      return await ub.UniversalBle.readRssi(deviceId);
    } catch (e) {
      // Some platforms refuse this on a connected device, and a link that has
      // just dropped refuses it too. Either way there is no signal reading,
      // which is a different fact from a signal of 0 dBm.
      throw BleTransportException('could not read the link RSSI', e);
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
    final batteryDeviceId = _batteryDeviceId;
    if (batteryDeviceId != null) await unsubscribeBattery(batteryDeviceId);
    final temperatureDeviceId = _temperatureDeviceId;
    if (temperatureDeviceId != null) {
      await unsubscribeDieTemperature(temperatureDeviceId);
    }
    final captureDeviceId = _captureDeviceId;
    if (captureDeviceId != null) await unsubscribeCapture(captureDeviceId);
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
