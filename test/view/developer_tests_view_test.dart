import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
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
