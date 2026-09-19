/// How much audio the speech model is given in one decode call.
///
/// ONE PLACE. Every window in the app - the fixed grid, the voice-activity
/// planner's cap, the speaker-turn splitter - is sized from [standard]. It is
/// here, on its own, because it is the single tuning constant with the largest
/// measured effect on accuracy, and because changing it changes peak memory.
library;

/// The decode window, and the shorter one a low-memory phone falls back to.
///
/// WHY 16 s, MEASURED. An evaluation agent ran the app's own pipeline
/// (sherpa-onnx 1.13.8, the same IndicConformer int8 export) over 600
/// benchmark utterances with human references and over the owner's own notes,
/// at 8, 12, 16, 24 and 30 s. Harness, runs and `RESULTS.md` are in
/// `notetaker-data/accuracy-20260918-205506/`:
///
/// | window | gramvaani-300 WER / CER (human refs, router off) | MUCS code-switched WER | owner's notes, SHIPPED diarize-then-decode path: WER / CER / decodes | peak RSS, one note |
/// |---|---|---|---|---|
/// | 8 s (shipped before) | 30.45 / 15.74 | 52.05 | 59.41 / 52.90 / 189 | 432 MB |
/// | 12 s | 28.83 / 14.62 | - | - | - |
/// | **16 s (here)** | **28.65 / 14.49** | **50.73** | **57.53 / 50.62 / 116** | **509 MB** |
/// | 24 s | 28.70 / 14.43 | - | - | 549 MB |
/// | 30 s | 28.63 / 14.42 | - | - | 735 MB |
///
/// 16 s is the knee: past it accuracy stops moving and memory does not. It
/// also makes the phone do LESS work - 189 decodes become 116 on the same
/// notes, because a speaker turn that used to be cut in two is now decoded
/// whole.
///
/// WHAT IS NOT NEGOTIABLE: that there IS a window. The IndicConformer export
/// silently drops the middle of a clip decoded in one call, which is why the
/// audio is always handed over in pieces.
abstract final class DecodeWindow {
  /// The window every model is decoded in, unless memory says otherwise.
  static const Duration standard = Duration(seconds: 16);

  /// What the app decoded in until this change, and what it falls back to when
  /// the phone is short of memory. Measured, shipped for months, and 3.4 WER
  /// worse - a worse transcript beats a killed job.
  static const Duration lowMemory = Duration(seconds: 8);

  /// Below this much free system memory, [forAvailableMemory] picks
  /// [lowMemory].
  ///
  /// WHERE THE NUMBER COMES FROM. Measured on the owner's Xiaomi (SD732G,
  /// debug build): the app idles near 373 MB and a transcription peaks near
  /// 700-726 MB, so one job needs roughly 350 MB of headroom over idle at 8 s.
  /// The 16 s window measured +77 MB on top of that on the laptop
  /// (432 -> 509 MB), which is the closest thing to a figure we have for the
  /// phone. 512 MB of MemAvailable is that ~430 MB plus a small margin: enough
  /// room for the job, and a signal that the phone is not already scraping.
  /// It is a threshold on a guess about a measurement made elsewhere - if the
  /// phone ever reports a killed job, this is the number to move first.
  static const int lowMemoryBelowKb = 512 * 1024;

  /// The window for a job on a phone reporting [availableKb] free
  /// (`MemAvailable`, see `drivers/process_memory.dart`).
  ///
  /// UNKNOWN MEANS FULL SIZE. `null` is every platform without `/proc`
  /// (iOS, macOS): there is nothing to be cautious with, and every
  /// measurement that motivates the fallback is Android's.
  static Duration forAvailableMemory(int? availableKb) =>
      availableKb != null && availableKb < lowMemoryBelowKb
      ? lowMemory
      : standard;
}
