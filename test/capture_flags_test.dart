import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/device_profile.dart';

/// The `fe08` wire format: one byte each way, and nothing guessed.
void main() {
  group('CaptureFlags.fromBytes', () {
    test('all clear is gate disabled, privacy mode off, silent', () {
      expect(
        CaptureFlags.fromBytes(<int>[0x00]),
        const CaptureFlags(privacyMode: false, speechOpen: false, gateEnabled: false),
      );
    });

    test('each bit is its own flag', () {
      expect(CaptureFlags.fromBytes(<int>[0x01]).privacyMode, isTrue);
      expect(CaptureFlags.fromBytes(<int>[0x02]).speechOpen, isTrue);
      expect(CaptureFlags.fromBytes(<int>[0x04]).gateEnabled, isTrue);
      expect(CaptureFlags.fromBytes(<int>[0x08]).micOff, isTrue);
      expect(CaptureFlags.fromBytes(<int>[0x04]).micOff, isFalse);
      expect(
        CaptureFlags.fromBytes(<int>[0x07]),
        const CaptureFlags(privacyMode: true, speechOpen: true, gateEnabled: true),
      );
    });

    test('a value that is not one byte is refused', () {
      expect(() => CaptureFlags.fromBytes(<int>[]), throwsFormatException);
      expect(
        () => CaptureFlags.fromBytes(<int>[0x04, 0x00]),
        throwsFormatException,
      );
    });

    test('reserved bits are refused rather than half-read', () {
      expect(() => CaptureFlags.fromBytes(<int>[0x10]), throwsFormatException);
      expect(() => CaptureFlags.fromBytes(<int>[0x80]), throwsFormatException);
      expect(() => CaptureFlags.fromBytes(<int>[0xFF]), throwsFormatException);
    });
  });

  // CaptureCommand.mute / .unmute keep the firmware's names on purpose: the
  // values go on the wire. The feature is called privacy mode in the UI.
  test('the four commands are the bytes the firmware defines', () {
    expect(CaptureCommand.gateDisabled.toBytes(), <int>[0]);
    expect(CaptureCommand.gateEnabled.toBytes(), <int>[1]);
    expect(CaptureCommand.mute.toBytes(), <int>[2]);
    expect(CaptureCommand.unmute.toBytes(), <int>[3]);
  });

  test('fe08 lives in the recorder service', () {
    expect(
      DeviceProfile.captureCharacteristicUuid,
      '6e40fe08-b5a3-f393-e0a9-e50e24dcca9e',
    );
  });
}
