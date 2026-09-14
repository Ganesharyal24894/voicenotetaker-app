import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/transcript_store.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/developer_view.dart';
import 'package:voicenotetaker_app/view/home/summarize_sheet.dart';
import 'package:voicenotetaker_app/view/home/summary_scope.dart';
import 'package:voicenotetaker_app/view/diagnostics_view.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/all_notes_view.dart';
import 'package:voicenotetaker_app/view/note_view.dart';
import 'package:voicenotetaker_app/view/recording_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';
import 'package:voicenotetaker_app/view/widgets/app_icons.dart';

import 'harness.dart';
import 'home_harness.dart';

void main() {
  setUpAll(registerViewFallbacks);

  /// Pumps past a pushed route's transition AND the frame that removes it.
  ///
  /// `pumpAndSettle` is not an option on these screens - the breathing dot on
  /// Home animates forever by design - so the transition is pumped by hand. It
  /// takes several frames rather than one: the navigator starts the animation on
  /// the frame after the pop, the platform's own page transition decides how long
  /// it runs, and the route only leaves the tree on the rebuild after that
  /// finishes.
  Future<void> settleRoute(WidgetTester tester) async {
    await flush(tester);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    // And once more afterwards, because a disposed route's teardown is a chain
    // of awaits - cancelling a stream subscription needs the real event loop,
    // not the tester's clock.
    await flush(tester);
  }

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

  testWidgets('Home opens Settings, Settings opens Diagnostics, and Diagnostics '
      'opens Developer options', (tester) async {
    // THE ROUTE ORDER IS THE OBSERVE/MUTATE SPLIT. Home's header icon goes to
    // Recorder settings, and Diagnostics - the screen anybody may look at - is
    // a row there; the developer screen is one tap further in, behind the
    // debug gate.
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);

    await tester.tap(find.bySemanticsLabel('Settings'));
    await settleRoute(tester);
    expect(find.byType(SettingsView), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Diagnostics'));
    await settleRoute(tester);

    expect(find.byType(DiagnosticsView), findsOneWidget);
    // Opening it is what starts the live readings - nothing else in the app
    // renders them, so nothing else subscribes.
    expect(harness.controller.diagnosticsOpen, isTrue);
    verify(() => harness.transport.subscribeFrames(knownDevice.id)).called(1);

    await tester.tap(find.text('Developer options'));
    await settleRoute(tester);
    expect(find.byType(DeveloperView), findsOneWidget);

    // Back out of both, and the subscriptions go with the diagnostics route.
    // Each Back is addressed to its own screen: both routes are mounted, so a
    // bare `find.bySemanticsLabel('Back')` would be ambiguous.
    await tester.tap(
      find.descendant(
        of: find.byType(DeveloperView),
        matching: find.bySemanticsLabel('Back'),
      ),
    );
    await settleRoute(tester);
    expect(find.byType(DeveloperView), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(DiagnosticsView),
        matching: find.bySemanticsLabel('Back'),
      ),
    );
    await settleRoute(tester);

    expect(find.byType(DiagnosticsView), findsNothing);
    expect(find.byType(SettingsView), findsOneWidget);
    expect(harness.controller.diagnosticsOpen, isFalse);
    verify(() => harness.transport.unsubscribeFrames(knownDevice.id)).called(1);
  });

  testWidgets('Home opens all notes, and a note opens on its transcript',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Notes tab'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('All notes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AllNotesView), findsOneWidget);
    expect(find.text('1 note'), findsOneWidget);

    await tester.tap(find.text('09:14 · 4 min'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(NoteView), findsOneWidget);
    expect(find.text('Summarize with your AI'), findsOneWidget);
  });

  testWidgets('Summarize with your AI on a note opens the single-note sheet',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    final path = await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    // The button needs a transcript to summarize.
    await tester.runAsync(
      () => TranscriptStore(fileStore: harness.fileStore).save(
        path,
        Transcript(
          languageCode: 'hi',
          modelId: SpeechModels.indicConformerHindiInt8.id,
          createdAt: DateTime.utc(2026, 9, 10),
          audioDuration: const Duration(minutes: 4),
          segments: const <TranscriptSegment>[
            TranscriptSegment(
              start: Duration.zero,
              end: Duration(seconds: 5),
              text: 'ठीक है',
            ),
          ],
        ),
      ),
    );
    await harness.controller.refreshLibrary();
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Notes tab'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('All notes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('09:14 · 4 min'));
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(NoteView), findsOneWidget);
    expect(find.byType(NoteSummarizeSheet), findsNothing);

    await tester.tap(find.text('Summarize with your AI'));
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(NoteSummarizeSheet), findsOneWidget);
    expect(find.text(NoteSummarizeSheet.title), findsOneWidget);
  });

  testWidgets('deleting a note from its menu updates the list immediately',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    await harness.seedRecording(
      at: DateTime(2026, 9, 10, 11, 30),
      length: const Duration(minutes: 2),
    );
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Notes tab'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('All notes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('2 notes'), findsOneWidget);
    // No delete control on a row: deleting lives on the note.
    expect(find.bySemanticsLabel(RegExp('Delete')), findsNothing);

    await tester.tap(find.text('09:14 · 4 min'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Delete note'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Delete'));
    await flush(tester);
    await settleRoute(tester);

    // Back on the list, which listens to the controller itself: the row is
    // gone without navigating away and back.
    expect(find.byType(NoteView), findsNothing);
    expect(find.byType(AllNotesView), findsOneWidget);
    expect(find.text('09:14 · 4 min'), findsNothing);
    expect(find.text('11:30 · 2 min'), findsOneWidget);
    expect(find.text('1 note'), findsOneWidget);

    expect(harness.controller.recordings, hasLength(1));
    expect(harness.fileStore.files.keys, hasLength(1));
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
    // Three of four bars, and no figure: 64% is in the mushy middle of the
    // discharge curve, which is exactly what the buckets exist for.
    expect(tester.widget<BatteryIcon>(find.byType(BatteryIcon)).bars, 3);
    expect(find.text('64%'), findsNothing);

    await tester.tap(recorderStatusLine());
    await settleDock(tester);
    await tester.tap(find.bySemanticsLabel('Disconnect'));
    await flush(tester);
    await settleDock(tester);

    // No stuck "connected" UI: with no notes to read, the app is back where
    // it pairs from.
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
    expect(tester.widget<BatteryIcon>(find.byType(BatteryIcon)).bars, 4);
    expect(find.text('Connected'), findsOneWidget);

    await harness.notifyBattery(tester, percent: 81, charging: true);
    await tester.pump();

    // The notification lands in the glyph, and the charging state with it.
    final icon = tester.widget<BatteryIcon>(find.byType(BatteryIcon));
    expect(icon.bars, 4);
    expect(icon.charging, isTrue);
    expect(find.text('Charging'), findsOneWidget);
  });

  group('Home without a recorder', () {
    testWidgets('someone with notes lands on Home, not the scan screen',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));

      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await settleDock(tester);

      expect(find.byType(HomeView), findsOneWidget);
      expect(find.byType(ScanView), findsNothing);
      expect(find.text('Not connected'), findsOneWidget);
    });

    testWidgets('a link that dropped by itself still gets its own screen',
        (tester) async {
      final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await harness.discover(tester);
      await harness.connect(tester);
      await settleDock(tester);

      await harness.dropLink(tester);
      await settleDock(tester);

      expect(find.byType(HomeView), findsNothing);
      expect(find.text('Recorder disconnected'), findsOneWidget);
    });

    testWidgets('Connect a recorder opens pairing over Home, and Back returns',
        (tester) async {
      final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await settleDock(tester);

      await tester.tap(recorderStatusLine());
      await settleDock(tester);
      await tester.tap(find.bySemanticsLabel('Connect a recorder'));
      await settleDock(tester);
      expect(find.byType(ScanView), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Back'));
      await settleDock(tester);
      expect(find.byType(ScanView), findsNothing);
      expect(find.byType(HomeView), findsOneWidget);

      // Pairing again and connecting lands on Home, connected.
      await tester.tap(recorderStatusLine());
      await settleDock(tester);
      await tester.tap(find.bySemanticsLabel('Connect a recorder'));
      await settleDock(tester);
      await harness.discover(tester);
      await harness.connect(tester);
      await settleDock(tester);
      expect(find.byType(ScanView), findsNothing);
      expect(find.text('Connected'), findsOneWidget);
    });
  });

  testWidgets('screens under AppRoot reach the summaries through the scope',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);

    expect(SummaryScope.maybeOf(tester.element(find.byType(HomeView))), isNotNull);
  });
}
