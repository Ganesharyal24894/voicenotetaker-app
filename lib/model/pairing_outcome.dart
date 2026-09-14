/// What went wrong on the way to an encrypted link, in the app's own words.
///
/// PURE. The driver turns a platform error into a [BleFailureKind] with
/// [BleFailureKind.fromError]; [PairingOutcome.classify] turns that, the step
/// it happened at and what the scan response said into the one thing the user
/// is told. Both are unit-tested without a radio.
library;

import 'pairing_advert.dart';

/// A platform failure, sorted by what it says about pairing.
enum BleFailureKind {
  /// The link was dropped with HCI `0x05` Authentication Failure - what the
  /// recorder does to a phone that is not its owner, right after connecting.
  authenticationFailure,

  /// The phone's stored key did not work: HCI `0x06` PIN or Key Missing, iOS
  /// "Peer removed pairing information". The recorder forgot this phone.
  keyMissing,

  /// Encryption with a stored key failed (ATT Insufficient Encryption).
  insufficientEncryption,

  /// The recorder refused, or the user cancelled, pairing - Android
  /// `BOND_NONE`, iOS Insufficient Authentication after the alert.
  pairingRejected,

  /// The attempt ran out of time.
  timeout,

  /// The link went away with no reason worth reading.
  disconnected,

  /// Anything else.
  other;

  /// Sorts a failure by the platform's error code name (`universal_ble`'s
  /// `UniversalBleErrorCode.name`), its message, its details and the reason
  /// the last disconnect gave. Every argument may be null.
  ///
  /// MESSAGES ARE MATCHED AS TEXT because that is all some paths carry: a
  /// disconnect on Android arrives as "Authentication Failure", and iOS sends
  /// only `localizedDescription` for its errors. Codes win where there is one.
  static BleFailureKind fromError({
    String? code,
    String? message,
    String? details,
    String? disconnectReason,
    bool isTimeout = false,
  }) {
    if (isTimeout) return BleFailureKind.timeout;
    final text = '${message ?? ''} ${disconnectReason ?? ''}'.toLowerCase();
    bool has(String part) => text.contains(part);

    if (has('key missing') ||
        has('peer removed pairing') ||
        has('removed pairing information')) {
      return BleFailureKind.keyMissing;
    }
    if (has('authentication failure') || code == 'authenticationFailure') {
      return BleFailureKind.authenticationFailure;
    }
    switch (code) {
      case 'insufficientEncryption':
      case 'insufficientKeySize':
        return BleFailureKind.insufficientEncryption;
      case 'insufficientAuthentication':
      case 'pairingFailed':
      case 'pairingCancelled':
      case 'pairingNotAllowed':
      case 'notPaired':
      case 'protectionLevelNotMet':
        return BleFailureKind.pairingRejected;
      case 'connectionTimeout':
      case 'operationTimeout':
      case 'pairingTimeout':
        return BleFailureKind.timeout;
    }
    if (has('encryption is insufficient') || has('insufficient encryption')) {
      return BleFailureKind.insufficientEncryption;
    }
    if (has('authentication is insufficient') ||
        has('insufficient authentication') ||
        has('failed to pair') ||
        has('pairing not allowed') ||
        has('pairing')) {
      return BleFailureKind.pairingRejected;
    }
    if (has('timed out') || has('timeout')) return BleFailureKind.timeout;
    // iOS read errors carry the numeric CBATTError code in `details`.
    switch (details) {
      case '5':
        return BleFailureKind.pairingRejected;
      case '15':
        return BleFailureKind.insufficientEncryption;
    }
    if (code == 'deviceDisconnected' ||
        code == 'connectionTerminated' ||
        has('disconnect') ||
        has('terminated') ||
        disconnectReason != null) {
      return BleFailureKind.disconnected;
    }
    return BleFailureKind.other;
  }
}

/// Where a connect attempt stood when it ended.
enum PairingStep {
  /// Connecting and discovering services.
  connecting,

  /// Android only: asking the OS to bond.
  bonding,

  /// Reading `fe02`, which needs encryption - the moment iOS pairs, and the
  /// proof on both platforms that the link is secure.
  securing,

  /// Finished, one way or the other.
  done,
}

/// The one thing the user is told about a connect attempt.
enum PairingOutcome {
  /// Connected, and encrypted where the recorder asks for it.
  success,

  /// The recorder has another owner and refused this phone at connect.
  notOwner,

  /// The recorder admitted this phone (it still resolves as a phone it knew)
  /// but refused to pair: it needs its pairing window opened.
  needsPairingWindow,

  /// This phone holds a key the recorder no longer has. Only the user can
  /// remove it, in the phone's Bluetooth settings.
  staleBond,

  /// Nothing answered in time.
  timeout,

  /// Anything else - out of range, a cancelled prompt. "Try again" territory.
  failed;

  /// A problem pairing, rather than with the radio: these get their own
  /// screens, and always-listening stops hammering on them.
  bool get isPairingProblem =>
      this == notOwner || this == needsPairingWindow || this == staleBond;

  /// Shown as "Paired to another phone" with the charger instructions.
  bool get needsCharger => this == notOwner || this == needsPairingWindow;

  /// How soon after connecting a plain drop still reads as "refused": the
  /// recorder disconnects a stranger within a connection event or two.
  static const Duration refusalWindow = Duration(seconds: 2);

  /// Decides the outcome of a failed attempt.
  ///
  /// [advert] is what the scan response said (null: not seen, or older
  /// firmware); [bondedBefore] whether the phone already held a bond when the
  /// attempt began; [sinceConnected] how long the link had been up, null when
  /// it never came up.
  static PairingOutcome classify({
    required PairingStep step,
    required BleFailureKind kind,
    PairingAdvert? advert,
    bool bondedBefore = false,
    Duration? sinceConnected,
  }) {
    final owned = advert?.owned ?? false;
    final windowOpen = advert?.windowOpen ?? false;
    final quickDrop =
        sinceConnected == null || sinceConnected <= refusalWindow;

    switch (kind) {
      case BleFailureKind.timeout:
        return PairingOutcome.timeout;
      case BleFailureKind.keyMissing:
        return PairingOutcome.staleBond;
      case BleFailureKind.authenticationFailure:
        // The recorder's refusal of a stranger. After the link was up for a
        // while it is its 45 s "never encrypted" limit instead.
        if (step == PairingStep.connecting || quickDrop) {
          return windowOpen ? PairingOutcome.failed : PairingOutcome.notOwner;
        }
        return owned && !windowOpen
            ? PairingOutcome.needsPairingWindow
            : PairingOutcome.failed;
      case BleFailureKind.insufficientEncryption:
        if (bondedBefore) return PairingOutcome.staleBond;
        return owned && !windowOpen
            ? PairingOutcome.needsPairingWindow
            : PairingOutcome.failed;
      case BleFailureKind.pairingRejected:
        if (windowOpen) return PairingOutcome.failed;
        // A recorder with an owner refuses pairing outside its window. With no
        // scan response to go on, a remembered recorder refusing is the same.
        if (owned || advert == null) return PairingOutcome.needsPairingWindow;
        return PairingOutcome.failed;
      case BleFailureKind.disconnected:
        if (!owned || windowOpen) return PairingOutcome.failed;
        if (step == PairingStep.connecting) return PairingOutcome.notOwner;
        return quickDrop
            ? PairingOutcome.notOwner
            : PairingOutcome.needsPairingWindow;
      case BleFailureKind.other:
        return PairingOutcome.failed;
    }
  }
}
