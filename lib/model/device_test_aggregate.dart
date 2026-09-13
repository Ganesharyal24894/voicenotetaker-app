/// Several samples of one device test, reduced to a figure and its spread.
///
/// WHY THIS FILE EXISTS. Both acoustic measurements are noisy. A noise floor
/// depends on the fridge compressor, and a sensitivity figure depends on
/// exactly where a head was when it spoke. ONE reading before the enclosure and
/// one after cannot be compared: the difference between them is the difference
/// between two single draws from two noisy processes, and it will happily show
/// a 3 dB "improvement" that is nothing at all.
///
/// THE BARE-BOARD BASELINE IS WHAT MAKES THAT CONCRETE. Five runs on the open
/// board put the sensitivity spread at 0.83 dB - tight enough that a real change
/// caused by the enclosure's port will stand clear of it, but only because the
/// spread was measured rather than assumed.
///
/// So the screen takes n samples and this file reduces them. It reports:
///
///   * a MEDIAN, not a mean. One bad sample - a dropout, a door slamming, a
///     scan the OS throttled - moves a mean of seven by a seventh of its error
///     and moves a median of seven not at all.
///   * the full RANGE, min to max. Not a standard deviation: nothing here is
///     known to be normally distributed and n is single digits, where a sample
///     SD is itself mostly noise. Not an inter-quartile range either, and that
///     is a deliberate choice - at these n the IQR discards exactly the extreme
///     readings that a resonance or a slammed door shows up as. The wildest
///     sample is usually the most interesting one here, so the spread that is
///     reported is the one that contains it. The price of that choice is that
///     the expected range GROWS with n, so a range is only comparable against
///     another range of similar size - which is why [DeviceTestSampling] fixes
///     the counts and why every batch prints its own n.
///
/// NOTHING IS EXCLUDED FROM THE MEDIAN. A sample with no reading at all - a
/// failed run, or a window in which no audio arrived - cannot enter a median, so
/// it is COUNTED and reported as [ReadingSpread.missing] instead of being
/// quietly forgotten: the screen says "n=4 of 5, one had no reading" rather
/// than "n=4".
///
/// Pure data and pure arithmetic: no I/O, no formatting, no clock. The strings
/// a human reads are assembled in `view/`.
library;

import 'device_test_result.dart';

/// How many samples a check takes, and which checks can take them unattended.
///
/// IN `model/` RATHER THAN BESIDE THE LOOP THAT USES IT. The screen names the
/// counts, the controller passes them, the service performs them and the tests
/// assert on them; a constant in any one of those four would have the other
/// three quoting a number they could not see.
///
/// THE COUNTS ARE FIXED AND THERE IS NO CONTROL FOR THEM. There used to be one
/// on the diagnostics screen, and it was wrong: diagnostics is a screen for
/// OBSERVERS, and a sample-count selector asks somebody to reason about
/// sampling statistics before they are allowed to look at their own microphone.
/// Worse, a knob means two batches on the same phone can be taken at different
/// n - and n is precisely what makes two batches comparable, because the spread
/// this file reports is a RANGE and the expected range of a sample grows with
/// its size. Fixing the counts here is what lets "Latest beside Before" be read
/// as a measurement rather than as an artefact of how patient somebody felt.
///
/// A developer who wants another n still has one: `DeviceTestService.run…` takes
/// `repeats` and always has. It is simply not a thing the UI asks about.
abstract final class DeviceTestSampling {
  /// Samples the noise floor takes: SEVEN.
  ///
  /// This check is fully unattended - the operator's whole job is to leave the
  /// room alone - so samples cost nobody anything but the recorder's time, and
  /// seven ten-second windows is a little over a minute of leaving it be.
  ///
  /// Seven rather than five because the extra two are nearly free here and buy
  /// a median that survives THREE bad samples instead of two, which is the
  /// difference between tolerating one fridge compressor cycle and tolerating a
  /// compressor plus a lorry. Seven rather than nine or ten because the range
  /// is what gets compared against the bare-board baseline, that baseline was
  /// taken at n=5, and the expected range of a normal sample runs about 2.33σ
  /// at n=5, 2.70σ at n=7 and 3.08σ at n=10 - so nine or ten would inflate the
  /// spread by a quarter against the baseline for no reason other than arithmetic
  /// and read as the enclosure adding variability it did not add. Seven keeps
  /// that inflation to about a sixth, and the card prints the n of every batch
  /// beside its range so the difference is visible rather than implied.
  ///
  /// Odd, so the median is a sample somebody measured rather than the mean of
  /// the two middle ones - the one place this file would otherwise report a
  /// number nobody took.
  static const int noiseFloorSamples = 7;

