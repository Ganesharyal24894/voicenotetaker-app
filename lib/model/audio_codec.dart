/// Codec identifiers exactly as the firmware reports them on the `fe02`
/// stream-info characteristic and accepts them on the `fe03` control
/// characteristic.
///
/// Pure data - see `lib/model/README` note in the project README: this layer
/// carries no logic and no I/O.
enum AudioCodec {
  /// Raw signed 16-bit little-endian PCM, split across notifications.
  pcmS16le(0),

  /// IMA ADPCM. One self-contained block per notification (device default).
  imaAdpcm(1);

  const AudioCodec(this.wireValue);

  /// The single byte used on the wire for this codec.
  final int wireValue;

  /// Returns the codec for [wireValue], or `null` if the device reported a
  /// codec this build does not know about.
  static AudioCodec? fromWire(int wireValue) {
    for (final codec in AudioCodec.values) {
      if (codec.wireValue == wireValue) return codec;
    }
    return null;
  }
}
