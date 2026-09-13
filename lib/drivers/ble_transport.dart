import 'dart:typed_data';

import '../model/audio_codec.dart';
import '../model/battery_status.dart';
import '../model/device_state.dart';
import '../model/stream_info.dart';

/// Everything the app needs from a Bluetooth Low Energy stack, expressed
/// without naming a single type from any BLE package.
///
/// This is the swap seam: `services/` and `controller/` talk only to this
/// interface, so replacing `universal_ble` - or targeting a platform it does
/// not cover - is confined to `lib/drivers/`.
abstract class BleTransport {
  /// Adapter power/permission state, pushed as it changes.
  Stream<BleAvailability> get availability;

  /// Current adapter state, read once.
  Future<BleAvailability> currentAvailability();

  /// Asks the OS for whatever runtime permissions scanning needs.
  /// Returns `true` when scanning is permitted afterwards.
  Future<bool> ensurePermissions();

  /// Emits peripherals matching the voiceNotetaker profile until
  /// [stopScan] is called or the returned subscription is cancelled.
  Stream<DiscoveredDevice> scan();

  Future<void> stopScan();

  /// Link state for [deviceId], pushed as it changes.
  Stream<BleConnectionStatus> connectionState(String deviceId);

  /// Connects and discovers services. Throws [BleTransportException] on
  /// failure.
  /// ATT MTU negotiated on the current link, or null when unknown.
  ///
  /// Worth surfacing: the 23-byte default leaves 20 bytes of notification
  /// payload, which cannot carry a 166-byte ADPCM frame at all.
  int? get negotiatedMtu;

  Future<void> connect(String deviceId, {Duration timeout});

  Future<void> disconnect(String deviceId);

  /// Reads the `fe02` stream-info characteristic.
  Future<StreamInfo> readStreamInfo(String deviceId);

  /// Writes [codec] to the `fe03` control characteristic.
  Future<void> selectCodec(String deviceId, AudioCodec codec);

  /// Reads the `fe04` auto-sleep characteristic.
  ///
  /// Throws [BleTransportException] when the characteristic is absent - which
  /// is what firmware older than `fe04` looks like from here - or when the
  /// value is not the single byte the protocol defines. Callers must treat
  /// that as "unknown", never as "off".
  Future<bool> readAutoSleep(String deviceId);

  /// Writes [enabled] to the `fe04` auto-sleep characteristic as one byte.
  Future<void> setAutoSleep(String deviceId, bool enabled);

  /// Reads the `fe05` battery characteristic once.
  ///
  /// Throws [BleTransportException] when the characteristic is absent - which
  /// is what firmware older than `fe05` looks like from here - or when the
  /// value is not the two bytes the protocol defines. Callers must treat that
  /// as "battery unavailable", never as a reading of zero.
  Future<BatteryStatus> readBattery(String deviceId);

  /// Subscribes to `fe05` and emits each battery notification, parsed.
  ///
  /// A malformed notification arrives as an error on the stream rather than
  /// as a made-up value. The stream closes when the subscription is cancelled
  /// or [unsubscribeBattery] is called.
  Stream<BatteryStatus> subscribeBattery(String deviceId);

  Future<void> unsubscribeBattery(String deviceId);

  /// Subscribes to `fe01` and emits each notification verbatim - sequence
  /// header included. Stripping that header is [FrameReassembler]'s job, not
  /// the transport's.
  Stream<Uint8List> subscribeFrames(String deviceId);

  Future<void> unsubscribeFrames(String deviceId);

  /// Releases platform resources. The transport is unusable afterwards.
  Future<void> dispose();
}

/// Failure raised by a [BleTransport] implementation, so callers never have to
/// catch a package-specific exception type.
class BleTransportException implements Exception {
  const BleTransportException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'BleTransportException: $message${cause == null ? '' : ' ($cause)'}';
}
