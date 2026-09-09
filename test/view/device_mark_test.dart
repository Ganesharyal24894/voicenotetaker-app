import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/app_icons.dart';
import 'package:voicenotetaker_app/view/widgets/device_mark.dart';

import 'harness.dart';

Widget _home(ViewHarness harness) => HomeView(
      controller: harness.controller,
      recents: const [],
      onOpenLibrary: () {},
      onOpenRecording: (_) {},
    );

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('the header has a 38x46 logo slot before the device name',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    expect(find.byType(DeviceMark), findsOneWidget);
    final slot = tester.getRect(find.byType(DeviceMark));
    expect(slot.width, DeviceMark.slotWidth);
    expect(slot.height, DeviceMark.slotHeight);
    expect(slot.width, 38);
    expect(slot.height, 46);

    // The slot leads, on the screen gutter...
    expect(slot.left, moreOrLessEquals(AppShape.gutter, epsilon: 0.5));

    // ...and the name/status block sits 12px to its right, shifted by the
    // full width of the slot plus the gap.
    final name = tester.getRect(find.text('voiceNotetaker'));
    expect(name.left, greaterThan(slot.right));
    expect(name.left - slot.right, moreOrLessEquals(12, epsilon: 0.5));
    expect(
      name.left - AppShape.gutter,
      moreOrLessEquals(DeviceMark.slotWidth + 12, epsilon: 0.5),
    );

    // The battery is still right-aligned: it did not move to make room.
    final battery = tester.getRect(find.byType(BatteryIcon));
    final screen = tester.getSize(find.byType(HomeView));
    expect(battery.left, greaterThan(screen.width * 0.6));
    expect(battery.right, lessThan(screen.width - AppShape.gutter));
  });

  testWidgets('disconnected dims the logo without moving anything',
      (tester) async {
    // Connected first, to record where the header sits.
    final connectedHarness =
        ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(connectedHarness.dispose);
    await connectedHarness.discover(tester);
    await connectedHarness.connect(tester);
    await pumpScreen(tester, _home(connectedHarness));

    expect(find.text('Connected'), findsOneWidget);
    final connectedSlot = tester.getRect(find.byType(DeviceMark));
    final connectedName = tester.getRect(find.text('voiceNotetaker'));
    expect(
      tester.widget<DeviceMark>(find.byType(DeviceMark)).dimmed,
      isFalse,
    );

    // A separate harness, so this is a fresh State rather than a rebuild.
    final offlineHarness = ViewHarness();
    addTearDown(offlineHarness.dispose);
    await pumpScreen(tester, _home(offlineHarness));

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.byType(DeviceMark), findsOneWidget);

    final mark = tester.widget<DeviceMark>(find.byType(DeviceMark));
    expect(mark.dimmed, isTrue, reason: 'the disconnected treatment');
    expect(
      tester
          .widgetList<Opacity>(
            find.descendant(
              of: find.byType(DeviceMark),
              matching: find.byType(Opacity),
            ),
          )
          .map((o) => o.opacity),
      contains(DeviceMark.dimmedOpacity),
    );

    // ...and nothing moved.
    expect(tester.getRect(find.byType(DeviceMark)), connectedSlot);
    expect(tester.getRect(find.text('voiceNotetaker')), connectedName);
  });

  testWidgets('the slot is the Hero the scan screen docks into',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    final hero = tester.widget<Hero>(
      find.ancestor(of: find.byType(DeviceMark), matching: find.byType(Hero)),
    );
    expect(hero.tag, ScanView.deviceMarkHeroTag);
  });

  testWidgets('the scan screen shows the same mark on the recorder card',
      (tester) async {
    final harness = ViewHarness(
      devices: const <DiscoveredDevice>[knownDevice, unknownDevice],
    );
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));
    await tester.pump(const Duration(seconds: 3));

    // One mark, on the recorder - not on the anonymous radio beside it.
    expect(find.byType(DeviceMark), findsOneWidget);
    final hero = tester.widget<Hero>(
      find.ancestor(of: find.byType(DeviceMark), matching: find.byType(Hero)),
    );
    expect(hero.tag, ScanView.deviceMarkHeroTag);
  });

  testWidgets('connecting flies the mark into the header slot and shrinks it',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    // Frame by frame, so the found entrance actually plays out - a single
    // long pump would just set the ticker's start time.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    final origin = tester.getRect(find.byType(DeviceMark));
    expect(origin.width, moreOrLessEquals(DeviceMark.foundWidth, epsilon: 0.1));

    await harness.connect(tester);

    // Sample the flight. Nothing here hardcodes the mock's -171/-83: the
    // framework computes the path from where the two slots actually are.
    final path = <Rect>[];
    for (var i = 0; i < 8; i++) {
      path.add(tester.getRect(find.byType(DeviceMark).first));
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(path.toSet().length, greaterThan(3), reason: 'it is in flight');
    expect(path.first.width, moreOrLessEquals(origin.width, epsilon: 0.1));
    expect(path.last.width, lessThan(origin.width));

    // It shrinks on the way, and it does not simply cut to the destination.
    final shrinking = path.map((r) => r.width).toList();
    for (var i = 1; i < shrinking.length; i++) {
      expect(shrinking[i], lessThanOrEqualTo(shrinking[i - 1] + 0.01));
    }

    await settleDock(tester);
    final landed = tester.getRect(find.byType(DeviceMark));
    expect(landed.width, DeviceMark.slotWidth);
    expect(landed.height, DeviceMark.slotHeight);
    expect(landed.top, lessThan(origin.top));
  });

  test('the mark keeps the symbol aspect ratio at any width', () {
    expect(const DeviceMark().height, DeviceMark.slotHeight);
    expect(
      const DeviceMark(width: 76).height,
      moreOrLessEquals(DeviceMark.slotHeight * 2, epsilon: 0.001),
    );
  });
}
