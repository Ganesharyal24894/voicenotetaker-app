import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/auto_sleep.dart';
import 'package:voicenotetaker_app/model/model_download.dart';
import 'package:voicenotetaker_app/view/models_view.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';

import 'harness.dart';

/// Recorder settings - `Settings.dc.html`.
void main() {
  setUpAll(registerViewFallbacks);

  Widget screen(ViewHarness harness, {VoidCallback? onOpenDiagnostics}) =>
      SettingsView(
        controller: harness.controller,
        onBack: () {},
        onOpenDiagnostics: onOpenDiagnostics ?? () {},
      );

  const oneMinute =
      AutoSleepSetting(enabled: true, duration: AutoSleepDuration.minute1);

  bool selected(WidgetTester tester, String label) =>
      tester.widget<SegmentButton>(find.widgetWithText(SegmentButton, label)).selected;

  bool enabled(WidgetTester tester, String label) =>
      tester.widget<SegmentButton>(find.widgetWithText(SegmentButton, label)).enabled;

  testWidgets('three sections and the Diagnostics row; no pairing yet',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    var diagnostics = false;
    await pumpScreen(tester, screen(harness, onOpenDiagnostics: () => diagnostics = true));

    expect(find.text('Recorder settings'), findsOneWidget);
    expect(find.text('LISTENING'), findsOneWidget);
    expect(find.text('AUTO-SLEEP'), findsOneWidget);
    expect(find.text('AUDIO'), findsOneWidget);
    expect(find.text('PAIRING'), findsNothing);
    expect(find.text('Always listening'), findsOneWidget);
    expect(find.text('Sleep when still for'), findsOneWidget);
    expect(find.text('Delete audio after 24 h'), findsOneWidget);
    expect(find.text('Transcripts are kept. Notes you mark Keep are never deleted.'),
        findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Diagnostics'));
    expect(diagnostics, isTrue);
  });

  testWidgets('auto-sleep: not connected, nothing chosen and nothing tappable',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await pumpScreen(tester, screen(harness));

    for (final label in <String>['30 s', '1 min', '2 min', '5 min', 'Never']) {
      expect(selected(tester, label), isFalse, reason: label);
      expect(enabled(tester, label), isFalse, reason: label);
    }
    expect(find.text('Connect your recorder to change this.'), findsOneWidget);
  });

  testWidgets('auto-sleep: a recorder that did not answer says so',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readAutoSleep(any())).thenThrow(
      const BleTransportException('could not read the auto-sleep setting'),
    );
    await harness.connect(tester);
    await pumpScreen(tester, screen(harness));

    expect(enabled(tester, '1 min'), isFalse);
    expect(find.text("Couldn't read this from your recorder."), findsOneWidget);
  });

  testWidgets('auto-sleep: shows the recorder\'s choice and changes it',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readAutoSleep(any()))
        .thenAnswer((_) async => oneMinute);
    await harness.connect(tester);
    await pumpScreen(tester, screen(harness));

    expect(selected(tester, '1 min'), isTrue);
    expect(find.text('Wakes when you move. Longer uses more battery.'), findsOneWidget);

    await tester.tap(find.text('Never'));
    await flush(tester);

    verify(() => harness.transport
        .setAutoSleepDuration(knownDevice.id, AutoSleepDuration.off)).called(1);
    expect(selected(tester, 'Never'), isTrue);
    expect(selected(tester, '1 min'), isFalse);
  });

  testWidgets('auto-sleep: a refused change goes back and says so plainly',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readAutoSleep(any()))
        .thenAnswer((_) async => oneMinute);
    when(() => harness.transport.setAutoSleepDuration(any(), any()))
        .thenThrow(const BleTransportException('ATT 0x13'));
    await harness.connect(tester);
    await pumpScreen(tester, Scaffold(body: screen(harness)));

    await tester.tap(find.text('5 min'));
    await flush(tester);

    expect(selected(tester, '1 min'), isTrue);
    expect(find.text(AutoSleepCard.couldNotChange), findsOneWidget);
  });

  testWidgets('speech models: the row says what is on the phone and opens the '
      'screen', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    var opened = false;
    await pumpScreen(
      tester,
      SettingsView(
        controller: harness.controller,
        onBack: () {},
        onOpenDiagnostics: () {},
        onOpenModels: () => opened = true,
      ),
    );

    expect(find.text('SPEECH MODELS'), findsOneWidget);
    expect(find.text('Speech models'), findsOneWidget);
    // A build with no downloader wired in has nothing installed, and says so
    // rather than inventing a figure.
    expect(find.text('Nothing downloaded yet'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Speech models'));
    expect(opened, isTrue);
  });

  test('speech models: a phone with nothing installed goes to the picker', () {
    final nothing = <ModelInstallStatus>[
      for (final release in ModelCatalogue.all)
        ModelInstallStatus.unknown(release),
    ];
    expect(SettingsView.opensSetup(nothing), isTrue);

    final some = <ModelInstallStatus>[
      ModelInstallStatus(
        release: ModelCatalogue.hindiSpeech,
        state: ModelInstallState.installed,
      ),
      ModelInstallStatus.unknown(ModelCatalogue.englishSpeech),
    ];
    expect(SettingsView.opensSetup(some), isFalse);

    // A build with no downloader at all has nothing to pick from either.
    expect(SettingsView.opensSetup(const <ModelInstallStatus>[]), isFalse);
  });

  testWidgets('speech models: with no callback the row pushes the screen '
      'itself', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await pumpScreen(tester, screen(harness));

    await tester.tap(find.bySemanticsLabel('Speech models'));
    await tester.pumpAndSettle();

    expect(find.byType(ModelsSettingsView), findsOneWidget);
    expect(find.text(ModelsCopy.settingsBody), findsOneWidget);
  });

  testWidgets('audio: the switch is the retention setting', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await pumpScreen(tester, screen(harness));
    final audioSwitch = find.descendant(
      of: find.ancestor(of: find.text('Delete audio after 24 h'), matching: find.byType(Row)).first,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(audioSwitch).value, isFalse);

    await tester.tap(audioSwitch);
    await flush(tester);

    expect(harness.controller.autoDeleteAudio, isTrue);
    expect(tester.widget<Switch>(audioSwitch).value, isTrue);
  });

  testWidgets('fits a 390x844 phone without overflow', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readAutoSleep(any()))
        .thenAnswer((_) async => oneMinute);
    await harness.connect(tester);
    await pumpScreen(tester, screen(harness));
    expect(tester.takeException(), isNull);
  });
}
