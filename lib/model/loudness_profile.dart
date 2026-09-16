/// How loud a recording is, moment by moment - enough of it to find a pause
/// in, and no more.
///
/// PURE: built from numbers, asked with numbers. Whoever has the audio fills
/// [frames] in (`TranscriptionService` reads the WAV a chunk at a time); this
/// file knows nothing about files.
///
/// WHY IT EXISTS. A speaker's turn longer than the speech model's window has
/// to be cut somewhere, and cutting through a word garbles it on both sides.
/// The quietest stretch in the allowed range is the best guess at a pause
/// without running a second model over the audio. One number per frame - about
/// 25 kB for a ten-minute note - is all that takes.
library;

class LoudnessProfile {
  const LoudnessProfile({required this.frameSamples, required this.frames});

  /// Nothing measured: every question answers null, and callers fall back to
  /// the fixed grid.
  static const LoudnessProfile empty =
      LoudnessProfile(frameSamples: 1, frames: <int>[]);

  /// How many samples each entry of [frames] covers.
  final int frameSamples;

  /// Mean absolute sample value in each frame, in order from sample 0.
  final List<int> frames;

  bool get isEmpty => frames.isEmpty;

  /// The middle of the quietest stretch [probeSamples] long inside
  /// `[start, end)`, or null when nothing that long fits or there is no
  /// profile.
  ///
  /// The earliest of equally quiet stretches wins, so the answer does not move
  /// when a recording is measured again.
  int? quietestSplit(int start, int end, int probeSamples) {
    if (frames.isEmpty || frameSamples <= 0 || probeSamples <= 0) return null;
    if (end <= start) return null;
    final probeFrames = probeSamples ~/ frameSamples;
    final width = probeFrames < 1 ? 1 : probeFrames;
    final first = (start + frameSamples - 1) ~/ frameSamples;
    // The last frame index at which a whole probe still ends by [end].
    final last = (end ~/ frameSamples) - width;
    if (last < first) return null;
    var best = -1;
    var bestSum = 0;
    for (var i = first; i <= last; i++) {
      if (i + width > frames.length) break;
      var sum = 0;
      for (var j = i; j < i + width; j++) {
        sum += frames[j];
      }
      if (best < 0 || sum < bestSum) {
        best = i;
        bestSum = sum;
      }
    }
    if (best < 0) return null;
    final middle = (best * frameSamples) + (width * frameSamples) ~/ 2;
    if (middle <= start || middle >= end) return null;
    return middle;
  }
}