  /// Samples the sensitivity check takes: THREE.
  ///
  /// EVERY SAMPLE OF THIS ONE COSTS A HUMAN. Somebody has to stand at
  /// [DeviceTestReadings.sensitivityDistanceCm] and speak, once per sample, and
  /// the check stops and waits for them in between. Five of those is tedious in
  /// the specific way that stops a check being run at all - and a check nobody
  /// runs measures nothing, which is worse than a check run at n=3.
  ///
  /// Three is the smallest count that still reports both things this file exists
  /// for: an odd median, which one bad sample cannot move, and a range, which
  /// needs at least two. The range from three samples is narrower than the
  /// baseline's five by about a quarter for purely combinatorial reasons - the
  /// same arithmetic as above, in the other direction - so a spread that LOOKS
  /// tighter than the baseline's is not news. A spread that looks WIDER at n=3
  /// than the baseline's at n=5 very much is.
  static const int sensitivitySamples = 3;

  /// How many samples [kind] takes. Not a setting - see the class comment.
  static int samplesFor(DeviceTestKind kind) => switch (kind) {
        DeviceTestKind.noiseFloor => noiseFloorSamples,
        DeviceTestKind.sensitivity => sensitivitySamples,
      };

  /// Whether [kind] can take its next sample with nobody present.
  ///
  /// The noise floor only needs the device left alone, so it loops on its own.
  /// The sensitivity check IS the operator: somebody speaks at the marked
  /// distance. Looping that unattended would record silence and report it as a
  /// quiet voice.
  static bool isAutomatic(DeviceTestKind kind) => switch (kind) {
        DeviceTestKind.noiseFloor => true,
        DeviceTestKind.sensitivity => false,
      };
}

/// One reading label measured across the samples of a batch.
class ReadingSpread {
  const ReadingSpread({
    required this.label,
    required this.unit,
    required this.values,
    required this.missing,
  });

  /// Reads [label] out of every run in [runs].
  ///
  /// Runs whose reading is absent, or present with a null value, are counted in
  /// [missing] rather than dropped - see the library comment.
  factory ReadingSpread.of(String label, Iterable<DeviceTestResult> runs) {
    final values = <num>[];
    var missing = 0;
    var unit = '';
    for (final run in runs) {
      final reading = run.reading(label);
      // The unit is taken from any sample that carries one, INCLUDING one whose
      // value is null: `— dBm` needs the unit to read correctly, and a batch
      // where nothing was measured would otherwise lose it.
      if (reading != null && unit.isEmpty) unit = reading.unit;
      final value = reading?.value;
      if (value == null) {
        missing++;
        continue;
      }
      values.add(value);
    }
    values.sort();
    return ReadingSpread(
      label: label,
      unit: unit,
      values: List<num>.unmodifiable(values),
      missing: missing,
    );
  }

  final String label;

  /// `dBFS`, `dBm`, `%`, `s`, or empty for a plain count.
  final String unit;

  /// Every sample that had a value, ASCENDING.
  ///
  /// Kept in full rather than reduced to three numbers, because the screen
  /// shows them: a single wild reading is often the most interesting result in
  /// the batch, and it can only be seen if it is on the page.
  final List<num> values;

  /// Samples that had no value for this label. Never folded into a zero.
  final int missing;

  /// Samples that contributed to [median] - the `n` the screen quotes.
  int get n => values.length;

  /// Samples taken, whether or not they produced this reading.
  int get sampleCount => values.length + missing;

  /// The middle sample, or the mean of the two middle ones when [n] is even.
  ///
  /// The even case is the only place this file reports a number nobody
  /// measured, which is one reason the default sample count is odd.
  num? get median {
    if (values.isEmpty) return null;
    final middle = values.length ~/ 2;
    if (values.length.isOdd) return values[middle];
    return (values[middle - 1] + values[middle]) / 2;
  }

