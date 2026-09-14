import 'transcription.dart';

/// Turns the speech a voice-activity detector found into decode windows.
///
/// Pure arithmetic on sample indices, no I/O: it runs inside the recognizer's
/// worker (which has the audio) and in unit tests alike.
///
/// WHY. A fixed 8 s grid cuts words in half wherever a boundary lands, and
/// where it lands moved CER by 13 points in the laptop run. Cutting in the
/// pauses instead removes that, and leaving silence out removes decode work.
///
/// THE RULES, in order:
///
///   1. segments are clamped to the audio, sorted, and overlapping or touching
///      ones merged;
///   2. a segment longer than the window is split on the fixed grid - the
///      detector is configured to split long speech itself, so this is a
///      backstop rather than the normal path;
///   3. each segment gets up to [plan]'s `padSamples` of silence either side,
///      never more than half the gap to its neighbour (so windows never
///      overlap) and never so much that it outgrows the window;
///   4. consecutive segments are packed into one window while the whole span,
///      pauses included, still fits - fewer, fuller windows, each cut in a
///      pause.
///
/// Every window is at most `maxWindowSamples` long, windows are in order and
/// do not overlap, and every sample of speech is inside exactly one window.
abstract final class SpeechWindows {
  static List<SampleRange> plan({
    required List<SampleRange> speech,
    required int totalSamples,
    required int maxWindowSamples,
    int padSamples = 0,
  }) {
    if (totalSamples < 0) {
      throw ArgumentError.value(totalSamples, 'totalSamples', 'must be >= 0');
    }
    if (maxWindowSamples <= 0) {
      throw ArgumentError.value(
          maxWindowSamples, 'maxWindowSamples', 'must be > 0');
    }
    if (padSamples < 0) {
      throw ArgumentError.value(padSamples, 'padSamples', 'must be >= 0');
    }

    // 1. Clamp, sort, merge.
    final clamped = <SampleRange>[
      for (final range in speech)
        if (range.start < totalSamples && range.end > range.start)
          SampleRange(
            range.start,
            range.end > totalSamples ? totalSamples : range.end,
          ),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <SampleRange>[];
    for (final range in clamped) {
      if (merged.isNotEmpty && range.start <= merged.last.end) {
        final last = merged.removeLast();
        merged.add(
          SampleRange(last.start, range.end > last.end ? range.end : last.end),
        );
      } else {
        merged.add(range);
      }
    }

    // 2. Split what is too long.
    final pieces = <SampleRange>[
      for (final range in merged)
        for (var start = range.start;
            start < range.end;
            start += maxWindowSamples)
          SampleRange(
            start,
            start + maxWindowSamples < range.end
                ? start + maxWindowSamples
                : range.end,
          ),
    ];

    // 3. Pad into the surrounding silence.
    final padded = <SampleRange>[];
    for (var i = 0; i < pieces.length; i++) {
      final piece = pieces[i];
      final before = i == 0 ? piece.start : piece.start - pieces[i - 1].end;
      final after = i == pieces.length - 1
          ? totalSamples - piece.end
          : pieces[i + 1].start - piece.end;
      // Shared gaps are split: the left half belongs to the piece before, the
      // right half to the piece after, so neighbours can never overlap.
      var left = i == 0 ? before : before - before ~/ 2;
      var right = i == pieces.length - 1 ? after : after ~/ 2;
      if (left > padSamples) left = padSamples;
      if (right > padSamples) right = padSamples;
      var room = maxWindowSamples - piece.length;
      if (left > room) left = room;
      room -= left;
      if (right > room) right = room;
      padded.add(SampleRange(piece.start - left, piece.end + right));
    }

    // 4. Pack.
    final windows = <SampleRange>[];
    for (final range in padded) {
      if (windows.isNotEmpty &&
          range.end - windows.last.start <= maxWindowSamples) {
        windows.add(SampleRange(windows.removeLast().start, range.end));
      } else {
        windows.add(range);
      }
    }
    return List<SampleRange>.unmodifiable(windows);
  }
}
