import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/drivers/haptics.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/not_saving_alert.dart';
import 'package:voicenotetaker_app/model/notes_saving.dart';

import '../view/harness.dart';

/// The not-saving alert at the controller: the buzz, the notification text,
/// and the cases that must stay quiet.
void main() {
  setUpAll(registerViewFallbacks);

  const grace = Duration(milliseconds: 60);
  Future<void> wait([Duration d = const Duration(milliseconds: 20)]) =>
      Future<void>.delayed(d);

  Future<(ViewHarness, FakeBackgroundMode, FakeHaptics)> listening() async {
    final background = FakeBackgroundMode();
    final haptics = FakeHaptics();
    final harness = ViewHarness(
      backgroundMode: background,
      haptics: haptics,
      notSavingAlert: NotSavingAlertPolicy(grace: grace),
    )..captureSupported = true;
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    await harness.controller.connect(knownDevice);
    await harness.controller.setContinuousEnabled(true);
    return (harness, background, haptics);
  }

  void failReconnects(ViewHarness harness) {
    when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
        .thenThrow(const BleTransportException('out of range'));
  }

  test('saving: no alert, the notification is the usual one', () async {
    final (harness, background, haptics) = await listening();
    await wait(grace * 2);

    expect(harness.controller.notesSaving, NotesSaving.saving);
    expect(haptics.buzzes, isEmpty);
    expect(background.titles.last, 'voiceNotetaker');
    expect(background.texts.last, 'Always listening');
  });

  test('disconnected for the grace period: one buzz and the notification says '
      'notes are not saving; back: one short buzz and back to normal', () async {
    final (harness, background, haptics) = await listening();
    failReconnects(harness);

    harness.link.add(BleConnectionStatus.disconnected);
    await wait();
    expect(harness.controller.notesSaving, NotesSaving.disconnected);
    expect(haptics.buzzes, isEmpty, reason: 'not before the grace period');

    await wait(grace * 2);
    expect(haptics.buzzes, <BuzzPattern>[BuzzPattern.notSaving]);
    expect(harness.controller.notSavingAlerting, isTrue);
    expect(background.titles.last, AppController.notSavingTitle);
    expect(background.texts.last, 'Recorder disconnected');

    when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
        .thenAnswer((_) async {});
    await harness.controller.connect(knownDevice);
    await wait();
    expect(haptics.buzzes, <BuzzPattern>[BuzzPattern.notSaving, BuzzPattern.resumed]);
    expect(harness.controller.notSavingAlerting, isFalse);
    expect(background.titles.last, 'voiceNotetaker');
  });

  test('muted by the wearer: shown, never buzzed', () async {
    final (harness, background, haptics) = await listening();

    harness.capture.add(
      const CaptureFlags(muted: true, speechOpen: false, gateEnabled: true),
    );
    await wait(grace * 3);

    expect(harness.controller.notesSaving, NotesSaving.muted);
    expect(haptics.buzzes, isEmpty);
    expect(background.titles.last, 'voiceNotetaker');
  });

  test('mic off to save battery is an alert', () async {
    final (harness, background, haptics) = await listening();

    harness.capture.add(
      const CaptureFlags(
        muted: false,
        speechOpen: false,
        gateEnabled: true,
        micOff: true,
      ),
    );
    await wait(grace * 3);

    expect(haptics.buzzes, <BuzzPattern>[BuzzPattern.notSaving]);
    expect(background.texts.last, 'Mic off to save battery');
  });

  test('turning always listening off ends it silently, and nothing runs after',
      () async {
    final (harness, background, haptics) = await listening();
    failReconnects(harness);
    harness.link.add(BleConnectionStatus.disconnected);
    await wait(grace * 3);
    expect(haptics.buzzes, hasLength(1));

    await harness.controller.setContinuousEnabled(false);
    await wait(grace * 3);

    expect(haptics.buzzes, hasLength(1), reason: 'no resume buzz for "off"');
    expect(harness.controller.notSavingAlerting, isFalse);
    expect(background.running, isFalse);
  });

  test('never alerts while always listening is off', () async {
    final haptics = FakeHaptics();
    final harness = ViewHarness(
      backgroundMode: FakeBackgroundMode(),
      haptics: haptics,
      notSavingAlert: NotSavingAlertPolicy(grace: grace),
    );
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    await harness.controller.connect(knownDevice);
    harness.link.add(BleConnectionStatus.disconnected);
    await wait(grace * 3);

    expect(haptics.buzzes, isEmpty);
  });
}
