import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/continuous_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/pairing_advert.dart';
import 'package:voicenotetaker_app/model/pairing_outcome.dart';
import 'package:voicenotetaker_app/model/reconnect_backoff.dart';
import 'package:voicenotetaker_app/model/recorder_pairing.dart';

import '../view/harness.dart';

/// Pairing at the controller: the scan states, the connect flow, "I've done
/// that", and always-listening against a recorder that refuses this phone.
void main() {
  setUpAll(registerViewFallbacks);

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  const ready = PairingAdvert(owned: false, windowOpen: false);
  const owned = PairingAdvert(owned: true, windowOpen: false);
  const window = PairingAdvert(owned: true, windowOpen: true);

  DiscoveredDevice recorder(PairingAdvert? advert, {bool? bonded}) =>
      DiscoveredDevice(
        id: knownDevice.id,
        name: knownDevice.name,
        rssi: -50,
        pairing: advert,
        bonded: bonded,
      );

  Future<ViewHarness> started(FakeBlePairing pairing,
      {List<DiscoveredDevice> devices = const <DiscoveredDevice>[]}) async {
    final harness = ViewHarness(pairing: pairing, devices: devices)
      ..captureSupported = true;
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    return harness;
  }

  test('a scan response arriving later updates the card', () async {
    final harness = await started(FakeBlePairing(),
        devices: <DiscoveredDevice>[recorder(null)]);
    await harness.controller.startScan();
    await settle();
    expect(harness.controller.pairingOf(harness.controller.devices.single),
        RecorderPairing.unknown);

    await harness.advertise(null, recorder(owned, bonded: false));

    expect(harness.controller.devices, hasLength(1));
    expect(harness.controller.pairingOf(harness.controller.devices.single),
        RecorderPairing.pairedToAnother);
  });

  test('Android first pairing: connected, bonded, and paired to this phone',
      () async {
    final pairing = FakeBlePairing();
    final harness = await started(pairing);

    await harness.controller.connect(recorder(ready, bonded: false));

    expect(pairing.calls, <String>['bond ${knownDevice.id}', 'secure ${knownDevice.id}']);
    expect(harness.controller.isConnected, isTrue);
    expect(harness.controller.pairedToThisPhone, isTrue);
    expect(harness.controller.pairedSince, isNotNull);
  });

  test('a recorder that says nothing about pairing still connects', () async {
    final pairing = FakeBlePairing();
    final harness = await started(pairing);

    await harness.controller.connect(recorder(null));

    expect(pairing.calls, isEmpty);
    expect(harness.controller.isConnected, isTrue);
    expect(harness.controller.pairedToThisPhone, isFalse);
  });

  test('Android, paired to another phone: instructions with no radio time',
      () async {
    final harness = await started(FakeBlePairing());

    await harness.controller.connect(recorder(owned, bonded: false));

    expect(harness.controller.pairingProblem, PairingOutcome.notOwner);
    verifyNever(() => harness.transport.connect(any()));
    expect(harness.controller.phase, AppPhase.idle);
  });

  test('iOS cannot know: it tries once, and a refusal shows the instructions',
      () async {
    final pairing = FakeBlePairing(systemBonds: false)
      ..failureKind = BleFailureKind.disconnected;
    final harness = await started(pairing);
    when(() => harness.transport.connect(any()))
        .thenThrow(const BleTransportException('dropped'));

    await harness.controller.connect(recorder(owned));

    verify(() => harness.transport.connect(knownDevice.id)).called(1);
    expect(harness.controller.pairingProblem, PairingOutcome.notOwner);
    expect(harness.controller.linkOutcome, LinkOutcome.none);
    expect(harness.controller.pairingOf(recorder(owned)),
        RecorderPairing.pairedToAnother);
  });

  test('iOS reinstalled on the owner: the read encrypts silently', () async {
    final pairing = FakeBlePairing(systemBonds: false);
    final harness = await started(pairing);

    await harness.controller.connect(recorder(owned));

    expect(harness.controller.isConnected, isTrue);
    expect(harness.controller.pairingProblem, isNull);
    expect(harness.controller.pairedToThisPhone, isTrue);
  });

  test('a stale key: disconnects and asks for Bluetooth settings', () async {
    final pairing = FakeBlePairing(bondedIds: <String>{knownDevice.id})
      ..secureError = const BleTransportException('key missing')
      ..failureKind = BleFailureKind.keyMissing;
    final harness = await started(pairing);

    await harness.controller.connect(recorder(ready, bonded: true));

    expect(harness.controller.pairingProblem, PairingOutcome.staleBond);
    expect(harness.controller.isConnected, isFalse);
    verify(() => harness.transport.disconnect(knownDevice.id)).called(1);
  });

  test('a pairing that simply failed is the usual "Couldn\'t connect"',
      () async {
    final pairing = FakeBlePairing()
      ..bondError = const BleTransportException('cancelled')
      ..failureKind = BleFailureKind.pairingRejected;
    final harness = await started(pairing);

    await harness.controller.connect(recorder(ready, bonded: false));

    expect(harness.controller.pairingProblem, isNull);
    expect(harness.controller.linkOutcome, LinkOutcome.connectFailed);
  });

  test("I've done that: connects as soon as the window shows open", () async {
    final harness = await started(FakeBlePairing(),
        devices: <DiscoveredDevice>[recorder(owned, bonded: false)]);
    await harness.controller.connect(recorder(owned, bonded: false));
    expect(harness.controller.pairingProblem, PairingOutcome.notOwner);

    await harness.controller.retryPairing();
    await settle();
    expect(harness.controller.lookingForPairingWindow, isTrue);
    expect(harness.controller.isConnected, isFalse);

    await harness.advertise(null, recorder(window, bonded: false));
    await settle();

    expect(harness.controller.isConnected, isTrue);
    expect(harness.controller.pairingProblem, isNull);
    expect(harness.controller.pairedToThisPhone, isTrue);
  });

  test("I've done that, and no window: the instructions come back", () async {
    final harness = await started(FakeBlePairing(),
        devices: <DiscoveredDevice>[recorder(owned, bonded: false)]);
    await harness.controller.connect(recorder(owned, bonded: false));

    await harness.controller.retryPairing();
    await settle();
    await harness.endScanWindowNow();

    expect(harness.controller.lookingForPairingWindow, isFalse);
    expect(harness.controller.pairingWindowMissed, isTrue);
    expect(harness.controller.pairingProblem, PairingOutcome.notOwner);

    await harness.controller.dismissPairingProblem();
    expect(harness.controller.pairingProblem, isNull);
    expect(harness.controller.pairingWindowMissed, isFalse);
  });

  group('always listening', () {
    test('a recorder that keeps refusing: status, then ten-minute waits',
        () async {
      final pairing = FakeBlePairing(systemBonds: false);
      final harness = await started(pairing);
      await harness.controller.connect(recorder(ready));
      await harness.controller.setContinuousEnabled(true);

      // Replaced by another phone: refused right after connecting.
      pairing.failureKind = BleFailureKind.authenticationFailure;
      when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
          .thenThrow(const BleTransportException('refused'));
      harness.link.add(BleConnectionStatus.disconnected);
      await settle();

      verify(() => harness.transport
          .connect(any(), timeout: ReconnectBackoff.attemptTimeout)).called(1);
      expect(harness.controller.continuousStatus,
          ContinuousStatus.pairedToAnother);
      expect(harness.controller.errorMessage, isNull);
      // One refusal: the usual ladder still.
      expect(harness.controller.scheduledReconnectDelay,
          const Duration(seconds: 2));

      await Future<void>.delayed(const Duration(milliseconds: 2200));
      verify(() => harness.transport
          .connect(any(), timeout: ReconnectBackoff.attemptTimeout)).called(1);
      expect(harness.controller.scheduledReconnectDelay,
          ReconnectBackoff.refusedDelay);
      expect(harness.controller.pairedToThisPhone, isFalse,
          reason: 'the refusal forgot it');
    });

    test('an out-of-range failure keeps the minute ladder', () async {
      final pairing = FakeBlePairing(systemBonds: false);
      final harness = await started(pairing);
      await harness.controller.connect(recorder(ready));
      await harness.controller.setContinuousEnabled(true);

      pairing.failureKind = BleFailureKind.timeout;
      when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
          .thenThrow(const BleTransportException('timeout'));
      harness.link.add(BleConnectionStatus.disconnected);
      await settle();

      expect(harness.controller.continuousStatus,
          ContinuousStatus.notConnected);
      expect(harness.controller.scheduledReconnectDelay,
          const Duration(seconds: 2));
    });

    test('Android reconnects through the bonded identity address', () async {
      const identity = 'C0:FF:EE:00:00:01';
      final pairing = FakeBlePairing()..identities = <String>[identity];
      final harness = await started(pairing);
      await harness.controller.connect(recorder(ready, bonded: false));
      await harness.controller.setContinuousEnabled(true);
      clearInteractions(harness.transport);

      harness.link.add(BleConnectionStatus.disconnected);
      await settle();

      verify(() => harness.transport
          .connect(identity, timeout: ReconnectBackoff.attemptTimeout)).called(1);
    });
  });
}
