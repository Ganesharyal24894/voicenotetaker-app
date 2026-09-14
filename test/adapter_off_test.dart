import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/auto_sleep.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/connection_lost_view.dart';
import 'package:voicenotetaker_app/view/diagnostics_view.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';

import 'view/harness.dart';

/// Bluetooth going off while the app is connected.
///
/// THE BUG THIS FILE EXISTS FOR. The app showed "Connected" - a device name, a
/// battery percentage, a working Disconnect button - after the phone's radio had
/// been switched off, and went on showing it until the app was killed and
/// restarted. The cause was not the screen: it was that the app was waiting for a
/// DISCONNECT EVENT THAT CAN NEVER ARRIVE. On Android the GATT callback that
/// reports a dropped link is delivered by the Bluetooth stack, and the stack has
/// just been shut down; there is no radio left to notice the peripheral is gone.
///
/// So the adapter state is what has to drive it. Anything but
/// [BleAvailability.poweredOn] means the link is over, and it tears down exactly
/// what a real disconnect tears down - through the same method, so the two
/// cannot drift apart.
///
/// Everything here is asserted on the CONTROLLER as well as the screen, because
/// the staleness would show up anywhere a connection is rendered rather than on
/// Home alone.
void main() {
  setUpAll(registerViewFallbacks);

  /// Connects, having started the controller so the adapter stream is live.
  Future<ViewHarness> connected(
    WidgetTester tester, {
    Duration? testWindow,
  }) async {
    final harness = ViewHarness(
      devices: const <DiscoveredDevice>[knownDevice],
      testWindow: testWindow,
    );
    addTearDown(harness.dispose);
    await harness.begin(tester);
    await harness.connect(tester);
    return harness;
  }

  group('the adapter going off IS the disconnect', () {
    testWidgets('nothing is left that could render as a live connection',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 64, charging: true),
      );
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => const AutoSleepSetting.legacy(true));

      await harness.begin(tester);
      await harness.connect(tester);
      expect(harness.controller.isConnected, isTrue);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);

      // The same list `disconnect_test.dart` asserts, because it is the same
      // teardown: whatever "disconnected" means, it means it here too.
      expect(harness.controller.isConnected, isFalse);
      expect(harness.controller.connectedDevice, isNull);
      expect(harness.controller.phase, AppPhase.idle);
      expect(harness.controller.batteryAvailable, isFalse);
      expect(harness.controller.batteryPercent, isNull);
      expect(harness.controller.batteryCharging, isFalse);
      expect(harness.controller.autoSleepAvailable, isFalse);
      expect(harness.controller.temperatureAvailable, isFalse);
      expect(harness.controller.dieTemperatureCelsius, isNull);
      // And the `fe05` subscription is off, not left feeding a dead screen.
      verify(() => harness.transport.unsubscribeBattery(knownDevice.id))
          .called(1);
    });

    testWidgets('it lands on the Bluetooth-off state, which is why that state '
        'was built', (tester) async {
      final harness = await connected(tester);

      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await settleDock(tester);
      expect(find.byType(HomeView), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);
      await settleDock(tester);

      // Amber, one tap from working, and it names the actual problem.
      expect(find.text('Bluetooth is off'), findsOneWidget);
      expect(find.text('Open Bluetooth settings'), findsOneWidget);
      // NOT the dropped-link screen: nothing went out of range, and "Reconnect"
      // would be an action that cannot possibly work.
      expect(find.byType(ConnectionLostView), findsNothing);
      expect(find.text('Recorder disconnected'), findsNothing);
      expect(harness.controller.linkOutcome, LinkOutcome.none);
    });

    testWidgets('a capture in progress is finished, not truncated',
        (tester) async {
      final harness = await connected(tester);
      await harness.record(tester);
      expect(harness.controller.isRecording, isTrue);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);

      // The WAV header was patched rather than left describing a file that
      // stopped mid-frame - the radio going away does not change what is
      // already on disk.
      expect(harness.controller.isRecording, isFalse);
      expect(harness.controller.lastRecording, isNotNull);
      expect(harness.controller.connectedDevice, isNull);
    });

    testWidgets('it acts on "not powered on", so resetting counts too',
        (tester) async {
      // Android reports STATE_TURNING_OFF before STATE_OFF, and that maps to
      // `unknown`. Tearing down on anything but `poweredOn` therefore acts one
      // event EARLIER than watching for `poweredOff` would.
      final harness = await connected(tester);

      await harness.notifyAvailability(tester, BleAvailability.unknown);

      expect(harness.controller.isConnected, isFalse);
      expect(harness.controller.connectedDevice, isNull);
      expect(harness.controller.phase, AppPhase.idle);
    });

    testWidgets('a withdrawn permission is the same fact', (tester) async {
      // iOS can revoke Bluetooth access from under a running app. There is no
      // radio left for this app either, so it is the same teardown.
      final harness = await connected(tester);

      await harness.notifyAvailability(tester, BleAvailability.unauthorized);

      expect(harness.controller.isConnected, isFalse);
      expect(harness.controller.connectedDevice, isNull);
    });

    testWidgets('the devices a dead radio found go with it', (tester) async {
      final harness = ViewHarness(
        devices: const <DiscoveredDevice>[knownDevice, unknownDevice],
      );
      addTearDown(harness.dispose);
      await harness.begin(tester);
      await harness.discover(tester);
      await harness.endScanWindow(tester);
      expect(harness.controller.devices, hasLength(2));
      expect(harness.controller.scanOutcome, ScanOutcome.devicesFound);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);

      // A list of peripherals found by a radio that is now off is not a list of
      // peripherals in range. And neither "found some" nor "found none" is true
      // of a window the radio never finished.
      expect(harness.controller.devices, isEmpty);
      expect(harness.controller.scanOutcome, ScanOutcome.pending);
    });

    testWidgets('a scan running when it happens is ended, even if the radio '
        'refuses to stop it', (tester) async {
      // The realistic failure: `stopScan` is a call into a stack that has just
      // been switched off. It must not cost the teardown, which is the part the
      // user can see.
      final harness = ViewHarness(
        devices: const <DiscoveredDevice>[knownDevice],
      );
      addTearDown(harness.dispose);
      when(() => harness.transport.stopScan())
          .thenThrow(const BleTransportException('could not stop scan'));
      await harness.begin(tester);
      await harness.discover(tester);
      expect(harness.controller.isScanning, isTrue);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);

      expect(harness.controller.isScanning, isFalse);
      expect(harness.controller.devices, isEmpty);
      expect(harness.controller.phase, AppPhase.idle);
      expect(harness.controller.availability, BleAvailability.poweredOff);
    });

    testWidgets('with nothing connected it is not an error', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await harness.begin(tester);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);

      expect(harness.controller.phase, AppPhase.idle);
      expect(harness.controller.errorMessage, isNull);
      verifyNever(() => harness.transport.disconnect(any()));
    });

    testWidgets('a repeated event does not tear down twice', (tester) async {
      final harness = await connected(tester);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);
      await harness.notifyAvailability(tester, BleAvailability.poweredOff);

      verify(() => harness.transport.disconnect(knownDevice.id)).called(1);
    });
  });

  group('Bluetooth coming back does not resurrect the link', () {
    testWidgets('the controller reports no connection, and no phantom device',
        (tester) async {
      final harness = await connected(tester);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);
      await harness.notifyAvailability(tester, BleAvailability.poweredOn);

      expect(harness.controller.availability, BleAvailability.poweredOn);
      expect(harness.controller.isConnected, isFalse);
      expect(harness.controller.connectedDevice, isNull);
      expect(harness.controller.phase, AppPhase.idle);
      expect(harness.controller.batteryAvailable, isFalse);
      // Nothing reconnected behind the user's back.
      verify(() => harness.transport.connect(knownDevice.id)).called(1);
    });

    testWidgets('the screen offers a scan - something the user can act on',
        (tester) async {
      final harness = await connected(tester);

      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await settleDock(tester);
      await harness.notifyAvailability(tester, BleAvailability.poweredOff);
      await settleDock(tester);
      expect(find.text('Bluetooth is off'), findsOneWidget);

      await harness.notifyAvailability(tester, BleAvailability.poweredOn);
      await settleDock(tester);

      expect(find.byType(ScanView), findsOneWidget);
      expect(find.text('Tap to scan'), findsOneWidget);
      // Not Home, and not the dropped-link screen either.
      expect(find.text('Bluetooth is off'), findsNothing);
      expect(find.byType(ConnectionLostView), findsNothing);
      // `lastDevice` survives, so a scan is not the only way back - but it is
      // the user's move to make.
      expect(harness.controller.lastDevice, knownDevice);
    });
  });

  group('the diagnostics screen stops streaming with the radio', () {
    testWidgets('the adapter going off drops fe01 and fe07', (tester) async {
      // THE POWER RULE. Nothing runs when it is not needed, and a teardown that
      // forgot these two would leave the app believing it was still counting
      // frames off a radio that is off.
      final harness = await connected(tester);
      await pumpScreen(
        tester,
        DiagnosticsView(controller: harness.controller),
      );
      await flush(tester);
      expect(harness.controller.linkHealth.watching, isTrue);
      expect(harness.controller.temperatureAvailable, isTrue);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);

      verify(() => harness.transport.unsubscribeFrames(knownDevice.id))
          .called(1);
      verify(() => harness.transport.unsubscribeDieTemperature(knownDevice.id))
          .called(1);
      expect(harness.controller.linkHealth.watching, isFalse);
      // The figure goes with the subscription: a reading nothing is taking any
      // more must not stay on screen.
      expect(harness.controller.temperatureAvailable, isFalse);
      expect(harness.controller.dieTemperatureCelsius, isNull);
    });

    testWidgets('a mic check running when it happens is stopped, and keeps '
        'what it measured', (tester) async {
      final harness = await connected(
        tester,
        testWindow: const Duration(seconds: 30),
      );
      await harness.controller.deviceTests.load();
      await pumpScreen(
        tester,
        DiagnosticsView(controller: harness.controller),
      );
      await flush(tester);
      // NOT awaited: awaiting the call waits out the whole batch, which is what
      // the tap on Run does not do either.
      unawaited(harness.controller.runNoiseFloorTest());
      await flush(tester);
      expect(harness.controller.deviceTests.isRunning, isTrue);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);
      await flush(tester);

      final tests = harness.controller.deviceTests;
      expect(tests.isRunning, isFalse);
      expect(tests.isBatchActive, isFalse);
      // Cancelled, not lost: the sample that was in flight is still saved and
      // the batch says it was stopped early.
      final batches = tests.batchesOf(DeviceTestKind.noiseFloor);
      expect(batches, hasLength(1));
      expect(batches.single.isPartial, isTrue);
    });
  });

  group('the resume re-check is a backstop, not the fix', () {
    testWidgets('an adapter that went off with no event is still caught',
        (tester) async {
      // The stream is what normally carries this, and it does - see the rest of
      // this file. This covers the one gap where a miss is plausible: the user
      // leaves for the system Bluetooth panel, turns the radio off there, and
      // comes back. Here the platform is made to report `poweredOff` while NO
      // stream event is pushed at all.
      final harness = await connected(tester);
      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await settleDock(tester);
      expect(find.byType(HomeView), findsOneWidget);

      when(() => harness.transport.currentAvailability())
          .thenAnswer((_) async => BleAvailability.poweredOff);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush(tester);
      await settleDock(tester);

      expect(harness.controller.availability, BleAvailability.poweredOff);
      expect(harness.controller.connectedDevice, isNull);
      expect(find.text('Bluetooth is off'), findsOneWidget);
    });

    testWidgets('a resume with the radio still on changes nothing',
        (tester) async {
      final harness = await connected(tester);
      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await settleDock(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush(tester);
      await settleDock(tester);

      expect(harness.controller.isConnected, isTrue);
      expect(find.byType(HomeView), findsOneWidget);
      verifyNever(() => harness.transport.disconnect(any()));
    });
  });
}
