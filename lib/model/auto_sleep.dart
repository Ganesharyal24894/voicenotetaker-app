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
  const AutoSleepSetting({required this.enabled, required this.duration});

  /// Whether the recorder sleeps by itself.
  final bool enabled;

  /// The duration in force; [AutoSleepDuration.off] when [enabled] is false.
  ///
  /// The recorder keeps the duration the user chose even while off, but it
  /// reports code 0 rather than that duration, so this is what it is DOING,
  /// not what it would do if switched on.
  final AutoSleepDuration duration;

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
/// TWO BYTES, `[flags, code]`, each way: flags bit 0 must equal `code != 0`,
/// every other flag bit is reserved, and the code is 0..4.
///
/// Anything else is refused rather than guessed at, because this setting
/// decides whether the recorder puts itself to sleep.
///
/// Pure data, like [StreamInfo.fromBytes]: this is the device protocol, not
/// the BLE stack, so it lives in `model/` and survives a package swap.
abstract final class AutoSleep {
  /// Bit 0 of the flags byte - auto-sleep enabled.
  static const int enabledBit = 0x01;

  /// Every other bit of the flags byte.
  static const int reservedBits = 0xFE;

  /// The one length, read and written.
  static const int wireBytes = 2;

  /// Reads a characteristic value.
  ///
  /// Throws [FormatException] on any other length, reserved bits, an unknown
  /// code, or flags that disagree with the code.
  static AutoSleepSetting fromBytes(List<int> bytes) {
    if (bytes.length != wireBytes) {
      throw FormatException(
        'auto-sleep is $wireBytes bytes, got ${bytes.length}',
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

  /// The two bytes for [duration]. [AutoSleepDuration.off] turns auto-sleep
  /// off; the recorder keeps the duration the user last chose.
  static Uint8List durationToBytes(AutoSleepDuration duration) =>
      Uint8List.fromList(<int>[
        duration == AutoSleepDuration.off ? 0x00 : enabledBit,
        duration.code,
      ]);
}
