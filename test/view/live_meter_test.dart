import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/recording_view.dart';
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

  testWidgets('with no level source the meter is a flat line, not a canned '
      'animation', (tester) async {
    final harness = await _recording(tester);
    addTearDown(harness.dispose);

    await pumpScreen(tester, RecordingView(controller: harness.controller));

    // Nothing has been decoded, so there is nothing to draw.
    expect(harness.controller.level, isNull);
    final meter = tester.widget<LiveWaveform>(find.byType(LiveWaveform));
    expect(meter.isFlat, isTrue);

    // ...and it stays flat. A meter that moved here would be lying about the
    // microphone.
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.widget<LiveWaveform>(find.byType(LiveWaveform)).isFlat,
      isTrue,
    );

    expect(
      find.bySemanticsLabel('Level meter, no signal'),
      findsOneWidget,
    );
  });

  testWidgets('measured levels draw bars', (tester) async {
    final harness = await _recording(tester);
    addTearDown(harness.dispose);

    await pumpScreen(
      tester,
      RecordingView(
        controller: harness.controller,
        levels: const <double>[0.2, 0.5, 0.9],
      ),
    );

    final meter = tester.widget<LiveWaveform>(find.byType(LiveWaveform));
    expect(meter.isFlat, isFalse);
    expect(meter.levels, hasLength(3));
    expect(find.bySemanticsLabel('Level meter'), findsOneWidget);
  });

  test('the meter maps dBFS onto the band over a 60 dB window', () {
    // The mapping the recording screen uses. Silence sits on the floor, full
    // scale fills the band, and ordinary speech lands in between rather than
    // pinned at the top.
    expect(RecordingView.normalise(0), 1.0);
    expect(RecordingView.normalise(-60), 0.0);
    expect(RecordingView.normalise(-96), 0.0);
    expect(RecordingView.normalise(-30), closeTo(0.5, 0.001));
    expect(RecordingView.normalise(-12), closeTo(0.8, 0.001));
  });
}
