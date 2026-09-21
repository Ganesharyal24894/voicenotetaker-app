import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/device_profile.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';

/// The `fe02` characteristic is packed little-endian:
/// uint32 sampleRateHz, uint8 bitsPerSample, uint8 channels, uint8 codec,
/// uint8 reserved.
void main() {
  Uint8List packed({
    int sampleRate = 16000,
    int bits = 16,
    int channels = 1,
    int codec = 1,
    int reserved = 0,
  }) {
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes)
      ..setUint32(0, sampleRate, Endian.little)
      ..setUint8(4, bits)
      ..setUint8(5, channels)
      ..setUint8(6, codec)
      ..setUint8(7, reserved);
    return bytes;
  }

  group('AudioCodec', () {
    test('wire values match the firmware control byte', () {
      expect(AudioCodec.pcmS16le.wireValue, 0);
      expect(AudioCodec.imaAdpcm.wireValue, 1);
      expect(AudioCodec.opusCelt.wireValue, 2);
    });

    test('codecs are appended, never renumbered', () {
      // The firmware and the host tooling share these numbers. A new codec
      // goes on the end; the order of the enum IS the order of the wire.
      expect(
        AudioCodec.values.map((c) => c.wireValue).toList(),
        [for (var i = 0; i < AudioCodec.values.length; i++) i],
      );
    });

    test('the Opus codec byte is the one the firmware sends', () {
      // AUDIO_CODEC_OPUS_CELT = 2 in the firmware's model/audio_format.h.
      expect(AudioCodec.fromWire(2), AudioCodec.opusCelt);
    });

    test('fromWire round-trips every known codec', () {
      for (final codec in AudioCodec.values) {
        expect(AudioCodec.fromWire(codec.wireValue), codec);
      }
    });

    test('an unknown codec byte maps to null rather than a wrong codec', () {
      expect(AudioCodec.fromWire(3), isNull);
      expect(AudioCodec.fromWire(255), isNull);
    });
  });

  group('StreamInfo.fromBytes', () {
    test('parses the device default: 16 kHz, 16-bit, mono, ADPCM', () {
      final info = StreamInfo.fromBytes(packed());
      expect(info.sampleRateHz, 16000);
      expect(info.bitsPerSample, 16);
      expect(info.channels, 1);
      expect(info.codec, AudioCodec.imaAdpcm);
      expect(info.rawCodec, 1);
    });

    test('reads the sample rate little-endian', () {
      // 44100 = 0x0000AC44 -> 0x44 0xAC 0x00 0x00.
      final bytes = Uint8List.fromList([0x44, 0xAC, 0, 0, 16, 2, 0, 0]);
      final info = StreamInfo.fromBytes(bytes);
      expect(info.sampleRateHz, 44100);
      expect(info.channels, 2);
      expect(info.codec, AudioCodec.pcmS16le);
    });

    test('keeps the raw byte for a codec this build does not know', () {
      final info = StreamInfo.fromBytes(packed(codec: 7));
      expect(info.codec, isNull);
      expect(info.rawCodec, 7);
    });

    test('ignores the reserved byte', () {
      expect(
        StreamInfo.fromBytes(packed(reserved: 0xFF)),
        StreamInfo.fromBytes(packed()),
      );
    });

    test('accepts a characteristic longer than 8 bytes', () {
      final long = Uint8List(12)..setRange(0, 8, packed());
      expect(StreamInfo.fromBytes(long).sampleRateHz, 16000);
    });

    test('rejects a truncated characteristic', () {
      expect(
        () => StreamInfo.fromBytes(Uint8List(7)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('derived values', () {
    test('decodedByteRate is rate * channels * bytesPerSample', () {
      expect(StreamInfo.fromBytes(packed()).decodedByteRate, 32000);
      expect(
        StreamInfo.fromBytes(packed(sampleRate: 44100, channels: 2))
            .decodedByteRate,
        44100 * 2 * 2,
      );
    });

    test('the fallback matches what the reference host tool assumes', () {
      expect(StreamInfo.fallback.sampleRateHz, 16000);
      expect(StreamInfo.fallback.bitsPerSample, 16);
      expect(StreamInfo.fallback.channels, 1);
      expect(StreamInfo.fallback.codec, AudioCodec.pcmS16le);
    });
  });

  group('DeviceProfile', () {
    test('an ADPCM block is 164 bytes: 4 header + 320 nibbles', () {
      expect(DeviceProfile.adpcmBlockBytes, 164);
      expect(DeviceProfile.adpcmSamplesPerBlock, 320);
      expect(DeviceProfile.adpcmBlockHeaderBytes, 4);
      expect(DeviceProfile.sequenceHeaderBytes, 2);
    });

    test('the characteristic UUIDs sit inside the service', () {
      expect(DeviceProfile.serviceUuid, startsWith('6e40fe00-'));
      expect(DeviceProfile.dataCharacteristicUuid, startsWith('6e40fe01-'));
      expect(DeviceProfile.infoCharacteristicUuid, startsWith('6e40fe02-'));
      expect(DeviceProfile.controlCharacteristicUuid, startsWith('6e40fe03-'));
      const suffix = 'b5a3-f393-e0a9-e50e24dcca9e';
      for (final uuid in [
        DeviceProfile.serviceUuid,
        DeviceProfile.dataCharacteristicUuid,
        DeviceProfile.infoCharacteristicUuid,
        DeviceProfile.controlCharacteristicUuid,
      ]) {
        expect(uuid, endsWith(suffix));
      }
    });

    test('the advertised name matches the firmware', () {
      expect(DeviceProfile.advertisedName, 'voiceNotetaker');
    });
  });
}
