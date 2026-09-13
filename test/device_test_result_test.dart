import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';

/// A saved result is the ONLY thing that makes a before-and-after comparison
/// possible, so it has to survive a round trip through the file exactly.
///
/// Two properties matter more than the rest:
///
///   * a null reading stays null. "No drops at any stop" and "drops began at
///     0 dBm" are different facts, and JSON is where they get collapsed.
///   * the enum names on the wire are STRINGS, not indices, so adding a sixth
///     test later cannot silently re-label every result already on disk.
void main() {
  group('a reading', () {
    test('round-trips through JSON', () {
      const reading =
          DeviceTestReading(label: 'Noise floor (RMS)', value: -62.4, unit: 'dBFS');
      expect(DeviceTestReading.fromJson(reading.toJson()), reading);
    });

    test('keeps a null value null rather than turning it into zero', () {
      const reading = DeviceTestReading(
        label: 'RSSI where drops began',
        value: null,
        unit: 'dBm',
      );
      final back = DeviceTestReading.fromJson(reading.toJson());
      expect(back.value, isNull);
      expect(back.value, isNot(0));
    });

    test('rejects a value that is not a number', () {
      expect(
        () => DeviceTestReading.fromJson(<String, Object?>{
          'label': 'Peak',
          'value': 'loud',
          'unit': 'dBFS',
        }),
        throwsFormatException,
      );
    });

    test('rejects a missing label', () {
      expect(
        () => DeviceTestReading.fromJson(<String, Object?>{
          'value': 1,
          'unit': '',
        }),
        throwsFormatException,
      );
    });
  });

  group('a range step', () {
    test('round-trips, RSSI and frame counts together', () {
      const step = DeviceTestStep(
        index: 3,
        rssiDbm: -78,
        framesReceived: 204,
        framesLost: 11,
      );
      expect(DeviceTestStep.fromJson(step.toJson()), step);
    });

    test('a step with no RSSI reading keeps it null', () {
      const step = DeviceTestStep(
        index: 1,
        rssiDbm: null,
        framesReceived: 10,
        framesLost: 0,
      );
      expect(DeviceTestStep.fromJson(step.toJson()).rssiDbm, isNull);
    });

    test('loss is a ratio of what the device sent, not of what arrived', () {
      const step = DeviceTestStep(
        index: 1,
        rssiDbm: -70,
        framesReceived: 90,
        framesLost: 10,
      );
      expect(step.framesExpected, 100);
      expect(step.lossRatio, closeTo(0.1, 1e-9));
      expect(step.dropped, isTrue);
    });

    test('a leg with no traffic is not a 100% loss', () {
      // The divide-by-zero this project has been bitten by before.
      const step = DeviceTestStep(
        index: 1,
        rssiDbm: -70,
        framesReceived: 0,
        framesLost: 0,
      );
      expect(step.lossRatio, 0.0);
      expect(step.dropped, isFalse);
    });

    test('rejects non-integer counters', () {
      expect(
        () => DeviceTestStep.fromJson(<String, Object?>{
          'index': 1,
          'rssiDbm': -70,
          'framesReceived': 'lots',
          'framesLost': 0,
        }),
        throwsFormatException,
      );
    });
  });

  group('a result', () {
    final result = DeviceTestResult(
      kind: DeviceTestKind.range,
      outcome: DeviceTestOutcome.completed,
      startedAt: DateTime.utc(2026, 9, 13, 14, 2, 11),
      duration: const Duration(seconds: 96),
      readings: const <DeviceTestReading>[
        DeviceTestReading(label: 'Stops', value: 4),
        DeviceTestReading(
          label: 'RSSI where drops began',
          value: -79,
          unit: 'dBm',
        ),
      ],
      steps: const <DeviceTestStep>[
        DeviceTestStep(index: 1, rssiDbm: -54, framesReceived: 300, framesLost: 0),
      ],
      note: 'Frames first went missing at stop 3.',
    );

    test('round-trips whole', () {
      final back = DeviceTestResult.fromJson(result.toJson());
      expect(back.kind, result.kind);
      expect(back.outcome, result.outcome);
      expect(back.startedAt, result.startedAt);
      expect(back.duration, result.duration);
      expect(back.readings, result.readings);
      expect(back.steps, result.steps);
      expect(back.note, result.note);
    });

    test('the kind is stored by name, never by index', () {
      // An index would be re-pointed by inserting a value into the enum, and
      // every result already on disk would quietly change what it measured.
      expect(result.toJson()['kind'], 'range');
      expect(result.toJson()['outcome'], 'completed');
    });

    test('a reading can be looked up by label', () {
      expect(result.reading('Stops')?.value, 4);
      expect(result.reading('nothing called this'), isNull);
    });

    test('an unavailable run records why, and has no readings', () {
      final unavailable = DeviceTestResult.unavailable(
        kind: DeviceTestKind.wakeOnMotion,
        at: DateTime.utc(2026, 9, 13),
        because: 'auto-sleep could not be enabled',
      );
      expect(unavailable.outcome, DeviceTestOutcome.unavailable);
      expect(unavailable.note, contains('auto-sleep'));
      expect(unavailable.hasReadings, isFalse);
      // And it survives the file, because "we could not measure it that day"
      // is part of the before-and-after story.
      expect(
        DeviceTestResult.fromJson(unavailable.toJson()).outcome,
        DeviceTestOutcome.unavailable,
      );
    });

    test('a kind this build does not know is rejected, not guessed at', () {
      final json = result.toJson()..['kind'] = 'thermal-cycling';
      expect(() => DeviceTestResult.fromJson(json), throwsFormatException);
    });

    test('an outcome this build does not know is rejected', () {
      final json = result.toJson()..['outcome'] = 'inconclusive';
      expect(() => DeviceTestResult.fromJson(json), throwsFormatException);
    });

    test('a missing duration is rejected', () {
      final json = result.toJson()..remove('durationMs');
      expect(() => DeviceTestResult.fromJson(json), throwsFormatException);
    });

    test('absent readings and steps read as empty, not as an error', () {
      final json = result.toJson()
        ..remove('readings')
        ..remove('steps');
      final back = DeviceTestResult.fromJson(json);
      expect(back.readings, isEmpty);
      expect(back.steps, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // WHERE A RUN SITS IN A BATCH
  //
  // These three fields are what let five noisy samples be read as one figure
  // with a spread instead of five unrelated numbers. They were ADDED to a
  // format that already had results saved in it, so the rule they have to keep
  // is that a file written before they existed still reads - as the one thing it
  // honestly is, a batch of one.
  // -------------------------------------------------------------------------
  group('a run in a batch', () {
    final walk = DeviceTestResult(
      kind: DeviceTestKind.range,
      outcome: DeviceTestOutcome.completed,
      startedAt: DateTime.utc(2026, 9, 13, 14, 2, 11),
      duration: const Duration(seconds: 96),
      readings: const <DeviceTestReading>[
        DeviceTestReading(label: 'Stops', value: 4),
      ],
      steps: const <DeviceTestStep>[
        DeviceTestStep(
          index: 1,
          rssiDbm: -54,
          framesReceived: 300,
          framesLost: 0,
        ),
      ],
      note: 'Frames first went missing at stop 3.',
    );

    DeviceTestResult inBatch({
      String? batchId = 'noise-floor-1700000000000-0',
      int index = 2,
      int target = 5,
    }) =>
        DeviceTestResult(
          kind: DeviceTestKind.noiseFloor,
          outcome: DeviceTestOutcome.completed,
          startedAt: DateTime.utc(2026, 9, 13, 14, 2),
          duration: const Duration(seconds: 10),
          batchId: batchId,
          repeatIndex: index,
          repeatTarget: target,
        );

    test('the batch fields round-trip', () {
      final back = DeviceTestResult.fromJson(inBatch().toJson());

      expect(back.batchId, 'noise-floor-1700000000000-0');
      expect(back.repeatIndex, 2);
      expect(back.repeatTarget, 5);
    });

    test('a run saved before batches existed reads as a lone sample', () {
      // EXACTLY what is on disk from the previous build: no batch keys at all.
      // Nothing is migrated and no version is bumped - absent means one.
      final legacy = <String, Object?>{
        'kind': 'noise-floor',
        'outcome': 'completed',
        'startedAt': '2026-09-13T14:02:00.000Z',
        'durationMs': 10000,
        'readings': <Object?>[
          <String, Object?>{
            'label': 'Noise floor (RMS)',
            'value': -54.2,
            'unit': 'dBFS',
          },
        ],
        'steps': <Object?>[],
        'note': null,
      };

      final back = DeviceTestResult.fromJson(legacy);

      expect(back.batchId, isNull);
      expect(back.repeatIndex, 1);
      expect(back.repeatTarget, 1);
      // And the measurement itself is untouched, which is the entire point.
      expect(back.reading('Noise floor (RMS)')?.value, -54.2);
    });

    test('a lone run is sample one of one, not sample zero', () {
      final lone = DeviceTestResult(
        kind: DeviceTestKind.range,
        outcome: DeviceTestOutcome.completed,
        startedAt: DateTime.utc(2026, 9, 13),
        duration: Duration.zero,
      );

      expect(lone.batchId, isNull);
      expect(lone.repeatIndex, 1);
      expect(lone.repeatTarget, 1);
    });

    test('a counter that is not a number is rejected, not guessed at', () {
      final json = inBatch().toJson()..['repeatIndex'] = 'second';
      expect(() => DeviceTestResult.fromJson(json), throwsFormatException);
    });

    test('a batch id that is not a string is rejected', () {
      final json = inBatch().toJson()..['batchId'] = 7;
      expect(() => DeviceTestResult.fromJson(json), throwsFormatException);
    });

    test('a nonsense counter costs the counter, never the measurement', () {
      // A zero or a negative has no meaning here, and losing a whole row of
      // readings over it would be the wrong trade.
      final json = inBatch().toJson()..['repeatTarget'] = 0;
      expect(DeviceTestResult.fromJson(json).repeatTarget, 1);
    });

    test('inBatch stamps the fields and changes nothing else', () {
      final stamped = walk.inBatch(
        batchId: 'range-1-0',
        repeatIndex: 3,
        repeatTarget: 5,
      );

      expect(stamped.batchId, 'range-1-0');
      expect(stamped.repeatIndex, 3);
      expect(stamped.repeatTarget, 5);
      expect(stamped.kind, walk.kind);
      expect(stamped.outcome, walk.outcome);
      expect(stamped.startedAt, walk.startedAt);
      expect(stamped.duration, walk.duration);
      expect(stamped.readings, walk.readings);
      expect(stamped.steps, walk.steps);
      expect(stamped.note, walk.note);
    });

    test('inBatch can measure the duration a run did not know', () {
      final stamped = walk.inBatch(
        batchId: null,
        repeatIndex: 1,
        repeatTarget: 1,
        duration: const Duration(seconds: 4),
      );

      expect(stamped.duration, const Duration(seconds: 4));
    });
  });
}
