import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/notes_saving.dart';

import '../view/harness.dart';

/// Privacy mode from the app: which command goes to the recorder, when the
/// app may send it, and that the state is the recorder's word, not the tap's.
void main() {
  setUpAll(registerViewFallbacks);

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  Future<ViewHarness> connected({bool listening = true}) async {
    final harness = ViewHarness(backgroundMode: FakeBackgroundMode())
      ..captureSupported = true;
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    await harness.controller.connect(knownDevice);
    if (listening) await harness.controller.setContinuousEnabled(true);
    clearInteractions(harness.transport);
    addTearDown(() => harness.controller.setContinuousEnabled(false));
    return harness;
  }

  const privacyOn =
      CaptureFlags(privacyMode: true, speechOpen: false, gateEnabled: true);
  const privacyOff =
      CaptureFlags(privacyMode: false, speechOpen: false, gateEnabled: true);

  test('turning it on sends mute, and off sends unmute', () async {
    final harness = await connected();

    await harness.controller.turnPrivacyModeOn();
    verify(() => harness.transport
        .writeCapture(knownDevice.id, CaptureCommand.mute)).called(1);

    await harness.controller.turnPrivacyModeOff();
    verify(() => harness.transport
        .writeCapture(knownDevice.id, CaptureCommand.unmute)).called(1);
  });

  test('the state is what the recorder reports, not what was sent', () async {
    final harness = await connected();

    await harness.controller.turnPrivacyModeOn();
    await settle();
    expect(harness.controller.notesSaving, NotesSaving.saving);

    harness.capture.add(privacyOn);
    await settle();
    expect(harness.controller.notesSaving, NotesSaving.privacyMode);

    await harness.controller.turnPrivacyModeOff();
    await settle();
    expect(harness.controller.notesSaving, NotesSaving.privacyMode);

    harness.capture.add(privacyOff);
    await settle();
    expect(harness.controller.notesSaving, NotesSaving.saving);
  });

  test('it can be set only while always listening runs on a live link',
      () async {
    final off = await connected(listening: false);
    expect(off.controller.canSetPrivacyMode, isFalse);
    await off.controller.turnPrivacyModeOn();
    verifyNever(() => off.transport.writeCapture(any(), any()));

    final on = await connected();
    expect(on.controller.canSetPrivacyMode, isTrue);
  });

  test('nothing is sent with no recorder connected', () async {
    final harness = ViewHarness(backgroundMode: FakeBackgroundMode());
    addTearDown(harness.dispose);
    await harness.controller.initialise();

    expect(harness.controller.canSetPrivacyMode, isFalse);
    await harness.controller.turnPrivacyModeOn();
    await harness.controller.turnPrivacyModeOff();
    verifyNever(() => harness.transport.writeCapture(any(), any()));
  });

  test('a write the recorder did not take changes nothing', () async {
    final harness = await connected();
    when(() => harness.transport.writeCapture(any(), CaptureCommand.mute))
        .thenThrow(const BleTransportException('gone'));

    await harness.controller.turnPrivacyModeOn();
    await settle();

    expect(harness.controller.notesSaving, NotesSaving.saving);
  });
}
