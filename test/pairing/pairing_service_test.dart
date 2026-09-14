import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/pairing_advert.dart';
import 'package:voicenotetaker_app/model/pairing_outcome.dart';
import 'package:voicenotetaker_app/model/recorder_pairing.dart';
import 'package:voicenotetaker_app/services/pairing/pairing_service.dart';
import 'package:voicenotetaker_app/services/pairing/pairing_store.dart';

import '../view/harness.dart';

void main() {
  const ready = PairingAdvert(owned: false, windowOpen: false);
  const owned = PairingAdvert(owned: true, windowOpen: false);
  final day = DateTime(2026, 9, 2, 10);

  (PairingService, MemoryFileStore) build(FakeBlePairing driver,
      {MemoryFileStore? files}) {
    final store = files ?? MemoryFileStore();
    return (
      PairingService(
        driver: driver,
        store: PairingStore(fileStore: store, directory: '/support'),
        clock: () => day,
      ),
      store,
    );
  }

  DiscoveredDevice recorder(String id, PairingAdvert? advert, {bool? bonded}) =>
      DiscoveredDevice(
        id: id,
        name: 'voiceNotetaker',
        pairing: advert,
        bonded: bonded,
      );

  test('Android first pairing bonds, secures and remembers since when',
      () async {
    final driver = FakeBlePairing();
    final (service, _) = build(driver);

    final attempt = await service.begin(recorder('AA', ready, bonded: false));
    expect(await attempt.afterConnect(), PairingOutcome.success);

    expect(driver.calls, <String>['bond AA', 'secure AA']);
    expect(service.isOwner('aa'), isTrue);
    expect(service.pairedSince('AA'), day);
  });

  test('the bond kept under an identity address is remembered too', () async {
    final driver = FakeBlePairing()..identities = <String>['C0:FF:EE:00:00:01'];
    final (service, _) = build(driver);

    final attempt =
        await service.begin(recorder('5A:11:22:33:44:55', ready, bonded: false));
    await attempt.afterConnect();

    expect(attempt.ownerId, 'C0:FF:EE:00:00:01');
    expect(service.isOwner('C0:FF:EE:00:00:01'), isTrue);
    expect(await service.reconnectId('5A:11:22:33:44:55'), 'C0:FF:EE:00:00:01');
  });

  test('iOS pairs on the read alone', () async {
    final driver = FakeBlePairing(systemBonds: false);
    final (service, _) = build(driver);

    final attempt = await service.begin(recorder('UUID-1', ready));
    expect(await attempt.afterConnect(), PairingOutcome.success);

    expect(driver.calls, <String>['secure UUID-1']);
    expect(service.isOwner('UUID-1'), isTrue);
    expect(await service.reconnectId('UUID-1'), 'UUID-1');
  });

  test('older firmware is neither bonded, secured nor remembered', () async {
    final driver = FakeBlePairing();
    final (service, _) = build(driver);

    final attempt = await service.begin(recorder('AA', null));
    expect(await attempt.afterConnect(), PairingOutcome.success);

    expect(driver.calls, isEmpty);
    expect(service.isOwner('AA'), isFalse);
    expect(service.stateOf(recorder('AA', null)), RecorderPairing.legacy);
  });

  test('a refused pairing forgets the recorder', () async {
    final driver = FakeBlePairing(systemBonds: false);
    final (service, files) = build(driver);
    await service.begin(recorder('UUID-1', ready)).then((a) => a.afterConnect());
    expect(service.isOwner('UUID-1'), isTrue);

    driver
      ..secureError = const BleTransportException('refused')
      ..failureKind = BleFailureKind.pairingRejected;
    final attempt = await service.begin(recorder('UUID-1', owned));
    expect(await attempt.afterConnect(), PairingOutcome.needsPairingWindow);
    expect(service.isOwner('UUID-1'), isFalse);

    // And stays forgotten across a restart.
    final (again, _) = build(driver, files: files);
    await again.load();
    expect(again.isOwner('UUID-1'), isFalse);
  });

  test('a stale key is reported, not forgotten', () async {
    final driver = FakeBlePairing(bondedIds: <String>{'AA'})
      ..secureError = const BleTransportException('no key')
      ..failureKind = BleFailureKind.keyMissing;
    final (service, _) = build(driver);

    final attempt = await service.begin(recorder('AA', ready, bonded: true));
    expect(await attempt.afterConnect(), PairingOutcome.staleBond);
    expect(driver.calls, <String>['secure AA'], reason: 'already bonded');
  });

  test('a connect that throws is classified', () async {
    final driver = FakeBlePairing()
      ..failureKind = BleFailureKind.authenticationFailure;
    final (service, _) = build(driver);

    final attempt = await service.begin(recorder('AA', owned, bonded: false));
    expect(
      await attempt.connectFailed(const BleTransportException('refused')),
      PairingOutcome.notOwner,
    );
  });

  test('the record survives a restart and a damaged file reads as empty',
      () async {
    final driver = FakeBlePairing(systemBonds: false);
    final (service, files) = build(driver);
    await service.begin(recorder('UUID-1', ready)).then((a) => a.afterConnect());

    final (again, _) = build(driver, files: files);
    await again.load();
    expect(again.pairedSince('uuid-1'), day);
    expect(again.stateOf(recorder('UUID-1', owned)), RecorderPairing.yours);

    files.files['/support/${PairingStore.fileName}'] = <int>[0x7B, 0x7B];
    final (damaged, _) = build(driver, files: files);
    await damaged.load();
    expect(damaged.isOwner('UUID-1'), isFalse);
  });

  test('reconnectId leaves recorders it does not own alone', () async {
    final driver = FakeBlePairing(bondedIds: <String>{'C0:FF:EE:00:00:01'});
    final (service, _) = build(driver);
    await service.load();
    expect(await service.reconnectId('EB:6B:5E:4C:33:A3'), 'EB:6B:5E:4C:33:A3');
  });
}
