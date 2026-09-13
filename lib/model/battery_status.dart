/// Wire format of the `fe05` battery characteristic.
///
/// Exactly two bytes:
///
///   * `[0]` - charge percent, `0 .. 100`, or [unknownPercent] (`0xFF`) when
///     the device itself does not know. Every other value is a firmware this
///     build cannot read.
///   * `[1]` - flags. Bit 0 is [chargingBit]; every other bit is reserved and
///     must be zero.
///
/// Pure data, like [AutoSleep.fromBytes]: this is the device protocol, not the
/// BLE stack, so it lives in `model/` and survives a package swap.
///
/// UNKNOWN IS NOT ZERO. `0xFF` means the device has no reading, which is a
/// different fact from "the battery is empty", and the two must never render
/// the same way. That is why [percent] is nullable rather than defaulting.
class BatteryStatus {
  const BatteryStatus({required this.percent, required this.charging});

  /// `0xFF` in byte 0 - the device has no reading to report.
  static const int unknownPercent = 0xFF;

  /// Highest percentage the contract allows.
  static const int maxPercent = 100;

  /// Bit 0 of the flags byte - the cell is charging.
  static const int chargingBit = 0x01;

  /// Every other flag bit. Set in a value we read means a firmware newer than
  /// this build, and the flags are not ours to interpret.
  static const int reservedFlagBits = 0xFE;

  /// The characteristic is exactly this long.
  static const int valueBytes = 2;

  /// Charge in percent, or `null` when the device reported [unknownPercent].
  ///
  /// Null is a third state on purpose - see the class comment.
  final int? percent;

  /// Whether the cell is being charged. Known independently of [percent]: a
  /// device that cannot measure its charge can still tell that power is in.
  final bool charging;

  /// Whether there is a percentage to show at all.
  bool get hasPercent => percent != null;

  /// Reads the two bytes the characteristic carries.
  ///
  /// Throws [FormatException] on any length but two, on a percentage that is
  /// neither `0 .. 100` nor [unknownPercent], and on reserved flag bits set.
  /// Rejecting is deliberate: guessing what a future firmware meant by a byte
  /// this build does not understand would put an invented number in front of
  /// the user.
  static BatteryStatus fromBytes(List<int> bytes) {
    if (bytes.length != valueBytes) {
      throw FormatException(
        'battery status is $valueBytes bytes, got ${bytes.length}',
      );
    }
    final charge = bytes[0];
    final flags = bytes[1];
    if (charge > maxPercent && charge != unknownPercent) {
      throw FormatException('battery percent out of range: $charge');
    }
    if (flags & reservedFlagBits != 0) {
      throw FormatException(
        'reserved battery flag bits set: '
        '0x${flags.toRadixString(16).padLeft(2, '0')}',
      );
    }
    return BatteryStatus(
      percent: charge == unknownPercent ? null : charge,
      charging: flags & chargingBit != 0,
    );
  }

  @override
  String toString() =>
      'BatteryStatus(${percent == null ? 'unknown' : '$percent%'}'
      '${charging ? ', charging' : ''})';

  @override
  bool operator ==(Object other) =>
      other is BatteryStatus &&
      other.percent == percent &&
      other.charging == charging;

  @override
  int get hashCode => Object.hash(percent, charging);
}
