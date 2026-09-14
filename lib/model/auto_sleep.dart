import 'dart:typed_data';

/// How long the recorder waits, still, before it puts itself to sleep.
///
/// The wire codes are the firmware's (`fe04` byte 1): `0` off, `1` 30 s,
/// `2` 1 min, `3` 2 min, `4` 5 min. See the firmware's
/// `doc/continuous-mode.md`, "Auto-sleep duration".
enum AutoSleepDuration {
  off(0, null),
  seconds30(1, Duration(seconds: 30)),
  minute1(2, Duration(minutes: 1)),
  minutes2(3, Duration(minutes: 2)),
  minutes5(4, Duration(minutes: 5));

  const AutoSleepDuration(this.code, this.stillFor);

  /// The code on the wire.
  final int code;

  /// How long the recorder must be still; null for [off].
  final Duration? stillFor;

  /// The duration for a wire [code], or null for a code this build does not
  /// know.
  static AutoSleepDuration? fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

/// What the recorder reported about auto-sleep.
class AutoSleepSetting {
  const AutoSleepSetting({required this.enabled, this.duration});

  /// Firmware that only knows on/off (the one-byte form).
  const AutoSleepSetting.legacy(this.enabled) : duration = null;

  /// Whether the recorder sleeps by itself.
  final bool enabled;

  /// The duration in force, or null when the firmware predates durations and
  /// cannot be told one. [AutoSleepDuration.off] when off on new firmware.
  final AutoSleepDuration? duration;

  /// Whether this firmware takes a duration - the two-byte form.
  bool get supportsDuration => duration != null;

  @override
  bool operator ==(Object other) =>
      other is AutoSleepSetting &&
      other.enabled == enabled &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(enabled, duration);

  @override
  String toString() => 'AutoSleepSetting(enabled: $enabled, duration: $duration)';
}

/// Wire format of the `fe04` auto-sleep characteristic.
///
/// TWO FORMS, and the READ LENGTH says which firmware this is:
///
///   * one byte - older firmware: bit 0 on/off, every other bit reserved;
///   * two bytes `[flags, code]` - firmware with durations: flags bit 0 must
///     equal `code != 0`, other flag bits reserved, code 0..4.
///
/// A value outside either form is refused rather than guessed at, because this
/// setting decides whether the recorder puts itself to sleep.
///
/// Pure data, like [StreamInfo.fromBytes]: this is the device protocol, not
/// the BLE stack, so it lives in `model/` and survives a package swap.
abstract final class AutoSleep {
  /// Bit 0 of the (first) byte - auto-sleep enabled.
  static const int enabledBit = 0x01;

  /// Every other bit of the (first) byte.
  static const int reservedBits = 0xFE;

  /// The legacy, on/off-only length.
  static const int legacyBytes = 1;

  /// The length that carries a duration.
  static const int durationBytes = 2;

  /// Reads a characteristic value in either form.
  ///
  /// Throws [FormatException] on any other length, reserved bits, an unknown
  /// code, or flags that disagree with the code.
  static AutoSleepSetting fromBytes(List<int> bytes) {
    if (bytes.length != legacyBytes && bytes.length != durationBytes) {
      throw FormatException(
        'auto-sleep is $legacyBytes or $durationBytes bytes, got ${bytes.length}',
      );
    }
    final flags = bytes.first;
    if (flags & reservedBits != 0) {
      throw FormatException(
        'reserved auto-sleep bits set: '
        '0x${flags.toRadixString(16).padLeft(2, '0')}',
      );
    }
    final enabled = flags & enabledBit != 0;
    if (bytes.length == legacyBytes) return AutoSleepSetting.legacy(enabled);
    final duration = AutoSleepDuration.fromCode(bytes[1]);
    if (duration == null) {
      throw FormatException('unknown auto-sleep code ${bytes[1]}');
    }
    if (enabled != (duration != AutoSleepDuration.off)) {
      throw FormatException(
        'auto-sleep flags say ${enabled ? 'on' : 'off'} but code is ${bytes[1]}',
      );
    }
    return AutoSleepSetting(enabled: enabled, duration: duration);
  }

  /// The legacy single byte: `0x01` to enable, `0x00` to disable. The
  /// firmware keeps its stored duration.
  static Uint8List toBytes(bool enabled) =>
      Uint8List.fromList(<int>[enabled ? enabledBit : 0x00]);

  /// The two-byte form for [duration].
  static Uint8List durationToBytes(AutoSleepDuration duration) =>
      Uint8List.fromList(<int>[
        duration == AutoSleepDuration.off ? 0x00 : enabledBit,
        duration.code,
      ]);
}
