import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/view/all_notes_view.dart';
import 'package:voicenotetaker_app/view/notes_calendar_sheet.dart';
import 'package:voicenotetaker_app/view/theme.dart';

import 'harness.dart';

/// Sunday 20 September 2026, the day the canvas is drawn against.
final DateTime _now = DateTime(2026, 9, 20, 18);

List<int> _transcript(String text) => utf8.encode(jsonEncode(Transcript(
      languageCode: 'hi',
      modelId: 'm',
      createdAt: DateTime.utc(2026, 9, 20),
      audioDuration: const Duration(minutes: 4),
      segments: <TranscriptSegment>[
        TranscriptSegment(
          start: Duration.zero,
          end: const Duration(seconds: 8),
          text: text,
        ),
      ],
    ).toJson()));

/// Two notes today, one on Friday the 18th, one on Saturday the 12th.
Future<ViewHarness> _seeded(WidgetTester tester) async {
  final harness = ViewHarness(clock: () => _now);
  addTearDown(harness.dispose);
  Future<void> note(DateTime at, String said) async {
    final path = await harness.seedRecording(at: at);
    harness.fileStore.files[RecordingNaming.transcriptPathOf(path)] =
        _transcript(said);
  }

  await note(DateTime(2026, 9, 20, 9, 14), 'सुबह की मीटिंग');
  await note(DateTime(2026, 9, 20, 17, 20), 'शाम को बैंक जाना है');
  await note(DateTime(2026, 9, 18, 10, 5), 'शाम को दुकान बंद');
  await note(DateTime(2026, 9, 12, 11, 48), 'गाड़ी की सर्विस');
  await harness.controller.refreshLibrary();
  return harness;
}

Future<void> _pump(WidgetTester tester, ViewHarness harness) async {
  await pumpScreen(
    tester,
    AllNotesView(
      controller: harness.controller,
      onOpen: (_, _) {},
      onBack: () {},
      now: _now,
    ),
  );
  await flush(tester);
}

Future<void> _openCalendar(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel(RegExp('(Pick|Change) days')));
  await tester.pumpAndSettle();
}

Finder _day(String number) => find.descendant(
      of: find.byType(NotesCalendarSheet),
      matching: find.text(number),
    );

