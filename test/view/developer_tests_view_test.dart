import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/device_test_aggregate.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';
import 'package:voicenotetaker_app/model/die_temperature.dart';
import 'package:voicenotetaker_app/services/device_test_store.dart';
import 'package:voicenotetaker_app/view/developer_view.dart';

import 'harness.dart';

/// The two cards the enclosure work added to the developer screen: the die
/// temperature, and the five-test harness.
///
/// Both are APPENDED below the battery card, never inserted above it - tests
/// elsewhere in this suite assert on what is visible at the top of this screen,
/// and more importantly the people who use it already know where to look.
void main() {
  setUpAll(registerViewFallbacks);

  /// Scrolls a card that starts below the fold into view.
  Future<void> reveal(WidgetTester tester, String caption) async {
    await tester.scrollUntilVisible(find.text(caption), 220);
    await tester.pump();
  }

  /// Writes a saved history into the store's file, exactly as a previous run
  /// would have, and makes the controller read it.
  Future<void> seedHistory(
    ViewHarness harness,
    List<DeviceTestResult> results,
  ) async {
    await harness.fileStore.writeBytes(
      harness.fileStore.join(
        ViewHarness.recordingsDirectory,
        DeviceTestStore.defaultFileName,
      ),
      utf8.encode(
        jsonEncode(<String, Object?>{
          'version': DeviceTestStore.formatVersion,
          'results': results.map((r) => r.toJson()).toList(),
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
  }) =>
      DeviceTestResult(
        kind: kind,
        outcome: outcome,
        startedAt: at,
        duration: const Duration(seconds: 10),
        readings: readings,
      );

  // -------------------------------------------------------------------------
  // THE DIE TEMPERATURE
  //
  // It reads above the room because the sensor shares a package with the CPU
  // and the radio, and it will read higher again inside the enclosure with a
  // cell underneath. The single thing these tests protect is the LABEL: nobody
  // may be able to read this figure as room temperature.
  // -------------------------------------------------------------------------
  group('the die temperature card', () {
    testWidgets('shows the figure the device reported', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readDieTemperature(any()))
          .thenAnswer((_) async => const DieTemperature(deciCelsius: 312));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DIE TEMPERATURE');

      expect(find.text('31.2 °C'), findsOneWidget);
      // The wire value beside it, so a decoding complaint is answerable.
      expect(find.text('312'), findsOneWidget);
    });

    testWidgets('never lets the figure be read as room temperature',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DIE TEMPERATURE');

      expect(find.text('DIE TEMPERATURE'), findsOneWidget);
      expect(find.textContaining('NOT the room'), findsOneWidget);
      expect(find.textContaining('self-heats'), findsOneWidget);
    });

    testWidgets('0x8000 reads as unknown, never as a number', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readDieTemperature(any()))
          .thenAnswer((_) async => const DieTemperature(deciCelsius: null));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DIE TEMPERATURE');

      expect(find.text('unknown (0x8000)'), findsOneWidget);
      // The bug this guards: a missing reading drawn as a freezing chip, which
      // looks like a plausible cold room.
      expect(find.text('0.0 °C'), findsNothing);
    });

    testWidgets('firmware without fe07 reads as unavailable', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readDieTemperature(any()))
          .thenThrow(const BleTransportException('no such characteristic'));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DIE TEMPERATURE');

      expect(find.text('unavailable'), findsOneWidget);
      expect(find.textContaining('fe07'), findsOneWidget);
      expect(find.text('0.0 °C'), findsNothing);
    });

    testWidgets('with nothing connected it asks for a connection',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DIE TEMPERATURE');

      expect(
        find.textContaining('Connect to the recorder to read this'),
        findsOneWidget,
      );
    });

    testWidgets('it follows fe07 notifications', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DIE TEMPERATURE');
      expect(find.text('31.2 °C'), findsOneWidget);

      await harness.notifyTemperature(tester, deciCelsius: 407);
      await tester.pump();

      expect(find.text('40.7 °C'), findsOneWidget);
      expect(find.text('31.2 °C'), findsNothing);
    });

    testWidgets('a dropped link clears it rather than showing a stale reading',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await harness.dropLink(tester);
      await reveal(tester, 'DIE TEMPERATURE');

      expect(find.text('31.2 °C'), findsNothing);
      expect(harness.controller.temperatureAvailable, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // THE TEST HARNESS
  // -------------------------------------------------------------------------
  group('the device tests card', () {
    testWidgets('offers all five tests and says what each measures',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(find.text('Range'), findsOneWidget);
      expect(find.text('Noise floor'), findsOneWidget);
      expect(find.text('Sensitivity'), findsOneWidget);
      expect(find.text('Link soak'), findsOneWidget);
      expect(find.text('Wake on motion'), findsOneWidget);
      // The range blurb names the dropped frames, because an acceptable RSSI on
      // a link that is shedding packets is the mistake the test exists for.
      expect(
        find.textContaining('acceptable RSSI can still be dropping frames'),
        findsOneWidget,
      );
    });

    testWidgets('says the comparison is by date, and does not pretend to know '
        'whether the case is on', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(find.textContaining('compare by date'), findsOneWidget);
      expect(find.textContaining('cannot know'), findsOneWidget);
    });

    testWidgets('with nothing connected every test is unavailable and says why',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(harness.controller.testBlocker, DeviceTestBlocker.notConnected);
      expect(
        find.textContaining('Connect to the recorder first'),
        findsOneWidget,
      );
      // And there is no result on screen at all - never a zero, never a dash
      // that looks like a measurement of nothing.
      expect(find.textContaining('Latest ·'), findsNothing);
    });

    testWidgets('a capture in progress blocks the tests, and says which',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await harness.record(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(harness.controller.testBlocker, DeviceTestBlocker.recording);
      expect(
        find.textContaining('audio notify stream takes one subscriber'),
        findsOneWidget,
      );
    });

    testWidgets('firmware without fe04 blocks only the wake test',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenThrow(const BleTransportException('no such characteristic'));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      // The acoustic and link tests need nothing but the audio stream.
      expect(harness.controller.testBlocker, isNull);
      expect(
        harness.controller.wakeTestBlocker,
        DeviceTestBlocker.noAutoSleep,
      );
      expect(
        find.textContaining('no auto-sleep characteristic'),
        findsOneWidget,
      );
    });

    testWidgets('a denied scan permission blocks the wake test', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.ensurePermissions())
          .thenAnswer((_) async => false);

      await harness.connect(tester);
      // A scan attempt is what discovers the refusal.
      await harness.discover(tester);
      await harness.connect(tester);

      expect(harness.controller.permissionDenied, isTrue);
      expect(
        harness.controller.wakeTestBlocker,
        DeviceTestBlocker.scanPermissionDenied,
      );
    });

    testWidgets('a connected recorder can run a test', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(harness.controller.testBlocker, isNull);
      expect(harness.controller.wakeTestBlocker, isNull);
      expect(find.textContaining('Connect to the recorder first'), findsNothing);
      expect(find.bySemanticsLabel('Run the range test'), findsOneWidget);
    });

    testWidgets('tapping Run starts the test and opens the audio stream',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      await tester.tap(find.bySemanticsLabel('Run the noise floor test'));
      await flush(tester);

      verify(() => harness.transport.subscribeFrames(knownDevice.id)).called(1);
      expect(
        harness.controller.deviceTests.running,
        DeviceTestKind.noiseFloor,
      );
      // The operator is half the test, so the instruction is on screen.
      expect(find.textContaining('Quiet room, hands off'), findsOneWidget);
      // And it is stoppable: a ten-second window is one thing, a three-minute
      // soak with no way out is another.
      expect(find.bySemanticsLabel('Stop the noise floor test'), findsOneWidget);

      harness.controller.cancelDeviceTest();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await flush(tester);
      expect(harness.controller.deviceTests.running, isNull);
    });

    testWidgets('the range walk offers Mark step and Finish while it runs',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      await tester.tap(find.bySemanticsLabel('Run the range test'));
      await flush(tester);

      expect(find.bySemanticsLabel('Mark a range step'), findsOneWidget);
      expect(find.bySemanticsLabel('Finish the range walk'), findsOneWidget);
      expect(find.textContaining('Walk away from the device'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Mark a range step'));
      await flush(tester);
      // The stop is on screen with both halves of the reading - the signal and
      // what the link actually delivered.
      expect(find.textContaining('Stop 1'), findsOneWidget);
      expect(find.textContaining('frames'), findsWidgets);

      // Through `runAsync`, not awaited directly: closing the walk cancels a
      // stream subscription, and that needs the real event loop rather than the
      // tester's clock - the same reason `flush` exists.
      harness.controller.cancelDeviceTest();
      await tester.runAsync(() => harness.controller.finishRangeWalk());
      await flush(tester);
      expect(harness.controller.deviceTests.running, isNull);
    });

    testWidgets('Stop on a range walk actually ends it, and saves the stops',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await harness.controller.deviceTests.load();
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      await tester.tap(find.bySemanticsLabel('Run the range test'));
      await flush(tester);
      await tester.tap(find.bySemanticsLabel('Mark a range step'));
      await flush(tester);

      // The bug this guards: cancelling a walk marks it abandoned but only
      // finishing closes the stream and writes the result, so a Stop that did
      // only the first half left the walk running with its button pressed.
      await tester.runAsync(
        () => tester.tap(find.bySemanticsLabel('Stop the range test')),
      );
      await flush(tester);

      expect(harness.controller.deviceTests.running, isNull);
      final saved =
          harness.controller.deviceTests.latestOf(DeviceTestKind.range);
      expect(saved, isNotNull);
      expect(saved!.outcome, DeviceTestOutcome.cancelled);
      expect(saved.steps, isNotEmpty);
    });

    testWidgets('a test that has never run shows no result at all',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await harness.controller.deviceTests.load();
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(find.textContaining('Latest ·'), findsNothing);
      expect(find.textContaining('0 runs kept'), findsOneWidget);
    });

    testWidgets('before the history is read it does not claim there is none',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      // `initialise()` is what reads the file. Until then "no runs" would be a
      // claim the app has not checked - the same rule the auto-sleep flag and
      // the battery follow.
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(find.textContaining('have not been read yet'), findsOneWidget);
      expect(find.textContaining('0 runs kept'), findsNothing);
    });

    testWidgets('the last two runs are shown side by side - the comparison',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      await seedHistory(harness, <DeviceTestResult>[
        run(
          DeviceTestKind.noiseFloor,
          at: now.subtract(const Duration(minutes: 5)),
          readings: const <DeviceTestReading>[
            DeviceTestReading(
              label: 'Noise floor (RMS)',
              value: -54.2,
              unit: 'dBFS',
            ),
          ],
        ),
        run(
          DeviceTestKind.noiseFloor,
          at: now.subtract(const Duration(days: 1)),
          readings: const <DeviceTestReading>[
            DeviceTestReading(
              label: 'Noise floor (RMS)',
              value: -68.9,
              unit: 'dBFS',
            ),
          ],
        ),
      ]);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      // This is the whole point of the harness: the enclosure raised the noise
      // floor by 14 dB, and both figures are on the screen to say so.
      expect(find.textContaining('−54.2 dBFS'), findsOneWidget);
      expect(find.textContaining('−68.9 dBFS'), findsOneWidget);
      expect(find.textContaining('Latest ·'), findsOneWidget);
      expect(find.textContaining('Before ·'), findsOneWidget);
      expect(find.textContaining('2 runs kept'), findsOneWidget);
    });

    testWidgets('a reading that was not measured shows a dash, never a zero',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(harness, <DeviceTestResult>[
        run(
          DeviceTestKind.range,
          at: DateTime.now(),
          readings: const <DeviceTestReading>[
            // Nothing dropped at any stop - the best possible outcome.
            DeviceTestReading(
              label: 'RSSI where drops began',
              value: null,
              unit: 'dBm',
            ),
            DeviceTestReading(label: 'Loss', value: 0, unit: '%'),
          ],
        ),
      ]);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      // "No drops anywhere" must not render as "drops began at 0 dBm".
      expect(find.textContaining('— dBm'), findsOneWidget);
      expect(find.textContaining('0 dBm'), findsNothing);
    });

    testWidgets('a run that did not complete is named as such', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(harness, <DeviceTestResult>[
        run(
          DeviceTestKind.wakeOnMotion,
          at: DateTime.now(),
          outcome: DeviceTestOutcome.failed,
          readings: const <DeviceTestReading>[
            DeviceTestReading(
              label: 'Shake to advertising',
              value: null,
              unit: 's',
            ),
          ],
        ),
      ]);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      // A failed run's blank reading must not be mistaken for a finished run's.
      expect(find.textContaining('failed'), findsOneWidget);
    });

    testWidgets('a result that was measured but not saved says so',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(milliseconds: 40));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      // The store's only file becomes unwritable.
      harness.fileStore.readOnly = true;
      // On the real event loop, so the forty-millisecond measuring window
      // actually elapses instead of waiting on the tester's frozen clock.
      await tester.runAsync(() => harness.controller.runNoiseFloorTest());
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(
        find.textContaining('measured but NOT saved'),
        findsOneWidget,
      );
    });
  });

  // -------------------------------------------------------------------------
  // AGGREGATES ON THE CARD
  //
  // The thing this card exists to answer is "did the enclosure make it worse",
  // and the answer is only worth having if the SPREAD of the samples is on the
  // screen beside the figure. A card that showed a median alone would invite
  // somebody to call a 3 dB change a regression when the five samples it came
  // from spanned ten - which is a confident wrong conclusion, and worse than no
  // baseline at all.
  // -------------------------------------------------------------------------
  group('the aggregate comparison', () {
    /// One sample of a batch, exactly as the service would have saved it.
    DeviceTestResult sample(
      DeviceTestKind kind, {
      required DateTime at,
      required String? batchId,
      required int index,
      required int target,
      required String label,
      required num? value,
      String unit = 'dBFS',
      DeviceTestOutcome outcome = DeviceTestOutcome.completed,
    }) =>
        DeviceTestResult(
          kind: kind,
          outcome: outcome,
          startedAt: at,
          duration: const Duration(seconds: 10),
          readings: <DeviceTestReading>[
            DeviceTestReading(label: label, value: value, unit: unit),
          ],
          batchId: batchId,
          repeatIndex: index,
          repeatTarget: target,
        );

    /// A batch of noise-floor samples, NEWEST FIRST the way the file keeps them.
    List<DeviceTestResult> noiseFloorBatch({
      required String batchId,
      required List<num?> values,
      required int target,
      required DateTime at,
    }) =>
        <DeviceTestResult>[
          for (var i = values.length - 1; i >= 0; i--)
            sample(
              DeviceTestKind.noiseFloor,
              at: at.add(Duration(minutes: i)),
              batchId: batchId,
              index: i + 1,
              target: target,
              label: 'Noise floor (RMS)',
              value: values[i],
              outcome: values[i] == null
                  ? DeviceTestOutcome.failed
                  : DeviceTestOutcome.completed,
            ),
        ];

    testWidgets('a batch reads as a median with the spread beside it',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-after',
          values: <num?>[-58, -62, -60, -61, -59],
          target: 5,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      // The n, so nobody has to guess how much the figure is worth.
      expect(find.textContaining('n=5 of 5'), findsOneWidget);
      // The median - a sample somebody actually took, not a mean.
      expect(find.textContaining('median −60.0 dBFS'), findsOneWidget);
      // AND the spread, on the same line. This is the requirement.
      expect(find.textContaining('−62.0 dBFS to −58.0 dBFS'), findsOneWidget);
      expect(find.textContaining('spread 4.0 dBFS'), findsOneWidget);
      // Five runs kept, one batch.
      expect(find.textContaining('5 runs kept'), findsOneWidget);
    });

    testWidgets('every sample is printed, so an outlier is visible',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      // One wild reading among five - a resonance, a dropout, a door. It is the
      // most interesting thing in the batch and it must be on the page.
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-outlier',
          values: <num?>[-60, -61, -59, -60, -12],
          target: 5,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(find.textContaining('samples:'), findsOneWidget);
      // Never silently dropped: it is in the sample list and in the range.
      expect(find.textContaining('−12.0 dBFS'), findsWidgets);
      // And it did not drag the middle value with it, which a mean would have.
      expect(find.textContaining('median −60.0 dBFS'), findsOneWidget);
    });

    testWidgets('a sample with no reading is counted, not quietly dropped',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-partial-readings',
          values: <num?>[-60, null, -62, -61, null],
          target: 5,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      // The only thing ever left out of a median is a sample that had no number
      // to contribute, and the card says how many that was.
      expect(find.textContaining('2 of 5 had no reading'), findsOneWidget);
      expect(find.textContaining('median −61.0 dBFS'), findsOneWidget);
      // The two failures are named rather than averaged away.
      expect(find.textContaining('2 failed'), findsOneWidget);
    });

    testWidgets('a batch stopped early says n and says it was stopped',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-stopped',
          values: <num?>[-58, -60, -62],
          target: 5,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      // Three of five is a usable baseline. It is NOT five, and it is not
      // discarded either.
      expect(find.textContaining('n=3 of 5'), findsOneWidget);
      expect(find.textContaining('stopped early'), findsOneWidget);
      expect(find.textContaining('median −60.0 dBFS'), findsOneWidget);
    });

    testWidgets('a single run is labelled as one, not dressed up as a baseline',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      // No batch id: exactly what every run saved by the previous build looks
      // like, and what a deliberate one-sample run looks like too.
      await seedHistory(harness, <DeviceTestResult>[
        run(
          DeviceTestKind.noiseFloor,
          at: DateTime.now(),
          readings: const <DeviceTestReading>[
            DeviceTestReading(
              label: 'Noise floor (RMS)',
              value: -54.2,
              unit: 'dBFS',
            ),
          ],
        ),
      ]);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(find.textContaining('n=1'), findsOneWidget);
      expect(find.textContaining('no spread to judge it by'), findsOneWidget);
      // The figure is still shown - it is just not called a spread of nothing.
      expect(find.textContaining('−54.2 dBFS'), findsOneWidget);
      expect(find.textContaining('samples:'), findsNothing);
      expect(find.textContaining('spread 0.0'), findsNothing);
    });

    testWidgets('Latest and Before are two BATCHES, each with its own n',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      await seedHistory(harness, <DeviceTestResult>[
        ...noiseFloorBatch(
          batchId: 'nf-after',
          values: <num?>[-52, -54, -53],
          target: 3,
          at: now.subtract(const Duration(minutes: 20)),
        ),
        ...noiseFloorBatch(
          batchId: 'nf-before',
          values: <num?>[-68, -70, -66, -69, -67],
          target: 5,
          at: now.subtract(const Duration(days: 1)),
        ),
      ]);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(find.textContaining('Latest ·'), findsOneWidget);
      expect(find.textContaining('Before ·'), findsOneWidget);
      // An n on each half, because five samples against three is a different
      // comparison from five against five.
      expect(find.textContaining('n=3 of 3'), findsOneWidget);
      expect(find.textContaining('n=5 of 5'), findsOneWidget);
      // The finding: about 15 dB, and both spreads are small enough to trust it.
      expect(find.textContaining('median −53.0 dBFS'), findsOneWidget);
      expect(find.textContaining('median −68.0 dBFS'), findsOneWidget);
      expect(find.textContaining('spread 2.0 dBFS'), findsOneWidget);
      expect(find.textContaining('spread 4.0 dBFS'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  group('the samples-per-test control', () {
    testWidgets('offers the counts and starts at five', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      expect(harness.controller.samplesPerTest, 5);
      expect(harness.controller.samplesPerTest, DeviceTestSampling.defaultCount);
      expect(find.text('Samples per test · 5'), findsOneWidget);
      for (final count in DeviceTestSampling.choices) {
        expect(
          find.bySemanticsLabel(
            count == 1
                ? 'Take a single sample per test'
                : 'Take $count samples per test',
          ),
          findsOneWidget,
        );
      }
      // And it says why more than one is taken at all.
      expect(find.textContaining('reported as a median'), findsOneWidget);
      expect(find.textContaining('stop early'), findsOneWidget);
    });

    testWidgets('choosing a count changes what the next test will take',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'Samples per test · 5');

      await tester.tap(find.bySemanticsLabel('Take 3 samples per test'));
      await tester.pump();

      expect(harness.controller.samplesPerTest, 3);
      expect(find.text('Samples per test · 3'), findsOneWidget);
    });

    testWidgets('a single sample is still offered', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'Samples per test · 5');

      await tester.tap(find.bySemanticsLabel('Take a single sample per test'));
      await tester.pump();

      // The right answer when the question is "is this board alive" rather than
      // "is this enclosure worse" - and the card then says n=1 out loud.
      expect(harness.controller.samplesPerTest, 1);
    });

    testWidgets('the count is fixed while a batch is in progress',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');
      await tester.tap(find.bySemanticsLabel('Run the noise floor test'));
      await flush(tester);

      harness.controller.samplesPerTest = 1;
      await tester.pump();

      // A batch carries the count it started with, or the n on the card would
      // not be the n that was measured.
      expect(harness.controller.samplesPerTest, 5);

      harness.controller.cancelDeviceTest();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await flush(tester);
    });

    testWidgets('a running test says which sample of how many it is on',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');
      await tester.tap(find.bySemanticsLabel('Run the noise floor test'));
      await flush(tester);

      // Progress has to be obvious: a test that looks identical on sample four
      // as on sample one is a test somebody abandons.
      expect(find.text('Sample 1 of 5'), findsOneWidget);

      harness.controller.cancelDeviceTest();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await flush(tester);
    });

    testWidgets('between samples it prompts, and offers to keep what it has',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      // The range walk is the clearest case: one person carries the phone away
      // and has to carry it back before they can walk it again, so the next
      // sample cannot possibly start on its own.
      await tester.tap(find.bySemanticsLabel('Run the range test'));
      await flush(tester);
      expect(find.text('Sample 1 of 5'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Mark a range step'));
      await flush(tester);
      await tester.runAsync(
        () => tester.tap(find.bySemanticsLabel('Finish the range walk')),
      );
      await flush(tester);

      final tests = harness.controller.deviceTests;
      expect(tests.running, isNull);
      expect(tests.awaitingNextSample, isTrue);
      expect(tests.samplesTaken, 1);
      // Progress, and what the operator has to do before the next one.
      expect(find.textContaining('1 of 5 samples taken'), findsOneWidget);
      expect(find.textContaining('walk it again'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Take the next sample of the range test'),
        findsOneWidget,
      );

      // The next walk starts only when they say so, and starts clean.
      await tester.tap(
        find.bySemanticsLabel('Take the next sample of the range test'),
      );
      await flush(tester);
      expect(tests.running, DeviceTestKind.range);
      expect(find.text('Sample 2 of 5'), findsOneWidget);
      expect(tests.steps, isEmpty);

      // And stopping keeps what was measured rather than discarding it.
      await tester.runAsync(
        () => tester.tap(find.bySemanticsLabel('Stop the range test')),
      );
      await flush(tester);

      expect(tests.isBatchActive, isFalse);
      final batch = tests.batchesOf(DeviceTestKind.range).single;
      expect(batch.sampleCount, 2);
      expect(batch.requested, 5);
      expect(batch.isPartial, isTrue);
    });

    testWidgets('stopping between samples keeps the samples already taken',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester, 'DEVICE TESTS');

      await tester.tap(find.bySemanticsLabel('Run the range test'));
      await flush(tester);
      await tester.tap(find.bySemanticsLabel('Mark a range step'));
      await flush(tester);
      await tester.runAsync(
        () => tester.tap(find.bySemanticsLabel('Finish the range walk')),
      );
      await flush(tester);

      final tests = harness.controller.deviceTests;
      expect(tests.awaitingNextSample, isTrue);

      await tester.tap(
        find.bySemanticsLabel(
          'Stop the range test and keep the 1 sample already taken',
        ),
      );
      await flush(tester);

      // NOTHING MEASURED IS THROWN AWAY for the batch having been incomplete.
      expect(tests.isBatchActive, isFalse);
      final batch = tests.batchesOf(DeviceTestKind.range).single;
      expect(batch.sampleCount, 1);
      expect(batch.requested, 5);
      expect(batch.isPartial, isTrue);
      expect(batch.runs.single.steps, isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('the diagnostics export', () {
    Future<void> export(WidgetTester tester) async {
      await tester.tap(find.text('Export diagnostics'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('carries the die temperature, labelled as the die',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await export(tester);

      expect(
        find.textContaining('die temperature: 31.2 °C die'),
        findsOneWidget,
      );
      // Whoever receives this report did not read the source, so the report
      // itself has to say it is not the room.
      expect(find.textContaining('NOT ambient'), findsOneWidget);
    });

    testWidgets('says unavailable rather than a number on older firmware',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readDieTemperature(any()))
          .thenThrow(const BleTransportException('no such characteristic'));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await export(tester);

      expect(
        find.textContaining('die temperature: unavailable'),
        findsOneWidget,
      );
    });

    testWidgets('carries every saved run, readings and note', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(harness, <DeviceTestResult>[
        DeviceTestResult(
          kind: DeviceTestKind.range,
          outcome: DeviceTestOutcome.completed,
          startedAt: DateTime.utc(2026, 9, 13, 14, 2),
          duration: const Duration(seconds: 96),
          readings: const <DeviceTestReading>[
            DeviceTestReading(
              label: 'RSSI where drops began',
              value: -79,
              unit: 'dBm',
            ),
          ],
          steps: const <DeviceTestStep>[
            DeviceTestStep(
              index: 1,
              rssiDbm: -54,
              framesReceived: 300,
              framesLost: 0,
            ),
          ],
          note: 'Frames first went missing at stop 2.',
        ),
      ]);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await export(tester);

      expect(find.textContaining('--- device tests (1 run kept) ---'),
          findsOneWidget);
      expect(find.textContaining('2026-09-13T14:02:00.000Z  range  completed'),
          findsOneWidget);
      expect(
        find.textContaining('RSSI where drops began: −79 dBm'),
        findsOneWidget,
      );
      // The walk itself, stop by stop: the summary on the card cannot be
      // re-derived from a single headline figure.
      expect(
        find.textContaining('stop 1: −54 dBm, 300 frames, 0 lost'),
        findsOneWidget,
      );
      expect(
        find.textContaining('note: Frames first went missing at stop 2.'),
        findsOneWidget,
      );
    });

    testWidgets('carries the median and the range of every batch',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      // Three samples, newest first the way the file keeps them.
      await seedHistory(harness, <DeviceTestResult>[
        for (var i = 3; i >= 1; i--)
          DeviceTestResult(
            kind: DeviceTestKind.noiseFloor,
            outcome: DeviceTestOutcome.completed,
            startedAt: DateTime.utc(2026, 9, 13, 14, i),
            duration: const Duration(seconds: 10),
            readings: <DeviceTestReading>[
              DeviceTestReading(
                label: 'Noise floor (RMS)',
                value: -60.0 - i,
                unit: 'dBFS',
              ),
            ],
            batchId: 'nf-1',
            repeatIndex: i,
            repeatTarget: 5,
          ),
      ]);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await export(tester);

      // Whoever receives this report is the person deciding whether the
      // enclosure made it worse, so the aggregate travels with the samples - and
      // so does the n it was computed from.
      expect(
        find.textContaining('--- device test batches'),
        findsOneWidget,
      );
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
      await seedHistory(harness, <DeviceTestResult>[
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
        ),
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
  });
}
