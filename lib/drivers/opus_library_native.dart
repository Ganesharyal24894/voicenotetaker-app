import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:opus_native/opus_native.dart' as opus;

import 'opus_library.dart';

/// [OpusLibrary] over the libopus 1.5.2 decoder that `packages/opus_native`
/// compiles from source for every platform, `flutter test` included.
///
/// The only file in the app that names `package:opus_native` or touches
/// native memory for audio. Everything it hands back is a Dart copy, so no
/// caller can hold a pointer into a buffer that is about to be freed.
class NativeOpusLibrary implements OpusLibrary {
  const NativeOpusLibrary();

  /// libopus's own version string - `libopus 1.5.2` for the vendored build.
  /// Named so a test can prove it is not some other libopus on the machine.
  String get version => opus.opusGetVersionString().cast<Utf8>().toDartString();

  @override
  OpusNativeDecoder openDecoder({
    required int sampleRateHz,
    required int channels,
  }) {
    final error = calloc<Int>();
    try {
      final state = opus.opusDecoderCreate(sampleRateHz, channels, error);
      if (error.value != opus.opusOk || state == nullptr) {
        throw OpusException(
          'opus_decoder_create($sampleRateHz Hz, $channels ch): '
          '${_describe(error.value)}',
          error.value,
        );
      }
      return _NativeDecoder(state, channels);
    } finally {
      calloc.free(error);
    }
  }
}

String _describe(int code) =>
    opus.opusStrerror(code).cast<Utf8>().toDartString();

class _NativeDecoder implements OpusNativeDecoder {
  _NativeDecoder(this._state, this._channels);

  Pointer<opus.OpusDecoderState> _state;
  final int _channels;

  /// Reused across frames: one 20 ms packet is ~50 bytes, so growing this is
  /// rare, and allocating per notification would be 50 mallocs a second.
  Pointer<UnsignedChar> _packet = nullptr;
  int _packetCapacity = 0;
  Pointer<Int16> _pcm = nullptr;
  int _pcmCapacity = 0;

  @override
  Int16List decode({Uint8List? packet, required int maxSamples}) {
    if (_state == nullptr) {
      throw const OpusException('decode after close');
    }
    _ensurePcm(maxSamples * _channels);
    final int got;
    if (packet == null) {
      got = opus.opusDecode(_state, nullptr, 0, _pcm, maxSamples, 0);
    } else {
      if (packet.isEmpty) {
        // libopus reads a zero-length packet as LOSS and would conceal all of
        // [maxSamples] - 120 ms when that is the buffer's capacity. Loss is
        // asked for with null, deliberately and with a frame's worth.
        throw const OpusException('empty packet; pass null to conceal');
      }
      _ensurePacket(packet.length);
      _packet.cast<Uint8>().asTypedList(packet.length).setAll(0, packet);
      got = opus.opusDecode(
        _state,
        _packet,
        packet.length,
        _pcm,
        maxSamples,
        0,
      );
    }
    if (got < 0) {
      throw OpusException('opus_decode: ${_describe(got)}', got);
    }
    // A copy, not a view: the native buffer is overwritten by the next frame.
    return Int16List.fromList(_pcm.asTypedList(got * _channels));
  }

  void _ensurePacket(int bytes) {
    if (bytes <= _packetCapacity) return;
    if (_packet != nullptr) calloc.free(_packet);
    _packet = calloc<UnsignedChar>(bytes);
    _packetCapacity = bytes;
  }

  void _ensurePcm(int samples) {
    if (samples <= _pcmCapacity) return;
    if (_pcm != nullptr) calloc.free(_pcm);
    _pcm = calloc<Int16>(samples);
    _pcmCapacity = samples;
  }

  @override
  void close() {
    if (_state == nullptr) return;
    opus.opusDecoderDestroy(_state);
    _state = nullptr;
    if (_packet != nullptr) calloc.free(_packet);
    if (_pcm != nullptr) calloc.free(_pcm);
    _packet = nullptr;
    _pcm = nullptr;
    _packetCapacity = 0;
    _pcmCapacity = 0;
  }
}
