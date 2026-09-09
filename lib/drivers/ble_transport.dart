import 'dart:typed_data';

import '../model/audio_codec.dart';
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
  Future<void> connect(String deviceId, {Duration timeout});

  Future<void> disconnect(String deviceId);

  /// Reads the `fe02` stream-info characteristic.
  Future<StreamInfo> readStreamInfo(String deviceId);

  /// Writes [codec] to the `fe03` control characteristic.
  Future<void> selectCodec(String deviceId, AudioCodec codec);

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
