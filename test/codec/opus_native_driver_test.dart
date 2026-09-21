import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/opus_library.dart';
import 'package:voicenotetaker_app/model/audio_frame.dart';
import 'package:voicenotetaker_app/services/codec/opus_stream_decoder.dart';

import 'opus_fixture.dart';

/// The vendored libopus through the app's driver when things go wrong: bad
/// packets, misuse of the native decoder, and whether native memory comes
/// back. The good path against the device's bitstream is
/// `opus_golden_test.dart`.
void main() {
  late OpusFixture fx;
  late List<Uint8List> packets;
  const library = OpusFixture.library;

  setUpAll(() {
    fx = OpusFixture.load();
    packets = fx.packets;
  });

  group('corrupt input', () {
    test(
      'a truncated packet costs one 20 ms frame and the stream carries on',
      () {
        final decoder = OpusStreamDecoder(library: library);
        addTearDown(decoder.dispose);
        for (var i = 0; i < 10; i++) {
          decoder.decode(
            AudioFrame(sequence: i, payload: packets[i], droppedBefore: 0),
          );
        }
        // A CELT packet cut to its TOC byte and one more is not decodable;
        // libopus says so, and the app conceals instead.
        final cut = Uint8List.sublistView(packets[10], 0, 2);
        expect(
          decoder.decode(
            AudioFrame(sequence: 10, payload: cut, droppedBefore: 0),
          ),
          hasLength(640),
        );
        expect(
          decoder.decode(
            AudioFrame(sequence: 11, payload: packets[11], droppedBefore: 0),
          ),
          hasLength(640),
        );
      },
    );

    test('a packet with an impossible TOC is refused by libopus', () {
      final native = library.openDecoder(sampleRateHz: 16000, channels: 1);
      addTearDown(native.close);
      // Code 3 (arbitrary frame count) with no count byte after it.
      expect(
        () =>
            native.decode(packet: Uint8List.fromList([0xbb]), maxSamples: 1920),
        throwsA(isA<OpusException>()),
      );
    });

    test(
      'random bytes never crash the decoder or produce the wrong length',
      () {
        final decoder = OpusStreamDecoder(library: library);
        addTearDown(decoder.dispose);
        final rng = math.Random(20260921);
        for (var i = 0; i < 500; i++) {
          final junk = Uint8List.fromList(
            List.generate(1 + rng.nextInt(80), (_) => rng.nextInt(256)),
          );
          final pcm = decoder.decode(
            AudioFrame(sequence: i, payload: junk, droppedBefore: 0),
          );
          // A valid-looking TOC may carry any Opus frame length; whatever
          // comes back is whole samples and never more than 120 ms.
          expect(pcm.length.isEven, isTrue);
          expect(pcm.length, lessThanOrEqualTo(1920 * 2));
        }
      },
    );
  });

  group('the native driver', () {
    test('refuses an empty packet instead of concealing its whole buffer', () {
      // libopus reads zero bytes as loss and would invent maxSamples - 120 ms
      // here. Concealment is asked for with null, a frame at a time.
      final native = library.openDecoder(sampleRateHz: 16000, channels: 1);
      addTearDown(native.close);
      expect(
        () => native.decode(packet: Uint8List(0), maxSamples: 1920),
        throwsA(isA<OpusException>()),
      );
      expect(native.decode(maxSamples: 320), hasLength(320));
    });

    test('the Android library is linked against libm', () {
      // libopus calls cos/exp/log. Without -lm the Android .so still builds
      // but names no libm.so, and bionic refuses to load it on a phone. The
      // host test process has libm already, so no decode here can notice -
      // this reads the hook instead. Verified on the built APK with
      // llvm-readelf: NEEDED libm.so, cos@LIBC.
      final hook = File('packages/opus_native/hook/build.dart')
          .readAsStringSync();
      expect(hook, contains("libraries: const ['m']"));
    });
  });

  group('the native decoder\'s lifecycle', () {
    test('closing twice is safe, and decoding after close is refused', () {
      final native = library.openDecoder(sampleRateHz: 16000, channels: 1);
      native.close();
      native.close();
      expect(
        () => native.decode(packet: packets.first, maxSamples: 1920),
        throwsA(isA<OpusException>()),
      );
    });

    test('an impossible format is refused at open', () {
      expect(
        () => library.openDecoder(sampleRateHz: 44100, channels: 1),
        throwsA(isA<OpusException>()),
      );
    });

    test(
      'opening and closing ten thousand decoders does not grow the process',
      () {
        // Each libopus decoder state is ~18 kB plus the driver's buffers.
        // Measured on x86-64: with opus_decoder_destroy removed, 10,000
        // streams grow RSS by 178 MB; with it, by -2.5 to +0.3 MB once the
        // first round has warmed the allocator. At 1,000 streams the two were
        // too close to call, which is why this churns so many.
        int rssKb() {
          final line = File('/proc/self/status')
              .readAsLinesSync()
              .firstWhere((l) => l.startsWith('VmRSS:'));
          return int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!);
        }

        void churn() {
          for (var i = 0; i < 5000; i++) {
            final d = OpusStreamDecoder(library: library);
            d.decode(
              AudioFrame(
                sequence: 0,
                payload: packets[i % 250],
                droppedBefore: 1,
              ),
            );
            d.dispose();
          }
        }

        churn(); // warm up allocator pools
        final before = rssKb();
        churn();
        churn();
        expect(rssKb() - before, lessThan(40000));
      },
      skip: !Platform.isLinux ? 'reads /proc/self/status' : false,
    );
  });
}
