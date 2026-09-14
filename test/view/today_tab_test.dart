import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/summary_controller.dart';
import 'package:voicenotetaker_app/services/summary/day_summary_store.dart';
import 'package:voicenotetaker_app/view/home/summarize_sheet.dart';
import 'package:voicenotetaker_app/view/home/today_tab.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';

import '../summary/fakes.dart';
import 'harness.dart';
import 'home_harness.dart';

final DateTime _now = DateTime(2026, 9, 15, 18, 30);

const String _reply = '''
## Summary
- Deadline moved to Friday: testing by Wed, demo Thu
- Staging access and the budget reply are blocking you.

## To-dos
- [ ] Get staging server access from IT | You promised | today 14:00 | 09:14
- [ ] Send budget follow-up to finance | You promised | this evening | 09:14
- [ ] Book car service | Note to self | - | 10:21

## Waiting on others
- Design files | Priya | tonight | 10:58

## Decisions
- Client deadline moved to Friday | 09:14
- Vendor rate to be fixed after lunch call | 11:52
- Hire a tester | 12:00
- Pause the ads | 13:00

## Ideas
- Try a shorter standup
''';

void main() {
  setUpAll(registerViewFallbacks);

  late ViewHarness harness;
  late FakeClipboard clipboard;
  late SummaryController summaries;

  Future<void> pump(WidgetTester tester, {ValueChanged<RecordingEntry>? onOpen}) async {
    await pumpScreen(tester, homeFor(harness, summaries: summaries, onOpenRecording: onOpen));
  }

  setUp(() {
    harness = ViewHarness();
    clipboard = FakeClipboard();
    summaries = summariesFor(harness, clipboard: clipboard, now: _now);
  });

  tearDown(() => harness.dispose());

  group('first run', () {
    testWidgets('explains the three steps and offers both actions', (tester) async {
      await pump(tester);

      expect(find.text(TodayEmpty.title), findsOneWidget);
      for (final step in TodayEmpty.steps) {
        expect(find.text(step.$1), findsOneWidget);
        expect(find.text(step.$2), findsOneWidget);
      }
      expect(find.text('Notes leave this phone only when you paste them.'), findsOneWidget);
      expect(find.bySemanticsLabel('Summarize with your AI'), findsOneWidget);
      expect(find.bySemanticsLabel('Paste AI reply'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Summarize opens the range sheet', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Summarize with your AI'));
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SummarizeRangeSheet), findsOneWidget);
    });

    testWidgets('pasting something unreadable says so plainly and changes nothing', (tester) async {
      clipboard.text = 'Sorry, I cannot help with that.';
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Paste AI reply'));
      await flush(tester);

      expect(find.text(SummaryController.unreadableMessage), findsOneWidget);
      expect(find.text(TodayEmpty.title), findsOneWidget);
    });

    testWidgets('pasting an empty clipboard says what to do', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Paste AI reply'));
      await flush(tester);
      expect(find.text(SummaryController.emptyClipboardMessage), findsOneWidget);
    });

    testWidgets('pasting a reply fills Today', (tester) async {
      clipboard.text = _reply;
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Paste AI reply'));
      await flush(tester);

      expect(find.text(TodayEmpty.title), findsNothing);
      expect(find.text('YOUR DAY'), findsOneWidget);
      expect(find.text('from your AI · 18:30'), findsOneWidget);
    });
  });

  group('with a summary', () {
    setUp(() async {
      await summaries.acceptReply(_reply);
    });

    testWidgets('the card, open to-dos first, waiting and decisions', (tester) async {
      await pump(tester);

      expect(
        find.text('Deadline moved to Friday: testing by Wed, demo Thu. Staging access and the budget reply are blocking you.'),
        findsOneWidget,
      );
      expect(find.text('3 open'), findsOneWidget);
      expect(find.text('Get staging server access from IT'), findsOneWidget);
      expect(find.text('You promised · today 14:00'), findsOneWidget);
      expect(find.text('Note to self'), findsOneWidget, reason: '"-" is no due date, so nothing after the dot');
      expect(find.text('WAITING ON OTHERS'), findsOneWidget);
      expect(find.text('Priya · tonight'), findsOneWidget);
      expect(find.text('Client deadline moved to Friday'), findsOneWidget);
      expect(find.text('Hire a tester'), findsNothing, reason: 'two decisions until Show all');
      expect(find.text('Try a shorter standup'), findsNothing, reason: 'behind More from your AI');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tick settles, then folds into Done (n); unticking brings it back', (tester) async {
      await pump(tester);

      await tester.tap(find.bySemanticsLabel('Book car service'));
      await tester.pump();
      // Still in place for a moment, ticked, so the tick is seen.
      expect(find.text('Book car service'), findsOneWidget);
      expect(find.text('2 open'), findsOneWidget);
      expect(find.text('Done (1)'), findsNothing);

      await tester.pump(TodayTab.settle);
      expect(find.text('Book car service'), findsNothing);
      expect(find.text('Done (1)'), findsOneWidget);

      await tester.tap(find.text('Done (1)'));
      await tester.pump();
      final text = tester.widget<Text>(find.text('Book car service'));
      expect(text.style?.decoration, TextDecoration.lineThrough);

      await tester.tap(find.bySemanticsLabel('Book car service'));
      await tester.pump();
      expect(find.text('Done (1)'), findsNothing);
      expect(find.text('3 open'), findsOneWidget);
      expect(summaries.latest!.todos.every((t) => !t.done), isTrue);
    });

    testWidgets('all ticked says all done', (tester) async {
      for (final todo in summaries.latest!.todos) {
        await summaries.setDone(todo, true);
      }
      await pump(tester);
      expect(find.text('all done'), findsOneWidget);
      expect(find.text('Done (3)'), findsOneWidget);
    });

    testWidgets('Show all decisions, and More from your AI', (tester) async {
      await pump(tester);
      final list = find.descendant(of: find.byType(TodayTab), matching: find.byType(Scrollable));

      await tester.scrollUntilVisible(find.bySemanticsLabel('Show all 4'), 100, scrollable: list);
      await tester.tap(find.bySemanticsLabel('Show all 4'));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Hire a tester'), 100, scrollable: list);
      expect(find.text('Pause the ads'), findsOneWidget);

      await tester.scrollUntilVisible(find.bySemanticsLabel('Show'), 100, scrollable: list);
      await tester.tap(find.bySemanticsLabel('Show'));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Try a shorter standup'), 100, scrollable: list);
      expect(find.text('Ideas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a note-time chip opens the note recorded at that time', (tester) async {
      await harness.seedRecording(at: DateTime(2026, 9, 15, 10, 20));
      await harness.seedRecording(at: DateTime(2026, 9, 15, 9, 14));
      RecordingEntry? opened;
      await pump(tester, onOpen: (entry) => opened = entry);

      await tester.tap(find.bySemanticsLabel('Open the note from 10:21'));
      await tester.pump();
      expect(opened?.title, 'Voice note 10:20');
    });

    testWidgets('a chip with no note near it says so', (tester) async {
      RecordingEntry? opened;
      await pump(tester, onOpen: (entry) => opened = entry);
      await tester.tap(find.bySemanticsLabel('Open the note from 10:21'));
      await tester.pump();
      expect(opened, isNull);
      expect(find.text(TodayTab.noteNotFound), findsOneWidget);
    });
  });

  testWidgets('a summary from an earlier day stays, says when, and nudges', (tester) async {
    final files = MemoryFileStore();
    final yesterday = SummaryController(
      loadTranscript: (_) async => null,
      store: DaySummaryStore(fileStore: files, directory: '/support'),
      clock: () => DateTime(2026, 9, 14, 18, 30),
    );
    await yesterday.acceptReply(_reply);
    summaries = SummaryController(
      loadTranscript: (_) async => null,
      store: DaySummaryStore(fileStore: files, directory: '/support'),
      clock: () => _now,
    );

    await pump(tester);
    await flush(tester);
    expect(find.text('from your AI · yesterday 18:30'), findsOneWidget);
    expect(find.bySemanticsLabel('Summarize today'), findsOneWidget);
    expect(find.text('3 open'), findsOneWidget);
  });
}
