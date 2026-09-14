import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/services/library_service.dart';

import 'view/harness.dart';

/// Transcribing a recording, at the controller: what is saved, what is shown,
/// and what is cleaned up.
void main() {
  setUpAll(registerViewFallbacks);

  Future<(ViewHarness, RecordingInfo)> seeded({
    ScriptedRecognizer? recognizer,
    bool modelInstalled = true,
    Duration length = const Duration(seconds: 20),
  }) async {
    final harness = ViewHarness(
      recognizer: recognizer ?? ScriptedRecognizer(),
      speechModelInstalled: modelInstalled,
    );
    addTearDown(harness.dispose);
    await harness.seedRecording(length: length);
    return (harness, harness.controller.recordings.single);
  }

  String sidecarOf(RecordingInfo info) =>
      RecordingNaming.transcriptPathOf(info.path);

  test('nothing is looked for or run until asked', () async {
    final (harness, info) = await seeded();

    expect(harness.controller.transcriptStatusFor(info),
        TranscriptStatus.checking);
    expect(harness.recognizer!.calls, 0);

    await harness.controller.loadTranscript(info);
    expect(harness.controller.transcriptStatusFor(info), TranscriptStatus.none);
    expect(harness.recognizer!.calls, 0);
  });

  test('a transcript is saved beside the recording and loaded back', () async {
    final recognizer = ScriptedRecognizer()
      ..texts = <int, String>{0: 'चेक चेक', 2: 'ठीक है'};
    final (harness, info) = await seeded(recognizer: recognizer);

    await harness.controller.transcribe(info);

    expect(harness.controller.transcriptStatusFor(info), TranscriptStatus.done);
    expect(harness.controller.transcriptFor(info)!.text, 'चेक चेक ठीक है');
    expect(harness.fileStore.files, contains(sidecarOf(info)));
    expect(harness.controller.lastTranscription, isNotNull);

    // A fresh start of the app: the transcript comes off disk, the engine is
    // not run again.
    final again = ViewHarness(recognizer: ScriptedRecognizer());
    addTearDown(again.dispose);
    again.fileStore.files.addAll(harness.fileStore.files);
    await again.controller.refreshLibrary();
    final reopened = again.controller.recordings.single;

    await again.controller.loadTranscript(reopened);

    expect(again.controller.transcriptStatusFor(reopened),
        TranscriptStatus.done);
    expect(again.controller.transcriptFor(reopened)!.text, 'चेक चेक ठीक है');
    expect(again.recognizer!.calls, 0);
  });

  test('a recording with no speech is saved as no speech', () async {
    final (harness, info) = await seeded();

    await harness.controller.transcribe(info);

    expect(harness.controller.transcriptStatusFor(info),
        TranscriptStatus.noSpeech);
    expect(harness.fileStore.files, contains(sidecarOf(info)));
  });

  test('a missing model is reported, and nothing is loaded', () async {
    final (harness, info) = await seeded(modelInstalled: false);

    await harness.controller.transcribe(info);

    expect(harness.controller.transcriptStatusFor(info),
        TranscriptStatus.modelMissing);
    expect(harness.recognizer!.calls, 0);
    expect(harness.fileStore.files, isNot(contains(sidecarOf(info))));
  });

  test('once the model is there, trying again works', () async {
    final (harness, info) = await seeded(modelInstalled: false);
    await harness.controller.transcribe(info);

    harness.installSpeechModel();
    harness.recognizer!.texts = <int, String>{0: 'हैलो'};
    await harness.controller.transcribe(info);

    expect(harness.controller.transcriptStatusFor(info), TranscriptStatus.done);
  });

  test('an engine failure is reported and nothing is saved', () async {
    final recognizer = ScriptedRecognizer()..failWith = StateError('native');
    final (harness, info) = await seeded(recognizer: recognizer);

    await harness.controller.transcribe(info);

    expect(harness.controller.transcriptStatusFor(info),
        TranscriptStatus.failed);
    expect(harness.fileStore.files, isNot(contains(sidecarOf(info))));
    expect(harness.controller.isTranscribing, isFalse);
  });

  test('progress is reported while it runs', () async {
    final recognizer = ScriptedRecognizer()
      ..gate = Completer<void>()
      ..holdBefore = 1;
    final (harness, info) = await seeded(recognizer: recognizer);

    final job = harness.controller.transcribe(info);
    await pumpEventQueue();

    expect(harness.controller.transcriptStatusFor(info),
        TranscriptStatus.running);
    expect(harness.controller.transcribingPath, info.path);
    expect(harness.controller.transcriptionDone, 1);
    expect(harness.controller.transcriptionTotal, 3);

    recognizer.gate!.complete();
    await job;
    expect(harness.controller.isTranscribing, isFalse);
  });

  test('only one transcription at a time', () async {
    final recognizer = ScriptedRecognizer()..gate = Completer<void>();
    final (harness, first) = await seeded(recognizer: recognizer);
    await harness.seedRecording(at: DateTime(2026, 9, 10, 11, 0));
    final second =
        harness.controller.recordings.firstWhere((r) => r.path != first.path);

    final job = harness.controller.transcribe(first);
    await pumpEventQueue();
    await harness.controller.transcribe(second);

    expect(recognizer.calls, 1);
    expect(harness.controller.transcribingPath, first.path);

    recognizer.gate!.complete();
    await job;
  });

  test('cancel stops it, saves nothing and shows no error', () async {
    final recognizer = ScriptedRecognizer()..gate = Completer<void>();
    final (harness, info) = await seeded(recognizer: recognizer);
    await harness.controller.loadTranscript(info);

    final job = harness.controller.transcribe(info);
    await pumpEventQueue();
    await harness.controller.cancelTranscription();
    await job;

    expect(recognizer.cancelled, isTrue);
    expect(harness.controller.transcriptStatusFor(info), TranscriptStatus.none);
    expect(harness.fileStore.files, isNot(contains(sidecarOf(info))));
  });

  test('deleting a recording deletes its transcript', () async {
    final recognizer = ScriptedRecognizer()..texts = <int, String>{0: 'हैलो'};
    final (harness, info) = await seeded(recognizer: recognizer);
    await harness.controller.transcribe(info);
    expect(harness.fileStore.files, contains(sidecarOf(info)));

    await harness.controller.deleteRecording(info);

    expect(harness.fileStore.files, isNot(contains(info.path)));
    expect(harness.fileStore.files, isNot(contains(sidecarOf(info))));
    expect(harness.controller.transcriptFor(info), isNull);
  });

  test('deleting the recording being transcribed stops the job first',
      () async {
    final recognizer = ScriptedRecognizer()..gate = Completer<void>();
    final (harness, info) = await seeded(recognizer: recognizer);

    final job = harness.controller.transcribe(info);
    await pumpEventQueue();
    await harness.controller.deleteRecording(info);
    await job;

    expect(recognizer.cancelled, isTrue);
    expect(harness.controller.isTranscribing, isFalse);
    expect(harness.fileStore.files, isNot(contains(info.path)));
    expect(harness.fileStore.files, isNot(contains(sidecarOf(info))));
  });
}
