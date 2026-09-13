import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/device_profile.dart';

import 'view/harness.dart';

/// The `fe05` battery characteristic: its wire format, and the controller's
/// rule that an unread battery is UNKNOWN rather than empty.
///
/// Every test here exists to stop a zero creeping in to stand where a real
/// measurement should be. `0%` is a fact about a flat cell; `0xFF`, a failed
/// read and firmware without `fe05` are three different facts, and none of
/// them is that one.
void main() {
  setUpAll(registerViewFallbacks);

  group('wire format', () {
    test('the characteristic is the one the firmware publishes', () {
      expect(
        DeviceProfile.batteryCharacteristicUuid,
        '6e40fe05-b5a3-f393-e0a9-e50e24dcca9e',
      );
    });

    test('byte 0 is the percentage', () {
      expect(BatteryStatus.fromBytes(<int>[0, 0x00]).percent, 0);
      expect(BatteryStatus.fromBytes(<int>[42, 0x00]).percent, 42);
      expect(BatteryStatus.fromBytes(<int>[100, 0x00]).percent, 100);
    });

    test('0xFF in byte 0 is UNKNOWN, and is not zero', () {
      final unknown = BatteryStatus.fromBytes(<int>[0xFF, 0x00]);
      expect(unknown.percent, isNull);
      expect(unknown.hasPercent, isFalse);

      // The distinction this whole class exists for.
      final empty = BatteryStatus.fromBytes(<int>[0, 0x00]);
      expect(empty.percent, 0);
      expect(empty.hasPercent, isTrue);
      expect(unknown, isNot(empty));
    });

    test('bit 0 of byte 1 is charging', () {
      expect(BatteryStatus.fromBytes(<int>[50, 0x01]).charging, isTrue);
      expect(BatteryStatus.fromBytes(<int>[50, 0x00]).charging, isFalse);
    });

    test('charging is readable even when the percentage is not', () {
      // A device that cannot measure the cell can still tell that power is in,
      // and that is worth showing.
      final status = BatteryStatus.fromBytes(<int>[0xFF, 0x01]);
      expect(status.percent, isNull);
      expect(status.charging, isTrue);
    });

    test('any length but two bytes is rejected', () {
      expect(() => BatteryStatus.fromBytes(<int>[]), throwsFormatException);
      expect(() => BatteryStatus.fromBytes(<int>[50]), throwsFormatException);
      expect(
        () => BatteryStatus.fromBytes(<int>[50, 0x00, 0x00]),
        throwsFormatException,
      );
    });

    test('a percentage above 100 that is not 0xFF is rejected', () {
      // Not clamped to 100: a value this build does not understand must not be
      // rounded into a number to put in front of the user.
      expect(() => BatteryStatus.fromBytes(<int>[101, 0]), throwsFormatException);
      expect(() => BatteryStatus.fromBytes(<int>[200, 0]), throwsFormatException);
      expect(() => BatteryStatus.fromBytes(<int>[0xFE, 0]), throwsFormatException);
    });

    test('reserved flag bits set means a firmware this build cannot read', () {
      expect(() => BatteryStatus.fromBytes(<int>[50, 0x02]), throwsFormatException);
      expect(() => BatteryStatus.fromBytes(<int>[50, 0x03]), throwsFormatException);
      expect(() => BatteryStatus.fromBytes(<int>[50, 0x80]), throwsFormatException);
      expect(() => BatteryStatus.fromBytes(<int>[50, 0xFF]), throwsFormatException);
    });

    test('the constants match the fixed contract', () {
      expect(BatteryStatus.valueBytes, 2);
      expect(BatteryStatus.unknownPercent, 0xFF);
      expect(BatteryStatus.maxPercent, 100);
      expect(BatteryStatus.chargingBit, 0x01);
      expect(BatteryStatus.reservedFlagBits, 0xFE);
    });
  });

  group('reading on connect', () {
    test('nothing is claimed before a device is connected', () {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      expect(harness.controller.batteryAvailable, isFalse);
      expect(harness.controller.batteryPercent, isNull);
      expect(harness.controller.batteryCharging, isFalse);
    });

    test('the reading is taken from the device on connect', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[64, 0x01]),
      );

      await harness.controller.connect(knownDevice);

      expect(harness.controller.batteryAvailable, isTrue);
      expect(harness.controller.batteryPercent, 64);
      expect(harness.controller.batteryCharging, isTrue);

      // Read from the device that was connected, not from anywhere else.
      verify(() => harness.transport.readBattery(knownDevice.id)).called(1);
    });

    test('0xFF leaves the percentage unknown without disabling the readout',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[0xFF, 0x01]),
      );

      await harness.controller.connect(knownDevice);

      // The characteristic IS there - so charging is trustworthy - but there
      // is no percentage to show.
      expect(harness.controller.batteryAvailable, isTrue);
      expect(harness.controller.batteryPercent, isNull);
      expect(harness.controller.batteryCharging, isTrue);
    });

    test('a failed read leaves the battery unknown, not flat', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenThrow(
        const BleTransportException('could not read the battery status'),
      );

      await harness.controller.connect(knownDevice);

      expect(harness.controller.batteryAvailable, isFalse);
      expect(harness.controller.batteryPercent, isNull,
          reason: 'firmware without fe05 must never be reported as 0%');
      // And it is not an app error: the recorder still records without it.
      expect(harness.controller.phase, AppPhase.connected,
          reason: 'a missing optional characteristic is not an app failure');
      expect(harness.controller.isConnected, isTrue);
      expect(harness.controller.errorMessage, isNull);
    });

    test('0% from the device really is 0%, and is available', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[0, 0x00]),
      );

      await harness.controller.connect(knownDevice);

      expect(harness.controller.batteryAvailable, isTrue);
      expect(harness.controller.batteryPercent, 0);
    });

    test('disconnecting drops the reading rather than keeping it', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.connect(knownDevice);
      expect(harness.controller.batteryAvailable, isTrue);

      await harness.controller.disconnect();

      expect(harness.controller.batteryAvailable, isFalse);
      expect(harness.controller.batteryPercent, isNull);
      expect(harness.controller.batteryCharging, isFalse);
      // The subscription is ended with the link, not left running.
      verify(() => harness.transport.unsubscribeBattery(knownDevice.id))
          .called(1);
    });
  });

  group('notifications keep it live', () {
    test('a notification replaces the value read on connect', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 80, charging: false),
      );

      await harness.controller.connect(knownDevice);
      expect(harness.controller.batteryPercent, 80);

      harness.battery.add(const BatteryStatus(percent: 79, charging: true));
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.batteryPercent, 79);
      expect(harness.controller.batteryCharging, isTrue);

      verify(() => harness.transport.subscribeBattery(knownDevice.id))
          .called(1);
    });

    test('a notification may take the percentage back to unknown', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.connect(knownDevice);
      expect(harness.controller.batteryPercent, 76);

      harness.battery.add(const BatteryStatus(percent: null, charging: false));
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.batteryAvailable, isTrue);
      expect(harness.controller.batteryPercent, isNull,
          reason: 'a device that stops knowing must not keep the old number');
    });

    test('an error on the stream is not an app failure', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.connect(knownDevice);

      harness.battery.addError(
        const BleTransportException('malformed battery notification'),
      );
      await Future<void>.delayed(Duration.zero);

      // The last good reading stands; nothing is invented and nothing breaks.
      expect(harness.controller.phase, AppPhase.connected);
      expect(harness.controller.batteryPercent, 76);
    });

    test('a transport that refuses to subscribe does not break the connection',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      // Thrown synchronously, not delivered on the stream.
      when(() => harness.transport.subscribeBattery(any())).thenThrow(
        const BleTransportException('already subscribed to the battery'),
      );
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 30, charging: false),
      );

      await harness.controller.connect(knownDevice);

      expect(harness.controller.isConnected, isTrue);
      expect(harness.controller.phase, AppPhase.connected);
      expect(harness.controller.batteryPercent, 30);
    });

    test('a subscription that fails outright leaves the one-shot read intact',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      // Firmware without `fe05` cannot be subscribed to either.
      when(() => harness.transport.subscribeBattery(any())).thenAnswer(
        (_) => Stream<BatteryStatus>.error(
          const BleTransportException('could not subscribe to the battery'),
        ),
      );
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 55, charging: false),
      );

      await harness.controller.connect(knownDevice);
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.batteryPercent, 55);
      expect(harness.controller.phase, AppPhase.connected);
    });
  });

  // -------------------------------------------------------------------------
  // THE BARS THE MAIN UI RENDERS
  //
  // Home shows four bars instead of a percentage, and the hysteresis that
  // keeps a bar from flickering needs the PREVIOUS answer. That state lives
  // here, in the controller, and not in the widget: a view that held it would
  // lose it to any rebuild that replaced the element, and the bars would snap
  // to the raw reading the moment the user navigated. The percentage is kept
  // alongside for the developer screen - nothing was thrown away.
  // -------------------------------------------------------------------------
  group('the bars the UI renders', () {
    test('the reading on connect is bucketed, and the figure kept', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.connect(knownDevice);

      expect(harness.controller.batteryPercent, 76);
      expect(harness.controller.batteryBars.bars, 3);
      expect(harness.controller.batteryBars.isFull, isFalse);
      expect(harness.controller.batteryBars.isCritical, isFalse);
    });

    test('the controller holds the hysteresis across notifications', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 80, charging: false),
      );

      await harness.controller.connect(knownDevice);
      expect(harness.controller.batteryBars.bars, 4);

      // 74% buckets to THREE bars from cold and holds FOUR when the last
      // answer was four. Four here proves the previous answer was passed in.
      harness.battery.add(const BatteryStatus(percent: 74, charging: false));
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.batteryPercent, 74);
      expect(harness.controller.batteryBars.bars, 4);
    });

    test('a reading going unknown clears the hysteresis', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 80, charging: false),
      );

      await harness.controller.connect(knownDevice);
      harness.battery.add(const BatteryStatus(percent: null, charging: false));
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.batteryBars.bars, 0);
      expect(harness.controller.batteryBars.isCritical, isFalse,
          reason: 'unknown is not empty');

      // There is no previous answer to hold any more, so this is a first
      // reading again and buckets down to three.
      harness.battery.add(const BatteryStatus(percent: 74, charging: false));
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.batteryBars.bars, 3);
    });

    test('0xFF is unknown bars, and a measured 0% is empty ones', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[0xFF, 0x00]),
      );

      await harness.controller.connect(knownDevice);
      expect(harness.controller.batteryBars.isCritical, isFalse);
      expect(harness.controller.batteryBars.bars, 0);

      harness.battery.add(BatteryStatus.fromBytes(<int>[0, 0x00]));
      await Future<void>.delayed(Duration.zero);

      // Same bar count, different fact - which is exactly why the readout
      // draws the two differently.
      expect(harness.controller.batteryBars.bars, 0);
      expect(harness.controller.batteryBars.isCritical, isTrue);
    });

    test('100% is reported as full', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[100, 0x00]),
      );

      await harness.controller.connect(knownDevice);

      expect(harness.controller.batteryBars.isFull, isTrue);
      expect(harness.controller.batteryBars.bars, 4);
    });

    test('disconnecting resets the bars, not just the figure', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.connect(knownDevice);
      expect(harness.controller.batteryBars.bars, 3);

      await harness.controller.disconnect();

      // Stale bars would be a stale measurement drawn as a live one, and
      // would also poison the dead-band on the next connection.
      expect(harness.controller.batteryBars.bars, 0);
      expect(harness.controller.batteryBars.isCritical, isFalse);
      expect(harness.controller.batteryPercent, isNull);
    });

    test('a dropped link resets the bars too', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.controller.connect(knownDevice);
      expect(harness.controller.batteryBars.bars, 3);

      harness.link.add(BleConnectionStatus.disconnected);
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.batteryBars.bars, 0);
      expect(harness.controller.batteryBars.isCritical, isFalse);
    });
  });
}
