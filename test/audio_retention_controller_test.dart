import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/library_service.dart';

import 'view/harness.dart';

/// The controller's side of audio retention: off by default, the Keep flag,
/// and when sweeps run.
void main() {
  setUpAll(registerViewFallbacks);

  // Recordings on the 10th, "now" on the 12th: old enough.
  final old = DateTime(2026, 9, 10, 9);
  final older = DateTime(2026, 9, 10, 8);
  final young = DateTime(2026, 9, 12, 11);
  final now = DateTime(2026, 9, 12, 12);

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  List<int> transcriptJson([String text = 'हाँ']) => utf8.encode(jsonEncode(
        Transcript(
          languageCode: 'hi',
          modelId: 'm',
          createdAt: DateTime.utc(2026, 9, 10),
          audioDuration: const Duration(seconds: 20),
          segments: <TranscriptSegment>[
            TranscriptSegment(
                start: Duration.zero, end: const Duration(seconds: 8), text: text),
          ],
        ).toJson(),
      ));

  Future<ViewHarness> build({
    Map<String, List<int>>? files,
    ScriptedRecognizer? recognizer,
    FakePlayback? playback,
  }) async {
    final harness = ViewHarness(
      clock: () => now,
      recognizer: recognizer,
      audioPlayer: playback?.player,
    );
    addTearDown(harness.dispose);
    if (files != null) harness.fileStore.files.addAll(files);
    return harness;
  }

  Future<String> seed(ViewHarness harness, DateTime at,
      {bool transcribed = true}) async {
    final path = await harness.seedRecording(
        at: at, length: const Duration(seconds: 20));
    if (transcribed) {
      harness.fileStore.files[RecordingNaming.transcriptPathOf(path)] =
          transcriptJson();
    }
    return path;
  }

  RecordingInfo info(ViewHarness harness, String path) =>
      harness.controller.recordings.singleWhere((r) => r.path == path);

  test('off by default: an old, transcribed recording keeps its audio',
      () async {
    final harness = await build();
    final path = await seed(harness, old);
    await harness.controller.initialise();
    await harness.controller.appForegrounded();

    expect(harness.controller.autoDeleteAudio, isFalse);
    expect(harness.fileStore.files.containsKey(path), isTrue);
    expect(harness.controller.lastAudioSweep, isNull);
  });

  test('turning it on removes day-old transcribed audio at once, lists the '
      'note without audio, and is remembered', () async {
    final harness = await build();
    final gone = await seed(harness, old);
    final fresh = await seed(harness, young);
    final untranscribed = await seed(harness, older, transcribed: false);
    await harness.controller.initialise();

    await harness.controller.setAutoDeleteAudio(true);

    expect(harness.fileStore.files.containsKey(gone), isFalse);
    expect(harness.fileStore.files.containsKey(fresh), isTrue);
    expect(harness.fileStore.files.containsKey(untranscribed), isTrue);
    expect(info(harness, gone).hasAudio, isFalse);
    expect(info(harness, fresh).hasAudio, isTrue);
    expect(harness.controller.lastAudioSweep!.removed, <String>[gone]);

    final again = await build(files: harness.fileStore.files);
    await again.controller.initialise();
    expect(again.controller.autoDeleteAudio, isTrue);
  });

  test('a kept recording survives the sweep and a restart', () async {
    final harness = await build();
    final path = await seed(harness, old);
    await harness.controller.initialise();

    await harness.controller.setKeepAudio(path, true);
    expect(info(harness, path).keepAudio, isTrue);
    expect(harness.controller.keepAudioFor(path), isTrue);

    await harness.controller.setAutoDeleteAudio(true);
    expect(harness.fileStore.files.containsKey(path), isTrue);

    final again = await build(files: harness.fileStore.files);
    await again.controller.initialise();
    expect(again.controller.keepAudioFor(path), isTrue);

    await again.controller.setKeepAudio(path, false);
    await again.controller.appForegrounded();
    expect(again.fileStore.files.containsKey(path), isFalse);
  });

  test('a sweep runs on start and on return to the app', () async {
    final harness = await build();
    await harness.controller.initialise();
    await harness.controller.setAutoDeleteAudio(true);

    final path = await seed(harness, old);
    expect(harness.fileStore.files.containsKey(path), isTrue);
    await harness.controller.appForegrounded();
    expect(harness.fileStore.files.containsKey(path), isFalse);

    final second = await seed(harness, older);
    final restarted = await build(files: harness.fileStore.files);
    await restarted.controller.initialise();
    expect(restarted.fileStore.files.containsKey(second), isFalse);
  });

  test('a transcript landing makes its old recording removable straight away',
      () async {
    final recognizer = ScriptedRecognizer()..texts = <int, String>{0: 'हाँ'};
    final harness = await build(recognizer: recognizer);
    final path = await seed(harness, old, transcribed: false);
    await harness.controller.initialise();
    await harness.controller.setAutoDeleteAudio(true);
    expect(harness.fileStore.files.containsKey(path), isTrue);

    await harness.controller.transcribe(info(harness, path));
    await settle();

    expect(harness.fileStore.files.containsKey(path), isFalse);
    expect(harness.fileStore.files
        .containsKey(RecordingNaming.transcriptPathOf(path)), isTrue);
  });

  test('a transcript with no words keeps the audio', () async {
    final recognizer = ScriptedRecognizer(); // every window decodes to ''
    final harness = await build(recognizer: recognizer);
    final path = await seed(harness, old, transcribed: false);
    await harness.controller.initialise();
    await harness.controller.setAutoDeleteAudio(true);

    await harness.controller.transcribe(info(harness, path));
    await settle();

    expect(harness.fileStore.files.containsKey(path), isTrue);
  });

  test('the recording loaded in the player is never removed', () async {
    final playback = FakePlayback();
    addTearDown(playback.close);
    final harness = await build(playback: playback);
    final path = await seed(harness, old);
    await harness.controller.initialise();
    await harness.controller.playRecording(info(harness, path));

    await harness.controller.setAutoDeleteAudio(true);

    expect(harness.fileStore.files.containsKey(path), isTrue);
  });

  test('a note without audio is neither played nor transcribed', () async {
    final playback = FakePlayback();
    addTearDown(playback.close);
    final recognizer = ScriptedRecognizer();
    final harness = await build(playback: playback, recognizer: recognizer);
    final path = await seed(harness, old);
    await harness.controller.initialise();
    await harness.controller.setAutoDeleteAudio(true);
    final removed = info(harness, path);
    expect(removed.hasAudio, isFalse);

    await harness.controller.playRecording(removed);
    await harness.controller.transcribe(removed);
    await settle();

    verifyNever(() => playback.player.load(any()));
    expect(harness.controller.playbackError, isNotNull);
    expect(recognizer.calls, 0);
    expect(harness.fileStore.files.keys
        .where((p) => p.endsWith(RecordingNaming.transcriptFailureSuffix)),
        isEmpty);
  });

  test('deleting a note without audio removes its transcript and markers',
      () async {
    final harness = await build();
    final path = await seed(harness, old);
    await harness.controller.initialise();
    await harness.controller.setKeepAudio(path, false);
    await harness.controller.setAutoDeleteAudio(true);

    await harness.controller.deleteRecording(info(harness, path));

    expect(harness.controller.recordings, isEmpty);
    expect(
        harness.fileStore.files.keys
            .where((p) => p.startsWith(ViewHarness.recordingsDirectory)),
        <String>[
          '${ViewHarness.recordingsDirectory}/audio-retention-settings.json'
        ]);
  });
}
