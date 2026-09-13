import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/device_test_aggregate.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';
import 'package:voicenotetaker_app/model/die_temperature.dart';
import 'package:voicenotetaker_app/services/device_test_store.dart';
import 'package:voicenotetaker_app/view/diagnostics_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';

import 'harness.dart';

/// Device Diagnostics - the screen a user can open in a release build.
///
/// Three things are being protected here, in descending order of how badly they
/// would hurt if they broke:
///
///   1. THE SUBSCRIPTIONS STOP. Opening this screen makes the recorder stream
///      audio and sample its die temperature. Both must stop the moment the
///      screen is not visible, and "not visible" includes the app being
///      backgrounded, not just the back chevron. Every test in this file leaves
///      the screen at the end, and the tester's own "a Timer is still pending"
///      assertion is what would catch a poll that outlived it.
///   2. NOTHING IS FABRICATED. No link, no `fe07`, a platform that will not
///      report a signal - each of those reads as a dash with a reason, never as
///      a zero.
///   3. THE COMPARISON IS A BATCH AGAINST A BATCH, with the spread on the page.
void main() {
  setUpAll(registerViewFallbacks);

  /// Scrolls a card that starts below the fold into view.
  Future<void> reveal(WidgetTester tester, String caption) async {
    await tester.scrollUntilVisible(find.text(caption), 220);
    await tester.pump();
  }

  /// Opens the screen and lets its `initState` work finish.
  Future<void> open(
    WidgetTester tester,
    ViewHarness harness, {
    VoidCallback? onOpenDeveloper,
  }) async {
    await pumpScreen(
      tester,
      DiagnosticsView(
        controller: harness.controller,
        onOpenDeveloper: onOpenDeveloper,
      ),
    );
    await flush(tester);
  }

  /// Leaves the screen, exactly as popping the route does.
  ///
  /// CALLED AT THE END OF EVERY TEST, and not for tidiness: the contract this
  /// screen has is that it stops what it started, and a widget test that simply
  /// ends leaves the route mounted - which is the one state the contract
  /// forbids. If the teardown ever stops working, the signal poll survives this
  /// call and the tester fails the test with a pending timer.
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  }

  /// Writes a saved history into the store's file, exactly as previous runs
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

  /// One `fe01` notification: a little-endian sequence header, then silent
  /// s16le PCM. `StreamInfo.fallback` is raw PCM, so the payload needs no
  /// decoding - and silence still counts as audio having ARRIVED, which is the
  /// distinction the acoustic checks turn on.
  Uint8List frameBytes(int sequence, {int samples = 160}) {
    final bytes = Uint8List(2 + samples * 2);
    bytes[0] = sequence & 0xFF;
    bytes[1] = (sequence >> 8) & 0xFF;
    return bytes;
  }

  /// Runs [start] on the REAL event loop and gets audio into its window.
  ///
  /// The measuring window is a real timer, so the tester's frozen clock cannot
  /// run it - and a window that saw no audio at all is a FAILED sample, which
  /// ends the batch. Every test about what happens between samples therefore has
  /// to put a frame in first.
  Future<void> withAudio(
    WidgetTester tester,
    ViewHarness harness,
    Future<void> Function() start, {
    int sequence = 0,
  }) async {
    await tester.runAsync(() async {
      final running = start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      harness.frames.add(frameBytes(sequence));
      await running;
    });
    await flush(tester);
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

  /// Opens the Details disclosure of one check.
  ///
  /// EVERY FIGURE THAT IS NOT THE HEADLINE IS BEHIND THIS, which is the whole
  /// point of the layout: the card answers "did it move?" in one line and keeps
  /// the range, the individual samples and the second reading one tap away. So
  /// every test that asserts on those has to open it, and a test that finds them
  /// without opening it has found a regression.
  Future<void> openDetails(WidgetTester tester, String check) async {
    final finder = find.bySemanticsLabel('Show the details of the $check check');
    // The control sits well down the mic check card, and `scrollUntilVisible`
    // needs an element that already exists: a widget the viewport has not
    // reached has not been laid out and therefore has no semantics to find. So
    // the list is dragged until it does exist, and only then scrolled to.
    for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -120));
      await tester.pump();
    }
    await tester.scrollUntilVisible(finder, 120);
    await tester.pump();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// One sample of a batch, exactly as the service would have saved it.
  DeviceTestResult sample(
    DeviceTestKind kind, {
    required DateTime at,
    required String? batchId,
    required int index,
    required int target,
    required List<DeviceTestReading> readings,
    DeviceTestOutcome outcome = DeviceTestOutcome.completed,
  }) =>
      DeviceTestResult(
        kind: kind,
        outcome: outcome,
        startedAt: at,
        duration: const Duration(seconds: 10),
        readings: readings,
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
            readings: <DeviceTestReading>[
              DeviceTestReading(
                label: 'Noise floor (RMS)',
                value: values[i],
                unit: 'dBFS',
              ),
            ],
            outcome: values[i] == null
                ? DeviceTestOutcome.failed
                : DeviceTestOutcome.completed,
          ),
      ];

  /// A batch of sensitivity samples, which carry BOTH readings - Average, the
  /// one the card leads with, and Loudest, which lives in the details.
  List<DeviceTestResult> sensitivityBatch({
    required String batchId,
    required List<num?> average,
    required List<num?> loudest,
    required int target,
    required DateTime at,
  }) =>
      <DeviceTestResult>[
        for (var i = average.length - 1; i >= 0; i--)
          sample(
            DeviceTestKind.sensitivity,
            at: at.add(Duration(minutes: i)),
            batchId: batchId,
            index: i + 1,
            target: target,
            readings: <DeviceTestReading>[
              DeviceTestReading(label: 'Peak', value: loudest[i], unit: 'dBFS'),
              DeviceTestReading(label: 'RMS', value: average[i], unit: 'dBFS'),
            ],
          ),
      ];

  /// A lone noise-floor run with no batch id - what every result saved before
  /// batching existed looks like, and what the bare-board baseline is made of.
  DeviceTestResult lone(num value, DateTime at) => run(
        DeviceTestKind.noiseFloor,
        at: at,
        readings: <DeviceTestReading>[
          DeviceTestReading(
            label: 'Noise floor (RMS)',
            value: value,
            unit: 'dBFS',
          ),
        ],
      );

  // -------------------------------------------------------------------------
  group('the screen', () {
    testWidgets('builds with nothing connected and says what it is',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);

      expect(find.text('Diagnostics'), findsOneWidget);
      expect(find.text('CONNECTION'), findsOneWidget);
      expect(find.text('MIC CHECK'), findsOneWidget);
      // It is an observer's screen, and it says so - there is no DEBUG ONLY
      // badge, because this one ships.
      expect(find.text('DEBUG ONLY'), findsNothing);
      expect(
        find.textContaining('Nothing here changes it.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await leave(tester);
    });

    testWidgets('offers Developer options only when it is given the door',
        (tester) async {
      // Null in a release build, where the developer screen does not exist at
      // all - see `developer_view.dart`. The button is absent rather than dead.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);
      expect(find.text('Developer options'), findsNothing);
      await leave(tester);

      var opened = false;
      await open(tester, harness, onOpenDeveloper: () => opened = true);
      expect(find.text('Developer options'), findsOneWidget);
      await tester.tap(find.text('Developer options'));
      await tester.pump();
      expect(opened, isTrue);

      await leave(tester);
    });
  });

  // -------------------------------------------------------------------------
  // THE POWER RULE
  //
  // Subscribing to `fe01` makes the recorder stream; subscribing to `fe07` is
  // what makes it sample the die at all. Neither is rendered anywhere else in
  // the app, so neither may be open when this screen is not visible. A user who
  // parks here and pockets the phone must not leave the radio running.
  // -------------------------------------------------------------------------
  group('the subscriptions it owns', () {
    testWidgets('a connection alone subscribes to neither', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);

      // Home draws the battery, so `fe05` is followed for the life of the link.
      verify(() => harness.transport.subscribeBattery(knownDevice.id)).called(1);
      // Nothing outside this screen draws the die temperature or counts frames.
      verifyNever(() => harness.transport.subscribeDieTemperature(any()));
      verifyNever(() => harness.transport.subscribeFrames(any()));
      expect(harness.controller.temperatureAvailable, isFalse);
    });

    testWidgets('opening it subscribes to the audio stream and to fe07',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);

      verify(() => harness.transport.subscribeFrames(knownDevice.id)).called(1);
      verify(() => harness.transport.subscribeDieTemperature(knownDevice.id))
          .called(1);
      expect(harness.controller.diagnosticsOpen, isTrue);
      expect(harness.controller.linkHealth.watching, isTrue);

      await leave(tester);
    });

    testWidgets('leaving it drops both, every time', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);
      await leave(tester);

      verify(() => harness.transport.unsubscribeFrames(knownDevice.id))
          .called(1);
      verify(() => harness.transport.unsubscribeDieTemperature(knownDevice.id))
          .called(1);
      expect(harness.controller.diagnosticsOpen, isFalse);
      expect(harness.controller.linkHealth.watching, isFalse);
      // And the figure goes with the subscription: keeping the last reading on
      // screen would be showing a measurement nothing is taking any more.
      expect(harness.controller.temperatureAvailable, isFalse);
    });

    testWidgets('backgrounding the app drops both, and resuming brings them '
        'back', (tester) async {
      // THE CASE THE BACK CHEVRON DOES NOT COVER. This is the app's first
      // lifecycle observer; nothing here watched AppLifecycleState before, so it
      // is scoped to this one screen's State and removed with it.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await flush(tester);

      expect(harness.controller.diagnosticsOpen, isFalse);
      expect(harness.controller.linkHealth.watching, isFalse);
      verify(() => harness.transport.unsubscribeFrames(knownDevice.id))
          .called(1);
      verify(() => harness.transport.unsubscribeDieTemperature(knownDevice.id))
          .called(1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush(tester);

      expect(harness.controller.diagnosticsOpen, isTrue);
      expect(harness.controller.linkHealth.watching, isTrue);

      await leave(tester);
    });

    testWidgets('a transient inactive state does not thrash the radio',
        (tester) async {
      // `inactive` fires for a notification shade, an incoming call, the iOS app
      // switcher preview. Tearing the subscriptions down and back up on each of
      // those would cost more than it saves.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await flush(tester);

      expect(harness.controller.diagnosticsOpen, isTrue);
      verifyNever(() => harness.transport.unsubscribeFrames(any()));

      await leave(tester);
    });

    testWidgets('opening it with nothing connected subscribes to nothing',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);

      verifyNever(() => harness.transport.subscribeFrames(any()));
      verifyNever(() => harness.transport.subscribeDieTemperature(any()));
      // Open, and honest about having nothing to show.
      expect(harness.controller.diagnosticsOpen, isTrue);
      expect(harness.controller.linkHealth.watching, isFalse);

      await leave(tester);
    });

    testWidgets('a link that drops stops the counting rather than freezing it',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);
      await harness.notifyFrame(tester, sequence: 0);
      expect(harness.controller.linkHealth.framesReceived, 1);

      await harness.dropLink(tester);

      expect(harness.controller.linkHealth.watching, isFalse);
      // The screen is still on top, so it still WANTS the readings - which is
      // what lets a reconnect bring them back without the user leaving.
      expect(harness.controller.diagnosticsOpen, isTrue);

      await leave(tester);
    });
  });

  // -------------------------------------------------------------------------
  // THE LIVE LINK
  //
  // This card replaced a stepped range walk and a three-minute soak. Both
  // measured the signal and the frames that went missing, and the device does
  // both continuously - so the measurement is now something you watch rather
  // than something you save.
  // -------------------------------------------------------------------------
  group('the live link card', () {
    testWidgets('shows the LIVE signal, not the one taken at scan time',
        (tester) async {
      final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await open(tester, harness);

      // `knownDevice.rssi` is -54: one sample off an advertising packet, taken
      // at scan time and never updated. `readRssi` is the live link, -58. A card
      // that showed the first would be showing a number from minutes ago.
      expect(find.text('−58 dBm'), findsOneWidget);
      expect(find.text('−54 dBm'), findsNothing);
      expect(find.bySemanticsLabel('Signal strength'), findsOneWidget);
      expect(
        harness.controller.linkHealth.rssiFraction,
        closeTo(0.74, 0.01),
      );

      await leave(tester);
    });

    testWidgets('counts frames streamed and frames lost from sequence gaps',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(milliseconds: 40));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);

      await harness.notifyFrame(tester, sequence: 0);
      await harness.notifyFrame(tester, sequence: 1);
      // Sequence 2 never arrives - the gap IS the loss, counted from what this
      // phone failed to receive rather than from a counter the firmware keeps.
      await harness.notifyFrame(tester, sequence: 3);

      expect(harness.controller.linkHealth.framesReceived, 3);
      expect(harness.controller.linkHealth.framesLost, 1);

      // THE COUNTERS ARE PUBLISHED ON THE POLL, not on every notification: at
      // 16 kHz a frame arrives about a hundred times a second and a rebuild per
      // frame would cost more than the measurement is worth.
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('Audio received'), findsOneWidget);
      expect(find.text('Audio lost'), findsOneWidget);
      // 1 of 4 expected. The rate is the assertion rather than the raw counts:
      // small integers collide with the samples-per-check labels further down
      // the card, and the rate is what a reader is actually looking at.
      expect(find.text('25.00%'), findsOneWidget);
      // The derivation is NOT on the screen: it is in the exported
      // diagnostics - see developer_export_test.dart.
      expect(find.textContaining('fe01'), findsNothing);
      expect(find.textContaining('sequence number'), findsNothing);

      await leave(tester);
    });

    testWidgets('a link with nothing lost yet reads as a dash, not 0.00%',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);

      // Subscribed, and no frame has arrived. A loss rate of 0.00% here would be
      // a perfect link that has not started.
      expect(harness.controller.linkHealth.lossPercent, isNull);
      expect(find.text('0.00%'), findsNothing);

      await leave(tester);
    });

    testWidgets('a platform that will not report the signal says so',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readRssi(any()))
          .thenThrow(const BleTransportException('not supported'));

      await harness.connect(tester);
      await open(tester, harness);

      // 0 dBm is a real reading and an absurd one, so no reading is a dash - and
      // the meter is empty rather than pinned to the bottom of the scale.
      expect(find.text('— dBm'), findsOneWidget);
      // The meter has nothing to place, so it draws its track and no fill.
      expect(harness.controller.linkHealth.rssiFraction, isNull);
      expect(find.bySemanticsLabel('Signal strength'), findsOneWidget);
      expect(find.byType(FractionallySizedBox), findsNothing);

      await leave(tester);
    });

    testWidgets('with nothing connected every figure is a dash with a reason',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);

      expect(find.text('— dBm'), findsOneWidget);
      expect(
        find.textContaining('Not connected, so there is nothing to measure'),
        findsOneWidget,
      );
      // Not zeroes. "No frames lost" and "nothing is counting" are different
      // facts and this is the last place they could be collapsed.
      expect(find.text('0'), findsNothing);

      await leave(tester);
    });

    testWidgets('the circled i explains the card in plain words', (tester) async {
      // THE SOAK AND THE RANGE WALK ARE STILL WHAT THIS CARD IS FOR. They are
      // simply not what it SAYS any more: "Leaving the screen open IS the soak
      // test" is a sentence for whoever retired the saved soak test, and the
      // person holding the recorder is told to walk away from it and watch.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);

      expect(
        find.text('How well the recorder is reaching your phone.'),
        findsOneWidget,
      );
      expect(find.textContaining('soak'), findsNothing);

      await tester.tap(find.bySemanticsLabel('About Connection'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Carry your phone away from the recorder'),
        findsOneWidget,
      );
      // What it does NOT do is hide the jargon behind the tap.
      expect(find.textContaining('frame'), findsNothing);
      expect(find.textContaining('RSSI'), findsNothing);
      // And the counters resetting is said without saying "the life of the
      // link".
      expect(
        find.textContaining('start again each time you open this screen'),
        findsOneWidget,
      );

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Carry your phone away'), findsNothing);

      await leave(tester);
    });

    testWidgets('it stands down while the mic check runs, and says why',
        (tester) async {
      // The frame subscription takes one listener. A card that kept counting
      // through a check would be reporting a stream it no longer has.
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);
      expect(harness.controller.linkHealth.watching, isTrue);

      await reveal(tester, 'MIC CHECK');
      await tester.tap(find.bySemanticsLabel('Run the noise floor check'));
      await flush(tester);

      expect(harness.controller.linkHealth.watching, isFalse);
      await tester.scrollUntilVisible(find.text('CONNECTION'), -220);
      await tester.pump();
      expect(
        find.textContaining('Paused while the mic check runs'),
        findsOneWidget,
      );

      harness.controller.cancelDeviceTest();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await flush(tester);
      // And it comes back, rather than staying dark after the check.
      expect(harness.controller.linkHealth.watching, isTrue);

      await leave(tester);
    });
  });

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

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'TEMPERATURE');

      expect(find.text('31.2 °C'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('never lets the figure be read as room temperature',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'TEMPERATURE');

      expect(find.text('TEMPERATURE'), findsOneWidget);
      expect(find.text('Recorder'), findsOneWidget);
      // "Die" and "junction" are gone from the screen; what stays is the one
      // fact a user needs, which is that this is not the room.
      expect(
        find.text('How warm the recorder is. Warmer than the room.'),
        findsOneWidget,
      );
      expect(find.textContaining('junction'), findsNothing);
      expect(find.textContaining('self-heats'), findsNothing);

      await leave(tester);
    });

    testWidgets('0x8000 reads as unknown, never as a number', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readDieTemperature(any()))
          .thenAnswer((_) async => const DieTemperature(deciCelsius: null));

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'TEMPERATURE');

      // 0x8000 is in the exported diagnostics, not on the card.
      expect(find.text('unknown'), findsOneWidget);
      expect(find.textContaining('0x8000'), findsNothing);
      expect(find.text('0.0 °C'), findsNothing);

      await leave(tester);
    });

    testWidgets('firmware without fe07 reads as unavailable', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readDieTemperature(any()))
          .thenThrow(const BleTransportException('no such characteristic'));

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'TEMPERATURE');

      expect(find.text('unavailable'), findsOneWidget);
      expect(find.textContaining('does not report its temperature'),
          findsOneWidget);

      await leave(tester);
    });

    testWidgets('with nothing connected it asks for a connection',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);
      await reveal(tester, 'TEMPERATURE');

      expect(find.text('unavailable'), findsOneWidget);
      expect(find.textContaining('Connect to the recorder to read this'),
          findsOneWidget);

      await leave(tester);
    });

    testWidgets('it follows fe07 notifications', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'TEMPERATURE');
      expect(find.text('31.2 °C'), findsOneWidget);

      // The die warms up as the radio works, which is the whole point of having
      // it on screen while the link is streaming.
      await harness.notifyTemperature(tester, deciCelsius: 447);

      expect(find.text('44.7 °C'), findsOneWidget);
      expect(find.text('31.2 °C'), findsNothing);

      await leave(tester);
    });

    testWidgets('the circled i says it is only measured while this is open',
        (tester) async {
      // A REAL COST TO THE USER - the recorder samples the sensor only because
      // this screen asked it to - so it is said, in the layer that has room for
      // it rather than on a card that has four words spare.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'TEMPERATURE');

      await tester.tap(find.bySemanticsLabel('About Temperature'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('only measures it while this screen is open'),
        findsOneWidget,
      );
      // Plain in here too: no characteristic, no die, no decidegrees.
      expect(find.textContaining('fe07'), findsNothing);
      expect(find.textContaining('die'), findsNothing);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await leave(tester);
    });
  });

  // -------------------------------------------------------------------------
  group('the mic check card', () {
    testWidgets('offers the two checks and says what each measures',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.text('Noise floor'), findsOneWidget);
      expect(find.text('Sensitivity'), findsOneWidget);
      // And nothing that was retired is still offered.
      expect(find.text('Range'), findsNothing);
      expect(find.text('Link soak'), findsNothing);
      expect(find.text('Wake on motion'), findsNothing);
      // One short sentence each, saying what the thing IS.
      expect(
        find.text('How much hiss the mic picks up in a silent room.'),
        findsOneWidget,
      );
      expect(
        find.text('How loudly your voice reaches the recorder.'),
        findsOneWidget,
      );
      // The distance is an instruction, so it is behind the circled i rather
      // than in a line that has to say what the check measures.
      expect(find.textContaining('30 cm'), findsNothing);
      expect(find.textContaining('dBFS'), findsNothing);

      await leave(tester);
    });

    testWidgets('the card\'s circled i says how to use the two checks',
        (tester) async {
      // The before-and-after IS the method, and it is an instruction rather
      // than a definition - so the card says what the checks are in one line
      // and the circled i says what to do with them.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(
        find.text('Two measurements to take now and compare later.'),
        findsOneWidget,
      );

      await tester.tap(find.bySemanticsLabel('About Mic check'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('before you put the recorder in its case'),
        findsOneWidget,
      );
      // Still not pretending to know whether the case is on.
      expect(find.textContaining('no way of knowing'), findsOneWidget);
      // And still saying nothing here writes to the device.
      expect(find.textContaining('it only listens'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await leave(tester);
    });

    testWidgets('each check has its own circled i, and it says what to DO',
        (tester) async {
      // THE HARD HALF OF THE BRIEF. A user who taps this has to come away
      // knowing where to put the recorder, not which sensor is in it.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      await tester.tap(find.bySemanticsLabel('About Noise floor'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Put the recorder down somewhere quiet'),
        findsOneWidget,
      );
      // What an unusual reading might MEAN, in terms of the object.
      expect(
        find.textContaining('resting against it or rattling'),
        findsOneWidget,
      );
      // Never a verdict on a reading.
      expect(find.textContaining('good'), findsNothing);
      expect(find.textContaining('bad'), findsNothing);
      // And no signal-processing words behind the tap either.
      expect(find.textContaining('MEMS'), findsNothing);
      expect(find.textContaining('RMS'), findsNothing);
      expect(find.textContaining('resonance'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('About Sensitivity'));
      await tester.pumpAndSettle();
      // The distance is kept, because the comparison depends on it - and it is
      // given as something to do rather than as a port geometry.
      expect(
        find.textContaining(
          'about ${DeviceTestReadings.sensitivityDistanceCm} cm away and speak',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('covering the microphone opening'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await leave(tester);
    });

    testWidgets('every circled i clears the 44px minimum hit target',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);

      for (final label in const <String>[
        'About Connection',
        'About Mic check',
        'About Noise floor',
        'About Sensitivity',
        'About Temperature',
      ]) {
        final finder = find.bySemanticsLabel(label);
        await tester.scrollUntilVisible(finder, 220);
        await tester.pump();
        expect(finder, findsOneWidget, reason: label);
        final size = tester.getSize(finder);
        expect(
          size.width,
          greaterThanOrEqualTo(AppShape.minTapTarget),
          reason: label,
        );
        expect(
          size.height,
          greaterThanOrEqualTo(AppShape.minTapTarget),
          reason: label,
        );
      }

      await leave(tester);
    });

    testWidgets('a circled i is a button to a screen reader, and dismissible',
        (tester) async {
      // THE ACCESSIBILITY REQUIREMENT, asserted rather than asserted-to. The
      // control is a button with a spoken label; the sheet is a route, so a
      // screen reader moves into it; and it goes away by its own Close button
      // AND by the barrier, which is what the system back gesture lands on.
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final handle = tester.ensureSemantics();

      await open(tester, harness);

      expect(
        tester.getSemantics(find.bySemanticsLabel('About Connection')),
        matchesSemantics(
          label: 'About Connection',
          isButton: true,
          // THE TAP ACTION IS THE REQUIREMENT. A node a screen reader can read
          // out and cannot activate is not a reachable control - see the note
          // on `Semantics.onTap` in `widgets/common.dart`.
          hasTapAction: true,
        ),
      );

      await tester.tap(find.bySemanticsLabel('About Connection'));
      await tester.pumpAndSettle();
      expect(find.text('Connection'), findsOneWidget);

      // Dismissed by tapping outside it, not only by the button.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.textContaining('Carry your phone away'), findsNothing);
      // And the live readings never moved: the card is where it was.
      expect(find.text('CONNECTION'), findsOneWidget);

      handle.dispose();
      await leave(tester);
    });

    testWidgets('with nothing connected it is unavailable and says why',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(harness.controller.testBlocker, DeviceTestBlocker.notConnected);
      expect(
        find.textContaining('Connect to the recorder first'),
        findsOneWidget,
      );
      // And there is no result on screen at all - never a zero, never a dash
      // that looks like a measurement of nothing.
      expect(find.textContaining('Latest ·'), findsNothing);

      await leave(tester);
    });

    testWidgets('a capture in progress blocks it, and says which',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await harness.record(tester);
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(harness.controller.testBlocker, DeviceTestBlocker.recording);
      expect(
        find.textContaining('A recording is running. Stop it, then try again.'),
        findsOneWidget,
      );

      await leave(tester);
    });

    testWidgets('firmware without fe04 blocks nothing here', (tester) async {
      // The wake test needed `fe04` and the scan permission. It is gone, and so
      // are the two blockers that only it had - a mic check needs neither.
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenThrow(const BleTransportException('no such characteristic'));

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(harness.controller.autoSleepAvailable, isFalse);
      expect(harness.controller.testBlocker, isNull);
      expect(find.textContaining('auto-sleep'), findsNothing);

      await leave(tester);
    });

    testWidgets('tapping Run starts the check and opens the audio stream',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      await tester.tap(find.bySemanticsLabel('Run the noise floor check'));
      await flush(tester);

      expect(
        harness.controller.deviceTests.running,
        DeviceTestKind.noiseFloor,
      );
      // The operator is half the check, so the instruction is on screen.
      expect(
        find.textContaining('Keep it quiet and do not touch it'),
        findsOneWidget,
      );
      // And it is stoppable.
      expect(
        find.bySemanticsLabel('Stop the noise floor check'),
        findsOneWidget,
      );

      harness.controller.cancelDeviceTest();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await flush(tester);
      expect(harness.controller.deviceTests.running, isNull);

      await leave(tester);
    });

    testWidgets('leaving the screen mid-check stops it and keeps what it had',
        (tester) async {
      // THE POWER RULE AGAIN. A check the user cannot see is still streaming, so
      // it stops - and what it measured is saved and labelled cancelled rather
      // than thrown away.
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await harness.controller.deviceTests.load();
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');
      await tester.tap(find.bySemanticsLabel('Run the noise floor check'));
      await flush(tester);
      expect(harness.controller.deviceTests.isRunning, isTrue);
      // Some audio did arrive, so there is a partial reading to keep. Without
      // this the run would be FAILED rather than cancelled, which is a different
      // and equally honest outcome - see the acoustic notes in the service.
      await harness.notifyFrame(tester, sequence: 0);

      await leave(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await flush(tester);

      expect(harness.controller.deviceTests.isRunning, isFalse);
      expect(harness.controller.deviceTests.isBatchActive, isFalse);
      final saved = harness.controller.deviceTests
          .latestOf(DeviceTestKind.noiseFloor);
      expect(saved, isNotNull);
      expect(saved!.outcome, DeviceTestOutcome.cancelled);
    });

    testWidgets('a check that has never run shows no result at all',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await harness.controller.deviceTests.load();
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('Latest ·'), findsNothing);
      expect(find.textContaining('0 runs saved'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('before the history is read it does not claim there is none',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      // Reading the file is what `initialise()` does. Until then "no runs" would
      // be a claim the app has not checked - the same rule the auto-sleep flag
      // and the battery follow.
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('have not been read yet'), findsOneWidget);
      expect(find.textContaining('0 runs saved'), findsNothing);

      await leave(tester);
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

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // WHAT THE CARD LEADS WITH is the latest figure, rounded, and the one
      // honest thing this history supports. Both runs are lone ones - no batch
      // id, which is what everything saved before batching existed looks like -
      // so neither measured a wobble and there is nothing to size 14 dB against.
      // The card says that rather than calling it a change.
      expect(find.textContaining('−54 dBFS'), findsOneWidget);
      expect(find.textContaining('not enough to compare with'), findsOneWidget);
      expect(find.textContaining('2 runs saved'), findsOneWidget);
      // The previous run's figure is NOT on the face of the card - that is what
      // made it unreadable.
      expect(find.textContaining('−68.9 dBFS'), findsNothing);
      expect(find.textContaining('Latest ·'), findsNothing);

      await openDetails(tester, 'noise floor');

      // And it is all still there, at full precision, one tap away. This is the
      // whole point of saving anything: the enclosure raised the noise floor by
      // 14 dB, and both figures say so.
      expect(find.textContaining('−54.2 dBFS'), findsOneWidget);
      expect(find.textContaining('−68.9 dBFS'), findsOneWidget);
      expect(find.textContaining('Latest ·'), findsOneWidget);
      expect(find.textContaining('Before ·'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('a reading that was not measured shows a dash, never a zero',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(harness, <DeviceTestResult>[
        run(
          DeviceTestKind.noiseFloor,
          at: DateTime.now(),
          outcome: DeviceTestOutcome.failed,
          readings: const <DeviceTestReading>[
            // No audio arrived, so there is no level. A silent stream is not a
            // quiet room, and it is certainly not 0 dBFS.
            DeviceTestReading(
              label: 'Noise floor (RMS)',
              value: null,
              unit: 'dBFS',
            ),
          ],
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('— dBFS'), findsOneWidget);
      expect(find.textContaining('0.0 dBFS'), findsNothing);

      await leave(tester);
    });

    testWidgets('a run that did not complete is named as such', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(harness, <DeviceTestResult>[
        run(
          DeviceTestKind.sensitivity,
          at: DateTime.now(),
          outcome: DeviceTestOutcome.failed,
          readings: const <DeviceTestReading>[
            DeviceTestReading(label: 'Peak', value: null, unit: 'dBFS'),
          ],
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // A failed run's blank reading must not be mistaken for a finished run's,
      // and the word survives the condensing: it sits beside the date, with the
      // disclosure still shut.
      expect(find.textContaining('failed'), findsOneWidget);
      expect(find.textContaining('measured today · failed'), findsOneWidget);

      await leave(tester);
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
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('Measured, but not saved'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('runs this build cannot read are accounted for, not hidden',
        (tester) async {
      // The baseline file holds runs of the three retired measurements. They stay
      // in the file untouched, and the card says how many there are rather than
      // showing a smaller history with no explanation.
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await harness.fileStore.writeBytes(
        harness.fileStore.join(
          ViewHarness.recordingsDirectory,
          DeviceTestStore.defaultFileName,
        ),
        utf8.encode(
          jsonEncode(<String, Object?>{
            'version': DeviceTestStore.formatVersion,
            'results': <Object?>[
              <String, Object?>{
                'kind': 'link-soak',
                'outcome': 'completed',
                'startedAt': '2026-09-13T14:05:00.000Z',
                'durationMs': 180000,
                'readings': <Object?>[],
                'note': null,
              },
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
              ).toJson(),
            ],
          }),
        ),
      );
      await harness.controller.deviceTests.load();

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('1 run saved'), findsOneWidget);
      expect(
        find.textContaining('1 older run is saved too'),
        findsOneWidget,
      );
      expect(find.textContaining('They are kept, untouched'), findsOneWidget);

      await leave(tester);
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

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // Not on the face of the card any more: the sample count, the range and
      // every individual reading are what made it unreadable.
      expect(find.textContaining('5 of 5 samples'), findsNothing);
      expect(find.textContaining('middle'), findsNothing);
      await openDetails(tester, 'noise floor');

      // How many samples, so nobody has to guess how much the figure is worth.
      // Spelled out rather than written n=5 of 5, which is the same fact in a
      // notation nobody outside a lab reads - the export still says n=.
      expect(find.textContaining('5 of 5 samples'), findsOneWidget);
      expect(find.textContaining('n='), findsNothing);
      // The median - a sample somebody actually took, not a mean - called the
      // middle one, which is what it is.
      expect(find.textContaining('middle −60.0 dBFS'), findsOneWidget);
      // AND the spread, on the same line. This is the requirement.
      expect(
        find.textContaining('ranged −62.0 dBFS to −58.0 dBFS'),
        findsOneWidget,
      );
      // The reading's own label is translated for the screen; the saved key
      // "Noise floor (RMS)" is untouched, and it is what the export prints.
      expect(find.textContaining('Hiss level:'), findsOneWidget);
      expect(find.textContaining('RMS'), findsNothing);
      expect(find.textContaining('5 runs saved'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('every sample is printed, so an outlier is visible',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      // One wild reading among five - a resonance, a door. It is the most
      // interesting thing in the batch and it must be on the page.
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-outlier',
          values: <num?>[-60, -61, -59, -60, -12],
          target: 5,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');
      await openDetails(tester, 'noise floor');

      expect(find.textContaining('samples:'), findsOneWidget);
      // Never silently dropped: it is in the sample list and in the range.
      expect(find.textContaining('−12.0 dBFS'), findsWidgets);
      // And it did not drag the middle value with it, which a mean would have.
      expect(find.textContaining('middle −60.0 dBFS'), findsOneWidget);

      await leave(tester);
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

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // The failures survive the condensing: the count sits beside the date with
      // the disclosure still shut, because a batch that half worked must not
      // look like one that worked.
      expect(find.textContaining('measured today · 2 failed'), findsOneWidget);

      await openDetails(tester, 'noise floor');

      // The only thing ever left out of a median is a sample that had no number
      // to contribute, and the details say how many that was.
      expect(find.textContaining('2 of 5 had no reading'), findsOneWidget);
      expect(find.textContaining('middle −61.0 dBFS'), findsOneWidget);
      // The two failures are named rather than averaged away - once in the
      // condensed line above, once in the batch's own full account.
      expect(find.textContaining('2 failed'), findsNWidgets(2));

      await leave(tester);
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

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // A PARTIAL BATCH STAYS VISIBLY PARTIAL with the disclosure shut. Short,
      // beside the date, rather than the four-clause run-on it used to be.
      expect(
        find.textContaining('measured today · 3 of 5 samples'),
        findsOneWidget,
      );

      await openDetails(tester, 'noise floor');

      // Three of five is a usable baseline. It is NOT five, and it is not
      // discarded either. Once in the condensed line, once in the full account.
      expect(find.textContaining('3 of 5 samples'), findsNWidgets(2));
      expect(find.textContaining('stopped early'), findsOneWidget);
      expect(find.textContaining('middle −60.0 dBFS'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('a single run is labelled as one, not dressed up as a baseline',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      // No batch id: exactly what every run saved by the earliest build looks
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

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');
      await openDetails(tester, 'noise floor');

      expect(find.textContaining('1 sample'), findsOneWidget);
      expect(
        find.textContaining('one run only, so there is no range to compare'),
        findsOneWidget,
      );
      // The figure is still shown - it is just not called a spread of nothing.
      expect(find.textContaining('−54.2 dBFS'), findsOneWidget);
      expect(find.textContaining('samples:'), findsNothing);
      expect(find.textContaining('ranged'), findsNothing);

      await leave(tester);
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

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');
      await openDetails(tester, 'noise floor');

      expect(find.textContaining('Latest ·'), findsOneWidget);
      expect(find.textContaining('Before ·'), findsOneWidget);
      // A count on each half, because five samples against three is a
      // different comparison from five against five.
      expect(find.textContaining('3 of 3 samples'), findsOneWidget);
      expect(find.textContaining('5 of 5 samples'), findsOneWidget);
      // The finding: about 15 dB, and both ranges are small enough to trust it.
      expect(find.textContaining('middle −53.0 dBFS'), findsOneWidget);
      expect(find.textContaining('middle −68.0 dBFS'), findsOneWidget);
      expect(
        find.textContaining('ranged −54.0 dBFS to −52.0 dBFS'),
        findsOneWidget,
      );
      expect(
        find.textContaining('ranged −70.0 dBFS to −66.0 dBFS'),
        findsOneWidget,
      );

      await leave(tester);
    });
  });

  // -------------------------------------------------------------------------
  // THE ONE LINE EACH CHECK LEADS WITH
  //
  // The feedback that produced this layout was "look how much data is shown in a
  // very scattered way user can never understand this", and it was right: one
  // check printed a date, a sample count, a status phrase, a median, a range and
  // every individual sample, twice over for sensitivity. About fifteen numbers
  // in answer to "is my mic OK?".
  //
  // What is left on the face of the card is the figure and how it sits against
  // the run before it, because the comparison is the ONLY thing a single
  // acoustic reading can honestly support. Three rules are protected here:
  //
  //   1. NO VERDICT. Not good, bad, fine, healthy, or a problem - ever.
  //   2. THE THRESHOLD IS DERIVED from the spread the saved samples actually
  //      showed, so the same difference reads as a change beside tight samples
  //      and as noise beside loose ones. A test that only checked one difference
  //      against one answer could not tell a derivation from a constant.
  //   3. NOTHING IS INVENTED when there is nothing to compare with.
  // -------------------------------------------------------------------------
  group('the headline each check leads with', () {
    testWidgets('with no earlier run it says so rather than comparing',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-first',
          values: <num?>[-60, -61, -59],
          target: 3,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('−60 dBFS'), findsOneWidget);
      expect(
        find.textContaining('nothing earlier to compare with'),
        findsOneWidget,
      );
      // No invented comparison, in either direction.
      expect(find.textContaining('than before'), findsNothing);
      expect(find.textContaining('about the same'), findsNothing);

      await leave(tester);
    });

    testWidgets('a difference inside the measured wobble is about the same',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      // Medians −60 and −58: two decibels apart, and each batch's own samples
      // spanned two decibels. Two is not more than two, so nothing moved.
      await seedHistory(harness, <DeviceTestResult>[
        ...noiseFloorBatch(
          batchId: 'nf-after',
          values: <num?>[-60, -61, -59],
          target: 3,
          at: now.subtract(const Duration(minutes: 20)),
        ),
        ...noiseFloorBatch(
          batchId: 'nf-before',
          values: <num?>[-58, -57, -59],
          target: 3,
          at: now.subtract(const Duration(days: 1)),
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('−60 dBFS'), findsOneWidget);
      expect(
        find.textContaining('about the same as before'),
        findsOneWidget,
      );

      // And the details say what "about the same" was measured against, so the
      // threshold reads as derived rather than decided.
      await openDetails(tester, 'noise floor');
      expect(
        find.textContaining('Counted as a change only past 2.0 dBFS'),
        findsOneWidget,
      );
      expect(
        find.textContaining('the widest these samples wobbled on their own'),
        findsOneWidget,
      );

      await leave(tester);
    });

    testWidgets('a difference that clears the wobble reads as louder',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      // −56 against −60: four decibels, against samples that spanned two.
      await seedHistory(harness, <DeviceTestResult>[
        ...noiseFloorBatch(
          batchId: 'nf-after',
          values: <num?>[-56, -57, -55],
          target: 3,
          at: now.subtract(const Duration(minutes: 20)),
        ),
        ...noiseFloorBatch(
          batchId: 'nf-before',
          values: <num?>[-60, -61, -59],
          target: 3,
          at: now.subtract(const Duration(days: 1)),
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('−56 dBFS'), findsOneWidget);
      expect(find.textContaining('louder than before'), findsOneWidget);
      // "Louder" is a direction, not a judgement. More hiss in a quiet room is
      // not called worse, because the app cannot know what caused it.
      for (final verdict in const <String>[
        'good',
        'bad',
        'fine',
        'healthy',
        'problem',
        'worse',
        'better',
      ]) {
        expect(find.textContaining(verdict), findsNothing, reason: verdict);
      }

      await leave(tester);
    });

    testWidgets('the other direction reads as quieter', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      await seedHistory(harness, <DeviceTestResult>[
        ...noiseFloorBatch(
          batchId: 'nf-after',
          values: <num?>[-64, -65, -63],
          target: 3,
          at: now.subtract(const Duration(minutes: 20)),
        ),
        ...noiseFloorBatch(
          batchId: 'nf-before',
          values: <num?>[-60, -61, -59],
          target: 3,
          at: now.subtract(const Duration(days: 1)),
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('−64 dBFS'), findsOneWidget);
      expect(find.textContaining('quieter than before'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('THE SAME difference reads differently beside looser samples',
        (tester) async {
      // THE TEST THAT PROVES THE THRESHOLD IS DERIVED. Identical medians to the
      // "louder" case above - −56 against −60, four decibels - but this batch's
      // own samples spanned twelve. Four decibels of movement inside a
      // twelve-decibel wobble is not evidence of anything, and a hard-coded
      // threshold could not tell the two cases apart.
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      await seedHistory(harness, <DeviceTestResult>[
        ...noiseFloorBatch(
          batchId: 'nf-after',
          values: <num?>[-56, -50, -62],
          target: 3,
          at: now.subtract(const Duration(minutes: 20)),
        ),
        ...noiseFloorBatch(
          batchId: 'nf-before',
          values: <num?>[-60, -61, -59],
          target: 3,
          at: now.subtract(const Duration(days: 1)),
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('−56 dBFS'), findsOneWidget);
      expect(find.textContaining('about the same as before'), findsOneWidget);
      expect(find.textContaining('louder than before'), findsNothing);

      await openDetails(tester, 'noise floor');
      expect(
        find.textContaining('Counted as a change only past 12.0 dBFS'),
        findsOneWidget,
      );

      await leave(tester);
    });

    testWidgets('two single runs cannot be compared, and it says so',
        (tester) async {
      // WHAT THE BARE-BOARD BASELINE ACTUALLY LOOKS LIKE: runs saved before
      // batching existed have no batch id, so each is a batch of one and neither
      // measured a wobble. There is no honest threshold, so there is no
      // comparison - rather than a threshold picked to produce one.
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      await seedHistory(harness, <DeviceTestResult>[
        lone(-56, now.subtract(const Duration(minutes: 20))),
        lone(-60, now.subtract(const Duration(days: 1))),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('−56 dBFS'), findsOneWidget);
      expect(find.textContaining('not enough to compare with'), findsOneWidget);

      await openDetails(tester, 'noise floor');
      expect(
        find.textContaining('No run of this check has taken two samples'),
        findsOneWidget,
      );

      await leave(tester);
    });

    testWidgets('an older batch lends its wobble to two single runs',
        (tester) async {
      // The same two lone runs, with one older batch behind them that DID take
      // several samples. Its spread is a measurement of this check on this
      // hardware, so it is the threshold rather than nothing.
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      await seedHistory(harness, <DeviceTestResult>[
        lone(-56, now.subtract(const Duration(minutes: 20))),
        lone(-60, now.subtract(const Duration(days: 1))),
        ...noiseFloorBatch(
          batchId: 'nf-oldest',
          values: <num?>[-60, -61, -59.5],
          target: 3,
          at: now.subtract(const Duration(days: 5)),
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // A 1.5 dB wobble, and four decibels clears it.
      expect(find.textContaining('louder than before'), findsOneWidget);

      await openDetails(tester, 'noise floor');
      expect(
        find.textContaining('Counted as a change only past 1.5 dBFS'),
        findsOneWidget,
      );

      await leave(tester);
    });

    testWidgets('the headline drops the decimal and the details keep it',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-tenths',
          values: <num?>[-39.2, -40.1, -38.5],
          target: 3,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // The samples spanned 1.6 dB, so the tenth in −39.2 is wobble wearing the
      // clothes of precision. It is not on the face of the card.
      expect(find.textContaining('−39 dBFS'), findsOneWidget);
      expect(find.textContaining('−39.2 dBFS'), findsNothing);

      await openDetails(tester, 'noise floor');

      // Kept in full where somebody has asked for detail, and kept in the
      // export, which this change did not touch.
      expect(find.textContaining('middle −39.2 dBFS'), findsOneWidget);
      expect(
        find.textContaining('ranged −40.1 dBFS to −38.5 dBFS'),
        findsOneWidget,
      );

      await leave(tester);
    });

    testWidgets('sensitivity leads with Average, and Loudest moves to details',
        (tester) async {
      // ONE METRIC LEADS. Loudest and Average used to sit on the card at equal
      // weight, which left a user deciding which of them to believe before they
      // could read either. Average is the level a voice actually arrives at;
      // Loudest is one instant and moves with a plosive.
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(
        harness,
        sensitivityBatch(
          batchId: 'sens-one',
          average: <num?>[-27, -28, -26],
          loudest: <num?>[-9, -10, -8],
          target: 3,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('−27 dBFS'), findsOneWidget);
      // Loudest is nowhere on the face of the card.
      expect(find.textContaining('Loudest'), findsNothing);
      expect(find.textContaining('−9 dBFS'), findsNothing);

      await openDetails(tester, 'sensitivity');

      // Both readings, Average first because it is the one the card led with.
      expect(find.textContaining('Average: middle −27.0 dBFS'), findsOneWidget);
      expect(find.textContaining('Loudest: middle −9.0 dBFS'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('a cancelled batch stays visibly cancelled, condensed',
        (tester) async {
      // The run-on this replaced read "1 of 5 samples · stopped early · one run
      // only, so there is no range to compare · cancelled" - four clauses saying
      // two things. Short on the card, complete in the details.
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(harness, <DeviceTestResult>[
        sample(
          DeviceTestKind.noiseFloor,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
          batchId: 'nf-cancelled',
          index: 1,
          target: 5,
          outcome: DeviceTestOutcome.cancelled,
          readings: const <DeviceTestReading>[
            DeviceTestReading(
              label: 'Noise floor (RMS)',
              value: -57.4,
              unit: 'dBFS',
            ),
          ],
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(
        find.textContaining('measured today · 1 of 5 · stopped early'),
        findsOneWidget,
      );
      // Not the run-on.
      expect(
        find.textContaining('one run only, so there is no range to compare'),
        findsNothing,
      );

      await openDetails(tester, 'noise floor');

      // Every clause is still on record where somebody asked for it.
      expect(find.textContaining('1 of 5 samples'), findsOneWidget);
      expect(
        find.textContaining('one run only, so there is no range to compare'),
        findsOneWidget,
      );
      expect(find.textContaining('cancelled'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('Details is closed until tapped, and closes again',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-toggle',
          values: <num?>[-60, -61, -59],
          target: 3,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      final show =
          find.bySemanticsLabel('Show the details of the noise floor check');
      for (var i = 0; i < 20 && show.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -120));
        await tester.pump();
      }
      await tester.scrollUntilVisible(show, 120);
      await tester.pump();

      // COLLAPSED BY DEFAULT.
      expect(find.textContaining('samples:'), findsNothing);
      // And a real 44px button to a screen reader, with a label that says which
      // way the tap goes.
      final size = tester.getSize(show);
      expect(size.width, greaterThanOrEqualTo(AppShape.minTapTarget));
      expect(size.height, greaterThanOrEqualTo(AppShape.minTapTarget));

      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.textContaining('samples:'), findsOneWidget);

      final hide =
          find.bySemanticsLabel('Hide the details of the noise floor check');
      expect(hide, findsOneWidget);
      await tester.tap(hide);
      await tester.pumpAndSettle();
      expect(find.textContaining('samples:'), findsNothing);

      await leave(tester);
    });

    testWidgets('each check has its own disclosure, opened independently',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final now = DateTime.now();
      await seedHistory(harness, <DeviceTestResult>[
        ...noiseFloorBatch(
          batchId: 'nf-only',
          values: <num?>[-60, -61, -59],
          target: 3,
          at: now.subtract(const Duration(minutes: 20)),
        ),
        ...sensitivityBatch(
          batchId: 'sens-only',
          average: <num?>[-27, -28, -26],
          loudest: <num?>[-9, -10, -8],
          target: 3,
          at: now.subtract(const Duration(minutes: 40)),
        ),
      ]);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');
      await openDetails(tester, 'noise floor');

      // The noise floor's samples are out; sensitivity's are not.
      expect(find.textContaining('Hiss level: middle'), findsOneWidget);
      expect(find.textContaining('Average: middle'), findsNothing);

      await leave(tester);
    });

    testWidgets('a reading that was never taken leads with a dash, not a zero',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await seedHistory(
        harness,
        noiseFloorBatch(
          batchId: 'nf-nothing',
          values: <num?>[null, null],
          target: 2,
          at: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      expect(find.textContaining('— dBFS'), findsOneWidget);
      expect(find.textContaining('no reading this time'), findsOneWidget);
      expect(find.textContaining('0 dBFS'), findsNothing);

      await leave(tester);
    });
  });

  // -------------------------------------------------------------------------
  // THE BATCHING, WHICH IS WHAT EARNS THE MIC CHECK ITS PLACE
  //
  // Five runs on the bare board put the sensitivity spread at 0.83 dB. That is
  // the reason this control exists: a change caused by the enclosure will stand
  // clear of a spread that narrow, and it is only possible to say so because the
  // spread was measured rather than assumed.
  // -------------------------------------------------------------------------
  group('the fixed sample counts', () {
    testWidgets('there is neither a control for them nor an explanation',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // The old knob is gone: diagnostics is for observers, and nobody should
      // have to reason about sampling statistics to read their own microphone.
      expect(find.textContaining('Samples per check'), findsNothing);
      expect(find.bySemanticsLabel('Take 3 samples per check'), findsNothing);
      expect(find.bySemanticsLabel('Take 5 samples per check'), findsNothing);
      expect(
        find.bySemanticsLabel('Take a single sample per check'),
        findsNothing,
      );

      // AND SO IS THE EXPLANATION THAT REPLACED IT. A heading, a line naming
      // both counts and a circled i about sampling statistics were three more
      // things on a card whose whole problem was how much it showed - and the
      // counts are fixed internally, so the machinery is not a user's business.
      // `DeviceTestSampling` still governs the runs; it is just not narrated.
      expect(
        find.text('Each check is taken several times'),
        findsNothing,
      );
      expect(find.bySemanticsLabel('About Repeated checks'), findsNothing);
      expect(
        find.textContaining('Noise floor ${DeviceTestSampling.noiseFloorSamples} times'),
        findsNothing,
      );
      expect(find.textContaining('median'), findsNothing);
      expect(find.textContaining('spread'), findsNothing);

      await leave(tester);
    });

    testWidgets('a running check says which sample of how many it is on',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(seconds: 30));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');
      await tester.tap(find.bySemanticsLabel('Run the noise floor check'));
      await flush(tester);

      // Progress has to be obvious: a check that looks identical on sample four
      // as on sample one is a check somebody abandons. And the count it is
      // counting up to is the noise floor's own fixed one, not a chosen number.
      expect(
        harness.controller.deviceTests.batchTarget,
        DeviceTestSampling.noiseFloorSamples,
      );
      expect(
        find.text('Sample 1 of ${DeviceTestSampling.noiseFloorSamples}'),
        findsOneWidget,
      );

      harness.controller.cancelDeviceTest();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await flush(tester);

      await leave(tester);
    });

    testWidgets('between samples it prompts, and offers to keep what it has',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(milliseconds: 60));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await harness.controller.deviceTests.load();
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      // Sensitivity is the prompted one: somebody has to stand at the mark and
      // speak, so the next sample cannot start on its own.
      await withAudio(tester, harness, harness.controller.runSensitivityTest);

      final tests = harness.controller.deviceTests;
      expect(tests.running, isNull);
      expect(tests.awaitingNextSample, isTrue);
      expect(tests.samplesTaken, 1);
      await reveal(tester, 'MIC CHECK');
      // Progress, and what the operator has to do before the next one.
      expect(
        find.textContaining(
          '1 of ${DeviceTestSampling.sensitivitySamples} samples taken',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('speak again'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Take the next sample of the sensitivity check',
        ),
        findsOneWidget,
      );

      // And stopping keeps what was measured rather than discarding it.
      await tester.tap(
        find.bySemanticsLabel(
          'Stop the sensitivity check and keep the 1 sample already taken',
        ),
      );
      await flush(tester);

      expect(tests.isBatchActive, isFalse);
      final batch = tests.batchesOf(DeviceTestKind.sensitivity).single;
      expect(batch.sampleCount, 1);
      expect(batch.requested, DeviceTestSampling.sensitivitySamples);
      expect(batch.isPartial, isTrue);

      await leave(tester);
    });

    testWidgets('the next sample starts only when the operator says so',
        (tester) async {
      final harness = ViewHarness(testWindow: const Duration(milliseconds: 40));
      addTearDown(harness.dispose);

      await harness.connect(tester);
      await harness.controller.deviceTests.load();
      await open(tester, harness);
      await reveal(tester, 'MIC CHECK');

      await withAudio(tester, harness, harness.controller.runSensitivityTest);
      final tests = harness.controller.deviceTests;
      expect(tests.awaitingNextSample, isTrue);

      await withAudio(
        tester,
        harness,
        harness.controller.continueDeviceTestBatch,
        sequence: 1,
      );

      // Two samples of three taken, and still waiting rather than looping.
      expect(tests.samplesTaken, 2);
      expect(tests.awaitingNextSample, isTrue);

      harness.controller.endDeviceTestBatch();
      await flush(tester);
      final batch = tests.batchesOf(DeviceTestKind.sensitivity).single;
      expect(batch.sampleCount, 2);
      expect(batch.isPartial, isTrue);

      await leave(tester);
    });
  });
}
