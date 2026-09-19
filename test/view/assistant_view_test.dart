import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/assistant_controller.dart';
import 'package:voicenotetaker_app/drivers/email_sender.dart';
import 'package:voicenotetaker_app/drivers/secret_store.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_send.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/transcript_store.dart';
import 'package:voicenotetaker_app/view/all_notes_view.dart';
import 'package:voicenotetaker_app/view/note_view.dart';
import 'package:voicenotetaker_app/services/assistant/assistant_account_store.dart';
import 'package:voicenotetaker_app/view/assistant_view.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';

import '../assistant/assistant_fakes.dart' as fakes;
import 'harness.dart';

/// "Send to Instinct" - the setup form, the settled screen, the Undo banner
/// and the mark on a note.
///
/// Every one of these drives the REAL [AssistantController] over fakes, so
/// what the screen shows is what the controller actually holds rather than
/// what a mock was told to say.
void main() {
  setUpAll(registerViewFallbacks);

  late fakes.MemoryFileStore files;
  late fakes.RecordingEmailSender sender;
  late MemorySecretStore secrets;
  late fakes.FakeNetwork network;

  const directory = '/support';
  const outboxPath = '$directory/assistant-outbox.json';
  const note = '/recordings/2026-09-18T09-14-00.wav';
  const instruction = 'Move the Thursday review to Friday';

  setUp(() {
    files = fakes.MemoryFileStore();
    sender = fakes.RecordingEmailSender();
    secrets = MemorySecretStore();
    network = fakes.FakeNetwork();
  });

  tearDown(() async => network.close());

  AssistantController build({
    bool withHaptics = true,
    OutboxPolicy policy = const OutboxPolicy(),
    DateTime Function()? clock,
  }) =>
      AssistantController(
        fileStore: files,
        directory: directory,
        sender: sender,
        secrets: secrets,
        network: network,
        haptics: withHaptics ? fakes.FakeHaptics() : null,
        policy: policy,
        clock: clock,
      );

  /// An outbox on disk before the controller ever starts - the only way to
  /// put a finished send in front of a screen without waiting out a real
  /// backoff.
  void seedOutbox(List<Map<String, Object?>> entries) {
    files.files[outboxPath] = Uint8List.fromList(
      utf8.encode(jsonEncode(<String, Object?>{
        'version': 1,
        'entries': entries,
      })),
    );
  }

  Map<String, Object?> entry({
    String noteId = note,
    String text = instruction,
    required String status,
    String? failure,
  }) =>
      <String, Object?>{
        'noteId': noteId,
        'instruction': text,
        'spokenAt': DateTime(2026, 9, 18, 9, 14).toIso8601String(),
        'status': status,
        'readyAt': DateTime(2026, 9, 18, 9, 14, 5).toIso8601String(),
        'attempts': 1,
        'failure': ?failure,
        if (status == 'sent')
          'sentAt': DateTime(2026, 9, 18, 9, 14, 6).toIso8601String(),
      };

  /// A controller that is on and set up.
  Future<AssistantController> ready({
    bool withHaptics = true,
    OutboxPolicy policy = const OutboxPolicy(),
  }) async {
    final controller = build(withHaptics: withHaptics, policy: policy);
    await controller.initialise();
    await controller.saveAccount(
      address: fakes.testAccount.address,
      password: fakes.testAccount.password,
    );
    await controller.setEnabled(true);
    return controller;
  }

  Widget screen(AssistantController controller) => AssistantView(
        assistant: controller,
        onBack: () {},
        now: DateTime(2026, 9, 18, 18),
      );

  PrimaryButton saveButton(WidgetTester tester) => tester.widget<PrimaryButton>(
        find.widgetWithText(PrimaryButton, AssistantCopy.save),
      );

  // -------------------------------------------------------------- not set up

  group('not set up', () {
    testWidgets('the setup form, with both addresses prefilled',
        (tester) async {
      final controller = build();
      await controller.initialise();
      await pumpScreen(tester, screen(controller));

      expect(find.text(AssistantCopy.title), findsOneWidget);
      expect(find.text(AssistantCopy.blurbOne), findsOneWidget);
      expect(find.text(AssistantCopy.blurbTwo), findsOneWidget);
      expect(find.text('ASSISTANT'), findsOneWidget);
      expect(find.text('SEND FROM'), findsOneWidget);
      expect(find.text(AssistantCopy.appPasswordLink), findsOneWidget);
      expect(find.text(AssistantCopy.approveOnce), findsOneWidget);

      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(
        fields.map((field) => field.controller!.text).toList(),
        <String>[
          AssistantController.defaultAssistantAddress,
          AssistantController.defaultSenderAddress,
          '',
        ],
      );
      // The password field, and only the password field, is obscured.
      expect(
        fields.map((field) => field.obscureText).toList(),
        <bool>[false, false, true],
      );

      controller.dispose();
    });

    testWidgets('Save is off until both addresses and the password are there',
        (tester) async {
      final controller = build();
      await controller.initialise();
      await pumpScreen(tester, screen(controller));

      // Prefilled addresses, no password yet.
      expect(saveButton(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).at(2), 'sixteenletters');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNotNull);

      // An address that is not one takes Save away again.
      await tester.enterText(find.byType(TextField).at(0), 'instinct');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).at(0), 'a b@mail.com');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).at(0), 'me@mail.com');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNotNull);

      controller.dispose();
    });

    testWidgets('Save keeps the details, turns it on, and shows the settled '
        'screen - and the password is never on the screen again',
        (tester) async {
      final controller = build();
      await controller.initialise();
      await pumpScreen(tester, screen(controller));

      await tester.enterText(find.byType(TextField).at(0), 'to@mail.com');
      await tester.enterText(find.byType(TextField).at(1), 'from@mail.com');
      await tester.enterText(find.byType(TextField).at(2), 'sixteenletters');
      await tester.pump();
      await tester.tap(find.widgetWithText(PrimaryButton, AssistantCopy.save));
      await tester.pump();
      await tester.pump();

      expect(controller.hasAccount, isTrue);
      expect(controller.enabled, isTrue);
      expect(controller.senderAddress, 'from@mail.com');
      expect(controller.assistantAddress, 'to@mail.com');

      // The settled screen, not the form.
      expect(find.text(AssistantCopy.sendingRow), findsOneWidget);
      expect(find.text('to@mail.com'), findsOneWidget);
      expect(find.text('from@mail.com'), findsOneWidget);
      // Nothing anywhere in the tree quotes the password.
      expect(find.text('sixteenletters'), findsNothing);
      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .any((text) => (text.data ?? '').contains('sixteenletters')),
        isFalse,
      );

      controller.dispose();
    });
  });

  // ------------------------------------------------------------- test email

  group('the test email', () {
    testWidgets('a failure says why, in one plain sentence', (tester) async {
      sender.willReturn(
        <EmailResult>[const EmailResult.failed(EmailFailure.signIn)],
      );
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      await tester.tap(find.widgetWithText(QuietButton, AssistantCopy.test));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(controller.testState, AssistantTestState.failed);
      expect(find.text(AssistantFailure.signIn.message), findsOneWidget);

      controller.dispose();
    });

    testWidgets('a success says to look for the reply', (tester) async {
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      await tester.tap(find.widgetWithText(QuietButton, AssistantCopy.test));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(controller.testState, AssistantTestState.sent);
      expect(find.text(AssistantCopy.testSent), findsOneWidget);
      expect(sender.sendCount, 1);

      controller.dispose();
    });

    testWidgets('while it is on the wire the button says so and cannot be '
        'tapped again', (tester) async {
      sender.holdOpen = true;
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      await tester.tap(find.widgetWithText(QuietButton, AssistantCopy.test));
      await tester.pump();
      await tester.pump();

      expect(find.text(AssistantCopy.testSending), findsOneWidget);
      expect(
        tester
            .widget<QuietButton>(
              find.widgetWithText(QuietButton, AssistantCopy.testSending),
            )
            .onPressed,
        isNull,
      );

      sender.inFlight!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text(AssistantCopy.testSent), findsOneWidget);

      controller.dispose();
    });
  });

  // ---------------------------------------------------------------- settled

  group('set up', () {
    testWidgets('the switch, the wake phrase and the two addresses',
        (tester) async {
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      expect(find.text(AssistantCopy.sendingRow), findsOneWidget);
      expect(find.text(AssistantCopy.rowOn), findsOneWidget);
      expect(find.text('WAKE PHRASE'), findsOneWidget);
      expect(find.text('“Instinct,”'), findsOneWidget);
      expect(find.text(AssistantCopy.wakeMeta), findsOneWidget);
      expect(find.text(AssistantCopy.to), findsOneWidget);
      expect(find.text(AssistantCopy.from), findsOneWidget);
      expect(find.text(fakes.testAssistant), findsOneWidget);
      expect(find.text(fakes.testAccount.address), findsOneWidget);
      // No form, and nowhere to read a password back from.
      expect(find.byType(TextField), findsNothing);

      controller.dispose();
    });

    testWidgets('turning it off leaves everything else in place',
        (tester) async {
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.pump();

      expect(controller.enabled, isFalse);
      expect(controller.hasAccount, isTrue);
      expect(find.text(AssistantCopy.rowOff), findsOneWidget);

      controller.dispose();
    });

    testWidgets('this phone buzzes; an iPhone says it cannot', (tester) async {
      final android = await ready();
      await pumpScreen(tester, screen(android));
      expect(find.text(AssistantCopy.buzzes), findsOneWidget);
      android.dispose();

      final iphone = await ready(withHaptics: false);
      await pumpScreen(tester, screen(iphone));
      expect(find.text(AssistantCopy.cannotBuzz), findsOneWidget);
      iphone.dispose();
    });

    testWidgets('the wake phrase can be changed, and a short one is refused',
        (tester) async {
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      await tester.tap(find.bySemanticsLabel(AssistantCopy.edit));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.tap(find.widgetWithText(TextButton, AssistantCopy.save));
      await tester.pumpAndSettle();

      expect(controller.wakePhrase, 'Instinct,');
      expect(find.text(AssistantCopy.wakeTooShort), findsOneWidget);

      await tester.tap(find.bySemanticsLabel(AssistantCopy.edit));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Jarvis');
      await tester.tap(find.widgetWithText(TextButton, AssistantCopy.save));
      await tester.pumpAndSettle();

      expect(controller.wakePhrase, 'Jarvis');
      expect(find.text('“Jarvis”'), findsOneWidget);

      controller.dispose();
    });

    testWidgets('recent sends: what was said, when, and Sent or Failed',
        (tester) async {
      seedOutbox(<Map<String, Object?>>[
        entry(status: 'sent'),
        entry(
          noteId: '/recordings/b.wav',
          text: 'Ask Priya for the invoice',
          status: 'failed',
          failure: 'gaveUp',
        ),
      ]);
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      expect(find.text('RECENT SENDS'), findsOneWidget);
      expect(find.text(instruction), findsOneWidget);
      expect(find.text('Ask Priya for the invoice'), findsOneWidget);
      expect(find.text(AssistantCopy.sent), findsOneWidget);
      expect(find.text(AssistantCopy.failed), findsOneWidget);
      expect(find.text('Today, 09:14'), findsNWidgets(2));

      controller.dispose();
    });

    testWidgets('nothing sent yet says so', (tester) async {
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      expect(find.text(AssistantCopy.nothingSentYet), findsOneWidget);

      controller.dispose();
    });

    testWidgets('forgetting is confirmed first, and clears the account',
        (tester) async {
      final controller = await ready();
      await pumpScreen(tester, screen(controller));

      await tester.scrollUntilVisible(
        find.bySemanticsLabel(AssistantCopy.forget),
        120,
      );
      await tester.tap(find.bySemanticsLabel(AssistantCopy.forget));
      await tester.pumpAndSettle();
      expect(find.text(AssistantCopy.forgetTitle), findsOneWidget);
      expect(find.text(AssistantCopy.forgetBody), findsOneWidget);

      // Cancel changes nothing.
      await tester.tap(find.widgetWithText(TextButton, AssistantCopy.cancel));
      await tester.pumpAndSettle();
      expect(controller.hasAccount, isTrue);
      expect(controller.enabled, isTrue);

      await tester.scrollUntilVisible(
        find.bySemanticsLabel(AssistantCopy.forget),
        120,
      );
      await tester.tap(find.bySemanticsLabel(AssistantCopy.forget));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(TextButton, AssistantCopy.forgetConfirm),
      );
      await tester.pumpAndSettle();

      expect(controller.hasAccount, isFalse);
      expect(controller.enabled, isFalse);
      expect(await secrets.read(AssistantAccountStore.key), isNull);
      // The setup form is back.
      expect(find.text(AssistantCopy.blurbOne), findsOneWidget);

      controller.dispose();
    });
  });

  // ------------------------------------------------------------ undo banner

  group('the Undo banner', () {
    Widget banner(AssistantController controller) => Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: AssistantUndoBanner(assistant: controller),
          ),
        );

    testWidgets('nothing at all when nothing is pending', (tester) async {
      final controller = await ready();
      await pumpScreen(tester, banner(controller));

      expect(find.text(AssistantCopy.sendingTo), findsNothing);

      controller.dispose();
    });

    testWidgets('the instruction, a countdown, and Undo stops it',
        (tester) async {
      final clock = fakes.FakeClock(DateTime(2026, 9, 18, 9, 14));
      final controller = AssistantController(
        fileStore: files,
        directory: directory,
        sender: sender,
        secrets: secrets,
        network: network,
        haptics: fakes.FakeHaptics(),
        clock: clock.call,
      );
      await controller.initialise();
      await controller.saveAccount(
        address: fakes.testAccount.address,
        password: fakes.testAccount.password,
      );
      await controller.setEnabled(true);
      await pumpScreen(tester, banner(controller));

      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, $instruction',
        spokenAt: clock.now,
      );
      await tester.pump();

      expect(find.text(AssistantCopy.sendingTo), findsOneWidget);
      expect(find.text(instruction), findsOneWidget);
      expect(find.text(AssistantCopy.undo), findsOneWidget);
      expect(find.text('5 s'), findsOneWidget);

      clock.advance(const Duration(seconds: 2));
      await tester.pump(AssistantUndoBanner.tick);
      expect(find.text('3 s'), findsOneWidget);

      await tester.tap(find.text(AssistantCopy.undo));
      await tester.pump();
      await tester.pump();

      expect(find.text(AssistantCopy.stopped), findsOneWidget);
      expect(controller.statusFor(note), AssistantSendStatus.notSent);
      expect(sender.sendCount, 0);

      await tester.pump(AssistantUndoBanner.outcomeLinger);
      expect(find.text(AssistantCopy.stopped), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('an Undo that arrives too late says it has already gone',
        (tester) async {
      final clock = fakes.FakeClock(DateTime(2026, 9, 18, 9, 14));
      final controller = AssistantController(
        fileStore: files,
        directory: directory,
        sender: sender,
        secrets: secrets,
        network: network,
        clock: clock.call,
      );
      await controller.initialise();
      await controller.saveAccount(
        address: fakes.testAccount.address,
        password: fakes.testAccount.password,
      );
      await controller.setEnabled(true);
      await pumpScreen(tester, banner(controller));

      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, $instruction',
        spokenAt: clock.now,
      );
      await tester.pump();
      expect(find.text(AssistantCopy.undo), findsOneWidget);

      // The window shuts while the banner is still on screen.
      clock.advance(const Duration(seconds: 9));
      await tester.tap(find.text(AssistantCopy.undo));
      await tester.pump();
      await tester.pump();

      expect(find.text(AssistantCopy.tooLate), findsOneWidget);

      await tester.pump(AssistantUndoBanner.outcomeLinger);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  });

  // ------------------------------------------------------- the note's mark

  group("the note's mark", () {
    Widget mark(AssistantController controller) => Scaffold(
          body: AssistantNoteMark(assistant: controller, noteId: note),
        );

    testWidgets('nothing on a note nobody addressed to the assistant',
        (tester) async {
      final controller = await ready();
      await pumpScreen(tester, mark(controller));

      expect(find.text(AssistantCopy.sentMark), findsNothing);
      expect(find.text(AssistantCopy.failedMark), findsNothing);

      controller.dispose();
    });

    testWidgets('sent: the green mark', (tester) async {
      seedOutbox(<Map<String, Object?>>[entry(status: 'sent')]);
      final controller = await ready();
      await pumpScreen(tester, mark(controller));

      expect(find.text(AssistantCopy.sentMark), findsOneWidget);

      controller.dispose();
    });

    testWidgets('failed: the amber line, and tapping it tries again',
        (tester) async {
      seedOutbox(
        <Map<String, Object?>>[entry(status: 'failed', failure: 'gaveUp')],
      );
      final controller = await ready();
      await pumpScreen(tester, mark(controller));

      expect(find.text(AssistantCopy.failedMark), findsOneWidget);
      expect(controller.failureMessageFor(note), isNotNull);

      await tester.tap(find.text(AssistantCopy.failedMark));
      await tester.pump();
      await tester.pump();

      expect(controller.statusFor(note), isNot(AssistantSendStatus.failed));

      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // ----------------------------------------------------- the settings row

  group('the row in Recorder settings', () {
    testWidgets('says Not set up, then On', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final controller = build();
      await controller.initialise();

      await pumpScreen(
        tester,
        SettingsView(
          controller: harness.controller,
          assistant: controller,
          onBack: () {},
          onOpenInstinct: () {},
        ),
      );
      await tester.scrollUntilVisible(find.text(AssistantCopy.title), 120);

      expect(find.text(AssistantCopy.title), findsOneWidget);
      expect(find.text(AssistantCopy.rowNotSetUp), findsOneWidget);

      await controller.saveAccount(
        address: fakes.testAccount.address,
        password: fakes.testAccount.password,
      );
      await controller.setEnabled(true);
      await tester.pump();

      expect(find.text(AssistantCopy.rowOn), findsOneWidget);

      controller.dispose();
    });

    testWidgets('no row at all on a build without the feature', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(
        tester,
        SettingsView(controller: harness.controller, onBack: () {}),
      );

      expect(find.text(AssistantCopy.title), findsNothing);
    });
  });

  // ------------------------------------------------------ on a real note

  group('on the note screen', () {
    final at = DateTime(2026, 9, 18, 9, 14);
    final now = DateTime(2026, 9, 18, 15);

    Transcript said(String text) => Transcript(
          languageCode: 'en',
          modelId: SpeechModels.indicConformerHindiInt8.id,
          createdAt: at,
          audioDuration: const Duration(seconds: 20),
          segments: <TranscriptSegment>[
            TranscriptSegment(
              start: Duration.zero,
              end: const Duration(seconds: 20),
              text: text,
            ),
          ],
        );

    /// One saved note, one outbox entry for it, and the note screen open.
    Future<AssistantController> openNote(
      WidgetTester tester, {
      String? status,
      String? failure,
    }) async {
      final harness = ViewHarness(clock: () => now);
      addTearDown(harness.dispose);
      await harness.controller.initialise();
      final path = await harness.seedRecording(
        at: at,
        length: const Duration(seconds: 20),
      );
      await TranscriptStore(fileStore: harness.fileStore)
          .save(path, said('Instinct, $instruction'));
      await harness.controller.refreshLibrary();
      final info =
          harness.controller.recordings.firstWhere((r) => r.path == path);

      if (status != null) {
        seedOutbox(<Map<String, Object?>>[
          entry(noteId: path, status: status, failure: failure),
        ]);
      }
      final controller = await ready();

      await pumpScreen(
        tester,
        NoteView(
          controller: harness.controller,
          assistant: controller,
          recording: info,
          now: now,
        ),
      );
      await flush(tester);
      return controller;
    }

    testWidgets('a sent note is marked, and the menu does not offer to resend',
        (tester) async {
      final controller = await openNote(tester, status: 'sent');

      expect(find.text(AssistantCopy.sentMark), findsOneWidget);
      // Every word that was said is still on the screen.
      expect(find.textContaining('Instinct,'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      expect(find.text(AssistantCopy.sendAgain), findsNothing);

      controller.dispose();
    });

    testWidgets('a failed note says so, and Send again is in the menu',
        (tester) async {
      final controller =
          await openNote(tester, status: 'failed', failure: 'gaveUp');

      expect(find.text(AssistantCopy.failedMark), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      expect(find.text(AssistantCopy.sendAgain), findsOneWidget);
      await tester.tap(find.text(AssistantCopy.sendAgain));
      await tester.pumpAndSettle();

      expect(
        controller.statusFor(controller.recentSends().single.noteId),
        isNot(AssistantSendStatus.failed),
      );

      controller.dispose();
    });

    testWidgets('an ordinary note is marked in no way at all', (tester) async {
      final controller = await openNote(tester);

      expect(find.text(AssistantCopy.sentMark), findsNothing);
      expect(find.text(AssistantCopy.failedMark), findsNothing);

      controller.dispose();
    });

    testWidgets('the notes list quotes the instruction without the wake '
        'phrase', (tester) async {
      final harness = ViewHarness(clock: () => now);
      addTearDown(harness.dispose);
      await harness.controller.initialise();
      final path = await harness.seedRecording(
        at: at,
        length: const Duration(seconds: 20),
      );
      await TranscriptStore(fileStore: harness.fileStore)
          .save(path, said('Instinct, $instruction'));
      await harness.controller.refreshLibrary();
      final controller = await ready();

      await pumpScreen(
        tester,
        AllNotesView(
          controller: harness.controller,
          assistant: controller,
          onOpen: (_) {},
          now: now,
        ),
      );
      await flush(tester);

      expect(find.text(instruction), findsOneWidget);
      expect(find.text('Instinct, $instruction'), findsNothing);

      controller.dispose();
    });
  });
}
