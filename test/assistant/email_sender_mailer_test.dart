// The SMTP driver, as far as it can be exercised without a mail server.
//
// The socket itself is not testable here and is not meant to be - that is what
// the `EmailSender` seam and `RecordingEmailSender` are for. What IS tested is
// the one piece of judgement in the file: turning a server's reply into a
// reason the outbox can act on. Get it wrong and either a wrong password is
// retried for twelve minutes, or a passing rate limit throws an instruction
// away.
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/email_sender.dart';
import 'package:voicenotetaker_app/drivers/email_sender_mailer.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_message.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_send.dart';
import 'package:voicenotetaker_app/services/assistant/assistant_outbox.dart';

void main() {
  EmailFailure reason(String reply) =>
      MailerEmailSender.failureForResponse(reply);

  group('a 4xx is the server saying "not now"', () {
    for (final reply in <String>[
      '421 4.7.0 Try again later, closing connection',
      '450 4.2.0 Mailbox busy',
      '451 4.3.0 Temporary local problem',
      '452 4.2.2 Over quota',
    ]) {
      test('"$reply" is worth trying again', () {
        expect(reason(reply), EmailFailure.server);
        // And what the outbox makes of it: worth waiting for.
        expect(AssistantOutbox.reasonFor(reason(reply)).isWorthRetrying,
            isTrue);
      });
    }
  });

  group('a 5xx about the password is permanent', () {
    for (final reply in <String>[
      '530 5.7.0 Authentication Required',
      '534 5.7.9 Application-specific password required',
      '535 5.7.8 Username and Password not accepted',
      '538 5.7.11 Encryption required for requested authentication mechanism',
    ]) {
      test('"${reply.split(' ').first}" is a sign-in problem, never retried',
          () {
        expect(reason(reply), EmailFailure.signIn);
        expect(AssistantOutbox.reasonFor(reason(reply)).isWorthRetrying,
            isFalse);
      });
    }
  });

  group('a 5xx about the recipient is permanent too', () {
    for (final reply in <String>[
      '550 5.1.1 The email account that you tried to reach does not exist',
      '551 5.1.6 User not local',
      '553 5.1.3 Invalid address',
      '554 5.7.1 Message rejected',
    ]) {
      test('"${reply.split(' ').first}" is the address, never retried', () {
        expect(reason(reply), EmailFailure.recipient);
        expect(AssistantOutbox.reasonFor(reason(reply)).isWorthRetrying,
            isFalse);
      });
    }
  });

  group('everything else gets the benefit of the doubt', () {
    test('a 5xx that is about neither is treated as the server', () {
      expect(reason('552 5.2.3 Message size exceeds limit'),
          EmailFailure.server);
      expect(reason('500 5.5.1 Unrecognized command'), EmailFailure.server);
    });

    test('a reply with no code at all is unknown, which is retried once more',
        () {
      expect(reason('Connection closed by foreign host'),
          EmailFailure.unknown);
      expect(reason(''), EmailFailure.unknown);
    });

    test('a number that is not a reply code is not read as one', () {
      // A three-digit number that is not 4xx or 5xx, and a longer run of
      // digits, must not be mistaken for a status.
      expect(reason('Wrote 1024 bytes then gave up'), EmailFailure.unknown);
      expect(reason('port 45000 unreachable'), EmailFailure.unknown);
    });

    test('the first code in the reply is the one that counts', () {
      expect(reason('535 5.7.8 see 550 in the docs'), EmailFailure.signIn);
    });
  });

  group('nothing the server said comes back out', () {
    test('only an enum is returned, never the reply text', () {
      // The SMTP conversation can contain the AUTH line, and the AUTH line
      // contains the password. The failure is an enum on purpose.
      const withPassword =
          '535 5.7.8 AUTH PLAIN AGdpZnRpbmpzckBnbWFpbC5jb20Ac2VjcmV0';
      final failure = reason(withPassword);
      expect(failure, EmailFailure.signIn);
      expect(failure.toString(), isNot(contains('AUTH')));
      expect(failure.toString(), isNot(contains('c2VjcmV0')));
    });

    test('EmailResult prints the reason and nothing else', () {
      expect(const EmailResult.failed(EmailFailure.signIn).toString(),
          'EmailResult(signIn)');
      expect(const EmailResult.sent().toString(), 'EmailResult(sent)');
    });
  });

  group('an account that cannot work does not open a socket', () {
    final message = AssistantMessage.forInstruction(
      instruction: 'remind me to call the bank',
      spokenAt: DateTime(2026, 9, 18, 14, 32),
      from: 'me@example.com',
      to: 'assistant@example.com',
    );

    const incomplete = <String, SmtpAccount>{
      'no sending address': SmtpAccount(address: '', password: 'secret'),
      'an address with no @':
          SmtpAccount(address: 'not-an-address', password: 'secret'),
      'no password': SmtpAccount(address: 'me@example.com', password: ''),
      'no host':
          SmtpAccount(address: 'me@example.com', password: 'x', host: ''),
      'no port':
          SmtpAccount(address: 'me@example.com', password: 'x', port: 0),
    };

    for (final MapEntry(key: what, value: account) in incomplete.entries) {
      test('$what is refused as a sign-in problem, without trying', () {
        // No timeout, no wait: an incomplete account is answered from memory.
        expect(
          const MailerEmailSender().send(message, account),
          completion(isA<EmailResult>()
              .having((r) => r.ok, 'ok', isFalse)
              .having((r) => r.failure, 'failure', EmailFailure.signIn)),
        );
      });
    }
  });
}