  num? get min => values.isEmpty ? null : values.first;

  num? get max => values.isEmpty ? null : values.last;

  /// `max - min`, or null with fewer than two samples.
  ///
  /// THE NUMBER THAT DECIDES WHETHER A BEFORE-AND-AFTER DIFFERENCE MEANS
  /// ANYTHING. A 3 dB change against a spread of 10 dB is noise.
  num? get spread =>
      values.length < 2 ? null : values.last - values.first;

  /// True when there is more than one sample, so a spread can be quoted.
  bool get hasSpread => values.length >= 2;

  @override
  String toString() => 'ReadingSpread($label, n=$n, median=$median, '
      'min=$min, max=$max, missing=$missing)';
}

/// The samples of one test taken as one batch - the unit of comparison.
///
/// "Latest beside Before" compares two of these, never two single runs.
class DeviceTestBatch {
  DeviceTestBatch({required this.kind, required List<DeviceTestResult> runs})
      : assert(runs.isNotEmpty, 'a batch with no runs is not a batch'),
        runs = List<DeviceTestResult>.unmodifiable(runs);

  final DeviceTestKind kind;

  /// The samples, OLDEST FIRST - the order they were measured in, which is the
  /// order a reader wants them in when looking for drift inside one batch.
  final List<DeviceTestResult> runs;

  /// Identifies the batch, or null for a run saved before batches existed (and
  /// for anything else that ran on its own).
  String? get batchId => runs.first.batchId;

  /// Samples actually collected. THE n, and it is quoted everywhere.
  int get sampleCount => runs.length;

  /// Samples that were asked for, which can be more than were taken.
  int get requested {
    var most = 1;
    for (final run in runs) {
      if (run.repeatTarget > most) most = run.repeatTarget;
    }
    return most < sampleCount ? sampleCount : most;
  }

  /// True when the operator stopped early, or a sample failed and ended it.
  ///
  /// A partial batch is USABLE, not discarded: three samples aggregated and
  /// labelled n=3 beat five samples thrown away.
  bool get isPartial => sampleCount < requested;

  /// A single run - the weakest comparison there is, and the screen says so.
  bool get isSingle => sampleCount == 1;

  /// When the first sample started.
  DateTime get startedAt => runs.first.startedAt;

  /// When the last sample started.
  DateTime get endedAt => runs.last.startedAt;

  int countOf(DeviceTestOutcome outcome) =>
      runs.where((run) => run.outcome == outcome).length;

  /// Whether any sample in the batch produced a number worth comparing.
  bool get hasReadings => runs.any((run) => run.hasReadings);

  /// [label] across every sample of the batch.
  ReadingSpread spreadOf(String label) => ReadingSpread.of(label, runs);

  /// Groups [newestFirst] - the store's own order - into batches.
  ///
  /// Batches come back NEWEST FIRST, each with its own runs oldest first.
  ///
  /// A run with no [DeviceTestResult.batchId] becomes a batch of one. That is
  /// what every result saved before this existed looks like, and treating it as
  /// n=1 is the honest reading of it: it WAS one run.
  static List<DeviceTestBatch> group(Iterable<DeviceTestResult> newestFirst) {
    final groups = <String, List<DeviceTestResult>>{};
    final order = <String>[];
    var loners = 0;
    for (final run in newestFirst) {
      final id = run.batchId;
      // The kind is part of the key as well as the id. Two tests can never
      // share a batch, whatever a hand-edited or future file claims.
      final key = id == null
          ? 'lone-${loners++}'
          : '${run.kind.wireName} $id';
      final bucket = groups[key];
      if (bucket == null) {
        groups[key] = <DeviceTestResult>[run];
        order.add(key);
      } else {
        bucket.add(run);
      }
    }
    return <DeviceTestBatch>[
      for (final key in order)
        DeviceTestBatch(
          kind: groups[key]!.first.kind,
          // The store hands out newest first; within a batch the measuring
          // order is what reads correctly.
          runs: groups[key]!.reversed.toList(growable: false),
        ),
    ];
  }

  @override
  String toString() =>
      'DeviceTestBatch(${kind.wireName}, n=$sampleCount of $requested)';
}
