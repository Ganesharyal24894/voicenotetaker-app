import 'capture_flags.dart';

/// What always-listening is doing, as ONE value the home screen and the
/// Android notification both render.
///
/// One resolver for both on purpose: a notification that said "Listening"
/// while the screen said "Device not connected" would be two answers to the
/// same question.
enum ContinuousStatus {
  /// The user has not turned always-listening on.
  off('Off'),

  /// On, and there is no link to the device right now. The app is trying.
  notConnected('Device not connected'),

  /// On, no link, and the recorder keeps refusing this phone: it was paired to
  /// another phone. Retries slow to one every 10 minutes.
  pairedToAnother('Paired to another phone'),

  /// On, no link, and this phone holds a key the recorder no longer has. Only
  /// forgetting the recorder in the phone's Bluetooth settings fixes it.
  oldPairing('Pairing needs a reset'),

  /// On and connected, but the firmware has no `fe08`. Manual recording still
  /// works; always-listening cannot.
  needsFirmwareUpdate('Needs firmware update'),

  /// On, connected, and the device is waiting for speech.
  listening('Always listening'),

  /// The speech gate is open: a note is being written now.
  hearingSpeech('Hearing speech'),

  /// The wearer muted the device with a double tap.
  muted('Muted on device'),

  /// Connected, but the recorder stopped its microphone to save battery
  /// (`fe08` bit 3): nothing has been receiving its audio for 2 minutes.
  micOff('Mic off to save battery');

  const ContinuousStatus(this.label);

  /// Short, plain copy. Shown on the home screen and in the notification.
  final String label;

  /// Resolves the status from the facts the controller holds.
  ///
  /// [refused] is [pairedToAnother] or [oldPairing] when the last automatic
  /// attempt ended in that pairing problem; it only shows while unconnected.
  ///
  /// [captureSupported] is null while it has not been checked yet - a link
  /// that is still coming up - which reads as "listening" rather than as a
  /// firmware problem nobody has found. [flags] is null until the device has
  /// answered once, which reads the same way for the same reason.
  static ContinuousStatus resolve({
    required bool enabled,
    required bool connected,
    required bool? captureSupported,
    required CaptureFlags? flags,
    ContinuousStatus? refused,
  }) {
    if (!enabled) return ContinuousStatus.off;
    if (!connected) return refused ?? ContinuousStatus.notConnected;
    if (captureSupported == false) return ContinuousStatus.needsFirmwareUpdate;
    // Muted outranks speech: a muted device cannot be hearing anything the
    // app will keep, whatever the gate bit says.
    if (flags != null && flags.muted) return ContinuousStatus.muted;
    // The recorder's own word that nothing is being captured, whatever the
    // phone believes it subscribed to.
    if (flags != null && flags.micOff) return ContinuousStatus.micOff;
    // `speechOpen` alone is "audio flowing", which is also true with the gate
    // disabled - the state the device is in for a moment after every connect,
    // before the app has written speech-only again.
    if (flags != null && flags.hearingSpeech) {
      return ContinuousStatus.hearingSpeech;
    }
    return ContinuousStatus.listening;
  }
}
