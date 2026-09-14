import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/auto_sleep.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/developer_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';

import 'harness.dart';

void main() {
  setUpAll(registerViewFallbacks);

  // -------------------------------------------------------------------------
  // THE DEBUG-ONLY GUARANTEE
  //
  // `flutter test` always runs a DEBUG build - kDebugMode is true and there is
  // no way to flip it from inside a test - so the release half of the gate
  // cannot be exercised at runtime here. It is covered two ways instead:
  //
  //   * the debug half is asserted below (the gate returns the screen), and
  //   * the source is asserted to contain exactly one construction of
  //     DeveloperView, inside an `if (kDebugMode)`. Because kDebugMode is a
  //     compile-time constant, that branch is dead code in a release build and
  //     the screen is tree-shaken out of the binary.
  //
  // A true end-to-end check would mean building a release binary and grepping
  // its symbols, which is a job for CI, not for `flutter test`.
  // -------------------------------------------------------------------------
  group('release gating', () {
    test('tests themselves run in debug mode', () {
      expect(kDebugMode, isTrue,
          reason: 'the assertions below describe the debug half of the gate');
    });

    test('the gate hands back the screen in a debug build', () {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      final screen = debugOnlyDeveloperView(controller: harness.controller);
      expect(screen, isA<DeveloperView>());
    });

    test('DeveloperView is constructed nowhere but inside the kDebugMode gate',
        () {
      // `debugOnlyDeveloperView(` contains the class name as a substring, so
      // match only a real constructor call.
      final construction = RegExp(r'(?<![A-Za-z_])DeveloperView\(');
      final sources = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

      for (final source in sources) {
        final text = source.readAsStringSync();
        if (source.path.endsWith('developer_view.dart')) continue;
        expect(
          construction.hasMatch(text),
          isFalse,
          reason: '${source.path} constructs DeveloperView outside the gate',
        );
      }

      final gate = File('lib/view/developer_view.dart').readAsStringSync();
      // Two mentions with a paren after them: the class's own constructor
      // declaration, and the single construction inside the gate.
      expect(construction.allMatches(gate), hasLength(2));
      expect(
        RegExp(r'return DeveloperView\(').allMatches(gate),
        hasLength(1),
      );
      expect(
        gate.contains('if (kDebugMode) {\n    return DeveloperView('),
        isTrue,
        reason: 'the single construction must sit inside `if (kDebugMode)`',
      );
    });
  });

  group('the screen', () {
    testWidgets('builds disconnected', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      expect(find.text('Developer'), findsOneWidget);
      expect(find.text('DEBUG ONLY'), findsOneWidget);
      expect(find.text('LINK'), findsOneWidget);
      expect(find.text('STREAM'), findsOneWidget);
      expect(find.text('CODEC'), findsOneWidget);
      expect(find.text('AUTO-SLEEP'), findsOneWidget);
      expect(find.text('Export diagnostics'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('what a user can only WATCH has moved to Diagnostics',
        (tester) async {
      // The observe/mutate split. This screen keeps the two controls that write
      // to the recorder plus the raw counters a bug report needs; the die
      // temperature and the mic check are readings, so they are on the screen
      // that ships in release builds.
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      expect(find.text('DIE TEMPERATURE'), findsNothing);
      expect(find.text('MIC CHECK'), findsNothing);
      expect(find.text('DEVICE TESTS'), findsNothing);
      // And nothing that used to run a measurement from here is offered.
      expect(find.bySemanticsLabel(RegExp('^Run the ')), findsNothing);
    });

    testWidgets('shows the link and stream readings it really has',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      expect(find.text('EB:6B:5E:4C:33:A3'), findsOneWidget);
      expect(find.text('−54 dBm'), findsOneWidget);
      expect(find.text('0 (0.00%)'), findsOneWidget);

      // THE ADVERTISING SAMPLE, NOT THE LIVE LINK, and the label says so. The
      // live signal is the meter on Diagnostics, and the two are different
      // numbers - one was taken once at scan time and never updated.
      expect(find.text('RSSI at scan'), findsOneWidget);

      // The five rows that always read "—" are gone: ATT MTU, interval, PHY,
      // throughput and the jitter buffer were never exposed by BleTransport, so
      // every one of them was a permanent dash taking up a line. Cell voltage
      // stays, because `fe05` genuinely has a value-shaped hole where it would
      // be.
      expect(find.text('ATT MTU'), findsNothing);
      expect(find.text('Interval'), findsNothing);
      expect(find.text('PHY'), findsNothing);
      expect(find.text('Throughput'), findsNothing);
      expect(find.text('Jitter buffer'), findsNothing);
      // Nothing above the fold reads as a dash any more. (Cell voltage still
      // does, further down the list, because `fe05` really does have a
      // value-shaped hole where the millivolts would be.)
      expect(find.text('—'), findsNothing);
    });

    testWidgets('the codec selector drives the controller', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      expect(harness.controller.preferredCodec, AudioCodec.imaAdpcm);

      await tester.tap(find.text('Raw PCM'));
      await tester.pump();

      expect(harness.controller.preferredCodec, AudioCodec.pcmS16le);
    });

    testWidgets('Export diagnostics produces a report', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      await tester.tap(find.text('Export diagnostics'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Diagnostics'), findsOneWidget);
      expect(
        find.textContaining('address: EB:6B:5E:4C:33:A3'),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------
  // AUTO-SLEEP
  //
  // The flag lives in the device's flash, so the screen may only ever show
  // what it read back. The state that matters most here is the THIRD one:
  // a device that did not answer must render as unavailable, with NEITHER
  // segment filled, because "Off" would be a claim about a setting that can
  // put the recorder to sleep.
  // ---------------------------------------------------------------------
  group('the auto-sleep toggle', () {
    /// Scrolls the auto-sleep card up to where it can be tapped: the
    /// developer screen is taller than the phone and the card is the last of
    /// them, so it starts below the fold.
    Future<void> reveal(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.text(label));
      await tester.pump();
    }

    /// The painted fill of a segment: purple when selected, null when not.
    Color? fillOf(WidgetTester tester, String label) {
      final box = tester.widget<Container>(
        find.ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      return (box.decoration! as BoxDecoration).color;
    }

    testWidgets('shows OFF when the device reports 0x00', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => const AutoSleepSetting.legacy(false));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      expect(fillOf(tester, 'Off'), AppColors.primaryFill);
      expect(fillOf(tester, 'On'), isNull);
    });

    testWidgets('shows ON when the device reports 0x01', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => const AutoSleepSetting.legacy(true));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      expect(fillOf(tester, 'On'), AppColors.primaryFill);
      expect(fillOf(tester, 'Off'), isNull);
    });

    testWidgets('a device that does not report it shows neither state',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any())).thenThrow(
        const BleTransportException('could not read the auto-sleep setting'),
      );

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      expect(fillOf(tester, 'On'), isNull);
      expect(fillOf(tester, 'Off'), isNull,
          reason: 'an unread flag must never render as "off"');
      expect(
        find.textContaining('did not report the setting'),
        findsOneWidget,
      );

      // And it is inert: tapping a setting the device never reported writes
      // nothing to the device.
      await reveal(tester, 'On');
      await tester.tap(find.text('On'));
      await flush(tester);
      verifyNever(() => harness.transport.setAutoSleep(any(), any()));
    });

    testWidgets('with nothing connected the control is unavailable',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      expect(fillOf(tester, 'On'), isNull);
      expect(fillOf(tester, 'Off'), isNull);
      expect(find.textContaining('Connect to the recorder'), findsOneWidget);
    });

    testWidgets('tapping ON writes to the device and repaints', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => const AutoSleepSetting.legacy(false));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      await reveal(tester, 'On');
      await tester.tap(find.text('On'));
      await flush(tester);

      verify(() => harness.transport.setAutoSleep(knownDevice.id, true))
          .called(1);
      expect(harness.controller.autoSleepEnabled, isTrue);
      expect(fillOf(tester, 'On'), AppColors.primaryFill);
    });

    testWidgets('tapping OFF writes the disable', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readAutoSleep(any()))
          .thenAnswer((_) async => const AutoSleepSetting.legacy(true));

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      await reveal(tester, 'Off');
      await tester.tap(find.text('Off'));
      await flush(tester);

      verify(() => harness.transport.setAutoSleep(knownDevice.id, false))
          .called(1);
      expect(fillOf(tester, 'Off'), AppColors.primaryFill);
    });

    testWidgets('says when the device sleeps and when it will not',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      expect(
        find.textContaining('about 10 seconds without motion'),
        findsOneWidget,
      );
      expect(
        find.textContaining('not sleep while recording'),
        findsOneWidget,
      );
    });

    testWidgets('the screen is reachable by its accessibility labels',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      // "On" and "Off" say nothing on their own when read aloud.
      expect(find.bySemanticsLabel('Auto-sleep on'), findsOneWidget);
      expect(find.bySemanticsLabel('Auto-sleep off'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // THE BATTERY CARD
  //
  // Home shows four bars, because that is all a percentage derived from cell
  // voltage can honestly support. The figure itself is not gone - the device
  // still reports it and still logs it, and it is kept HERE, where a caveat
  // can be written down next to it and where precision is worth something.
  // -------------------------------------------------------------------------
  group('the battery card', () {
    /// The card is the last one on a screen taller than the phone, so it has
    /// to be scrolled to before it is even built.
    Future<void> reveal(WidgetTester tester) async {
      await tester.scrollUntilVisible(find.text('BATTERY'), 200);
      await tester.pump();
    }

    Future<ViewHarness> connected(WidgetTester tester, int? percent,
        {bool charging = false}) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus(percent: percent, charging: charging),
      );
      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester);
      return harness;
    }

    testWidgets('keeps the percentage the main screen no longer shows',
        (tester) async {
      await connected(tester, 64);

      expect(find.text('Charge'), findsOneWidget);
      expect(find.text('64%'), findsOneWidget);
      // And what Home drew from it, so a complaint about the bars can be
      // checked against the figure that produced them.
      expect(find.text('Bars'), findsOneWidget);
      expect(find.text('3 of 4'), findsOneWidget);
    });

    testWidgets('says why the bars exist', (tester) async {
      await connected(tester, 64);

      expect(find.textContaining('2 mV'), findsOneWidget);
      expect(find.textContaining('9 and 38 mV per point'), findsOneWidget);
    });

    testWidgets('millivolts are not invented from the percentage',
        (tester) async {
      // `fe05` carries a percentage and a flags byte, and nothing else.
      // Back-calculating a voltage through the same curve that produced the
      // percentage would be a circle dressed up as a measurement, so the row
      // reads unknown - the same rule ATT MTU follows.
      await connected(tester, 64);

      expect(find.text('Cell voltage'), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Cell voltage'),
            matching: find.byType(Row),
          ),
          matching: find.text('—'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('0xFF reads as unknown, never as a number', (tester) async {
      await connected(tester, null);

      expect(find.text('unknown (0xFF)'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('firmware without fe05 reads as unavailable', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenThrow(
        const BleTransportException('no such characteristic'),
      );

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await reveal(tester);

      expect(find.text('unavailable'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('full and critical are named beside the count',
        (tester) async {
      await connected(tester, 100);
      expect(find.text('4 of 4 (full)'), findsOneWidget);
    });

    testWidgets('a critical reading is named too', (tester) async {
      await connected(tester, 8);
      expect(find.text('1 of 4 (critical)'), findsOneWidget);
    });

    testWidgets('a flat cell is not reported as a full one', (tester) async {
      await connected(tester, 0);
      expect(find.text('0%'), findsOneWidget);
      expect(find.text('0 of 4 (critical)'), findsOneWidget);
      // The bug this guards: a bucketing loop that fell through with "all
      // bars" drew a dead cell as a full one.
      expect(find.textContaining('(full)'), findsNothing);
      expect(find.text('4 of 4'), findsNothing);
    });

    testWidgets('charging is stated', (tester) async {
      await connected(tester, 40, charging: true);

      expect(find.text('Charging'), findsOneWidget);
      expect(find.text('yes'), findsOneWidget);
    });

    testWidgets('the diagnostics report carries the figure and the bars',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 64, charging: false),
      );

      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));

      await tester.tap(find.text('Export diagnostics'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Both halves: a report with only the percentage could not explain a
      // complaint about the bars, and one with only the bars could not be
      // checked.
      expect(find.textContaining('battery: 64%'), findsOneWidget);
      expect(find.textContaining('battery bars: 3 of 4'), findsOneWidget);
    });
  });

  group('the last transcript card', () {
    Future<ViewHarness> open(WidgetTester tester) async {
      final harness = ViewHarness(recognizer: ScriptedRecognizer());
      addTearDown(harness.dispose);
      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await tester.scrollUntilVisible(find.text('LAST TRANSCRIPT'), 200);
      await tester.pump();
      return harness;
    }

    testWidgets('is a readout only: no recording picker, no Transcribe',
        (tester) async {
      await open(tester);

      expect(find.text('Transcribe a recording to see its timings.'),
          findsOneWidget);
      expect(find.text('TRANSCRIPTION SPIKE'), findsNothing);
      expect(find.text('Transcribe'), findsNothing);
      expect(find.byType(DropdownButton<String>), findsNothing);
    });

    testWidgets('shows the last job\'s timings and memory', (tester) async {
      final harness = ViewHarness(recognizer: ScriptedRecognizer());
      addTearDown(harness.dispose);
      await harness.seedRecording(length: const Duration(seconds: 16));
      await tester.runAsync(
        () => harness.controller.transcribe(harness.controller.recordings.single),
      );
      await harness.connect(tester);
      await pumpScreen(tester, DeveloperView(controller: harness.controller));
      await tester.scrollUntilVisible(find.text('Memory after'), 200);
      await tester.pump();

      expect(find.text('1200 ms'), findsOneWidget);
      expect(find.text('293 MB'), findsOneWidget);
      expect(find.text('684 MB'), findsOneWidget);
      expect(find.text('303 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
