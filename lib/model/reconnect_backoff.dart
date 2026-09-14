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
  static Duration delayFor(int attempt) {
    if (attempt < 0) return schedule.first;
    if (attempt >= schedule.length) return schedule.last;
    return schedule[attempt];
  }
}
