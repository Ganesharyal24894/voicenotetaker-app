/// One connect attempt, step by step, as a pure state machine.
///
/// ```
/// connecting --connected--> bonding   (Android, recorder pairs, no bond yet)
///            \-connected--> securing  (recorder pairs: bonded, or iOS)
///             \-connected-> done      (older firmware: nothing to secure)
/// bonding    --bonded-----> securing
/// securing   --secured----> done (success)
/// any        --failed-----> done (PairingOutcome.classify)
/// ```
///
/// SECURING IS A READ OF `fe02`. Every characteristic needs encryption, so the
/// read either rides a link the stored key already encrypted, or is what makes
/// iOS show its pairing alert. Its success is the proof, on both platforms,
/// that this phone is the owner.
///
/// The service (`services/pairing/pairing_service.dart`) runs the drivers;
/// this decides what comes next and what it meant.
library;

import 'pairing_advert.dart';
import 'pairing_outcome.dart';

class PairingFlow {
  PairingFlow({
    required this.advert,
    required this.systemBonds,
    this.bondedBefore = false,
    this.rememberedOwner = false,
  });

  /// The scan response's status; null when not seen.
  final PairingAdvert? advert;

  /// The platform bonds explicitly (Android `createBond`). False on iOS, where
  /// pairing happens on the first encrypted read.
  final bool systemBonds;

  /// The OS already held a bond when the attempt began.
  final bool bondedBefore;

  /// The app remembers an encrypted connection to this recorder.
  final bool rememberedOwner;

  PairingStep _step = PairingStep.connecting;
  PairingOutcome? _outcome;

  PairingStep get step => _step;

  /// Null until [step] is [PairingStep.done].
  PairingOutcome? get outcome => _outcome;

  /// Whether this recorder is one that pairs at all. Unknown recorders - older
  /// firmware, or a remembered id with no scan - connect exactly as before.
  bool get recorderPairs => advert != null || rememberedOwner;

  /// The link is up and services are discovered.
  PairingStep connected() {
    if (_step != PairingStep.connecting) return _step;
    if (!recorderPairs) {
      _finish(PairingOutcome.success);
    } else if (systemBonds && !bondedBefore) {
      _step = PairingStep.bonding;
    } else {
      _step = PairingStep.securing;
    }
    return _step;
  }

  /// The OS reports the bond made.
  PairingStep bonded() {
    if (_step == PairingStep.bonding) _step = PairingStep.securing;
    return _step;
  }

  /// The encrypted read answered.
  PairingStep secured() {
    if (_step == PairingStep.securing) _finish(PairingOutcome.success);
    return _step;
  }

  /// The current step failed with [kind].
  PairingOutcome failed(BleFailureKind kind, {Duration? sinceConnected}) {
    if (_step == PairingStep.done) return _outcome!;
    final outcome = PairingOutcome.classify(
      step: _step,
      kind: kind,
      advert: advert,
      bondedBefore: bondedBefore,
      sinceConnected: sinceConnected,
    );
    _finish(outcome);
    return outcome;
  }

  void _finish(PairingOutcome outcome) {
    _outcome = outcome;
    _step = PairingStep.done;
  }
}
