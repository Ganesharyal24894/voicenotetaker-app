/// One batch's headline reading set against the batch before it.
///
/// WHY A COMPARISON AND NOT A VERDICT. A single acoustic reading means nothing
/// to the person holding the recorder. `−39 dBFS` is not good, is not bad, and
/// is not even interesting; what is interesting is whether it moved since the
/// last time, because that is the one question a saved baseline can answer. So
/// this file reduces two batches to one of six statements, and none of them is
/// a judgement.
///
/// WHAT COUNTS AS "ABOUT THE SAME" IS MEASURED, NOT CHOSEN. Both readings wobble
/// from one sample to the next - a fridge compressor, a head half a step further
/// from the microphone - and the batches on disk already say by how much:
/// [ReadingSpread.spread] is the full min-to-max range of the samples that
/// produced the median. A difference between two medians that is no wider than
/// that wobble is not evidence of anything, so the threshold IS the wobble:
///
///   * the wider of the two compared batches' own spreads, because a change has
///     to clear the noisiest evidence there is rather than the quietest;
///   * failing that - two batches of one sample each, which is what every run
///     saved before batching existed looks like - the widest spread any other
///     saved batch of the same check measured, passed in as [fallback];
///   * failing that, nothing. No batch of this check ever took two samples, so
///     there is no measured wobble to test against and the honest answer is
///     [ReadingChange.notComparable] rather than an invented threshold.
///
/// Nothing here is hard-coded: change the sample counts, change the check, and
/// the threshold follows the data. What it deliberately does NOT do is assume a
/// distribution - no standard deviations, no confidence intervals. At the single
/// digit sample counts [DeviceTestSampling] fixes, a sample SD is itself mostly
/// noise, and the full range is the statistic the rest of this layer already
/// reports.
///
/// Pure arithmetic over [ReadingSpread]: no clock, no I/O, no strings a human
/// reads. The words are in `view/mic_check_copy.dart`.
library;

import 'device_test_aggregate.dart';

/// Which of the six things can truthfully be said about a reading.
///
/// NONE OF THESE IS "GOOD" OR "BAD", and none of them can become one. The
/// screen's rule is that it compares and never judges, and an enum with no
/// verdict in it is how that rule is kept by construction rather than by
/// remembering.
enum ReadingChange {
  /// This is the first batch of this check. There is nothing behind it.
  noPrevious,

  /// The latest batch produced no number for this reading at all.
  notMeasured,

  /// There is an earlier batch, but the two cannot be set against each other:
  /// it has no number either, or no batch of this check ever measured a spread
  /// to compare a difference against.
  notComparable,

  /// The two medians differ by no more than the measured wobble.
  same,

  /// The latest median is above the previous one by more than the wobble.
  higher,

  /// The latest median is below the previous one by more than the wobble.
  lower,
}

/// The comparison itself, with every number that went into it kept.
///
/// The numbers are kept rather than discarded because the screen shows the
/// value on the same line as the change, and because a test that can only see
/// the verdict cannot tell a correct threshold from a lucky one.
class ReadingComparison {
  const ReadingComparison({
    required this.change,
    required this.unit,
    this.latest,
    this.previous,
    this.threshold,
  });

  /// Sets [latest] against [previous], deriving the threshold from the data.
  ///
  /// [fallback] is every OTHER saved batch's spread for the same reading,
  /// consulted only when neither compared batch measured a spread of its own.
  /// Order does not matter; the widest is taken.
  factory ReadingComparison.between({
    required ReadingSpread latest,
    ReadingSpread? previous,
    Iterable<ReadingSpread> fallback = const <ReadingSpread>[],
  }) {
    // The unit is taken from whichever spread carries one: a batch in which
    // nothing was measured still has to render as `— dBFS`.
    final unit = latest.unit.isNotEmpty
        ? latest.unit
        : (previous?.unit ?? '');
    final value = latest.median;
    if (value == null) {
      return ReadingComparison(
        change: ReadingChange.notMeasured,
        unit: unit,
        previous: previous?.median,
      );
    }
    if (previous == null) {
      return ReadingComparison(
        change: ReadingChange.noPrevious,
        unit: unit,
        latest: value,
      );
    }
    final was = previous.median;
    final threshold = _wobble(latest, previous, fallback);
    if (was == null || threshold == null) {
      return ReadingComparison(
        change: ReadingChange.notComparable,
        unit: unit,
        latest: value,
        previous: was,
        threshold: threshold,
      );
    }
    final difference = value - was;
    return ReadingComparison(
      // AT THE THRESHOLD IT IS THE SAME. A difference exactly as wide as the
      // wobble has not cleared it, and the tie has to fall somewhere: it falls
      // on the side that claims less.
      change: difference.abs() <= threshold
          ? ReadingChange.same
          : difference > 0
              ? ReadingChange.higher
              : ReadingChange.lower,
      unit: unit,
      latest: value,
      previous: was,
      threshold: threshold,
    );
  }

  final ReadingChange change;

  /// `dBFS`, `%`, or empty - whatever the saved readings carried.
  final String unit;

  /// The latest batch's median, or null when it measured nothing.
  final num? latest;

  /// The previous batch's median, or null when there was none or it measured
  /// nothing.
  final num? previous;

  /// The wobble the difference had to clear, or null when none was measured.
  ///
  /// Exposed so the screen's Details can say what the comparison was made
  /// against, and so a test asserts on the derivation rather than on a literal.
  final num? threshold;

  /// `latest - previous`, signed, or null when either is missing.
  num? get difference {
    final now = latest;
    final was = previous;
    if (now == null || was == null) return null;
    return now - was;
  }

  /// True for the three outcomes that are a comparison rather than an excuse.
  bool get isComparison =>
      change == ReadingChange.same ||
      change == ReadingChange.higher ||
      change == ReadingChange.lower;

  /// The widest spread available, preferring the two batches being compared.
  static num? _wobble(
    ReadingSpread latest,
    ReadingSpread previous,
    Iterable<ReadingSpread> fallback,
  ) =>
      _widest(<ReadingSpread>[latest, previous]) ?? _widest(fallback);

  static num? _widest(Iterable<ReadingSpread> spreads) {
    num? widest;
    for (final spread in spreads) {
      final value = spread.spread;
      if (value == null) continue;
      if (widest == null || value > widest) widest = value;
    }
    return widest;
  }

  @override
  String toString() => 'ReadingComparison(${change.name}, latest=$latest, '
      'previous=$previous, threshold=$threshold)';
}
