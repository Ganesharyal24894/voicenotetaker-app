import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/background_task_plan.dart';
import 'package:voicenotetaker_app/model/background_transcription_policy.dart';
import 'package:voicenotetaker_app/model/phone_power.dart';
import 'package:voicenotetaker_app/services/library_service.dart';

import 'view/harness.dart';

/// The iPhone's half of background transcription: asking iOS for a
/// `BGProcessingTask` window, spending one when it is granted, and handing it
/// back the moment iOS asks.
///
/// An iPhone keeps this app alive for Bluetooth and nothing else, so a queued
/// transcript cannot simply carry on the way it does on Android. The app asks
/// for a window instead; iOS picks its own moment, or never. Every rule here
/// is written so that "never" costs the user nothing but a wait.
void main() {
  setUpAll(registerViewFallbacks);

  final nine = DateTime(2026, 9, 14, 9);
  final ten = DateTime(2026, 9, 14, 10);
  final eleven = DateTime(2026, 9, 14, 11);

  String pathAt(DateTime at) =>
      '${ViewHarness.recordingsDirectory}/${RecordingNaming.fileName(at)}';

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  /// Built as the iPhone app is: no platform keep-alive for transcription,
  /// but a background driver that can grant a window.
  Future<({ViewHarness harness, FakeBackgroundMode background})> iphone({
    ScriptedRecognizer? recognizer,
    FakePhonePower? power,
    bool modelInstalled = true,
  }) async {
    final phone = power ?? FakePhonePower();
    final background = FakeBackgroundMode();
    final harness = ViewHarness(
      recognizer: recognizer ?? ScriptedRecognizer(),
      phonePower: phone,
      backgroundMode: background,
      speechModelInstalled: modelInstalled,
      // The iPhone: nothing keeps this isolate running off screen.
      backgroundTranscription: false,
    );
    addTearDown(() async {
      await harness.dispose();
      await phone.close();
    });
    harness.fileStore.files[
            '${ViewHarness.recordingsDirectory}/continuous-settings.json'] =
        utf8.encode(jsonEncode(<String, Object?>{
      'version': 1,
      'enabled': true,
    }));
    for (final at in <DateTime>[nine, eleven, ten]) {
      await harness.seedRecording(at: at, length: const Duration(seconds: 20));
    }
    await harness.controller.initialise();
    return (harness: harness, background: background);
  }

  group('asking for a window', () {
    test('leaving the screen with notes to transcribe asks for one', () async {
      final phone = await iphone();
      await phone.harness.controller.appForegrounded();
      await settle();
      phone.background.workRequests.clear();

      await phone.harness.controller.appBackgrounded();
      await settle();

      // The queue drained while the app was on screen, so there is nothing
      // left to ask for - the request is withdrawn instead.
      expect(phone.background.workRequests.last, isNull);
    });

    test('work still queued asks, on a charger and without the network',
        () async {
      // A battery too low for the policy, so nothing runs on screen either and
      // the queue is still there when the app leaves.
      final phone = await iphone(
        power: FakePhonePower(const PhonePowerState(
          batteryPercent: 10,
          onExternalPower: false,
          batterySaver: false,
        )),
        recognizer: ScriptedRecognizer()..texts = <int, String>{0: 'हाँ'},
      );
      await phone.harness.controller.appBackgrounded();
      await settle();
      phone.background.workRequests.clear();

      await phone.harness.controller.appForegrounded();
      await phone.harness.controller.appBackgrounded();
      await settle();

      final request = phone.background.workRequests.last;
      expect(request, isNotNull);
      expect(request!.requiresExternalPower, isTrue);
      expect(request.requiresNetworkConnectivity, isFalse);
      expect(request.earliestDelay, BackgroundTaskPlan.earliestDelay);
    });

    test('no speech model installed: nothing is asked for', () async {
      final phone = await iphone(modelInstalled: false);
      await phone.harness.controller.appForegrounded();
      await phone.harness.controller.appBackgrounded();
      await settle();

      expect(
        phone.background.workRequests.where((r) => r != null),
        isEmpty,
        reason: 'a window with nothing that could use it',
      );
    });
  });

  group('spending a window', () {
    test('nothing runs off screen until one is granted', () async {
      final phone = await iphone();
      await settle();

      // Not even planned: off screen with nothing keeping the process alive,
      // the library is not read and no decision is taken.
      expect(phone.harness.recognizer!.calls, 0);
      expect(phone.harness.controller.transcriptionQueue, isEmpty);
      expect(phone.harness.controller.transcriptionPermit, isNull);

      // And it is not because there was nothing to do.
      await phone.background.grantWindow();
      await settle();
      expect(phone.harness.recognizer!.calls, 3);
    });

    test('a granted window runs the queue, newest first', () async {
      final phone = await iphone();
      await settle();

      await phone.background.grantWindow();
      await settle();

      expect(
        phone.harness.recognizer!.audioPaths,
        <String>[pathAt(eleven), pathAt(ten), pathAt(nine)],
      );
      expect(phone.harness.controller.transcriptionQueue, isEmpty);
    });

    test('the window is not handed back until the work is done', () async {
      final phone = await iphone();
      await settle();

      var finished = false;
      final window = phone.background.grantWindow().then((_) {
        finished = true;
      });
      // Nothing has been awaited yet, so the run cannot have completed.
      expect(finished, isFalse);
      await window;

      expect(finished, isTrue);
      expect(phone.harness.recognizer!.calls, 3);
    });

    test('the same power policy applies inside a window', () async {
      final phone = await iphone(
        power: FakePhonePower(const PhonePowerState(
          batteryPercent: 10,
          onExternalPower: false,
          batterySaver: false,
        )),
      );
      await settle();

      await phone.background.grantWindow();
      await settle();

      expect(phone.harness.recognizer!.calls, 0);
      expect(phone.harness.controller.transcriptionPermit,
          TranscriptionPermit.batteryLow);
      expect(phone.harness.controller.transcriptionQueue, hasLength(3));
    });

    test('a hot phone is not transcribed on, window or not', () async {
      final phone = await iphone(
        power: FakePhonePower(const PhonePowerState(
          batteryPercent: 100,
          onExternalPower: true,
          batterySaver: false,
          thermal: ThermalState.severe,
        )),
      );
      await settle();

      await phone.background.grantWindow();
      await settle();

      expect(phone.harness.recognizer!.calls, 0);
      expect(phone.harness.controller.transcriptionPermit,
          TranscriptionPermit.tooHot);
    });

    test('the window ends where it started: nothing keeps running after it',
        () async {
      final phone = await iphone();
      await settle();
      await phone.background.grantWindow();
      await settle();

      // Back to "nothing keeps this process alive": the next time the app
      // leaves the screen the answer is noKeepAlive again, not batteryOk.
      expect(phone.harness.controller.transcriptionQueue, isEmpty);
      await phone.harness.controller.appForegrounded();
      await phone.harness.controller.appBackgrounded();
      await settle();
      expect(phone.harness.controller.transcriptionPermit,
          TranscriptionPermit.noKeepAlive);
    });

    test('the model is freed when the window closes', () async {
      final phone = await iphone();
      await settle();

      await phone.background.grantWindow();
      await settle();

      expect(phone.harness.recognizer!.releaseRequests, greaterThan(0));
    });

    test('work left over asks for another window; a drained queue withdraws',
        () async {
      final phone = await iphone();
      await settle();
      phone.background.workRequests.clear();

      await phone.background.grantWindow();
      await settle();

      expect(phone.background.workRequests.last, isNull,
          reason: 'nothing left to do, so nothing to wake the phone for');
    });

    test('a window granted while the app is on screen is left alone',
        () async {
      final phone = await iphone();
      await phone.harness.controller.appForegrounded();
      await settle();
      final calls = phone.harness.recognizer!.calls;

      await phone.background.grantWindow();
      await settle();

      expect(phone.harness.recognizer!.calls, calls,
          reason: 'the foreground queue already ran these');
    });
  });

  group('giving a window back', () {
    test('expiring stops the run and keeps the queue', () async {
      final phone = await iphone(
        recognizer: ScriptedRecognizer()..texts = <int, String>{0: 'हाँ'},
      );
      await settle();

      final window = phone.background.grantWindow();
      // iOS wants the window back before the run has finished.
      phone.background.expireWindow();
      await window;
      await settle();

      // Whatever was not done is still queued for the next window or the next
      // time the app is opened - never lost.
      expect(
        phone.harness.recognizer!.calls +
            phone.harness.controller.transcriptionQueue.length,
        greaterThanOrEqualTo(3),
      );
    });

    test('expiring with no window open changes nothing', () async {
      final phone = await iphone();
      await settle();

      phone.background.expireWindow();
      await settle();

      // Nothing was running, and the next window still works.
      expect(phone.harness.recognizer!.calls, 0);
      await phone.background.grantWindow();
      await settle();
      expect(phone.harness.recognizer!.calls, 3);
    });
  });

  group('Android is not asked for windows', () {
    test('its foreground service is the window', () async {
      final phone = FakePhonePower();
      final background = FakeBackgroundMode();
      final harness = ViewHarness(
        recognizer: ScriptedRecognizer(),
        phonePower: phone,
        backgroundMode: background,
        backgroundTranscription: true,
      );
      addTearDown(() async {
        await harness.dispose();
        await phone.close();
      });
      await harness.seedRecording(at: nine, length: const Duration(seconds: 20));
      await harness.controller.initialise();
      await harness.controller.appForegrounded();
      await harness.controller.appBackgrounded();
      await settle();

      expect(background.workRequests, isEmpty);
    });
  });
}
