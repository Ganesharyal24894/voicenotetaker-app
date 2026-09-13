import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/edge_state.dart';

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

  // What used to be a bare red line under the title. A refused permission now
  // gets the whole screen and an action, because a line of red text tells the
  // user what happened and nothing about what to do next.
  testWidgets('a refused scan permission gets the permission screen, not a '
      'red line', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    when(() => harness.transport.ensurePermissions())
        .thenAnswer((_) async => false);
    await harness.controller.startScan();
    await pumpScreen(tester, ScanView(controller: harness.controller));

    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    expect(find.text('Open app settings'), findsOneWidget);
    expect(find.text('Bluetooth permission was denied.'), findsNothing);
    // The device list and the scan control are gone: scanning cannot work.
    expect(find.text('Tap to scan'), findsNothing);
  });

  // A failure NO edge state covers must still be visible somewhere, so the
  // line survives for exactly those - it is no longer where categorised
  // failures are reported.
  testWidgets('a failure with no edge state of its own still surfaces as a '
      'line', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    final path = await harness.seedRecording();
    harness.fileStore.undeletable.add(path);
    await harness.controller.deleteRecording(
      harness.controller.recordings.single,
    );
    await pumpScreen(tester, ScanView(controller: harness.controller));

    expect(find.byType(EdgeState), findsNothing);
    final message = tester.widget<Text>(
      find.textContaining('Could not delete'),
    );
    expect(message.style?.color, AppColors.error);
  });

  test('a device is only "known" when it advertises the recorder name', () {
    expect(ScanView.isKnown(knownDevice), isTrue);
    expect(ScanView.isKnown(unknownDevice), isFalse);
  });
}
