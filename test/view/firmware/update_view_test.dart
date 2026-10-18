import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/firmware_update.dart';
import 'package:voicenotetaker_app/model/firmware_update_state.dart';
import 'package:voicenotetaker_app/view/firmware/update_copy.dart';
import 'package:voicenotetaker_app/view/firmware/update_progress.dart';
import 'package:voicenotetaker_app/view/firmware/update_view.dart';
import 'package:voicenotetaker_app/view/firmware/update_widgets.dart';

import '../harness.dart';
import 'update_fakes.dart';

/// The recorder-update screen, one state at a time - the approved
/// `canvas-update/project/Update*.dc.html` and `Updating.dc.html`.
void main() {
  late int closes;

  setUp(() => closes = 0);

  Future<void> pump(WidgetTester tester, FakeUpdates updates,
          {UpdateProgress? progress}) =>
      pumpScreen(
        tester,
        UpdateView(
          updates: updates,
          progress: progress,
          onClose: () => closes++,
        ),
      );

  UpdateButton button(WidgetTester tester, String label) =>
      tester.widget<UpdateButton>(find.widgetWithText(UpdateButton, label));

  StepMark mark(WidgetTester tester, String label) =>
      tester.widget<StepRow>(find.widgetWithText(StepRow, label)).mark;

  group('ready', () {
    testWidgets('what is new, both checks met, and Update now starts it',
        (tester) async {
      final updates = offered();
      await pump(tester, updates);

      expect(find.text('Recorder update'), findsOneWidget);
      expect(find.text('Version 0.2.0, published 14 Oct'), findsOneWidget);
      expect(find.text("WHAT'S NEW"), findsOneWidget);
      expect(find.text(canvasNotes), findsOneWidget);
      expect(find.text('BEFORE YOU START'), findsOneWidget);
      expect(find.text('Recorder is on its charger'), findsOneWidget);
      expect(find.text('Phone is next to it'), findsOneWidget);
      expect(find.byType(Tick), findsNWidgets(2));
      expect(find.text(UpdateCopy.takesAbout), findsOneWidget);

      await tester.tap(find.text('Update now'));
      expect(updates.installs, 1);

      await tester.tap(find.text('Not now'));
      expect(closes, 1);
    });

    testWidgets('no release notes, no card', (tester) async {
      final updates = offered()
        ..decision = UpdateOffered(release020(notes: '  '));
      await pump(tester, updates);

      expect(find.text("WHAT'S NEW"), findsNothing);
      expect(find.text('Update now'), findsOneWidget);
    });
  });

  group('blocked', () {
    testWidgets('off the charger: the check says what to do, the button is off',
        (tester) async {
      final updates = blocked(UpdateBlockReason.notOnCharger);
      await pump(tester, updates);

      expect(find.text('Put the recorder on its charger'), findsOneWidget);
      expect(find.text("So it can't run out of power halfway"), findsOneWidget);
      expect(find.text('Phone is next to it'), findsOneWidget);
      expect(find.byType(Tick), findsOneWidget);
      expect(button(tester, 'Update now').onPressed, isNull);

      await tester.tap(find.text('Update now'));
      expect(updates.installs, 0);
    });

    testWidgets('not connected: the phone check is the one unmet',
        (tester) async {
      final updates = blocked(UpdateBlockReason.notConnected);
      await pump(tester, updates);

      expect(find.text('Bring your phone next to the recorder'), findsOneWidget);
      expect(find.text('Phone is next to it'), findsNothing);
      expect(button(tester, 'Update now').onPressed, isNull);
    });

    testWidgets('an unreadable version: no checks, the cable is the way',
        (tester) async {
      final updates = blocked(UpdateBlockReason.unknownVersion);
      await pump(tester, updates);

      expect(find.text('BEFORE YOU START'), findsNothing);
      expect(find.text(UpdateCopy.cableOnly), findsOneWidget);
      expect(button(tester, 'Update now').onPressed, isNull);
    });

    testWidgets('plugging it in turns the button on, without leaving',
        (tester) async {
      final updates = blocked(UpdateBlockReason.notOnCharger);
      await pump(tester, updates);
      expect(button(tester, 'Update now').onPressed, isNull);

      final release = updates.latestRelease!;
      updates.emit(UpdateAvailable(release), decision: UpdateOffered(release));
      await tester.pump();

      expect(find.text('Recorder is on its charger'), findsOneWidget);
      expect(button(tester, 'Update now').onPressed, isNotNull);
    });
  });

  group('updating', () {
    testWidgets('downloading reads Preparing with the download percent',
        (tester) async {
      final updates = offered()
        ..emit(UpdateDownloading(release020(), bytesDone: 50000));
      await pump(tester, updates);

      expect(find.text('Updating your recorder'), findsOneWidget);
      expect(find.text('Version 0.2.0'), findsOneWidget);
      expect(find.text('Preparing'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(mark(tester, UpdateCopy.stepUpdateMode), StepMark.pending);
      expect(find.text(UpdateCopy.keepOpen), findsOneWidget);
      // Nothing to tap, and no back button: the system gesture leaves.
      expect(find.byType(UpdateButton), findsNothing);
      expect(find.bySemanticsLabel('Back'), findsNothing);
    });

    testWidgets('waiting for the bootloader: step 1 done, sending next',
        (tester) async {
      final updates = offered()..emit(UpdateWaitingForBootloader(release020()));
      await pump(tester, updates);

      expect(find.text('Sending'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      expect(mark(tester, UpdateCopy.stepUpdateMode), StepMark.done);
      expect(mark(tester, UpdateCopy.stepSending), StepMark.active);
      expect(mark(tester, UpdateCopy.stepRestart), StepMark.pending);
    });

    testWidgets('transferring: the percent, and an estimate only after 10%',
        (tester) async {
      var now = DateTime(2026, 10, 18, 9);
      final updates = offered();
      final progress = UpdateProgress(updates.state, now: () => now);
      addTearDown(progress.dispose);
      await pump(tester, updates, progress: progress);

      updates.emit(UpdateTransferring(release020(), percent: 0));
      now = now.add(const Duration(seconds: 15));
      updates.emit(UpdateTransferring(release020(), percent: 5));
      await tester.pump();
      expect(find.text('5%'), findsOneWidget);
      expect(find.textContaining('left'), findsNothing);

      // 20% in 60 s is 3 s a percent: 80% more is four minutes.
      now = now.add(const Duration(seconds: 45));
      updates.emit(UpdateTransferring(release020(), percent: 20));
      await tester.pump();
      expect(find.text('20%'), findsOneWidget);
      expect(find.text('About 4 minutes left'), findsOneWidget);
    });

    testWidgets('confirming: step 3 is the active one', (tester) async {
      final updates = offered()..emit(UpdateConfirming(release020()));
      await pump(tester, updates);

      expect(find.text('100%'), findsOneWidget);
      expect(mark(tester, UpdateCopy.stepSending), StepMark.done);
      expect(mark(tester, UpdateCopy.stepRestart), StepMark.active);
    });

    testWidgets('leaving mid-transfer and coming back keeps the run',
        (tester) async {
      var now = DateTime(2026, 10, 18, 9);
      final updates = offered();
      final progress = UpdateProgress(updates.state, now: () => now);
      addTearDown(progress.dispose);
      await pump(tester, updates, progress: progress);
      updates.emit(UpdateTransferring(release020(), percent: 0));
      await tester.pump();

      // Away from the screen while it carries on.
      await pumpScreen(tester, const SizedBox());
      now = now.add(const Duration(seconds: 126));
      updates.emit(UpdateTransferring(release020(), percent: 42));

      await pump(tester, updates, progress: progress);
      expect(find.text('42%'), findsOneWidget);
      // 42% in 126 s: 58% more is 174 s, rounded up.
      expect(find.text('About 3 minutes left'), findsOneWidget);
    });
  });

  group('done', () {
    testWidgets('says what is running, and Done clears it and leaves',
        (tester) async {
      final updates = offered()..emit(UpdateDone(v('0.2.0')));
      await pump(tester, updates);

      expect(find.text('Your recorder is up to date'), findsOneWidget);
      expect(find.text('Version 0.2.0 is running and notes are saving again.'),
          findsOneWidget);

      await tester.tap(find.text('Done'));
      expect(updates.dismissals, 1);
      expect(closes, 1);
    });

    testWidgets('opened with nothing to offer, it says so plainly',
        (tester) async {
      final updates = FakeUpdates(installedVersion: v('0.2.0'));
      await pump(tester, updates);

      expect(find.text('Version 0.2.0 is running.'), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
    });
  });

  group('failed', () {
    testWidgets('the link dropped part-way: the percent, update mode, the cable',
        (tester) async {
      final updates = offered();
      final progress = UpdateProgress(updates.state);
      addTearDown(progress.dispose);
      updates.emit(UpdateTransferring(release020(), percent: 61));
      updates.emit(const UpdateFailed(UpdateFailure.transferFailed, canRetry: true));
      await pump(tester, updates, progress: progress);

      expect(find.text("The update didn't finish"), findsOneWidget);
      expect(find.text('The connection dropped at 61%'), findsOneWidget);
      expect(find.text('Your recorder is waiting in update mode'), findsOneWidget);
      expect(find.text(UpdateCopy.waitingBody), findsOneWidget);
      expect(find.text('IF IT KEEPS FAILING'), findsOneWidget);
      expect(find.text(UpdateCopy.usbFallback), findsOneWidget);

      await tester.tap(find.text('Try again'));
      expect(updates.retries, 1);

      // Later leaves the failure in place: only it can resume the recorder.
      await tester.tap(find.text('Later'));
      expect(closes, 1);
      expect(updates.dismissals, 0);
    });

    testWidgets('each reason in plain words', (tester) async {
      final cases = <UpdateFailure, String>{
        UpdateFailure.bootloaderNotFound: "The phone couldn't find your recorder",
        UpdateFailure.checksumMismatch:
            "The download didn't arrive intact, so nothing was sent",
        UpdateFailure.triggerRefused:
            'Put the recorder on its charger and try again',
      };
      for (final MapEntry(key: reason, value: words) in cases.entries) {
        final updates = offered()
          ..emit(UpdateFailed(reason, canRetry: true));
        await pump(tester, updates);
        expect(find.text(words), findsOneWidget, reason: reason.name);
        expect(find.text(UpdateCopy.usbFallback), findsOneWidget);
      }
      // Refused and checksum touched nothing on the recorder.
      expect(find.text("Your recorder wasn't changed"), findsOneWidget);
    });

    testWidgets('nothing to retry: one Close, which clears it', (tester) async {
      final updates = offered()
        ..emit(const UpdateFailed(UpdateFailure.recorderDidNotReturn,
            canRetry: false));
      await pump(tester, updates);

      expect(find.text("Your recorder didn't reconnect after the update"),
          findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      await tester.tap(find.text('Close'));
      expect(updates.dismissals, 1);
      expect(closes, 1);
    });
  });
}
