import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/recording_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/waveform.dart';

import 'harness.dart';

Future<ViewHarness> _recording(WidgetTester tester) async {
  final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
  await harness.discover(tester);
  await harness.connect(tester);
  await harness.record(tester);
  return harness;
}

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('shows the timer and the stop control while recording',
      (tester) async {
    final harness = await _recording(tester);
    addTearDown(harness.dispose);

    await pumpScreen(tester, RecordingView(controller: harness.controller));

    expect(harness.controller.isRecording, isTrue);
    expect(find.text('Recording'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.bySemanticsLabel('Stop recording'), findsOneWidget);
    expect(find.byType(LiveWaveform), findsOneWidget);
    expect(find.text('Saving to your phone'), findsOneWidget);
  });

  testWidgets('the timer ticks', (tester) async {
    final harness = await _recording(tester);
    addTearDown(harness.dispose);

    // The widget tester's clock is fake, so drive the screen's clock by hand
    // rather than relying on the wall clock inside the test zone.
    var now = DateTime(2026, 9, 10, 14, 30);
    // A key of its own guarantees a fresh State - and therefore an initState
    // that reads the injected clock - even if another RecordingView has
    // already occupied this position in the tree.
    await pumpScreen(
      tester,
      RecordingView(
        key: UniqueKey(),
        controller: harness.controller,
        clock: () => now,
      ),
    );
    expect(find.text('00:00'), findsOneWidget);

    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:03'), findsOneWidget);

    now = now.add(const Duration(seconds: 59));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('01:02'), findsOneWidget);
  });

  testWidgets('the timer is drawn thin, large and tabular', (tester) async {
    final harness = await _recording(tester);
    addTearDown(harness.dispose);

    await pumpScreen(tester, RecordingView(controller: harness.controller));

    final timer = tester.widget<Text>(find.text('00:00'));
    expect(timer.style, AppText.timer);
  });

  testWidgets('the stop control stops the capture', (tester) async {
    final harness = await _recording(tester);
    addTearDown(harness.dispose);

    await pumpScreen(tester, RecordingView(controller: harness.controller));

    await tester.tap(find.bySemanticsLabel('Stop recording'));
    await flush(tester);

    expect(harness.controller.isRecording, isFalse);
    expect(harness.controller.phase, AppPhase.connected);
  });

  testWidgets('the stop control clears the 44px minimum', (tester) async {
    final harness = await _recording(tester);
    addTearDown(harness.dispose);

    await pumpScreen(tester, RecordingView(controller: harness.controller));

    final size = tester.getSize(find.bySemanticsLabel('Stop recording'));
    expect(size.width, greaterThanOrEqualTo(AppShape.minTapTarget));
    expect(size.height, greaterThanOrEqualTo(AppShape.minTapTarget));
  });

  testWidgets('peak level renders as unknown until a level meter exists',
      (tester) async {
    final harness = await _recording(tester);
    addTearDown(harness.dispose);

    await pumpScreen(tester, RecordingView(controller: harness.controller));

    expect(find.text('peak'), findsOneWidget);
    expect(find.text('— dBFS'), findsOneWidget);
  });

  test('the waveform reproduces the mock and colours by height', () {
    expect(LiveWaveform.mockHeights, hasLength(32));
    expect(LiveWaveform.colorForLevel(14 / 118), AppColors.waveFloor);
    expect(LiveWaveform.colorForLevel(58 / 118), AppColors.purple700);
    expect(LiveWaveform.colorForLevel(112 / 118), AppColors.purple300);
  });
}
