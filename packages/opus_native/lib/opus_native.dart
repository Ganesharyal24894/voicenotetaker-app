/// The raw libopus decoder API, bound with `@Native` to the code asset that
/// `hook/build.dart` compiles from the vendored 1.5.2 sources.
///
/// Nothing here allocates, owns or frees anything: that is the app's driver,
/// `lib/drivers/opus_library_native.dart`. This file is the C signatures and
/// only the C signatures, so it can be checked against `include/opus.h` line
/// by line.
///
/// The asset id is this library's own URI, which is the default for `@Native`,
/// so no `assetId:` is spelled out.
library;

import 'dart:ffi';

/// `OpusDecoder`, opaque on both sides of the boundary.
final class OpusDecoderState extends Opaque {}

/// `OPUS_OK`.
const int opusOk = 0;

/// `const char *opus_get_version_string(void)`
@Native<Pointer<Char> Function()>(symbol: 'opus_get_version_string')
external Pointer<Char> opusGetVersionString();

/// `const char *opus_strerror(int error)`
@Native<Pointer<Char> Function(Int)>(symbol: 'opus_strerror')
external Pointer<Char> opusStrerror(int error);

/// `OpusDecoder *opus_decoder_create(opus_int32 Fs, int channels, int *error)`
@Native<Pointer<OpusDecoderState> Function(Int32, Int, Pointer<Int>)>(
  symbol: 'opus_decoder_create',
)
external Pointer<OpusDecoderState> opusDecoderCreate(
  int sampleRateHz,
  int channels,
  Pointer<Int> error,
);

/// `void opus_decoder_destroy(OpusDecoder *st)`
@Native<Void Function(Pointer<OpusDecoderState>)>(
  symbol: 'opus_decoder_destroy',
)
external void opusDecoderDestroy(Pointer<OpusDecoderState> decoder);

/// `int opus_decode(OpusDecoder *st, const unsigned char *data,
///                  opus_int32 len, opus_int16 *pcm, int frame_size,
///                  int decode_fec)`
///
/// A null [data] with [length] 0 is packet loss concealment: libopus invents
/// [frameSize] samples per channel from its own state. For a real packet,
/// [frameSize] is the capacity of [pcm] instead. Returns samples decoded per
/// channel, or a negative `OPUS_*` error.
@Native<
  Int Function(
    Pointer<OpusDecoderState>,
    Pointer<UnsignedChar>,
    Int32,
    Pointer<Int16>,
    Int,
    Int,
  )
>(symbol: 'opus_decode')
external int opusDecode(
  Pointer<OpusDecoderState> decoder,
  Pointer<UnsignedChar> data,
  int length,
  Pointer<Int16> pcm,
  int frameSize,
  int decodeFec,
);
