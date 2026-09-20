import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/auto_sleep.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';

import 'view/harness.dart';

/// Ending the link on purpose.
///
/// The requirement these tests carry is "no stuck connected UI": after a
/// disconnect there must be nothing left that a screen could render as a live
/// connection - no device, no device name, no battery reading, no auto-sleep
/// answer, and no subscription still running against the radio.
void main() {
  setUpAll(registerViewFallbacks);

  test('with nothing connected it does nothing', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await harness.controller.disconnect();

    verifyNever(() => harness.transport.disconnect(any()));
    expect(harness.controller.phase, AppPhase.idle);
  });

  test('it goes through the transport for the device that was connected',
      () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.controller.connect(knownDevice);

    await harness.controller.disconnect();

    verify(() => harness.transport.disconnect(knownDevice.id)).called(1);
  });

  test('nothing is left that could render as connected', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readBattery(any())).thenAnswer(
      (_) async => const BatteryStatus(percent: 64, charging: true),
    );
    when(() => harness.transport.readAutoSleep(any()))
        .thenAnswer(
      (_) async => const AutoSleepSetting(
        enabled: true,
        duration: AutoSleepDuration.seconds30,
      ),
    );

    await harness.controller.connect(knownDevice);
    expect(harness.controller.isConnected, isTrue);

    await harness.controller.disconnect();

    expect(harness.controller.isConnected, isFalse);
    expect(harness.controller.connectedDevice, isNull);
    expect(harness.controller.phase, AppPhase.idle);
    expect(harness.controller.batteryAvailable, isFalse);
    expect(harness.controller.batteryPercent, isNull);
    expect(harness.controller.batteryCharging, isFalse);
    expect(harness.controller.autoSleepAvailable, isFalse);
    // The fe05 subscription is ended, not left feeding a dead screen.
    verify(() => harness.transport.unsubscribeBattery(knownDevice.id))
        .called(1);
  });

  test('a capture in progress is stopped before the link goes', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.controller.connect(knownDevice);
    await harness.controller.startRecording();
    expect(harness.controller.isRecording, isTrue);

    await harness.controller.disconnect();

    // The file was finished properly rather than cut off with the link.
    expect(harness.controller.isRecording, isFalse);
    expect(harness.controller.lastRecording, isNotNull);
    verifyInOrder(<Future<void> Function()>[
      () => harness.transport.unsubscribeFrames(knownDevice.id),
      () => harness.transport.disconnect(knownDevice.id),
    ]);
    expect(harness.controller.connectedDevice, isNull);
  });

  test('a transport failure is reported but still drops the connection',
      () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.disconnect(any()))
        .thenThrow(const BleTransportException('could not disconnect'));

    await harness.controller.connect(knownDevice);
    await harness.controller.disconnect();

    // The message is surfaced...
    expect(harness.controller.errorMessage, 'could not disconnect');
    // ...but the app does NOT keep claiming a connection the user dismissed.
    expect(harness.controller.connectedDevice, isNull);
    expect(harness.controller.isConnected, isFalse);
    expect(harness.controller.batteryAvailable, isFalse);
    expect(harness.controller.phase, AppPhase.idle);
  });

  test('a successful disconnect clears a stale error message', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.setAutoSleepDuration(any(), any()))
        .thenThrow(const BleTransportException('write failed'));

    await harness.controller.connect(knownDevice);
    await harness.controller.setAutoSleep(true);
    expect(harness.controller.errorMessage, 'Could not change auto-sleep.');

    await harness.controller.disconnect();

    expect(harness.controller.errorMessage, isNull);
  });

  test('reconnecting after a disconnect reads the device again', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await harness.controller.connect(knownDevice);
    await harness.controller.disconnect();
    await harness.controller.connect(knownDevice);

    expect(harness.controller.isConnected, isTrue);
    expect(harness.controller.batteryPercent, 76);
    verify(() => harness.transport.readBattery(knownDevice.id)).called(2);
    verify(() => harness.transport.subscribeBattery(knownDevice.id)).called(2);
  });
}
