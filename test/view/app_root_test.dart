import 'package:flutter_test/flutter_test.dart';
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
}
