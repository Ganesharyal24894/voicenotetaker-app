import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

/// Asserts the exact 44-byte canonical RIFF/WAVE header, field by field at its
/// documented offset. Anything looser would let a byte-order or offset slip
/// through and produce files that some players open and others reject.
void main() {
  String ascii(Uint8List header, int offset) =>
      const AsciiDecoder().convert(header.sublist(offset, offset + 4));

  int u16(Uint8List header, int offset) =>
      ByteData.sublistView(header).getUint16(offset, Endian.little);

  int u32(Uint8List header, int offset) =>
      ByteData.sublistView(header).getUint32(offset, Endian.little);

  group('16 kHz / 16-bit / mono, the device default', () {
    late Uint8List header;

    setUp(() {
      header = WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
        dataLength: 32000,
      );
    });

    test('the header is exactly 44 bytes', () {
      expect(header.length, 44);
      expect(WavWriter.headerLength, 44);
    });

    test('offset 0..3  ChunkID is "RIFF"', () => expect(ascii(header, 0), 'RIFF'));

    test('offset 4..7  ChunkSize is 36 + dataLength', () {
      expect(u32(header, 4), 36 + 32000);
      expect(WavWriter.chunkSizeOffset, 4);
    });

    test('offset 8..11 Format is "WAVE"', () => expect(ascii(header, 8), 'WAVE'));

    test('offset 12..15 Subchunk1ID is "fmt " (trailing space)', () {
      expect(ascii(header, 12), 'fmt ');
    });

    test('offset 16..19 Subchunk1Size is 16', () => expect(u32(header, 16), 16));

    test('offset 20..21 AudioFormat is 1 (uncompressed PCM)', () {
      expect(u16(header, 20), 1);
    });

    test('offset 22..23 NumChannels is 1', () => expect(u16(header, 22), 1));

    test('offset 24..27 SampleRate is 16000', () => expect(u32(header, 24), 16000));

    test('offset 28..31 ByteRate is rate * channels * bytesPerSample', () {
      expect(u32(header, 28), 16000 * 1 * 2);
    });

    test('offset 32..33 BlockAlign is channels * bytesPerSample', () {
      expect(u16(header, 32), 2);
    });

    test('offset 34..35 BitsPerSample is 16', () => expect(u16(header, 34), 16));

    test('offset 36..39 Subchunk2ID is "data"', () {
      expect(ascii(header, 36), 'data');
    });

    test('offset 40..43 Subchunk2Size is dataLength', () {
      expect(u32(header, 40), 32000);
      expect(WavWriter.dataSizeOffset, 40);
    });

    test('the raw bytes are exactly the expected header', () {
      expect(
        header,
        equals(Uint8List.fromList(<int>[
          0x52, 0x49, 0x46, 0x46, // "RIFF"
          0x24, 0x7D, 0x00, 0x00, // 32036
          0x57, 0x41, 0x56, 0x45, // "WAVE"
          0x66, 0x6D, 0x74, 0x20, // "fmt "
          0x10, 0x00, 0x00, 0x00, // 16
          0x01, 0x00, //             PCM
          0x01, 0x00, //             1 channel
          0x80, 0x3E, 0x00, 0x00, // 16000
          0x00, 0x7D, 0x00, 0x00, // 32000 byte/s
          0x02, 0x00, //             block align 2
          0x10, 0x00, //             16 bits
          0x64, 0x61, 0x74, 0x61, // "data"
          0x00, 0x7D, 0x00, 0x00, // 32000
        ])),
      );
    });
  });

  group('other formats', () {
    test('stereo 44.1 kHz 16-bit derives ByteRate and BlockAlign', () {
      final header = WavWriter.buildHeader(
        sampleRateHz: 44100,
        channels: 2,
        bitsPerSample: 16,
      );
      expect(u32(header, 24), 44100);
      expect(u16(header, 22), 2);
      expect(u16(header, 32), 4);
      expect(u32(header, 28), 44100 * 4);
    });

    test('8-bit mono derives BlockAlign 1', () {
      final header = WavWriter.buildHeader(
        sampleRateHz: 8000,
        channels: 1,
        bitsPerSample: 8,
      );
      expect(u16(header, 32), 1);
      expect(u32(header, 28), 8000);
    });
  });

  group('provisional header and patching', () {
    test('dataLength defaults to 0, giving ChunkSize 36', () {
      final header = WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      );
      expect(u32(header, 4), 36);
      expect(u32(header, 40), 0);
    });

    test('patchLengths rewrites both length fields in place', () {
      final header = WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      );
      WavWriter.patchLengths(header, 12345);
      expect(u32(header, 4), 36 + 12345);
      expect(u32(header, 40), 12345);
    });

    test('patchLengths leaves every other byte untouched', () {
      final built = WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
        dataLength: 999,
      );
      final patched = WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      );
      WavWriter.patchLengths(patched, 999);
      expect(patched, equals(built));
    });

    test('the patch byte helpers match the fields they replace', () {
      final header = WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
        dataLength: 4096,
      );
      expect(
        WavWriter.chunkSizeBytes(4096),
        equals(header.sublist(4, 8)),
      );
      expect(
        WavWriter.dataSizeBytes(4096),
        equals(header.sublist(40, 44)),
      );
    });

    test('patchLengths rejects a buffer shorter than the header', () {
      expect(
        () => WavWriter.patchLengths(Uint8List(43), 0),
        throwsArgumentError,
      );
    });
  });

  group('wrapPcm', () {
    test('places the payload immediately after the 44-byte header', () {
      final pcm = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final wav = WavWriter.wrapPcm(
        pcm,
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      );
      expect(wav.length, 44 + 64);
      expect(u32(wav, 40), 64);
      expect(u32(wav, 4), 36 + 64);
      expect(wav.sublist(44), equals(pcm));
    });

    test('an empty payload still produces a valid 44-byte file', () {
      final wav = WavWriter.wrapPcm(
        Uint8List(0),
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      );
      expect(wav.length, 44);
      expect(u32(wav, 40), 0);
    });
  });

  group('argument validation', () {
    test('rejects a non-positive sample rate', () {
      expect(
        () => WavWriter.buildHeader(
            sampleRateHz: 0, channels: 1, bitsPerSample: 16),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive channel count', () {
      expect(
        () => WavWriter.buildHeader(
            sampleRateHz: 16000, channels: 0, bitsPerSample: 16),
        throwsArgumentError,
      );
    });

    test('rejects a bit depth that is not a multiple of 8', () {
      expect(
        () => WavWriter.buildHeader(
            sampleRateHz: 16000, channels: 1, bitsPerSample: 12),
        throwsArgumentError,
      );
    });

    test('rejects a negative data length', () {
      expect(
        () => WavWriter.buildHeader(
          sampleRateHz: 16000,
          channels: 1,
          bitsPerSample: 16,
          dataLength: -1,
        ),
        throwsArgumentError,
      );
    });
  });
}
