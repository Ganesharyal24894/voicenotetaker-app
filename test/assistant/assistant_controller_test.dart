import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/assistant_controller.dart';
import 'package:voicenotetaker_app/drivers/email_sender.dart';
import 'package:voicenotetaker_app/drivers/haptics.dart';
import 'package:voicenotetaker_app/drivers/network_status.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_send.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_settings.dart';
import 'package:voicenotetaker_app/services/assistant/assistant_settings_store.dart';
import 'package:voicenotetaker_app/view/assistant/assistant_failure_copy.dart';

import 'assistant_fakes.dart';

/// The controller is the whole surface the UI gets. These tests are written
/// the way a screen would use it.
///
/// The undo window is shortened to a few milliseconds rather than faked,
/// because the controller's timers are real ones and the point of several of
/// these tests is that the timer fires without anybody pumping.
void main() {
  late MemoryFileStore files;
  late RecordingEmailSender sender;
  late RecordingSecretStore secrets;
  late FakeNetwork network;
  late FakeHaptics haptics;

  const undoWindow = Duration(milliseconds: 20);
  const policy = OutboxPolicy(
    undoWindow: undoWindow,
    backoff: <Duration>[Duration(milliseconds: 20)],
  );
  const directory = '/support';
  const settingsPath = '$directory/assistant-settings.json';
  const outboxPath = '$directory/assistant-outbox.json';
  const note = '/recordings/2026-09-18T14-32-00.wav';
  final spokenAt = DateTime(2026, 9, 18, 14, 32);

  AssistantController makeController({bool withHaptics = true}) =>
      AssistantController(
        fileStore: files,
        directory: directory,
        sender: sender,
        secrets: secrets,
        network: network,
        haptics: withHaptics ? haptics : null,
        policy: policy,
      );

  /// A controller that is on, set up, and ready.
  Future<AssistantController> readyController({bool withHaptics = true}) async {
    final controller = makeController(withHaptics: withHaptics);
    await controller.initialise();
    await controller.saveAccount(
      address: testAccount.address,
      password: testAccount.password,
    );
    await controller.setEnabled(true);
    return controller;
  }

  /// Waits for the undo window and the send behind it.
  Future<void> settle() async {
    await Future<void>.delayed(undoWindow * 3);
    await pumpEventQueue();
  }

  setUp(() {
    files = MemoryFileStore();
    sender = RecordingEmailSender();
    secrets = RecordingSecretStore();
    network = FakeNetwork();
    haptics = FakeHaptics();
  });

  tearDown(() async => network.close());

  group('off by default', () {
    test('a fresh install is off, with no account', () async {
      final controller = makeController();
      await controller.initialise();

      expect(controller.enabled, isFalse);
      expect(controller.hasAccount, isFalse);
      expect(controller.senderAddress, isNull);
      expect(controller.isLoaded, isTrue);
      controller.dispose();
    });

    test('a wake phrase in a note does nothing while it is off', () async {
      final controller = makeController();
      await controller.initialise();
      await controller.saveAccount(
        address: testAccount.address,
        password: testAccount.password,
      );

      final entry = await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(entry, isNull);
      expect(sender.sendCount, 0);
      expect(controller.statusFor(note), AssistantSendStatus.notSent);
      controller.dispose();
    });

    test('on but with no account sends nothing, and says so', () async {
      final controller = makeController();
      await controller.initialise();
      await controller.setEnabled(true);

      final entry = await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(entry, isNull);
      expect(sender.sendCount, 0);
      expect(controller.needsSetup, isTrue);
      controller.dispose();
    });

    test('the defaults the setup screen prefills', () async {
      expect(AssistantController.defaultAssistantAddress, contains('@'));
      expect(AssistantController.defaultSenderAddress, contains('@'));
      expect(AssistantController.defaultWakePhrase, isNotEmpty);
      expect(AssistantController.defaultSmtpHost, 'smtp.gmail.com');
      expect(AssistantController.defaultSmtpPort, 465);
    });
  });

  group('off means inert', () {
    /// A phone that has been set up and then switched off: an account in the
    /// keystore, a settings file that says off.
    Future<void> setUpThenSwitchOff() async {
      final first = await readyController();
      await first.setEnabled(false);
      first.dispose();
      files.reads.clear();
      secrets.forgetCalls();
    }

    test('a launch with the feature off reads the settings file and nothing '
        'else', () async {
      await setUpThenSwitchOff();

      final controller = makeController();
      await controller.initialise();
      await pumpEventQueue();

      // THE KEYSTORE IS NOT OPENED.
      expect(secrets.wasTouched, isFalse);
      // NOR IS THE OUTBOX FILE - only the settings, which is how the switch
      // was known to be off in the first place.
      expect(files.reads, isNotEmpty);
      expect(files.reads, everyElement(settingsPath));
      // NO CONNECTIVITY SUBSCRIPTION AND NO TIMER.
      expect(network.isWatched, isFalse);
      expect(controller.enabled, isFalse);
      expect(controller.isLoaded, isTrue);
      expect(controller.isReady, isFalse);
      controller.dispose();
    });

    test('a fresh install, which is also off, is the same', () async {
      final controller = makeController();
      await controller.initialise();
      await pumpEventQueue();

      expect(secrets.wasTouched, isFalse);
      expect(files.reads, everyElement(settingsPath));
      expect(network.isWatched, isFalse);
      controller.dispose();
    });

    test('prepare tells Off apart from Not set up, and starts nothing',
        () async {
      await setUpThenSwitchOff();
      final controller = makeController();
      await controller.initialise();
      expect(controller.hasAccount, isFalse, reason: 'nothing read yet');

      await controller.prepare();

      expect(controller.hasAccount, isTrue);
      expect(controller.isReady, isTrue);
      expect(controller.enabled, isFalse);
      // Looking at a feature that is off is not turning it on.
      expect(network.isWatched, isFalse);
      expect(sender.sendCount, 0);
      controller.dispose();
    });

    test('two screens asking at once open the keystore once', () async {
      await setUpThenSwitchOff();
      final controller = makeController();
      await controller.initialise();

      await Future.wait(<Future<void>>[
        controller.prepare(),
        controller.prepare(),
      ]);

      expect(secrets.reads, hasLength(1));
      controller.dispose();
    });

    test('turning it on later does the work the off launch skipped, and the '
        'next note goes', () async {
      await setUpThenSwitchOff();
      final controller = makeController();
      await controller.initialise();

      await controller.setEnabled(true);

      expect(controller.hasAccount, isTrue);
      expect(controller.isReady, isTrue);
      expect(network.isWatched, isTrue);

      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(sender.sendCount, 1);
      expect(controller.statusFor(note), AssistantSendStatus.sent);
      controller.dispose();
    });

    test('turning it off leaves no live connectivity subscription', () async {
      final controller = await readyController();
      expect(network.isWatched, isTrue);

      await controller.setEnabled(false);

      expect(network.isWatched, isFalse);
      controller.dispose();
    });

    test('a queued instruction is kept when the switch goes off, is not sent, '
        'and goes when it comes back on', () async {
      network.go(NetworkKind.none);
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();
      expect(controller.statusFor(note), AssistantSendStatus.queued);

      await controller.setEnabled(false);
      // The connection comes back while the feature is off: nothing goes.
      network.go(NetworkKind.unmetered);
      await settle();

      expect(sender.sendCount, 0);
      // NOTHING IS DROPPED: it is still on disk, word for word.
      expect(files.textOf(outboxPath), contains('remind me at six'));

      await controller.setEnabled(true);
      await settle();

      expect(sender.sendCount, 1);
      expect(controller.statusFor(note), AssistantSendStatus.sent);
      controller.dispose();
    });

    test('forgetEverything leaves nothing running either', () async {
      final controller = await readyController();
      await controller.forgetEverything();

      expect(network.isWatched, isFalse);
      expect(controller.enabled, isFalse);
      controller.dispose();
    });

    test('a note offered while it is off still touches no keystore', () async {
      await setUpThenSwitchOff();
      final controller = makeController();

      final entry = await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(entry, isNull);
      expect(secrets.wasTouched, isFalse);
      expect(files.reads, everyElement(settingsPath));
      expect(sender.sendCount, 0);
      controller.dispose();
    });
  });

  group('a note that is an instruction', () {
    test('is queued, buzzes once, and goes when the undo window closes',
        () async {
      final controller = await readyController();

      final entry = await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me to call the bank at six',
        spokenAt: spokenAt,
      );

      expect(entry, isNotNull);
      expect(controller.statusFor(note), AssistantSendStatus.pendingUndo);
      expect(haptics.buzzes, <BuzzPattern>[BuzzPattern.confirm]);
      expect(sender.sendCount, 0);

      await settle();

      expect(sender.sendCount, 1);
      expect(sender.sent.single.body, 'remind me to call the bank at six');
      expect(controller.statusFor(note), AssistantSendStatus.sent);
      controller.dispose();
    });

    test('the wake phrase is stripped from what is sent', () async {
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'इंस्टिंक्ट, मुझे छह बजे याद दिलाना',
        spokenAt: spokenAt,
      );
      await settle();

      expect(sender.sent.single.body, 'मुझे छह बजे याद दिलाना');
      controller.dispose();
    });

    test('a note without the wake phrase is left alone', () async {
      final controller = await readyController();

      final entry = await controller.noteTranscribed(
        noteId: note,
        transcript: 'in six minutes I need to leave for the airport',
        spokenAt: spokenAt,
      );
      await settle();

      expect(entry, isNull);
      expect(sender.sendCount, 0);
      controller.dispose();
    });

    test('the wake phrase with nothing after it sends nothing', () async {
      final controller = await readyController();

      final entry = await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct.',
        spokenAt: spokenAt,
      );
      await settle();

      expect(entry, isNull);
      expect(sender.sendCount, 0);
      controller.dispose();
    });

    test('offering the same note twice sends once', () async {
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();
      final second = await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(second, isNull);
      expect(sender.sendCount, 1);
      controller.dispose();
    });

    test('notifies its listeners when something changes', () async {
      final controller = await readyController();
      var notices = 0;
      controller.addListener(() => notices++);

      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(notices, greaterThan(1));
      controller.dispose();
    });

    test('with no way to vibrate it still queues', () async {
      final controller = await readyController(withHaptics: false);

      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(controller.canVibrate, isFalse);
      expect(sender.sendCount, 1);
      controller.dispose();
    });
  });

  group('undo', () {
    test('stops the send, and the status goes back to notSent', () async {
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );

      expect(await controller.undo(note), isTrue);
      await settle();

      expect(sender.sendCount, 0);
      expect(controller.statusFor(note), AssistantSendStatus.notSent);
      controller.dispose();
    });

    test('undoRemaining counts down and reaches zero', () async {
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );

      expect(controller.undoRemaining(note), greaterThan(Duration.zero));
      expect(
        controller.undoRemaining(note),
        lessThanOrEqualTo(controller.undoWindow),
      );

      await settle();
      expect(controller.undoRemaining(note), Duration.zero);
      controller.dispose();
    });

    test('undoRemaining is zero for a note with nothing to undo', () async {
      final controller = await readyController();

      expect(controller.undoRemaining('/recordings/other.wav'), Duration.zero);
      controller.dispose();
    });

    test('undo after it has gone is refused, not pretended', () async {
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(await controller.undo(note), isFalse);
      expect(controller.statusFor(note), AssistantSendStatus.sent);
      controller.dispose();
    });
  });

  group('failure and retry', () {
    test('a refused password leaves a failure with a sentence to show',
        () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.signIn),
      ]);
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(controller.statusFor(note), AssistantSendStatus.failed);
      expect(controller.entryFor(note)!.failure, AssistantFailure.signIn);
      expect(controller.failureFor(note)?.message, isNotEmpty);
      controller.dispose();
    });

    test('retry sends it again', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.signIn),
      ]);
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      sender.willReturn(const <EmailResult>[EmailResult.sent()]);
      expect(await controller.retry(note), isTrue);
      await settle();

      expect(controller.statusFor(note), AssistantSendStatus.sent);
      expect(controller.failureFor(note), isNull);
      controller.dispose();
    });

    test('retry on a note with nothing to retry is refused', () async {
      final controller = await readyController();

      expect(await controller.retry('/recordings/other.wav'), isFalse);
      controller.dispose();
    });

    test('offline it waits, and goes when the connection returns', () async {
      network.go(NetworkKind.none);
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      expect(sender.sendCount, 0);
      expect(controller.statusFor(note), AssistantSendStatus.queued);
      expect(controller.failureFor(note)?.message, isNotEmpty);

      network.go(NetworkKind.unmetered);
      await settle();

      expect(sender.sendCount, 1);
      expect(controller.statusFor(note), AssistantSendStatus.sent);
      controller.dispose();
    });
  });

  group('setup', () {
    test('the account goes to the keystore and the password has no getter',
        () async {
      final controller = makeController();
      await controller.initialise();

      expect(
        await controller.saveAccount(
          address: testAccount.address,
          password: testAccount.password,
        ),
        isTrue,
      );

      expect(controller.hasAccount, isTrue);
      expect(controller.senderAddress, testAccount.address);
      expect(secrets.values.keys, hasLength(1));
      // Nothing about the account is in the settings FILE.
      final settings =
          files.textOf('$directory/${AssistantSettingsStore.fileName}') ?? '';
      expect(settings, isNot(contains(testAccount.password)));
      expect(settings, isNot(contains(testAccount.address)));
      controller.dispose();
    });

    test('an incomplete account is refused', () async {
      final controller = makeController();
      await controller.initialise();

      expect(
        await controller.saveAccount(address: 'not-an-address', password: 'x'),
        isFalse,
      );
      expect(
        await controller.saveAccount(address: 'a@b.com', password: ''),
        isFalse,
      );
      expect(controller.hasAccount, isFalse);
      controller.dispose();
    });

    test('clearing the account leaves nothing behind', () async {
      final controller = await readyController();
      await controller.clearAccount();

      expect(controller.hasAccount, isFalse);
      expect(secrets.values, isEmpty);
      controller.dispose();
    });

    test('settings survive a restart; the switch does not turn itself on',
        () async {
      final first = await readyController();
      await first.setAssistantAddress('someone@else.com');
      await first.setWakePhrase('Hey Buddy');
      first.dispose();

      final second = makeController();
      await second.initialise();

      expect(second.enabled, isTrue);
      expect(second.assistantAddress, 'someone@else.com');
      expect(second.wakePhrase, 'Hey Buddy');
      expect(second.hasAccount, isTrue);
      second.dispose();
    });

    test('a wake phrase that is too short is refused', () async {
      final controller = await readyController();

      expect(await controller.setWakePhrase('  '), isFalse);
      expect(await controller.setWakePhrase('a'), isFalse);
      expect(controller.wakePhrase, AssistantController.defaultWakePhrase);
      controller.dispose();
    });

    test('a changed wake phrase is what notes are matched against', () async {
      final controller = await readyController();
      await controller.setWakePhrase('Hey Buddy');

      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();
      expect(sender.sendCount, 0);

      await controller.noteTranscribed(
        noteId: '/recordings/second.wav',
        transcript: 'hey buddy, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();
      expect(sender.sent.single.body, 'remind me at six');
      controller.dispose();
    });

    test('an assistant address that is not an address is refused', () async {
      final controller = await readyController();

      expect(await controller.setAssistantAddress('nonsense'), isFalse);
      expect(
        controller.assistantAddress,
        AssistantSettings.defaultAssistantAddress,
      );
      controller.dispose();
    });

    test('forgetEverything turns it off and empties the outbox', () async {
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      await settle();

      await controller.forgetEverything();

      expect(controller.enabled, isFalse);
      expect(controller.hasAccount, isFalse);
      expect(controller.recentSends(), isEmpty);
      expect(controller.statusFor(note), AssistantSendStatus.notSent);
      controller.dispose();
    });
  });

  group('the test email', () {
    test('goes straight out and leaves no outbox entry', () async {
      final controller = await readyController();

      expect(await controller.sendTestEmail(), isTrue);

      expect(controller.testState, AssistantTestState.sent);
      expect(sender.sendCount, 1);
      expect(sender.sent.single.to, AssistantSettings.defaultAssistantAddress);
      expect(sender.sent.single.body, AssistantController.testInstruction);
      expect(controller.recentSends(), isEmpty);
      controller.dispose();
    });

    test('with no account it fails without touching the network', () async {
      final controller = makeController();
      await controller.initialise();

      expect(await controller.sendTestEmail(), isFalse);
      expect(controller.testState, AssistantTestState.failed);
      expect(controller.testFailure, AssistantFailure.notConfigured);
      expect(sender.sendCount, 0);
      controller.dispose();
    });

    test('offline it says so rather than trying', () async {
      network.go(NetworkKind.none);
      final controller = await readyController();

      expect(await controller.sendTestEmail(), isFalse);
      expect(controller.testFailure, AssistantFailure.network);
      expect(sender.sendCount, 0);
      controller.dispose();
    });

    test('a refused password comes back as a sign-in failure', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.signIn),
      ]);
      final controller = await readyController();

      expect(await controller.sendTestEmail(), isFalse);
      expect(controller.testFailure, AssistantFailure.signIn);
      controller.dispose();
    });

    test('saving the account again resets the test state', () async {
      final controller = await readyController();
      await controller.sendTestEmail();
      expect(controller.testState, AssistantTestState.sent);

      await controller.saveAccount(
        address: testAccount.address,
        password: 'another-app-password',
      );

      expect(controller.testState, AssistantTestState.idle);
      controller.dispose();
    });

    test('it does not work as a way to send arbitrary text', () async {
      // There is no parameter: the test email says one fixed thing.
      final controller = await readyController();
      await controller.sendTestEmail();

      expect(sender.sent.single.body, AssistantController.testInstruction);
      controller.dispose();
    });
  });

  group('what the UI reads', () {
    test('titleFor strips the wake phrase but the raw transcript is untouched',
        () async {
      final controller = await readyController();
      const raw = 'Instinct, remind me at six';

      expect(controller.titleFor(raw), 'remind me at six');
      expect(controller.titleFor('just an ordinary note'),
          'just an ordinary note');
      // The caller still holds every word that was said.
      expect(raw, 'Instinct, remind me at six');
      controller.dispose();
    });

    test('matchIn gives the spoken phrase and the instruction', () async {
      final controller = await readyController();
      final match = controller.matchIn('Instinct, remind me at six')!;

      expect(match.spoken, 'Instinct,');
      expect(match.instruction, 'remind me at six');
      expect(controller.matchIn('nothing here'), isNull);
      controller.dispose();
    });

    test('recentSends is newest first and includes failures', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.sent(),
        EmailResult.failed(EmailFailure.signIn),
      ]);
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: '/recordings/one.wav',
        transcript: 'Instinct, first',
        spokenAt: spokenAt,
      );
      await settle();
      await controller.noteTranscribed(
        noteId: '/recordings/two.wav',
        transcript: 'Instinct, second',
        spokenAt: spokenAt,
      );
      await settle();

      final recent = controller.recentSends();
      expect(recent, hasLength(2));
      expect(recent.first.noteId, '/recordings/two.wav');
      expect(recent.first.status, AssistantSendStatus.failed);
      expect(recent.last.status, AssistantSendStatus.sent);
      controller.dispose();
    });

    test('hasPending is true only while something is waiting', () async {
      final controller = await readyController();
      expect(controller.hasPending, isFalse);

      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      expect(controller.hasPending, isTrue);

      await settle();
      expect(controller.hasPending, isFalse);
      controller.dispose();
    });

    test('a queued note survives the app being killed and goes on the next run',
        () async {
      final first = await readyController();
      await first.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      // Killed inside the undo window.
      first.dispose();
      expect(sender.sendCount, 0);

      final second = makeController();
      await second.initialise();
      await settle();

      expect(sender.sendCount, 1);
      expect(second.statusFor(note), AssistantSendStatus.sent);
      second.dispose();
    });

    test('disposing twice, and after a send, is harmless', () async {
      final controller = await readyController();
      await controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, remind me at six',
        spokenAt: spokenAt,
      );
      controller.dispose();
      controller.dispose();
      await settle();
    });
  });
}
