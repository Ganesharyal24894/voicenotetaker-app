import 'dart:typed_data';

/// Pure-Dart IMA ADPCM decoder, ported one-for-one from the Python reference
/// at `host/adpcm.py` in the firmware repository.
///
/// The firmware emits ONE self-contained block per BLE notification: each block
/// carries its own predictor and step index in a 4-byte header, so a dropped
/// packet costs exactly one block instead of desynchronising the decoder for
/// the rest of the stream. Never carry state across [decodeBlock] calls.
///
/// Block layout:
///
/// ```text
/// offset size field
/// 0      2    int16 predictor (little-endian)
/// 2      1    uint8 step index
/// 3      1    uint8 reserved
/// 4      ..   4-bit codes, LOW NIBBLE FIRST
/// ```
///
/// A mismatch between this and the firmware's encoder degrades audio silently,
/// which is why `test/adpcm_decoder_test.dart` checks it against golden vectors
/// produced by the Python reference itself.
abstract final class AdpcmDecoder {
  /// IMA step size table, 89 entries (indices 0..88).
  static const List<int> stepTable = <int>[
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, //
    41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173,
    190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
    724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
    6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289,
    16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
  ];

  /// Step-index adjustment per 4-bit code.
  static const List<int> indexTable = <int>[
    -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8, //
  ];

  /// Bytes of block header preceding the nibble payload.
  static const int headerBytes = 4;

  /// Highest valid index into [stepTable].
  static const int maxStepIndex = 88;

  static const int _minSample = -32768;
  static const int _maxSample = 32767;

  /// Decodes one self-contained ADPCM block into signed 16-bit samples.
  ///
  /// Returns an empty list when [block] is too short to contain a header,
  /// matching the reference implementation. Each payload byte yields two
  /// samples: the low nibble first, then the high nibble - so the result
  /// always has an even length, and a block encoding an odd number of samples
  /// carries one padding sample the caller is expected to know about.
  static Int16List decodeBlock(Uint8List block) {
    if (block.length < headerBytes) return Int16List(0);

    final header = ByteData.sublistView(block, 0, headerBytes);
    var predictor = header.getInt16(0, Endian.little);
    var index = _clamp(header.getUint8(2), 0, maxStepIndex);

    final payloadLength = block.length - headerBytes;
    final out = Int16List(payloadLength * 2);

    var o = 0;
    for (var i = headerBytes; i < block.length; i++) {
      final byte = block[i];
      // LOW NIBBLE FIRST - reversing this produces audio that is recognisable
      // but badly distorted, which is exactly the kind of silent failure the
      // golden vectors exist to catch.
      for (var half = 0; half < 2; half++) {
        final code = half == 0 ? (byte & 0x0F) : (byte >> 4);
        final step = stepTable[index];

        var delta = step >> 3;
        if (code & 4 != 0) delta += step;
        if (code & 2 != 0) delta += step >> 1;
        if (code & 1 != 0) delta += step >> 2;

        predictor += (code & 8) != 0 ? -delta : delta;
        predictor = _clamp(predictor, _minSample, _maxSample);
        index = _clamp(index + indexTable[code], 0, maxStepIndex);

        out[o++] = predictor;
      }
    }
    return out;
  }

  /// Decodes a block straight into little-endian PCM bytes, ready to append to
  /// a WAV payload.
  static Uint8List decodeBlockToPcmBytes(Uint8List block) {
    final samples = decodeBlock(block);
    final bytes = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      view.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }

  static int _clamp(int value, int lo, int hi) =>
      value < lo ? lo : (value > hi ? hi : value);
}
