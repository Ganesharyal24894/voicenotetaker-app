import 'dart:typed_data';

/// Access to libopus, which is native code, so it lives in `drivers/` with
/// every other piece of the outside world.
///
/// `services/codec/opus_stream_decoder.dart` is written entirely against these
/// two interfaces and `dart:typed_data`, which is what lets the Opus decoding
/// rules - one packet per frame, a concealed frame for a dropped packet, a
/// corrupt packet costing exactly that packet - be tested with no native code
/// at all, and lets the native binding be swapped without touching them.
abstract interface class OpusLibrary {
  /// Opens a decoder. The caller owns it and must [OpusNativeDecoder.close] it.
  ///
  /// Throws [OpusException] when the library is missing or refuses the format.
  OpusNativeDecoder openDecoder({
    required int sampleRateHz,
    required int channels,
  });
}

/// One libopus decoder state.
///
/// NOT thread safe and NOT shareable: libopus keeps the previous frame's state
/// inside it, so one of these belongs to exactly one stream.
abstract interface class OpusNativeDecoder {
  /// Decodes one packet, or conceals a lost one when [packet] is null.
  ///
  /// Passing null is libopus's packet loss concealment: it invents a frame
  /// from the decoder's own state instead of leaving a hole. [maxSamples] is
  /// the per-channel capacity of the output, and must be at least as large as
  /// the frame the packet carries.
  ///
  /// Returns the samples decoded, interleaved, as many as libopus produced.
  /// Throws [OpusException] for a packet libopus rejects, and for an EMPTY
  /// packet, which libopus would silently treat as loss of [maxSamples].
  Int16List decode({Uint8List? packet, required int maxSamples});

  /// Frees the native state. Safe to call more than once.
  void close();
}

/// Anything libopus, or the loading of it, refused to do.
class OpusException implements Exception {
  const OpusException(this.message, [this.code]);

  final String message;

  /// libopus's own negative error code, when there was one.
  final int? code;

  @override
  String toString() =>
      'OpusException: $message${code == null ? '' : ' ($code)'}';
}
