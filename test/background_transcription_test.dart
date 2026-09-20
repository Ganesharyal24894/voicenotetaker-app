import 'dart:async';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/background_transcription_policy.dart';
import 'package:voicenotetaker_app/model/phone_power.dart';
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
    // Words, so the notes are kept: an empty one would be deleted.
    final harness = await seeded(
      recognizer: ScriptedRecognizer()..texts = <int, String>{0: 'हाँ'},
    );
    // One already has a transcript beside it.
    harness.fileStore.files[RecordingNaming.transcriptPathOf(pathAt(ten))] =
        <int>[];

    await harness.controller.appForegrounded();
    await settle();

    expect(harness.recognizer!.audioPaths, <String>[pathAt(eleven), pathAt(nine)]);
    expect(harness.controller.transcriptionQueue, isEmpty);
    expect(harness.controller.listTranscriptStatusFor(info(harness, eleven)),
        TranscriptStatus.done);
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
    // Nothing will use the model off screen, so it is freed, not kept warm.
    expect(recognizer.releaseRequests, greaterThan(0));
    expect(harness.controller.transcriptionPermit,
        TranscriptionPermit.noKeepAlive);

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

  group('off screen on Android, with always-listening keeping the process',
      () {
    const low = PhonePowerState(
      batteryPercent: 20,
      onExternalPower: false,
      batterySaver: false,
      thermal: ThermalState.none,
    );

    /// Seeded like [seeded], built as the Android app is: background
    /// transcription on, always-listening saved as on, a battery reader.
    Future<ViewHarness> android({
      ScriptedRecognizer? recognizer,
      FakePhonePower? power,
      bool listening = true,
      Duration recheck = const Duration(seconds: 60),
      bool initialise = true,
      FakeBackgroundMode? background,
    }) async {
      final phone = power ?? FakePhonePower();
      final harness = ViewHarness(
        recognizer: recognizer ?? ScriptedRecognizer(),
        phonePower: phone,
        backgroundMode: background,
        backgroundTranscription: true,
        powerRecheckInterval: recheck,
      );
      addTearDown(() async {
        await harness.dispose();
        await phone.close();
      });
      harness.fileStore.files[
              '${ViewHarness.recordingsDirectory}/continuous-settings.json'] =
          utf8.encode(jsonEncode(<String, Object?>{
        'version': 1,
        'enabled': listening,
      }));
      for (final at in <DateTime>[nine, eleven, ten]) {
        await harness.seedRecording(at: at, length: const Duration(seconds: 20));
      }
      if (initialise) await harness.controller.initialise();
      return harness;
    }

    test('a healthy battery: the queue runs without the app being opened',
        () async {
      final harness = await android();
      await settle();

      expect(harness.recognizer!.audioPaths,
          <String>[pathAt(eleven), pathAt(ten), pathAt(nine)]);
      expect(harness.controller.transcriptionPermit,
          TranscriptionPermit.batteryOk);
      // Drained off screen: the model is freed at once, not left to a timer.
      expect(harness.recognizer!.releaseRequests, greaterThan(0));
    });

    test('the CPU is held for a run off screen, and let go at the end of it',
        () async {
      final background = FakeBackgroundMode();
      final harness = await android(background: background);
      await settle();

      // A foreground service keeps the PROCESS, not the CPU: once the packet
      // that woke it is done with, the phone is free to suspend and a job on
      // a worker thread is frozen between packets.
      expect(harness.recognizer!.calls, 3);
      expect(background.cpuHolds, 1,
          reason: 'one lock for the run, not one per job');
      expect(background.cpuHeld, isFalse, reason: 'let go when the run ended');
    });

    test('nothing is held for a run on screen', () async {
      final background = FakeBackgroundMode();
      final harness = await android(background: background);
      await settle();
      background.cpuHolds = 0;

      await harness.seedRecording(
          at: DateTime(2026, 9, 14, 12), length: const Duration(seconds: 20));
      await harness.controller.appForegrounded();
      await settle();

      expect(background.cpuHolds, 0,
          reason: 'the screen being on is what keeps the CPU up');
    });

    test('low battery: nothing runs; plugging in starts it', () async {
      final power = FakePhonePower(low);
      final harness = await android(power: power);
      await settle();

      expect(harness.recognizer!.calls, 0);
      expect(harness.controller.transcriptionPermit,
          TranscriptionPermit.batteryLow);
      expect(harness.controller.transcriptionQueue, hasLength(3));
      expect(power.listening, isTrue, reason: 'waiting for a charger');

      power.plug();
      await settle();

      expect(harness.recognizer!.calls, 3);
      expect(harness.controller.transcriptionPermit,
          TranscriptionPermit.charging);
      expect(power.listening, isFalse, reason: 'nothing left to wait for');
    });

    test('battery saver or heat pause it too', () async {
      final saver = FakePhonePower(const PhonePowerState(
        batteryPercent: 90,
        onExternalPower: false,
        batterySaver: true,
      ));
      final a = await android(power: saver);
      await settle();
      expect(a.recognizer!.calls, 0);
      expect(a.controller.transcriptionPermit, TranscriptionPermit.batterySaver);

      final hot = FakePhonePower(const PhonePowerState(
        onExternalPower: true,
        thermal: ThermalState.severe,
      ));
      final b = await android(power: hot);
      await settle();
      expect(b.recognizer!.calls, 0);
      expect(b.controller.transcriptionPermit, TranscriptionPermit.tooHot);
    });

    test('always-listening off: nothing keeps the process, so it waits for '
        'the app, and the battery is not even read', () async {
      final power = FakePhonePower();
      final harness = await android(power: power, listening: false);
      await settle();

      expect(harness.recognizer!.calls, 0);
      expect(harness.controller.transcriptionPermit,
          TranscriptionPermit.noKeepAlive);
      expect(power.reads, 0);
      expect(power.listening, isFalse);

      await harness.controller.appForegrounded();
      await settle();
      expect(harness.recognizer!.calls, 3);
    });

    test('on screen it runs whatever the battery says', () async {
      final harness = await android(power: FakePhonePower(low), initialise: false);
      await harness.controller.appForegrounded();
      await harness.controller.initialise();
      await settle();
      expect(harness.recognizer!.calls, 3);
      expect(harness.controller.transcriptionPermit,
          TranscriptionPermit.foreground);
    });

    test('leaving the app mid-job does not stop it when the policy allows',
        () async {
      final recognizer = ScriptedRecognizer()..gate = Completer<void>();
      final harness = await android(recognizer: recognizer, initialise: false);
      await harness.controller.appForegrounded();
      await harness.controller.initialise();
      await settle();
      expect(harness.controller.transcribingPath, pathAt(eleven));

      await harness.controller.appBackgrounded();
      await settle();

      expect(recognizer.cancelled, isFalse);
      expect(harness.controller.transcribingPath, pathAt(eleven));

      recognizer.gate!.complete();
      await settle();
      expect(recognizer.audioPaths,
          <String>[pathAt(eleven), pathAt(ten), pathAt(nine)]);
    });

    test('leaving the app mid-job on a low battery pauses it and frees the '
        'model', () async {
      final recognizer = ScriptedRecognizer()..gate = Completer<void>();
      final harness = await android(
        recognizer: recognizer,
        power: FakePhonePower(low),
        initialise: false,
      );
      await harness.controller.appForegrounded();
      await harness.controller.initialise();
      await settle();

      await harness.controller.appBackgrounded();
      await settle();

      expect(recognizer.cancelled, isTrue);
      expect(recognizer.releaseRequests, greaterThan(0));
      expect(harness.controller.isTranscribing, isFalse);
      expect(harness.controller.transcriptionQueue.first, pathAt(eleven));
    });

    test('a running job re-reads the phone and pauses when it is unplugged, '
        'then resumes on the charger', () async {
      final power = FakePhonePower(const PhonePowerState(onExternalPower: true));
      final recognizer = ScriptedRecognizer()..gate = Completer<void>();
      final harness = await android(
        recognizer: recognizer,
        power: power,
        recheck: const Duration(milliseconds: 20),
      );
      await settle();
      expect(harness.controller.transcribingPath, pathAt(eleven));

      power.state = low;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(recognizer.cancelled, isTrue);
      expect(harness.controller.isTranscribing, isFalse);
      expect(harness.controller.transcriptionQueue.first, pathAt(eleven));
      expect(harness.controller.transcriptionPermit,
          TranscriptionPermit.batteryLow);
      expect(recognizer.releaseRequests, greaterThan(0));

      recognizer.gate = null;
      power.plug();
      await settle();
      expect(recognizer.audioPaths.sublist(1),
          <String>[pathAt(eleven), pathAt(ten), pathAt(nine)]);
    });

    test('opening the app stops waiting for the charger', () async {
      final power = FakePhonePower(low);
      final harness = await android(power: power);
      await settle();
      expect(power.listening, isTrue);

      await harness.controller.appForegrounded();
      await settle();
      expect(power.listening, isFalse);
      expect(harness.recognizer!.calls, 3);
    });

    test('teardown frees the model', () async {
      final harness = await android();
      await settle();
      final before = harness.recognizer!.releaseRequests;
      await harness.controller.teardown();
      expect(harness.recognizer!.releaseRequests, greaterThan(before));
    });
  });
}
