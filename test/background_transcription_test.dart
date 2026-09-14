import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/services/library_service.dart';

import 'view/harness.dart';

/// Recordings transcribed by themselves while the app is open: order, one at
/// a time, failures remembered, and nothing behind the user's back.
void main() {
  setUpAll(registerViewFallbacks);

  final nine = DateTime(2026, 9, 14, 9);
  final ten = DateTime(2026, 9, 14, 10);
  final eleven = DateTime(2026, 9, 14, 11);

  Future<ViewHarness> seeded({
    ScriptedRecognizer? recognizer,
    bool modelInstalled = true,
  }) async {
    final harness = ViewHarness(
      recognizer: recognizer ?? ScriptedRecognizer(),
      speechModelInstalled: modelInstalled,
    );
    addTearDown(harness.dispose);
    for (final at in <DateTime>[nine, eleven, ten]) {
      await harness.seedRecording(at: at, length: const Duration(seconds: 20));
    }
    await harness.controller.initialise();
    return harness;
  }

  String pathAt(DateTime at) =>
      '${ViewHarness.recordingsDirectory}/${RecordingNaming.fileName(at)}';

  RecordingInfo info(ViewHarness harness, DateTime at) =>
      harness.controller.recordings.singleWhere((r) => r.path == pathAt(at));

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  test('nothing is transcribed until the app is on screen', () async {
    final harness = await seeded();
    await settle();
    expect(harness.recognizer!.calls, 0);
  });

  test('on screen, every recording without a transcript is done, newest '
      'first, one at a time', () async {
    final harness = await seeded();
    // One already has a transcript beside it.
    harness.fileStore.files[RecordingNaming.transcriptPathOf(pathAt(ten))] =
        <int>[];

    await harness.controller.appForegrounded();
    await settle();

    expect(harness.recognizer!.audioPaths, <String>[pathAt(eleven), pathAt(nine)]);
    expect(harness.controller.transcriptionQueue, isEmpty);
    expect(harness.controller.listTranscriptStatusFor(info(harness, eleven)),
        TranscriptStatus.noSpeech);
  });

  test('with no model on the phone nothing is queued', () async {
    final harness = await seeded(modelInstalled: false);

    await harness.controller.appForegrounded();
    await settle();

    expect(harness.recognizer!.calls, 0);
    expect(harness.controller.transcriptionQueue, isEmpty);
  });

  test('the others wait, and say so, while one runs', () async {
    final recognizer = ScriptedRecognizer()..gate = Completer<void>();
    final harness = await seeded(recognizer: recognizer);

    await harness.controller.appForegrounded();
    await settle();

    expect(harness.controller.transcriptStatusFor(info(harness, eleven)),
        TranscriptStatus.running);
    expect(harness.controller.transcriptStatusFor(info(harness, nine)),
        TranscriptStatus.queued);
    expect(recognizer.calls, 1);

    recognizer.gate!.complete();
    await settle();
    expect(recognizer.calls, 3);
  });

  test('opening a waiting recording moves it up next', () async {
    final recognizer = ScriptedRecognizer()..gate = Completer<void>();
    final harness = await seeded(recognizer: recognizer);
    await harness.controller.appForegrounded();
    await settle();

    harness.controller.prioritiseTranscription(info(harness, nine));
    recognizer.gate!.complete();
    await settle();

    expect(recognizer.audioPaths,
        <String>[pathAt(eleven), pathAt(nine), pathAt(ten)]);
  });

  test('leaving the app stops the job, and it runs again on return', () async {
    final recognizer = ScriptedRecognizer()..gate = Completer<void>();
    final harness = await seeded(recognizer: recognizer);
    await harness.controller.appForegrounded();
    await settle();

    await harness.controller.appBackgrounded();
    await settle();

    expect(recognizer.cancelled, isTrue);
    expect(harness.controller.isTranscribing, isFalse);
    expect(harness.controller.transcriptionQueue.first, pathAt(eleven));
    expect(recognizer.calls, 1);

    recognizer.gate = null;
    await harness.controller.appForegrounded();
    await settle();
    expect(recognizer.audioPaths.sublist(1),
        <String>[pathAt(eleven), pathAt(ten), pathAt(nine)]);
  });

  test('a failure is saved and not tried again on the next launch', () async {
    final recognizer = ScriptedRecognizer()..failWith = StateError('native');
    final harness = await seeded(recognizer: recognizer);
    await harness.controller.appForegrounded();
    await settle();
    expect(recognizer.calls, 3);
    expect(
      harness.fileStore.files,
      contains(RecordingNaming.transcriptFailurePathOf(pathAt(ten))),
    );

    final again = ViewHarness(recognizer: ScriptedRecognizer());
    addTearDown(again.dispose);
    again.fileStore.files.addAll(harness.fileStore.files);
    await again.controller.initialise();
    await again.controller.appForegrounded();
    await settle();

    expect(again.recognizer!.calls, 0);
    final reopened = again.controller.recordings.first;
    expect(again.controller.listTranscriptStatusFor(reopened),
        TranscriptStatus.failed);
    await again.controller.loadTranscript(reopened);
    expect(again.controller.transcriptStatusFor(reopened),
        TranscriptStatus.failed);
  });

  test('Transcribe on a failed recording still works, and clears the failure',
      () async {
    final recognizer = ScriptedRecognizer()..failWith = StateError('native');
    final harness = await seeded(recognizer: recognizer);
    final recording = info(harness, ten);
    await harness.controller.transcribe(recording);
    expect(harness.fileStore.files,
        contains(RecordingNaming.transcriptFailurePathOf(recording.path)));

    recognizer.failWith = null;
    await harness.controller.transcribe(recording);

    expect(harness.controller.transcriptStatusFor(recording),
        TranscriptStatus.noSpeech);
    expect(harness.fileStore.files,
        isNot(contains(RecordingNaming.transcriptFailurePathOf(recording.path))));
  });

  test('deleting a recording removes its saved failure too', () async {
    final recognizer = ScriptedRecognizer()..failWith = StateError('native');
    final harness = await seeded(recognizer: recognizer);
    final recording = info(harness, ten);
    await harness.controller.transcribe(recording);

    await harness.controller.deleteRecording(recording);

    expect(harness.fileStore.files.keys.where((p) => p.contains('100000')),
        isEmpty);
  });
}
