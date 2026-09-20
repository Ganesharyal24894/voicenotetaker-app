/// Is the recorder asleep, or is it gone?
///
/// The firmware powers itself off (System OFF) when it has been still and
/// either the wearer is in privacy mode or the link has been idle. It lets the
/// link go ON PURPOSE first - HCI `0x13` Remote User Terminated Connection -
/// and then stops advertising entirely. Only motion wakes it, after which it
/// reboots and advertises again within milliseconds.
///
/// That is a NORMAL state, not a fault: nothing is wrong, nothing is lost that
/// the wearer did not choose to lose, and nobody should be buzzed at 02:00
/// about it. A supervision timeout (`0x08`) is the opposite - the recorder is
/// out of range, flat or crashed - and stays worth telling the wearer about.
///
/// PURE. It is fed what the platform said and what the app has since seen, and
/// answers with one [RecorderPresence]. The controller owns the timers, the
/// radio and the copy.
///
/// WHAT EACH PLATFORM GIVES US (`universal_ble` 2.3.0, checked in its source):
///
///   * **Android** passes the HCI code through as its name, so a sleep arrives
///     as `"Remote User Terminated Connection"` and a supervision timeout as
///     `"Connection Timeout"`. A disconnect this phone asked for is
///     `GATT_SUCCESS`, which it reports as no reason at all.
///   * **iOS** passes `error?.localizedDescription` from
///     `didDisconnectPeripheral`, so a remote termination reads as "The
///     specified device has disconnected from us." and a supervision timeout
///     as "The connection has timed out unexpectedly." - and a clean end can
///     also arrive with NO error, which is what the firmware's own note
///     predicts.
///   * **Anything else** - a stack that says nothing, a platform this app has
///     not met - is [LinkDropReason.unknown], and the answer is then inferred
///     from behaviour rather than guessed.
library;

/// Why a link ended, in the only three flavours the app acts on.
enum LinkDropReason {
  /// HCI `0x13`: the recorder let go deliberately. Going to sleep looks like
  /// this - and so does the wearer's own "disconnect" on the device.
  remoteTerminated,

  /// HCI `0x08`: the link faded rather than ended. Out of range, a flat cell,
  /// a crash. A real drop.
  supervisionTimeout,

  /// The platform said nothing readable. iOS reports a clean disconnect this
  /// way, so this is NOT evidence of a fault - only the absence of evidence.
  unknown;

  /// Sorts the platform's own words. Null, empty or unrecognised text is
  /// [unknown]: inventing a reason is worse than admitting there is none.
  static LinkDropReason fromPlatform(String? reason) {
    final text = reason?.toLowerCase().trim();
    if (text == null || text.isEmpty) return LinkDropReason.unknown;
    bool has(String part) => text.contains(part);

    // Android 0x13/0x15, iOS CBErrorPeripheralDisconnected.
    if (has('remote user terminated') ||
        has('terminated connection due to power off') ||
        has('disconnected from us') ||
        has('peripheral disconnected')) {
      return LinkDropReason.remoteTerminated;
    }
    // Android 0x08 "Connection Timeout", iOS "The connection has timed out
    // unexpectedly.", and 0x3E for a link that never came up at all.
    if (has('connection timeout') ||
        has('timed out') ||
        has('timeout') ||
        has('connection failed to be established')) {
      return LinkDropReason.supervisionTimeout;
    }
    return LinkDropReason.unknown;
  }
}

/// Where the recorder is, as far as the app can honestly tell.
enum RecorderPresence {
  /// Connected right now.
  linked,

  /// The link ended cleanly and the app is deciding which of the two it was.
  /// Short-lived, and never long enough to matter to the wearer.
  settling,

  /// Believed to be in System OFF: it let go cleanly and has not been heard
  /// from since. Picking it up wakes it.
  asleep,

  /// The link is down and this is not a sleep - a timeout, or a recorder that
  /// is there and will not let us in. This is what the not-saving alert is
  /// for.
  lost;

  /// Whether notes stopping is the recorder's own doing rather than a fault.
  /// Nothing buzzes for these.
  bool get isRestful =>
      this == RecorderPresence.asleep || this == RecorderPresence.settling;
}

