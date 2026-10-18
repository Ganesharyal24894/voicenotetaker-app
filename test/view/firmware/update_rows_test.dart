import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/firmware_update.dart';
import 'package:voicenotetaker_app/model/firmware_update_state.dart';
import 'package:voicenotetaker_app/view/firmware/recorder_section.dart';
import 'package:voicenotetaker_app/view/firmware/update_ready_row.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';

import '../harness.dart';
import '../home_harness.dart';
import 'update_fakes.dart';

/// Where the update shows outside its own screen: Today's quiet row and
/// Settings' Software row - `canvas-update/project/Main.dc.html` and
/// `Settings.dc.html`.
void main() {
  setUpAll(registerViewFallbacks);

  group('Settings: the Software row', () {
    Future<int Function()> settings(WidgetTester tester, FakeUpdates? updates,
        {VoidCallback? onOpenDiagnostics}) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      var opened = 0;
      await pumpScreen(
        tester,
        SettingsView(
          controller: harness.controller,
          onBack: () {},
          onOpenDiagnostics: onOpenDiagnostics ?? () {},
          updates: updates,
          onOpenUpdate: () => opened++,
        ),
      );
      // The Recorder section is the last one, below the fold.
      final list = find
          .descendant(of: find.byType(SettingsView), matching: find.byType(Scrollable))
          .first;
      await tester.drag(list, const Offset(0, -2000));
      await tester.pumpAndSettle();
      return () => opened;
    }

    testWidgets('an update ready: both versions, and a tap opens the screen',
        (tester) async {
      final opened = await settings(tester, offered());

      expect(find.text('RECORDER'), findsOneWidget);
      expect(find.text('Software'), findsOneWidget);
      expect(find.text('Version 0.1.0. Update to 0.2.0 ready'), findsOneWidget);

      await tester.tap(find.text('Software'));
      expect(opened(), 1);
    });

    testWidgets('blocked off the charger still says the update is ready',
        (tester) async {
      await settings(tester, blocked(UpdateBlockReason.notOnCharger));
      expect(find.text('Version 0.1.0. Update to 0.2.0 ready'), findsOneWidget);
    });

    testWidgets('up to date: says so, and leads nowhere', (tester) async {
      final opened = await settings(
        tester,
        FakeUpdates(installedVersion: v('0.2.0'), latestRelease: release020()),
      );

      expect(find.text('Version 0.2.0, up to date'), findsOneWidget);
      await tester.tap(find.text('Software'));
      expect(opened(), 0);
    });

    testWidgets('checking reads Checking…', (tester) async {
      await settings(
        tester,
        FakeUpdates(state: const UpdateChecking(), installedVersion: v('0.1.0')),
      );
      expect(find.text('Checking…'), findsOneWidget);
    });

    testWidgets('mid-run it reopens the screen', (tester) async {
      final updates = offered()
        ..emit(UpdateTransferring(release020(), percent: 30));
      final opened = await settings(tester, updates);

      expect(find.text('Updating to 0.2.0'), findsOneWidget);
      await tester.tap(find.text('Software'));
      expect(opened(), 1);
    });

    testWidgets('Diagnostics sits under it, in the same section',
        (tester) async {
      var diagnostics = false;
      await settings(tester, offered(), onOpenDiagnostics: () => diagnostics = true);

      final software = tester.getTopLeft(find.text('Software'));
      final row = tester.getTopLeft(find.text('Diagnostics'));
      expect(row.dy, greaterThan(software.dy));
      expect(find.byType(SettingsLinkCard), findsNWidgets(2));

      await tester.tap(find.text('Diagnostics'));
      expect(diagnostics, isTrue);
    });

    testWidgets('no service: no Software row, Diagnostics stays',
        (tester) async {
      await settings(tester, null);
      expect(find.text('Software'), findsNothing);
      expect(find.text('Diagnostics'), findsOneWidget);
    });
  });

  group('Today: the update row', () {
    Future<int Function()> today(WidgetTester tester, FakeUpdates? updates) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      var opened = 0;
      final summaries = summariesFor(harness);
      addTearDown(summaries.dispose);
      await pumpScreen(
        tester,
        HomeView(
          controller: harness.controller,
          summaries: summaries,
          onOpenLibrary: () {},
          onOpenRecording: (_) {},
          updates: updates,
          onOpenUpdate: () => opened++,
        ),
      );
      return () => opened;
    }

    testWidgets('shows when the update can go now, and a tap opens it',
        (tester) async {
      final opened = await today(tester, offered());

      expect(find.text('A recorder update is ready'), findsOneWidget);
      expect(find.text('Version 0.2.0. Takes about 5 minutes on the charger.'),
          findsOneWidget);
      await tester.tap(find.text('A recorder update is ready'));
      expect(opened(), 1);
    });

    testWidgets('not while it is blocked, up to date, running, or absent',
        (tester) async {
      for (final updates in <FakeUpdates?>[
        blocked(UpdateBlockReason.notOnCharger),
        blocked(UpdateBlockReason.notConnected),
        FakeUpdates(installedVersion: v('0.2.0')),
        offered()..emit(UpdateTransferring(release020(), percent: 10)),
        null,
      ]) {
        await today(tester, updates);
        expect(find.byType(UpdateReadyRow), findsOneWidget);
        expect(find.text('A recorder update is ready'), findsNothing);
      }
    });

    testWidgets('comes and goes with the decision, on Today only',
        (tester) async {
      final updates = blocked(UpdateBlockReason.notOnCharger);
      await today(tester, updates);
      expect(find.text('A recorder update is ready'), findsNothing);

      final release = updates.latestRelease!;
      updates.emit(UpdateAvailable(release), decision: UpdateOffered(release));
      await tester.pump();
      expect(find.text('A recorder update is ready'), findsOneWidget);

      await tester.tap(find.text('Notes'));
      await tester.pump();
      expect(find.text('A recorder update is ready'), findsNothing);
    });
  });

  group('SoftwareLine', () {
    test('never says up to date before a release has been looked at', () {
      final line = SoftwareLine.of(
        state: const UpdateIdle(),
        decision: const UpdateNone(),
        installed: v('0.1.0'),
        latestKnown: false,
      );
      expect(line.meta, 'Version 0.1.0');
      expect(line.opens, isFalse);
    });

    test('no version yet asks for the recorder', () {
      final line = SoftwareLine.of(
        state: const UpdateIdle(),
        decision: const UpdateNone(),
        installed: null,
        latestKnown: true,
      );
      expect(line.meta, 'Connect your recorder to see its version');
    });

    test('a failed run reopens the screen', () {
      final line = SoftwareLine.of(
        state: const UpdateFailed(UpdateFailure.transferFailed, canRetry: true),
        decision: const UpdateNone(),
        installed: null,
        latestKnown: true,
      );
      expect(line.meta, "The last update didn't finish");
      expect(line.opens, isTrue);
    });
  });
}
