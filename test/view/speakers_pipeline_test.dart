import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/transcription/transcript_store.dart';
import 'package:voicenotetaker_app/view/note_view.dart';
import 'package:voicenotetaker_app/view/speakers_sheet.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';

import 'harness.dart';

/// THE SHEET ON THE REAL PIPELINE. Every other speakers test drives the sheet
/// through a fake controller; this one opens it over a real [NoteView] on a
/// real `AppController`, with only the two engines scripted, so what is
/// checked is the whole chain: a tap in the sheet, `AppControllerSpeakers`,
/// the controller, a re-run through the transcription service, the saved
/// transcript, and the note screen redrawing itself from it.
void main() {
  setUpAll(registerViewFallbacks);

  const int rate = 16000;
  const Duration length = Duration(seconds: 30);
  final DateTime at = DateTime(2026, 9, 10, 9, 14);
  final DateTime now = DateTime(2026, 9, 10, 15, 14);

  int samples(double seconds) => (seconds * rate).round();

  SpeakerTurn turn(double start, double end, int speaker) =>
      SpeakerTurn(start: samples(start), end: samples(end), speaker: speaker);

  final twoSpeakers = <SpeakerTurn>[turn(0, 15, 0), turn(15, 30, 1)];
  final threeSpeakers = <SpeakerTurn>[
    turn(0, 10, 0),
    turn(10, 20, 1),
    turn(20, 30, 2),
  ];

  /// The note screen, over a note that has really been through the pipeline.
  ///
  /// [runs] is what the separation engine hears, run by run: the first is the
  /// transcription the note already has when the screen opens, the rest are
  /// what a re-run from the sheet will hear.
  Future<(ViewHarness, RecordingInfo)> openNote(
    WidgetTester tester, {
    required List<List<SpeakerTurn>> runs,
  }) async {
    final diarizer = ScriptedDiarizer()..turns = runs.last;
    diarizer.scripted.addAll(runs);
    final harness = ViewHarness(
      // Every window says something, so the note is never deleted as empty.
      recognizer: ScriptedRecognizer()
        ..texts = <int, String>{for (var i = 0; i < 24; i++) i: 'ठीक है'},
      diarizer: diarizer,
      clock: () => now,
    );
    addTearDown(harness.dispose);
    final path = await harness.seedRecording(at: at, length: length);
    final info = harness.controller.recordings.firstWhere(
      (recording) => recording.path == path,
    );
    // The first transcription, before anything is on screen.
    await tester.runAsync(() => harness.controller.transcribe(info));
    await harness.controller.refreshLibrary();

    await pumpScreen(
      tester,
      NoteView(controller: harness.controller, recording: info, now: now),
    );
    await flush(tester);
    return (harness, info);
  }

  /// Opens the Speakers sheet the way somebody does: the Edit beside the chips.
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Speakers'), findsOneWidget);
  }

  Finder countSegment(String label) =>
      find.widgetWithText(SegmentButton, label);

  group('the Speakers sheet on the real controller', () {
    testWidgets('it opens on what the pipeline heard', (tester) async {
      final (harness, info) =
          await openNote(tester, runs: <List<SpeakerTurn>>[twoSpeakers]);

      expect(harness.controller.speakerLabelsFor(info.path),
          <String>['S1', 'S2']);
      await openSheet(tester);

      // A field per speaker, each on its own default label, and Auto.
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text(SpeakersSheet.countFootnote), findsOneWidget);
      final auto = tester.widget<SegmentButton>(countSegment('Auto'));
      expect(auto.selected, isTrue);
    });

    testWidgets('a count runs detection again, and says how far it has got',
        (tester) async {
      final (harness, info) = await openNote(
        tester,
        runs: <List<SpeakerTurn>>[twoSpeakers, threeSpeakers],
      );
      await openSheet(tester);
      // The re-run is held after its first window, so the sheet can be looked
      // at while the job is genuinely running.
      final gate = Completer<void>();
      harness.recognizer!
        ..gate = gate
        ..holdBefore = 1;

      await tester.tap(countSegment('3'));
      await flush(tester, rounds: 8);

      // Mid-run: the footnote is replaced by the honest version of it.
      expect(find.text(SpeakersSheet.countFootnote), findsNothing);
      expect(
        find.textContaining(SpeakersSheet.working),
        findsOneWidget,
        reason: 'the sheet should report the re-run it started',
      );
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator).first,
      );
      expect(bar.value, isNotNull);
      expect(bar.value, inInclusiveRange(0.0, 1.0));

      gate.complete();
      await flush(tester, rounds: 12);

      // The engine was asked for three, the choice was saved beside the note,
      // and the sheet has grown the speaker the re-run found.
      expect(harness.diarizer!.counts, <int?>[null, 3]);
      expect(harness.controller.speakerCountFor(info.path), 3);
      expect(
        harness.fileStore.files,
        contains(RecordingNaming.speakerSettingsPathOf(info.path)),
      );
      expect(harness.controller.speakerLabelsFor(info.path),
          <String>['S1', 'S2', 'S3']);
      expect(find.byType(TextField), findsNWidgets(3));
      expect(tester.widget<SegmentButton>(countSegment('3')).selected, isTrue);
      // And the re-run is over, so the footnote is back.
      expect(find.text(SpeakersSheet.countFootnote), findsOneWidget);
    });

    testWidgets('merging goes through, and the speaker leaves the sheet',
        (tester) async {
      final (harness, info) =
          await openNote(tester, runs: <List<SpeakerTurn>>[threeSpeakers]);
      await openSheet(tester);
      expect(find.byType(TextField), findsNWidgets(3));

      // Speaker 3 is Speaker 1 again.
      await tester.tap(find.text('Merge…').last);
      await tester.pumpAndSettle();
      expect(find.text('Merge Speaker 3 into…'), findsOneWidget);
      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();
      await flush(tester);

      expect(find.text('Speakers'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(harness.controller.speakerLabelsFor(info.path),
          <String>['S1', 'S2']);
      expect(harness.controller.speakerMergesFor(info.path),
          <String, String>{'S3': 'S1'});
      expect(
        harness.fileStore.files,
        contains(RecordingNaming.speakerSettingsPathOf(info.path)),
      );
      // THE FILE BESIDE THE NOTE is what was rewritten, not only a copy in
      // memory: the merge has to survive the app being closed.
      final saved = await tester.runAsync(
        () => TranscriptStore(fileStore: harness.fileStore).load(info.path),
      );
      expect(
        saved!.segments
            .map((segment) => segment.speaker)
            .whereType<String>()
            .toSet(),
        <String>{'S1', 'S2'},
      );
    });

    testWidgets('a rename still lands on the note, through the real seam',
        (tester) async {
      final (harness, info) =
          await openNote(tester, runs: <List<SpeakerTurn>>[twoSpeakers]);
      await openSheet(tester);

      await tester.enterText(find.byType(TextField).at(1), 'Priya');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await flush(tester);

      expect(harness.controller.speakerNamesFor(info.path).customName('S2'),
          'Priya');
      expect(
        harness.fileStore.files,
        contains(RecordingNaming.speakerNamesPathOf(info.path)),
      );
      // On the chip and above the paragraph, without a refresh.
      expect(find.text('Priya'), findsNWidgets(2));
      expect(find.text('Speaker 2'), findsNothing);
    });

    testWidgets('merging down to one person takes the chips and Edit away',
        (tester) async {
      final (harness, info) =
          await openNote(tester, runs: <List<SpeakerTurn>>[twoSpeakers]);
      expect(find.text('Edit'), findsOneWidget);
      await openSheet(tester);

      // Two speakers, so the only merge there is folds one into the other.
      await tester.tap(find.text('Merge…').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();
      await flush(tester);

      // One person is not labelled at all - in the sheet or on the note.
      expect(harness.controller.speakerLabelsFor(info.path), isEmpty);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await flush(tester);

      expect(find.text('Edit'), findsNothing);
      expect(find.text('Speaker 1'), findsNothing);
      expect(find.text('Speaker 2'), findsNothing);
    });
  });
}
