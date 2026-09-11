import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/view/library_view.dart';
import 'package:voicenotetaker_app/view/placeholder_data.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';
import 'package:voicenotetaker_app/view/theme.dart';

import 'harness.dart';

final DateTime _now = DateTime(2026, 9, 10, 18, 0);

Widget _library({
  ValueChanged<RecordingEntry>? onOpen,
  VoidCallback? onNewRecording,
  List<RecordingEntry>? entries,
}) =>
    LibraryView(
      entries: entries ?? PlaceholderData.library(now: _now),
      onOpen: onOpen ?? (_) {},
      onNewRecording: onNewRecording ?? () {},
      // Pinned, not the wall clock. The entries are built relative to _now,
      // so without this the TODAY/YESTERDAY headers were only correct on
      // 10 Sept 2026 and the test failed at the next midnight.
      now: _now,
    );

void main() {
  testWidgets('builds, grouped by day, with time / duration / size',
      (tester) async {
    await pumpScreen(tester, _library());

    expect(find.text('Recordings'), findsOneWidget);
    expect(find.text('4 items'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);

    expect(find.text('Standup notes'), findsOneWidget);
    expect(find.text('09:14 · 4:12 · 7.9 MB'), findsOneWidget);
    expect(find.text('Call with supplier'), findsOneWidget);
    expect(find.text('16:40 · 11:03 · 21.2 MB'), findsOneWidget);

    expect(find.text('New recording'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The bug this pins: LibraryView used to call dayLabel() with no `now`, so
  // the headers came from the wall clock while the entries came from a fixed
  // date. It read correctly on the day it was written and broke at the next
  // midnight. Passing a `now` a week after the entries must therefore NOT
  // produce TODAY -- if it does, the injected clock is being ignored again.
  testWidgets('day headers follow the injected clock, not the wall clock',
      (tester) async {
    final entries = PlaceholderData.library(now: _now);

    await pumpScreen(tester, _library(entries: entries));
    expect(find.text('TODAY'), findsOneWidget,
        reason: 'entries are same-day as the pinned now');

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpScreen(
      tester,
      LibraryView(
        entries: entries,
        onOpen: (_) {},
        onNewRecording: () {},
        now: _now.add(const Duration(days: 7)),
      ),
    );
    expect(find.text('TODAY'), findsNothing,
        reason: 'a week later nothing is today; the widget must use `now`');
    expect(find.text('YESTERDAY'), findsNothing);
  });

  testWidgets('builds empty', (tester) async {
    await pumpScreen(tester, _library(entries: const <RecordingEntry>[]));

    expect(find.text('0 items'), findsOneWidget);
    expect(find.text('No recordings yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search filters the list', (tester) async {
    await pumpScreen(tester, _library());

    await tester.enterText(find.byType(TextField), 'supplier');
    await tester.pump();

    expect(find.text('Call with supplier'), findsOneWidget);
    expect(find.text('Standup notes'), findsNothing);
  });

  testWidgets('search with no match says so', (tester) async {
    await pumpScreen(tester, _library());

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();

    expect(find.textContaining('Nothing matches'), findsOneWidget);
  });

  testWidgets('a row opens that recording', (tester) async {
    RecordingEntry? opened;
    await pumpScreen(tester, _library(onOpen: (entry) => opened = entry));

    await tester.tap(find.text('Idea — enclosure vents'));
    await tester.pump();

    expect(opened?.title, 'Idea — enclosure vents');
  });

  testWidgets('New recording is a filled, 44px-plus target', (tester) async {
    var started = false;
    await pumpScreen(tester, _library(onNewRecording: () => started = true));

    final size = tester.getSize(find.bySemanticsLabel('New recording'));
    expect(size.height, greaterThanOrEqualTo(AppShape.minTapTarget));

    await tester.tap(find.text('New recording'));
    await tester.pump();
    expect(started, isTrue);
  });

  testWidgets('the search field keeps a 44px hit area around its 42px well',
      (tester) async {
    await pumpScreen(tester, _library());

    final field = tester.getSize(find.byType(TextField));
    expect(field.height, lessThanOrEqualTo(42));
    final well = tester.getSize(
      find.ancestor(of: find.byType(TextField), matching: find.byType(SizedBox))
          .last,
    );
    expect(well.height, greaterThanOrEqualTo(AppShape.minTapTarget));
  });
}
