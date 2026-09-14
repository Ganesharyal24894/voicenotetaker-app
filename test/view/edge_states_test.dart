import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/connection_lost_view.dart';
import 'package:voicenotetaker_app/view/all_notes_view.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/app_icons.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';
import 'package:voicenotetaker_app/view/widgets/edge_state.dart';
import 'package:voicenotetaker_app/view/widgets/scan_control.dart';

import 'harness.dart';
import 'home_harness.dart';

/// The tint of the one glyph inside the edge state on screen.
///
/// Colour ENCODES CATEGORY in these screens - amber the user can fix it, red it
/// genuinely failed, purple nothing is wrong - so it is asserted rather than
/// left to a screenshot.
Color _tint(WidgetTester tester) {
  final well = find.descendant(
    of: find.byType(EdgeState),
    matching: find.byType(AppIcon),
  );
  return tester.widget<AppIcon>(well).color;
}

AppGlyph _glyph(WidgetTester tester) {
  final well = find.descendant(
    of: find.byType(EdgeState),
    matching: find.byType(AppIcon),
  );
  return tester.widget<AppIcon>(well).glyph;
}

void main() {
  setUpAll(registerViewFallbacks);

  group('an adapter that cannot be used gets a screen of its own', () {
    testWidgets('powered off: amber, and one tap to the Bluetooth settings',
        (tester) async {
      final harness = ViewHarness(availability: BleAvailability.poweredOff);
      addTearDown(harness.dispose);

      await harness.begin(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      expect(find.text('Bluetooth is off'), findsOneWidget);
      expect(
        find.text(
          'voiceNotetaker finds your recorder over Bluetooth. Turn it on to '
          'scan.',
        ),
        findsOneWidget,
      );
      expect(find.text('Bluetooth off'), findsOneWidget);
      expect(_glyph(tester), AppGlyph.bluetoothOff);
      // The user can fix this one.
      expect(_tint(tester), AppColors.warning);
      // The scan control is gone: there is nothing to scan with.
      expect(find.byType(ScanControl), findsNothing);

      await tester.tap(find.text('Open Bluetooth settings'));
      await flush(tester);
      verify(() => harness.settings.openBluetoothSettings()).called(1);
    });

    testWidgets('unauthorized: amber, and one tap to the app settings',
        (tester) async {
      final harness = ViewHarness(availability: BleAvailability.unauthorized);
      addTearDown(harness.dispose);

      await harness.begin(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      expect(find.text('Bluetooth permission needed'), findsOneWidget);
      expect(
        find.text(
          'Nearby-device access is off, so scanning finds nothing. You can '
          'grant it in Settings.',
        ),
        findsOneWidget,
      );
      expect(find.text('No permission'), findsOneWidget);
      expect(_glyph(tester), AppGlyph.lock);
      expect(_tint(tester), AppColors.warning);

      await tester.tap(find.text('Open app settings'));
      await flush(tester);
      verify(() => harness.settings.openAppSettings()).called(1);
    });

    testWidgets('and "Why is this needed?" actually answers the question',
        (tester) async {
      final harness = ViewHarness(availability: BleAvailability.unauthorized);
      addTearDown(harness.dispose);

      await harness.begin(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      await tester.tap(find.text('Why is this needed?'));
      await tester.pumpAndSettle();

      expect(find.text('Why Bluetooth is needed'), findsOneWidget);
      expect(find.textContaining('Bluetooth Low Energy'), findsOneWidget);
      // And it says what the manifest declares: no location is derived.
      expect(find.textContaining('never derives your location'),
          findsOneWidget);
    });

    testWidgets('unsupported: red, and NO primary action, because retrying '
        'cannot help', (tester) async {
      final harness = ViewHarness(availability: BleAvailability.unsupported);
      addTearDown(harness.dispose);
      var libraryOpened = 0;

      await harness.begin(tester);
      await pumpScreen(
        tester,
        ScanView(
          controller: harness.controller,
          onOpenLibrary: () => libraryOpened++,
        ),
      );

      expect(find.text("This phone can't use Bluetooth LE"), findsOneWidget);
      expect(find.text('Unsupported'), findsOneWidget);
      expect(_glyph(tester), AppGlyph.circleSlash);
      // This one really cannot work.
      expect(_tint(tester), AppColors.error);

      // THE POINT OF THIS SCREEN: no retry is offered, because a retry would
      // be a lie. Only the secondary action, pointing at what still works.
      expect(
        find.descendant(
          of: find.byType(EdgeState),
          matching: find.byType(PrimaryButton),
        ),
        findsNothing,
      );
      expect(find.text('Scan again'), findsNothing);
      expect(find.text('Try again'), findsNothing);

      await tester.tap(find.text('Open library'));
      await flush(tester);
      expect(libraryOpened, 1);
    });

    testWidgets('a powered-on adapter gets none of them', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.begin(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      expect(find.byType(EdgeState), findsNothing);
      expect(find.text('Tap to scan'), findsOneWidget);
    });

    testWidgets('and an adapter switched off while the screen is open swaps '
        'to it', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.begin(tester);
      await pumpScreen(
        tester,
        ListenableBuilder(
          listenable: harness.controller,
          builder: (_, _) => ScanView(controller: harness.controller),
        ),
      );
      expect(find.byType(EdgeState), findsNothing);

      await harness.notifyAvailability(tester, BleAvailability.poweredOff);
      await tester.pump();

      expect(find.text('Bluetooth is off'), findsOneWidget);
    });
  });

  group('a scan that found nothing is a RESULT, not a failure', () {
    testWidgets('a finished window with nothing in it says so, in purple',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));
      // Mid-scan nothing is concluded: the screen is still scanning.
      expect(find.text('Scanning…'), findsOneWidget);
      expect(find.byType(EdgeState), findsNothing);
      expect(harness.controller.scanOutcome, ScanOutcome.pending);

      await harness.endScanWindow(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      expect(harness.controller.scanOutcome, ScanOutcome.nothingFound);
      expect(find.text('No recorder nearby'), findsOneWidget);
      expect(
        find.text(
          'Nothing answered in 10 seconds. Check the recorder is awake and '
          'within a few metres.',
        ),
        findsOneWidget,
      );
      expect(find.text('None found'), findsOneWidget);
      expect(_glyph(tester), AppGlyph.broadcast);

      // PURPLE. Nothing has gone wrong, and this screen must not read as
      // though something had.
      expect(_tint(tester), AppColors.purpleText);
      expect(_tint(tester), isNot(AppColors.error));
      expect(_tint(tester), isNot(AppColors.warning));
    });

    testWidgets('and the copy names 10 seconds because the transport waits '
        'exactly that long', (tester) async {
      // The number is user-visible; this is what stops it drifting.
      expect(BleTransport.scanWindow, const Duration(seconds: 10));
    });

    testWidgets('"Scan again" starts another scan', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.endScanWindow(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      await tester.tap(find.text('Scan again'));
      await flush(tester);

      verify(() => harness.transport.scan()).called(2);
      expect(harness.controller.isScanning, isTrue);
      // And the screen is no longer claiming a conclusion it has un-reached.
      expect(harness.controller.scanOutcome, ScanOutcome.pending);
    });

    testWidgets('a window that DID find something concludes nothing of the '
        'kind', (tester) async {
      final harness = ViewHarness(
        devices: const <DiscoveredDevice>[knownDevice],
      );
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.endScanWindow(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      expect(harness.controller.scanOutcome, ScanOutcome.devicesFound);
      expect(find.text('No recorder nearby'), findsNothing);
      expect(find.text('Connect'), findsOneWidget);
    });

    testWidgets('a scan the USER stopped early concludes nothing either',
        (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.stopScan(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      // "Nothing answered in 10 seconds" would be a lie after two: only a
      // window that ran to its end may say it.
      expect(harness.controller.scanOutcome, ScanOutcome.pending);
      expect(find.text('No recorder nearby'), findsNothing);
      expect(find.text('Tap to scan'), findsOneWidget);
    });
  });

  group('a failed connect is not a failed scan', () {
    Future<ViewHarness> failing(WidgetTester tester) async {
      final harness = ViewHarness(
        devices: const <DiscoveredDevice>[knownDevice],
      );
      addTearDown(harness.dispose);
      when(() => harness.transport.connect(any())).thenAnswer(
        (_) async => throw const BleTransportException('gatt 133'),
      );
      await harness.discover(tester);
      await harness.connect(tester);
      return harness;
    }

    testWidgets('it names the specific failure, in red', (tester) async {
      final harness = await failing(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      expect(harness.controller.linkOutcome, LinkOutcome.connectFailed);
      expect(find.text("Couldn't connect"), findsOneWidget);
      expect(
        find.text(
          'voiceNotetaker found the recorder but the connection didn\'t '
          'complete. This usually clears on a second try.',
        ),
        findsOneWidget,
      );
      expect(find.text('Not connected'), findsOneWidget);
      expect(_glyph(tester), AppGlyph.linkBroken);
      // This one really did fail.
      expect(_tint(tester), AppColors.error);

      // NOT confused with "nothing was there": the recorder was found.
      expect(find.text('No recorder nearby'), findsNothing);
      expect(harness.controller.scanOutcome, isNot(ScanOutcome.nothingFound));
    });

    testWidgets('"Try again" goes back to the same recorder', (tester) async {
      final harness = await failing(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      await tester.tap(find.text('Try again'));
      await flush(tester);

      verify(() => harness.transport.connect(knownDevice.id)).called(2);
    });

    testWidgets('"Choose another device" drops the explanation, not the '
        'devices', (tester) async {
      final harness = await failing(tester);
      await pumpScreen(
        tester,
        ListenableBuilder(
          listenable: harness.controller,
          builder: (_, _) => ScanView(controller: harness.controller),
        ),
      );

      await tester.tap(find.text('Choose another device'));
      await flush(tester);
      await tester.pump();

      expect(find.byType(EdgeState), findsNothing);
      expect(harness.controller.linkOutcome, LinkOutcome.none);
      // The list the user was choosing from is still there.
      expect(find.text('voiceNotetaker'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
    });
  });

  group('a dropped link is not a failed connect', () {
    testWidgets('it gets Home\'s screen, amber, and the reassurance that the '
        'recorder keeps going', (tester) async {
      final harness = ViewHarness(
        devices: const <DiscoveredDevice>[knownDevice],
      );
      addTearDown(harness.dispose);

      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await harness.discover(tester);
      await harness.connect(tester);
      await settleDock(tester);

      await harness.dropLink(tester);
      await settleDock(tester);

      expect(harness.controller.linkOutcome, LinkOutcome.connectionLost);
      expect(find.byType(ConnectionLostView), findsOneWidget);
      // Home's title, because this is Home telling the user what happened.
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('Recorder disconnected'), findsOneWidget);
      // THE REASSURANCE IS THE POINT: a dropped link is not lost audio.
      expect(
        find.text(
          'The link dropped, most likely out of range. Your recorder keeps '
          'capturing on its own and will sync when you reconnect.',
        ),
        findsOneWidget,
      );
      expect(_glyph(tester), AppGlyph.signalLost);
      expect(_tint(tester), AppColors.warning);

      // NOT the failed-handshake screen, which is red and says something else.
      expect(find.text("Couldn't connect"), findsNothing);
      expect(_tint(tester), isNot(AppColors.error));
    });

    testWidgets('Reconnect goes back to the recorder it lost', (tester) async {
      final harness = ViewHarness(
        devices: const <DiscoveredDevice>[knownDevice],
      );
      addTearDown(harness.dispose);

      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await harness.discover(tester);
      await harness.connect(tester);
      await settleDock(tester);
      await harness.dropLink(tester);
      await settleDock(tester);

      await tester.tap(find.text('Reconnect'));
      await flush(tester);
      await settleDock(tester);

      verify(() => harness.transport.connect(knownDevice.id)).called(2);
      expect(harness.controller.linkOutcome, LinkOutcome.none);
    });

    testWidgets('a disconnect the USER asked for shows nothing of the sort',
        (tester) async {
      final harness = ViewHarness(
        devices: const <DiscoveredDevice>[knownDevice],
      );
      addTearDown(harness.dispose);

      await pumpScreen(tester, AppRoot(controller: harness.controller));
      await harness.discover(tester);
      await harness.connect(tester);
      await settleDock(tester);

      // Disconnect lives in the recorder sheet the Home status line opens.
      await tester.tap(recorderStatusLine());
      await settleDock(tester);
      await tester.tap(find.bySemanticsLabel('Disconnect'));
      await flush(tester);
      await settleDock(tester);

      expect(harness.controller.linkOutcome, LinkOutcome.none);
      expect(find.byType(ConnectionLostView), findsNothing);
      expect(find.text('Recorder disconnected'), findsNothing);
      expect(find.byType(ScanView), findsOneWidget);
    });
  });

  group('an empty notes list is an invitation, not an apology', () {
    testWidgets('it is purple, and it does not apologise', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await pumpScreen(
        tester,
        AllNotesView(controller: harness.controller, onOpen: (_) {}),
      );

      expect(find.text('No notes yet'), findsOneWidget);
      expect(_glyph(tester), AppGlyph.levels);
      expect(_tint(tester), AppColors.purpleText);
      expect(_tint(tester), isNot(AppColors.error));
      expect(_tint(tester), isNot(AppColors.warning));
      expect(find.textContaining('Sorry'), findsNothing);
      expect(find.textContaining('No notes yet.'), findsNothing);
      // Nothing to search yet, so no search field.
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('the shared structure', () {
    testWidgets('every action on an edge state clears the 44px minimum',
        (tester) async {
      final harness = ViewHarness(availability: BleAvailability.unauthorized);
      addTearDown(harness.dispose);

      await harness.begin(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      for (final label in <String>['Open app settings', 'Why is this needed?']) {
        final target = find.ancestor(
          of: find.text(label),
          matching: find.byType(Semantics),
        );
        expect(
          tester.getSize(target.first).height,
          greaterThanOrEqualTo(AppShape.minTapTarget),
          reason: '"$label" must be at least 44px tall',
        );
      }
    });

    testWidgets('a state with no actions at all still builds', (tester) async {
      await pumpScreen(
        tester,
        const Scaffold(
          body: Column(
            children: <Widget>[
              Expanded(
                child: EdgeState(
                  glyph: AppGlyph.levels,
                  tint: AppColors.purpleText,
                  headline: 'Nothing here',
                  body: 'And nothing to do about it.',
                ),
              ),
            ],
          ),
        ),
      );

      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.byType(PrimaryButton), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the icon well and the primary button are the sizes the design '
        'draws', (tester) async {
      final harness = ViewHarness(availability: BleAvailability.poweredOff);
      addTearDown(harness.dispose);

      await harness.begin(tester);
      await pumpScreen(tester, ScanView(controller: harness.controller));

      // 64x64 well with a 28px glyph in it, from the mockups.
      final well = tester.getSize(
        find
            .ancestor(
              of: find.byType(AppIcon),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(well, const Size(EdgeState.wellSize, EdgeState.wellSize));
      expect(
        tester.getSize(find.byType(AppIcon)),
        const Size(EdgeState.glyphSize, EdgeState.glyphSize),
      );

      // 48px primary, spanning the content width inside the 24px gutters.
      final button = tester.getSize(find.byType(PrimaryButton));
      expect(button.height, 48);
      expect(button.width, 390 - 2 * AppShape.gutter);

      // The body copy is measured rather than full-bleed.
      final body = tester.getSize(
        find.text(
          'voiceNotetaker finds your recorder over Bluetooth. Turn it on to '
          'scan.',
        ),
      );
      expect(body.width, lessThanOrEqualTo(EdgeState.bodyMaxWidth));
    });

    test('the seven states are seven glyphs, not one reused', () {
      const glyphs = <AppGlyph>{
        AppGlyph.bluetoothOff,
        AppGlyph.lock,
        AppGlyph.circleSlash,
        AppGlyph.broadcast,
        AppGlyph.linkBroken,
        AppGlyph.signalLost,
        AppGlyph.levels,
      };
      expect(glyphs, hasLength(7));
    });
  });
}
