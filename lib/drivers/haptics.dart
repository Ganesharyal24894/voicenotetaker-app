/// A short vibration the phone makes by itself - for the not-saving alert.
///
/// A driver: a platform capability with no domain logic. WHEN to buzz is
/// `NotSavingAlertPolicy`'s decision; this only makes it so.
///
/// WHAT EACH PLATFORM DOES:
///
///   * Android: the system vibrator, as a NOTIFICATION vibration. It follows
///     the phone's own rules: nothing in silent mode or Do Not Disturb, and
///     nothing when the user turned notification vibration off.
///   * iOS: nothing yet. An app in the background cannot vibrate on its own;
///     the only way is a local notification with sound, which needs a
///     notification permission and plugin this app does not have. The header
///     line still says "Not saving" when the app is opened.
abstract class Haptics {
  Future<void> buzz(BuzzPattern pattern);
}

enum BuzzPattern {
  /// Notes stopped saving: one firm buzz.
  notSaving,

  /// Saving again: one short tick.
  resumed,
}
