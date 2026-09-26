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

  /// Something the user just said or did was recognised: one short buzz, so
  /// they know without looking at the phone. Short on purpose - it confirms,
  /// it does not alert.
  ///
  /// NAMED FOR THE BUZZ, NOT FOR THE CALLER. A driver enum is shared, and a
  /// value called after one feature would have to be renamed the day that
  /// feature is deleted or a second caller wants the same 120 ms.
  ///
  /// iOS gets nothing, for the reason in the class comment above: an app in
  /// the background cannot vibrate on its own.
  confirm,
}
