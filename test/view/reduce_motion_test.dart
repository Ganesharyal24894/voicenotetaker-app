import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/device_mark.dart';
import 'package:voicenotetaker_app/view/widgets/motion.dart';
import 'package:voicenotetaker_app/view/widgets/scan_control.dart';

import 'harness.dart';

/// Pumps [child] at the mock's frame with the platform's reduce-motion setting
/// forced on or off.
///
/// `MediaQueryData(disableAnimations: true)` is applied with `copyWith` so the
/// screen still has a size and padding to lay itself out against; the flag
/// under test is the same one `MediaQuery.disableAnimationsOf` reads.
Future<void> pumpWithMotion(
  WidgetTester tester,
  Widget child, {
  required bool reduced,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(),
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
}

Widget _home(ViewHarness harness) => HomeView(
      controller: harness.controller,
      recents: const [],
      onOpenLibrary: () {},
      onOpenRecording: (_) {},
    );

void main() {
  setUpAll(registerViewFallbacks);

  group('the two loops go static', () {
    testWidgets('the scan ripple and the turning glyph stop', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await harness.discover(tester);

      // With motion allowed, the scan control drives frames forever.
      await pumpWithMotion(
        tester,
        ScanView(controller: harness.controller),
        reduced: false,
      );
      expect(find.text('Scanning…'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      // With reduce motion on, nothing is driving anything.
      await pumpWithMotion(
        tester,
        ScanView(key: UniqueKey(), controller: harness.controller),
        reduced: true,
      );
      expect(find.text('Scanning…'), findsOneWidget);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'no animation may be running under reduce motion',
      );

      // And it stays still: the glyph is at the same angle a cycle later.
      final glyph = find.descendant(
        of: find.byType(ScanControl),
        matching: find.byType(RotationTransition),
      );
      final before = tester.widget<RotationTransition>(glyph).turns.value;
      await tester.pump(const Duration(milliseconds: 1600));
      final after = tester.widget<RotationTransition>(glyph).turns.value;
      expect(after, before);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('the connected dot stops breathing', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      await harness.discover(tester);
      await harness.connect(tester);

      await pumpWithMotion(tester, _home(harness), reduced: false);
      expect(find.text('Connected'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BreathingDot),
          matching: find.byType(FadeTransition),
        ),
        findsOneWidget,
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await pumpWithMotion(
        tester,
        _home(harness),
        reduced: true,
      );
      // The dot is a plain dot: no opacity animation wrapping it at all.
      expect(
        find.descendant(
          of: find.byType(BreathingDot),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('one-shot animations become instant state changes', () {
    testWidgets('a discovered row does not slide in', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      await harness.discover(tester);

      await pumpWithMotion(
        tester,
        ScanView(controller: harness.controller),
        reduced: true,
      );

      final atOnce = tester.getRect(find.text('EB:6B:5E:4C:33:A3'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.getRect(find.text('EB:6B:5E:4C:33:A3')),
        atOnce,
        reason: 'the row is already where it belongs on the first frame',
      );
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('...where without it, the row really does travel',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      await harness.discover(tester);

      await pumpWithMotion(
        tester,
        ScanView(controller: harness.controller),
        reduced: false,
      );

      final atOnce = tester.getRect(find.text('EB:6B:5E:4C:33:A3'));
      await tester.pump(const Duration(milliseconds: 600));
      final settled = tester.getRect(find.text('EB:6B:5E:4C:33:A3'));
      expect(settled.left, lessThan(atOnce.left));
      expect(atOnce.left - settled.left, greaterThan(1));
    });

    testWidgets('the board does not turn as it is found', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      await harness.discover(tester);

      await pumpWithMotion(
        tester,
        ScanView(controller: harness.controller),
        reduced: true,
      );

      // Full size on the very first frame - no scale-up, no turn.
      final mark = tester.getRect(find.byType(DeviceMark));
      expect(mark.width, DeviceMark.foundWidth);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.getRect(find.byType(DeviceMark)), mark);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('the record button does not scale on press', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      await harness.discover(tester);
      await harness.connect(tester);

      await pumpWithMotion(tester, _home(harness), reduced: true);

      final resting = tester.getRect(find.bySemanticsLabel('Record'));
      final gesture = await tester.startGesture(resting.center);
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.getRect(find.bySemanticsLabel('Record')), resting);
      await gesture.up();
      await flush(tester);
    });

    testWidgets('docking into the header is instant, with no hero flight',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await pumpWithMotion(
        tester,
        AppRoot(controller: harness.controller),
        reduced: true,
      );
      await harness.discover(tester);
      await harness.connect(tester);
      await tester.pump();

      // No transition to sit through: Home is simply there, and the scan
      // screen is simply gone.
      expect(find.byType(HomeView), findsOneWidget);
      expect(find.byType(ScanView), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  testWidgets('nothing is left running after any of it', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    // Motion allowed, so every controller in the app really does start.
    await pumpWithMotion(
      tester,
      AppRoot(controller: harness.controller),
      reduced: false,
    );
    await harness.discover(tester);
    await tester.pump(const Duration(seconds: 2));
    await harness.connect(tester);
    await settleDock(tester);
    await tester.pump(const Duration(seconds: 3));
    await harness.record(tester);
    await settleDock(tester);
    await tester.pump(const Duration(seconds: 3));
    await harness.stop(tester);
    await settleDock(tester);

    // Tear the whole tree down and let time pass. The harness fails the test
    // at teardown if a Timer or a Ticker outlived its widget - the class of
    // bug this project has already been bitten by.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.binding.transientCallbackCount, 0);
  });
}
