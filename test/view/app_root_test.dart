import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/library_view.dart';
import 'package:voicenotetaker_app/view/playback_view.dart';
import 'package:voicenotetaker_app/view/recording_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';

import 'harness.dart';

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('the device state chooses the screen', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    expect(find.byType(ScanView), findsOneWidget);

    // Home replaces the scan screen through a real route transition - that is
    // what gives the docking Hero something to fly between - so each state
    // change is pumped past its transition before the stack is asserted on.
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    expect(find.byType(HomeView), findsOneWidget);
    expect(find.byType(ScanView), findsNothing);

    await harness.record(tester);
    await settleDock(tester);
    expect(find.byType(RecordingView), findsOneWidget);
    expect(find.byType(HomeView), findsNothing);

    await harness.stop(tester);
    await settleDock(tester);
    expect(find.byType(HomeView), findsOneWidget);
  });

  testWidgets('Home opens the library, and the library opens playback',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    // A real saved recording, listed by the library service - the screens are
    // no longer fed placeholder rows.
    await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    await tester.pump();

    await tester.tap(find.text('All'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LibraryView), findsOneWidget);

    await tester.tap(find.text('Voice note 09:14'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PlaybackView), findsOneWidget);
  });

  testWidgets('the library\'s New recording button starts a capture',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);

    await tester.tap(find.text('All'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('New recording'));
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(harness.controller.isRecording, isTrue);
    expect(find.byType(RecordingView), findsOneWidget);
  });

  testWidgets('deleting from the library updates the list immediately',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    await harness.seedRecording(at: DateTime(2026, 9, 10, 11, 30));
    await tester.pump();

    await tester.tap(find.text('All'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('2 items'), findsOneWidget);
    expect(find.text('Voice note 09:14'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Delete Voice note 09:14'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await flush(tester);
    await tester.pumpAndSettle();

    // The pushed library route is NOT rebuilt by AppRoot's setState, so this
    // is the assertion that the route listens to the controller itself. The
    // row must be gone without navigating away and back.
    expect(find.byType(LibraryView), findsOneWidget);
    expect(find.text('Voice note 09:14'), findsNothing);
    expect(find.text('Voice note 11:30'), findsOneWidget);
    expect(find.text('1 item'), findsOneWidget);

    // The file and the library entry both went: no orphan behind the list.
    expect(harness.controller.recordings, hasLength(1));
    expect(harness.fileStore.files.keys, hasLength(1));
  });

  testWidgets('deleting the only recording empties the library',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    await tester.pump();

    await tester.tap(find.text('All'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.bySemanticsLabel('Delete Voice note 09:14'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await flush(tester);
    await tester.pumpAndSettle();

    expect(find.text('No recordings yet.'), findsOneWidget);
    expect(find.text('0 items'), findsOneWidget);
  });

  testWidgets('disconnecting from Home returns to the scan screen',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    when(() => harness.transport.readBattery(any())).thenAnswer(
      (_) async => const BatteryStatus(percent: 64, charging: true),
    );

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    expect(find.byType(HomeView), findsOneWidget);
    expect(find.text('64%'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Disconnect'));
    await flush(tester);
    await settleDock(tester);

    // No stuck "connected" UI: the app is back where it pairs from.
    expect(find.byType(ScanView), findsOneWidget);
    expect(find.byType(HomeView), findsNothing);
    expect(harness.controller.connectedDevice, isNull);
    expect(harness.controller.batteryAvailable, isFalse);
    verify(() => harness.transport.disconnect(knownDevice.id)).called(1);
  });

  testWidgets('the battery readout on Home follows fe05 notifications',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    when(() => harness.transport.readBattery(any())).thenAnswer(
      (_) async => const BatteryStatus(percent: 80, charging: false),
    );

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);

    await harness.notifyBattery(tester, percent: 81, charging: true);
    await tester.pump();

    expect(find.text('81%'), findsOneWidget);
    expect(find.text('Charging'), findsOneWidget);
  });
}
