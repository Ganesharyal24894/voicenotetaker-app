import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/pairing_advert.dart';
import 'package:voicenotetaker_app/model/pairing_outcome.dart';

/// Error mapping and outcome classification - firmware `doc/pairing.md`,
/// "Failure behaviours" and "What the app must do", step 4.
void main() {
  group('BleFailureKind.fromError', () {
    test('Android HCI 0x05 on disconnect: authentication failure', () {
      expect(
        BleFailureKind.fromError(message: 'Authentication Failure'),
        BleFailureKind.authenticationFailure,
      );
      expect(
        BleFailureKind.fromError(
          code: 'deviceDisconnected',
          message: 'Device Disconnected',
          disconnectReason: 'Authentication Failure',
        ),
        BleFailureKind.authenticationFailure,
      );
    });

    test('a key the recorder no longer has', () {
      expect(BleFailureKind.fromError(disconnectReason: 'PIN or Key Missing'),
          BleFailureKind.keyMissing);
      expect(
        BleFailureKind.fromError(
            message: 'Peer removed pairing information'),
        BleFailureKind.keyMissing,
      );
    });

    test('pairing refused or cancelled', () {
      expect(BleFailureKind.fromError(code: 'pairingFailed', message: 'Failed to pair'),
          BleFailureKind.pairingRejected);
      expect(BleFailureKind.fromError(code: 'insufficientAuthentication'),
          BleFailureKind.pairingRejected);
      expect(BleFailureKind.fromError(message: 'Authentication is insufficient.'),
          BleFailureKind.pairingRejected);
      expect(
        BleFailureKind.fromError(code: 'unknownError', message: 'x', details: '5'),
        BleFailureKind.pairingRejected,
        reason: 'iOS CBATTError 5 in details',
      );
    });

    test('insufficient encryption', () {
      expect(BleFailureKind.fromError(code: 'insufficientEncryption'),
          BleFailureKind.insufficientEncryption);
      expect(BleFailureKind.fromError(message: 'Encryption is insufficient.'),
          BleFailureKind.insufficientEncryption);
      expect(BleFailureKind.fromError(details: '15'),
          BleFailureKind.insufficientEncryption);
    });

    test('timeouts', () {
      expect(BleFailureKind.fromError(isTimeout: true), BleFailureKind.timeout);
      expect(BleFailureKind.fromError(code: 'connectionTimeout'),
          BleFailureKind.timeout);
      expect(BleFailureKind.fromError(message: 'Operation timed out'),
          BleFailureKind.timeout);
    });

    test('plain drops and the rest', () {
      expect(BleFailureKind.fromError(code: 'deviceDisconnected'),
          BleFailureKind.disconnected);
      expect(
        BleFailureKind.fromError(disconnectReason: 'Remote User Terminated Connection'),
        BleFailureKind.disconnected,
      );
      expect(BleFailureKind.fromError(message: 'boom'), BleFailureKind.other);
      expect(BleFailureKind.fromError(), BleFailureKind.other);
    });
  });

  group('PairingOutcome.classify', () {
    const ready = PairingAdvert(owned: false, windowOpen: false);
    const owned = PairingAdvert(owned: true, windowOpen: false);
    const window = PairingAdvert(owned: true, windowOpen: true);

    test('refused at connect: not the owner', () {
      expect(
        PairingOutcome.classify(
          step: PairingStep.connecting,
          kind: BleFailureKind.authenticationFailure,
          advert: owned,
        ),
        PairingOutcome.notOwner,
      );
      // iOS gives no reason: a drop on a recorder that has an owner.
      expect(
        PairingOutcome.classify(
          step: PairingStep.connecting,
          kind: BleFailureKind.disconnected,
          advert: owned,
        ),
        PairingOutcome.notOwner,
      );
      // No scan (always-listening): the reason alone is enough.
      expect(
        PairingOutcome.classify(
          step: PairingStep.connecting,
          kind: BleFailureKind.authenticationFailure,
        ),
        PairingOutcome.notOwner,
      );
    });

    test('a drop just after connecting, while securing, is a refusal too', () {
      expect(
        PairingOutcome.classify(
          step: PairingStep.securing,
          kind: BleFailureKind.disconnected,
          advert: owned,
          sinceConnected: const Duration(milliseconds: 300),
        ),
        PairingOutcome.notOwner,
      );
    });

    test('admitted, then pairing refused: needs the window', () {
      expect(
        PairingOutcome.classify(
          step: PairingStep.bonding,
          kind: BleFailureKind.pairingRejected,
          advert: owned,
          sinceConnected: const Duration(seconds: 3),
        ),
        PairingOutcome.needsPairingWindow,
      );
      expect(
        PairingOutcome.classify(
          step: PairingStep.securing,
          kind: BleFailureKind.disconnected,
          advert: owned,
          sinceConnected: const Duration(seconds: 8),
        ),
        PairingOutcome.needsPairingWindow,
        reason: 'the iOS alert refused, link dropped 200 ms later',
      );
    });

    test('a stale key', () {
      expect(
        PairingOutcome.classify(
          step: PairingStep.securing,
          kind: BleFailureKind.keyMissing,
          advert: ready,
        ),
        PairingOutcome.staleBond,
      );
      expect(
        PairingOutcome.classify(
          step: PairingStep.securing,
          kind: BleFailureKind.insufficientEncryption,
          advert: ready,
          bondedBefore: true,
        ),
        PairingOutcome.staleBond,
      );
    });

    test('inside an open window, or on a recorder with no owner, retry', () {
      for (final kind in <BleFailureKind>[
        BleFailureKind.pairingRejected,
        BleFailureKind.authenticationFailure,
        BleFailureKind.disconnected,
      ]) {
        expect(
          PairingOutcome.classify(
            step: PairingStep.bonding,
            kind: kind,
            advert: window,
            sinceConnected: const Duration(seconds: 5),
          ),
          PairingOutcome.failed,
          reason: kind.name,
        );
      }
      expect(
        PairingOutcome.classify(
          step: PairingStep.bonding,
          kind: BleFailureKind.pairingRejected,
          advert: ready,
        ),
        PairingOutcome.failed,
        reason: 'the user cancelled the prompt',
      );
    });

    test('out of time, or out of range', () {
      expect(
        PairingOutcome.classify(
          step: PairingStep.connecting,
          kind: BleFailureKind.timeout,
          advert: owned,
        ),
        PairingOutcome.timeout,
      );
      expect(
        PairingOutcome.classify(
          step: PairingStep.connecting,
          kind: BleFailureKind.disconnected,
        ),
        PairingOutcome.failed,
        reason: 'older firmware, or no scan: a drop is just a drop',
      );
      expect(
        PairingOutcome.classify(
          step: PairingStep.connecting,
          kind: BleFailureKind.other,
          advert: owned,
        ),
        PairingOutcome.failed,
      );
    });

    test('which outcomes are pairing problems', () {
      expect(
        PairingOutcome.values.where((o) => o.isPairingProblem).toSet(),
        <PairingOutcome>{
          PairingOutcome.notOwner,
          PairingOutcome.needsPairingWindow,
          PairingOutcome.staleBond,
        },
      );
      expect(
        PairingOutcome.values.where((o) => o.needsCharger).toSet(),
        <PairingOutcome>{
          PairingOutcome.notOwner,
          PairingOutcome.needsPairingWindow,
        },
      );
    });
  });
}
