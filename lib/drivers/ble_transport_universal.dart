import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart' as ub;

import '../model/audio_codec.dart';
import '../model/auto_sleep.dart';
import '../model/battery_status.dart';
import '../model/capture_flags.dart';
import '../model/device_profile.dart';
import '../model/device_state.dart';
import '../model/die_temperature.dart';
import '../model/pairing_advert.dart';
import '../model/pairing_outcome.dart';
import '../model/recorder_sleep.dart';
import '../model/stream_info.dart';
import 'ble_pairing.dart';
import 'ble_transport.dart';

/// [BleTransport] and [BlePairing] backed by the `universal_ble` package.
///
/// This file is the ONLY place in the app allowed to import `universal_ble`.
/// Everything it exposes is expressed in `lib/model/` types, so swapping the
/// package means writing a sibling of this file and changing one line in
/// `main.dart`.
class UniversalBleTransport implements BleTransport, BlePairing {
  UniversalBleTransport();

  /// The app's own channel for what `universal_ble` does not offer: the list of
  /// bonded devices (Android `BluetoothAdapter.getBondedDevices`), handled in
  /// `MainActivity.kt`. iOS has no handler and no such list.
  static const MethodChannel bluetoothChannel =
      MethodChannel('com.ganeshsharma.voicenotetaker_app/bluetooth');

  /// How recent a disconnect must be for its reason to explain a failure.
  static const Duration dropReasonWindow = Duration(seconds: 5);

  /// The reason the platform gave for the last disconnect of each device, and
  /// when - lower-cased ids. `universal_ble` reports it only through its one
  /// global connection callback, not through `connectionStream`.
  ///
  /// A NULL REASON IS RECORDED TOO, and that is the whole point of the change:
  /// iOS reports a clean `didDisconnectPeripheral` with no error at all, so
  /// "the platform said nothing" has to be a fact this map can hold rather
  /// than an absence indistinguishable from "nothing has dropped".
  final Map<String, (String?, DateTime)> _dropReasons =
      <String, (String?, DateTime)>{};
  bool _watchingDrops = false;

  /// Installed on first use rather than in the constructor, so building the
  /// transport touches no platform code.
  void _watchDrops() {
    if (_watchingDrops) return;
    _watchingDrops = true;
    ub.UniversalBle.onConnectionChange = (deviceId, connected, error) {
      if (connected) return;
      _dropReasons[deviceId.toLowerCase()] = (error, DateTime.now());
    };
  }

