/// Every string the mic check card shows, assembled away from the widget tree.
///
/// WHY THIS IS NOT INLINE IN `diagnostics_view.dart`. The card was rewritten
/// because it showed too much: one check rendered a date, a sample count, a
/// status phrase, a median, a range and every individual sample - about fifteen
/// numbers to answer "is my mic OK?". The fix is a ONE-LINE headline and a
/// collapsed disclosure for the rest, and "one line" is a measurement: the lines
/// here are laid out at the width a 390px phone gives them, in the real Sora, by
/// `test/view/diagnostics_copy_test.dart`. A string built inside a `build`
/// method cannot be measured without building the screen, so the strings live
/// here and the widget only places them.
///
/// IT COMPARES AND NEVER JUDGES. Nothing in this file says good, bad, fine,
/// healthy or a problem, and there is no code path that could: the words come
/// from [ReadingChange], which has no verdict in it. The most any line says is
/// that a reading moved, and whether a difference counts as movement is decided
/// by the measured wobble in `model/device_test_comparison.dart` rather than
/// here.
///
/// PLAIN IN BOTH LAYERS, the same rule the rest of the screen follows. No dBFS
/// floor, no RMS, no median, no n. The precise engineering wording is in the
/// exported diagnostics, which is where somebody reading a bug report looks -
/// and the export is untouched by this file.
library;

import '../model/device_test_aggregate.dart';
import '../model/device_test_comparison.dart';
import '../model/device_test_result.dart';
import 'format.dart';

/// The mic check card's words. Pure: no widgets, no clock except one the caller
/// passes in.
abstract final class MicCheckCopy {
  /// What sits between the value and the comparison on the headline line.
  ///
  /// Wide spaces either side of the dot, because the two halves are a figure and
  /// a sentence about it rather than two items in a list - and because the
  /// widget sets them in different weights, which needs the air.
  static const String separator = '  ·  ';

  /// The figure the check leads with, rounded: `−39 dBFS`.
  ///
  /// Rounded because the run-to-run wobble is about a decibel - see
  /// [Fmt.headline]. The tenth is in the details and in the export.
  static String value(ReadingComparison comparison) =>
      Fmt.headline(comparison.latest, comparison.unit);

  /// How this reading sits against the run before it, in five words or fewer.
  ///
  /// "louder" and "quieter" rather than "higher" and "lower": both readings are
  /// levels, both checks are about sound arriving at a microphone, and loudness
  /// is the word somebody already has for it. For the quiet-room check louder
  /// means more hiss and for the voice check louder means a clearer voice -
  /// which is exactly why neither is called an improvement.
  static String change(ReadingComparison comparison) =>
      switch (comparison.change) {
        ReadingChange.noPrevious => 'nothing earlier to compare with',
        ReadingChange.notMeasured => 'no reading this time',
        ReadingChange.notComparable => 'not enough to compare with',
        ReadingChange.same => 'about the same as before',
        ReadingChange.higher => 'louder than before',
        ReadingChange.lower => 'quieter than before',
      };

  /// When the batch was taken, plus anything unusual about it, condensed.
  ///
  /// `measured today`, `measured yesterday`, `measured on Mon`,
  /// `measured on 12 Mar` - and a partial or cancelled batch appends its own
  /// short tag, because a run that did not finish must stay VISIBLY unfinished
  /// even after everything else about it moves behind a tap.
  static String taken(DeviceTestBatch batch, {DateTime? now}) => <String>[
        measuredWhen(batch.startedAt, now: now),
        if (condition(batch).isNotEmpty) condition(batch),
      ].join(' · ');

  /// `measured yesterday`. Lower case, because it is a footnote and not a
  /// heading.
  static String measuredWhen(DateTime at, {DateTime? now}) {
    final day = Fmt.day(at, now: now);
    return switch (day) {
      'Today' => 'measured today',
      'Yesterday' => 'measured yesterday',
      // A weekday or a date keeps its capital: "measured on mon" reads as a
      // typo, and lower-casing a month name is worse.
      _ => 'measured on $day',
    };
  }

  /// The one short tag a batch that did not go to plan earns, or `''`.
  ///
  /// CONDENSED, NOT HIDDEN. What used to read "1 of 5 samples · stopped early ·
  /// one run only, so there is no range to compare · cancelled" - four clauses
  /// saying two things - is now at most two: how far it got, and the single
  /// worst thing that happened to it. The full account is in the details, which
  /// still prints every outcome it counted.
  static String condition(DeviceTestBatch batch) {
    final outcome = _worstOutcome(batch);
    final parts = <String>[
      if (batch.isPartial)
        // "3 of 7" says nothing about what was counted, so the word goes in -
        // unless an outcome follows it, where the line has no room for it and
        // the following words make the count obvious anyway.
        '${batch.sampleCount} of ${batch.requested}'
            '${outcome == null ? ' samples' : ''}',
      ...?outcome,
    ];
    return parts.join(' · ');
  }

  /// The one outcome worth naming, worst first. Nothing is said about a batch
  /// that completed: that is what a batch is supposed to look like.
  static List<String>? _worstOutcome(DeviceTestBatch batch) {
    for (final outcome in const <DeviceTestOutcome>[
      DeviceTestOutcome.unavailable,
      DeviceTestOutcome.failed,
      DeviceTestOutcome.cancelled,
    ]) {
      final count = batch.countOf(outcome);
      if (count == 0) continue;
      final word = switch (outcome) {
        DeviceTestOutcome.unavailable => 'could not run',
        DeviceTestOutcome.failed => 'failed',
        DeviceTestOutcome.cancelled => 'stopped early',
        DeviceTestOutcome.completed => '',
      };
      // A count is only worth printing when there was more than one sample for
      // it to be a count OF.
      return <String>[batch.isSingle ? word : '$count $word'];
    }
    return null;
  }

  /// What the "about the same" threshold was, for the details.
  ///
  /// SAYING WHAT THE COMPARISON WAS MADE AGAINST is the difference between a
  /// threshold and a magic number. It is derived from the samples on disk - see
  /// `model/device_test_comparison.dart` - so the details quote it rather than
  /// asking anybody to trust it.
  static String basis(ReadingComparison comparison) {
    final threshold = comparison.threshold;
    if (threshold == null) {
      return 'No run of this check has taken two samples, so there is no '
          'wobble to measure a change against yet.';
    }
    return 'Counted as a change only past '
        '${Fmt.measurement(threshold, comparison.unit)} - the widest these '
        'samples wobbled on their own.';
  }
}
