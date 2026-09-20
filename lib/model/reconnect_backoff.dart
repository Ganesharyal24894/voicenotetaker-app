/// How long always-listening waits before each attempt to reach the device
/// again.
///
/// THE FIRST ATTEMPT IS IMMEDIATE. A link usually drops because the wearer
/// walked out of range for a moment, and on a phone in Doze the disconnect
/// callback is one of the few moments the CPU is certainly awake - an attempt
/// started inside it does not depend on a timer firing later.
///
/// THEN IT BACKS OFF TO ONCE A MINUTE AND STAYS THERE. Each attempt is a
/// direct connect with a bounded timeout, which runs the radio for that long,
/// so a device left on the desk overnight must not be hunted for continuously.
/// A minute is also the most speech a wearer walking back into range can lose
/// to the wait, which is the other side of the trade.
abstract final class ReconnectBackoff {
  static const List<Duration> schedule = <Duration>[
    Duration.zero,
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// How long each automatic connect attempt may take before it is abandoned.
  /// Shorter than the 30 s a tapped connect gets: nobody is waiting on this
  /// one, and the next attempt is coming anyway.
  static const Duration attemptTimeout = Duration(seconds: 20);

  /// The wait before attempt number [attempt], counting from zero.
  ///
  /// [asleep] is the recorder believed to be in System OFF: there is nothing
  /// to hunt for, so the ladder is abandoned for one standing, mostly passive
  /// wait - see [asleepDelay] and [asleepAttemptTimeout].
  ///
  /// [refusals] is how many attempts in a row ended in a PAIRING problem - the
  /// recorder paired to another phone, or a key it no longer has. Retrying
  /// those every minute cannot succeed until someone acts on the recorder or
  /// in the phone's settings, so from [refusalsBeforeLongWait] on the wait is
  /// [refusedDelay]. One refusal is not enough: a first "refused" can be a
  /// window closing or a bond settling.
  static Duration delayFor(
    int attempt, {
    int refusals = 0,
    bool asleep = false,
  }) {
    if (asleep) return asleepDelay;
    if (refusals >= refusalsBeforeLongWait) return refusedDelay;
    if (attempt < 0) return schedule.first;
    if (attempt >= schedule.length) return schedule.last;
    return schedule[attempt];
  }

  /// Refusals in a row before the long wait.
  static const int refusalsBeforeLongWait = 2;

  /// The wait once the recorder keeps refusing this phone.
  static const Duration refusedDelay = Duration(minutes: 10);

  /// WHILE THE RECORDER IS ASLEEP THE APP STOPS HUNTING AND STARTS WAITING.
  ///
  /// A sleeping recorder is in System OFF: it answers nothing, and only motion
  /// wakes it - after which it reboots and advertises again within
  /// milliseconds. So an attempt every minute can only fail, and a whole night
  /// of them is 480 attempts x 20 s of the phone's radio driven hard, for
  /// nothing. That is the phone's battery, and a user whose phone is flat by
  /// morning turns the feature off.
  ///
  /// INSTEAD: ONE STANDING ATTEMPT THAT WAITS FOR THE ADVERTISEMENT. Both
  /// platforms have a primitive for exactly this, and neither costs a duty
  /// cycle worth measuring - the controller, not the app, does the waiting:
  ///
  ///   * Android `autoConnect = true` hands the wait to the Bluetooth
  ///     controller's own filtered background scan, which is offloaded and
  ///     which the platform runs whether this app asks or not.
  ///   * iOS keeps a pending connection that survives the app being
  ///     suspended, and resolves the moment the peripheral advertises.
  ///
  /// The cost is then one connect call per [asleepAttemptTimeout] instead of
  /// hundreds of hard radio attempts, and the wearer picking the recorder up
  /// still gets a link in about a second, because the wait was already armed.
  static const Duration asleepDelay = Duration(seconds: 10);

  /// How long one standing "wait for it to advertise" attempt is left armed
  /// before it is cancelled and re-armed. Bounded rather than endless so a
  /// pending connect the platform quietly dropped cannot strand the app.
  static const Duration asleepAttemptTimeout = Duration(minutes: 2);
}