/// Follows one recorder across a drop and decides whether it went to sleep.
///
/// THE RULES
///
///   * A supervision timeout is never a sleep. Straight to [lost].
///   * A clean, explained drop (`0x13`) is a sleep unless the recorder turns
///     up again: [settling] for [cleanConfirm], and [asleep] after it, or as
///     soon as an attempt to reach it finds nothing.
///   * A clean drop with NO reason (iOS, and any stack that stays quiet) gets
///     the longer [unknownConfirm] before it counts as sleep, and a failed
///     connect alone does not shorten it: out of range looks exactly the same
///     from here, and only time separates them.
///   * Anything HEARD from the recorder - an advertisement, a refusal, a
///     connection - ends the sleep belief at once. A device that answers is
///     not in System OFF.
class RecorderSleepWatch {
  RecorderSleepWatch({
    this.cleanConfirm = defaultCleanConfirm,
    this.unknownConfirm = defaultUnknownConfirm,
  });

  /// How long a `0x13` drop waits before it counts as sleep. Long enough for a
  /// recorder that merely rebooted to advertise again (milliseconds), short
  /// enough to be over well inside the not-saving alert's 30 s grace.
  static const Duration defaultCleanConfirm = Duration(seconds: 10);

  /// The same for a drop the platform did not explain. Longer because the only
  /// thing separating "asleep" from "walked out of range on a stack that says
  /// nothing" is that a recorder in range and awake would have been reachable
  /// by now.
  static const Duration defaultUnknownConfirm = Duration(seconds: 90);

  final Duration cleanConfirm;
  final Duration unknownConfirm;

  RecorderPresence _presence = RecorderPresence.lost;
  DateTime? _settledBy;
  DateTime? _asleepSince;
  bool _explained = false;

  /// Where the recorder is. Ask [update] first if time may have passed.
  RecorderPresence get presence => _presence;

  /// Whether the recorder is believed to be in System OFF.
  bool get isAsleep => _presence == RecorderPresence.asleep;

  /// When the sleep began; null unless [isAsleep].
  DateTime? get asleepSince => _asleepSince;

  /// The link came up.
  void linked(DateTime now) {
    _presence = RecorderPresence.linked;
    _settledBy = null;
    _asleepSince = null;
    _explained = false;
  }

  /// The link ended by itself, for [reason].
  void dropped({required LinkDropReason reason, required DateTime now}) {
    _asleepSince = null;
    if (reason == LinkDropReason.supervisionTimeout) {
      _presence = RecorderPresence.lost;
      _settledBy = null;
      _explained = false;
      return;
    }
    _explained = reason == LinkDropReason.remoteTerminated;
    _presence = RecorderPresence.settling;
    _settledBy = now.add(_explained ? cleanConfirm : unknownConfirm);
  }

  /// The recorder was heard from: an advertisement, a refusal, a link. It is
  /// awake, whatever it did a moment ago.
  void heard(DateTime now) {
    if (_presence == RecorderPresence.linked) return;
    _presence = RecorderPresence.lost;
    _settledBy = null;
    _asleepSince = null;
    _explained = false;
  }

  /// An attempt to reach it found nothing - a connect that timed out, or a
  /// scan window that ended without it.
  ///
  /// This CONFIRMS an explained clean drop, because a recorder that merely
  /// rebooted would be advertising. It does not shorten an unexplained one:
  /// there, silence is also what out of range sounds like.
  void foundNothing(DateTime now) {
    if (_presence != RecorderPresence.settling) return;
    if (!_explained) {
      update(now);
      return;
    }
    _presence = RecorderPresence.asleep;
    _asleepSince = now;
    _settledBy = null;
  }

  /// Nothing is being watched any more: always-listening off, the user
  /// disconnecting, the radio going away.
  void reset() {
    _presence = RecorderPresence.lost;
    _settledBy = null;
    _asleepSince = null;
    _explained = false;
  }

  /// Lets time pass, and answers where the recorder is now.
  RecorderPresence update(DateTime now) {
    final by = _settledBy;
    if (by != null && !now.isBefore(by)) {
      _presence = RecorderPresence.asleep;
      _asleepSince = by;
      _settledBy = null;
    }
    return _presence;
  }

  /// When [update] would change the answer even though nothing else happens.
  /// Null when no decision is pending.
  DateTime? nextCheck() => _settledBy;
}
