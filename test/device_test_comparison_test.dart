import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_test_aggregate.dart';
import 'package:voicenotetaker_app/model/device_test_comparison.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';

/// What counts as a change, and why it is not a number somebody chose.
///
/// THE ONE THING THE MIC CHECK CARD NOW SAYS is whether a reading moved since
/// last time, so the whole card rests on this arithmetic. If the threshold were
/// a constant it would be wrong in both directions at once: 2 dB is a change
/// beside samples that spanned half a decibel and is nothing beside samples that
/// spanned ten, and a single figure cannot be both. So it is derived from the
/// spread the saved samples actually showed, and these tests are what stop it
/// quietly becoming a constant again.
///
/// A test that checked one difference against one verdict could not tell the
/// difference. Every case here therefore varies the SPREAD and holds the
/// difference still, or the other way about.
void main() {
  /// A spread of [values] under a label, as [ReadingSpread.of] would build it
  /// from the samples of a batch.
  ReadingSpread spread(List<num?> values, {String unit = 'dBFS'}) =>
      ReadingSpread.of(
        'Noise floor (RMS)',
        <DeviceTestResult>[
          for (final value in values)
            DeviceTestResult(
              kind: DeviceTestKind.noiseFloor,
              outcome: value == null
                  ? DeviceTestOutcome.failed
                  : DeviceTestOutcome.completed,
              startedAt: DateTime(2026, 9, 14, 9, 14),
              duration: const Duration(seconds: 10),
              readings: <DeviceTestReading>[
                DeviceTestReading(
                  label: 'Noise floor (RMS)',
                  value: value,
                  unit: unit,
                ),
              ],
            ),
        ],
      );

  group('what the threshold is derived from', () {
    test('the wider of the two compared batches own spreads', () {
      // Latest spans 2 dB, previous spans 6. The threshold is 6, because a
      // change has to clear the noisiest evidence there is rather than the
      // quietest - and 4 dB of movement does not clear it.
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-60, -61, -59]),
        previous: spread(<num?>[-56, -53, -59]),
      );

      expect(comparison.threshold, 6);
      expect(comparison.difference, -4);
      expect(comparison.change, ReadingChange.same);
    });

    test('the SAME difference is a change beside tighter samples', () {
      // Identical medians to the case above - −60 against −56 - and now both
      // batches are tight. This is the pair that proves the derivation: one
      // difference, two answers, decided entirely by the stored spread.
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-60, -60.5, -59.5]),
        previous: spread(<num?>[-56, -56.5, -55.5]),
      );

      expect(comparison.threshold, 1);
      expect(comparison.difference, -4);
      expect(comparison.change, ReadingChange.lower);
    });

    test('a difference exactly as wide as the wobble has not cleared it', () {
      // The tie falls on the side that claims less.
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-60, -61, -59]),
        previous: spread(<num?>[-58, -59, -57]),
      );

      expect(comparison.threshold, 2);
      expect(comparison.difference, -2);
      expect(comparison.change, ReadingChange.same);
    });

    test('a hair past it is a change', () {
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-60, -61, -59]),
        previous: spread(<num?>[-57.9, -58.9, -56.9]),
      );

      expect(comparison.threshold, 2);
      expect(comparison.change, ReadingChange.lower);
    });

    test('an older batch lends its spread when neither compared one has any',
        () {
      // WHAT THE BARE-BOARD BASELINE LOOKS LIKE once a lone run sits either
      // side of it: every result saved before batching existed is a batch of
      // one, and a batch of one cannot show its own wobble. An older batch of
      // the same check measured on the same hardware can.
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-56]),
        previous: spread(<num?>[-60]),
        fallback: <ReadingSpread>[
          spread(<num?>[-60, -61, -59.5]),
          spread(<num?>[-62]),
        ],
      );

      expect(comparison.threshold, 1.5);
      expect(comparison.difference, 4);
      expect(comparison.change, ReadingChange.higher);
    });

    test('the compared batches win over the fallback, even when tighter', () {
      // The fallback is a last resort, not a vote. Two batches that measured
      // their own wobble are the evidence about THIS pair of runs.
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-60, -60.5]),
        previous: spread(<num?>[-56, -56.5]),
        fallback: <ReadingSpread>[spread(<num?>[-60, -75])],
      );

      expect(comparison.threshold, 0.5);
      expect(comparison.change, ReadingChange.lower);
    });

    test('with no measured wobble anywhere there is no comparison', () {
      // NOT A GUESS AND NOT A DEFAULT. Two single readings genuinely do not say
      // how much this check wobbles, and inventing a threshold to produce a
      // verdict is the one thing this file must never do.
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-56]),
        previous: spread(<num?>[-60]),
        fallback: <ReadingSpread>[spread(<num?>[-62])],
      );

      expect(comparison.threshold, isNull);
      expect(comparison.change, ReadingChange.notComparable);
      // The figures are still carried, because the card still shows the latest.
      expect(comparison.latest, -56);
      expect(comparison.previous, -60);
    });
  });

  group('the states that are not a comparison', () {
    test('the first batch of a check has nothing behind it', () {
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-60, -61, -59]),
      );

      expect(comparison.change, ReadingChange.noPrevious);
      expect(comparison.latest, -60);
      expect(comparison.previous, isNull);
      expect(comparison.isComparison, isFalse);
    });

    test('a batch that measured nothing leads with no reading, never a zero',
        () {
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[null, null]),
        previous: spread(<num?>[-60, -61, -59]),
      );

      expect(comparison.change, ReadingChange.notMeasured);
      expect(comparison.latest, isNull);
      expect(comparison.difference, isNull);
      // The unit survives a batch with no values, so the card can render
      // `— dBFS` rather than a bare dash.
      expect(comparison.unit, 'dBFS');
    });

    test('an earlier batch that measured nothing cannot be compared against',
        () {
      final comparison = ReadingComparison.between(
        latest: spread(<num?>[-60, -61, -59]),
        previous: spread(<num?>[null, null]),
      );

      expect(comparison.change, ReadingChange.notComparable);
      expect(comparison.latest, -60);
      expect(comparison.previous, isNull);
    });

    test('the unit is taken from the earlier batch when the latest lost it',
        () {
      final comparison = ReadingComparison.between(
        latest: ReadingSpread.of(
          'Noise floor (RMS)',
          const <DeviceTestResult>[],
        ),
        previous: spread(<num?>[-60, -61]),
      );

      expect(comparison.unit, 'dBFS');
      expect(comparison.change, ReadingChange.notMeasured);
    });
  });

  group('the three that ARE a comparison', () {
    test('louder, quieter and the same are the only verdicts there are', () {
      // NO VERDICT EXISTS TO BE SAID. There is no enum value for good, bad,
      // fine or a problem, which is how the screen's "compare, never judge" rule
      // is kept by construction rather than by remembering it.
      expect(ReadingChange.values, hasLength(6));
      expect(
        ReadingChange.values.map((change) => change.name),
        containsAll(<String>['same', 'higher', 'lower']),
      );

      final louder = ReadingComparison.between(
        latest: spread(<num?>[-50, -50.5]),
        previous: spread(<num?>[-60, -60.5]),
      );
      final quieter = ReadingComparison.between(
        latest: spread(<num?>[-70, -70.5]),
        previous: spread(<num?>[-60, -60.5]),
      );
      final same = ReadingComparison.between(
        latest: spread(<num?>[-60, -60.5]),
        previous: spread(<num?>[-60.2, -60.7]),
      );

      expect(louder.change, ReadingChange.higher);
      expect(quieter.change, ReadingChange.lower);
      expect(same.change, ReadingChange.same);
      for (final comparison in <ReadingComparison>[louder, quieter, same]) {
        expect(comparison.isComparison, isTrue);
      }
    });
  });
}
