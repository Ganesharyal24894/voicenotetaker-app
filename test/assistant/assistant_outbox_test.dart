import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/email_sender.dart';
import 'package:voicenotetaker_app/drivers/network_status.dart';
import 'package:voicenotetaker_app/drivers/secret_store.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_message.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_send.dart';
import 'package:voicenotetaker_app/services/assistant/assistant_account_store.dart';
import 'package:voicenotetaker_app/services/assistant/assistant_outbox.dart';

import 'assistant_fakes.dart';

/// The outbox is the app's only outbound path. These tests are written from
/// the promises in its class comment: nothing during the undo window, one note
/// one send, it survives being killed, it gives up honestly, and offline costs
/// nothing.
void main() {
  late MemoryFileStore files;
  late RecordingEmailSender sender;
  late MemorySecretStore secrets;
  late FakeNetwork network;
  late FakeClock clock;

  const policy = OutboxPolicy();
  const directory = '/support';
  const note = '/recordings/2026-09-18T14-32-00.wav';
  final spokenAt = DateTime(2026, 9, 18, 14, 32);

  AssistantOutbox makeOutbox({
    String assistantAddress = testAssistant,
    OutboxPolicy withPolicy = policy,
    int historyLimit = AssistantOutbox.defaultHistoryLimit,
  }) =>
      AssistantOutbox(
        fileStore: files,
        directory: directory,
        sender: sender,
        accounts: AssistantAccountStore(secrets: secrets),
        assistantAddress: () async => assistantAddress,
        network: network,
        policy: withPolicy,
        clock: clock.call,
        historyLimit: historyLimit,
      );

  /// Queues one instruction and lets its undo window close.
  Future<void> queueAndRelease(
    AssistantOutbox outbox, {
    String noteId = note,
    String instruction = 'remind me at six',
  }) async {
    await outbox.enqueue(
      noteId: noteId,
      instruction: instruction,
      spokenAt: spokenAt,
    );
    clock.advance(policy.undoWindow);
    await outbox.pump();
  }

  setUp(() async {
    files = MemoryFileStore();
    sender = RecordingEmailSender();
    secrets = MemorySecretStore();
    network = FakeNetwork();
    clock = FakeClock();
    await AssistantAccountStore(secrets: secrets).save(testAccount);
  });

  tearDown(() async => network.close());

  group('the undo window', () {
    test('a new entry is pendingUndo and nothing is sent', () async {
      final outbox = makeOutbox();
      final entry = await outbox.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );

      expect(entry, isNotNull);
      expect(entry!.status, AssistantSendStatus.pendingUndo);
      expect(entry.readyAt, clock.now.add(policy.undoWindow));
      expect(sender.sendCount, 0);
    });

    test('pumping inside the window sends nothing', () async {
      final outbox = makeOutbox();
      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );

      clock.advance(policy.undoWindow - const Duration(milliseconds: 1));
      await outbox.pump();

      expect(sender.sendCount, 0);
      expect(outbox.statusFor(note), AssistantSendStatus.pendingUndo);
    });

    test('the window closing releases the entry and it goes', () async {
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(sender.sendCount, 1);
      expect(outbox.statusFor(note), AssistantSendStatus.sent);
      expect(outbox.entryFor(note)!.sentAt, clock.now);
    });

    test('undo inside the window removes the entry for good', () async {
      final outbox = makeOutbox();
      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );

      expect(await outbox.undo(note), isTrue);
      expect(outbox.statusFor(note), AssistantSendStatus.notSent);

      clock.advance(const Duration(hours: 1));
      await outbox.pump();

      expect(sender.sendCount, 0);
    });

    test('undo after the window is refused and changes nothing', () async {
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(await outbox.undo(note), isFalse);
      expect(outbox.statusFor(note), AssistantSendStatus.sent);
    });

    test('undo for a note nobody queued is refused', () async {
      final outbox = makeOutbox();
      await outbox.load();

      expect(await outbox.undo('/recordings/nothing.wav'), isFalse);
    });

    test('an undone note can be queued again - undo is not a block', () async {
      final outbox = makeOutbox();
      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );
      await outbox.undo(note);

      final again = await outbox.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );

      expect(again, isNotNull);
    });
  });

  group('one note, one send', () {
    test('a second enqueue of the same note is refused', () async {
      final outbox = makeOutbox();
      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );

      final second = await outbox.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );

      expect(second, isNull);
      expect(outbox.entries, hasLength(1));
    });

    test('re-transcribing a note that already went sends nothing', () async {
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      final again = await outbox.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );
      clock.advance(const Duration(minutes: 5));
      await outbox.pump();

      expect(again, isNull);
      expect(sender.sendCount, 1);
    });

    test('a failed note is remembered too, so it is not re-queued', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.signIn),
      ]);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(outbox.statusFor(note), AssistantSendStatus.failed);
      expect(
        await outbox.enqueue(
          noteId: note,
          instruction: 'remind me at six',
          spokenAt: spokenAt,
        ),
        isNull,
      );
    });

    test('an empty instruction is not queued', () async {
      final outbox = makeOutbox();

      expect(
        await outbox.enqueue(
          noteId: note,
          instruction: '   ',
          spokenAt: spokenAt,
        ),
        isNull,
      );
      expect(outbox.entries, isEmpty);
    });

    test('two different notes are two sends, oldest first', () async {
      final outbox = makeOutbox();
      await outbox.enqueue(
        noteId: '/recordings/a.wav',
        instruction: 'first',
        spokenAt: spokenAt,
      );
      await outbox.enqueue(
        noteId: '/recordings/b.wav',
        instruction: 'second',
        spokenAt: spokenAt,
      );
      clock.advance(policy.undoWindow);
      await outbox.pump();

      expect(sender.sent.map((message) => message.body), <String>[
        'first',
        'second',
      ]);
    });
  });

  group('what actually goes out', () {
    test('the body is the instruction and nothing else', () async {
      final outbox = makeOutbox();
      await queueAndRelease(
        outbox,
        instruction: 'remind me to call the bank at six',
      );

      final message = sender.sent.single;
      expect(message.body, 'remind me to call the bank at six');
      expect(message.to, testAssistant);
      expect(message.from, testAccount.address);
      expect(message.subject, AssistantMessage.subjectFor(spokenAt));
      // Not the note id, not the file, not the wake phrase.
      expect(message.body, isNot(contains(note)));
      expect(message.subject, isNot(contains(note)));
    });

    test('the account the sender is handed is the stored one', () async {
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(sender.accounts.single.address, testAccount.address);
      expect(sender.accounts.single.password, testAccount.password);
    });

    test('the address in force when it goes is the one used', () async {
      var address = 'old@example.com';
      final outbox = AssistantOutbox(
        fileStore: files,
        directory: directory,
        sender: sender,
        accounts: AssistantAccountStore(secrets: secrets),
        assistantAddress: () async => address,
        network: network,
        policy: policy,
        clock: clock.call,
      );
      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me',
        spokenAt: spokenAt,
      );
      address = testAssistant;
      clock.advance(policy.undoWindow);
      await outbox.pump();

      expect(sender.sent.single.to, testAssistant);
    });
  });

  group('failure', () {
    test('a refused password fails at once, with no retry', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.signIn),
      ]);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      final entry = outbox.entryFor(note)!;
      expect(entry.status, AssistantSendStatus.failed);
      expect(entry.failure, AssistantFailure.signIn);
      expect(entry.attempts, 1);

      clock.advance(const Duration(hours: 2));
      await outbox.pump();
      expect(sender.sendCount, 1);
    });

    test('a refused recipient fails at once', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.recipient),
      ]);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(outbox.entryFor(note)!.failure, AssistantFailure.address);
      expect(outbox.statusFor(note), AssistantSendStatus.failed);
    });

    test('an assistant address that is not an address fails at once', () async {
      final outbox = makeOutbox(assistantAddress: '   ');
      await queueAndRelease(outbox);

      expect(sender.sendCount, 0);
      expect(outbox.entryFor(note)!.failure, AssistantFailure.address);
    });

    test('no account: the entry fails and says so', () async {
      await AssistantAccountStore(secrets: secrets).clear();
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(sender.sendCount, 0);
      expect(outbox.entryFor(note)!.failure, AssistantFailure.notConfigured);
      expect(outbox.statusFor(note), AssistantSendStatus.failed);
    });

    test('a server failure is retried on the backoff, then given up', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.server),
      ]);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(sender.sendCount, 1);
      expect(outbox.statusFor(note), AssistantSendStatus.queued);
      expect(outbox.entryFor(note)!.failure, AssistantFailure.server);

      for (var attempt = 1; attempt <= policy.backoff.length; attempt++) {
        final wait = policy.waitAfter(attempt)!;
        // Just short of the backoff: nothing happens.
        clock.advance(wait - const Duration(seconds: 1));
        await outbox.pump();
        expect(sender.sendCount, attempt, reason: 'too early at $attempt');

        clock.advance(const Duration(seconds: 1));
        await outbox.pump();
        expect(sender.sendCount, attempt + 1, reason: 'missed attempt $attempt');
      }

      final entry = outbox.entryFor(note)!;
      expect(entry.status, AssistantSendStatus.failed);
      expect(entry.failure, AssistantFailure.gaveUp);
      expect(entry.attempts, policy.maxAttempts);

      // And it stays given up.
      clock.advance(const Duration(days: 1));
      await outbox.pump();
      expect(sender.sendCount, policy.maxAttempts);
    });

    test('a failure that then succeeds is sent once', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.connection),
        EmailResult.sent(),
      ]);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(outbox.statusFor(note), AssistantSendStatus.queued);

      clock.advance(policy.waitAfter(1)!);
      await outbox.pump();

      expect(sender.sendCount, 2);
      expect(outbox.statusFor(note), AssistantSendStatus.sent);
    });

    test('retry puts a failed entry back at the top of the ladder', () async {
      sender.willReturn(const <EmailResult>[
        EmailResult.failed(EmailFailure.signIn),
      ]);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);
      expect(outbox.statusFor(note), AssistantSendStatus.failed);

      sender.willReturn(const <EmailResult>[EmailResult.sent()]);
      expect(await outbox.retry(note), isTrue);
      expect(outbox.entryFor(note)!.attempts, 0);

      await outbox.pump();
      expect(outbox.statusFor(note), AssistantSendStatus.sent);
    });

    test('retry does nothing for an entry that is not failed', () async {
      final outbox = makeOutbox();
      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me',
        spokenAt: spokenAt,
      );

      expect(await outbox.retry(note), isFalse);
      expect(await outbox.retry('/recordings/nothing.wav'), isFalse);
    });
  });

  group('offline', () {
    test('with no connection nothing is sent and no attempt is spent', () async {
      network.go(NetworkKind.none);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      final entry = outbox.entryFor(note)!;
      expect(sender.sendCount, 0);
      expect(entry.status, AssistantSendStatus.queued);
      expect(entry.attempts, 0);
      expect(entry.failure, AssistantFailure.network);
    });

    test('it goes the moment the connection is back', () async {
      network.go(NetworkKind.none);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);
      expect(sender.sendCount, 0);

      network.go(NetworkKind.unmetered);
      await outbox.pump();

      expect(sender.sendCount, 1);
      expect(outbox.statusFor(note), AssistantSendStatus.sent);
    });

    test('a long time offline never uses up the retry budget', () async {
      network.go(NetworkKind.none);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      for (var i = 0; i < 20; i++) {
        clock.advance(const Duration(minutes: 30));
        await outbox.pump();
      }
      expect(outbox.entryFor(note)!.attempts, 0);

      network.go(NetworkKind.metered);
      await outbox.pump();
      expect(outbox.statusFor(note), AssistantSendStatus.sent);
    });

    test('mobile data is a connection: an instruction is small', () async {
      network.go(NetworkKind.metered);
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(sender.sendCount, 1);
    });
  });

  group('surviving the app being killed', () {
    test('a queued entry is on disk and comes back', () async {
      final first = makeOutbox();
      await first.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );

      // A brand-new outbox over the same files: the app was killed.
      final second = makeOutbox();
      await second.load();

      final entry = second.entryFor(note)!;
      expect(entry.instruction, 'remind me at six');
      expect(entry.status, AssistantSendStatus.pendingUndo);
      expect(entry.spokenAt, spokenAt);
    });

    test('an undo window that expired while the app was dead still goes',
        () async {
      final first = makeOutbox();
      await first.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );

      clock.advance(const Duration(hours: 3));
      final second = makeOutbox();
      await second.pump();

      expect(sender.sendCount, 1);
      expect(second.statusFor(note), AssistantSendStatus.sent);
    });

    test('a sent entry is not sent again after a restart', () async {
      final first = makeOutbox();
      await queueAndRelease(first);
      expect(sender.sendCount, 1);

      final second = makeOutbox();
      await second.pump();

      expect(sender.sendCount, 1);
      expect(second.statusFor(note), AssistantSendStatus.sent);
    });

    test('an entry left mid-send comes back as queued, not sending', () async {
      sender.holdOpen = true;
      final first = makeOutbox();
      // Not awaited: the send is deliberately left on the wire.
      unawaitedPump(first, clock);
      await pumpEventQueue();
      expect(first.statusFor(note), AssistantSendStatus.notSent);

      await first.enqueue(
        noteId: note,
        instruction: 'remind me at six',
        spokenAt: spokenAt,
      );
      clock.advance(policy.undoWindow);
      final running = first.pump();
      await pumpEventQueue();
      expect(first.statusFor(note), AssistantSendStatus.sending);

      // The file, as it stands with the socket still open.
      final second = makeOutbox();
      await second.load();
      expect(second.statusFor(note), AssistantSendStatus.queued);

      sender.inFlight!.complete();
      await running;
    });

    test('a damaged outbox file reads as empty rather than throwing', () async {
      await files.writeBytes(
        '$directory/${AssistantOutbox.fileName}',
        'not json at all'.codeUnits,
      );
      final outbox = makeOutbox();
      await outbox.load();

      expect(outbox.entries, isEmpty);
    });

    test('a damaged entry is dropped and the good ones survive', () async {
      final good = AssistantSend.pending(
        noteId: note,
        instruction: 'remind me',
        spokenAt: spokenAt,
        now: clock.now,
        policy: policy,
      );
      await files.writeBytes(
        '$directory/${AssistantOutbox.fileName}',
        '{"version":1,"entries":[{"noteId":""},'
                '${_json(good)}]}'
            .codeUnits,
      );
      final outbox = makeOutbox();
      await outbox.load();

      expect(outbox.entries, hasLength(1));
      expect(outbox.entries.single.noteId, note);
    });

    test('a file that cannot be written does not break the session', () async {
      files.unwritable.add('$directory/${AssistantOutbox.fileName}');
      final outbox = makeOutbox();
      await queueAndRelease(outbox);

      expect(sender.sendCount, 1);
      expect(outbox.statusFor(note), AssistantSendStatus.sent);
    });
  });

  group('housekeeping', () {
    test('nextDue is the soonest unsettled entry, null when there is none',
        () async {
      final outbox = makeOutbox();
      expect(outbox.nextDue, isNull);

      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me',
        spokenAt: spokenAt,
      );
      expect(outbox.nextDue, clock.now.add(policy.undoWindow));

      clock.advance(policy.undoWindow);
      await outbox.pump();
      expect(outbox.nextDue, isNull);
    });

    test('hasPending is true only while something is waiting', () async {
      final outbox = makeOutbox();
      expect(outbox.hasPending, isFalse);

      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me',
        spokenAt: spokenAt,
      );
      expect(outbox.hasPending, isTrue);

      clock.advance(policy.undoWindow);
      await outbox.pump();
      expect(outbox.hasPending, isFalse);
    });

    test('finished entries are trimmed to the history limit, newest kept',
        () async {
      final outbox = makeOutbox(historyLimit: 3);
      for (var i = 0; i < 6; i++) {
        await queueAndRelease(outbox, noteId: '/recordings/$i.wav');
        clock.advance(const Duration(minutes: 1));
      }

      expect(outbox.entries, hasLength(3));
      expect(
        outbox.entries.map((entry) => entry.noteId),
        <String>['/recordings/5.wav', '/recordings/4.wav', '/recordings/3.wav'],
      );
    });

    test('recent gives the newest first, capped', () async {
      final outbox = makeOutbox();
      for (var i = 0; i < 4; i++) {
        await queueAndRelease(outbox, noteId: '/recordings/$i.wav');
        clock.advance(const Duration(minutes: 1));
      }

      expect(outbox.recent(2).map((entry) => entry.noteId),
          <String>['/recordings/3.wav', '/recordings/2.wav']);
    });

    test('clear empties the outbox and the file', () async {
      final outbox = makeOutbox();
      await queueAndRelease(outbox);
      await outbox.clear();

      expect(outbox.entries, isEmpty);
      final reloaded = makeOutbox();
      await reloaded.load();
      expect(reloaded.entries, isEmpty);
    });

    test('onChanged fires on every state change', () async {
      final outbox = makeOutbox();
      var changes = 0;
      outbox.onChanged = () => changes++;

      await outbox.enqueue(
        noteId: note,
        instruction: 'remind me',
        spokenAt: spokenAt,
      );
      final afterEnqueue = changes;
      clock.advance(policy.undoWindow);
      await outbox.pump();

      expect(afterEnqueue, greaterThan(0));
      expect(changes, greaterThan(afterEnqueue));
    });

    test('statusFor is notSent for a note the outbox never saw', () async {
      final outbox = makeOutbox();
      await outbox.load();

      expect(
        outbox.statusFor('/recordings/never-spoken.wav'),
        AssistantSendStatus.notSent,
      );
    });

    test('sendOnce goes straight out, with no entry left behind', () async {
      final outbox = makeOutbox();
      await outbox.load();

      final result = await outbox.sendOnce(
        const AssistantMessage(
          from: 'giftinjsr@gmail.com',
          to: testAssistant,
          subject: 'test',
          body: 'hello',
        ),
        testAccount,
      );

      expect(result.ok, isTrue);
      expect(sender.sendCount, 1);
      expect(outbox.entries, isEmpty);
    });
  });
}

/// The saved JSON of [send], for building a file by hand.
String _json(AssistantSend send) {
  final json = send.toJson();
  final parts = json.entries.map((entry) {
    final value = entry.value;
    return value is int
        ? '"${entry.key}":$value'
        : '"${entry.key}":"$value"';
  });
  return '{${parts.join(',')}}';
}

/// Kicks a pump without waiting for it, so a test can look at the outbox while
/// a send is on the wire.
void unawaitedPump(AssistantOutbox outbox, FakeClock clock) {
  outbox.pump().ignore();
}
