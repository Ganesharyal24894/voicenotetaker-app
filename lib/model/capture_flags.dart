import 'dart:typed_data';

/// Wire format of the `fe08` capture characteristic, as READ or NOTIFIED.
///
/// Exactly one byte:
///
///   * bit 0 - [privacyMode]: the wearer double-tapped the device to put it
///     in privacy mode. The device can BOOT in privacy mode (a persisted one,
///     or one it could not read), so the first read may already say so. The
///     firmware and this wire format still call this bit "muted"; the feature
///     is called privacy mode everywhere the wearer can see it.
///   * bit 1 - [speechOpen]: audio is flowing - `fe01` subscribed AND not in
///     privacy mode AND (gate disabled OR gate open). With the gate disabled
///     it is set whenever `fe01` is subscribed, so it means "speech heard"
///     ONLY together with [gateEnabled]; see [hearingSpeech].
///   * bit 2 - [gateEnabled]: the device is streaming speech only. It resets to
///     disabled on every connect and disconnect, so always-listening writes it
///     again after every reconnect.
///   * bit 3 - [micOff]: the microphone is stopped to save battery, because
///     nothing has received audio for 2 minutes (no `fe01` subscriber on a
///     recorder without storage). Clears as soon as `fe01` is subscribed.
///     This is POWER saving and nothing else: the device decided it, the
///     wearer did not, and it is a different thing from privacy mode.
///
/// Changes are sampled every 20 ms on the device (100 ms in privacy mode); two
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
    required this.privacyMode,
    required this.speechOpen,
    required this.gateEnabled,
    this.micOff = false,
  });

  /// `fe08` bit 0. The wire name is "muted"; the feature the wearer sees
  /// is called privacy mode. The name and value here must match the
  /// firmware, so they are NOT renamed.
  static const int mutedBit = 0x01;
  static const int speechOpenBit = 0x02;
  static const int gateEnabledBit = 0x04;
  static const int micOffBit = 0x08;

  /// Every other bit.
  static const int reservedBits = 0xF0;

  /// The characteristic is exactly this long, in both directions.
  static const int valueBytes = 1;

  /// The wearer's deliberate choice: the microphone is off because they
  /// asked for it (a double tap, or a command from the app). Not to be
  /// confused with [micOff], which is the device saving power.
  final bool privacyMode;

  /// Audio is flowing on `fe01` - see the class comment for exactly when.
  final bool speechOpen;

  final bool gateEnabled;

  /// The microphone is off to save battery - see the class comment.
  final bool micOff;

  /// The speech gate is enabled and open: the device is hearing speech now.
  bool get hearingSpeech => gateEnabled && speechOpen && !privacyMode;

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
      privacyMode: value & mutedBit != 0,
      speechOpen: value & speechOpenBit != 0,
      gateEnabled: value & gateEnabledBit != 0,
      micOff: value & micOffBit != 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureFlags &&
      other.privacyMode == privacyMode &&
      other.speechOpen == speechOpen &&
      other.gateEnabled == gateEnabled &&
      other.micOff == micOff;

  @override
  int get hashCode => Object.hash(privacyMode, speechOpen, gateEnabled, micOff);

  @override
  String toString() => 'CaptureFlags(privacyMode: $privacyMode, '
      'speechOpen: $speechOpen, '
      'gateEnabled: $gateEnabled, micOff: $micOff)';
}

/// What the app may WRITE to `fe08`: one byte, one of four commands.
///
/// Writing is not the mirror image of reading on purpose - the device owns
/// the gate's state and privacy mode, the app only asks.
///
/// [mute] and [unmute] keep their firmware names ([CaptureCommand.mute] is
/// `CAPTURE_CMD_MUTE`): they are on the wire and must match. The feature is
/// called privacy mode in everything the wearer reads.
enum CaptureCommand {
  /// Stream everything while `fe01` is subscribed. The device's default after
  /// a connect, and what a manual recording needs.
  gateDisabled(0),

  /// Stream speech only. Always listening.
  gateEnabled(1),

  /// Turn privacy mode on (firmware `CAPTURE_CMD_MUTE`). The wearer normally
  /// does this with a double tap; the app has no control for it yet.
  mute(2),

  /// Turn privacy mode off (firmware `CAPTURE_CMD_UNMUTE`).
  unmute(3);

  const CaptureCommand(this.wireValue);

  final int wireValue;

  /// The single byte to write.
  Uint8List toBytes() => Uint8List.fromList(<int>[wireValue]);
}
