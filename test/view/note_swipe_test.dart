import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/view/note_audio_panel.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/note_view.dart';
import 'package:voicenotetaker_app/view/widgets/waveform.dart';

import 'harness.dart';

/// Sunday 20 September 2026, early evening.
final DateTime _now = DateTime(2026, 9, 20, 18);

/// Three notes today and one yesterday, newest first - the order All notes
/// shows them in.
Future<List<RecordingInfo>> _library(ViewHarness harness) async {
  for (final at in <DateTime>[
    DateTime(2026, 9, 20, 9, 14),
    DateTime(2026, 9, 20, 11, 40),
    DateTime(2026, 9, 20, 17, 20),
    DateTime(2026, 9, 19, 19, 30),
  ]) {
    await harness.seedRecording(at: at);
  }
  await harness.controller.refreshLibrary();
  return <RecordingInfo>[...harness.controller.recordings]
    ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
}

Future<void> _pump(
  WidgetTester tester,
  ViewHarness harness, {
  required RecordingInfo open,
  required List<RecordingInfo> siblings,
}) async {
  await pumpScreen(
    tester,
    NoteView(
      // A fresh route in the app is a fresh screen; the key says so here.
      key: ValueKey<String>(open.path),
      controller: harness.controller,
      recording: open,
      siblings: siblings,
      now: _now,
      onBack: () {},
    ),
  );
  await flush(tester);
}

/// Left = the note below in the list (older).
Future<void> _swipeLeft(WidgetTester tester) async {
  await tester.drag(find.byType(PageView), const Offset(-360, 0));
  await tester.pumpAndSettle();
}