  @override
  LinkDropReason? lastDropReason(String deviceId) {
    final drop = _dropReasons[deviceId.toLowerCase()];
    if (drop == null ||
        DateTime.now().difference(drop.$2) > dropReasonWindow) {
      return null;
    }
    return LinkDropReason.fromPlatform(drop.$1);
  }

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
        _watchDrops();
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
    bool waitForAdvertisement = false,
  }) async {
    _watchDrops();
    _dropReasons.remove(deviceId.toLowerCase());
    try {
      await ub.UniversalBle.connect(
        deviceId,
        timeout: timeout,
        // iPHONE ONLY, AND ONLY FOR WHAT IT DOES THERE. On iOS 17 and newer
        // this sets `CBConnectPeripheralOptionEnableAutoReconnect`, so after
        // an unexpected disconnect Core Bluetooth re-establishes the link by
        // itself - including while the app is suspended, which is exactly the
        // case the app cannot reach: a suspended app gets no timer to run its
        // own reconnect with. Older iOS ignores it.
        //
        // NOT ON ANDROID. There the same flag becomes the platform's
        // `autoConnect`, which trades a first connection that takes seconds
        // for one that takes a scan window - and Android has the foreground
        // service, so the app's own reconnect backoff runs and is faster.
        //
        // WITH [waitForAdvertisement] IT IS ASKED FOR ON BOTH. That is the
        // point of the flag: Android's `autoConnect` hands the waiting to the
        // controller's own offloaded scan instead of driving the radio from
        // here, which is what makes a recorder asleep overnight cost the
        // phone nothing.
        autoConnect: waitForAdvertisement || Platform.isIOS,
      );
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
      if (waitForAdvertisement) {
        // A standing attempt outlives its Dart timeout: the platform keeps
        // waiting for the advertisement, and `universal_ble` documents
        // `disconnect` as the way to call that off. Without this, re-arming
        // would stack pending connections, and one of them could connect
        // behind the app's back.
        try {
          await ub.UniversalBle.disconnect(deviceId);
        } catch (_) {
          // Nothing was pending, or the stack has already let go.
        }
      }
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
  Future<AutoSleepSetting> readAutoSleep(String deviceId) async {
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
  Future<void> setAutoSleepDuration(
    String deviceId,
    AutoSleepDuration duration,
  ) async {
    try {
      await ub.UniversalBle.write(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.autoSleepCharacteristicUuid,
        AutoSleep.durationToBytes(duration),
      );
    } catch (e) {
      throw BleTransportException('could not set auto-sleep to ${duration.name}', e);
    }
  }

  @override
  Future<Uint8List> readBatteryHistory(String deviceId) async {
    try {
      // An ordinary read: Android, iOS and BlueZ fetch a value longer than
      // one MTU with Read Blob requests by themselves.
      return await ub.UniversalBle.read(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.batteryHistoryCharacteristicUuid,
      );
    } catch (e) {
      throw BleTransportException('could not read the battery history', e);
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

  // -------------------------------------------------------------------------
  // PAIRING - see `BlePairing`
  // -------------------------------------------------------------------------

  @override
  bool get systemBonds => ub.BleCapabilities.hasSystemPairingApi;

  @override
  Future<bool?> isBonded(String deviceId) async {
    if (!systemBonds) return null;
    try {
      return await ub.UniversalBle.isPaired(deviceId);
    } catch (e) {
      _log('bond state unknown: $e');
      return null;
    }
  }

  @override
  Future<void> bond(String deviceId, {required Duration timeout}) async {
    if (!systemBonds) return;
    try {
      // `createBond`, then waits for `ACTION_BOND_STATE_CHANGED`. Answers at
      // once when already bonded.
      await ub.UniversalBle.pair(deviceId, timeout: timeout);
    } catch (e) {
      throw BleTransportException('could not pair with $deviceId', e);
    }
  }

  @override
  Future<void> secure(String deviceId, {required Duration timeout}) async {
    try {
      // Long enough for a person to read and accept the iOS pairing alert.
      await ub.UniversalBle.read(
        deviceId,
        DeviceProfile.serviceUuid,
        DeviceProfile.infoCharacteristicUuid,
        timeout: timeout,
      );
    } catch (e) {
      throw BleTransportException('could not read an encrypted value', e);
    }
  }

  @override
  Future<List<String>> bondedRecorderIds() async {
    if (!systemBonds) return const <String>[];
    try {
      final ids = await bluetoothChannel.invokeListMethod<String>(
        'bondedDevices',
        <String, Object?>{'name': DeviceProfile.advertisedName},
      );
      return ids ?? const <String>[];
    } on PlatformException catch (e) {
      _log('bonded devices unavailable: $e');
      return const <String>[];
    } on MissingPluginException {
      return const <String>[];
    }
  }

  @override
  BleFailureKind describe(Object error, {required String deviceId}) {
    var cause = error;
    // Unwrap our own wrapper to what the platform threw.
    while (cause is BleTransportException && cause.cause != null) {
      cause = cause.cause!;
    }
    final drop = _dropReasons[deviceId.toLowerCase()];
    final reason = drop != null &&
            DateTime.now().difference(drop.$2) <= dropReasonWindow
        ? drop.$1
        : null;
    String? code;
    String? message;
    String? details;
    if (cause is ub.UniversalBleException) {
      code = cause.code.name;
      message = cause.message;
      details = cause.details?.toString();
      final inner = cause.details;
      if (inner is PlatformException) {
        message = '$message ${inner.message ?? ''}';
        details = inner.details?.toString();
      }
    } else if (cause is PlatformException) {
      final number = int.tryParse(cause.code);
      if (number != null &&
          number >= 0 &&
          number < ub.UniversalBleErrorCode.values.length) {
        code = ub.UniversalBleErrorCode.values[number].name;
      }
      message = cause.message;
      details = cause.details?.toString();
    } else {
      message = cause.toString();
    }
    return BleFailureKind.fromError(
      code: code,
      message: message,
      details: details,
      disconnectReason: reason,
      isTimeout: cause is TimeoutException,
    );
  }

  static DiscoveredDevice _mapDevice(ub.BleDevice device) => DiscoveredDevice(
        id: device.deviceId,
        name: device.name,
        rssi: device.rssi,
        // From the scan response, when the platform merged it in - Android and
        // iOS both do while scanning actively in the foreground.
        pairing: PairingAdvert.parse(
          device.manufacturerDataList.map(
            (data) => (data.companyId, data.payload.toList()),
          ),
        ),
        // Android reports the bond with every result; iOS leaves it null.
        bonded: device.paired,
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
