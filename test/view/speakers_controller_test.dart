import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/speakers_controller.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/library_service.dart';

import 'harness.dart';

/// Two speakers, S2 first, so "in the order they first speak" is a claim the
/// test can actually fail. [third] adds an S3, for the merges that have to
/// leave somebody behind.
List<int> _transcript({bool third = false}) => utf8.encode(jsonEncode(Transcript(
      languageCode: 'hi',
      modelId: 'm',
      createdAt: DateTime.utc(2026, 9, 10),
      audioDuration: const Duration(minutes: 4),
      segments: <TranscriptSegment>[
        const TranscriptSegment(
          start: Duration.zero,
          end: Duration(seconds: 8),
          text: 'हाँ, सुनो',
          speaker: 'S2',
        ),
        const TranscriptSegment(
          start: Duration(seconds: 9),
          end: Duration(seconds: 14),
          text: 'अच्छा',
          speaker: 'S1',
        ),
        if (third)
          const TranscriptSegment(
            start: Duration(seconds: 15),
            end: Duration(seconds: 20),
            text: 'हाँ जी',
            speaker: 'S3',
          ),
      ],
    ).toJson()));

Future<(ViewHarness, SpeakersController, RecordingInfo)> _seeded({
  bool withTranscript = true,
  bool thirdSpeaker = false,
}) async {
  final harness = ViewHarness(clock: () => DateTime(2026, 9, 10, 15));
  addTearDown(harness.dispose);
  final path = await harness.seedRecording();
  if (withTranscript) {
    harness.fileStore.files[RecordingNaming.transcriptPathOf(path)] =
        _transcript(third: thirdSpeaker);
  }
  await harness.controller.refreshLibrary();
  final note = harness.controller.recordings
      .firstWhere((recording) => recording.path == path);
  await harness.controller.loadTranscript(note);
  await harness.controller.loadSpeakerNames(path);
  return (harness, AppControllerSpeakers(harness.controller), note);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(registerViewFallbacks);

  group('AppControllerSpeakers', () {
    test('speakerLabelsFor: the note\'s labels, first speaker first',
        () async {
      final (_, speakers, note) = await _seeded();

      expect(speakers.speakerLabelsFor(note.path), <String>['S2', 'S1']);
    });

    test('a note with no transcript has no speakers', () async {
      final (_, speakers, note) = await _seeded(withTranscript: false);

      expect(speakers.speakerLabelsFor(note.path), isEmpty);
      // And a path the controller has never heard of is not a crash.
      expect(speakers.speakerLabelsFor('/nowhere.wav'), isEmpty);
    });

    test('renameSpeakers goes through to the controller, and is saved',
        () async {
      final (harness, speakers, note) = await _seeded();

      await speakers.renameSpeakers(note.path, <String, String>{'S2': 'Priya'});

      expect(speakers.speakerNamesFor(note.path).customName('S2'), 'Priya');
      expect(
        harness.controller.speakerNamesFor(note.path).customName('S2'),
        'Priya',
      );
      expect(
        harness.fileStore.files,
        contains(RecordingNaming.speakerNamesPathOf(note.path)),
      );
    });

    test('a blank name clears it, back to Speaker N', () async {
      final (_, speakers, note) = await _seeded();

      await speakers.renameSpeakers(note.path, <String, String>{'S2': 'Priya'});
      await speakers.renameSpeakers(note.path, <String, String>{'S2': ''});

      final names = speakers.speakerNamesFor(note.path);
      expect(names.customName('S2'), isNull);
      expect(
        names.labelFor('S2', speakers.speakerLabelsFor(note.path)),
        'Speaker 1',
      );
    });

    test('a rename tells the sheet to redraw', () async {
      final (_, speakers, note) = await _seeded();
      var told = 0;
      void listener() => told++;
      speakers.addListener(listener);
      addTearDown(() => speakers.removeListener(listener));

      await speakers.renameSpeakers(note.path, <String, String>{'S1': 'Me'});

      expect(told, greaterThan(0));
    });

    test('the count starts on Auto and keeps what it is given', () async {
      final (_, speakers, note) = await _seeded();

      expect(speakers.speakerCountFor(note.path), isNull);

      await speakers.setSpeakerCount(note.path, 3);
      expect(speakers.speakerCountFor(note.path), 3);

      await speakers.setSpeakerCount(note.path, null);
      expect(speakers.speakerCountFor(note.path), isNull);
    });

    test('the count is per note', () async {
      final (harness, speakers, note) = await _seeded();
      final other = await harness.seedRecording(
        at: DateTime(2026, 9, 9, 18, 5),
      );

      await speakers.setSpeakerCount(note.path, 2);

      expect(speakers.speakerCountFor(other), isNull);
    });

    test('the count is saved beside the note, not held in the adapter',
        () async {
      final (harness, speakers, note) = await _seeded();

      await speakers.setSpeakerCount(note.path, 3);

      // The controller is the one that knows, and the sidecar is written.
      expect(harness.controller.speakerCountFor(note.path), 3);
      expect(
        harness.fileStore.files,
        contains(RecordingNaming.speakerSettingsPathOf(note.path)),
      );
      // A second adapter over the same controller sees it: nothing about a
      // speaker lives in AppControllerSpeakers.
      expect(
        AppControllerSpeakers(harness.controller).speakerCountFor(note.path),
        3,
      );
    });

    test('mergeSpeakers rewrites the note, and the label is gone', () async {
      final (harness, speakers, note) = await _seeded(thirdSpeaker: true);
      expect(speakers.speakerLabelsFor(note.path), <String>['S2', 'S1', 'S3']);

      await speakers.mergeSpeakers(note.path, 'S3', 'S1');

      expect(speakers.speakerLabelsFor(note.path), <String>['S2', 'S1']);
      expect(harness.controller.speakerMergesFor(note.path),
          <String, String>{'S3': 'S1'});
      expect(
        harness.fileStore.files,
        contains(RecordingNaming.speakerSettingsPathOf(note.path)),
      );
    });

    test('a merge that leaves one person leaves the note with no labels',
        () async {
      final (_, speakers, note) = await _seeded();

      await speakers.mergeSpeakers(note.path, 'S1', 'S2');

      expect(speakers.speakerLabelsFor(note.path), isEmpty);
    });

    test('nothing is running, so there is no progress to report', () async {
      final (_, speakers, note) = await _seeded();

      expect(speakers.detectionProgressFor(note.path), isNull);
    });

    test('detectionProgressFor is the running job, and only for its note',
        () async {
      // The re-run IS a transcription, so the sheet's progress is the
      // transcription's - held mid-job here so there is something to read.
      final gate = Completer<void>();
      final harness = ViewHarness(
        recognizer: ScriptedRecognizer()
          ..texts = <int, String>{for (var i = 0; i < 24; i++) i: 'ठीक है'}
          ..gate = gate
          ..holdBefore = 1,
        diarizer: ScriptedDiarizer()
          ..turns = <SpeakerTurn>[
            const SpeakerTurn(start: 0, end: 240000, speaker: 0),
            const SpeakerTurn(start: 240000, end: 480000, speaker: 1),
          ],
        clock: () => DateTime(2026, 9, 10, 15),
      );
      addTearDown(harness.dispose);
      final path = await harness.seedRecording(
        length: const Duration(seconds: 30),
      );
      final speakers = AppControllerSpeakers(harness.controller);
      final note = harness.controller.recordings.single;

      final running = harness.controller.transcribe(note);
      await pumpEventQueue();

      final progress = speakers.detectionProgressFor(path);
      expect(progress, isNotNull);
      expect(progress, inInclusiveRange(0.0, 1.0));
      expect(speakers.detectionProgressFor('/some/other/note.wav'), isNull);

      gate.complete();
      await running;

      // Over: back to nothing running.
      expect(speakers.detectionProgressFor(path), isNull);
    });

    test('it is the interface the sheet is written against', () async {
      // Whatever the pipeline adds, the sheet only ever sees this.
      final (_, speakers, _) = await _seeded();

      expect(speakers, isA<SpeakersController>());
      expect(speakers, isA<Listenable>());
    });
  });
}
