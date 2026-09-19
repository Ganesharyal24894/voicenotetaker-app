import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/decode_window.dart';
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
    // The measured number: 16 s beat 8 s on every set in
    // `notetaker-data/accuracy-20260918-205506/`, and 24 s and 30 s bought
    // nothing for a lot more memory. A change to it must be a deliberate one.
    test('IndicConformer is decoded in windows of at most 16 s at 16 kHz', () {
      const model = SpeechModels.indicConformerHindiInt8;
      expect(model.maxWindow, DecodeWindow.standard);
      expect(model.maxWindow, const Duration(seconds: 16));
      expect(model.sampleRateHz, 16000);
      expect(model.featureDim, 80);

      // 40 s of audio.
      final windows = WindowPlanner.forModel(model, 40 * 16000);
      expect(windows, <SampleRange>[
        const SampleRange(0, 256000),
        const SampleRange(256000, 512000),
        const SampleRange(512000, 640000),
      ]);
    });

    test('both models are cut on the same grid, so segment times match', () {
      expect(
        SpeechModels.parakeetTdtEnglishInt8.maxWindow,
        SpeechModels.indicConformerHindiInt8.maxWindow,
      );
    });

    test('a job short of memory may ask for shorter windows', () {
      const model = SpeechModels.indicConformerHindiInt8;
      final windows = WindowPlanner.forModel(
        model,
        20 * 16000,
        window: DecodeWindow.lowMemory,
      );

      expect(windows, <SampleRange>[
        const SampleRange(0, 128000),
        const SampleRange(128000, 256000),
        const SampleRange(256000, 320000),
      ]);
    });
  });
}
