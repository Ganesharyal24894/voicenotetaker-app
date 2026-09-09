import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';

import 'harness.dart';

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('builds while scanning with nothing discovered yet',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));

    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Scanning…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds idle, before a scan has been started', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await pumpScreen(tester, ScanView(controller: harness.controller));

    expect(find.text('Tap to scan'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders discovered devices with their MAC addresses',
      (tester) async {
    final harness = ViewHarness(
      devices: <DiscoveredDevice>[knownDevice, unknownDevice],
    );
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));

    // The address is how two identical recorders are told apart, so it is on
    // screen for both of them.
    expect(find.text('voiceNotetaker'), findsOneWidget);
    expect(find.text('EB:6B:5E:4C:33:A3'), findsOneWidget);
    expect(find.text('Unknown device'), findsOneWidget);
    expect(find.text('C2:1A:90:07:4E:B8'), findsOneWidget);

    expect(find.text('−54 dBm'), findsOneWidget);
    expect(find.text('−88 dBm'), findsOneWidget);
  });

  testWidgets('only the recorder gets a Connect button, and unknown devices '
      'are dimmed', (tester) async {
    final harness = ViewHarness(
      devices: <DiscoveredDevice>[knownDevice, unknownDevice],
    );
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));

    expect(find.text('Connect'), findsOneWidget);

    final dimmed = tester.widgetList<Opacity>(find.byType(Opacity)).where(
          (o) => o.opacity == 0.55,
        );
    expect(dimmed, hasLength(1));
  });

  testWidgets('tapping Connect asks the transport to connect', (tester) async {
    final harness = ViewHarness(
      devices: <DiscoveredDevice>[knownDevice],
    );
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));

    await tester.tap(find.text('Connect'));
    await flush(tester);

    verify(() => harness.transport.connect(knownDevice.id)).called(1);
  });

  testWidgets('the Connect button clears the 44px minimum hit target',
      (tester) async {
    final harness = ViewHarness(
      devices: <DiscoveredDevice>[knownDevice],
    );
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));

    final size = tester.getSize(find.text('Connect').hitTestable());
    expect(size.height, lessThanOrEqualTo(AppShape.minTapTarget));
    final button = tester.getSize(
      find.ancestor(
        of: find.text('Connect'),
        matching: find.byType(Container),
      ).first,
    );
    expect(button.height, greaterThanOrEqualTo(AppShape.minTapTarget));
  });

  testWidgets('surfaces a controller error', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    when(() => harness.transport.ensurePermissions())
        .thenAnswer((_) async => false);
    await harness.controller.startScan();
    await pumpScreen(tester, ScanView(controller: harness.controller));

    expect(find.text('Bluetooth permission was denied.'), findsOneWidget);
    final message = tester.widget<Text>(
      find.text('Bluetooth permission was denied.'),
    );
    expect(message.style?.color, AppColors.error);
  });

  test('a device is only "known" when it advertises the recorder name', () {
    expect(ScanView.isKnown(knownDevice), isTrue);
    expect(ScanView.isKnown(unknownDevice), isFalse);
  });
}
