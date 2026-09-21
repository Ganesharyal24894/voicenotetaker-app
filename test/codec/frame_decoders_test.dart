import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/opus_library.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/audio_frame.dart';
import 'package:voicenotetaker_app/services/codec/adpcm_decoder.dart';
import 'package:voicenotetaker_app/services/codec/frame_decoder.dart';
import 'package:voicenotetaker_app/services/codec/opus_stream_decoder.dart';
import 'package:voicenotetaker_app/services/codec/stream_decoder.dart';

import 'fake_opus.dart';

/// The one door every stream's decoder comes through.
void main() {
  AudioFrame frame(List<int> payload, {int droppedBefore = 0}) => AudioFrame(
    sequence: 0,
    payload: Uint8List.fromList(payload),
    droppedBefore: droppedBefore,
  );

  test('every codec the app knows has a decoder', () {
    final decoders = FrameDecoders(opus: FakeOpusLibrary());
    for (final codec in AudioCodec.values) {
      final decoder = decoders.open(codec: codec);
      addTearDown(decoder.dispose);
      expect(decoder.codec, codec);
    }
  });

  test('PCM passes through byte for byte', () {
    final decoder = const FrameDecoders().open(codec: AudioCodec.pcmS16le);
    final payload = [1, 2, 3, 4];
    expect(decoder.decode(frame(payload)), payload);
    expect(decoder, isA<PcmPassthroughDecoder>());
  });

  test('ADPCM is exactly the block decoder, with no state of its own', () {
    final decoder = const FrameDecoders().open(codec: AudioCodec.imaAdpcm);
    final block = Uint8List.fromList([0x10, 0x00, 5, 0, 0x12, 0x34, 0x9A]);
    expect(
      decoder.decode(frame(block)),
      AdpcmDecoder.decodeBlockToPcmBytes(block),
    );
  });

  test('ADPCM does nothing with a gap - it has nothing to conceal with', () {
    // The contrast with Opus is the point: a lost ADPCM block is simply
    // missing audio, and the note comes out that much shorter.
    final decoder = const FrameDecoders().open(codec: AudioCodec.imaAdpcm);
    final block = Uint8List.fromList([0, 0, 0, 0, 0x11]);
    expect(
      decoder.decode(frame(block, droppedBefore: 3)),
      AdpcmDecoder.decodeBlockToPcmBytes(block),
    );
  });

  test('Opus is opened at the stream format the device reported', () {
    final opus = FakeOpusLibrary();
    final decoder = FrameDecoders(opus: opus)
        .open(codec: AudioCodec.opusCelt, sampleRateHz: 16000, channels: 1);
    addTearDown(decoder.dispose);
    expect(decoder, isA<OpusStreamDecoder>());
    expect(opus.opened.single.sampleRateHz, 16000);
    expect(opus.opened.single.channels, 1);
  });

  test('each open is a new decoder - streams never share Opus state', () {
    final opus = FakeOpusLibrary();
    final decoders = FrameDecoders(opus: opus);
    final a = decoders.open(codec: AudioCodec.opusCelt);
    final b = decoders.open(codec: AudioCodec.opusCelt);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    expect(identical(a, b), isFalse);
    expect(opus.opened, hasLength(2));
  });

  group('without libopus wired in', () {
    const bare = FrameDecoders();

    test('says it cannot decode Opus, and can decode everything else', () {
      expect(bare.supports(AudioCodec.opusCelt), isFalse);
      expect(bare.supports(AudioCodec.imaAdpcm), isTrue);
      expect(bare.supports(AudioCodec.pcmS16le), isTrue);
    });

    test('refuses to open Opus, naming the wiring rather than the device', () {
      expect(
        () => bare.open(codec: AudioCodec.opusCelt),
        throwsA(
          isA<OpusException>().having(
            (e) => e.message,
            'message',
            contains('no libopus'),
          ),
        ),
      );
    });
  });

  test('with libopus wired in, every codec is supported', () {
    final decoders = FrameDecoders(opus: FakeOpusLibrary());
    for (final codec in AudioCodec.values) {
      expect(decoders.supports(codec), isTrue, reason: codec.name);
    }
  });

  test('PCM and ADPCM decoders survive dispose, having nothing to free', () {
    for (final codec in [AudioCodec.pcmS16le, AudioCodec.imaAdpcm]) {
      final StreamDecoder decoder = const FrameDecoders().open(codec: codec);
      decoder.dispose();
      decoder.dispose();
    }
  });
}
