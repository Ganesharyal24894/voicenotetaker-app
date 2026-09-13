import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/window_planner.dart';

void main() {
  group('WindowPlanner.fixed', () {
    test('no audio, no windows', () {
      expect(WindowPlanner.fixed(totalSamples: 0, windowSamples: 10), isEmpty);
    });

    test('audio shorter than a window is one window', () {
      expect(
        WindowPlanner.fixed(totalSamples: 7, windowSamples: 10),
        <SampleRange>[const SampleRange(0, 7)],
      );
    });

    test('an exact multiple leaves no empty tail', () {
      expect(
        WindowPlanner.fixed(totalSamples: 30, windowSamples: 10),
        <SampleRange>[
          const SampleRange(0, 10),
          const SampleRange(10, 20),
          const SampleRange(20, 30),
        ],
      );
    });

    test('the remainder becomes a short last window', () {
      expect(
        WindowPlanner.fixed(totalSamples: 25, windowSamples: 10).last,
        const SampleRange(20, 25),
      );
    });

    test('windows cover every sample exactly once, and none is too long', () {
      for (final total in <int>[1, 9, 10, 11, 99, 100, 101, 12345]) {
        final windows = WindowPlanner.fixed(
          totalSamples: total,
          windowSamples: 10,
        );
        var expectedStart = 0;
        for (final window in windows) {
          expect(window.start, expectedStart);
          expect(window.length, inInclusiveRange(1, 10));
          expectedStart = window.end;
        }
        expect(expectedStart, total);
      }
    });

    test('rejects nonsense sizes', () {
      expect(
        () => WindowPlanner.fixed(totalSamples: -1, windowSamples: 10),
        throwsArgumentError,
      );
      expect(
        () => WindowPlanner.fixed(totalSamples: 10, windowSamples: 0),
        throwsArgumentError,
      );
    });
  });

  group('WindowPlanner.forModel', () {
    // The load-bearing number: this export drops the middle of anything
    // longer, so a change to the window must be a deliberate one.
    test('IndicConformer is decoded in windows of at most 8 s at 16 kHz', () {
      const model = SpeechModels.indicConformerHindiInt8;
      expect(model.maxWindow, const Duration(seconds: 8));
      expect(model.sampleRateHz, 16000);
      expect(model.featureDim, 80);

      // 20 s of audio.
      final windows = WindowPlanner.forModel(model, 20 * 16000);
      expect(windows, <SampleRange>[
        const SampleRange(0, 128000),
        const SampleRange(128000, 256000),
        const SampleRange(256000, 320000),
      ]);
    });
  });
}
