
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/auto_sleep.dart';
import 'package:voicenotetaker_app/model/device_profile.dart';

import 'view/harness.dart';

/// The `fe04` auto-sleep flag: its wire format, and the controller's rule that
/// an unread flag is UNKNOWN rather than off.
///
/// The device keeps this in flash, so it survives a reboot and the app can
/// never derive it - only read it. Every test here exists to stop a default
/// creeping in to stand where a real reading should be.
void main() {
  setUpAll(registerViewFallbacks);

  group('wire format', () {
    test('the characteristic is the one the firmware publishes', () {
      expect(
        DeviceProfile.autoSleepCharacteristicUuid,
        '6e40fe04-b5a3-f393-e0a9-e50e24dcca9e',
      );
    });

    test('two bytes carry the duration in force', () {
      expect(
        AutoSleep.fromBytes(<int>[0x00, 0x00]),
        const AutoSleepSetting(enabled: false, duration: AutoSleepDuration.off),
      );
      expect(
        AutoSleep.fromBytes(<int>[0x01, 0x01]).duration,
        AutoSleepDuration.seconds30,
      );
      expect(AutoSleep.fromBytes(<int>[0x01, 0x02]).duration, AutoSleepDuration.minute1);
      expect(AutoSleep.fromBytes(<int>[0x01, 0x03]).duration, AutoSleepDuration.minutes2);
      expect(AutoSleep.fromBytes(<int>[0x01, 0x04]).duration, AutoSleepDuration.minutes5);
    });

    test('writing a duration sends [flags, code] with bit 0 = code != 0', () {
      expect(AutoSleep.durationToBytes(AutoSleepDuration.off), <int>[0x00, 0x00]);
      expect(AutoSleep.durationToBytes(AutoSleepDuration.seconds30), <int>[0x01, 0x01]);
      expect(AutoSleep.durationToBytes(AutoSleepDuration.minute1), <int>[0x01, 0x02]);
      expect(AutoSleep.durationToBytes(AutoSleepDuration.minutes2), <int>[0x01, 0x03]);
      expect(AutoSleep.durationToBytes(AutoSleepDuration.minutes5), <int>[0x01, 0x04]);
    });

    test('any length but two bytes is rejected', () {
      expect(() => AutoSleep.fromBytes(<int>[]), throwsFormatException);
      expect(() => AutoSleep.fromBytes(<int>[0x01]), throwsFormatException);
      expect(
        () => AutoSleep.fromBytes(<int>[0x01, 0x01, 0x00]),
        throwsFormatException,
      );
    });

    test('reserved bits, unknown codes and disagreeing flags are refused', () {
      // The firmware rejects these on write; on read they would mean the
      // setting has grown a meaning we do not know, so they are not guessed at.
      expect(() => AutoSleep.fromBytes(<int>[0x03, 0x01]), throwsFormatException);
      expect(() => AutoSleep.fromBytes(<int>[0xFF, 0x01]), throwsFormatException);
      expect(() => AutoSleep.fromBytes(<int>[0x80, 0x00]), throwsFormatException);
      expect(() => AutoSleep.fromBytes(<int>[0x01, 0x05]), throwsFormatException);
      expect(() => AutoSleep.fromBytes(<int>[0x01, 0x00]), throwsFormatException);
      expect(() => AutoSleep.fromBytes(<int>[0x00, 0x02]), throwsFormatException);
    });
  });

  group('reading on connect', () {
    test('nothing is claimed before a device is connected', () {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      expect(harness.controller.autoSleepAvailable, isFalse);
    });

    test('[0x00, 0x00] from the device reads as off', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => AutoSleep.fromBytes(<int>[0x00, 0x00]));

      await harness.controller.connect(knownDevice);

      expect(harness.controller.autoSleepAvailable, isTrue);
      expect(harness.controller.autoSleepEnabled, isFalse);
    });

    test('[0x01, 0x01] from the device reads as on', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => AutoSleep.fromBytes(<int>[0x01, 0x01]));

      await harness.controller.connect(knownDevice);

      expect(harness.controller.autoSleepAvailable, isTrue);
      expect(harness.controller.autoSleepEnabled, isTrue);

      // Read from the device that was connected, not from anywhere else.
      verify(() => harness.transport.readAutoSleep(knownDevice.id)).called(1);
    });

    test('a failed read leaves the setting unknown, not off', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any())).thenThrow(
        const BleTransportException('could not read the auto-sleep setting'),
      );

      await harness.controller.connect(knownDevice);

      expect(harness.controller.autoSleepAvailable, isFalse,
          reason: 'a recorder that did not answer is not the same as "off"');
      // And it is not an app error: the recorder still works without it.
      expect(harness.controller.phase, AppPhase.connected,
          reason: 'a missing optional setting is not an app failure');
      expect(harness.controller.isConnected, isTrue);
    });

    test('disconnecting drops the reading rather than keeping it', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any())).thenAnswer(
        (_) async => const AutoSleepSetting(
          enabled: true,
          duration: AutoSleepDuration.seconds30,
        ),
      );

      await harness.controller.connect(knownDevice);
      expect(harness.controller.autoSleepAvailable, isTrue);

      await harness.controller.disconnect();

      expect(harness.controller.autoSleepAvailable, isFalse);
    });
  });

  group('writing', () {
    test('enabling with nothing chosen picks the shortest option', () async {
      // `fe04` takes a duration, so "on" has to name one. The recorder's own
      // default is the shortest, and so is this.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.connect(knownDevice);

      await harness.controller.setAutoSleep(true);
      verify(() => harness.transport.setAutoSleepDuration(
          knownDevice.id, AutoSleepDuration.seconds30)).called(1);
      expect(harness.controller.autoSleepEnabled, isTrue);

      await harness.controller.setAutoSleep(false);
      verify(() => harness.transport
              .setAutoSleepDuration(knownDevice.id, AutoSleepDuration.off))
          .called(1);
      expect(harness.controller.autoSleepEnabled, isFalse);
    });

    test('enabling keeps the duration already in force', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any())).thenAnswer(
        (_) async => const AutoSleepSetting(
          enabled: true,
          duration: AutoSleepDuration.minutes5,
        ),
      );
      await harness.controller.connect(knownDevice);

      await harness.controller.setAutoSleep(false);
      await harness.controller.setAutoSleep(true);

      verify(() => harness.transport
              .setAutoSleepDuration(knownDevice.id, AutoSleepDuration.minutes5))
          .called(1);
    });

    test('the bytes on the wire are [flags, code]', () {
      // The driver is the only place that turns the setting into bytes, and it
      // does it through [AutoSleep]; this pins the mapping the firmware
      // validates.
      expect(AutoSleep.durationToBytes(AutoSleepDuration.off), <int>[0x00, 0x00]);
      expect(AutoSleep.durationToBytes(AutoSleepDuration.seconds30),
          <int>[0x01, 0x01]);
      expect(AutoSleep.durationToBytes(AutoSleepDuration.off), hasLength(2));
    });

    test('nothing is written when the device never reported the flag',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any())).thenThrow(
        const BleTransportException('no such characteristic'),
      );

      await harness.controller.connect(knownDevice);
      await harness.controller.setAutoSleep(true);

      verifyNever(() => harness.transport.setAutoSleepDuration(any(), any()));
      expect(harness.controller.autoSleepAvailable, isFalse);
    });

    test('nothing is written with no device connected', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.setAutoSleep(true);

      verifyNever(() => harness.transport.setAutoSleepDuration(any(), any()));
    });

    test('a write that fails leaves the shown state as the device left it',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.setAutoSleepDuration(any(), any()))
          .thenThrow(const BleTransportException('write failed'));

      await harness.controller.connect(knownDevice);
      await harness.controller.setAutoSleep(true);

      expect(harness.controller.autoSleepEnabled, isFalse,
          reason: 'the device kept its old setting, so the app must too');
      expect(harness.controller.autoSleepAvailable, isTrue);
      expect(harness.controller.errorMessage, 'Could not change auto-sleep.');
    });
  });

  group('durations', () {
    const oneMinute = AutoSleepSetting(
      enabled: true,
      duration: AutoSleepDuration.minute1,
    );

    test('the duration read back is the one shown', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => oneMinute);

      await harness.controller.connect(knownDevice);
      expect(harness.controller.autoSleepDuration, AutoSleepDuration.minute1);

      final silent = ViewHarness();
      addTearDown(silent.dispose);
      when(() => silent.transport.readAutoSleep(any())).thenThrow(
        const BleTransportException('could not read the auto-sleep setting'),
      );
      await silent.controller.connect(knownDevice);
      expect(silent.controller.autoSleepDuration, isNull,
          reason: 'nothing read means nothing to show');
    });

    test('choosing one writes the two-byte form and shows it at once',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => oneMinute);
      await harness.controller.connect(knownDevice);

      final changed = await harness.controller
          .setAutoSleepDuration(AutoSleepDuration.minutes5);

      expect(changed, isTrue);
      verify(() => harness.transport
              .setAutoSleepDuration(knownDevice.id, AutoSleepDuration.minutes5))
          .called(1);
      expect(harness.controller.autoSleepDuration, AutoSleepDuration.minutes5);
      expect(harness.controller.autoSleepEnabled, isTrue);

      await harness.controller.setAutoSleepDuration(AutoSleepDuration.off);
      expect(harness.controller.autoSleepEnabled, isFalse);
    });

    test('a refused write puts the old choice back and says it failed',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => oneMinute);
      when(() => harness.transport.setAutoSleepDuration(any(), any()))
          .thenThrow(const BleTransportException('ATT 0x13'));
      await harness.controller.connect(knownDevice);

      final seen = <AutoSleepDuration?>[];
      harness.controller.addListener(
        () => seen.add(harness.controller.autoSleepDuration),
      );
      final changed = await harness.controller
          .setAutoSleepDuration(AutoSleepDuration.seconds30);

      expect(changed, isFalse);
      expect(seen.first, AutoSleepDuration.seconds30, reason: 'optimistic');
      expect(harness.controller.autoSleepDuration, AutoSleepDuration.minute1);
      expect(harness.controller.errorMessage, isNull,
          reason: 'the screen says it in plain words, not the error slot');
    });

    test('nothing is written with no link, or when nothing was read', () async {
      final none = ViewHarness();
      addTearDown(none.dispose);
      expect(
        await none.controller.setAutoSleepDuration(AutoSleepDuration.minute1),
        isFalse,
        reason: 'no link',
      );

      final silent = ViewHarness();
      addTearDown(silent.dispose);
      when(() => silent.transport.readAutoSleep(any())).thenThrow(
        const BleTransportException('could not read the auto-sleep setting'),
      );
      await silent.controller.connect(knownDevice);
      expect(
        await silent.controller.setAutoSleepDuration(AutoSleepDuration.minute1),
        isFalse,
        reason: 'writing a value the app never read would be a guess',
      );
      verifyNever(() => silent.transport.setAutoSleepDuration(any(), any()));
      verifyNever(() => none.transport.setAutoSleepDuration(any(), any()));
    });

    test('turning it on shows the duration it was turned on with', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any())).thenAnswer(
        (_) async => const AutoSleepSetting(
          enabled: false,
          duration: AutoSleepDuration.off,
        ),
      );
      await harness.controller.connect(knownDevice);

      await harness.controller.setAutoSleep(true);

      verify(() => harness.transport.setAutoSleepDuration(
          knownDevice.id, AutoSleepDuration.seconds30)).called(1);
      expect(harness.controller.autoSleepDuration, AutoSleepDuration.seconds30);
    });
  });
}
