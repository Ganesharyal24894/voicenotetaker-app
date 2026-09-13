import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_test_aggregate.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';

/// The arithmetic that turns several noisy samples into one comparable figure.
///
/// This is the file that decides whether "the noise floor got 3 dB worse after
/// the enclosure" is a finding or a coincidence, so it is tested on the host with
/// no radio, no clock and no widgets anywhere near it.
///
/// The two rules it must never break: a MEDIAN that one wild sample cannot move,
/// and a SPREAD that still contains that wild sample so somebody can see it.
void main() {
  DeviceTestResult sample({
    DeviceTestKind kind = DeviceTestKind.noiseFloor,
    String? batchId = 'batch-1',
    int index = 1,
    int target = 5,
    int minute = 0,
    DeviceTestOutcome outcome = DeviceTestOutcome.completed,
    num? rms = -60,
    String label = 'Noise floor (RMS)',
  }) =>
      DeviceTestResult(
        kind: kind,
        outcome: outcome,
        startedAt: DateTime.utc(2026, 9, 13, 14, minute),
        duration: const Duration(seconds: 10),
        readings: <DeviceTestReading>[
          DeviceTestReading(label: label, value: rms, unit: 'dBFS'),
        ],
        batchId: batchId,
        repeatIndex: index,
        repeatTarget: target,
      );

  ReadingSpread spreadOf(List<num?> values) => ReadingSpread.of(
        'Noise floor (RMS)',
        <DeviceTestResult>[
          for (var i = 0; i < values.length; i++)
            sample(index: i + 1, minute: i, rms: values[i]),
        ],
      );

  group('the spread of one reading', () {
    test('the median of an odd number of samples is one of the samples', () {
      final spread = spreadOf(<num?>[-58, -62, -60, -61, -59]);

      expect(spread.n, 5);
      // Not a mean. -60.0 exactly, and it is a reading somebody took.
      expect(spread.median, -60);
      expect(spread.values, <num>[-62, -61, -60, -59, -58]);
    });

    test('the median of an even number is the mean of the middle two', () {
      final spread = spreadOf(<num?>[-58, -62, -60, -64]);

      expect(spread.median, -61);
    });

    test('one wild sample moves the median not at all', () {
      // The point of the whole file. A dropout, a slammed door, a scan the OS
      // throttled - one of these per batch is normal, and a MEAN would carry it
      // straight into the baseline.
      final clean = spreadOf(<num?>[-60, -61, -59, -60, -61]);
      final withOutlier = spreadOf(<num?>[-60, -61, -59, -60, -12]);

      expect(clean.median, -60);
      expect(withOutlier.median, -60);
      // And the outlier is NOT hidden: the range still contains it, which is how
      // a reader knows the batch had something odd in it.
      expect(withOutlier.max, -12);
      expect(withOutlier.spread, 49);
      expect(withOutlier.values, contains(-12));
    });

    test('min, max and spread are the full envelope, not a trimmed one', () {
      final spread = spreadOf(<num?>[-70, -60, -50, -55, -65]);

      expect(spread.min, -70);
      expect(spread.max, -50);
      expect(spread.spread, 20);
      expect(spread.hasSpread, isTrue);
    });

    test('one sample has no spread at all, and does not pretend to', () {
      final spread = spreadOf(<num?>[-54.2]);

      expect(spread.n, 1);
      expect(spread.median, -54.2);
      expect(spread.spread, isNull);
      expect(spread.hasSpread, isFalse);
      // Not zero. "The spread was nothing" and "there is no spread to report"
      // are different claims, and only the second one is true here.
      expect(spread.min, -54.2);
      expect(spread.max, -54.2);
    });

    test('a sample with no reading is counted, never folded into a zero', () {
      // A failed run, or "RSSI where drops began" on a walk where nothing
      // dropped. It cannot enter a median, so it is declared instead.
      final spread = spreadOf(<num?>[-60, null, -62, -61, null]);

      expect(spread.n, 3);
      expect(spread.sampleCount, 5);
      expect(spread.missing, 2);
      expect(spread.median, -61);
      // The bug this guards: a null treated as 0 dBFS, which would read as a
      // catastrophically loud noise floor and drag a median with it.
      expect(spread.values, isNot(contains(0)));
    });

    test('a batch that measured nothing has no median, not a zero', () {
      final spread = spreadOf(<num?>[null, null, null]);

      expect(spread.n, 0);
      expect(spread.missing, 3);
      expect(spread.median, isNull);
      expect(spread.min, isNull);
      expect(spread.max, isNull);
      expect(spread.spread, isNull);
    });

    test('the unit survives a batch where nothing was measured', () {
      // `— dBm` needs its unit as much as `−79 dBm` does.
      final spread = spreadOf(<num?>[null, null]);
      expect(spread.unit, 'dBFS');
    });

    test('a label no run carries is empty rather than an error', () {
      final spread = ReadingSpread.of(
        'nothing called this',
        <DeviceTestResult>[sample()],
      );

      expect(spread.n, 0);
      expect(spread.missing, 1);
      expect(spread.median, isNull);
    });
  });

  group('grouping runs into batches', () {
    test('samples sharing a batch id become one batch, oldest sample first',
        () {
      // The store hands out newest first; a reader wants the measuring order.
      final batches = DeviceTestBatch.group(<DeviceTestResult>[
        sample(index: 3, minute: 3),
        sample(index: 2, minute: 2),
        sample(index: 1, minute: 1),
      ]);

      expect(batches, hasLength(1));
      expect(batches.first.sampleCount, 3);
      expect(
        batches.first.runs.map((run) => run.repeatIndex),
        <int>[1, 2, 3],
      );
      expect(batches.first.startedAt, DateTime.utc(2026, 9, 13, 14, 1));
      expect(batches.first.endedAt, DateTime.utc(2026, 9, 13, 14, 3));
    });

    test('batches come back newest first', () {
      final batches = DeviceTestBatch.group(<DeviceTestResult>[
        sample(batchId: 'later', minute: 9, target: 1),
        sample(batchId: 'earlier', minute: 1, target: 1),
      ]);

      expect(batches.map((batch) => batch.batchId), <String>['later', 'earlier']);
    });

    test('a run with no batch id is a batch of one - which is what it was', () {
      // EVERY RESULT SAVED BEFORE BATCHES EXISTED looks like this, and reading
      // them as n=1 is the only honest thing to do with them.
      final batches = DeviceTestBatch.group(<DeviceTestResult>[
        sample(batchId: null, target: 1, minute: 2),
        sample(batchId: null, target: 1, minute: 1),
      ]);

      expect(batches, hasLength(2));
      expect(batches.every((batch) => batch.isSingle), isTrue);
      expect(batches.every((batch) => batch.sampleCount == 1), isTrue);
      expect(batches.every((batch) => batch.isPartial), isFalse);
    });

    test('two tests never share a batch, whatever the file says', () {
      final batches = DeviceTestBatch.group(<DeviceTestResult>[
        sample(kind: DeviceTestKind.noiseFloor, batchId: 'same'),
        sample(kind: DeviceTestKind.linkSoak, batchId: 'same'),
      ]);

      expect(batches, hasLength(2));
      expect(
        batches.map((batch) => batch.kind).toSet(),
        <DeviceTestKind>{DeviceTestKind.noiseFloor, DeviceTestKind.linkSoak},
      );
    });

    test('a batch stopped early is partial, keeps its samples and says n', () {
      // THE REQUIREMENT THAT MATTERS MOST ABOUT PARTIAL RUNS: three of five
      // stopped is three samples aggregated, never three samples discarded.
      final batch = DeviceTestBatch.group(<DeviceTestResult>[
        sample(index: 3, minute: 3, rms: -62),
        sample(index: 2, minute: 2, rms: -60),
        sample(index: 1, minute: 1, rms: -58),
      ]).single;

      expect(batch.sampleCount, 3);
      expect(batch.requested, 5);
      expect(batch.isPartial, isTrue);
      expect(batch.spreadOf('Noise floor (RMS)').median, -60);
    });

    test('a finished batch is not partial', () {
      final batch = DeviceTestBatch.group(<DeviceTestResult>[
        for (var i = 3; i >= 1; i--) sample(index: i, minute: i, target: 3),
      ]).single;

      expect(batch.sampleCount, 3);
      expect(batch.requested, 3);
      expect(batch.isPartial, isFalse);
    });

    test('more samples than were asked for still reads honestly', () {
      // Cannot happen through the service, but a hand-edited file must not make
      // the screen say "n=3 of 2".
      final batch = DeviceTestBatch.group(<DeviceTestResult>[
        for (var i = 3; i >= 1; i--) sample(index: i, minute: i, target: 2),
      ]).single;

      expect(batch.requested, 3);
      expect(batch.isPartial, isFalse);
    });

    test('outcomes are counted, so a batch cannot hide its failures', () {
      final batch = DeviceTestBatch.group(<DeviceTestResult>[
        sample(index: 3, minute: 3, outcome: DeviceTestOutcome.failed, rms: null),
        sample(index: 2, minute: 2),
        sample(index: 1, minute: 1),
      ]).single;

      expect(batch.countOf(DeviceTestOutcome.completed), 2);
      expect(batch.countOf(DeviceTestOutcome.failed), 1);
      expect(batch.countOf(DeviceTestOutcome.cancelled), 0);
      // The failed sample's absent reading is declared rather than averaged.
      expect(batch.spreadOf('Noise floor (RMS)').missing, 1);
      expect(batch.spreadOf('Noise floor (RMS)').n, 2);
    });

    test('an empty history is no batches, not an empty batch', () {
      expect(DeviceTestBatch.group(const <DeviceTestResult>[]), isEmpty);
    });
  });

  group('the sampling policy', () {
    test('the default is five, and it is odd on purpose', () {
      // Odd, so the median is a sample somebody measured rather than the mean of
      // the middle two - the only place this code reports a number nobody took.
      expect(DeviceTestSampling.defaultCount, 5);
      expect(DeviceTestSampling.defaultCount.isOdd, isTrue);
    });

    test('the choices include one, so a single run stays possible', () {
      expect(DeviceTestSampling.choices, contains(1));
      expect(DeviceTestSampling.choices, contains(DeviceTestSampling.defaultCount));
    });

    test('only the tests that need nobody present repeat on their own', () {
      expect(DeviceTestSampling.isAutomatic(DeviceTestKind.noiseFloor), isTrue);
      expect(DeviceTestSampling.isAutomatic(DeviceTestKind.linkSoak), isTrue);
      // These three ARE the operator: somebody walks, speaks, shakes. Looping
      // them unattended would record the seconds after a walk as the walk.
      expect(DeviceTestSampling.isAutomatic(DeviceTestKind.range), isFalse);
      expect(
        DeviceTestSampling.isAutomatic(DeviceTestKind.sensitivity),
        isFalse,
      );
      expect(
        DeviceTestSampling.isAutomatic(DeviceTestKind.wakeOnMotion),
        isFalse,
      );
    });
  });
}
