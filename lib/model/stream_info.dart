import 'dart:typed_data';

import 'audio_codec.dart';

/// Contents of the `fe02` stream-info characteristic.
///
/// Wire layout (packed, little-endian, 8 bytes):
///
/// ```text
/// offset size field
/// 0      4    uint32 sampleRateHz
/// 4      1    uint8  bitsPerSample
/// 5      1    uint8  channels
/// 6      1    uint8  codec
/// 7      1    uint8  reserved
/// ```
class StreamInfo {
  const StreamInfo({
    required this.sampleRateHz,
    required this.bitsPerSample,
    required this.channels,
    required this.codec,
    this.rawCodec,
  });

  /// The value assumed when the device cannot be queried.
  static const StreamInfo fallback = StreamInfo(
    sampleRateHz: 16000,
    bitsPerSample: 16,
    channels: 1,
    codec: AudioCodec.pcmS16le,
    rawCodec: 0,
  );

  /// Number of bytes the characteristic is expected to carry.
  static const int wireLength = 8;

  final int sampleRateHz;
  final int bitsPerSample;
  final int channels;

  /// Decoded codec, or `null` when the device reported an unknown value.
  final AudioCodec? codec;

  /// The codec byte exactly as read, kept so unknown values can be surfaced.
  final int? rawCodec;

  int get bytesPerSample => bitsPerSample ~/ 8;

  /// Byte rate of the *decoded* PCM stream.
  int get decodedByteRate => sampleRateHz * channels * bytesPerSample;

  /// Parses the packed little-endian representation.
  ///
  /// This lives with the data class rather than in `drivers/` on purpose: the
  /// byte layout is a property of the device protocol, not of whichever BLE
  /// package happens to deliver the bytes. Swapping the BLE package must not
  /// mean re-implementing this.
  ///
  /// Throws [FormatException] when [bytes] is shorter than [wireLength].
  factory StreamInfo.fromBytes(Uint8List bytes) {
    if (bytes.length < wireLength) {
      throw FormatException(
        'stream info must be at least $wireLength bytes, got ${bytes.length}',
      );
    }
    final data = ByteData.sublistView(bytes);
    final rawCodec = data.getUint8(6);
    return StreamInfo(
      sampleRateHz: data.getUint32(0, Endian.little),
      bitsPerSample: data.getUint8(4),
      channels: data.getUint8(5),
      codec: AudioCodec.fromWire(rawCodec),
      rawCodec: rawCodec,
    );
  }

  @override
  String toString() => 'StreamInfo($sampleRateHz Hz, $bitsPerSample-bit, '
      '$channels ch, codec ${codec?.name ?? rawCodec})';

  @override
  bool operator ==(Object other) =>
      other is StreamInfo &&
      other.sampleRateHz == sampleRateHz &&
      other.bitsPerSample == bitsPerSample &&
      other.channels == channels &&
      other.codec == codec &&
      other.rawCodec == rawCodec;

  @override
  int get hashCode =>
      Object.hash(sampleRateHz, bitsPerSample, channels, codec, rawCodec);
}
