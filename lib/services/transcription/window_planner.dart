import '../../model/transcription.dart';

/// Splits a recording into the windows a speech model decodes one at a time.
///
/// WHY WINDOWS AT ALL. The IndicConformer export silently drops the middle of
/// a long clip decoded in one call, so audio is never handed to it in pieces
/// longer than [SpeechModel.maxWindow].
///
/// WHY FIXED WINDOWS, FOR NOW. They are what the prior research measured, and
/// they need nothing but arithmetic. Their known cost is that a boundary can
/// fall in the middle of a word, which then comes out garbled on both sides.
/// The better answer is voice-activity segmentation - `sherpa_onnx` ships
/// Silero and TEN VAD - but that needs a second model file on the device and
/// is a deliberate follow-up, not part of the feasibility spike. It slots in
/// here as another planner; nothing downstream cares how the ranges were
/// chosen.
abstract final class WindowPlanner {
  /// Consecutive, non-overlapping windows of [windowSamples] covering
  /// `[0, totalSamples)`. The last window is shorter when the audio does not
  /// divide evenly. No audio is dropped and none is decoded twice.
  static List<SampleRange> fixed({
    required int totalSamples,
    required int windowSamples,
  }) {
    if (totalSamples < 0) {
      throw ArgumentError.value(totalSamples, 'totalSamples', 'must be >= 0');
    }
    if (windowSamples <= 0) {
      throw ArgumentError.value(windowSamples, 'windowSamples', 'must be > 0');
    }
    return <SampleRange>[
      for (var start = 0; start < totalSamples; start += windowSamples)
        SampleRange(
          start,
          start + windowSamples < totalSamples
              ? start + windowSamples
              : totalSamples,
        ),
    ];
  }

  /// [fixed], sized from a model's own window and sample rate.
  static List<SampleRange> forModel(SpeechModel model, int totalSamples) =>
      fixed(
        totalSamples: totalSamples,
        windowSamples:
            model.maxWindow.inMicroseconds * model.sampleRateHz ~/ 1000000,
      );
}
