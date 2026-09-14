import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/home/notes_tab.dart';
import 'package:voicenotetaker_app/view/home/today_tab.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/app_icons.dart';

import 'harness.dart';
import 'home_harness.dart';

/// Home as the app actually mounts it - see `homeFor`.
Widget _home(
  ViewHarness harness, {
  VoidCallback? onOpenSettings,
  VoidCallback? onOpenDiagnostics,
  VoidCallback? onOpenLibrary,
  ValueChanged<RecordingEntry>? onOpenRecording,
  VoidCallback? onConnect,
}) =>
    homeFor(
      harness,
      onOpenSettings: onOpenSettings,
      onOpenDiagnostics: onOpenDiagnostics,
      onOpenLibrary: onOpenLibrary,
      onOpenRecording: onOpenRecording,
      onConnect: onConnect,
    );

Future<void> _openRecorderSheet(WidgetTester tester) async {
  await tester.tap(recorderStatusLine());
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('two tabs under one header; Today is the default', (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await harness.connect(tester);
    await pumpScreen(tester, _home(harness));

    expect(find.text('voiceNotetaker'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.bySemanticsLabel('Record'), findsOneWidget);
    expect(find.bySemanticsLabel('Today tab'), findsOneWidget);
    expect(find.bySemanticsLabel('Notes tab'), findsOneWidget);
    // First run: the three steps.
    expect(find.text(TodayEmpty.title), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Today tab')).flagsCollection.isSelected,
      Tristate.isTrue,
    );

    await tester.tap(find.bySemanticsLabel('Notes tab'));
    await tester.pump();
    expect(find.text('NOTES TODAY'), findsOneWidget);
    // The header stays.
    expect(find.text('voiceNotetaker'), findsOneWidget);
    expect(find.byType(BatteryIcon), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds disconnected without throwing', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await pumpScreen(tester, _home(harness));

    expect(find.text('Not connected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // THE BATTERY READOUT
  //
  // Four bars, no figure. The device's percentage comes from cell voltage
  // against an OCV curve where about 2 mV separate one point from the next in
  // the middle, so the number was precise-looking rather than reliable; the
  // buckets claim only what the measurement supports. The percentage is not
  // gone - it is on the wire, in the log, and on the developer screen.
  //
  // What these tests defend: the bucket boundaries, the dead-band that stops
  // a bar flickering, the THREE pictures (bars, measured-and-empty, no
  // reading at all), full and critical as states of their own, and words for
  // a screen reader that cannot count bars.
  // -------------------------------------------------------------------------
  group('the battery readout', () {
    /// The glyph, which is now the whole readout.
    BatteryIcon icon(WidgetTester tester) =>
        tester.widget<BatteryIcon>(find.byType(BatteryIcon));

    Future<ViewHarness> connected(WidgetTester tester, int? percent,
        {bool charging = false}) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => BatteryStatus(percent: percent, charging: charging),
      );
      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));
      return harness;
    }

    testWidgets('draws bars, and no percentage anywhere', (tester) async {
      await connected(tester, 64);

      expect(icon(tester).bars, 3);
      // The figure is gone from the main UI on purpose: 64% sits in the part
      // of the curve the measurement is worst at.
      expect(find.text('64%'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });

    // Every bucket boundary, one test each, walked from an unknown reading -
    // which is the state the app is in the moment it connects. Rising into a
    // bar has to clear the dead-band, so these are the first-reading answers
    // a user actually sees. The pure arithmetic is pinned down in
    // `test/battery_bars_test.dart`; these assert the screen renders it.
    const Map<int, int> boundaries = <int, int>{
      100: 4,
      78: 4,
      77: 3,
      53: 3,
      52: 2,
      28: 2,
      27: 1,
      3: 1,
      2: 0,
      0: 0,
    };
    for (final MapEntry<int, int> expected in boundaries.entries) {
      testWidgets('${expected.key}% draws ${expected.value} of 4 bars',
          (tester) async {
        await connected(tester, expected.key);
        expect(icon(tester).bars, expected.value);
      });
    }

    testWidgets('no fe05 at all draws an empty shell, not zero bars',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenThrow(
        const BleTransportException('no such characteristic'),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      // Null, not zero: the shell is drawn with no slots in it at all, which
      // is a different picture from a cell measured as flat.
      expect(icon(tester).bars, isNull);
      expect(icon(tester).color, AppColors.textTertiary);
      expect(find.bySemanticsLabel('Battery level unknown'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('0xFF draws an empty shell too', (tester) async {
      await connected(tester, null);

      expect(icon(tester).bars, isNull);
      expect(find.bySemanticsLabel('Battery level unknown'), findsOneWidget);
    });

    testWidgets('a measured 0% is empty and critical, never unknown',
        (tester) async {
      await connected(tester, 0);

      // THE DISTINCTION THIS WHOLE READOUT IS BUILT ON: zero bars with the
      // critical tint is a flat cell; no bars at all is no answer. They must
      // not render alike.
      expect(icon(tester).bars, 0);
      expect(icon(tester).color, AppColors.error);
      expect(find.bySemanticsLabel('Battery empty'), findsOneWidget);
      expect(find.bySemanticsLabel('Battery level unknown'), findsNothing);
    });

    testWidgets('a flat cell is not a full one', (tester) async {
      // The regression this exists for: a bucketing loop that fell through
      // with "all bars" instead of "no bars" drew 0% as FULL.
      await connected(tester, 0);

      expect(icon(tester).bars, isNot(4));
      expect(icon(tester).color, isNot(AppColors.connected));
    });

    testWidgets('full is a state of its own, and is confirmed not rounded',
        (tester) async {
      // The firmware caps the reported percentage at 99 while charging, so
      // 100 means the charger terminated on a full cell - a fact, not a
      // rounded number.
      await connected(tester, 100);

      expect(icon(tester).bars, 4);
      expect(icon(tester).color, AppColors.connected);
      expect(icon(tester).charging, isFalse,
          reason: 'green WITHOUT the bolt is what separates full from charging');
      expect(find.bySemanticsLabel('Battery full'), findsOneWidget);
    });

    testWidgets('99% fills four bars without claiming to be full',
        (tester) async {
      await connected(tester, 99);

      expect(icon(tester).bars, 4);
      expect(icon(tester).color, AppColors.textTertiary);
      expect(find.bySemanticsLabel('Battery 4 of 4 bars'), findsOneWidget);
    });

    testWidgets('critical is visually distinct, and says so in words',
        (tester) async {
      // 10% is LED_BATTERY_LOW_PERCENT: the app's warning and the device's
      // own amber blink agree, so the two never disagree in front of a user.
      await connected(tester, 8);

      expect(icon(tester).bars, 1);
      expect(icon(tester).color, AppColors.error);
      expect(
        find.bySemanticsLabel('Battery 1 of 4 bars, critically low'),
        findsOneWidget,
      );
    });

    testWidgets('11% is not critical', (tester) async {
      await connected(tester, 11);

      expect(icon(tester).color, AppColors.textTertiary);
      expect(find.bySemanticsLabel('Battery 1 of 4 bars'), findsOneWidget);
    });

    testWidgets('two bars charging does not look like two bars discharging',
        (tester) async {
      await connected(tester, 40, charging: true);

      expect(icon(tester).bars, 2);
      expect(icon(tester).charging, isTrue);
      expect(icon(tester).color, AppColors.connected);
      // Said in WORDS, not only in the glyph's colour. It replaces
      // "Connected" because the breathing green dot beside it already says
      // the link is up, and the header has no room for both.
      expect(find.text('Charging'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(
        find.bySemanticsLabel('Battery 2 of 4 bars, charging'),
        findsOneWidget,
      );
    });

    testWidgets('discharging at the same level says only Connected',
        (tester) async {
      await connected(tester, 40);

      expect(icon(tester).bars, 2);
      expect(icon(tester).charging, isFalse);
      expect(icon(tester).color, AppColors.textTertiary);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Charging'), findsNothing);
      expect(find.bySemanticsLabel('Battery 2 of 4 bars'), findsOneWidget);
    });

    testWidgets('charging outranks critical, and keeps the bolt',
        (tester) async {
      // The user has already done the thing a red shell would be asking for.
      await connected(tester, 4, charging: true);

      expect(icon(tester).bars, 1);
      expect(icon(tester).color, AppColors.connected,
          reason: 'not the critical red: it is already on the charger');
      expect(icon(tester).charging, isTrue);
      // The words do not soften, though - the screen reader still hears it.
      expect(
        find.bySemanticsLabel('Battery 1 of 4 bars, critically low, charging'),
        findsOneWidget,
      );
    });

    testWidgets('charging shows even when the charge does not', (tester) async {
      await connected(tester, null, charging: true);

      expect(icon(tester).bars, isNull);
      expect(icon(tester).charging, isTrue);
      expect(find.text('Charging'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Battery level unknown, charging'),
        findsOneWidget,
      );
    });

    testWidgets('the dead-band holds a bar while the reading wobbles',
        (tester) async {
      final harness = await connected(tester, 80);
      expect(icon(tester).bars, 4);

      // 75 is a boundary. Walk a reading back and forth across it: a cell
      // sitting there really does report 74, 76, 74 as the load changes, and
      // a bar that twitched with it would read as BROKEN in a way a number
      // twitching between 74 and 76 does not.
      for (final int percent in <int>[76, 74, 76, 73, 77, 74]) {
        await harness.notifyBattery(tester, percent: percent, charging: false);
        await tester.pump();
        expect(
          icon(tester).bars,
          4,
          reason: '$percent% is inside the dead-band, so the bar must hold',
        );
      }

      // It is a dead-band, not a latch: clear of it, the bar does drop.
      await harness.notifyBattery(tester, percent: 71, charging: false);
      await tester.pump();
      expect(icon(tester).bars, 3);

      // ...and rising back into the wobble does not put it straight back.
      await harness.notifyBattery(tester, percent: 76, charging: false);
      await tester.pump();
      expect(icon(tester).bars, 3);
      await harness.notifyBattery(tester, percent: 78, charging: false);
      await tester.pump();
      expect(icon(tester).bars, 4);
    });

    testWidgets('the dead-band survives the view being rebuilt from scratch',
        (tester) async {
      // WHERE THE STATE LIVES. The previous answer is held by the controller,
      // not by the widget: a view that kept it would lose it to any rebuild
      // that replaced the element - a route change, a reparent, a hot reload
      // - and the bars would snap to the raw reading the moment the user
      // navigated. 74% buckets to THREE bars from cold and holds FOUR when
      // the last answer was four, so the two cases are tellable apart.
      final harness = await connected(tester, 80);
      await harness.notifyBattery(tester, percent: 74, charging: false);
      await tester.pump();
      expect(icon(tester).bars, 4);

      // Tear the whole tree down and build a new HomeView over the same
      // controller.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpScreen(tester, _home(harness));

      expect(icon(tester).bars, 4,
          reason: 'the controller kept the previous answer, so 74% holds');
    });

    testWidgets('a reading that goes away resets the dead-band',
        (tester) async {
      final harness = await connected(tester, 80);
      expect(icon(tester).bars, 4);

      // No reading means no previous answer to hold: the next 74% is a first
      // reading again, and buckets to three.
      await harness.notifyBattery(tester, percent: null, charging: false);
      await tester.pump();
      expect(icon(tester).bars, isNull);

      await harness.notifyBattery(tester, percent: 74, charging: false);
      await tester.pump();
      expect(icon(tester).bars, 3);
    });

    testWidgets('the header does not move between states', (tester) async {
      final harness = await connected(tester, 9);
      final name = tester.getRect(find.text('voiceNotetaker'));
      final glyph = tester.getRect(find.byType(BatteryIcon));

      // 9% -> 100% is the widest jump the contract allows, and it changes the
      // bars, the tint and the semantics. The device name beside it must not
      // move: the glyph is a fixed size in every state.
      await harness.notifyBattery(tester, percent: 100, charging: false);
      await tester.pump();
      expect(icon(tester).bars, 4);
      expect(tester.getRect(find.text('voiceNotetaker')), name);
      expect(tester.getRect(find.byType(BatteryIcon)), glyph);

      // ...and neither does dropping back to no reading at all.
      await harness.notifyBattery(tester, percent: null, charging: false);
      await tester.pump();
      expect(icon(tester).bars, isNull);
      expect(tester.getRect(find.text('voiceNotetaker')), name);
      expect(tester.getRect(find.byType(BatteryIcon)), glyph);

      // Nor does the bolt appearing.
      await harness.notifyBattery(tester, percent: 50, charging: true);
      await tester.pump();
      expect(icon(tester).charging, isTrue);
      expect(tester.getRect(find.text('voiceNotetaker')), name);
      expect(tester.getRect(find.byType(BatteryIcon)), glyph);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a notification moves the readout without a reconnect',
        (tester) async {
      final harness = await connected(tester, 80);
      expect(icon(tester).bars, 4);

      await harness.notifyBattery(tester, percent: 30, charging: false);
      await tester.pump();

      expect(icon(tester).bars, 2);
    });
  });

  group('Recorder settings, which the status line opens', () {
    testWidgets('holds always listening, and Disconnect while connected',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));
      await _openRecorderSheet(tester);

      expect(find.byType(AlwaysListeningCard), findsOneWidget);
      expect(find.bySemanticsLabel('Disconnect'), findsOneWidget);
      final size = tester.getSize(find.bySemanticsLabel('Disconnect'));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
      expect(tester.widget<Text>(find.text('Disconnect')).style?.color, AppColors.error);

      await tester.tap(find.bySemanticsLabel('Disconnect'));
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 400));

      verify(() => harness.transport.disconnect(knownDevice.id)).called(1);
      expect(harness.controller.isConnected, isFalse);
      expect(harness.controller.phase, AppPhase.idle);
      expect(find.bySemanticsLabel('Disconnect'), findsNothing,
          reason: 'nothing left to disconnect');
    });

    testWidgets('leaves no stale device name or battery behind', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBattery(any())).thenAnswer(
        (_) async => const BatteryStatus(percent: 64, charging: true),
      );

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));
      expect(tester.widget<BatteryIcon>(find.byType(BatteryIcon)).bars, 3);
      expect(find.text('Charging'), findsOneWidget);

      await _openRecorderSheet(tester);
      await tester.tap(find.bySemanticsLabel('Disconnect'));
      await flush(tester);
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Charging'), findsNothing);
      final glyph = tester.widget<BatteryIcon>(find.byType(BatteryIcon));
      expect(glyph.bars, isNull);
      expect(glyph.charging, isFalse);
      expect(find.bySemanticsLabel('Battery level unknown'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('offers Connect when nothing is connected', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      var connect = false;

      await pumpScreen(tester, _home(harness, onConnect: () => connect = true));
      await _openRecorderSheet(tester);

      expect(find.bySemanticsLabel('Disconnect'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Connect a recorder'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(connect, isTrue);
    });
  });

  group('the mic in the header', () {
    testWidgets('starts a manual recording while connected', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(tester, _home(harness));

      final size = tester.getSize(find.bySemanticsLabel('Record'));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));

      await tester.tap(find.bySemanticsLabel('Record'));
      await flush(tester);

      expect(harness.controller.phase, AppPhase.recording);
      verify(() => harness.transport.subscribeFrames(knownDevice.id)).called(1);
    });

    testWidgets('says why, in plain words, when it cannot', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(tester, _home(harness));
      await tester.tap(find.bySemanticsLabel('Record'));
      await tester.pump();

      expect(find.text('Connect your recorder to record.'), findsOneWidget);
      expect(harness.controller.isRecording, isFalse);
    });
  });

  testWidgets('Notes: search and All notes open the library', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    var opened = 0;

    await pumpScreen(tester, _home(harness, onOpenLibrary: () => opened++));
    await tester.tap(find.bySemanticsLabel('Notes tab'));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('All notes'));
    await tester.tap(find.bySemanticsLabel('Search notes'));
    await tester.pump();
    expect(opened, 2);
  });

  testWidgets('Notes: a row opens playback for that recording', (tester) async {
    final now = DateTime.now();
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    RecordingEntry? opened;
    final at = DateTime(now.year, now.month, now.day, 0, 1);
    await harness.seedRecording(at: at);

    await pumpScreen(tester, _home(harness, onOpenRecording: (entry) => opened = entry));
    await tester.tap(find.bySemanticsLabel('Notes tab'));
    await tester.pump();
    expect(find.byType(NotesTab), findsOneWidget);

    await tester.tap(find.text('00:01'));
    await tester.pump();

    expect(opened?.title, 'Voice note 00:01');
    expect(opened?.path, isNotNull);
  });

  // Two separate tests rather than two pumps in one: pumping a second screen
  // into the same position reuses the State of the first, which hides bugs.
  testWidgets('the menu opens Recorder settings', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    var opened = 0;

    await pumpScreen(tester, _home(harness, onOpenSettings: () => opened++));

    await tester.tap(find.bySemanticsLabel('Settings'));
    await tester.pump();
    await tester.tap(recorderStatusLine());
    await tester.pump();
    expect(opened, 2, reason: 'the menu and the status line both go there');
  });

  testWidgets('Diagnostics is a row on Recorder settings', (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    var opened = false;

    await pumpScreen(tester, _home(harness, onOpenDiagnostics: () => opened = true));
    await tester.tap(find.bySemanticsLabel('Settings'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.bySemanticsLabel('Diagnostics'));
    await tester.pump();
    expect(opened, isTrue);
  });

  group('short viewports', () {
    for (final tab in <String>['Today tab', 'Notes tab']) {
      testWidgets('landscape does not overflow on $tab', (tester) async {
        final harness = ViewHarness();
        addTearDown(harness.dispose);
        await pumpScreen(tester, _home(harness), size: const Size(873, 393));
        await harness.connect(tester);
        await tester.tap(find.bySemanticsLabel(tab));
        await tester.pump();

        expect(tester.takeException(), isNull, reason: 'a RenderFlex overflow raises here');
      });
    }
  });

  testWidgets('the battery glyph carries a bolt only while charging',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await pumpScreen(tester, _home(harness));
    await harness.connect(tester);

    await harness.notifyBattery(tester, percent: 62, charging: false);
    expect(tester.widget<BatteryIcon>(find.byType(BatteryIcon)).charging, isFalse);

    await harness.notifyBattery(tester, percent: 62, charging: true);
    expect(tester.widget<BatteryIcon>(find.byType(BatteryIcon)).charging, isTrue);
    expect(tester.takeException(), isNull);
  });
}
