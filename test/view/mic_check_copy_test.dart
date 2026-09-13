import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_test_aggregate.dart';
import 'package:voicenotetaker_app/model/device_test_comparison.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';
import 'package:voicenotetaker_app/view/mic_check_copy.dart';

/// The words the mic check card says, read as writing.
///
/// SEPARATE FROM THE FIT. `diagnostics_copy_test.dart` measures these same lines
/// in the real Sora and cares only whether they wrap; this file cares only what
/// they SAY. Both are needed: a line can be short and wrong, and it can be right
/// and three lines long.
///
/// THE RULE BEING PROTECTED is that the card compares and never judges. Not a
/// verdict in any state, including the states nobody reaches on a happy path -
/// which is exactly where a stray "looks fine" would survive review.
void main() {
  ReadingComparison comparison(ReadingChange change) => ReadingComparison(
        change: change,
        unit: 'dBFS',
        latest: change == ReadingChange.notMeasured ? null : -39.2,
        previous: -40,
        threshold: 1.6,
      );

  DeviceTestResult sample({
    required DeviceTestOutcome outcome,
    required int index,
    required int target,
  }) =>
      DeviceTestResult(
        kind: DeviceTestKind.noiseFloor,
        outcome: outcome,
        startedAt: DateTime(2026, 9, 14, 9, 14 + index),
        duration: const Duration(seconds: 10),
        readings: const <DeviceTestReading>[
          DeviceTestReading(
            label: 'Noise floor (RMS)',
            value: -39.2,
            unit: 'dBFS',
          ),
        ],
        batchId: 'b',
        repeatIndex: index,
        repeatTarget: target,
      );

  DeviceTestBatch batch({
    required int taken,
    required int requested,
    DeviceTestOutcome outcome = DeviceTestOutcome.completed,
    int badSamples = 0,
  }) =>
      DeviceTestBatch(
        kind: DeviceTestKind.noiseFloor,
        runs: <DeviceTestResult>[
          for (var i = 0; i < taken; i++)
            sample(
              outcome: i < badSamples ? outcome : DeviceTestOutcome.completed,
              index: i + 1,
              target: requested,
            ),
        ],
      );

  test('the figure the card leads with is rounded', () {
    expect(MicCheckCopy.value(comparison(ReadingChange.same)), '−39 dBFS');
    expect(
      MicCheckCopy.value(comparison(ReadingChange.notMeasured)),
      '— dBFS',
    );
  });

  test('every comparison is a direction, and none of them is a verdict', () {
    expect(
      MicCheckCopy.change(comparison(ReadingChange.same)),
      'about the same as before',
    );
    expect(
      MicCheckCopy.change(comparison(ReadingChange.higher)),
      'louder than before',
    );
    expect(
      MicCheckCopy.change(comparison(ReadingChange.lower)),
      'quieter than before',
    );
    expect(
      MicCheckCopy.change(comparison(ReadingChange.noPrevious)),
      'nothing earlier to compare with',
    );
    expect(
      MicCheckCopy.change(comparison(ReadingChange.notComparable)),
      'not enough to compare with',
    );
    expect(
      MicCheckCopy.change(comparison(ReadingChange.notMeasured)),
      'no reading this time',
    );

    // THE RULE, over every state there is. "Louder" is where a reading went, not
    // whether it should have gone there - the app cannot know what caused it, so
    // it does not say.
    for (final change in ReadingChange.values) {
      final text = MicCheckCopy.change(comparison(change)).toLowerCase();
      for (final verdict in const <String>[
        'good',
        'bad',
        'fine',
        'healthy',
        'normal',
        'problem',
        'worse',
        'better',
        'ok',
        'fail',
        'pass',
      ]) {
        expect(text.contains(verdict), isFalse, reason: '$change said $verdict');
      }
    }
  });

  test('when a run was taken reads as a footnote, not a heading', () {
    final now = DateTime(2026, 9, 14, 18);
    expect(
      MicCheckCopy.measuredWhen(DateTime(2026, 9, 14, 9), now: now),
      'measured today',
    );
    expect(
      MicCheckCopy.measuredWhen(DateTime(2026, 9, 13, 16), now: now),
      'measured yesterday',
    );
    // A weekday or a date keeps its capital - "measured on mon" reads as a typo.
    expect(
      MicCheckCopy.measuredWhen(DateTime(2026, 9, 11, 11), now: now),
      'measured on Fri',
    );
    expect(
      MicCheckCopy.measuredWhen(DateTime(2026, 3, 12, 11), now: now),
      'measured on 12 Mar',
    );
  });

  test('a batch that went to plan earns no tag at all', () {
    // Nothing is said about a completed batch: that is what one is supposed to
    // look like, and the count is in the details for anybody who wants it.
    expect(MicCheckCopy.condition(batch(taken: 7, requested: 7)), '');
    expect(
      MicCheckCopy.taken(
        batch(taken: 7, requested: 7),
        now: DateTime(2026, 9, 14, 18),
      ),
      'measured today',
    );
  });

  test('a batch that did not earns one short tag, never four clauses', () {
    // WHAT THIS REPLACED, in full: "1 of 5 samples · stopped early · one run
    // only, so there is no range to compare · cancelled". Four clauses saying
    // two things, on the face of the card.
    expect(
      MicCheckCopy.condition(
        batch(
          taken: 1,
          requested: 5,
          outcome: DeviceTestOutcome.cancelled,
          badSamples: 1,
        ),
      ),
      '1 of 5 · stopped early',
    );
    expect(
      MicCheckCopy.condition(
        batch(
          taken: 3,
          requested: 7,
          outcome: DeviceTestOutcome.failed,
          badSamples: 2,
        ),
      ),
      '3 of 7 · 2 failed',
    );
    // A full batch with a bad sample in it is not partial, but the sample is
    // still named.
    expect(
      MicCheckCopy.condition(
        batch(
          taken: 7,
          requested: 7,
          outcome: DeviceTestOutcome.failed,
          badSamples: 1,
        ),
      ),
      '1 failed',
    );
    // Worst first: a batch that could not run at all says that rather than
    // reporting the cancellation that followed.
    expect(
      MicCheckCopy.condition(
        batch(
          taken: 1,
          requested: 1,
          outcome: DeviceTestOutcome.unavailable,
          badSamples: 1,
        ),
      ),
      'could not run',
    );
  });

  test('the details say what a change was measured against', () {
    expect(
      MicCheckCopy.basis(comparison(ReadingChange.same)),
      contains('1.6 dBFS'),
    );
    expect(
      MicCheckCopy.basis(comparison(ReadingChange.same)),
      contains('the widest these samples wobbled on their own'),
    );
    // AND SAYS WHEN THERE IS NOTHING TO MEASURE AGAINST, rather than quoting a
    // threshold nobody derived.
    expect(
      MicCheckCopy.basis(
        const ReadingComparison(
          change: ReadingChange.notComparable,
          unit: 'dBFS',
          latest: -39.2,
        ),
      ),
      'No run of this check has taken two samples, so there is no wobble to '
      'measure a change against yet.',
    );
  });
}
