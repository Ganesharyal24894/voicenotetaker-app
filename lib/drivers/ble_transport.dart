import 'dart:typed_data';

import '../model/audio_codec.dart';
import '../model/auto_sleep.dart';
import '../model/battery_status.dart';
import '../model/capture_flags.dart';
import '../model/device_state.dart';
import '../model/die_temperature.dart';
import '../model/recorder_sleep.dart';
import '../model/stream_info.dart';

/// Everything the app needs from a Bluetooth Low Energy stack, expressed
/// without naming a single type from any BLE package.
///
/// This is the swap seam: `services/` and `controller/` talk only to this
/// interface, so replacing `universal_ble` - or targeting a platform it does
/// not cover - is confined to `lib/drivers/`.
abstract class BleTransport {
  /// How long one [scan] runs before its stream closes by itself.
  ///
  /// A BOUNDED scan is what makes "nothing answered" a statement the app can
  /// make at all: a scan that runs until the user stops it can only ever be
  /// reported as "still looking". The number is user-visible - the empty-state
  /// copy says "Nothing answered in 10 seconds" - so the two must agree, and
  /// this is the one place it is written down.
  static const Duration scanWindow = Duration(seconds: 10);

  /// Adapter power/permission state, pushed as it changes.
  Stream<BleAvailability> get availability;

  /// Current adapter state, read once.
  Future<BleAvailability> currentAvailability();

  /// Asks the OS for whatever runtime permissions scanning needs.
  /// Returns `true` when scanning is permitted afterwards.
  Future<bool> ensurePermissions();

  /// Emits peripherals matching the voiceNotetaker profile until [scanWindow]
  /// elapses, [stopScan] is called, or the returned subscription is cancelled.
  ///
  /// THE STREAM CLOSING MEANS THE SCAN WINDOW ENDED. That is the only signal
  /// callers get for "the scan finished", and it is what tells a finished scan
  /// that saw nothing apart from one that has not seen anything yet.
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

  /// [waitForAdvertisement] arms a STANDING attempt instead of a hard one:
  /// the platform waits for the peripheral to advertise and connects then
  /// (Android `autoConnect`, an iOS pending connection that survives
  /// suspension). It costs next to no radio time, which is what makes it the
  /// right thing to point at a recorder believed asleep - see
  /// [ReconnectBackoff.asleepAttemptTimeout]. It still gives up at [timeout].
  Future<void> connect(
    String deviceId, {
    Duration timeout,
    bool waitForAdvertisement,
  });

  /// Why the last link to [deviceId] ended, as the platform reported it, or
  /// null when nothing recent explains it.
  ///
  /// This is how "the recorder went to sleep" (`0x13`, and then silence) is
  /// told apart from "the recorder is gone" (`0x08`). The platforms word it
  /// differently and iOS may say nothing at all;
  /// [LinkDropReason.fromPlatform] is where that is sorted out, and
  /// [RecorderSleepWatch] is what decides what it means.
  LinkDropReason? lastDropReason(String deviceId);

  Future<void> disconnect(String deviceId);

  /// Reads the `fe02` stream-info characteristic.
  Future<StreamInfo> readStreamInfo(String deviceId);

  /// Writes [codec] to the `fe03` control characteristic.
  Future<void> selectCodec(String deviceId, AudioCodec codec);

  /// Reads the `fe04` auto-sleep characteristic.
  ///
  /// Accepts both forms: one byte from firmware that only knows on/off, two
  /// bytes `[flags, code]` from firmware with durations - the answer's
  /// [AutoSleepSetting.supportsDuration] says which.
  ///
  /// Throws [BleTransportException] when the characteristic is absent - which
  /// is what firmware older than `fe04` looks like from here - or when the
  /// value is in neither form. Callers must treat that as "unknown", never as
  /// "off".
  Future<AutoSleepSetting> readAutoSleep(String deviceId);

  /// Writes [enabled] to `fe04` as the legacy single byte. The firmware keeps
  /// its stored duration.
  Future<void> setAutoSleep(String deviceId, bool enabled);

  /// Writes [duration] to `fe04` as two bytes. Only for firmware whose read
  /// was two bytes; older firmware refuses the length.
  Future<void> setAutoSleepDuration(String deviceId, AutoSleepDuration duration);

  /// Reads the `fe09` battery-life history once, as its raw bytes.
  ///
  /// Up to 428 bytes, longer than one MTU: the platform fetches the rest with
  /// Read Blob requests on its own. Decoding is `BatteryHistory.fromBytes`.
  /// Throws [BleTransportException] when the characteristic is absent (older
  /// firmware) or the read fails.
  Future<Uint8List> readBatteryHistory(String deviceId);

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

  /// Reads the `fe07` die-temperature characteristic once.
  ///
  /// Throws [BleTransportException] when the characteristic is absent - which
  /// is what firmware older than `fe07` looks like from here - or when the
  /// value is not the two bytes the protocol defines. Callers must treat that
  /// as "temperature unavailable", never as 0 \u00B0C.
  Future<DieTemperature> readDieTemperature(String deviceId);

  /// Subscribes to `fe07` and emits each notification, parsed.
  ///
  /// A malformed notification arrives as an error on the stream rather than as
  /// a made-up value, exactly as [subscribeBattery] does.
  Stream<DieTemperature> subscribeDieTemperature(String deviceId);

  Future<void> unsubscribeDieTemperature(String deviceId);

  /// Whether the connected firmware has the `fe08` capture characteristic.
  ///
  /// Answered from the service discovery [connect] already did, so it costs no
  /// radio time. False for a device that is not connected. This is how the app
  /// tells "needs a firmware update" apart from a read that merely failed.
  Future<bool> supportsCapture(String deviceId);

  /// Reads the `fe08` capture state once.
  ///
  /// Always-listening calls this every minute as its keep-alive: the firmware
  /// drops a link with no GATT activity from the phone for ten minutes.
  /// Throws [BleTransportException] when the characteristic is absent or the
  /// value is not the one byte the protocol defines.
  Future<CaptureFlags> readCapture(String deviceId);

  /// Writes one [CaptureCommand] byte to `fe08`.
  Future<void> writeCapture(String deviceId, CaptureCommand command);

  /// Subscribes to `fe08` and emits each notification, parsed.
  ///
  /// A malformed notification arrives as an error on the stream rather than as
  /// a made-up value, exactly as [subscribeBattery] does.
  Stream<CaptureFlags> subscribeCapture(String deviceId);

  Future<void> unsubscribeCapture(String deviceId);

  /// Signal strength of the LIVE link to [deviceId], in dBm.
  ///
  /// Not the same number as [DiscoveredDevice.rssi], which is one sample taken
  /// off an advertising packet at scan time and never updated afterwards. A
  /// range test needs the current link, so it needs this.
  ///
  /// Throws [BleTransportException] when the platform will not report it -
  /// which callers must render as unknown, never as 0 dBm.
  Future<int> readRssi(String deviceId);

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
