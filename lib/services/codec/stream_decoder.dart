import 'dart:typed_data';

import '../../model/audio_codec.dart';
import '../../model/audio_frame.dart';
import 'adpcm_decoder.dart';

/// Decodes the frames of ONE stream into s16le PCM.
///
/// WHY THIS IS AN OBJECT AND NOT A STATIC FUNCTION. PCM and ADPCM are
/// stateless per notification, so for years `FrameDecoder.decode()` was a
/// static switch. Opus is not: its decoder carries the previous frame's
/// spectral and gain state, so two streams decoded through one decoder would
/// contaminate each other, and a decoder never released would leak native
/// memory. A decoder therefore belongs to a stream and has a lifecycle:
/// opened when the stream starts, [dispose]d when it ends.
///
/// One decoder per stream is also what keeps the manual recorder and
/// always-listening honest: both open theirs through [FrameDecoders], so the
/// two can never decode the same stream two different ways.
abstract interface class StreamDecoder {
  /// The codec this decoder was opened for.
  AudioCodec get codec;

  /// Decodes one frame into little-endian 16-bit PCM bytes.
  ///
  /// Returns an empty list for a frame that carries no audio. Implementations
  /// must not throw for a corrupt payload - a bad packet costs that packet.
  Uint8List decode(AudioFrame frame);

  /// Releases whatever the decoder holds. Safe to call more than once.
  ///
  /// After this, [decode] must never touch freed state; a decoder that holds
  /// any returns an empty list instead.
  void dispose();
}

/// Codec 0: already s16le on the wire, merely split across notifications.
class PcmPassthroughDecoder implements StreamDecoder {
  @override
  AudioCodec get codec => AudioCodec.pcmS16le;

  @override
  Uint8List decode(AudioFrame frame) => frame.payload;

  @override
  void dispose() {}
}

/// Codec 1: one self-contained IMA ADPCM block per notification.
///
/// Stateless by construction - each block carries its own predictor - so this
/// is a lifecycle wrapper around [AdpcmDecoder] and nothing more. A dropped
/// packet costs exactly one block and never desynchronises anything.
class AdpcmStreamDecoder implements StreamDecoder {
  @override
  AudioCodec get codec => AudioCodec.imaAdpcm;

  @override
  Uint8List decode(AudioFrame frame) =>
      AdpcmDecoder.decodeBlockToPcmBytes(frame.payload);

  @override
  void dispose() {}
}
