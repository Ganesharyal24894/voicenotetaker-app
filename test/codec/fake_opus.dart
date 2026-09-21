import 'dart:typed_data';

import 'package:voicenotetaker_app/drivers/opus_library.dart';

/// A libopus stand-in that records what it was asked, so the decoding RULES in
/// `OpusStreamDecoder` - when to conceal, how much, when to give up - are
/// tested without native code. `opus_golden_test.dart` covers the real library.
class FakeOpusLibrary implements OpusLibrary {
  final List<FakeOpusDecoder> opened = <FakeOpusDecoder>[];

  /// When set, [openDecoder] refuses, as libopus does for a bad format.
  OpusException? refuseWith;

  @override
  OpusNativeDecoder openDecoder({
    required int sampleRateHz,
    required int channels,
  }) {
    final refusal = refuseWith;
    if (refusal != null) throw refusal;
    final decoder = FakeOpusDecoder(sampleRateHz, channels);
    opened.add(decoder);
    return decoder;
  }

  /// Decoders opened and never closed.
  Iterable<FakeOpusDecoder> get leaked => opened.where((d) => !d.closed);
}

/// One call to [FakeOpusDecoder.decode]: the packet, or null for concealment.
typedef FakeCall = ({Uint8List? packet, int maxSamples});

class FakeOpusDecoder implements OpusNativeDecoder {
  FakeOpusDecoder(this.sampleRateHz, this.channels);

  final int sampleRateHz;
  final int channels;
  final List<FakeCall> calls = <FakeCall>[];
  int closeCount = 0;
  bool get closed => closeCount > 0;

  /// Packets whose first byte is this are rejected, like a corrupt TOC.
  static const int corruptMarker = 0xFF;

  /// When true, concealment is refused too.
  bool refuseConcealment = false;

  /// Samples a real packet decodes to; libopus reads this from the TOC byte.
  int packetSamples = 320;

  /// Every decoded sample carries this value, so a test can tell a real
  /// frame (the packet's first byte) from a concealed one (-1).
  static const int concealedSample = -1;

  @override
  Int16List decode({Uint8List? packet, required int maxSamples}) {
    if (closed) throw StateError('decode after close');
    calls.add((packet: packet, maxSamples: maxSamples));
    if (packet == null) {
      if (refuseConcealment) throw const OpusException('no state', -1);
      return Int16List(maxSamples)..fillRange(0, maxSamples, concealedSample);
    }
    if (packet.first == corruptMarker) {
      throw const OpusException('corrupted stream', -4);
    }
    if (packetSamples > maxSamples) {
      throw const OpusException('buffer too small', -2);
    }
    return Int16List(packetSamples)..fillRange(0, packetSamples, packet.first);
  }

  @override
  void close() => closeCount++;
}
