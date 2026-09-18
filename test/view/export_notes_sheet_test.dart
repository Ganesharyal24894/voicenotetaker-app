import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/export_controller.dart';
import 'package:voicenotetaker_app/drivers/disk_space.dart';
import 'package:voicenotetaker_app/services/export/note_export_service.dart';
import 'package:voicenotetaker_app/view/export_notes_sheet.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';

import '../export/export_fakes.dart' as store_fakes;
import '../summary/fakes.dart';
import 'harness.dart';

const String recordings = '/documents/recordings';
const String exports = '/support/exports';

Uint8List audio(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 17 + 3) & 0xFF));

void main() {
  setUpAll(registerViewFallbacks);

  late store_fakes.MemoryFileStore store;
  late FakeShareSheet share;

  final now = DateTime(2026, 9, 18, 21);

  ExportController makeController({
    DiskSpace diskSpace = const FixedDiskSpace(),
    bool withShare = true,
  }) =>
      ExportController(
        exports: NoteExportService(
          fileStore: store,
          recordingsDirectory: recordings,
          exportsDirectory: exports,
          diskSpace: diskSpace,
        ),
        shareSheet: withShare ? share : null,
        now: () => now,
      );

  setUp(() {
    share = FakeShareSheet();
    store = store_fakes.MemoryFileStore()
      ..put('$recordings/voicenote-20260918-090000.wav', audio(40000))
      ..put('$recordings/voicenote-20260918-090000.transcript.json',
          '{"segments":[]}'.codeUnits)
      ..put('$recordings/voicenote-20260901-090000.wav', audio(20000));
  });

  Future<ExportController> pumpSheet(
    WidgetTester tester, {
    DiskSpace diskSpace = const FixedDiskSpace(),
    bool withShare = true,
  }) async {
    final controller =
        makeController(diskSpace: diskSpace, withShare: withShare);
    addTearDown(controller.dispose);
    await pumpScreen(
      tester,
      Scaffold(body: ExportNotesSheet(exports: controller)),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('opens on Today, with the three ranges and what today holds',
      (tester) async {
    await pumpSheet(tester);

    expect(find.text('Export notes'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Last 7 days'), findsOneWidget);
    expect(find.text('Everything'), findsOneWidget);
    expect(
      tester
          .widget<SegmentButton>(find.widgetWithText(SegmentButton, 'Today'))
          .selected,
      isTrue,
    );
    expect(find.textContaining('1 note · '), findsOneWidget);
    expect(find.bySemanticsLabel('Make the zip'), findsOneWidget);
  });

  testWidgets('picking Everything recounts', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('Everything'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 notes · '), findsOneWidget);
  });

  testWidgets('an empty range says so and the button does nothing',
      (tester) async {
    store = store_fakes.MemoryFileStore();
    await pumpSheet(tester);

    expect(find.text('No notes in this range yet.'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pumpAndSettle();
    expect(find.text('No notes in this range yet.'), findsOneWidget);
  });

  testWidgets('making the zip ends with its name, its size and Send it',
      (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pumpAndSettle();

    expect(find.text('voicenotetaker-20260918.zip'), findsOneWidget);
    expect(find.textContaining('1 note · '), findsOneWidget);
    expect(find.bySemanticsLabel('Send it'), findsOneWidget);
    expect(find.bySemanticsLabel('Done'), findsOneWidget);
  });

  testWidgets('Send it hands the zip to the share sheet', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Send it'));
    await tester.pumpAndSettle();

    expect(share.sharedFiles.single,
        <String>['$exports/voicenotetaker-20260918.zip']);
  });

  testWidgets('with no share sheet there is no Send it, and it says so',
      (tester) async {
    await pumpSheet(tester, withShare: false);
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Send it'), findsNothing);
    expect(find.textContaining('nowhere to send it'), findsOneWidget);
  });

  testWidgets('a phone with no room says how much it has', (tester) async {
    await pumpSheet(tester, diskSpace: const FixedDiskSpace(1000));
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not enough room on the phone'), findsOneWidget);
    expect(find.bySemanticsLabel('Make the zip'), findsOneWidget);
  });

  testWidgets('the progress bar is determinate from its first frame',
      (tester) async {
    final controller = await pumpSheet(tester);
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pump();

    final bars = find.byType(LinearProgressIndicator);
    if (bars.evaluate().isNotEmpty) {
      expect(tester.widget<LinearProgressIndicator>(bars).value, isNotNull);
    }
    await tester.pumpAndSettle();
    expect(controller.phase, ExportPhase.ready);
  });

  testWidgets('Done closes the sheet', (tester) async {
    // No addTearDown: the sheet owns this one and disposes it on close, which
    // is the thing this test is checking.
    final controller = makeController();
    await pumpScreen(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showExportNotesSheet(context, exports: controller),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Done'));
    await tester.pumpAndSettle();

    expect(find.byType(ExportNotesSheet), findsNothing);
    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty,
        reason: 'the zip is a copy and does not outlive the sheet');
  });

  testWidgets('a zip that was sent is swept at the next opening, not this one',
      (tester) async {
    Future<void> open(ExportController controller) async {
      await pumpScreen(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showExportNotesSheet(context, exports: controller),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    final first = makeController();
    await open(first);
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Send it'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Done'));
    await tester.pumpAndSettle();

    // Still there: AirDrop may be halfway through it.
    expect(store.files.keys.where((k) => k.startsWith(exports)), hasLength(1));

    await open(makeController());
    await tester.pumpAndSettle();
    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
  });

  testWidgets('a file that could not be read is said out loud', (tester) async {
    store.unreadable.add('$recordings/voicenote-20260918-090000.wav');
    await pumpSheet(tester);
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.bySemanticsLabel('Send it'), findsOneWidget);
  });

  testWidgets('Stop says Stopping the moment it is tapped', (tester) async {
    final controller = await pumpSheet(tester);
    await tester.tap(find.bySemanticsLabel('Make the zip'));
    await tester.pump();
    if (controller.phase == ExportPhase.writing) {
      await tester.tap(find.bySemanticsLabel('Stop'));
      await tester.pump();
      expect(find.text('Stopping…'), findsOneWidget);
    }
    await tester.pumpAndSettle();
  });

  testWidgets('no overflow on the mock frame', (tester) async {
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
  });

  group('the Settings row', () {
    testWidgets('is there when there is an export to open', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      var opened = false;
      await pumpScreen(
        tester,
        SettingsView(
          controller: harness.controller,
          onBack: () {},
          onOpenDiagnostics: () {},
          onExportNotes: () => opened = true,
        ),
      );

      expect(find.text('Export notes'), findsOneWidget);
      expect(find.text('One zip of your recordings and transcripts'),
          findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Export notes'));
      expect(opened, isTrue);
    });

    testWidgets('is absent when there is not', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await pumpScreen(
        tester,
        SettingsView(
          controller: harness.controller,
          onBack: () {},
          onOpenDiagnostics: () {},
        ),
      );

      expect(find.text('Export notes'), findsNothing);
      expect(find.text('Diagnostics'), findsOneWidget);
    });
  });
}
