import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/placeholder_data.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';

import 'harness.dart';

Widget _home(
  ViewHarness harness, {
  VoidCallback? onOpenDeveloper,
  VoidCallback? onOpenLibrary,
  ValueChanged<RecordingEntry>? onOpenRecording,
}) =>
    HomeView(
      controller: harness.controller,
      recents: PlaceholderData.library(),
      onOpenLibrary: onOpenLibrary ?? () {},
      onOpenRecording: onOpenRecording ?? (_) {},
      onOpenDeveloper: onOpenDeveloper,
    );

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('builds connected: device, state pill, record button, recents',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    expect(find.text('voiceNotetaker'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Tap to record'), findsOneWidget);
    expect(find.text('RECENT'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Standup notes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds disconnected without throwing', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await pumpScreen(tester, _home(harness));

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connect a recorder to start'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('battery reads as unknown - there is no battery service yet',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    expect(PlaceholderData.batteryLevel, isNull);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('the record button starts a capture', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    await tester.tap(find.bySemanticsLabel('Record'));
    await flush(tester);

    expect(harness.controller.phase, AppPhase.recording);
    verify(() => harness.transport.subscribeFrames(knownDevice.id)).called(1);
  });

  testWidgets('the record button is at least 44px across', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    final size = tester.getSize(find.bySemanticsLabel('Record'));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('"All" opens the library', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    var opened = false;

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness, onOpenLibrary: () => opened = true));

    await tester.tap(find.text('All'));
    await tester.pump();

    expect(opened, isTrue);
  });

  testWidgets('a recent row opens playback for that recording',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    RecordingEntry? opened;

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(
      tester,
      _home(harness, onOpenRecording: (entry) => opened = entry),
    );

    await tester.tap(find.text('Standup notes'));
    await tester.pump();

    expect(opened?.title, 'Standup notes');
  });

  // Two separate tests rather than two pumps in one: pumping a second screen
  // into the same position reuses the State of the first, which hides bugs.
  testWidgets('the developer entry point is absent when it is not supplied',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    expect(find.bySemanticsLabel('Developer'), findsNothing);
  });

  testWidgets('the developer entry point is present when it is supplied',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    var opened = false;

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(
      tester,
      _home(harness, onOpenDeveloper: () => opened = true),
    );

    expect(find.bySemanticsLabel('Developer'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Developer'));
    await tester.pump();
    expect(opened, isTrue);
  });
}
