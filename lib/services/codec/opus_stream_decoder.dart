import 'dart:typed_data';

import '../../drivers/opus_library.dart';
import '../../model/audio_codec.dart';
import '../../model/audio_frame.dart';
import 'stream_decoder.dart';

/// Codec 2: one self-contained Opus packet per BLE notification.
///
/// The firmware encodes with the STANDARD `opus_encoder` API in
/// `OPUS_APPLICATION_RESTRICTED_LOWDELAY` - CELT only - at 16 kHz mono, 20 ms
/// frames, 24 kbps unconstrained VBR. That is an ordinary Opus bitstream; no
/// private decoder is involved, which was the whole reason the firmware chose
/// that API over `opus_custom`.
///
/// WHAT THIS ADDS OVER A RAW `opus_decode` CALL:
///
///  - **Concealment.** `AudioFrame.droppedBefore` counts the notifications the
///    link lost. ADPCM can do nothing with that number and the note simply
///    comes out short; Opus can decode a null packet and invent a frame from
///    the decoder's own state, which is the measured reason Opus at 3 % loss
///    still transcribes better than ADPCM at 0 %.
///  - **A bad packet costs one packet.** A truncated or corrupt payload is
///    concealed like a lost one rather than thrown at a BLE stream listener
///    that has nowhere to put an error.
///  - **A lifecycle.** The decoder state is per stream; [dispose] frees it.
class OpusStreamDecoder implements StreamDecoder {
  OpusStreamDecoder({
    required OpusLibrary library,
    this.sampleRateHz = 16000,
    this.channels = 1,
    this.frameMs = 20,
    this.maxConcealedFrames = defaultMaxConcealedFrames,
  }) : _decoder = library.openDecoder(
         sampleRateHz: sampleRateHz,
         channels: channels,
       );

  /// How many frames in a row will be invented before a gap is left as a gap.
  ///
  /// libopus's concealment is built to bridge the odd lost packet; run long
  /// enough it fades to near-silence anyway, and a link that is down for a
  /// second should produce a shorter note rather than a second of plausible
  /// noise that was never said. Five frames is 100 ms.
  static const int defaultMaxConcealedFrames = 5;

  /// The longest frame Opus can carry, so the output buffer is never the
  /// reason a packet fails to decode: 120 ms at the stream's sample rate.
  static const int _maxFrameMs = 120;

  final int sampleRateHz;
  final int channels;

  /// The frame the firmware sends, and therefore the length of a concealed
  /// frame. libopus needs to be told how much to invent; it cannot know.
  final int frameMs;

  final int maxConcealedFrames;

  final OpusNativeDecoder _decoder;
  bool _disposed = false;

  @override
  AudioCodec get codec => AudioCodec.opusCelt;

  /// Samples per channel in one 20 ms frame: 320 at 16 kHz.
  int get frameSamples => sampleRateHz * frameMs ~/ 1000;

  int get _capacitySamples => sampleRateHz * _maxFrameMs ~/ 1000;

  @override
  Uint8List decode(AudioFrame frame) {
    if (_disposed) return Uint8List(0);

    final out = BytesBuilder(copy: false);

    // The packets the link lost, before the one that did arrive. Concealed
    // first so the invented audio lands where the missing audio was.
    final missing = frame.droppedBefore.clamp(0, maxConcealedFrames);
    for (var i = 0; i < missing; i++) {
      out.add(_conceal());
    }

    out.add(_decodePacket(frame.payload));
    return out.toBytes();
  }

  /// One packet, or a concealed frame if libopus will not have it.
  ///
  /// An empty payload is loss as far as libopus is concerned, so it takes the
  /// same path as a rejected one.
  Uint8List _decodePacket(Uint8List packet) {
    if (packet.isEmpty) return _conceal();
    try {
      return _pcmBytes(
        _decoder.decode(packet: packet, maxSamples: _capacitySamples),
      );
    } on OpusException {
      return _conceal();
    }
  }

  /// One frame invented from the decoder's own state.
  ///
  /// [maxSamples] is not a capacity here: for a null packet libopus reads it
  /// as how much to conceal, so it is exactly one frame and not the buffer.
  Uint8List _conceal() {
    try {
      return _pcmBytes(_decoder.decode(maxSamples: frameSamples));
    } on OpusException {
      return Uint8List(0);
    }
  }

  /// Written out explicitly rather than by viewing the Int16List's buffer:
  /// that view is host-endian, and this stream is little-endian by contract.
  Uint8List _pcmBytes(Int16List samples) {
    final bytes = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      view.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _decoder.close();
  }
}