/// Right = the note above in the list (newer).
Future<void> _swipeRight(WidgetTester tester) async {
  await tester.drag(find.byType(PageView), const Offset(360, 0));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('the header says where you are in the list you came from',
      (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    final notes = await _library(harness);

    await _pump(tester, harness, open: notes[1], siblings: notes);

    expect(find.text('2 of 4 · Today'), findsOneWidget);
    expect(find.text('11:40 · 4 min'), findsOneWidget);
  });

  testWidgets('left walks back through the list, right comes forward again',
      (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    final notes = await _library(harness);

    await _pump(tester, harness, open: notes[0], siblings: notes);
    expect(find.text('1 of 4 · Today'), findsOneWidget);
    expect(find.text('17:20 · 4 min'), findsOneWidget);

    await _swipeLeft(tester);
    expect(find.text('2 of 4 · Today'), findsOneWidget);
    expect(find.text('11:40 · 4 min'), findsOneWidget);

    await _swipeLeft(tester);
    expect(find.text('3 of 4 · Today'), findsOneWidget);
    expect(find.text('09:14 · 4 min'), findsOneWidget);

    await _swipeRight(tester);
    expect(find.text('2 of 4 · Today'), findsOneWidget);
    expect(find.text('11:40 · 4 min'), findsOneWidget);
  });

  testWidgets('crossing a day says so', (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    final notes = await _library(harness);

    await _pump(tester, harness, open: notes[2], siblings: notes);
    expect(find.text('3 of 4 · Today'), findsOneWidget);

    await _swipeLeft(tester);
    expect(find.text('4 of 4 · Yesterday'), findsOneWidget);
    expect(find.text('19:30 · 4 min'), findsOneWidget);
  });

  testWidgets('the ends do not wrap - they spring back', (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    final notes = await _library(harness);

    // The first note: right goes nowhere.
    await _pump(tester, harness, open: notes.first, siblings: notes);
    await _swipeRight(tester);
    expect(find.text('1 of 4 · Today'), findsOneWidget);
    expect(find.text('17:20 · 4 min'), findsOneWidget);

    // The last note: left goes nowhere.
    await _pump(tester, harness, open: notes.last, siblings: notes);
    expect(find.text('4 of 4 · Yesterday'), findsOneWidget);
    await _swipeLeft(tester);
    expect(find.text('4 of 4 · Yesterday'), findsOneWidget);
    expect(find.text('19:30 · 4 min'), findsOneWidget);
  });

  testWidgets('the swipe follows a FILTERED list, not the whole library',
      (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    final notes = await _library(harness);
    // As if two days had been picked out of four notes.
    final filtered = <RecordingInfo>[notes[0], notes[3]];

    await _pump(tester, harness, open: filtered.first, siblings: filtered);
    expect(find.text('1 of 2 · Today'), findsOneWidget);

    await _swipeLeft(tester);
    // Straight to yesterday: the notes in between are not in this list.
    expect(find.text('2 of 2 · Yesterday'), findsOneWidget);
    expect(find.text('19:30 · 4 min'), findsOneWidget);

    await _swipeLeft(tester);
    expect(find.text('2 of 2 · Yesterday'), findsOneWidget);
  });

  testWidgets('one note on its own: the day alone, and nothing to swipe',
      (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    final notes = await _library(harness);

    await _pump(
      tester,
      harness,
      open: notes[1],
      siblings: const <RecordingInfo>[],
    );

    expect(find.byType(PageView), findsNothing);
    expect(find.text('Today'), findsWidgets);
    expect(find.textContaining(' of '), findsNothing);
  });

  testWidgets('a list that does not hold the note leaves it on its own',
      (tester) async {
    final harness = ViewHarness(clock: () => _now);
    addTearDown(harness.dispose);
    final notes = await _library(harness);

    await _pump(
      tester,
      harness,
      open: notes[1],
      siblings: <RecordingInfo>[notes[0], notes[3]],
    );

    expect(find.byType(PageView), findsNothing);
    expect(find.text('11:40 · 4 min'), findsOneWidget);
  });

  testWidgets('changing note stops the audio and closes the panel',
      (tester) async {
    final playback = FakePlayback();
    addTearDown(playback.close);
    final harness = ViewHarness(
      clock: () => _now,
      audioPlayer: playback.player,
    );
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    final notes = await _library(harness);

    await _pump(tester, harness, open: notes[0], siblings: notes);
    await tester.tap(find.bySemanticsLabel('Show audio'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(NoteAudioPanel), findsOneWidget);

    await _swipeLeft(tester);
    await flush(tester);

    expect(find.text('2 of 4 · Today'), findsOneWidget);
    verify(() => playback.player.stop()).called(greaterThanOrEqualTo(1));
    expect(harness.controller.playbackState.isPlaying, isFalse);
    // The panel belonged to the note that was left.
    expect(find.byType(NoteAudioPanel), findsNothing);

    // And it is still gone on the way back.
    await _swipeRight(tester);
    expect(find.text('1 of 4 · Today'), findsOneWidget);
    expect(find.byType(NoteAudioPanel), findsNothing);
  });

  testWidgets('a drag on the waveform scrubs instead of changing note',
      (tester) async {
    final playback = FakePlayback();
    addTearDown(playback.close);
    final harness = ViewHarness(
      clock: () => _now,
      audioPlayer: playback.player,
    );
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    final notes = await _library(harness);

    await _pump(tester, harness, open: notes[0], siblings: notes);
    await tester.tap(find.bySemanticsLabel('Show audio'));
    await tester.pump();
    await tester.pump();

    final box = tester.getRect(find.byType(ScrubWaveform));
    await tester.dragFrom(
      Offset(box.left + box.width * 0.2, box.center.dy),
      const Offset(-120, 0),
    );
    await tester.pumpAndSettle();

    // The waveform owns horizontal drags inside the panel: it seeks, and the
    // note does not change.
    verify(() => playback.player.seek(any())).called(greaterThanOrEqualTo(1));
    expect(find.text('1 of 4 · Today'), findsOneWidget);
  });

  testWidgets("a note opened from Home's list swipes within today's notes",
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);

    // Home reads the wall clock, so the notes are seeded on today's date.
    final today = DateTime.now();
    for (final hour in <int>[9, 11, 17]) {
      await harness.seedRecording(
        at: DateTime(today.year, today.month, today.day, hour, 40),
      );
    }
    await harness.seedRecording(
      at: DateTime(today.year, today.month, today.day - 1, 19, 30),
    );
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Notes tab'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel(RegExp('^Note at 11:40')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Home lists today; yesterday's note is not in that list.
    expect(find.text('2 of 3 · Today'), findsOneWidget);
    await _swipeLeft(tester);
    expect(find.text('3 of 3 · Today'), findsOneWidget);
    await _swipeLeft(tester);
    expect(find.text('3 of 3 · Today'), findsOneWidget);
    expect(find.textContaining('Yesterday'), findsNothing);
  });
}
