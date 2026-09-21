import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/motion.dart';
import 'package:voicenotetaker_app/view/widgets/privacy_banner.dart';
import 'package:voicenotetaker_app/view/widgets/privacy_mode_card.dart';

import 'harness.dart';
import 'home_harness.dart';

/// Privacy mode on Today and on Recorder settings, as approved in
/// `canvas-privacy/`: the banner, the switch, and the purple status line.
/// Every screen follows the recorder's `fe08` report, never the tap alone.
void main() {
  setUpAll(registerViewFallbacks);

  const privacyOn =
      CaptureFlags(privacyMode: true, speechOpen: false, gateEnabled: true);
  const privacyOff =
      CaptureFlags(privacyMode: false, speechOpen: false, gateEnabled: true);

  Future<ViewHarness> listening(WidgetTester tester, {bool on = true}) async {
    final harness = ViewHarness(backgroundMode: FakeBackgroundMode())
      ..captureSupported = true;
    addTearDown(harness.dispose);
    await harness.begin(tester);
    await harness.connect(tester);
    if (on) await harness.controller.setContinuousEnabled(true);
    return harness;
  }

  Future<void> stopListening(WidgetTester tester, ViewHarness harness) async {
    final done = harness.controller.setContinuousEnabled(false);
    await flush(tester);
    await done;
  }

  Future<void> report(WidgetTester tester, ViewHarness harness, CaptureFlags flags) async {
    harness.capture.add(flags);
    await flush(tester);
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(recorderStatusLine());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Switch privacySwitch(WidgetTester tester) => tester.widget<Switch>(
        find.descendant(of: find.byType(PrivacyModeCard), matching: find.byType(Switch)),
      );

  group('Today', () {
    testWidgets('an ordinary day adds nothing', (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));

      expect(find.text('Saving notes'), findsOneWidget);
      expect(find.byType(PrivacyBanner), findsOneWidget);
      expect(find.text(PrivacyBanner.title), findsNothing);
      expect(find.text(PrivacyBanner.resume), findsNothing);
      await stopListening(tester, harness);
    });

    testWidgets('privacy mode shows the banner, and the status line is purple',
        (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await report(tester, harness, privacyOn);

      expect(find.text(PrivacyBanner.title), findsOneWidget);
      expect(find.text(PrivacyBanner.meta), findsOneWidget);
      expect(find.text(PrivacyBanner.resume), findsOneWidget);
      expect(find.byType(ShieldIcon), findsOneWidget);

      final label = tester.widget<Text>(find.text('Privacy mode on'));
      expect(label.style?.color, AppColors.purple300);
      final dot = tester.widget<BreathingDot>(find.byType(BreathingDot).first);
      expect(dot.color, AppColors.purple400);
      expect(dot.breathing, isFalse);
      await stopListening(tester, harness);
    });

    testWidgets('the banner card wears the purple chip border', (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await report(tester, harness, privacyOn);

      final card = tester.widget<Container>(
        find
            .ancestor(of: find.text(PrivacyBanner.title), matching: find.byType(Container))
            .last,
      );
      final border = (card.decoration! as BoxDecoration).border! as Border;
      expect(border.top.color, AppColors.purpleChipBorder);
      await stopListening(tester, harness);
    });

    testWidgets('Resume sends unmute, and the banner goes only when the '
        'recorder says so', (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await report(tester, harness, privacyOn);
      clearInteractions(harness.transport);

      await tester.tap(find.bySemanticsLabel(PrivacyBanner.resume));
      await flush(tester);

      verify(() => harness.transport
          .writeCapture(knownDevice.id, CaptureCommand.unmute)).called(1);
      verifyNever(() => harness.transport.writeCapture(any(), CaptureCommand.mute));
      expect(find.text(PrivacyBanner.title), findsOneWidget);

      await report(tester, harness, privacyOff);
      expect(find.text(PrivacyBanner.title), findsNothing);
      expect(find.text('Saving notes'), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('the status line still opens Recorder settings in privacy mode',
        (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await report(tester, harness, privacyOn);

      await openSettings(tester);

      expect(find.text(SettingsView.title), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('the banner belongs to Today, not Notes', (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await report(tester, harness, privacyOn);

      await tester.tap(find.text('Notes').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text(PrivacyBanner.title), findsNothing);
      expect(find.text('Privacy mode on'), findsOneWidget);
      await stopListening(tester, harness);
    });
  });

  group('Recorder settings', () {
    testWidgets('off: under Always listening, with the footnote',
        (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await openSettings(tester);

      expect(find.text(PrivacyModeCard.title), findsOneWidget);
      expect(find.text(PrivacyModeCard.metaOff), findsOneWidget);
      expect(find.text(PrivacyModeCard.footnote), findsOneWidget);
      expect(privacySwitch(tester).value, isFalse);
      expect(privacySwitch(tester).onChanged, isNotNull);
      expect(
        tester.getTopLeft(find.byType(PrivacyModeCard)).dy,
        greaterThan(tester.getTopLeft(find.text('Always listening')).dy),
      );
      final footnote = tester.widget<Text>(find.text(PrivacyModeCard.footnote));
      expect(footnote.style, AppText.footnote12);
      await stopListening(tester, harness);
    });

    testWidgets('a tap sends mute, and the switch waits for the recorder',
        (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await openSettings(tester);
      clearInteractions(harness.transport);

      await tester.tap(find.descendant(
          of: find.byType(PrivacyModeCard), matching: find.byType(Switch)));
      await flush(tester);

      verify(() => harness.transport
          .writeCapture(knownDevice.id, CaptureCommand.mute)).called(1);
      expect(privacySwitch(tester).value, isFalse);
      expect(find.text(PrivacyModeCard.metaOff), findsOneWidget);

      await report(tester, harness, privacyOn);
      expect(privacySwitch(tester).value, isTrue);
      expect(find.text(PrivacyModeCard.metaOn), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('on: a tap sends unmute, and the switch waits for the recorder',
        (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await report(tester, harness, privacyOn);
      await openSettings(tester);
      clearInteractions(harness.transport);

      await tester.tap(find.descendant(
          of: find.byType(PrivacyModeCard), matching: find.byType(Switch)));
      await flush(tester);

      verify(() => harness.transport
          .writeCapture(knownDevice.id, CaptureCommand.unmute)).called(1);
      expect(privacySwitch(tester).value, isTrue);

      await report(tester, harness, privacyOff);
      expect(privacySwitch(tester).value, isFalse);
      expect(find.text(PrivacyModeCard.metaOff), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('the Always listening dot is purple in privacy mode',
        (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      await report(tester, harness, privacyOn);
      await openSettings(tester);

      final dot = tester.widget<BreathingDot>(find.descendant(
        of: find.byType(AlwaysListeningCard),
        matching: find.byType(BreathingDot),
      ));
      expect(dot.color, AppColors.purple400);
      await stopListening(tester, harness);
    });

    testWidgets('recorder not connected: disabled, and says why',
        (tester) async {
      final harness = await listening(tester);
      await pumpScreen(tester, homeFor(harness));
      when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
          .thenThrow(const BleTransportException('out of range'));
      await harness.dropLink(tester);
      await settleDock(tester);
      await openSettings(tester);

      expect(find.text(PrivacyModeCard.metaUnavailable), findsOneWidget);
      expect(privacySwitch(tester).value, isFalse);
      expect(privacySwitch(tester).onChanged, isNull);
      expect(find.text(PrivacyModeCard.footnote), findsOneWidget);
      await stopListening(tester, harness);
    });

    testWidgets('always listening off: disabled, nothing is sent',
        (tester) async {
      final harness = await listening(tester, on: false);
      await pumpScreen(tester, homeFor(harness));
      await openSettings(tester);

      expect(privacySwitch(tester).onChanged, isNull);
      expect(find.text(PrivacyModeCard.metaUnavailable), findsOneWidget);
      verifyNever(() => harness.transport.writeCapture(any(), any()));
    });
  });
}
