import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/opus_library.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/audio_frame.dart';
import 'package:voicenotetaker_app/services/codec/opus_stream_decoder.dart';

import 'fake_opus.dart';

/// The rules of turning notifications into PCM, against a fake libopus. What
/// libopus itself does with a real packet is `opus_golden_test.dart`'s job.
void main() {
  late FakeOpusLibrary library;
  late OpusStreamDecoder decoder;

  FakeOpusDecoder native() => library.opened.single;

  AudioFrame frame(List<int> payload, {int droppedBefore = 0, int seq = 0}) =>
      AudioFrame(
        sequence: seq,
        payload: Uint8List.fromList(payload),
        droppedBefore: droppedBefore,
      );

  /// The s16le bytes back as samples.
  List<int> samples(Uint8List pcm) {
    final view = ByteData.sublistView(pcm);
    return [
      for (var i = 0; i < pcm.length; i += 2) view.getInt16(i, Endian.little),
    ];
  }

  setUp(() {
    library = FakeOpusLibrary();
    decoder = OpusStreamDecoder(library: library);
  });

  tearDown(() => decoder.dispose());

  group('opening', () {
    test('opens one native decoder at the stream format', () {
      expect(library.opened, hasLength(1));
      expect(native().sampleRateHz, 16000);
      expect(native().channels, 1);
      expect(decoder.codec, AudioCodec.opusCelt);
    });

    test('a 20 ms frame at 16 kHz is 320 samples', () {
      expect(decoder.frameSamples, 320);
    });

    test('a refusal from libopus surfaces at open, not at the first frame', () {
      library.refuseWith = const OpusException('bad arg', -1);
      expect(
        () => OpusStreamDecoder(library: library),
        throwsA(isA<OpusException>()),
      );
    });
  });

  group('a packet that arrived', () {
    test('decodes to 320 samples = 640 little-endian bytes', () {
      final pcm = decoder.decode(frame([7, 1, 2, 3]));
      expect(pcm, hasLength(640));
      expect(samples(pcm), everyElement(7));
    });

    test('gives libopus room for the longest Opus frame, not just 20 ms', () {
      // Opus packets carry their own duration. A buffer sized to exactly one
      // expected frame would turn any longer packet into a decode failure.
      decoder.decode(frame([7]));
      expect(native().calls.single.maxSamples, 1920); // 120 ms at 16 kHz
    });

    test('samples come out little-endian, negatives as two\'s complement', () {
      native().packetSamples = 1;
      expect(decoder.decode(frame([0x80])), [0x80, 0x00]); // 128
      // A concealed frame from the fake is all -1: 0xFFFF on the wire.
      expect(decoder.decode(frame([])).sublist(0, 2), [0xFF, 0xFF]);
    });

    test('passes the packet bytes through untouched', () {
      decoder.decode(frame([9, 8, 7]));
      expect(native().calls.single.packet, [9, 8, 7]);
    });
  });

  group('a packet that did not arrive', () {
    test('a gap of one is concealed with one invented 20 ms frame', () {
      final pcm = decoder.decode(frame([7], droppedBefore: 1));
      expect(pcm, hasLength(2 * 640));
      final s = samples(pcm);
      // Concealed audio first, where the missing audio was, then the packet.
      expect(s.sublist(0, 320), everyElement(FakeOpusDecoder.concealedSample));
      expect(s.sublist(320), everyElement(7));
    });

    test('concealment asks libopus for exactly one frame, with no packet', () {
      decoder.decode(frame([7], droppedBefore: 1));
      final conceal = native().calls.first;
      expect(conceal.packet, isNull);
      // For a null packet, libopus reads frame_size as HOW MUCH to invent -
      // so it must be the frame, not the 120 ms buffer capacity.
      expect(conceal.maxSamples, 320);
    });

    test('each lost packet is one concealed frame', () {
      final pcm = decoder.decode(frame([7], droppedBefore: 3));
      expect(pcm, hasLength(4 * 640));
      expect(native().calls.where((c) => c.packet == null), hasLength(3));
    });

    test('a long outage is left as a gap after five invented frames', () {
      final pcm = decoder.decode(frame([7], droppedBefore: 400));
      expect(
        pcm,
        hasLength((OpusStreamDecoder.defaultMaxConcealedFrames + 1) * 640),
      );
    });

    test('the concealment cap is configurable, including off', () {
      decoder.dispose();
      decoder = OpusStreamDecoder(library: library, maxConcealedFrames: 0);
      final pcm = decoder.decode(frame([7], droppedBefore: 2));
      expect(pcm, hasLength(640));
    });

    test('a contiguous stream never conceals', () {
      for (var i = 0; i < 10; i++) {
        decoder.decode(frame([7], seq: i));
      }
      expect(native().calls.where((c) => c.packet == null), isEmpty);
    });
  });

  group('a packet that arrived broken', () {
    test('a corrupt packet costs one concealed frame, not an exception', () {
      final pcm = decoder.decode(frame([FakeOpusDecoder.corruptMarker, 1]));
      expect(pcm, hasLength(640));
      expect(samples(pcm), everyElement(FakeOpusDecoder.concealedSample));
    });

    test('an empty payload is treated as loss, not handed to libopus', () {
      final pcm = decoder.decode(frame([]));
      expect(pcm, hasLength(640));
      expect(native().calls.single.packet, isNull);
    });

    test('the stream carries on normally after a corrupt packet', () {
      decoder.decode(frame([FakeOpusDecoder.corruptMarker]));
      expect(samples(decoder.decode(frame([5]))), everyElement(5));
    });

    test(
      'when concealment fails too, the frame is empty rather than thrown',
      () {
        native().refuseConcealment = true;
        expect(decoder.decode(frame([FakeOpusDecoder.corruptMarker])), isEmpty);
        expect(decoder.decode(frame([5], droppedBefore: 2)), hasLength(640));
      },
    );
  });

  group('lifecycle', () {
    test('dispose closes the native decoder', () {
      decoder.dispose();
      expect(native().closed, isTrue);
      expect(library.leaked, isEmpty);
    });

    test('dispose twice closes once', () {
      decoder.dispose();
      decoder.dispose();
      expect(native().closeCount, 1);
    });

    test(
      'a disposed decoder returns nothing and never touches freed state',
      () {
        decoder.dispose();
        // The fake throws on decode-after-close, as freed native memory would
        // do something far worse.
        expect(decoder.decode(frame([7], droppedBefore: 2)), isEmpty);
        expect(native().calls, isEmpty);
      },
    );

    test('two streams get two independent native decoders', () {
      final other = OpusStreamDecoder(library: library);
      addTearDown(other.dispose);
      expect(library.opened, hasLength(2));
      decoder.decode(frame([1]));
      other.decode(frame([2]));
      expect(library.opened[0].calls.single.packet, [1]);
      expect(library.opened[1].calls.single.packet, [2]);
    });
  });
}
