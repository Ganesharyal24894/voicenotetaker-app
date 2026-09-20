import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';
import 'package:voicenotetaker_app/services/device_test_store.dart';
import 'package:voicenotetaker_app/view/developer_view.dart';

import 'harness.dart';

/// The diagnostics export - the one way the measurements leave the phone.
///
/// It stays on the developer screen rather than moving to Diagnostics with the
/// mic check itself, because what it produces is a paste for a bug report: raw
/// byte counters, wire values, the whole saved history run by run. The
/// comparison a human actually reads is the card on the diagnostics screen.
///
/// Two properties matter more than the rest:
///
///   * nothing is truncated. A report that drops the run somebody wanted to
///     compare against is not a report.
///   * nothing is invented. An unavailable reading says "unavailable"; it never
///     becomes a zero, which whoever receives the report would read as a
///     measurement.
void main() {
  setUpAll(registerViewFallbacks);

  Future<void> export(WidgetTester tester) async {
    await tester.tap(find.text('Export diagnostics'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Writes a saved history into the store's file, exactly as previous runs
  /// would have, and makes the controller read it.
  Future<void> seedHistory(
    ViewHarness harness,
    List<Map<String, Object?>> rows,
  ) async {
    await harness.fileStore.writeBytes(
      harness.fileStore.join(
        ViewHarness.recordingsDirectory,
        DeviceTestStore.defaultFileName,
      ),
      utf8.encode(
        jsonEncode(<String, Object?>{
          'version': DeviceTestStore.formatVersion,
          'results': rows,
        }),
      ),
    );
    await harness.controller.deviceTests.load();
  }

  DeviceTestResult run(
    DeviceTestKind kind, {
    required DateTime at,
    List<DeviceTestReading> readings = const <DeviceTestReading>[],
    DeviceTestOutcome outcome = DeviceTestOutcome.completed,
    String? note,
    String? batchId,
    int index = 1,
    int target = 1,
  }) =>
      DeviceTestResult(
        kind: kind,
        outcome: outcome,
        startedAt: at,
        duration: const Duration(seconds: 10),
        readings: readings,
        note: note,
        batchId: batchId,
        repeatIndex: index,
        repeatTarget: target,
      );

  testWidgets('carries the die temperature, labelled as the die',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await harness.connect(tester);
    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    // The developer screen READS fe07 once as it opens rather than subscribing:
    // notifications are what make the firmware sample continuously, and they
    // belong to the screen that draws a live figure.
    await flush(tester);
    await export(tester);

    expect(
      find.textContaining('die temperature: 31.2 °C die'),
      findsOneWidget,
    );
    // Whoever receives this report did not read the source, so the report
    // itself has to say it is not the room.
    expect(find.textContaining('NOT ambient'), findsOneWidget);
  });

  testWidgets('reads the die once rather than subscribing to it',
      (tester) async {
    // THE POWER RULE. A subscription to fe07 makes the device sample the sensor
    // for as long as it is open, and this screen only needs one figure for one
    // report.
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await harness.connect(tester);
    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await flush(tester);

    verify(() => harness.transport.readDieTemperature(knownDevice.id))
        .called(greaterThanOrEqualTo(1));
    verifyNever(() => harness.transport.subscribeDieTemperature(any()));
  });

  testWidgets('says unavailable rather than a number on older firmware',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readDieTemperature(any()))
        .thenThrow(const BleTransportException('no such characteristic'));

    await harness.connect(tester);
    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await flush(tester);
    await export(tester);

    expect(
      find.textContaining('die temperature: unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('carries every saved run, readings and note', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await seedHistory(harness, <Map<String, Object?>>[
      run(
        DeviceTestKind.sensitivity,
        at: DateTime.utc(2026, 9, 13, 14, 2),
        readings: const <DeviceTestReading>[
          DeviceTestReading(label: 'Peak', value: -8.2, unit: 'dBFS'),
          DeviceTestReading(label: 'RMS', value: -24.6, unit: 'dBFS'),
        ],
        note: 'Spoken at 30 cm from the microphone port.',
      ).toJson(),
    ]);

    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await export(tester);

    expect(
      find.textContaining('--- device tests (1 run kept) ---'),
      findsOneWidget,
    );
    expect(
      find.textContaining('2026-09-13T14:02:00.000Z  sensitivity  completed'),
      findsOneWidget,
    );
    expect(find.textContaining('Peak: −8.2 dBFS'), findsOneWidget);
    expect(find.textContaining('RMS: −24.6 dBFS'), findsOneWidget);
    expect(
      find.textContaining('note: Spoken at 30 cm from the microphone port.'),
      findsOneWidget,
    );
  });

  testWidgets('carries the median and the range of every batch',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    // Three samples, newest first the way the file keeps them.
    await seedHistory(harness, <Map<String, Object?>>[
      for (var i = 3; i >= 1; i--)
        run(
          DeviceTestKind.noiseFloor,
          at: DateTime.utc(2026, 9, 13, 14, i),
          readings: <DeviceTestReading>[
            DeviceTestReading(
              label: 'Noise floor (RMS)',
              value: -60.0 - i,
              unit: 'dBFS',
            ),
          ],
          batchId: 'nf-1',
          index: i,
          target: 5,
        ).toJson(),
    ]);

    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await export(tester);

    // Whoever receives this report is the person deciding whether the
    // enclosure made it worse, so the aggregate travels with the samples - and
    // so does the n it was computed from.
    expect(find.textContaining('--- device test batches'), findsOneWidget);
    expect(
      find.textContaining('noise-floor  n=3 of 5  (stopped early)'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Noise floor (RMS): median −62.0 dBFS, range −63.0 dBFS to '
        '−61.0 dBFS, spread 2.0 dBFS (n=3)',
      ),
      findsOneWidget,
    );
    // And the run-by-run list is still there underneath it, so the aggregate
    // can be checked rather than taken on trust.
    expect(
      find.textContaining('--- device tests (3 runs kept) ---'),
      findsOneWidget,
    );
  });

  testWidgets('a lone run is exported as n=1 with no spread', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await seedHistory(harness, <Map<String, Object?>>[
      run(
        DeviceTestKind.noiseFloor,
        at: DateTime.utc(2026, 9, 13, 14, 2),
        readings: const <DeviceTestReading>[
          DeviceTestReading(
            label: 'Noise floor (RMS)',
            value: -54.2,
            unit: 'dBFS',
          ),
        ],
      ).toJson(),
    ]);

    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await export(tester);

    expect(
      find.textContaining('Noise floor (RMS): −54.2 dBFS (n=1, no spread)'),
      findsOneWidget,
    );
  });

  testWidgets('says so plainly when nothing has been run', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await export(tester);

    expect(
      find.textContaining('nothing has been run on this phone yet'),
      findsOneWidget,
    );
  });

  // -------------------------------------------------------------------------
  // THE RUNS THIS BUILD NO LONGER READS
  //
  // The file on the owner's phone holds a bare-board baseline, and some of those
  // runs are of measurements that have since been retired. They stay in the
  // file - see `device_test_store_test.dart` - but this build cannot interpret
  // them, so they cannot appear in the history. A report that listed two runs
  // out of a file of five without saying so would read as data loss.
  // -------------------------------------------------------------------------
  testWidgets('accounts for the runs it cannot read rather than hiding them',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await seedHistory(harness, <Map<String, Object?>>[
      <String, Object?>{
        'kind': 'wake-on-motion',
        'outcome': 'completed',
        'startedAt': '2026-09-13T14:05:00.000Z',
        'durationMs': 4200,
        'readings': <Object?>[
          <String, Object?>{
            'label': 'Shake to advertising',
            'value': 1.9,
            'unit': 's',
          },
        ],
        'note': null,
      },
      <String, Object?>{
        'kind': 'range',
        'outcome': 'completed',
        'startedAt': '2026-09-13T14:04:00.000Z',
        'durationMs': 96000,
        'readings': <Object?>[],
        'steps': <Object?>[],
        'note': null,
      },
      run(
        DeviceTestKind.noiseFloor,
        at: DateTime.utc(2026, 9, 13, 14, 3),
        readings: const <DeviceTestReading>[
          DeviceTestReading(
            label: 'Noise floor (RMS)',
            value: -54.2,
            unit: 'dBFS',
          ),
        ],
      ).toJson(),
    ]);

    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await export(tester);

    expect(
      find.textContaining('saved runs this build does not read: 2'),
      findsOneWidget,
    );
    expect(
      find.textContaining('kept in the file untouched'),
      findsOneWidget,
    );
    // The readable run is still exported in full.
    expect(find.textContaining('Noise floor (RMS): −54.2 dBFS'), findsOneWidget);
    // And nothing pretends to know what the wake figure meant.
    expect(find.textContaining('Shake to advertising'), findsNothing);
  });

  testWidgets('carries the wording the diagnostics screen no longer says',
      (tester) async {
    // WHERE THE ENGINEERING REGISTER WENT. The diagnostics screen used to carry
    // these derivations in front of anybody who opened it. It now says the same
    // things in plain language, and NOTHING WAS DELETED: the precise wording is
    // here, in the report that actually travels into a bug thread.
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await export(tester);

    expect(
      find.textContaining('--- how the diagnostics screen measures things ---'),
      findsOneWidget,
    );
    // The loss derivation, off the card and into the report.
    expect(
      find.textContaining('counted from gaps in the fe01 sequence number'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Leaving that screen open IS the soak test'),
      findsOneWidget,
    );
    // The die, by that name, with the 0x8000 case spelled out.
    expect(find.textContaining('DIE temperature from fe07'), findsOneWidget);
    expect(find.textContaining('0x8000'), findsOneWidget);
    // The two acoustic measurements in full, MEMS and RMS and all.
    expect(find.textContaining('RMS dBFS'), findsWidgets);
    expect(find.textContaining('MEMS microphone'), findsOneWidget);
    expect(
      find.textContaining('${DeviceTestReadings.sensitivityDistanceCm} cm from '
          'the microphone port'),
      findsOneWidget,
    );
    // And why a batch is a median and a range rather than a mean and an SD.
    expect(
      find.textContaining('never a mean and never a standard deviation'),
      findsOneWidget,
    );
  });

  testWidgets('says nothing about unread runs when there are none',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await seedHistory(harness, <Map<String, Object?>>[
      run(DeviceTestKind.noiseFloor, at: DateTime.utc(2026, 9, 13)).toJson(),
    ]);

    await pumpScreen(tester, DeveloperView(controller: harness.controller));
    await export(tester);

    expect(find.textContaining('does not read'), findsNothing);
  });
}
