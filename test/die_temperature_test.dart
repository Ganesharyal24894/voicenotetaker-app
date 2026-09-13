import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/die_temperature.dart';

/// `fe07` is two bytes and exactly two bytes: a little-endian SIGNED int16 in
/// decidegrees Celsius, with `0x8000` meaning the device has no reading.
///
/// The two things these tests exist to pin down are the SIGN and the SENTINEL.
/// A hand-rolled little-endian read that forgets to sign-extend turns -4.1 °C
/// into +6549.5 °C, and a build that reads `0x8000` as a number rather than as
/// "unknown" reports -3276.8 °C - either of which would be shown to someone
/// deciding whether their enclosure is cooking the board.
void main() {
  Uint8List bytes(int lo, int hi) => Uint8List.fromList(<int>[lo, hi]);

  group('the wire format', () {
    test('253 decidegrees is 25.3 degrees', () {
      final reading = DieTemperature.fromBytes(bytes(0xFD, 0x00));
      expect(reading.deciCelsius, 253);
      expect(reading.celsius, closeTo(25.3, 1e-9));
      expect(reading.hasReading, isTrue);
    });

    test('the bytes are little-endian, not big-endian', () {
      // 0x01F4 = 500 = 50.0 C. Read the other way round it is 0xF401, which is
      // negative and out of range - so a byte-swap cannot pass silently.
      expect(DieTemperature.fromBytes(bytes(0xF4, 0x01)).deciCelsius, 500);
      expect(
        () => DieTemperature.fromBytes(bytes(0x01, 0xF4)),
        throwsFormatException,
      );
    });

    test('a negative reading is sign-extended, not read as a huge positive',
        () {
      // -41 decidegrees = 0xFFD7. An unsigned read gives 65495, which is
      // +6549.5 C - the exact bug this asserts against.
      final reading = DieTemperature.fromBytes(bytes(0xD7, 0xFF));
      expect(reading.deciCelsius, -41);
      expect(reading.celsius, closeTo(-4.1, 1e-9));
    });

    test('the bounds are the firmware\'s own, not narrower', () {
      // -500 and 1500 decidegrees: DIE_TEMP_IMPLAUSIBLE_LOW_DDC and
      // DIE_TEMP_IMPLAUSIBLE_HIGH_DDC on the device. The firmware replaces
      // anything outside that with the unknown sentinel before sending, so
      // these are exactly the extremes that can arrive - and a narrower window
      // here would throw away a reading the device thinks is real.
      expect(DieTemperature.minDeciCelsius, -500);
      expect(DieTemperature.maxDeciCelsius, 1500);
      expect(
        DieTemperature.fromBytes(bytes(0x0C, 0xFE)).deciCelsius,
        DieTemperature.minDeciCelsius,
      );
      expect(
        DieTemperature.fromBytes(bytes(0xDC, 0x05)).deciCelsius,
        DieTemperature.maxDeciCelsius,
      );
    });

    test('a genuinely hot die is a reading, not a rejection', () {
      // 95.0 C is above the part's rated 85 and is exactly the fact an
      // enclosure test is looking for. It must not be filtered away.
      final reading = DieTemperature.fromBytes(bytes(0xB6, 0x03));
      expect(reading.celsius, closeTo(95.0, 1e-9));
    });
  });

  group('unknown', () {
    test('0x8000 is unknown, not -3276.8 degrees', () {
      final reading = DieTemperature.fromBytes(bytes(0x00, 0x80));
      expect(reading.deciCelsius, isNull);
      expect(reading.celsius, isNull);
      expect(reading.hasReading, isFalse);
    });

    test('unknown is not zero', () {
      // The bug: a build that defaults a missing reading to 0 reports a
      // freezing chip, which reads as a plausible cold room.
      final unknown = DieTemperature.fromBytes(bytes(0x00, 0x80));
      final freezing = DieTemperature.fromBytes(bytes(0x00, 0x00));
      expect(unknown.celsius, isNull);
      expect(freezing.celsius, 0.0);
      expect(unknown, isNot(freezing));
    });

    test('unknown says so rather than printing a number', () {
      expect(
        DieTemperature.fromBytes(bytes(0x00, 0x80)).toString(),
        contains('unknown'),
      );
    });
  });

  group('malformed values are rejected, never guessed', () {
    test('one byte is not a temperature', () {
      expect(
        () => DieTemperature.fromBytes(<int>[0xFD]),
        throwsFormatException,
      );
    });

    test('three bytes is not a temperature either', () {
      expect(
        () => DieTemperature.fromBytes(<int>[0xFD, 0x00, 0x00]),
        throwsFormatException,
      );
    });

    test('an empty value is rejected', () {
      expect(() => DieTemperature.fromBytes(<int>[]), throwsFormatException);
    });

    test('a reading below anything the firmware can send is rejected', () {
      // -60.0 C = -600 decidegrees = 0xFDA8, past the firmware's own floor, so
      // the bytes are not what this build thinks they are.
      expect(
        () => DieTemperature.fromBytes(bytes(0xA8, 0xFD)),
        throwsFormatException,
      );
    });

    test('a reading above anything the firmware can send is rejected', () {
      // 200.0 C = 2000 decidegrees = 0x07D0, past the firmware's own ceiling.
      expect(
        () => DieTemperature.fromBytes(bytes(0xD0, 0x07)),
        throwsFormatException,
      );
    });

    test('a byte outside 0..255 is rejected', () {
      expect(
        () => DieTemperature.fromBytes(<int>[300, 0]),
        throwsFormatException,
      );
    });
  });

  group('value semantics', () {
    test('two readings of the same die are equal', () {
      expect(
        const DieTemperature(deciCelsius: 312),
        const DieTemperature(deciCelsius: 312),
      );
      expect(
        const DieTemperature(deciCelsius: 312).hashCode,
        const DieTemperature(deciCelsius: 312).hashCode,
      );
    });

    test('it names itself as a die temperature', () {
      expect(
        const DieTemperature(deciCelsius: 312).toString(),
        contains('die'),
      );
    });
  });
}
