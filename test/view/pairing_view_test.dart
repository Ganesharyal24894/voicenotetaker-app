import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/pairing_advert.dart';
import 'package:voicenotetaker_app/model/pairing_outcome.dart';
import 'package:voicenotetaker_app/view/pair_new_phone_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';

import 'harness.dart';

/// Pairing on screen: the device card states, `PairingMode.dc.html`, the
/// stale-bond advice and the PAIRING section of `Settings.dc.html`.
void main() {
  setUpAll(registerViewFallbacks);

  const ready = PairingAdvert(owned: false, windowOpen: false);
  const owned = PairingAdvert(owned: true, windowOpen: false);
  const window = PairingAdvert(owned: true, windowOpen: true);

  DiscoveredDevice recorder(String id, PairingAdvert? advert, {bool? bonded}) =>
      DiscoveredDevice(
        id: id,
        name: 'voiceNotetaker',
        rssi: -50,
        pairing: advert,
        bonded: bonded,
      );

  Widget scan(ViewHarness harness) => ListenableBuilder(
        listenable: harness.controller,
        builder: (context, _) => ScanView(controller: harness.controller),
      );

  Future<ViewHarness> started(
    WidgetTester tester, {
    FakeBlePairing? pairing,
    List<DiscoveredDevice> devices = const <DiscoveredDevice>[],
  }) async {
    final harness = ViewHarness(
      pairing: pairing ?? FakeBlePairing(),
      devices: devices,
    );
    addTearDown(harness.dispose);
    await harness.begin(tester);
    return harness;
  }

  testWidgets('each card says how the recorder stands with this phone',
      (tester) async {
    final harness = await started(
      tester,
      pairing: FakeBlePairing(bondedIds: <String>{'00:00:00:00:00:02'}),
      devices: <DiscoveredDevice>[
        recorder('00:00:00:00:00:01', ready, bonded: false),
        recorder('00:00:00:00:00:02', owned, bonded: true),
        recorder('00:00:00:00:00:03', owned, bonded: false),
        recorder('00:00:00:00:00:04', window, bonded: false),
        recorder('00:00:00:00:00:05', null),
      ],
    );
    await harness.discover(tester);
    await pumpScreen(tester, scan(harness), size: const Size(390, 1600));

    expect(find.text('Ready to pair'), findsOneWidget);
    expect(find.text('Your recorder'), findsOneWidget);
    expect(find.text('Paired to another phone'), findsOneWidget);
    expect(find.text('Ready to pair with this phone'), findsOneWidget);
    // Older firmware: the card as it always was, nothing added.
    expect(find.text('Connect'), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('no pairing driver: cards carry no pairing line',
      (tester) async {
    final harness = ViewHarness(
      devices: <DiscoveredDevice>[recorder('00:00:00:00:00:01', owned)],
    );
    addTearDown(harness.dispose);
    await harness.discover(tester);
    await pumpScreen(tester, scan(harness));

    expect(find.text('Paired to another phone'), findsNothing);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('tapping a recorder paired to another phone shows the '
      'charger instructions', (tester) async {
    final device = recorder(knownDevice.id, owned, bonded: false);
    final harness =
        await started(tester, devices: <DiscoveredDevice>[device]);
    await harness.discover(tester);
    await pumpScreen(tester, scan(harness));

    await tester.tap(find.text('Connect'));
    await flush(tester);

    expect(find.text('Paired to another phone'), findsOneWidget);
    expect(find.text(ScanView.pairingBody), findsOneWidget);
    expect(find.text("I've done that"), findsOneWidget);
    expect(find.text('Why?'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    verifyNever(() => harness.transport.connect(any()));

    await tester.tap(find.text('Why?'));
    await tester.pumpAndSettle();
    expect(find.text('Why pair this way'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets("I've done that looks for the window, then says it wasn't seen",
      (tester) async {
    final device = recorder(knownDevice.id, owned, bonded: false);
    final harness =
        await started(tester, devices: <DiscoveredDevice>[device]);
    await harness.controller.connect(device);
    await pumpScreen(tester, scan(harness));

    await tester.tap(find.text("I've done that"));
    await flush(tester);
    expect(find.text('Looking…'), findsOneWidget);

    await harness.endScanWindow(tester);
    expect(find.text(ScanView.pairingMissedBody), findsOneWidget);
    expect(find.text("I've done that"), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await flush(tester);
    expect(find.text(ScanView.pairingMissedBody), findsNothing);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('pairing refused on a recorder that knew this phone: '
      'pair this phone again', (tester) async {
    final pairing = FakeBlePairing(systemBonds: false)
      ..secureError = const BleTransportException('refused')
      ..failureKind = BleFailureKind.pairingRejected;
    final harness = await started(tester, pairing: pairing);
    await harness.controller.connect(recorder(knownDevice.id, owned));
    await pumpScreen(tester, scan(harness));

    expect(harness.controller.pairingProblem,
        PairingOutcome.needsPairingWindow);
    expect(find.text(ScanView.pairAgainHeadline), findsOneWidget);
    expect(find.text(ScanView.pairingBody), findsOneWidget);
  });

  group('a stale bond', () {
    Future<ViewHarness> stale(WidgetTester tester) async {
      final pairing = FakeBlePairing(
        systemBonds: defaultTargetPlatform == TargetPlatform.android,
        bondedIds: <String>{knownDevice.id},
      )
        ..secureError = const BleTransportException('key missing')
        ..failureKind = BleFailureKind.keyMissing;
      final harness = await started(tester, pairing: pairing);
      await harness.controller.connect(recorder(knownDevice.id, ready));
      await pumpScreen(tester, scan(harness));
      return harness;
    }

    testWidgets('Android opens Bluetooth settings', (tester) async {
      final harness = await stale(tester);

      expect(find.text(ScanView.staleBondHeadline), findsOneWidget);
      expect(find.text(ScanView.staleBondBody), findsOneWidget);
      await tester.tap(find.text('Open Bluetooth settings'));
      await flush(tester);
      verify(() => harness.settings.openBluetoothSettings()).called(1);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('iOS says where to go, in words', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final harness = await stale(tester);

        expect(find.text(ScanView.staleBondBodyIos), findsOneWidget);
        expect(find.text('Open Bluetooth settings'), findsNothing);
        expect(find.text('Try again'), findsOneWidget);
        verifyNever(() => harness.settings.openBluetoothSettings());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Settings: PAIRING', () {
    Widget settings(ViewHarness harness, {VoidCallback? onPairNewPhone}) =>
        SettingsView(
          controller: harness.controller,
          onBack: () {},
          onPairNewPhone: onPairNewPhone,
        );

    testWidgets('paired to this phone, and a quiet way to pair a new one',
        (tester) async {
      final harness = await started(tester);
      await harness.controller.connect(recorder(knownDevice.id, ready, bonded: false));
      var opened = false;
      await pumpScreen(tester, settings(harness, onPairNewPhone: () => opened = true),
          size: const Size(390, 1200));

      expect(find.text('PAIRING'), findsOneWidget);
      expect(find.text(PairingCard.title), findsOneWidget);
      expect(find.textContaining('Since '), findsOneWidget);
      await tester.tap(find.text('Pair a new phone'));
      expect(opened, isTrue);
    });

    testWidgets('older firmware: no pairing section', (tester) async {
      final harness = await started(tester);
      await harness.controller.connect(recorder(knownDevice.id, null));
      await pumpScreen(tester, settings(harness), size: const Size(390, 1200));

      expect(find.text('PAIRING'), findsNothing);
    });

    testWidgets('Pair a new phone tells what to do on the new phone',
        (tester) async {
      final harness = await started(tester);
      await harness.controller.connect(recorder(knownDevice.id, ready, bonded: false));
      await pumpScreen(tester, settings(harness), size: const Size(390, 1200));

      await tester.tap(find.text('Pair a new phone'));
      await tester.pumpAndSettle();

      expect(find.text(PairNewPhoneView.body), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text(PairNewPhoneView.body), findsNothing);
      expect(find.text(PairingCard.title), findsOneWidget);
    });
  });
}
