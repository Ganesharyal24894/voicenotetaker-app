import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/auto_sleep.dart';
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

  testWidgets('auto-sleep: older firmware says to update', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.connect(tester);
    await pumpScreen(tester, screen(harness));

    expect(enabled(tester, '1 min'), isFalse);
    expect(find.text('Update your recorder to change this.'), findsOneWidget);
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
