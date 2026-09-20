import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/language_router.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/library_service.dart';

import 'view/harness.dart';

/// The controller's side of empty-note deletion and the language setting.
void main() {
  setUpAll(registerViewFallbacks);

  final at = DateTime(2026, 9, 15, 9);
  final later = DateTime(2026, 9, 15, 10);

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  List<int> transcriptJson(String text) => utf8.encode(jsonEncode(Transcript(
        languageCode: 'hi',
        modelId: 'indicconformer-hi-int8',
        createdAt: DateTime.utc(2026, 9, 15),
        audioDuration: const Duration(seconds: 8),
        segments: <TranscriptSegment>[
          TranscriptSegment(
              start: Duration.zero, end: const Duration(seconds: 8), text: text),
        ],
      ).toJson()));

  Future<(ViewHarness, String)> seeded({
    ScriptedRecognizer? recognizer,
    String? transcript,
    bool marked = false,
    ViewHarness? reuse,
  }) async {
    final harness = reuse ?? ViewHarness(recognizer: recognizer);
    if (reuse == null) addTearDown(harness.dispose);
    final path = await harness.seedRecording(
        at: reuse == null ? at : later, length: const Duration(seconds: 20));
    if (transcript != null) {
      harness.fileStore.files[RecordingNaming.transcriptPathOf(path)] =
          transcriptJson(transcript);
    }
    if (marked) {
      harness.fileStore.files[RecordingNaming.emptyNotePathOf(path)] = <int>[1];
    }
    return (harness, path);
  }

  RecordingInfo info(ViewHarness harness, String path) =>
      harness.controller.recordings.singleWhere((r) => r.path == path);

  bool listed(ViewHarness harness, String path) =>
      harness.controller.recordings.any((r) => r.path == path);

  Iterable<String> filesOf(ViewHarness harness, String path) {
    final stem = path.substring(0, path.length - 4);
    return harness.fileStore.files.keys.where((p) => p.startsWith(stem));
  }

  group('after a transcription', () {
    test('no speech in any window: the note is deleted and unlisted', () async {
      final (harness, path) = await seeded(recognizer: ScriptedRecognizer());
      await harness.controller.initialise();

      await harness.controller.transcribe(info(harness, path));
      await settle();

      expect(filesOf(harness, path), isEmpty);
      expect(listed(harness, path), isFalse);
      expect(harness.controller.lastEmptyNoteSweep!.deleted, <String>[path]);
    });

    test('words keep it', () async {
      final (harness, path) = await seeded(
          recognizer: ScriptedRecognizer()..texts = <int, String>{1: 'हाँ'});
      await harness.controller.initialise();

      await harness.controller.transcribe(info(harness, path));
      await settle();

      expect(harness.fileStore.files, contains(path));
      expect(harness.fileStore.files,
          isNot(contains(RecordingNaming.emptyNotePathOf(path))));
    });

    test('a failed transcription keeps it', () async {
      final (harness, path) = await seeded(
          recognizer: ScriptedRecognizer()..failWith = StateError('boom'));
      await harness.controller.initialise();

      await harness.controller.transcribe(info(harness, path));
      await settle();

      expect(harness.fileStore.files, contains(path));
      expect(listed(harness, path), isTrue);
    });

    test('Keep keeps it', () async {
      final (harness, path) = await seeded(recognizer: ScriptedRecognizer());
      await harness.controller.initialise();
      await harness.controller.setKeepAudio(path, true);

      await harness.controller.transcribe(info(harness, path));
      await settle();

      expect(harness.fileStore.files, contains(path));
      expect(harness.controller.transcriptStatusFor(info(harness, path)),
          TranscriptStatus.noSpeech);
    });

    test('an open note waits until its last screen closes', () async {
      final (harness, path) = await seeded(recognizer: ScriptedRecognizer());
      await harness.controller.initialise();
      harness.controller
        ..noteOpened(path)
        ..noteOpened(path);

      await harness.controller.transcribe(info(harness, path));
      await settle();
      expect(harness.fileStore.files, contains(path));
      expect(harness.controller.lastEmptyNoteSweep!.deferred, <String>[path]);

      harness.controller.noteClosed(path);
      await settle();
      expect(harness.fileStore.files, contains(path));

      harness.controller.noteClosed(path);
      await settle();
      expect(filesOf(harness, path), isEmpty);
      expect(listed(harness, path), isFalse);
    });

    test('deferred and then killed: the next start deletes it', () async {
      final (harness, path) = await seeded(recognizer: ScriptedRecognizer());
      await harness.controller.initialise();
      harness.controller.noteOpened(path);
      await harness.controller.transcribe(info(harness, path));
      await settle();
      expect(harness.fileStore.files, contains(path));

      final restarted = ViewHarness();
      addTearDown(restarted.dispose);
      restarted.fileStore.files.addAll(harness.fileStore.files);
      await restarted.controller.initialise();

      expect(filesOf(restarted, path), isEmpty);
      expect(listed(restarted, path), isFalse);
    });
  });

  group('at start', () {
    test('a marked note is finished at every start', () async {
      final (harness, path) = await seeded(transcript: '', marked: true);
      final (_, spoken) =
          await seeded(reuse: harness, transcript: 'ठीक है', marked: true);

      await harness.controller.initialise();

      expect(filesOf(harness, path), isEmpty);
      expect(harness.fileStore.files, contains(spoken));
      expect(harness.controller.recordings.map((r) => r.path), <String>[spoken]);
    });

    test('an empty transcript that was never marked is left alone', () async {
      // The marker is what the sweep acts on, and only this app writes it.
      // An empty transcript put there by hand is not this app's to delete.
      final (harness, path) = await seeded(transcript: '  ');

      await harness.controller.initialise();

      expect(harness.fileStore.files, contains(path));
    });

    test('a kept empty note survives the sweep', () async {
      final (harness, path) = await seeded(transcript: '', marked: true);
      harness.fileStore.files[RecordingNaming.keepAudioPathOf(path)] = <int>[1];

      await harness.controller.initialise();

      expect(harness.fileStore.files, contains(path));
    });
  });

  group('the language setting', () {
    test('auto by default, persisted, and read back at start', () async {
      final harness = ViewHarness(recognizer: ScriptedRecognizer());
      addTearDown(harness.dispose);
      await harness.controller.initialise();
      expect(harness.controller.transcriptionLanguage,
          TranscriptionLanguage.auto);

      var notified = 0;
      harness.controller.addListener(() => notified++);
      await harness.controller.setTranscriptionLanguage(
          TranscriptionLanguage.english);
      expect(harness.controller.transcriptionLanguage,
          TranscriptionLanguage.english);
      expect(notified, 1);

      final restarted = ViewHarness(recognizer: ScriptedRecognizer());
      addTearDown(restarted.dispose);
      restarted.fileStore.files.addAll(harness.fileStore.files);
      await restarted.controller.initialise();
      expect(restarted.controller.transcriptionLanguage,
          TranscriptionLanguage.english);
    });

    test('English is what the next job runs: without the English model it '
        'is reported missing', () async {
      final recognizer = ScriptedRecognizer()..texts = <int, String>{0: 'hello'};
      final (harness, path) = await seeded(recognizer: recognizer);
      await harness.controller.initialise();
      await harness.controller.setTranscriptionLanguage(
          TranscriptionLanguage.english);

      await harness.controller.transcribe(info(harness, path));
      expect(harness.controller.transcriptStatusFor(info(harness, path)),
          TranscriptStatus.modelMissing);
      expect(recognizer.calls, 0);

      const english = SpeechModels.parakeetTdtEnglishInt8;
      for (final file in english.files) {
        harness.fileStore.files['${ViewHarness.modelsDirectory}/'
            '${english.directoryName}/${file.name}'] = Uint8List(file.sizeBytes);
      }
      await harness.controller.transcribe(info(harness, path));
      await settle();

      final transcript = harness.controller.transcriptFor(info(harness, path))!;
      expect(transcript.languageCode, 'en');
      expect(transcript.modelId, english.id);
      expect(transcript.segments.first.languageCode, 'en');
      expect(transcript.text, 'hello');
    });
  });
}
