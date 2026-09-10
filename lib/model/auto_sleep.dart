import 'dart:typed_data';

/// Wire format of the `fe04` auto-sleep characteristic.
///
/// Exactly one byte: bit 0 carries the flag, every other bit is reserved and
/// must be zero. The firmware rejects any other length and any other bit
/// pattern, so the app writes nothing else - and refuses to interpret
/// anything else rather than guess what a future firmware meant by it.
///
/// Pure data, like [StreamInfo.fromBytes]: this is the device protocol, not
/// the BLE stack, so it lives in `model/` and survives a package swap.
abstract final class AutoSleep {
  /// Bit 0 - auto-sleep enabled.
  static const int enabledBit = 0x01;

  /// Every other bit. Set in a value we read means a firmware newer than this
  /// build, and the flag is not ours to interpret.
  static const int reservedBits = 0xFE;

  /// The characteristic is exactly this long, in both directions.
  static const int valueBytes = 1;

  /// Reads the flag out of a characteristic value.
  ///
  /// Throws [FormatException] on any length but one byte, or on a value with
  /// reserved bits set.
  static bool fromBytes(List<int> bytes) {
    if (bytes.length != valueBytes) {
      throw FormatException(
        'auto-sleep is $valueBytes byte, got ${bytes.length}',
      );
    }
    final value = bytes.first;
    if (value & reservedBits != 0) {
      throw FormatException(
        'reserved auto-sleep bits set: '
        '0x${value.toRadixString(16).padLeft(2, '0')}',
      );
    }
    return value & enabledBit != 0;
  }

  /// The single byte to write: `0x01` to enable, `0x00` to disable.
  static Uint8List toBytes(bool enabled) =>
      Uint8List.fromList(<int>[enabled ? enabledBit : 0x00]);
}
