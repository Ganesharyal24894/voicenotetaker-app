import '../../drivers/opus_library.dart';
import '../../model/audio_codec.dart';
import 'opus_stream_decoder.dart';
import 'stream_decoder.dart';

/// Opens the one decoder a stream will use, for whichever codec the device
/// reported.
///
/// Shared by the manual recorder, always-listening and the device tests, so
/// none of them can decode the same stream differently from the others.
///
/// WHY THIS IS NO LONGER A STATIC `decode()`. Opus carries state from one
/// frame to the next, so it needs a decoder that is created with the stream
/// and released with it. PCM and ADPCM do not, but they go through the same
/// door anyway: one place that knows how a codec is decoded is the whole
/// point of this file.
class FrameDecoders {
  /// [opus] is the native libopus binding. It is null in the layers that
  /// never see codec 2 - and in every test that does not ask for it - so
  /// nothing pays for loading a native library it will not use.
  const FrameDecoders({this._opus});

  final OpusLibrary? _opus;

  /// Whether this build can decode [codec] at all.
  bool supports(AudioCodec codec) =>
      codec != AudioCodec.opusCelt || _opus != null;

  /// Opens a decoder for one stream. The caller owns it and must
  /// [StreamDecoder.dispose] it when the stream ends.
  ///
  /// Throws [OpusException] when the device asked for Opus and this build has
  /// no libopus wired in. That is a wiring mistake, not a device fault, and it
  /// should say so rather than produce silence.
  StreamDecoder open({
    required AudioCodec codec,
    int sampleRateHz = 16000,
    int channels = 1,
  }) {
    switch (codec) {
      case AudioCodec.pcmS16le:
        return PcmPassthroughDecoder();
      case AudioCodec.imaAdpcm:
        return AdpcmStreamDecoder();
      case AudioCodec.opusCelt:
        final opus = _opus;
        if (opus == null) {
          throw const OpusException(
            'the device chose Opus but no libopus was wired into this build',
          );
        }
        return OpusStreamDecoder(
          library: opus,
          sampleRateHz: sampleRateHz,
          channels: channels,
        );
    }
  }
}
