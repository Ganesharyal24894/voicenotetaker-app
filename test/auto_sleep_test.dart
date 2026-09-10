import 'dart:typed_data';

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

    test('bit 0 carries the flag', () {
      expect(AutoSleep.fromBytes(<int>[0x01]), isTrue);
      expect(AutoSleep.fromBytes(<int>[0x00]), isFalse);
    });

    test('writing sends exactly one byte, 0x01 or 0x00', () {
      expect(AutoSleep.toBytes(true), Uint8List.fromList(<int>[0x01]));
      expect(AutoSleep.toBytes(false), Uint8List.fromList(<int>[0x00]));
    });

    test('any length but one byte is rejected', () {
      expect(() => AutoSleep.fromBytes(<int>[]), throwsFormatException);
      expect(
        () => AutoSleep.fromBytes(<int>[0x01, 0x00]),
        throwsFormatException,
      );
    });

    test('reserved bits set means a firmware this build cannot read', () {
      // The firmware rejects these on write; on read they would mean the flag
      // has grown a meaning we do not know, so they are not guessed at.
      expect(() => AutoSleep.fromBytes(<int>[0x03]), throwsFormatException);
      expect(() => AutoSleep.fromBytes(<int>[0xFF]), throwsFormatException);
      expect(() => AutoSleep.fromBytes(<int>[0x80]), throwsFormatException);
    });
  });

  group('reading on connect', () {
    test('nothing is claimed before a device is connected', () {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      expect(harness.controller.autoSleepAvailable, isFalse);
    });

    test('0x00 from the device reads as off', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => AutoSleep.fromBytes(<int>[0x00]));

      await harness.controller.connect(knownDevice);

      expect(harness.controller.autoSleepAvailable, isTrue);
      expect(harness.controller.autoSleepEnabled, isFalse);
    });

    test('0x01 from the device reads as on', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => AutoSleep.fromBytes(<int>[0x01]));

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
          reason: 'firmware without fe04 must not be reported as "off"');
      // And it is not an app error: the recorder still works without it.
      expect(harness.controller.phase, AppPhase.connected,
          reason: 'a missing optional setting is not an app failure');
      expect(harness.controller.isConnected, isTrue);
    });

    test('disconnecting drops the reading rather than keeping it', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => true);

      await harness.controller.connect(knownDevice);
      expect(harness.controller.autoSleepAvailable, isTrue);

      await harness.controller.disconnect();

      expect(harness.controller.autoSleepAvailable, isFalse);
    });
  });

  group('writing', () {
    test('enabling sends true, disabling sends false', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => false);

      await harness.controller.connect(knownDevice);

      await harness.controller.setAutoSleep(true);
      verify(() => harness.transport.setAutoSleep(knownDevice.id, true))
          .called(1);
      expect(harness.controller.autoSleepEnabled, isTrue);

      await harness.controller.setAutoSleep(false);
      verify(() => harness.transport.setAutoSleep(knownDevice.id, false))
          .called(1);
      expect(harness.controller.autoSleepEnabled, isFalse);
    });

    test('the byte on the wire is 0x01 to enable and 0x00 to disable', () {
      // The driver is the only place that turns the flag into bytes, and it
      // does it through [AutoSleep]; this pins the mapping the firmware
      // validates.
      expect(AutoSleep.toBytes(true).single, 0x01);
      expect(AutoSleep.toBytes(false).single, 0x00);
      expect(AutoSleep.toBytes(true), hasLength(1));
      expect(AutoSleep.toBytes(false), hasLength(1));
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

      verifyNever(() => harness.transport.setAutoSleep(any(), any()));
      expect(harness.controller.autoSleepAvailable, isFalse);
    });

    test('nothing is written with no device connected', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.setAutoSleep(true);

      verifyNever(() => harness.transport.setAutoSleep(any(), any()));
    });

    test('a write that fails leaves the shown state as the device left it',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => false);
      when(() => harness.transport.setAutoSleep(any(), any()))
          .thenThrow(const BleTransportException('write failed'));

      await harness.controller.connect(knownDevice);
      await harness.controller.setAutoSleep(true);

      expect(harness.controller.autoSleepEnabled, isFalse,
          reason: 'the device kept its old setting, so the app must too');
      expect(harness.controller.autoSleepAvailable, isTrue);
      expect(harness.controller.errorMessage, 'write failed');
    });
  });
}