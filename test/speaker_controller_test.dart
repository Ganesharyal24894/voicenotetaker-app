import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/services/library_service.dart';

import 'view/harness.dart';

/// The speakers sheet's half of the controller: which labels a note has, how
/// many people the user says are in it, and which of them are the same person.
void main() {
  setUpAll(registerViewFallbacks);

  const rate = 16000;
  int s(double seconds) => (seconds * rate).round();

  SpeakerTurn turn(double start, double end, int speaker) =>
      SpeakerTurn(start: s(start), end: s(end), speaker: speaker);

  /// Two people, twelve seconds each way.
  final twoSpeakers = <SpeakerTurn>[
    turn(0, 12, 0),
    turn(12, 24, 1),
  ];

  /// Three people.
  final threeSpeakers = <SpeakerTurn>[
    turn(0, 9, 0),
    turn(9, 18, 1),
    turn(18, 27, 2),
  ];

  Future<(ViewHarness, RecordingInfo)> seeded({
    List<SpeakerTurn>? turns,
    List<List<SpeakerTurn>>? scripted,
    bool speakerModelsInstalled = true,
    Duration length = const Duration(seconds: 30),
  }) async {
    final diarizer = ScriptedDiarizer()
      ..turns = turns ?? const <SpeakerTurn>[];
    if (scripted != null) diarizer.scripted.addAll(scripted);
    final harness = ViewHarness(
      // Every window says something, so no note is deleted as empty.
      recognizer: ScriptedRecognizer()
        ..texts = <int, String>{for (var i = 0; i < 12; i++) i: 'ठीक है'},
      diarizer: diarizer,
      speakerModelsInstalled: speakerModelsInstalled,
    );
    addTearDown(harness.dispose);
    await harness.seedRecording(length: length);
    return (harness, harness.controller.recordings.single);
  }

  group('labels', () {
    test('two speakers are labelled, and listed in the order they speak',
        () async {
      final (harness, info) = await seeded(turns: twoSpeakers);

      await harness.controller.transcribe(info);

      expect(harness.controller.speakerLabels(info.path), <String>['S1', 'S2']);
      expect(harness.controller.speakerLabelsFor(info.path),
          harness.controller.speakerLabels(info.path));
      final transcript = harness.controller.transcriptFor(info)!;
      expect(transcript.segments.first.speaker, 'S1');
      expect(transcript.segments.last.speaker, 'S2');
    });

    test('one speaker is not labelled, so the note reads plain', () async {
      final (harness, info) = await seeded(
        turns: <SpeakerTurn>[turn(0, 30, 0)],
      );

      await harness.controller.transcribe(info);

      expect(harness.controller.speakerLabels(info.path), isEmpty);
      expect(
        harness.controller.transcriptFor(info)!.segments
            .every((segment) => segment.speaker == null),
        isTrue,
      );
    });

    test('models not installed: no speakers, and the note is still made',
        () async {
      final (harness, info) = await seeded(
        turns: twoSpeakers,
        speakerModelsInstalled: false,
      );

      await harness.controller.transcribe(info);

      expect(harness.diarizer!.calls, 0);
      expect(harness.controller.speakerLabels(info.path), isEmpty);
      expect(harness.controller.transcriptFor(info)!.hasSpeech, isTrue);
    });

    test('a note nobody has transcribed has no labels to show', () async {
      final (harness, info) = await seeded(turns: twoSpeakers);

      expect(harness.controller.speakerLabels(info.path), isEmpty);
    });
  });

  group('how many people', () {
    test('auto until the user says otherwise', () async {
      final (harness, info) = await seeded(turns: twoSpeakers);

      await harness.controller.transcribe(info);

      expect(harness.controller.speakerCountFor(info.path), isNull);
      expect(harness.diarizer!.counts, <int?>[null]);
    });

    test('choosing a count saves it and works the note out again', () async {
      final (harness, info) = await seeded(
        scripted: <List<SpeakerTurn>>[twoSpeakers, threeSpeakers],
      );
      await harness.controller.transcribe(info);
      expect(harness.controller.speakerLabels(info.path), hasLength(2));

      await harness.controller.setSpeakerCount(info.path, 3);

      expect(harness.diarizer!.counts, <int?>[null, 3]);
      expect(harness.recognizer!.calls, 2);
      expect(harness.controller.speakerCountFor(info.path), 3);
      expect(harness.controller.speakerLabels(info.path), hasLength(3));
      expect(
        harness.fileStore.files.keys,
        contains(RecordingNaming.speakerSettingsPathOf(info.path)),
      );
    });

    test('the choice outlives a restart', () async {
      final (harness, info) = await seeded(turns: twoSpeakers);
      await harness.controller.transcribe(info);
      await harness.controller.setSpeakerCount(info.path, 2);

      final again = ViewHarness(
        recognizer: ScriptedRecognizer(),
        diarizer: ScriptedDiarizer()..turns = twoSpeakers,
      );
      addTearDown(again.dispose);
      again.fileStore.files.addAll(harness.fileStore.files);
      await again.controller.refreshLibrary();
      final reopened = again.controller.recordings.single;
      await again.controller.loadSpeakerNames(reopened.path);

      expect(again.controller.speakerCountFor(reopened.path), 2);
      expect(again.recognizer!.calls, 0);
    });

    test('choosing the count it already has does nothing at all', () async {
      final (harness, info) = await seeded(turns: twoSpeakers);
      await harness.controller.transcribe(info);
      await harness.controller.setSpeakerCount(info.path, 2);
      final runs = harness.recognizer!.calls;

      await harness.controller.setSpeakerCount(info.path, 2);

      expect(harness.recognizer!.calls, runs);
    });

    test('going back to auto works the note out again too', () async {
      final (harness, info) = await seeded(turns: twoSpeakers);
      await harness.controller.transcribe(info);
      await harness.controller.setSpeakerCount(info.path, 4);

      await harness.controller.setSpeakerCount(info.path, null);

      expect(harness.controller.speakerCountFor(info.path), isNull);
      expect(harness.diarizer!.counts, <int?>[null, 4, null]);
    });

    test('a note whose audio has gone keeps the choice and runs nothing',
        () async {
      final (harness, info) = await seeded(turns: twoSpeakers);
      await harness.controller.transcribe(info);
      final runs = harness.recognizer!.calls;
      // What the retention sweep leaves behind: the transcript and a marker,
      // and no WAV.
      harness.fileStore.files[RecordingNaming.audioRemovedPathOf(info.path)] =
          harness.fileStore.files[info.path]!.sublist(0, 2);
      harness.fileStore.files.remove(info.path);
      await harness.controller.refreshLibrary();

      await harness.controller.setSpeakerCount(info.path, 3);

      expect(harness.controller.speakerCountFor(info.path), 3);
      expect(harness.recognizer!.calls, runs);
    });
  });

  group('the same person twice', () {
    test('merging rewrites the saved transcript', () async {
      final (harness, info) = await seeded(turns: threeSpeakers);
      await harness.controller.transcribe(info);

      await harness.controller.mergeSpeakers(info.path, 'S2', 'S1');

      expect(harness.controller.speakerLabels(info.path), <String>['S1', 'S3']);
      final transcript = harness.controller.transcriptFor(info)!;
      expect(transcript.segments.any((seg) => seg.speaker == 'S2'), isFalse);
      // And it is on disk, not only on the screen.
      final again = ViewHarness(recognizer: ScriptedRecognizer());
      addTearDown(again.dispose);
      again.fileStore.files.addAll(harness.fileStore.files);
      await again.controller.refreshLibrary();
      final reopened = again.controller.recordings.single;
      await again.controller.loadTranscript(reopened);
      expect(again.controller.speakerLabels(reopened.path),
          <String>['S1', 'S3']);
    });

    test('merging into a label that was itself merged follows the chain',
        () async {
      final (harness, info) = await seeded(turns: threeSpeakers);
      await harness.controller.transcribe(info);
      await harness.controller.mergeSpeakers(info.path, 'S2', 'S1');

      await harness.controller.mergeSpeakers(info.path, 'S3', 'S2');

      // Everybody is S1 now, which means one speaker, which means the note
      // goes back to reading plain.
      expect(harness.controller.speakerLabels(info.path), isEmpty);
      expect(
        harness.controller.transcriptFor(info)!.segments
            .every((segment) => segment.speaker == null),
        isTrue,
      );
    });

    test('merging the last two speakers leaves a plain note', () async {
      final (harness, info) = await seeded(turns: twoSpeakers);
      await harness.controller.transcribe(info);

      await harness.controller.mergeSpeakers(info.path, 'S2', 'S1');

      expect(harness.controller.speakerLabels(info.path), isEmpty);
    });

    test('merging a label into itself changes nothing', () async {
      final (harness, info) = await seeded(turns: twoSpeakers);
      await harness.controller.transcribe(info);

      await harness.controller.mergeSpeakers(info.path, 'S1', 'S1');

      expect(harness.controller.speakerLabels(info.path), <String>['S1', 'S2']);
    });

    test('a merge survives the note being worked out again', () async {
      final (harness, info) = await seeded(
        scripted: <List<SpeakerTurn>>[threeSpeakers, threeSpeakers],
      );
      await harness.controller.transcribe(info);
      await harness.controller.mergeSpeakers(info.path, 'S2', 'S1');

      await harness.controller.setSpeakerCount(info.path, 3);

      // The engine found three again; the user's answer is still that two of
      // them are one person.
      expect(harness.controller.speakerLabels(info.path), <String>['S1', 'S3']);
      expect(harness.controller.speakerMergesFor(info.path),
          <String, String>{'S2': 'S1'});
    });

    test('the names the user gave are untouched by a merge', () async {
      final (harness, info) = await seeded(turns: threeSpeakers);
      await harness.controller.transcribe(info);
      await harness.controller.loadSpeakerNames(info.path);
      await harness.controller
          .renameSpeakers(info.path, <String, String>{'S1': 'Asha'});

      await harness.controller.mergeSpeakers(info.path, 'S2', 'S1');

      expect(
        harness.controller.speakerNamesFor(info.path).customName('S1'),
        'Asha',
      );
    });
  });
}
