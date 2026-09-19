import '../../model/decode_window.dart';
import '../../model/transcription.dart';

/// Splits a recording into the windows a speech model decodes one at a time.
///
/// WHY WINDOWS AT ALL. The IndicConformer export silently drops the middle of
/// a long clip decoded in one call, so audio is never handed to it in pieces
/// longer than [SpeechModel.maxWindow], which is [DecodeWindow.standard] -
/// the one place the length is decided, and where the measurement that chose
/// it is written down.
///
/// WHY FIXED WINDOWS BY DEFAULT. They are what the prior research measured, and
/// they need nothing but arithmetic. Their known cost is that a boundary can
/// fall in the middle of a word, which then comes out garbled on both sides.
/// Voice-activity segmentation (`model/speech_windows.dart`, run inside the
/// recognizer) cuts in the pauses instead; it is behind a flag until measured,
/// and this grid is always the fallback when its model is not installed.
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
  ///
  /// [window] overrides [SpeechModel.maxWindow] for one job - the low-memory
  /// fallback of [DecodeWindow.forAvailableMemory] is the only caller that
  /// passes it.
  static List<SampleRange> forModel(
    SpeechModel model,
    int totalSamples, {
    Duration? window,
  }) =>
      fixed(
        totalSamples: totalSamples,
        windowSamples: (window ?? model.maxWindow).inMicroseconds *
            model.sampleRateHz ~/
            1000000,
      );
}
