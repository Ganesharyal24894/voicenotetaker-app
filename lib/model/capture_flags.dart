import 'dart:typed_data';

/// Wire format of the `fe08` capture characteristic, as READ or NOTIFIED.
///
/// Exactly one byte:
///
///   * bit 0 - [muted]: the wearer double-tapped the device to mute it. The
///     device can BOOT muted (a persisted mute, or one it could not read), so
///     the first read may already say so.
///   * bit 1 - [speechOpen]: audio is flowing - `fe01` subscribed AND not
///     muted AND (gate disabled OR gate open). With the gate disabled it is set
///     whenever `fe01` is subscribed, so it means "speech heard" ONLY together
///     with [gateEnabled]; see [hearingSpeech].
///   * bit 2 - [gateEnabled]: the device is streaming speech only. It resets to
///     disabled on every connect and disconnect, so always-listening writes it
///     again after every reconnect.
///
/// Changes are sampled every 20 ms on the device (100 ms while muted); two
/// within one tick arrive as one notification carrying the final state.
///
/// Every other bit is reserved and must be zero. A value with one set is a
/// firmware newer than this build and is refused rather than half-read, the
/// same rule `AutoSleep` and `BatteryStatus` follow.
///
/// Pure data: this is the device protocol, not the BLE stack, so it lives in
/// `model/` and survives a package swap.
class CaptureFlags {
  const CaptureFlags({
    required this.muted,
    required this.speechOpen,
    required this.gateEnabled,
  });

  static const int mutedBit = 0x01;
  static const int speechOpenBit = 0x02;
  static const int gateEnabledBit = 0x04;

  /// Every other bit.
  static const int reservedBits = 0xF8;

  /// The characteristic is exactly this long, in both directions.
  static const int valueBytes = 1;

  final bool muted;

  /// Audio is flowing on `fe01` - see the class comment for exactly when.
  final bool speechOpen;

  final bool gateEnabled;

  /// The speech gate is enabled and open: the device is hearing speech now.
  bool get hearingSpeech => gateEnabled && speechOpen && !muted;

  /// Reads the one byte the characteristic carries.
  ///
  /// Throws [FormatException] on any length but one byte, or on reserved bits
  /// set.
  static CaptureFlags fromBytes(List<int> bytes) {
    if (bytes.length != valueBytes) {
      throw FormatException(
        'capture state is $valueBytes byte, got ${bytes.length}',
      );
    }
    final value = bytes.first;
    if (value & reservedBits != 0) {
      throw FormatException(
        'reserved capture bits set: '
        '0x${value.toRadixString(16).padLeft(2, '0')}',
      );
    }
    return CaptureFlags(
      muted: value & mutedBit != 0,
      speechOpen: value & speechOpenBit != 0,
      gateEnabled: value & gateEnabledBit != 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureFlags &&
      other.muted == muted &&
      other.speechOpen == speechOpen &&
      other.gateEnabled == gateEnabled;

  @override
  int get hashCode => Object.hash(muted, speechOpen, gateEnabled);

  @override
  String toString() => 'CaptureFlags(muted: $muted, speechOpen: $speechOpen, '
      'gateEnabled: $gateEnabled)';
}

/// What the app may WRITE to `fe08`: one byte, one of four commands.
///
/// Writing is not the mirror image of reading on purpose - the device owns
/// the gate's state and the mute, the app only asks.
enum CaptureCommand {
  /// Stream everything while `fe01` is subscribed. The device's default after
  /// a connect, and what a manual recording needs.
  gateDisabled(0),

  /// Stream speech only. Always listening.
  gateEnabled(1),

  /// Mute the microphone. The wearer normally does this with a double tap;
  /// the app has no control for it yet.
  mute(2),

  /// Unmute the microphone.
  unmute(3);

  const CaptureCommand(this.wireValue);

  final int wireValue;

  /// The single byte to write.
  Uint8List toBytes() => Uint8List.fromList(<int>[wireValue]);
}
