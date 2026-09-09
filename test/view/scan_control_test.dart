import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/widgets/scan_control.dart';

import 'harness.dart';

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('the scan control is a 96px circle in a 116px hit area',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await pumpScreen(tester, ScanView(controller: harness.controller));

    // The thing this replaced was a ~13px spinner with a small label beside
    // it. The hit target is now the whole ripple area.
    final target = tester.getSize(find.bySemanticsLabel('Scan for devices'));
    expect(target.width, greaterThanOrEqualTo(96));
    expect(target.height, greaterThanOrEqualTo(96));
    expect(target.width, ScanControl.rippleSize);
    expect(target.height, ScanControl.rippleSize);
    expect(ScanControl.discSize, 96);
  });

  testWidgets('it is dead centre in the space below the device list',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));
    await tester.pump(const Duration(milliseconds: 600));

    final screen = tester.getSize(find.byType(ScanView));
    final control = tester.getRect(find.byType(ScanControl));
    expect(control.center.dx, moreOrLessEquals(screen.width / 2, epsilon: 0.5));
  });

  testWidgets('it is reachable: tapping it starts a scan', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await pumpScreen(tester, ScanView(controller: harness.controller));
    expect(find.text('Tap to scan'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Scan for devices').hitTestable());
    await flush(tester);

    expect(harness.controller.isScanning, isTrue);
  });

  testWidgets('and tapping it again stops one', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    // `ScanView` is stateless and `AppRoot` is what listens, so the screen is
    // built from the controller's state rather than rebuilt after the tap.
    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));
    expect(find.text('Scanning…'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Stop scanning').hitTestable());
    await flush(tester);

    expect(harness.controller.isScanning, isFalse);
  });

  testWidgets('the device count moves to the header', (tester) async {
    final harness = ViewHarness(
      devices: const <DiscoveredDevice>[knownDevice],
    );
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));

    expect(find.text('1 found'), findsOneWidget);
    // ...and it is in the header row, not beside the control.
    final header = tester.getRect(find.text('Devices'));
    final count = tester.getRect(find.text('1 found'));
    expect(count.center.dy, moreOrLessEquals(header.center.dy, epsilon: 8));
  });

  testWidgets('nothing keeps ticking once the control is gone',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));
    // Both loops running: the glyph turning and the rings rippling.
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    // Let them run, then tear the screen down. A controller that outlived its
    // State would surface here as a pending timer or a live ticker.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));

    expect(tester.binding.transientCallbackCount, 0);
  });
}
