import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/notes_saving.dart';
import 'package:voicenotetaker_app/model/pairing_outcome.dart';
import 'package:voicenotetaker_app/model/recorder_sleep.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/connect_banner.dart';
import 'package:voicenotetaker_app/view/widgets/privacy_banner.dart';

import 'harness.dart';
import 'home_harness.dart';

/// The way to connect from Home, as approved in `canvas-connect/` (option
/// A): a card on Today while always listening has no recorder, which opens
/// the scan screen over Home; and Settings' "Connect a recorder" offered
/// whether or not always listening is on.
void main() {
  setUpAll(registerViewFallbacks);

  /// Home under [AppRoot], always listening on and connected - with no notes,
  /// the case where only always listening keeps Home up.
  Future<(ViewHarness, FakeBlePairing)> listening(WidgetTester tester) async {
    final pairing = FakeBlePairing(systemBonds: false);
    final harness = ViewHarness(
      devices: const <DiscoveredDevice>[knownDevice],
      pairing: pairing,
      backgroundMode: FakeBackgroundMode(),
    )..captureSupported = true;
    addTearDown(harness.dispose);
    await harness.begin(tester);
    await pumpScreen(tester, AppRoot(controller: harness.controller));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);
    await harness.controller.setContinuousEnabled(true);
    await flush(tester);
    return (harness, pairing);
  }

  /// The link drops and every attempt to get it back fails.
  Future<void> drop(WidgetTester tester, ViewHarness harness) async {
    when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
        .thenThrow(const BleTransportException('no answer'));
    when(
      () => harness.transport.connect(
        any(),
        timeout: any(named: 'timeout'),
        waitForAdvertisement: any(named: 'waitForAdvertisement'),
      ),
    ).thenThrow(const BleTransportException('no answer'));
    await harness.dropLink(tester);
    await settleDock(tester);
  }

  Future<void> stopListening(WidgetTester tester, ViewHarness harness) async {
    final done = harness.controller.setContinuousEnabled(false);
    await flush(tester);
    await done;
  }

  Finder cardTitled(String title) => find.descendant(
        of: find.byType(ConnectBanner),
        matching: find.text(title),
      );

  group('the card on Today', () {
    testWidgets('recorder disconnected: Connect, with an amber edge',
        (tester) async {
      final (harness, _) = await listening(tester);
      await drop(tester, harness);

      expect(harness.controller.notesSaving, NotesSaving.disconnected);
      expect(find.text('Not saving — recorder disconnected'), findsOneWidget);
      expect(cardTitled(ConnectBanner.disconnectedTitle), findsOneWidget);
      expect(find.text(ConnectBanner.disconnectedMeta), findsOneWidget);
      expect(find.bySemanticsLabel(ConnectBanner.connect), findsOneWidget);

      final card = tester.widget<Container>(
        find
            .ancestor(
              of: find.text(ConnectBanner.disconnectedTitle),
              matching: find.byType(Container),
            )
            .last,
      );
      final border = (card.decoration! as BoxDecoration).border! as Border;
      expect(border.top.color, AppColors.warningCardBorder);
      await stopListening(tester, harness);
    });

    testWidgets('pairing needs a reset: Fix', (tester) async {
      final (harness, pairing) = await listening(tester);
      pairing.failureKind = BleFailureKind.keyMissing;
      await drop(tester, harness);

      expect(harness.controller.notesSaving, NotesSaving.oldPairing);
      expect(cardTitled(ConnectBanner.oldPairingTitle), findsOneWidget);
      expect(find.text(ConnectBanner.oldPairingMeta), findsOneWidget);
      expect(find.bySemanticsLabel(ConnectBanner.fix), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('paired to another phone: Pair', (tester) async {
      final (harness, pairing) = await listening(tester);
      pairing.failureKind = BleFailureKind.authenticationFailure;
      await drop(tester, harness);

      expect(harness.controller.notesSaving, NotesSaving.pairedToAnother);
      expect(cardTitled(ConnectBanner.pairedToAnotherTitle), findsOneWidget);
      expect(find.text(ConnectBanner.pairedToAnotherMeta), findsOneWidget);
      expect(find.bySemanticsLabel(ConnectBanner.pair), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('nothing while saving', (tester) async {
      final (harness, _) = await listening(tester);

      expect(find.text('Saving notes'), findsOneWidget);
      expect(find.byType(ConnectBanner), findsOneWidget);
      expect(find.text(ConnectBanner.disconnectedTitle), findsNothing);
      expect(find.bySemanticsLabel(ConnectBanner.connect), findsNothing);
      await stopListening(tester, harness);
    });

    testWidgets('nothing in privacy mode: that card has the slot',
        (tester) async {
      final (harness, _) = await listening(tester);
      harness.capture.add(
        const CaptureFlags(privacyMode: true, speechOpen: false, gateEnabled: true),
      );
      await flush(tester);

      expect(find.text(PrivacyBanner.title), findsOneWidget);
      expect(find.text(ConnectBanner.disconnectedTitle), findsNothing);
      await stopListening(tester, harness);
    });

    testWidgets('nothing while the recorder is asleep', (tester) async {
      final (harness, _) = await listening(tester);
      harness.dropReason = LinkDropReason.remoteTerminated;
      await drop(tester, harness);

      expect(harness.controller.notesSaving, NotesSaving.asleep);
      expect(find.text(ConnectBanner.disconnectedTitle), findsNothing);
      await stopListening(tester, harness);
    });

    testWidgets('nothing when connected with always listening off',
        (tester) async {
      final (harness, _) = await listening(tester);
      await stopListening(tester, harness);

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text(ConnectBanner.disconnectedTitle), findsNothing);
    });

    testWidgets('it belongs to Today, not Notes', (tester) async {
      final (harness, _) = await listening(tester);
      await drop(tester, harness);

      await tester.tap(find.text('Notes').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text(ConnectBanner.disconnectedTitle), findsNothing);
      await stopListening(tester, harness);
    });

    testWidgets('Connect opens the scan screen over Home, and Back returns',
        (tester) async {
      final (harness, _) = await listening(tester);
      await drop(tester, harness);

      await tester.tap(find.bySemanticsLabel(ConnectBanner.connect));
      await settleDock(tester);
      expect(find.byType(ScanView), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Back'));
      await settleDock(tester);
      expect(find.byType(ScanView), findsNothing);
      expect(find.byType(HomeView), findsOneWidget);
      expect(cardTitled(ConnectBanner.disconnectedTitle), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('Fix opens the same scan screen', (tester) async {
      final (harness, pairing) = await listening(tester);
      pairing.failureKind = BleFailureKind.keyMissing;
      await drop(tester, harness);

      await tester.tap(find.bySemanticsLabel(ConnectBanner.fix));
      await settleDock(tester);
      expect(find.byType(ScanView), findsOneWidget);
      await stopListening(tester, harness);
    });
  });

  group('Recorder settings', () {
    testWidgets('Connect a recorder is there with always listening on and no '
        'link, and opens the scan screen over Home', (tester) async {
      final (harness, _) = await listening(tester);
      await drop(tester, harness);

      await tester.tap(recorderStatusLine());
      await settleDock(tester);
      expect(find.text(SettingsView.title), findsOneWidget);
      expect(find.bySemanticsLabel('Connect a recorder'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Connect a recorder'));
      await settleDock(tester);
      expect(find.byType(ScanView), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Back'));
      await settleDock(tester);
      expect(find.byType(HomeView), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('connected with always listening on: neither Connect nor '
        'Disconnect - the link is the app\'s to keep', (tester) async {
      final (harness, _) = await listening(tester);

      await tester.tap(recorderStatusLine());
      await settleDock(tester);

      expect(find.bySemanticsLabel('Connect a recorder'), findsNothing);
      expect(find.text('Disconnect'), findsNothing);
      await stopListening(tester, harness);
    });
  });
}
