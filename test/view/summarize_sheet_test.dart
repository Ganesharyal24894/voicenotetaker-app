import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/summary_controller.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/summary/summary_range.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/view/home/summarize_sheet.dart';
import 'package:voicenotetaker_app/view/home/summary_scope.dart';

import '../summary/fakes.dart';
import 'harness.dart';

final DateTime _now = DateTime(2026, 9, 15, 18, 30);

void main() {
  late FakeClipboard clipboard;
  late FakeShareSheet share;
  late Map<String, Transcript?> transcripts;
  late SummaryController summaries;

  setUp(() {
    clipboard = FakeClipboard();
    share = FakeShareSheet();
    transcripts = <String, Transcript?>{};
    summaries = SummaryController(
      loadTranscript: (r) async => transcripts[r.path],
      clipboard: clipboard,
      shareSheet: share,
      clock: () => _now,
    );
  });

  Future<void> open(WidgetTester tester, List<RecordingInfo> recordings) async {
    await pumpScreen(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSummarizeSheet(context, summaries: summaries, recordings: recordings),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  RecordingInfo note(DateTime at, String words, {int minutes = 12}) {
    final r = recordingAt(at, minutes: minutes);
    transcripts[r.path] = transcriptOf(words);
    return r;
  }

  testWidgets('pick a range: the count line follows it', (tester) async {
    final recordings = <RecordingInfo>[
      note(DateTime(2026, 9, 15, 9, 14), 'एक दो तीन'),
      note(DateTime(2026, 9, 15, 10, 21), 'चार', minutes: 68),
      note(DateTime(2026, 9, 14, 9, 0), 'पाँच छह'),
      recordingAt(DateTime(2026, 9, 15, 11, 0), hasTranscript: false),
    ];
    await open(tester, recordings);

    expect(find.text(SummarizeRangeSheet.title), findsOneWidget);
    expect(find.text(SummarizeRangeSheet.subtitle), findsOneWidget);
    expect(find.text('2 notes · 1 h 20 min · 4 words'), findsOneWidget);
    expect(find.text("1 note isn't transcribed yet, so it's left out."), findsOneWidget);
    expect(find.text(SummarizeRangeSheet.longWarning), findsNothing);

    await tester.tap(find.bySemanticsLabel('Yesterday'));
    await flush(tester);
    expect(find.text('1 note · 12 min · 2 words'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('30 days'));
    await flush(tester);
    expect(find.text('3 notes · 1 h 32 min · 6 words'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no transcribed notes: says so, and Copy is off', (tester) async {
    await open(tester, const <RecordingInfo>[]);
    expect(find.text('No transcribed notes in this range yet.'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Copy prompt'));
    await flush(tester);
    expect(clipboard.text, isNull);
  });

  testWidgets('Copy prompt copies, then shows Copied with the prompt; Done closes', (tester) async {
    await open(tester, <RecordingInfo>[note(DateTime(2026, 9, 15, 9, 14), 'एक दो तीन')]);

    await tester.tap(find.bySemanticsLabel('Copy prompt'));
    await flush(tester);

    expect(clipboard.text, startsWith('You are my productivity assistant.'));
    expect(clipboard.text, contains('[09:14 · 12 min]\nएक दो तीन'));
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text(CopiedView.nextStep), findsOneWidget);
    expect(find.text('Today · 1 note · 3 words'), findsOneWidget);
    expect(find.text(clipboard.text!), findsOneWidget);

    // A reply pasted now is about the range just copied.
    await summaries.acceptReply('## Ideas\n- x');
    expect(summaries.latest!.range, SummaryRange.today);

    await tester.tap(find.bySemanticsLabel('Done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('Share opens the share sheet with the prompt', (tester) async {
    await open(tester, <RecordingInfo>[note(DateTime(2026, 9, 15, 9, 14), 'एक')]);
    await tester.tap(find.bySemanticsLabel('Share'));
    await flush(tester);
    expect(share.shared.single, contains('--- Notes ---'));
  });

  testWidgets('a long prompt offers to split, and copies part by part', (tester) async {
    final recordings = <RecordingInfo>[
      for (var i = 0; i < 10; i++)
        note(DateTime(2026, 9, 15, 8 + i, 0), List<String>.filled(900, 'शब्द').join(' ')),
    ];
    await open(tester, recordings);

    expect(find.text('10 notes · 2 h 00 min · about 9,000 words'), findsOneWidget);
    expect(find.text('Split into 2 parts'), findsOneWidget);
    expect(find.text(SummarizeRangeSheet.longWarning), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Copy prompt'));
    await flush(tester);

    expect(clipboard.text, startsWith('Part 1 of 2.'));
    expect(find.text('Part 1 of 2 copied'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Copy part 2'));
    await flush(tester);
    expect(clipboard.text, startsWith('Part 2 of 2 (the last part).'));
    expect(find.text('Part 2 of 2 copied'), findsOneWidget);
    expect(find.bySemanticsLabel('Done'), findsOneWidget);
  });

  testWidgets('left unsplit, a long prompt copies whole', (tester) async {
    final recordings = <RecordingInfo>[
      for (var i = 0; i < 10; i++)
        note(DateTime(2026, 9, 15, 8 + i, 0), List<String>.filled(900, 'शब्द').join(' ')),
    ];
    await open(tester, recordings);
    await tester.tap(find.bySemanticsLabel('Copy prompt'));
    await flush(tester);
    expect(clipboard.text, startsWith('You are my productivity assistant.'));
    expect(find.text('Copied'), findsOneWidget);
  });

  group('showNoteSummarizeSheet', () {
    Future<void> openNote(WidgetTester tester, RecordingInfo recording, {bool scoped = true}) async {
      final button = Builder(
        builder: (context) => TextButton(
          onPressed: () => showNoteSummarizeSheet(context, recording),
          child: const Text('open'),
        ),
      );
      await pumpScreen(
        tester,
        Scaffold(body: scoped ? SummaryScope(summaries: summaries, child: button) : button),
      );
      await tester.tap(find.text('open'));
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('previews the prompt and copies it', (tester) async {
      final recording = note(DateTime(2026, 9, 15, 9, 14), 'एक दो तीन');
      await openNote(tester, recording);

      expect(find.text(NoteSummarizeSheet.title), findsOneWidget);
      expect(find.text('This note · 12 min · 3 words'), findsOneWidget);
      expect(find.textContaining('Below is the transcript of one recorded conversation'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Copy prompt'));
      await flush(tester);
      expect(clipboard.text, contains('--- Transcript ---\n[00:00] एक दो तीन'));
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('a note with no transcript says so, and Copy is off', (tester) async {
      await openNote(tester, recordingAt(DateTime(2026, 9, 15, 9, 14), hasTranscript: false));
      expect(find.text("This note isn't transcribed yet. Once it is, you can summarize it here."), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Copy prompt'));
      await flush(tester);
      expect(clipboard.text, isNull);
    });

    testWidgets('without a scope it does nothing rather than failing', (tester) async {
      await openNote(tester, recordingAt(DateTime(2026, 9, 15, 9, 14)), scoped: false);
      expect(find.text(NoteSummarizeSheet.title), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
