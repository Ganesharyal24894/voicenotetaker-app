import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/view/all_notes_view.dart';

import 'harness.dart';

final DateTime _now = DateTime(2026, 9, 10, 18);

List<int> _transcript(String text) => utf8.encode(jsonEncode(Transcript(
      languageCode: 'hi',
      modelId: 'm',
      createdAt: DateTime.utc(2026, 9, 10),
      audioDuration: const Duration(minutes: 4),
      segments: <TranscriptSegment>[
        TranscriptSegment(
          start: Duration.zero,
          end: const Duration(seconds: 8),
          text: text,
        ),
      ],
    ).toJson()));

Future<ViewHarness> _seeded(WidgetTester tester) async {
  final harness = ViewHarness(clock: () => _now);
  addTearDown(harness.dispose);
  final meeting = await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
  harness.fileStore.files[RecordingNaming.transcriptPathOf(meeting)] =
      _transcript('कल की मीटिंग में क्लाइंट ने डेडलाइन बढ़ा दी');
  final hr = await harness.seedRecording(
    at: DateTime(2026, 9, 9, 18, 5),
    length: const Duration(minutes: 7),
  );
  harness.fileStore.files[RecordingNaming.transcriptPathOf(hr)] =
      _transcript('सैलरी पर HR से बात हो गई');
  await harness.seedRecording(
    at: DateTime(2026, 9, 10, 11, 40),
    length: const Duration(minutes: 6),
  );
  await harness.controller.refreshLibrary();
  return harness;
}

Future<void> _pump(
  WidgetTester tester,
  ViewHarness harness, {
  ValueChanged<RecordingInfo>? onOpen,
}) async {
  await pumpScreen(
    tester,
    AllNotesView(
      controller: harness.controller,
      onOpen: (recording, _) => onOpen?.call(recording),
      onBack: () {},
      now: _now,
    ),
  );
  await flush(tester);
}

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('rows quote the transcript, grouped by day, newest first',
      (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);

    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('3 notes'), findsOneWidget);
    // The pinned day headings now carry their count.
    expect(find.text('TODAY · 2 NOTES'), findsOneWidget);
    expect(find.text('YESTERDAY · 1 NOTE'), findsOneWidget);
    expect(find.text('कल की मीटिंग में क्लाइंट ने डेडलाइन बढ़ा दी'),
        findsOneWidget);
    expect(find.text('09:14 · 4 min'), findsOneWidget);
    expect(find.text('Waiting for transcript'), findsNothing);
    // A build without speech-to-text says nothing is coming.
    expect(find.text('No transcript'), findsOneWidget);
    // Newest first.
    expect(
      tester.getTopLeft(find.text('11:40 · 6 min')).dy,
      lessThan(tester.getTopLeft(find.text('09:14 · 4 min')).dy),
    );
    // Delete lives on the note, never on a row.
    expect(find.bySemanticsLabel(RegExp('Delete')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search filters by what was said, after typing settles',
      (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);

    await tester.enterText(find.byType(TextField), 'hr');
    await tester.pump();
    // Not yet: the debounce has not run out.
    expect(find.text('3 notes'), findsOneWidget);
    expect(find.text('09:14 · 4 min'), findsOneWidget);

    await tester.pump(AllNotesView.searchDebounce);
    expect(find.text('सैलरी पर HR से बात हो गई'), findsOneWidget);
    expect(find.text('09:14 · 4 min'), findsNothing);
    expect(find.text('TODAY · 2 NOTES'), findsNothing);

    await tester.enterText(find.byType(TextField), 'मीटिंग');
    await tester.pump(AllNotesView.searchDebounce);
    expect(find.text('09:14 · 4 min'), findsOneWidget);
    expect(find.text('18:05 · 7 min'), findsNothing);
  });

  testWidgets('search by time', (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);

    await tester.enterText(find.byType(TextField), '11:40');
    await tester.pump(AllNotesView.searchDebounce);

    expect(find.text('11:40 · 6 min'), findsOneWidget);
    expect(find.text('09:14 · 4 min'), findsNothing);
  });

  testWidgets('no match says so, plainly', (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(AllNotesView.searchDebounce);

    expect(find.text('No notes match'), findsOneWidget);
  });

  testWidgets('a row opens its note', (tester) async {
    final harness = await _seeded(tester);
    RecordingInfo? opened;
    await _pump(tester, harness, onOpen: (r) => opened = r);

    await tester.tap(find.text('18:05 · 7 min'));
    await tester.pump();

    expect(opened?.recordedAt, DateTime(2026, 9, 9, 18, 5));
  });

  testWidgets('badges: audio deleted, and kept while deleting is on',
      (tester) async {
    final harness = await _seeded(tester);
    final meeting = harness.controller.recordings
        .firstWhere((r) => r.recordedAt.hour == 9)
        .path;
    // The other transcribed note's audio was removed by the sweep.
    final hr = harness.controller.recordings
        .firstWhere((r) => r.recordedAt.hour == 18)
        .path;
    harness.fileStore.files[RecordingNaming.audioRemovedPathOf(hr)] = <int>[];
    harness.fileStore.files.remove(hr);
    await tester.runAsync(() async {
      await harness.controller.setKeepAudio(meeting, true);
      await harness.controller.setAutoDeleteAudio(true);
    });
    await _pump(tester, harness);

    expect(find.text('Audio kept'), findsOneWidget);
    expect(find.text('Audio deleted'), findsOneWidget);
  });

  testWidgets('every row clears the 44px minimum', (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);

    final row = tester.getSize(
      find.ancestor(
        of: find.text('09:14 · 4 min'),
        matching: find.byType(GestureDetector),
      ).first,
    );
    expect(row.height, greaterThanOrEqualTo(44));
  });
}
