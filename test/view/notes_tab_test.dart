import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/notes_overview.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/view/home/notes_tab.dart';

import 'harness.dart';

final DateTime _now = DateTime(2026, 9, 15, 18, 55);

RecordingInfo _rec(int hour, int minute, {int minutes = 6, int day = 15}) => RecordingInfo(
      path: '/r/$day-$hour-$minute.wav',
      name: 'n',
      recordedAt: DateTime(2026, 9, day, hour, minute),
      sizeBytes: 1,
      duration: Duration(minutes: minutes),
    );

void main() {
  RecordingInfo? opened;
  var library = 0;

  Future<void> pump(WidgetTester tester, NotesOverview overview) async {
    opened = null;
    library = 0;
    await pumpScreen(
      tester,
      Scaffold(
        body: NotesTab(
          overview: overview,
          now: _now,
          onOpenRecording: (r) => opened = r,
          onOpenLibrary: () => library++,
        ),
      ),
    );
  }

  testWidgets('nothing needs you: no section, just today', (tester) async {
    await pump(
      tester,
      NotesOverview.derive(recordings: <RecordingInfo>[_rec(17, 15)], now: _now, statusOf: (_) => TranscriptStatus.done),
    );
    expect(find.text('NEEDS YOU'), findsNothing);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('6 min'), findsNWidgets(2), reason: 'the strip and the row');
    expect(find.text('of speech'), findsOneWidget);
    expect(find.text('note'), findsOneWidget);
    expect(find.text('conversations'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows say where each note stands', (tester) async {
    final writing = _rec(18, 52, minutes: 2);
    final running = _rec(18, 40, minutes: 11);
    final queued = _rec(17, 15);
    final failed = _rec(14, 22, minutes: 3);
    final plain = _rec(12, 40, minutes: 9);
    await pump(
      tester,
      NotesOverview.derive(
        recordings: <RecordingInfo>[writing, running, queued, failed, plain],
        now: _now,
        writingPath: writing.path,
        transcribingPath: running.path,
        transcriptionDone: 2,
        transcriptionTotal: 5,
        statusOf: (r) => switch (r) {
          _ when r == queued => TranscriptStatus.queued,
          _ when r == failed => TranscriptStatus.failed,
          _ => TranscriptStatus.done,
        },
      ),
    );
    expect(find.text('18:52'), findsOneWidget);
    expect(find.text('2 min so far'), findsOneWidget);
    expect(find.text('Writing…'), findsOneWidget);
    expect(find.text('Transcribing 40%'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text("Couldn't transcribe"), findsOneWidget);
    expect(find.text('2 h 05 min'), findsNothing);
    expect(find.text('31 min'), findsOneWidget, reason: '2 + 11 + 6 + 3 + 9');

    await tester.tap(find.text('12:40'));
    expect(opened, plain);
  });

  testWidgets('needs you: audio deleting soon and a failed note, with their actions', (tester) async {
    final soon = _rec(20, 10, day: 14);
    final failed = _rec(14, 22, minutes: 3);
    await pump(
      tester,
      NotesOverview.derive(
        recordings: <RecordingInfo>[soon, failed],
        now: _now,
        autoDeleteAudio: true,
        statusOf: (r) => r == failed ? TranscriptStatus.failed : TranscriptStatus.done,
      ),
    );
    expect(find.text('NEEDS YOU'), findsOneWidget);
    expect(find.text('1 note loses its audio soon'), findsOneWidget);
    expect(find.text('At 20:10 · transcripts stay'), findsOneWidget);
    expect(find.text("1 note couldn't be transcribed"), findsOneWidget);
    expect(find.text('14:22 · 3 min'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Review'));
    expect(library, 1);
    await tester.tap(find.bySemanticsLabel('Open'));
    expect(opened, failed);
  });

  testWidgets('several failed notes point at the library, with the day when not today', (tester) async {
    final a = _rec(9, 0, day: 13);
    final b = _rec(8, 0, day: 12);
    await pump(
      tester,
      NotesOverview.derive(recordings: <RecordingInfo>[a, b], now: _now, statusOf: (_) => TranscriptStatus.unsupported),
    );
    expect(find.text("2 notes couldn't be transcribed"), findsOneWidget);
    expect(find.text('Latest Sun 09:00 · 6 min'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Review'));
    expect(library, 1);
    expect(find.text('No notes yet today. They show up here as you talk.'), findsOneWidget);
  });

  testWidgets('conversations show only when they differ from notes', (tester) async {
    final a = _rec(9, 0);
    final b = _rec(10, 0);
    await pump(
      tester,
      NotesOverview.derive(
        recordings: <RecordingInfo>[a, b],
        now: _now,
        statusOf: (_) => TranscriptStatus.done,
        isAutomatic: (r) => r == a,
      ),
    );
    expect(find.text('conversations'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
  });
}