Color? _colourOf(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).style?.color;

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('the calendar sits beside search, and search is untouched',
      (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);

    final search = find.byType(TextField);
    final button = find.bySemanticsLabel('Pick days');
    expect(search, findsOneWidget);
    expect(button, findsOneWidget);
    expect(find.text('Search transcripts'), findsOneWidget);

    // Same height, to the right of the field.
    expect(
      tester.getCenter(button).dy,
      closeTo(tester.getCenter(search).dy, 1),
    );
    expect(
      tester.getTopLeft(button).dx,
      greaterThan(tester.getTopRight(search).dx - 1),
    );
  });

  testWidgets('a day with no notes is greyed and does nothing when tapped',
      (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);
    await _openCalendar(tester);

    // The 19th has nothing; the 20th has two.
    expect(_colourOf(tester, _day('19')), AppColors.waveFloor);
    expect(_colourOf(tester, _day('20')), AppColors.textPrimary);

    await tester.tap(_day('19'));
    await tester.pump();
    // Nothing picked, so the button still offers everything.
    expect(find.text('Show all notes'), findsOneWidget);
    expect(find.text('Clear'), findsNothing);
  });

  testWidgets('picking days adds them up, and Show applies them',
      (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);
    await _openCalendar(tester);

    await tester.tap(_day('20'));
    await tester.pump();
    expect(find.text('Show 2 notes'), findsOneWidget);

    await tester.tap(_day('12'));
    await tester.pump();
    expect(find.text('Show 3 notes'), findsOneWidget);

    // Tapping again drops it.
    await tester.tap(_day('12'));
    await tester.pump();
    expect(find.text('Show 2 notes'), findsOneWidget);
    await tester.tap(_day('12'));
    await tester.pump();

    await tester.tap(find.text('Show 3 notes'));
    await tester.pumpAndSettle();

    // The list, the header count and the chips all agree.
    expect(find.text('3 notes'), findsOneWidget);
    expect(find.text('TODAY · 2 NOTES'), findsOneWidget);
    expect(find.text('12 SEP · 1 NOTE'), findsOneWidget);
    expect(find.text('FRIDAY · 1 NOTE'), findsNothing);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('12 Sep'), findsOneWidget);
  });

  testWidgets('a chip drops its day; Clear drops the lot', (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);
    await _openCalendar(tester);
    await tester.tap(_day('20'));
    await tester.tap(_day('18'));
    await tester.pump();
    await tester.tap(find.text('Show 3 notes'));
    await tester.pumpAndSettle();

    expect(find.text('3 notes'), findsOneWidget);
    expect(find.bySemanticsLabel('Stop showing Friday'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Stop showing Friday'));
    await tester.pump();
    expect(find.text('2 notes'), findsOneWidget);
    expect(find.text('FRIDAY · 1 NOTE'), findsNothing);

    // Clear inside the calendar puts everything back.
    await _openCalendar(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('4 notes'), findsOneWidget);
    expect(find.text('TODAY · 2 NOTES'), findsOneWidget);
    expect(find.text('FRIDAY · 1 NOTE'), findsOneWidget);
    expect(find.text('12 SEP · 1 NOTE'), findsOneWidget);
    expect(find.bySemanticsLabel('Pick days'), findsOneWidget);
  });

  testWidgets('picked days and search are both applied', (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);
    await _openCalendar(tester);
    await tester.tap(_day('20'));
    await tester.pump();
    await tester.tap(find.text('Show 2 notes'));
    await tester.pumpAndSettle();

    // "शाम" is said today AND on Friday; only today's is left.
    await tester.enterText(find.byType(TextField), 'शाम');
    await tester.pump(AllNotesView.searchDebounce);

    expect(find.text('1 note'), findsOneWidget);
    expect(find.text('शाम को बैंक जाना है'), findsOneWidget);
    expect(find.text('शाम को दुकान बंद'), findsNothing);

    // A word said only outside the picked days finds nothing.
    await tester.enterText(find.byType(TextField), 'सर्विस');
    await tester.pump(AllNotesView.searchDebounce);
    expect(find.text('No notes match'), findsOneWidget);
  });

  testWidgets('months step back, stop at this one, and say when bare',
      (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);
    await _openCalendar(tester);

    expect(find.text('September 2026'), findsOneWidget);
    expect(find.text('No notes this month.'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Previous month'));
    await tester.pump();
    expect(find.text('August 2026'), findsOneWidget);
    expect(find.text('No notes this month.'), findsOneWidget);
    // August has 31 days and no 32nd.
    expect(_day('31'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Next month'));
    await tester.pump();
    expect(find.text('September 2026'), findsOneWidget);

    // Nothing can be recorded later than now, so forward stops here.
    await tester.tap(find.bySemanticsLabel('Next month'));
    await tester.pump();
    expect(find.text('September 2026'), findsOneWidget);
  });

  testWidgets('a day says how many notes it holds, for a screen reader',
      (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);
    await _openCalendar(tester);

    expect(find.bySemanticsLabel('20, 2 notes'), findsOneWidget);
    expect(find.bySemanticsLabel('18, 1 note'), findsOneWidget);
    expect(find.bySemanticsLabel('19, no notes'), findsOneWidget);
  });

  testWidgets('day headings stay pinned while their notes scroll under them',
      (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    for (var i = 0; i < 12; i++) {
      await harness.seedRecording(at: DateTime(2026, 9, 20, 6 + i, 5));
    }
    for (var i = 0; i < 4; i++) {
      await harness.seedRecording(at: DateTime(2026, 9, 19, 8 + i, 5));
    }
    await harness.controller.refreshLibrary();
    await _pump(tester, harness);

    final heading = find.text('TODAY · 12 NOTES');
    final firstRow = find.text('17:05 · 4 min');
    expect(heading, findsOneWidget);
    expect(firstRow, findsOneWidget);

    final headingAt = tester.getTopLeft(heading).dy;
    final rowAt = tester.getTopLeft(firstRow).dy;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
    await tester.pump();

    // The rows moved; the heading did not.
    expect(tester.getTopLeft(heading).dy, closeTo(headingAt, 0.5));
    expect(tester.getTopLeft(firstRow).dy, lessThan(rowAt - 70));
    // And it is still the heading over them, not a stray label.
    expect(heading, findsOneWidget);
  });

  testWidgets('leaving All notes and coming back shows everything again',
      (tester) async {
    final harness = await _seeded(tester);
    await _pump(tester, harness);
    await _openCalendar(tester);
    await tester.tap(_day('20'));
    await tester.pump();
    await tester.tap(find.text('Show 2 notes'));
    await tester.pumpAndSettle();
    expect(find.text('2 notes'), findsOneWidget);

    // Leave the screen for real - the state goes with it.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    // A fresh screen is a fresh filter.
    await _pump(tester, harness);
    expect(find.text('4 notes'), findsOneWidget);
    expect(find.bySemanticsLabel('Pick days'), findsOneWidget);
  });

  testWidgets('no notes at all: no calendar to open', (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    await _pump(tester, harness);

    expect(find.text('No notes yet'), findsOneWidget);
    expect(find.bySemanticsLabel('Pick days'), findsNothing);
  });
}
