import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/drivers/haptics.dart';
import 'package:voicenotetaker_app/model/continuous_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/home_status.dart';
import 'package:voicenotetaker_app/model/not_saving_alert.dart';
import 'package:voicenotetaker_app/model/notes_saving.dart';
import 'package:voicenotetaker_app/model/reconnect_backoff.dart';
import 'package:voicenotetaker_app/model/recorder_sleep.dart';

import '../view/harness.dart';

/// The recorder going to sleep, at the controller: no buzz, plain words, and
/// no hunting for a device that is in System OFF.
void main() {
  setUpAll(registerViewFallbacks);

  const grace = Duration(milliseconds: 60);
  const retry = Duration(milliseconds: 40);
  Future<void> wait([Duration d = const Duration(milliseconds: 20)]) =>
      Future<void>.delayed(d);

  Future<(ViewHarness, FakeBackgroundMode, FakeHaptics)> listening({
    required LinkDropReason reason,
  }) async {
    final background = FakeBackgroundMode();
    final haptics = FakeHaptics();
    final harness = ViewHarness(
      backgroundMode: background,
      haptics: haptics,
      notSavingAlert: NotSavingAlertPolicy(grace: grace),
      asleepRetryDelay: retry,
    )..captureSupported = true;
    harness.dropReason = reason;
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    await harness.controller.connect(knownDevice);
    await harness.controller.setContinuousEnabled(true);
    return (harness, background, haptics);
  }

  /// Nothing answers: the recorder is in System OFF.
  void nothingAnswers(ViewHarness harness) {
    when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
        .thenThrow(const BleTransportException('no answer'));
    when(
      () => harness.transport.connect(
        any(),
        timeout: any(named: 'timeout'),
        waitForAdvertisement: any(named: 'waitForAdvertisement'),
      ),
    ).thenThrow(const BleTransportException('no answer'));
  }

  test('a clean drop with nothing answering reads as asleep, and says so',
      () async {
    final (harness, background, haptics) =
        await listening(reason: LinkDropReason.remoteTerminated);
    nothingAnswers(harness);

    harness.link.add(BleConnectionStatus.disconnected);
    await wait(grace * 4);

    expect(harness.controller.recorderAsleep, isTrue);
    expect(harness.controller.continuousStatus, ContinuousStatus.asleep);
    expect(harness.controller.notesSaving, NotesSaving.asleep);
    expect(
      HomeStatus.resolve(
        continuous: harness.controller.continuousStatus,
        connected: false,
        charging: false,
      ),
      const HomeStatus(
        'Recorder asleep — pick it up to wake it',
        HomeStatusTone.idle,
      ),
    );
    // The notification agrees, and it is not the alert.
    expect(background.titles.last, 'voiceNotetaker');
    expect(background.texts.last, 'Recorder asleep');
    expect(haptics.buzzes, isEmpty, reason: 'nobody is buzzed at 02:00');
    expect(harness.controller.notSavingAlerting, isFalse);
  });

  test('asleep is not a fault: no alert however long it lasts', () async {
    final (harness, background, haptics) =
        await listening(reason: LinkDropReason.remoteTerminated);
    nothingAnswers(harness);

    harness.link.add(BleConnectionStatus.disconnected);
    await wait(grace * 8);

    expect(haptics.buzzes, isEmpty);
    expect(background.titles, isNot(contains(AppController.notSavingTitle)));
  });

  test('a supervision timeout still buzzes: that one is real', () async {
    final (harness, background, haptics) =
        await listening(reason: LinkDropReason.supervisionTimeout);
    nothingAnswers(harness);

    harness.link.add(BleConnectionStatus.disconnected);
    await wait(grace * 4);

    expect(harness.controller.recorderAsleep, isFalse);
    expect(harness.controller.notesSaving, NotesSaving.disconnected);
    expect(haptics.buzzes, <BuzzPattern>[BuzzPattern.notSaving]);
    expect(background.titles.last, AppController.notSavingTitle);
    expect(background.texts.last, 'Recorder disconnected');
  });

  test('asleep stops the hunting: one standing wait instead of attempts',
      () async {
    final (harness, _, _) =
        await listening(reason: LinkDropReason.remoteTerminated);
    nothingAnswers(harness);

    harness.link.add(BleConnectionStatus.disconnected);
    await wait(grace * 4);

    // The ladder is abandoned for the sleeping wait.
    expect(harness.controller.scheduledReconnectDelay, retry);
    // And the attempt itself is the cheap kind: the platform waits for the
    // advertisement instead of the app driving the radio at nothing.
    verify(
      () => harness.transport.connect(
        any(),
        timeout: ReconnectBackoff.asleepAttemptTimeout,
        waitForAdvertisement: true,
      ),
    ).called(greaterThan(0));
  });

  test('picking it up wakes it: the standing wait connects and notes resume',
      () async {
    final (harness, background, haptics) =
        await listening(reason: LinkDropReason.remoteTerminated);
    nothingAnswers(harness);

    harness.link.add(BleConnectionStatus.disconnected);
    await wait(grace * 4);
    expect(harness.controller.recorderAsleep, isTrue);

    // Motion wakes the recorder: it reboots, advertises, and the standing
    // attempt resolves.
    when(
      () => harness.transport.connect(
        any(),
        timeout: any(named: 'timeout'),
        waitForAdvertisement: any(named: 'waitForAdvertisement'),
      ),
    ).thenAnswer((_) async {});
    await wait(retry * 4);

    expect(harness.controller.recorderAsleep, isFalse);
    expect(harness.controller.isConnected, isTrue);
    expect(harness.controller.notesSaving, NotesSaving.saving);
    expect(haptics.buzzes, isEmpty, reason: 'it was never an alert');
    expect(background.texts.last, 'Always listening');
  });
}
