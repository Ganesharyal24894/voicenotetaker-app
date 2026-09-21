/// Codec identifiers exactly as the firmware reports them on the `fe02`
/// stream-info characteristic and accepts them on the `fe03` control
/// characteristic.
///
/// The wire values are shared with the firmware and the host tooling, so they
/// are APPEND-ONLY. Renumbering one would make an old device and a new app
/// agree on a number and disagree on what it means, which does not fail - it
/// produces noise.
///
/// Pure data - see `lib/model/README` note in the project README: this layer
/// carries no logic and no I/O.
enum AudioCodec {
  /// Raw signed 16-bit little-endian PCM, split across notifications.
  pcmS16le(0),

  /// IMA ADPCM. One self-contained block per notification (device default).
  imaAdpcm(1),

  /// Opus in CELT-only mode: the firmware's standard `opus_encoder` API in
  /// `OPUS_APPLICATION_RESTRICTED_LOWDELAY`, 16 kHz mono, 20 ms frames,
  /// 24 kbps VBR. One self-contained packet per notification, like ADPCM.
  ///
  /// A FULLY STANDARD OPUS BITSTREAM - the firmware chose the standard API
  /// over `opus_custom` precisely so that any compliant decoder can read it.
  opusCelt(2);

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
