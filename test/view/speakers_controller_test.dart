import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/speakers_controller.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/library_service.dart';

import 'harness.dart';

/// Two speakers, S2 first, so "in the order they first speak" is a claim the
/// test can actually fail.
List<int> _transcript() => utf8.encode(jsonEncode(Transcript(
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
      ],
    ).toJson()));

Future<(ViewHarness, SpeakersController, RecordingInfo)> _seeded({
  bool withTranscript = true,
}) async {
  final harness = ViewHarness(clock: () => DateTime(2026, 9, 10, 15));
  addTearDown(harness.dispose);
  final path = await harness.seedRecording();
  if (withTranscript) {
    harness.fileStore.files[RecordingNaming.transcriptPathOf(path)] =
        _transcript();
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

    test('until the pipeline lands, merging and re-detection do nothing',
        () async {
      // The TODOs in AppControllerSpeakers. Pinned so the day they start
      // doing something, this test says so.
      final (_, speakers, note) = await _seeded();

      await speakers.mergeSpeakers(note.path, 'S1', 'S2');
      expect(speakers.speakerLabelsFor(note.path), <String>['S2', 'S1']);
      expect(speakers.detectionProgressFor(note.path), isNull);
    });

    test('it is the interface the sheet is written against', () async {
      // Whatever the pipeline adds, the sheet only ever sees this.
      final (_, speakers, _) = await _seeded();

      expect(speakers, isA<SpeakersController>());
      expect(speakers, isA<Listenable>());
    });
  });
}
