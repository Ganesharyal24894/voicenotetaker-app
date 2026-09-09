import 'dart:typed_data';

/// The fields of a RIFF/WAVE header, as read back off disk.
///
/// The mirror image of `WavWriter`: what that class writes, this class reads.
/// `test/wav_reader_test.dart` asserts the pair against each other so the two
/// can never drift apart.
class WavHeader {
  const WavHeader({
    required this.audioFormat,
    required this.channels,
    required this.sampleRateHz,
    required this.byteRate,
    required this.blockAlign,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });

  /// 1 for uncompressed PCM, which is all the recorder ever writes.
  final int audioFormat;
  final int channels;
  final int sampleRateHz;

  /// Bytes per second of audio, straight from the header.
  final int byteRate;
  final int blockAlign;
  final int bitsPerSample;

  /// Absolute offset of the first payload byte.
  final int dataOffset;

  /// Payload length the header claims.
  final int dataLength;

  /// Length of [dataLength] bytes of audio at this header's byte rate.
  ///
  /// `null` when the header cannot describe a length - a zero byte rate - so a
  /// caller never has to guess one from the file size.
  Duration? get duration {
    if (byteRate <= 0) return null;
    return Duration(microseconds: (dataLength * 1000000 / byteRate).round());
  }

  /// Length of [payloadBytes] of audio at this header's byte rate.
  ///
  /// Used when the file on disk is shorter than the header claims, which is
  /// what a recording interrupted by a crash looks like.
  Duration? durationOf(int payloadBytes) {
    if (byteRate <= 0 || payloadBytes < 0) return null;
    return Duration(microseconds: (payloadBytes * 1000000 / byteRate).round());
  }

  @override
  String toString() => 'WavHeader($sampleRateHz Hz, $bitsPerSample-bit, '
      '$channels ch, $dataLength B at +$dataOffset)';
}

/// Reads RIFF/WAVE headers.
///
/// Deliberately total: every malformed, truncated or foreign file returns
/// `null`. A recordings list must not blow up because one file on disk is a
/// half-written casualty of a crash.
abstract final class WavReader {
  /// `RIFF` + size + `WAVE`.
  static const int _riffHeaderLength = 12;

  /// Every chunk is a 4-byte id and a 4-byte size.
  static const int _chunkHeaderLength = 8;

  /// Smallest `fmt ` chunk that carries the fields this reader needs.
  static const int _minFmtLength = 16;

  /// Bytes worth reading off the front of a file to find the header.
  ///
  /// The app's own writer emits exactly 44, but files from elsewhere can carry
  /// `LIST`/`fact` chunks before `data`; 4 KiB covers those without reading a
  /// whole recording into memory.
  static const int probeLength = 4096;

  /// Parses the header at the start of [bytes], or returns `null`.
  ///
  /// [bytes] may be a prefix of the file: only the header is examined, and the
  /// payload is not required to be present.
  static WavHeader? parse(Uint8List bytes) {
    if (bytes.length < _riffHeaderLength) return null;
    if (!_matches(bytes, 0, 'RIFF') || !_matches(bytes, 8, 'WAVE')) return null;

    final view = ByteData.sublistView(bytes);

    int? audioFormat;
    int? channels;
    int? sampleRateHz;
    int? byteRate;
    int? blockAlign;
    int? bitsPerSample;

    var offset = _riffHeaderLength;
    while (offset + _chunkHeaderLength <= bytes.length) {
      final id = _ascii(bytes, offset);
      final size = view.getUint32(offset + 4, Endian.little);
      final body = offset + _chunkHeaderLength;

      if (id == 'fmt ') {
        if (size < _minFmtLength || body + _minFmtLength > bytes.length) {
          return null;
        }
        audioFormat = view.getUint16(body, Endian.little);
        channels = view.getUint16(body + 2, Endian.little);
        sampleRateHz = view.getUint32(body + 4, Endian.little);
        byteRate = view.getUint32(body + 8, Endian.little);
        blockAlign = view.getUint16(body + 12, Endian.little);
        bitsPerSample = view.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        // The payload itself need not be present in [bytes]; its declared
        // length is all this reader wants.
        if (audioFormat == null) return null;
        return WavHeader(
          audioFormat: audioFormat,
          channels: channels!,
          sampleRateHz: sampleRateHz!,
          byteRate: byteRate!,
          blockAlign: blockAlign!,
          bitsPerSample: bitsPerSample!,
          dataOffset: body,
          dataLength: size,
        );
      }

      // Chunks are word-aligned: an odd size is followed by a pad byte.
      final advance = _chunkHeaderLength + size + (size.isOdd ? 1 : 0);
      // A zero-length or absurd chunk size would loop or overflow; give up.
      if (advance <= 0 || offset + advance <= offset) return null;
      offset += advance;
    }

    // Ran out of bytes before a `data` chunk: truncated, or not a WAVE file.
    return null;
  }

  static bool _matches(Uint8List bytes, int offset, String ascii) {
    if (offset + ascii.length > bytes.length) return false;
    for (var i = 0; i < ascii.length; i++) {
      if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }

  static String _ascii(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes, offset, offset + 4);
}
