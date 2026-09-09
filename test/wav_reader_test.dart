import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/services/wav_reader.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

/// The reader is asserted against the project's OWN writer, never against a
/// header typed out by hand: a length shown in the library that disagrees with
/// the file the recorder wrote is a silent bug, so writer and reader are pinned
/// to each other here and cannot drift apart.
void main() {
  group('reads back exactly what WavWriter wrote', () {
    test('the recorder\'s own format: 16 kHz, 16-bit, mono', () {
      // 4.000 s of audio: 16000 Hz * 1 ch * 2 B = 32000 B/s.
      const dataLength = 128000;
      final header = WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
        dataLength: dataLength,
      );

      final parsed = WavReader.parse(header)!;

      expect(parsed.audioFormat, 1);
      expect(parsed.sampleRateHz, 16000);
      expect(parsed.channels, 1);
      expect(parsed.bitsPerSample, 16);
      expect(parsed.byteRate, 32000);
      expect(parsed.blockAlign, 2);
      expect(parsed.dataOffset, WavWriter.headerLength);
      expect(parsed.dataLength, dataLength);
      expect(parsed.duration, const Duration(seconds: 4));
    });

    test('every rate / channel / depth the writer accepts', () {
      const cases = <List<int>>[
        <int>[8000, 1, 16],
        <int>[16000, 1, 16],
        <int>[22050, 2, 16],
        <int>[44100, 2, 16],
        <int>[48000, 1, 8],
        <int>[96000, 2, 24],
      ];

      for (final c in cases) {
        final sampleRateHz = c[0];
        final channels = c[1];
        final bitsPerSample = c[2];
        final byteRate = sampleRateHz * channels * (bitsPerSample ~/ 8);
        // Exactly one second of audio, whatever the format.
        final header = WavWriter.buildHeader(
          sampleRateHz: sampleRateHz,
          channels: channels,
          bitsPerSample: bitsPerSample,
          dataLength: byteRate,
        );

        final parsed = WavReader.parse(header)!;
        expect(parsed.sampleRateHz, sampleRateHz, reason: '$c');
        expect(parsed.channels, channels, reason: '$c');
        expect(parsed.bitsPerSample, bitsPerSample, reason: '$c');
        expect(parsed.byteRate, byteRate, reason: '$c');
        expect(parsed.duration, const Duration(seconds: 1), reason: '$c');
      }
    });

    test('a whole file built by wrapPcm', () {
      final pcm = Uint8List(3200); // 0.1 s at 16 kHz mono 16-bit.
      final file = WavWriter.wrapPcm(
        pcm,
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      );

      final parsed = WavReader.parse(file)!;
      expect(parsed.dataLength, pcm.length);
      expect(parsed.dataOffset + parsed.dataLength, file.length);
      expect(parsed.duration, const Duration(milliseconds: 100));
    });

    test('the header the recorder patches on stop', () {
      // A capture writes a provisional header with dataLength 0, streams the
      // audio, then patches the two length fields - which is the state the
      // library actually reads.
      final header = WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      );
      expect(WavReader.parse(header)!.duration, Duration.zero);

      WavWriter.patchLengths(header, 32000);
      expect(WavReader.parse(header)!.dataLength, 32000);
      expect(WavReader.parse(header)!.duration, const Duration(seconds: 1));
    });

    test('the reader only needs the header, not the payload', () {
      final file = WavWriter.wrapPcm(
        Uint8List(64000),
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      );
      final headerOnly = Uint8List.sublistView(
        file,
        0,
        WavWriter.headerLength,
      );

      // The library reads 4 KiB off the front of a file, never the whole
      // thing; the declared length must still come back.
      expect(WavReader.parse(headerOnly)!.dataLength, 64000);
      expect(WavReader.parse(headerOnly)!.duration, const Duration(seconds: 2));
    });
  });

  group('malformed input returns null instead of throwing', () {
    Uint8List validHeader() => WavWriter.buildHeader(
          sampleRateHz: 16000,
          channels: 1,
          bitsPerSample: 16,
          dataLength: 32000,
        );

    test('empty', () => expect(WavReader.parse(Uint8List(0)), isNull));

    test('shorter than a RIFF header', () {
      expect(WavReader.parse(Uint8List(8)), isNull);
    });

    test('truncated part-way through the header', () {
      final header = validHeader();
      for (final length in <int>[12, 20, 36, 43]) {
        expect(
          WavReader.parse(Uint8List.sublistView(header, 0, length)),
          isNull,
          reason: 'truncated to $length bytes',
        );
      }
    });

    test('not a RIFF file', () {
      final header = validHeader();
      header[0] = 0x4A; // 'J'
      expect(WavReader.parse(header), isNull);
    });

    test('RIFF but not WAVE', () {
      final header = validHeader();
      header[8] = 0x41; // 'AVI '
      expect(WavReader.parse(header), isNull);
    });

    test('no data chunk', () {
      final header = validHeader();
      header[36] = 0x4C; // 'Lata'
      expect(WavReader.parse(header), isNull);
    });

    test('a fmt chunk too short to describe the audio', () {
      final header = validHeader();
      ByteData.sublistView(header).setUint32(16, 8, Endian.little);
      expect(WavReader.parse(header), isNull);
    });

    test('a chunk size that runs off the end', () {
      final header = validHeader();
      ByteData.sublistView(header).setUint32(16, 0xFFFFFFF0, Endian.little);
      expect(WavReader.parse(header), isNull);
    });

    test('random bytes', () {
      final noise = Uint8List.fromList(
        List<int>.generate(200, (i) => (i * 37 + 11) % 256),
      );
      expect(WavReader.parse(noise), isNull);
    });
  });

  group('durations', () {
    WavHeader header({int dataLength = 32000, int sampleRateHz = 16000}) =>
        WavReader.parse(
          WavWriter.buildHeader(
            sampleRateHz: sampleRateHz,
            channels: 1,
            bitsPerSample: 16,
            dataLength: dataLength,
          ),
        )!;

    test('a length is computed from the header fields, not the byte count', () {
      // Same payload size, different sample rate: the duration must follow the
      // header, which is the whole reason the rate is read at all.
      expect(header(sampleRateHz: 16000).duration, const Duration(seconds: 1));
      expect(
        header(sampleRateHz: 8000).duration,
        const Duration(seconds: 2),
      );
    });

    test('durationOf times a payload the file actually holds', () {
      final h = header(dataLength: 320000);
      expect(h.duration, const Duration(seconds: 10));
      // A capture killed mid-write leaves a header claiming more than is there.
      expect(h.durationOf(32000), const Duration(seconds: 1));
      expect(h.durationOf(0), Duration.zero);
      expect(h.durationOf(-1), isNull);
    });

    test('sub-second lengths keep their milliseconds', () {
      expect(
        header(dataLength: 1600).duration,
        const Duration(milliseconds: 50),
      );
    });
  });
}
