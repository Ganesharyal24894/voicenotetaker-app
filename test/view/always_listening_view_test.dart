
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/connection_lost_view.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';

import 'harness.dart';
import 'home_harness.dart';

/// The always-listening card on Home, and what it changes around it.
void main() {
  setUpAll(registerViewFallbacks);

  Widget home(ViewHarness harness) => homeFor(harness);

  /// The always-listening card lives on Recorder settings, which the status
  /// line opens.
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(recorderStatusLine());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// The Always listening switch - the first on Recorder settings.
  Finder listeningSwitch() => find.byType(Switch).first;

  /// Turns always-listening off at the end of a test, which is what cancels
  /// its keep-alive and reconnect timers. The tester's own "a Timer is still
  /// pending" check is what catches one that outlives it.
  Future<void> stopListening(WidgetTester tester, ViewHarness harness) async {
    final done = harness.controller.setContinuousEnabled(false);
    await flush(tester);
    await done;
  }

  Future<ViewHarness> connected(WidgetTester tester, {bool fe08 = true}) async {
    final harness = ViewHarness(backgroundMode: FakeBackgroundMode())
      ..captureSupported = fe08;
    addTearDown(harness.dispose);
    await harness.begin(tester);
    await harness.connect(tester);
    return harness;
  }

  testWidgets('iPhone says what it does differently; Android does not',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final harness = await connected(tester);
      await pumpScreen(tester, home(harness));
      await openSheet(tester);

      expect(find.text(AlwaysListeningCard.title), findsOneWidget);
      expect(find.text(AlwaysListeningCard.iosNote), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the iPhone line is not shown on Android', (tester) async {
    final harness = await connected(tester);
    await pumpScreen(tester, home(harness));
    await openSheet(tester);

    expect(find.text(AlwaysListeningCard.title), findsOneWidget);
    expect(find.text(AlwaysListeningCard.iosNote), findsNothing);
  });

  testWidgets('off, it offers itself and leaves Home as it was',
      (tester) async {
    final harness = await connected(tester);
    await pumpScreen(tester, home(harness));
    expect(find.text('Connected'), findsOneWidget);
    await openSheet(tester);

    expect(find.text(AlwaysListeningCard.title), findsOneWidget);
    expect(find.text('Notes save when you speak'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(tester.widget<Switch>(listeningSwitch()).value, isFalse);
  });

  testWidgets('switching it on listens, and Record steps aside',
      (tester) async {
    final harness = await connected(tester);
    await pumpScreen(tester, home(harness));
    await openSheet(tester);

    await tester.tap(listeningSwitch());
    await flush(tester);

    expect(harness.controller.continuousActive, isTrue);
    expect(find.text('Always listening'), findsOneWidget);
    expect(find.text('Saving notes'), findsWidgets);
    expect(find.text('Disconnect'), findsNothing);
    Navigator.of(tester.element(find.byType(AlwaysListeningCard))).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.bySemanticsLabel('Record'));
    await tester.pump();
    expect(harness.controller.isRecording, isFalse);
    expect(find.text('Notes already save on their own while always listening is on.'), findsOneWidget);
    await stopListening(tester, harness);
  });

  testWidgets('it shows what the device reports', (tester) async {
    final harness = await connected(tester);
    await harness.controller.setContinuousEnabled(true);
    await pumpScreen(tester, home(harness));

    await openSheet(tester);
    harness.capture.add(
      const CaptureFlags(privacyMode: true, speechOpen: false, gateEnabled: true),
    );
    await flush(tester);
    expect(find.text('Privacy mode on'), findsOneWidget);

    harness.capture.add(
      const CaptureFlags(privacyMode: false, speechOpen: true, gateEnabled: true),
    );
    await flush(tester);
    expect(find.text('Saving notes'), findsOneWidget);

    harness.capture.add(
      const CaptureFlags(
        privacyMode: false,
        speechOpen: false,
        gateEnabled: true,
        micOff: true,
      ),
    );
    await flush(tester);
    expect(find.text('Not saving — mic off to save battery'), findsOneWidget);
    await stopListening(tester, harness);
  });

  testWidgets('a recorder with no fe08 says it needs an update, and Record '
      'still works', (tester) async {
    // The one firmware check the app keeps: a board that does not answer fe08
    // is not running this firmware, and always-listening is the one feature
    // that genuinely cannot work without it.
    final harness = await connected(tester, fe08: false);
    await harness.controller.setContinuousEnabled(true);
    await pumpScreen(tester, home(harness));

    expect(find.text('Not saving — recorder needs an update'), findsOneWidget);
    await openSheet(tester);
    expect(find.text('Not saving — recorder needs an update'), findsOneWidget);
    await stopListening(tester, harness);
  });

  testWidgets('permissions are explained before they are asked for',
      (tester) async {
    final background = FakeBackgroundMode()..batteryExempt = false;
    final harness = ViewHarness(backgroundMode: background)
      ..captureSupported = true;
    addTearDown(harness.dispose);
    await harness.begin(tester);
    await harness.connect(tester);
    await pumpScreen(tester, home(harness));
    await openSheet(tester);

    await tester.tap(listeningSwitch());
    await flush(tester);
    expect(find.text('Keep listening'), findsOneWidget);
    expect(background.permissionRequests, 0);

    await tester.tap(find.text('Allow'));
    await flush(tester);
    expect(background.permissionRequests, 1);
    expect(harness.controller.continuousEnabled, isTrue);
    await stopListening(tester, harness);
  });

  testWidgets('the Keep listening sheet asks for what THIS phone needs',
      (tester) async {
    final android = AlwaysListeningCard.permissionReason(
        ios: false, autostart: false);
    final xiaomi = AlwaysListeningCard.permissionReason(
        ios: false, autostart: true);
    final ios = AlwaysListeningCard.permissionReason(
        ios: true, autostart: false);

    // Android: the foreground service needs a notification and the battery
    // exemption, and neither is named in jargon.
    expect(android, contains('notifications'));
    expect(android, contains('background'));
    expect(android, isNot(contains('Background App Refresh')));
    expect(android, isNot(contains('Autostart')));

    // Xiaomi gets the extra line, and only Xiaomi.
    expect(xiaomi, startsWith(android));
    expect(xiaomi, contains('Autostart'));

    // iPhone: a different pair of things, for different reasons - and it does
    // not promise Android's "keeps transcribing" behaviour.
    expect(ios, contains('notifications'));
    expect(ios, contains('Background App Refresh'));
    expect(ios, contains('charger'));
    expect(ios, isNot(contains('Autostart')));
  });

  testWidgets('the iPhone line no longer promises transcripts only on open',
      (tester) async {
    // The app now asks iOS for a processing window, so "when you open the
    // app" is no longer the whole truth - and the line must not say it is.
    expect(AlwaysListeningCard.iosNote, contains('keep saving'));
    expect(AlwaysListeningCard.iosNote, contains('charger'));
  });

  testWidgets('a dropped link stays on Home, saying the device is not '
      'connected', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice])
      ..captureSupported = true;
    addTearDown(harness.dispose);
    await harness.begin(tester);
    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    await harness.controller.setContinuousEnabled(true);
    // The next attempt fails, so the screen can be looked at without a link.
    when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
        .thenThrow(const BleTransportException('out of range'));

    await harness.dropLink(tester);
    await settleDock(tester);

    expect(find.byType(HomeView), findsOneWidget);
    expect(find.byType(ConnectionLostView), findsNothing);
    expect(find.byType(ScanView), findsNothing);
    expect(find.text('Not saving — recorder disconnected'), findsOneWidget);
    await stopListening(tester, harness);
  });
}
