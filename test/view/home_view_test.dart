import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/placeholder_data.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';
import 'package:voicenotetaker_app/view/theme.dart';

import 'harness.dart';

/// Home as the app actually mounts it.
///
/// The [ListenableBuilder] is not scaffolding for the test: `HomeView` is
/// stateless and reads the controller, and in the app `AppRoot` rebuilds it on
/// every notification. Without it here a battery notification or a disconnect
/// would change the controller and leave the old frame on screen, and the
/// tests below would be asserting against a view that never updates.
Widget _home(
  ViewHarness harness, {
  VoidCallback? onOpenDeveloper,
  VoidCallback? onOpenLibrary,
  ValueChanged<RecordingEntry>? onOpenRecording,
}) =>
    ListenableBuilder(
      listenable: harness.controller,
      builder: (context, _) => HomeView(
        controller: harness.controller,
        recents: PlaceholderData.library(),
        onOpenLibrary: onOpenLibrary ?? () {},
        onOpenRecording: onOpenRecording ?? (_) {},
        onOpenDeveloper: onOpenDeveloper,
      ),
    );

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('builds connected: device, state pill, record button, recents',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    expect(find.text('voiceNotetaker'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Tap to record'), findsOneWidget);
    expect(find.text('RECENT'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Standup notes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds disconnected without throwing', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await pumpScreen(tester, _home(harness));

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connect a recorder to start'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('the battery readout', () {
    testWidgets('shows the percentage the device reported', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 64, charging: false),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      expect(find.text('64%'), findsOneWidget);
      expect(find.text('—'), findsNothing);
      expect(find.bySemanticsLabel('Battery 64 percent'), findsOneWidget);
    });

    testWidgets('shows an em dash, never 0%, when there is no fe05',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenThrow(
        const BleTransportException('could not read the battery status'),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      expect(find.text('—'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
      expect(find.bySemanticsLabel('Battery level unknown'), findsOneWidget);
      // Unavailable, not broken.
      expect(tester.takeException(), isNull);
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('shows an em dash, never 0%, when the device reports 0xFF',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[0xFF, 0x00]),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      expect(find.text('—'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('a real 0% is shown as 0%, not as unknown', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[0, 0x00]),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      expect(find.text('0%'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('40% charging does not look like 40% discharging',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[40, 0x01]),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      expect(find.text('40%'), findsOneWidget);
      // Said in WORDS, not only in the readout's colour. It replaces
      // "Connected" because the breathing green dot beside it already says
      // the link is up, and the header has no room for both.
      expect(find.text('Charging'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(
        find.bySemanticsLabel('Battery 40 percent, charging'),
        findsOneWidget,
      );
      // And the figure is tinted, as a second, redundant signal.
      final text = tester.widget<Text>(find.text('40%'));
      expect(text.style?.color, AppColors.connected);
    });

    testWidgets('discharging at the same level says only Connected',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[40, 0x00]),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      expect(find.text('40%'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Charging'), findsNothing);
      final text = tester.widget<Text>(find.text('40%'));
      expect(text.style?.color, AppColors.textTertiary);
    });

    testWidgets('charging shows even when the percentage does not',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus.fromBytes(<int>[0xFF, 0x01]),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      expect(find.text('—'), findsOneWidget);
      expect(find.text('Charging'), findsOneWidget);
    });

    testWidgets('the header does not reflow as the charge ticks',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 9, charging: false),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));
      final narrow = tester.getRect(find.text('voiceNotetaker'));

      // 9% -> 100% is the widest jump the contract allows. The device name
      // beside it must not move: the readout's width is reserved.
      await harness.notifyBattery(tester, percent: 100, charging: false);
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);
      expect(tester.getRect(find.text('voiceNotetaker')), narrow);

      // ...and neither does dropping back to no reading at all.
      await harness.notifyBattery(tester, percent: null, charging: false);
      await tester.pump();
      expect(find.text('—'), findsOneWidget);
      expect(tester.getRect(find.text('voiceNotetaker')), narrow);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a notification moves the readout without a reconnect',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 80, charging: false),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));
      expect(find.text('80%'), findsOneWidget);

      await harness.notifyBattery(tester, percent: 81, charging: true);
      await tester.pump();

      expect(find.text('81%'), findsOneWidget);
      expect(find.text('80%'), findsNothing);
      expect(find.text('Charging'), findsOneWidget);
    });
  });

  group('the disconnect control', () {
    testWidgets('is present while connected and drops the link',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      expect(find.bySemanticsLabel('Disconnect'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Disconnect'));
      await flush(tester);

      // Through the controller, and it reached the transport for the device
      // that was actually connected.
      verify(() => harness.transport.disconnect(knownDevice.id)).called(1);
      expect(harness.controller.isConnected, isFalse);
      expect(harness.controller.connectedDevice, isNull);
      expect(harness.controller.phase, AppPhase.idle);
    });

    testWidgets('leaves no stale device name or battery behind',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 64, charging: true),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));
      expect(find.text('64%'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Disconnect'));
      await flush(tester);
      await tester.pump();

      // The header falls back to the advertised name rather than keeping the
      // name of a device that is no longer there, and the readings are gone.
      expect(harness.controller.connectedDevice, isNull);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('Charging'), findsNothing);
      expect(find.text('64%'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('Connect a recorder to start'), findsOneWidget);
      expect(harness.controller.autoSleepAvailable, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is absent when nothing is connected', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, _home(harness));

      expect(find.bySemanticsLabel('Disconnect'), findsNothing);
    });

    testWidgets('clears the 44px minimum', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      final size = tester.getSize(find.bySemanticsLabel('Disconnect'));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });
  });

  testWidgets('the record button starts a capture', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    await tester.tap(find.bySemanticsLabel('Record'));
    await flush(tester);

    expect(harness.controller.phase, AppPhase.recording);
    verify(() => harness.transport.subscribeFrames(knownDevice.id)).called(1);
  });

  testWidgets('the record button is at least 44px across', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    final size = tester.getSize(find.bySemanticsLabel('Record'));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('"All" opens the library', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    var opened = false;

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness, onOpenLibrary: () => opened = true));

    await tester.tap(find.text('All'));
    await tester.pump();

    expect(opened, isTrue);
  });

  testWidgets('a recent row opens playback for that recording',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    RecordingEntry? opened;

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(
      tester,
      _home(harness, onOpenRecording: (entry) => opened = entry),
    );

    await tester.tap(find.text('Standup notes'));
    await tester.pump();

    expect(opened?.title, 'Standup notes');
  });

  // Two separate tests rather than two pumps in one: pumping a second screen
  // into the same position reuses the State of the first, which hides bugs.
  testWidgets('the developer entry point is absent when it is not supplied',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    expect(find.bySemanticsLabel('Developer'), findsNothing);
  });

  testWidgets('the developer entry point is present when it is supplied',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    var opened = false;

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(
      tester,
      _home(harness, onOpenDeveloper: () => opened = true),
    );

    expect(find.bySemanticsLabel('Developer'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Developer'));
    await tester.pump();
    expect(opened, isTrue);
  });
}
