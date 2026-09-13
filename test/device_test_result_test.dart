import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';

/// A saved result is the ONLY thing that makes a before-and-after comparison
/// possible, so it has to survive a round trip through the file exactly.
///
/// Two properties matter more than the rest:
///
///   * a null reading stays null. "No audio arrived" and "a level of 0 dBFS"
///     are different facts, and JSON is where they get collapsed.
///   * the enum names on the wire are STRINGS, not indices, so retiring a
///     measurement cannot silently re-label every result already on disk. That
///     property is what makes the retired-kind tests at the bottom pass.
void main() {
  group('a reading', () {
    test('round-trips through JSON', () {
      const reading = DeviceTestReading(
        label: 'Noise floor (RMS)',
        value: -62.4,
        unit: 'dBFS',
      );
      expect(DeviceTestReading.fromJson(reading.toJson()), reading);
    });

    test('keeps a null value null rather than turning it into zero', () {
      const reading = DeviceTestReading(
        label: 'Noise floor (RMS)',
        value: null,
        unit: 'dBFS',
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

  group('a result', () {
    final result = DeviceTestResult(
      kind: DeviceTestKind.sensitivity,
      outcome: DeviceTestOutcome.completed,
      startedAt: DateTime.utc(2026, 9, 13, 14, 2, 11),
      duration: const Duration(seconds: 10),
      readings: const <DeviceTestReading>[
        DeviceTestReading(label: 'Peak', value: -8.2, unit: 'dBFS'),
        DeviceTestReading(label: 'RMS', value: -24.6, unit: 'dBFS'),
      ],
      note: 'Spoken at 30 cm from the microphone port.',
    );

    test('round-trips whole', () {
      final back = DeviceTestResult.fromJson(result.toJson());
      expect(back.kind, result.kind);
      expect(back.outcome, result.outcome);
      expect(back.startedAt, result.startedAt);
      expect(back.duration, result.duration);
      expect(back.readings, result.readings);
      expect(back.note, result.note);
    });

    test('the kind is stored by name, never by index', () {
      // An index would be re-pointed by removing a value from the enum, and
      // every result already on disk would quietly change what it measured.
      // Retiring three kinds is exactly the event this protects against.
      expect(result.toJson()['kind'], 'sensitivity');
      expect(result.toJson()['outcome'], 'completed');
    });

    test('the two surviving kinds keep the wire names the baseline uses', () {
      // The bare-board baseline on the owner's phone is stored under these two
      // strings. Renaming either breaks the comparison the file exists for.
      expect(DeviceTestKind.noiseFloor.wireName, 'noise-floor');
      expect(DeviceTestKind.sensitivity.wireName, 'sensitivity');
      expect(DeviceTestKind.values, hasLength(2));
    });

    test('a reading can be looked up by label', () {
      expect(result.reading('Peak')?.value, -8.2);
      expect(result.reading('nothing called this'), isNull);
    });

    test('an unavailable run records why, and has no readings', () {
      final unavailable = DeviceTestResult.unavailable(
        kind: DeviceTestKind.sensitivity,
        at: DateTime.utc(2026, 9, 13),
        because: 'the device did not report its stream format',
      );
      expect(unavailable.outcome, DeviceTestOutcome.unavailable);
      expect(unavailable.note, contains('stream format'));
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

    test('absent readings read as empty, not as an error', () {
      final json = result.toJson()..remove('readings');
      expect(DeviceTestResult.fromJson(json).readings, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // THE RETIRED MEASUREMENTS
  //
  // The range walk, the link soak and wake-on-motion were removed. There is a
  // phone with runs of all three in it, taken on the bare board, and those runs
  // must not turn into a crash or a silent truncation of the file. The rule this
  // layer keeps is narrow and deliberate: a retired kind is REJECTED here, the
  // same way a kind from a future build is, and the store above is what keeps
  // the row. Guessing at it - mapping `link-soak` onto something else - would
  // put numbers measured by a different method into the same column.
  // -------------------------------------------------------------------------
  group('a run of a measurement that was retired', () {
    Map<String, Object?> saved(String kind) => <String, Object?>{
          'kind': kind,
          'outcome': 'completed',
          'startedAt': '2026-09-13T14:02:00.000Z',
          'durationMs': 96000,
          'readings': <Object?>[
            <String, Object?>{
              'label': 'RSSI where drops began',
              'value': -79,
              'unit': 'dBm',
            },
          ],
          'steps': <Object?>[
            <String, Object?>{
              'index': 1,
              'rssiDbm': -54,
              'framesReceived': 300,
              'framesLost': 0,
            },
          ],
          'note': 'Frames first went missing at stop 3.',
        };

    test('is not read by this build, and is not reinterpreted either', () {
      for (final kind in <String>['range', 'link-soak', 'wake-on-motion']) {
        expect(
          () => DeviceTestResult.fromJson(saved(kind)),
          throwsFormatException,
          reason: '$kind must not be mapped onto a surviving kind',
        );
      }
    });

    test('a `steps` list from the old format is ignored, not rejected', () {
      // The range walk wrote a `steps` array. A readable run that happens to
      // carry one - a hand-edited file, or a kind that came back - must not lose
      // its readings over a key this build no longer has a field for.
      final json = saved('noise-floor')
        ..['readings'] = <Object?>[
          <String, Object?>{
            'label': 'Noise floor (RMS)',
            'value': -54.2,
            'unit': 'dBFS',
          },
        ];

      final back = DeviceTestResult.fromJson(json);

      expect(back.kind, DeviceTestKind.noiseFloor);
      expect(back.reading('Noise floor (RMS)')?.value, -54.2);
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
    final voice = DeviceTestResult(
      kind: DeviceTestKind.sensitivity,
      outcome: DeviceTestOutcome.completed,
      startedAt: DateTime.utc(2026, 9, 13, 14, 2, 11),
      duration: const Duration(seconds: 10),
      readings: const <DeviceTestReading>[
        DeviceTestReading(label: 'Peak', value: -8.2, unit: 'dBFS'),
      ],
      note: 'Spoken at 30 cm from the microphone port.',
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
        kind: DeviceTestKind.noiseFloor,
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
      final stamped = voice.inBatch(
        batchId: 'sensitivity-1-0',
        repeatIndex: 3,
        repeatTarget: 5,
      );

      expect(stamped.batchId, 'sensitivity-1-0');
      expect(stamped.repeatIndex, 3);
      expect(stamped.repeatTarget, 5);
      expect(stamped.kind, voice.kind);
      expect(stamped.outcome, voice.outcome);
      expect(stamped.startedAt, voice.startedAt);
      expect(stamped.duration, voice.duration);
      expect(stamped.readings, voice.readings);
      expect(stamped.note, voice.note);
    });

    test('inBatch can measure the duration a run did not know', () {
      final stamped = voice.inBatch(
        batchId: null,
        repeatIndex: 1,
        repeatTarget: 1,
        duration: const Duration(seconds: 4),
      );

      expect(stamped.duration, const Duration(seconds: 4));
    });
  });
}
