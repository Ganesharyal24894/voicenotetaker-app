import 'dart:typed_data';

/// Wire format of the `fe07` die-temperature characteristic.
///
/// Exactly two bytes: a little-endian SIGNED int16 in DECIDEGREES Celsius, so
/// `253` is 25.3 °C and `-41` is -4.1 °C. [unknownRaw] (`0x8000`, which is
/// `INT16_MIN`) means the device has no reading.
///
/// Pure data, like [BatteryStatus.fromBytes]: this is the device protocol, not
/// the BLE stack, so it lives in `model/` and survives a package swap.
///
/// THIS IS THE DIE, NOT THE ROOM. The figure is the nRF52840's own junction
/// temperature, read from its internal TEMP peripheral. The chip self-heats -
/// the radio and the CPU are inside the same package as the sensor - so it
/// reads well above ambient, and it reads higher still with a LiPo cell under
/// the board and plastic around both. Anything that renders this as "room
/// temperature" is wrong; every label the app puts on it says "die".
///
/// UNKNOWN IS NOT ZERO, and it is not cold either. `0x8000` is -3276.8 °C in
/// the wire's own units, which is why the sentinel is unambiguous: it lies far
/// outside anything the sensor can physically report. [deciCelsius] is
/// nullable rather than defaulting, for the same reason [BatteryStatus.percent]
/// is.
class DieTemperature {
  const DieTemperature({required this.deciCelsius});

  /// `0x8000` read as a signed int16 - the device has no reading to report.
  ///
  /// Written out as the signed value it decodes to, because that is what the
  /// comparison in [fromBytes] actually sees.
  static const int unknownRaw = -32768;

  /// The characteristic is exactly this long.
  static const int valueBytes = 2;

  /// Coldest reading accepted, in decidegrees: -50.0 °C.
  ///
  /// MATCHED TO THE FIRMWARE, not chosen here. `DIE_TEMP_IMPLAUSIBLE_LOW_DDC`
  /// in the device's `model/die_temp_model.h` is -500, and anything outside
  /// that window is replaced with [unknownRaw] before it reaches the wire. So
  /// -500 is the coldest value the device can send, and a narrower bound on
  /// this side would reject a reading the device considers real - which is the
  /// wrong direction to be wrong in.
  static const int minDeciCelsius = -500;

  /// Hottest reading accepted, in decidegrees: 150.0 °C, the firmware's
  /// `DIE_TEMP_IMPLAUSIBLE_HIGH_DDC`.
  ///
  /// Far above the 85 °C the part is rated for and above its 105 °C absolute
  /// maximum junction temperature, deliberately on both sides: a chip that is
  /// genuinely cooking inside a sealed case is exactly the finding this
  /// characteristic exists to deliver, and the bound is here to catch a
  /// protocol mismatch, not to hide heat.
  static const int maxDeciCelsius = 1500;

  /// Die temperature in tenths of a degree Celsius, or `null` when the device
  /// reported [unknownRaw].
  ///
  /// Null is a third state on purpose - see the class comment.
  final int? deciCelsius;

  /// Whether there is a reading to show at all.
  bool get hasReading => deciCelsius != null;

  /// The reading in whole degrees Celsius, or `null` when there is none.
  double? get celsius {
    final raw = deciCelsius;
    return raw == null ? null : raw / 10.0;
  }

  /// Reads the two bytes the characteristic carries.
  ///
  /// Throws [FormatException] on any length but two, on a byte outside
  /// `0 .. 255`, and on a reading outside [minDeciCelsius] ..
  /// [maxDeciCelsius]. Rejecting is deliberate, exactly as [BatteryStatus]
  /// rejects: a value the sensor cannot produce means the bytes are not what
  /// this build thinks they are, and putting an invented temperature in front
  /// of the user is worse than admitting there is none.
  static DieTemperature fromBytes(List<int> bytes) {
    if (bytes.length != valueBytes) {
      throw FormatException(
        'die temperature is $valueBytes bytes, got ${bytes.length}',
      );
    }
    for (final byte in bytes) {
      if (byte < 0 || byte > 0xFF) {
        throw FormatException('die temperature byte out of range: $byte');
      }
    }
    // Signed, little-endian, through `ByteData` rather than by hand: the sign
    // extension is exactly where a hand-rolled version gets it wrong.
    final raw = ByteData.sublistView(Uint8List.fromList(bytes))
        .getInt16(0, Endian.little);
    if (raw == unknownRaw) return const DieTemperature(deciCelsius: null);
    if (raw < minDeciCelsius || raw > maxDeciCelsius) {
      throw FormatException(
        'die temperature out of range: $raw decidegrees '
        '(${raw / 10.0} °C)',
      );
    }
    return DieTemperature(deciCelsius: raw);
  }

  @override
  String toString() => 'DieTemperature('
      '${deciCelsius == null ? 'unknown' : '${celsius!.toStringAsFixed(1)} °C die'})';

  @override
  bool operator ==(Object other) =>
      other is DieTemperature && other.deciCelsius == deciCelsius;

  @override
  int get hashCode => deciCelsius.hashCode;
}
