import 'dart:typed_data';

/// Builds the canonical 44-byte RIFF/WAVE header for uncompressed PCM.
///
/// ```text
/// offset size field                value
/// 0      4    ChunkID              'RIFF'
/// 4      4    ChunkSize            36 + dataLength
/// 8      4    Format               'WAVE'
/// 12     4    Subchunk1ID          'fmt '
/// 16     4    Subchunk1Size        16
/// 20     2    AudioFormat          1 (PCM)
/// 22     2    NumChannels
/// 24     4    SampleRate
/// 28     4    ByteRate             rate * channels * bits/8
/// 32     2    BlockAlign           channels * bits/8
/// 34     2    BitsPerSample
/// 36     4    Subchunk2ID          'data'
/// 40     4    Subchunk2Size        dataLength
/// ```
///
/// Nothing here touches the filesystem: the recording service streams the
/// header through a [FileSink], then patches the two length fields once the
/// payload size is known.
abstract final class WavWriter {
  /// Size of the header this class produces.
  static const int headerLength = 44;

  /// Offset of the `ChunkSize` field (`36 + dataLength`).
  static const int chunkSizeOffset = 4;

  /// Offset of the `Subchunk2Size` field (`dataLength`).
  static const int dataSizeOffset = 40;

  /// `ChunkSize` is everything after the first 8 bytes.
  static const int _chunkSizeOverhead = headerLength - 8;

  static const int _pcmFormatTag = 1;

  /// Builds a header describing [dataLength] bytes of PCM payload.
  ///
  /// Pass `dataLength: 0` for a provisional header, then call [patchLengths]
  /// once the real payload size is known.
  static Uint8List buildHeader({
    required int sampleRateHz,
    required int channels,
    required int bitsPerSample,
    int dataLength = 0,
  }) {
    if (sampleRateHz <= 0) {
      throw ArgumentError.value(sampleRateHz, 'sampleRateHz', 'must be > 0');
    }
    if (channels <= 0) {
      throw ArgumentError.value(channels, 'channels', 'must be > 0');
    }
    if (bitsPerSample <= 0 || bitsPerSample % 8 != 0) {
      throw ArgumentError.value(
        bitsPerSample,
        'bitsPerSample',
        'must be a positive multiple of 8',
      );
    }
    if (dataLength < 0) {
      throw ArgumentError.value(dataLength, 'dataLength', 'must be >= 0');
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final blockAlign = channels * bytesPerSample;
    final byteRate = sampleRateHz * blockAlign;

    final header = Uint8List(headerLength);
    final view = ByteData.sublistView(header);

    _writeAscii(header, 0, 'RIFF');
    view.setUint32(chunkSizeOffset, _chunkSizeOverhead + dataLength,
        Endian.little);
    _writeAscii(header, 8, 'WAVE');
    _writeAscii(header, 12, 'fmt ');
    view.setUint32(16, 16, Endian.little);
    view.setUint16(20, _pcmFormatTag, Endian.little);
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, sampleRateHz, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, bitsPerSample, Endian.little);
    _writeAscii(header, 36, 'data');
    view.setUint32(dataSizeOffset, dataLength, Endian.little);

    return header;
  }

  /// The 4 bytes to write at [chunkSizeOffset] for a payload of [dataLength].
  static Uint8List chunkSizeBytes(int dataLength) =>
      _uint32le(_chunkSizeOverhead + dataLength);

  /// The 4 bytes to write at [dataSizeOffset] for a payload of [dataLength].
  static Uint8List dataSizeBytes(int dataLength) => _uint32le(dataLength);

  /// Rewrites both length fields of an in-memory header.
  static void patchLengths(Uint8List header, int dataLength) {
    if (header.length < headerLength) {
      throw ArgumentError.value(
        header.length,
        'header.length',
        'must be at least $headerLength',
      );
    }
    final view = ByteData.sublistView(header);
    view.setUint32(chunkSizeOffset, _chunkSizeOverhead + dataLength,
        Endian.little);
    view.setUint32(dataSizeOffset, dataLength, Endian.little);
  }

  /// Convenience for tests and one-shot writes: header + payload in one buffer.
  static Uint8List wrapPcm(
    Uint8List pcm, {
    required int sampleRateHz,
    required int channels,
    required int bitsPerSample,
  }) {
    final header = buildHeader(
      sampleRateHz: sampleRateHz,
      channels: channels,
      bitsPerSample: bitsPerSample,
      dataLength: pcm.length,
    );
    final out = Uint8List(header.length + pcm.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + pcm.length, pcm);
    return out;
  }

  static Uint8List _uint32le(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
    return bytes;
  }

  static void _writeAscii(Uint8List target, int offset, String ascii) {
    for (var i = 0; i < ascii.length; i++) {
      target[offset + i] = ascii.codeUnitAt(i);
    }
  }
}
