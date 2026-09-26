import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_send.dart';

const OutboxPolicy _policy = OutboxPolicy();
const String _noteId = '/notes/2026-09-18-1432.wav';
const String _instruction = 'remind me to call Priya about the invoice';

final DateTime _spokenAt = DateTime(2026, 9, 18, 14, 32);
final DateTime _t0 = DateTime(2026, 9, 18, 14, 32, 10);

/// A brand-new entry, still inside its undo window.
AssistantSend _pending(DateTime now) => AssistantSend.pending(
      noteId: _noteId,
      instruction: _instruction,
      spokenAt: _spokenAt,
      now: now,
      policy: _policy,
    );

/// The same entry once the undo window has closed.
AssistantSend _queued(DateTime now) => _pending(now).release();

/// The entry as it comes back off disk, through real JSON text.
AssistantSend _roundTrip(AssistantSend send) {
  final back = AssistantSend.fromJson(jsonDecode(jsonEncode(send.toJson())));
  expect(back, isNotNull, reason: 'expected a readable entry');
  return back!;
}

void main() {
  group('OutboxPolicy', () {
    test('the defaults are five seconds of undo and five backoffs', () {
      expect(_policy.undoWindow, const Duration(seconds: 5));
      expect(_policy.backoff, <Duration>[
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 5),
      ]);
    });

    test('maxAttempts is the first go plus one per backoff', () {
      expect(_policy.maxAttempts, 6);
      expect(
        const OutboxPolicy(backoff: <Duration>[Duration(seconds: 1)])
            .maxAttempts,
        2,
      );
      expect(const OutboxPolicy(backoff: <Duration>[]).maxAttempts, 1);
    });

    test('the retry window is the whole ladder added up', () {
      expect(_policy.retryWindow, const Duration(seconds: 760));
      expect(_policy.retryWindow, const Duration(minutes: 12, seconds: 40));
      expect(const OutboxPolicy(backoff: <Duration>[]).retryWindow,
          Duration.zero);
    });

    test('waitAfter gives each rung in turn', () {
      expect(_policy.waitAfter(1), const Duration(seconds: 10));
      expect(_policy.waitAfter(2), const Duration(seconds: 30));
      expect(_policy.waitAfter(3), const Duration(minutes: 2));
      expect(_policy.waitAfter(4), const Duration(minutes: 5));
      expect(_policy.waitAfter(5), const Duration(minutes: 5));
    });

    test('waitAfter is null off either end of the ladder', () {
      expect(_policy.waitAfter(0), isNull);
      expect(_policy.waitAfter(-1), isNull);
      expect(_policy.waitAfter(-100), isNull);
      expect(_policy.waitAfter(6), isNull);
      expect(_policy.waitAfter(7), isNull);
      expect(_policy.waitAfter(1000), isNull);
    });
  });

  group('a new entry', () {
    test('opens the undo window and has sent nothing', () {
      final send = _pending(_t0);
      expect(send.status, AssistantSendStatus.pendingUndo);
      expect(send.readyAt, _t0.add(const Duration(seconds: 5)));
      expect(send.attempts, 0);
      expect(send.failure, isNull);
      expect(send.sentAt, isNull);
      expect(send.isSettled, isFalse);
    });

    test('it carries the note id, the instruction and the spoken time', () {
      final send = _pending(_t0);
      expect(send.noteId, _noteId);
      expect(send.instruction, _instruction);
      expect(send.spokenAt, _spokenAt);
    });
  });

  group('the undo window', () {
    test('is open until the moment it closes', () {
      final send = _pending(_t0);
      expect(send.undoOpen(_t0), isTrue);
      expect(send.undoOpen(_t0.add(const Duration(seconds: 4, milliseconds: 999))),
          isTrue);
    });

    test('is shut at the boundary and after it', () {
      final send = _pending(_t0);
      expect(send.undoOpen(send.readyAt), isFalse);
      expect(send.undoOpen(send.readyAt.add(const Duration(milliseconds: 1))),
          isFalse);
      expect(send.undoOpen(_t0.add(const Duration(hours: 1))), isFalse);
    });

    test('is shut once the entry has been released, whatever the clock says',
        () {
      final send = _queued(_t0);
      expect(send.undoOpen(_t0), isFalse);
      expect(send.undoOpen(_t0.subtract(const Duration(seconds: 1))), isFalse);
    });
  });

  group('when an entry is due', () {
    test('never while the undo window is the status, even long after readyAt',
        () {
      final send = _pending(_t0);
      expect(send.isDue(_t0), isFalse);
      expect(send.isDue(send.readyAt), isFalse);
      expect(send.isDue(_t0.add(const Duration(days: 1))), isFalse);
    });

    test('queued and not yet at readyAt is not due', () {
      final send = _queued(_t0);
      expect(send.isDue(_t0), isFalse);
      expect(send.isDue(send.readyAt.subtract(const Duration(milliseconds: 1))),
          isFalse);
    });

    test('queued and at or past readyAt is due', () {
      final send = _queued(_t0);
      expect(send.isDue(send.readyAt), isTrue);
      expect(send.isDue(send.readyAt.add(const Duration(minutes: 1))), isTrue);
    });

    test('a settled entry is never due', () {
      final sent = _queued(_t0).succeeded(_t0);
      final failed = _queued(_t0)
          .afterFailure(AssistantFailure.signIn, now: _t0, policy: _policy);
      expect(sent.isDue(_t0.add(const Duration(days: 1))), isFalse);
      expect(failed.isDue(_t0.add(const Duration(days: 1))), isFalse);
      expect(sent.isSettled, isTrue);
      expect(failed.isSettled, isTrue);
    });
  });

  group('release', () {
    test('queues the entry and forgets the old reason', () {
      final stale = AssistantSend(
        noteId: _noteId,
        instruction: _instruction,
        spokenAt: _spokenAt,
        status: AssistantSendStatus.pendingUndo,
        readyAt: _t0,
        attempts: 2,
        failure: AssistantFailure.network,
      );
      final released = stale.release();
      expect(released.status, AssistantSendStatus.queued);
      expect(released.failure, isNull);
      expect(released.attempts, 2);
      expect(released.readyAt, _t0);
    });
  });

  group('succeeded', () {
    test('marks it sent, counts the attempt and clears the reason', () {
      final at = _t0.add(const Duration(seconds: 30));
      final send = _queued(_t0)
          .afterFailure(AssistantFailure.network, now: _t0, policy: _policy)
          .startSending()
          .succeeded(at);
      expect(send.status, AssistantSendStatus.sent);
      expect(send.sentAt, at);
      expect(send.attempts, 2);
      expect(send.failure, isNull);
      expect(send.isSettled, isTrue);
    });

    test('a first-time success is one attempt', () {
      final send = _queued(_t0).succeeded(_t0);
      expect(send.attempts, 1);
      expect(send.sentAt, _t0);
    });
  });

  group('a retryable failure walks the ladder', () {
    test('the first failure waits ten seconds', () {
      final send = _queued(_t0)
          .afterFailure(AssistantFailure.network, now: _t0, policy: _policy);
      expect(send.status, AssistantSendStatus.queued);
      expect(send.attempts, 1);
      expect(send.readyAt, _t0.add(const Duration(seconds: 10)));
      expect(send.failure, AssistantFailure.network);
      expect(send.isSettled, isFalse);
    });

    test('the second waits thirty seconds', () {
      final first = _queued(_t0)
          .afterFailure(AssistantFailure.network, now: _t0, policy: _policy);
      final at = first.readyAt;
      final second =
          first.afterFailure(AssistantFailure.server, now: at, policy: _policy);
      expect(second.status, AssistantSendStatus.queued);
      expect(second.attempts, 2);
      expect(second.readyAt, at.add(const Duration(seconds: 30)));
      expect(second.failure, AssistantFailure.server);
    });

    test('the third waits two minutes', () {
      final at = _t0.add(const Duration(minutes: 1));
      final send = _queued(_t0)
          .copyWith(attempts: 2)
          .afterFailure(AssistantFailure.network, now: at, policy: _policy);
      expect(send.attempts, 3);
      expect(send.readyAt, at.add(const Duration(minutes: 2)));
      expect(send.status, AssistantSendStatus.queued);
    });

    test('the fourth waits five minutes', () {
      final at = _t0.add(const Duration(minutes: 3));
      final send = _queued(_t0)
          .copyWith(attempts: 3)
          .afterFailure(AssistantFailure.server, now: at, policy: _policy);
      expect(send.attempts, 4);
      expect(send.readyAt, at.add(const Duration(minutes: 5)));
      expect(send.status, AssistantSendStatus.queued);
    });

    test('the fifth waits five minutes', () {
      final at = _t0.add(const Duration(minutes: 8));
      final send = _queued(_t0)
          .copyWith(attempts: 4)
          .afterFailure(AssistantFailure.network, now: at, policy: _policy);
      expect(send.attempts, 5);
      expect(send.readyAt, at.add(const Duration(minutes: 5)));
      expect(send.status, AssistantSendStatus.queued);
    });

    test('the sixth is the end of the ladder and it gives up', () {
      final at = _t0.add(const Duration(minutes: 13));
      final send = _queued(_t0)
          .copyWith(attempts: 5)
          .afterFailure(AssistantFailure.network, now: at, policy: _policy);
      expect(send.status, AssistantSendStatus.failed);
      expect(send.attempts, 6);
      expect(send.attempts, _policy.maxAttempts);
      expect(send.failure, AssistantFailure.gaveUp);
      expect(send.isSettled, isTrue);
    });

    test('walking it end to end lands on gaveUp after maxAttempts tries', () {
      var send = _queued(_t0);
      var at = _t0;
      for (var rung = 0; rung < _policy.backoff.length + 1; rung++) {
        send =
            send.afterFailure(AssistantFailure.network, now: at, policy: _policy);
        at = send.readyAt;
      }
      expect(send.attempts, _policy.maxAttempts);
      expect(send.status, AssistantSendStatus.failed);
      expect(send.failure, AssistantFailure.gaveUp);
    });
  });

  group('a permanent failure stops at once', () {
    test('a sign-in refusal fails immediately and waits for nothing', () {
      final queued = _queued(_t0);
      final send = queued.afterFailure(AssistantFailure.signIn,
          now: _t0.add(const Duration(minutes: 1)), policy: _policy);
      expect(send.status, AssistantSendStatus.failed);
      expect(send.attempts, 1);
      expect(send.failure, AssistantFailure.signIn);
      expect(send.readyAt, queued.readyAt);
    });

    test('a refused address fails immediately', () {
      final queued = _queued(_t0);
      final send =
          queued.afterFailure(AssistantFailure.address, now: _t0, policy: _policy);
      expect(send.status, AssistantSendStatus.failed);
      expect(send.attempts, 1);
      expect(send.failure, AssistantFailure.address);
      expect(send.readyAt, queued.readyAt);
    });

    test('no account set up fails immediately', () {
      final queued = _queued(_t0);
      final send = queued.afterFailure(AssistantFailure.notConfigured,
          now: _t0, policy: _policy);
      expect(send.status, AssistantSendStatus.failed);
      expect(send.attempts, 1);
      expect(send.failure, AssistantFailure.notConfigured);
      expect(send.readyAt, queued.readyAt);
    });

    test('it did not eat a rung: a retry still starts at the first backoff',
        () {
      final at = _t0.add(const Duration(hours: 1));
      final send = _queued(_t0)
          .afterFailure(AssistantFailure.signIn, now: _t0, policy: _policy)
          .retried(at)
          .afterFailure(AssistantFailure.network, now: at, policy: _policy);
      expect(send.attempts, 1);
      expect(send.readyAt, at.add(const Duration(seconds: 10)));
      expect(send.status, AssistantSendStatus.queued);
    });
  });

  group('retried', () {
    test('starts the whole decision over', () {
      final at = _t0.add(const Duration(hours: 2));
      final send = _queued(_t0)
          .copyWith(attempts: 5)
          .afterFailure(AssistantFailure.network, now: _t0, policy: _policy)
          .retried(at);
      expect(send.status, AssistantSendStatus.queued);
      expect(send.attempts, 0);
      expect(send.readyAt, at);
      expect(send.failure, isNull);
      expect(send.isDue(at), isTrue);
    });
  });

  group('AssistantFailure', () {
    test('only a network or server problem is worth trying again', () {
      expect(AssistantFailure.network.isWorthRetrying, isTrue);
      expect(AssistantFailure.server.isWorthRetrying, isTrue);
      expect(AssistantFailure.signIn.isWorthRetrying, isFalse);
      expect(AssistantFailure.address.isWorthRetrying, isFalse);
      expect(AssistantFailure.notConfigured.isWorthRetrying, isFalse);
      expect(AssistantFailure.gaveUp.isWorthRetrying, isFalse);
      expect(
        <AssistantFailure>[
          for (final value in AssistantFailure.values)
            if (value.isWorthRetrying) value,
        ],
        <AssistantFailure>[AssistantFailure.network, AssistantFailure.server],
      );
    });
  });

  group('JSON', () {
    test('a pending entry round-trips', () {
      final send = _pending(_t0);
      final back = _roundTrip(send);
      expect(back.noteId, send.noteId);
      expect(back.instruction, send.instruction);
      expect(back.spokenAt, send.spokenAt);
      expect(back.status, AssistantSendStatus.pendingUndo);
      expect(back.readyAt, send.readyAt);
      expect(back.attempts, 0);
      expect(back.failure, isNull);
      expect(back.sentAt, isNull);
    });

    test('a queued entry round-trips with its reason kept', () {
      final send = _queued(_t0)
          .afterFailure(AssistantFailure.network, now: _t0, policy: _policy);
      final back = _roundTrip(send);
      expect(back.status, AssistantSendStatus.queued);
      expect(back.attempts, 1);
      expect(back.readyAt, send.readyAt);
      expect(back.failure, AssistantFailure.network);
      expect(back.sentAt, isNull);
    });

    test('a sent entry round-trips with its sentAt', () {
      final at = _t0.add(const Duration(seconds: 7));
      final send = _queued(_t0).succeeded(at);
      final back = _roundTrip(send);
      expect(back.status, AssistantSendStatus.sent);
      expect(back.sentAt, at);
      expect(back.attempts, 1);
      expect(back.failure, isNull);
    });

    test('a failed entry round-trips with the reason it failed for', () {
      final send = _queued(_t0)
          .afterFailure(AssistantFailure.signIn, now: _t0, policy: _policy);
      final back = _roundTrip(send);
      expect(back.status, AssistantSendStatus.failed);
      expect(back.failure, AssistantFailure.signIn);
      expect(back.attempts, 1);
    });

    test('a gave-up entry round-trips', () {
      final send = _queued(_t0)
          .copyWith(attempts: 5)
          .afterFailure(AssistantFailure.server, now: _t0, policy: _policy);
      final back = _roundTrip(send);
      expect(back.status, AssistantSendStatus.failed);
      expect(back.failure, AssistantFailure.gaveUp);
      expect(back.attempts, 6);
    });

    test('a notSent entry round-trips', () {
      final send = _pending(_t0).copyWith(status: AssistantSendStatus.notSent);
      expect(_roundTrip(send).status, AssistantSendStatus.notSent);
    });

    test('a multi-line Devanagari instruction survives the file', () {
      final send = AssistantSend.pending(
        noteId: _noteId,
        instruction: 'मुझे छह बजे याद दिलाना\nऔर दूध ले आना',
        spokenAt: _spokenAt,
        now: _t0,
        policy: _policy,
      );
      expect(_roundTrip(send).instruction,
          'मुझे छह बजे याद दिलाना\nऔर दूध ले आना');
    });

    test('a send that was on the wire when the app died comes back queued', () {
      // The send either reached the server or it did not and the outbox cannot
      // know which, so it is re-queued rather than resumed as sending.
      final onTheWire = _queued(_t0).startSending();
      expect(onTheWire.toJson()['status'], 'sending');
      expect(_roundTrip(onTheWire).status, AssistantSendStatus.queued);
    });

    test('an omitted failure and sentAt are left out of the file entirely', () {
      final json = _pending(_t0).toJson();
      expect(json.containsKey('failure'), isFalse);
      expect(json.containsKey('sentAt'), isFalse);
      expect(json['noteId'], _noteId);
      expect(json['status'], 'pendingUndo');
      expect(json['attempts'], 0);
    });
  });

  group('JSON that cannot be trusted is refused', () {
    test('anything that is not a map', () {
      expect(AssistantSend.fromJson(null), isNull);
      expect(AssistantSend.fromJson('pendingUndo'), isNull);
      expect(AssistantSend.fromJson(42), isNull);
      expect(AssistantSend.fromJson(<Object?>[]), isNull);
      expect(AssistantSend.fromJson(jsonDecode('[]')), isNull);
    });

    test('a missing or empty note id', () {
      final good = _pending(_t0).toJson();
      expect(AssistantSend.fromJson(<String, Object?>{...good}..remove('noteId')),
          isNull);
      expect(AssistantSend.fromJson(<String, Object?>{...good, 'noteId': ''}),
          isNull);
      expect(AssistantSend.fromJson(<String, Object?>{...good, 'noteId': 7}),
          isNull);
    });

    test('a missing instruction', () {
      final good = _pending(_t0).toJson();
      expect(
        AssistantSend.fromJson(
            <String, Object?>{...good}..remove('instruction')),
        isNull,
      );
    });

    test('a date that will not parse', () {
      final good = _pending(_t0).toJson();
      expect(
        AssistantSend.fromJson(
            <String, Object?>{...good, 'spokenAt': 'this afternoon'}),
        isNull,
      );
      expect(
        AssistantSend.fromJson(<String, Object?>{...good, 'readyAt': 'soon'}),
        isNull,
      );
      expect(
        AssistantSend.fromJson(<String, Object?>{...good, 'readyAt': 0}),
        isNull,
      );
    });

    test('a status this build does not know, or one of the wrong type', () {
      final good = _pending(_t0).toJson();
      expect(
        AssistantSend.fromJson(<String, Object?>{...good, 'status': 'exploded'}),
        isNull,
      );
      expect(
        AssistantSend.fromJson(<String, Object?>{...good, 'status': 3}),
        isNull,
      );
      expect(
        AssistantSend.fromJson(<String, Object?>{...good, 'status': null}),
        isNull,
      );
      expect(
        AssistantSend.fromJson(<String, Object?>{...good}..remove('status')),
        isNull,
      );
    });

    test('an unknown failure name loses the reason, not the entry', () {
      final good = _queued(_t0)
          .afterFailure(AssistantFailure.network, now: _t0, policy: _policy)
          .toJson();
      final back = AssistantSend.fromJson(
          <String, Object?>{...good, 'failure': 'sunspots'});
      expect(back, isNotNull);
      expect(back!.failure, isNull);
      expect(back.status, AssistantSendStatus.queued);
      expect(back.attempts, 1);
    });

    test('a bad attempt count reads as none, and a bad sentAt as none', () {
      final good = _pending(_t0).toJson();
      final back = AssistantSend.fromJson(<String, Object?>{
        ...good,
        'attempts': 'lots',
        'sentAt': 'yesterday',
      });
      expect(back, isNotNull);
      expect(back!.attempts, 0);
      expect(back.sentAt, isNull);
    });
  });

  group('toString leaks nothing', () {
    test('it prints no word of the instruction', () {
      final printed = _queued(_t0).toString();
      expect(printed, isNot(contains('remind')));
      expect(printed, isNot(contains('Priya')));
      expect(printed, isNot(contains('invoice')));
      expect(printed, contains('queued'));
      expect(printed, contains('41 chars'));
    });

    test('nor the note id', () {
      expect(_pending(_t0).toString(), isNot(contains(_noteId)));
    });
  });
}
