import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/pairing_advert.dart';
import 'package:voicenotetaker_app/model/pairing_flow.dart';
import 'package:voicenotetaker_app/model/pairing_outcome.dart';
import 'package:voicenotetaker_app/model/recorder_pairing.dart';

void main() {
  const ready = PairingAdvert(owned: false, windowOpen: false);
  const owned = PairingAdvert(owned: true, windowOpen: false);
  const window = PairingAdvert(owned: true, windowOpen: true);

  group('PairingFlow', () {
    test('Android, first pairing: connect, bond, secure', () {
      final flow = PairingFlow(advert: ready, systemBonds: true);
      expect(flow.step, PairingStep.connecting);
      expect(flow.connected(), PairingStep.bonding);
      expect(flow.bonded(), PairingStep.securing);
      expect(flow.secured(), PairingStep.done);
      expect(flow.outcome, PairingOutcome.success);
    });

    test('Android, already bonded: straight to securing', () {
      final flow =
          PairingFlow(advert: owned, systemBonds: true, bondedBefore: true);
      expect(flow.connected(), PairingStep.securing);
    });

    test('iOS never bonds explicitly: the read pairs', () {
      final flow = PairingFlow(advert: ready, systemBonds: false);
      expect(flow.connected(), PairingStep.securing);
      flow.secured();
      expect(flow.outcome, PairingOutcome.success);
    });

    test('older firmware: nothing to bond or secure', () {
      final flow = PairingFlow(advert: null, systemBonds: true);
      expect(flow.recorderPairs, isFalse);
      expect(flow.connected(), PairingStep.done);
      expect(flow.outcome, PairingOutcome.success);
    });

    test('a remembered owner with no scan still secures', () {
      final flow = PairingFlow(
        advert: null,
        systemBonds: false,
        rememberedOwner: true,
      );
      expect(flow.connected(), PairingStep.securing);
    });

    test('a failure ends it, classified at its step', () {
      final flow = PairingFlow(advert: owned, systemBonds: true);
      expect(
        flow.failed(BleFailureKind.authenticationFailure),
        PairingOutcome.notOwner,
      );
      expect(flow.step, PairingStep.done);
      // Later events change nothing.
      expect(flow.connected(), PairingStep.done);
      expect(flow.failed(BleFailureKind.timeout), PairingOutcome.notOwner);
    });

    test('bond refused while the window is open: try again', () {
      final flow = PairingFlow(advert: window, systemBonds: true);
      flow.connected();
      expect(
        flow.failed(
          BleFailureKind.pairingRejected,
          sinceConnected: const Duration(seconds: 4),
        ),
        PairingOutcome.failed,
      );
    });

    test('events out of order are ignored', () {
      final flow = PairingFlow(advert: ready, systemBonds: true);
      expect(flow.bonded(), PairingStep.connecting);
      expect(flow.secured(), PairingStep.connecting);
      expect(flow.outcome, isNull);
    });
  });

  group('RecorderPairing.resolve', () {
    test('no status: older firmware', () {
      expect(RecorderPairing.resolve(advert: null, bonded: true),
          RecorderPairing.legacy);
    });

    test('flags 00: ready to pair', () {
      expect(RecorderPairing.resolve(advert: ready), RecorderPairing.readyToPair);
      // A bond the recorder no longer has does not make it ours.
      expect(RecorderPairing.resolve(advert: ready, bonded: true),
          RecorderPairing.readyToPair);
    });

    test('flags 01: ours when bonded or remembered, else another phone', () {
      expect(RecorderPairing.resolve(advert: owned, bonded: true),
          RecorderPairing.yours);
      expect(RecorderPairing.resolve(advert: owned, remembered: true),
          RecorderPairing.yours);
      expect(RecorderPairing.resolve(advert: owned, bonded: false),
          RecorderPairing.pairedToAnother);
      expect(RecorderPairing.resolve(advert: owned),
          RecorderPairing.pairedToAnother);
    });

    test('a refusal outranks a stale bond', () {
      expect(
        RecorderPairing.resolve(advert: owned, bonded: true, refusedHere: true),
        RecorderPairing.pairedToAnother,
      );
    });

    test('flags 02/03: pairing mode, unless it is already ours', () {
      expect(
        RecorderPairing.resolve(
          advert: const PairingAdvert(owned: false, windowOpen: true),
        ),
        RecorderPairing.pairingMode,
      );
      expect(RecorderPairing.resolve(advert: window),
          RecorderPairing.pairingMode);
      expect(RecorderPairing.resolve(advert: window, remembered: true),
          RecorderPairing.yours);
      expect(
        RecorderPairing.resolve(
            advert: window, remembered: true, refusedHere: true),
        RecorderPairing.pairingMode,
      );
    });
  });
}
