import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/note_voices.dart';

import '../fakes/fake_speaker_embedder.dart';
import '../view/harness.dart';

/// The owner's guided voice recording at the controller: recorded like a
/// note, never one, and always-listening paused around it.
void main() {
  setUpAll(registerViewFallbacks);

  const sample = '/support/voices/enrol-1.wav';
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<ViewHarness> connected({bool listening = false}) async {
    final harness = ViewHarness()..captureSupported = true;
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    await harness.controller.connect(knownDevice);
    if (listening) await harness.controller.setContinuousEnabled(true);
    clearInteractions(harness.transport);
    return harness;
  }

  test('always-listening pauses for it and comes back after', () async {
    final harness = await connected(listening: true);
    expect(harness.controller.continuousActive, isTrue);

    expect(await harness.controller.startVoiceSample(sample), isTrue);

    expect(harness.controller.continuousActive, isFalse);
    expect(harness.controller.isRecordingVoiceSample, isTrue);
    verify(
      () => harness.transport.writeCapture(
        knownDevice.id,
        CaptureCommand.gateDisabled,
      ),
    ).called(greaterThanOrEqualTo(1));

    final take = await harness.controller.stopVoiceSample();

    expect(take!.path, sample);
    expect(take.linkLost, isFalse);
    expect(harness.controller.isRecordingVoiceSample, isFalse);
    expect(harness.controller.continuousActive, isTrue);
    verify(
      () => harness.transport.writeCapture(
        knownDevice.id,
        CaptureCommand.gateEnabled,
      ),
    ).called(1);
  });

  test('the file is written where asked, and is never a note', () async {
    final harness = await connected();

    await harness.controller.startVoiceSample(sample);
    await harness.controller.stopVoiceSample();

    expect(harness.fileStore.files.keys, contains(sample));
    expect(harness.controller.recordings, isEmpty);
    expect(harness.controller.isRecording, isFalse);
  });

  test('with always-listening off, nothing starts it afterwards', () async {
    final harness = await connected();

    await harness.controller.startVoiceSample(sample);
    await harness.controller.stopVoiceSample();

    expect(harness.controller.continuousActive, isFalse);
    verifyNever(
      () => harness.transport.writeCapture(any(), CaptureCommand.gateEnabled),
    );
  });

  test('no recorder: refused', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.controller.initialise();

    expect(await harness.controller.startVoiceSample(sample), isFalse);
    expect(await harness.controller.stopVoiceSample(), isNull);
  });

  test('Record is refused while it runs', () async {
    final harness = await connected();
    await harness.controller.startVoiceSample(sample);

    await harness.controller.startRecording();

    expect(harness.controller.isRecording, isFalse);
    await harness.controller.stopVoiceSample();
  });

  test('a dropped link closes the file and the take says so', () async {
    final harness = await connected();
    await harness.controller.startVoiceSample(sample);

    harness.link.add(BleConnectionStatus.disconnected);
    await settle();

    expect(harness.controller.voiceSampleInterrupted, isTrue);
    final take = await harness.controller.stopVoiceSample();
    expect(take!.linkLost, isTrue);
    expect(harness.controller.voiceSampleInterrupted, isFalse);
  });

  group('the voices hook', () {
    test('a transcribed note with speech hands its voices on, labelled',
        () async {
      final found = <(String, NoteVoices)>[];
      final harness = ViewHarness(
        recognizer: ScriptedRecognizer()..texts = <int, String>{0: 'हाँ जी'},
        diarizer: ScriptedDiarizer()
          ..turns = const <SpeakerTurn>[
            SpeakerTurn(start: 0, end: 16000 * 20, speaker: 0),
          ],
        embedder: FakeSpeakerEmbedder(),
        onVoicesFound: (path, voices) => found.add((path, voices)),
      );
      addTearDown(harness.dispose);
      final path = await harness.seedRecording(
        length: const Duration(seconds: 20),
      );

      await harness.controller.transcribe(harness.controller.recordings.single);

      expect(found, hasLength(1));
      expect(found.single.$1, path);
      expect(found.single.$2.turns.single.label, 'S1');
    });

    test('a note with no speech hands nothing on: it is about to go',
        () async {
      final found = <String>[];
      final harness = ViewHarness(
        recognizer: ScriptedRecognizer(),
        diarizer: ScriptedDiarizer()
          ..turns = const <SpeakerTurn>[
            SpeakerTurn(start: 0, end: 16000 * 20, speaker: 0),
          ],
        embedder: FakeSpeakerEmbedder(),
        onVoicesFound: (path, _) => found.add(path),
      );
      addTearDown(harness.dispose);
      await harness.seedRecording(length: const Duration(seconds: 20));

      await harness.controller.transcribe(harness.controller.recordings.single);

      expect(found, isEmpty);
    });
  });
}
