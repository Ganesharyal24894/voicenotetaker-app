import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_message.dart';

import 'assistant_fakes.dart';

const String _sender = 'giftinjsr@gmail.com';
final DateTime _spokenAt = DateTime(2026, 9, 18, 14, 32);

AssistantMessage _forInstruction(String instruction) =>
    AssistantMessage.forInstruction(
      instruction: instruction,
      spokenAt: _spokenAt,
      from: _sender,
      to: testAssistant,
    );

void main() {
  group('the body is the instruction and nothing else', () {
    test('a plain instruction goes out exactly as it was spoken', () {
      const instruction = 'remind me to call Priya about the invoice';
      expect(_forInstruction(instruction).body, instruction);
    });

    test('surrounding whitespace is trimmed and nothing else changes', () {
      const instruction = '  remind me at six  ';
      expect(_forInstruction(instruction).body, instruction.trim());
      expect(_forInstruction(instruction).body, 'remind me at six');
    });

    test('a multi-line instruction keeps its inner newlines', () {
      const instruction = '\nbuy milk\nbuy bread\n  and call the plumber\n';
      expect(_forInstruction(instruction).body, instruction.trim());
      expect(
        _forInstruction(instruction).body,
        'buy milk\nbuy bread\n  and call the plumber',
      );
    });

    test('a Devanagari instruction survives byte for byte', () {
      const instruction = '  मुझे छह बजे याद दिलाना  ';
      expect(_forInstruction(instruction).body, instruction.trim());
      expect(_forInstruction(instruction).body, 'मुझे छह बजे याद दिलाना');
    });

    test('nothing is appended: no signature, no note id, no device name', () {
      const instruction = 'remind me to call Priya about the invoice';
      final message = _forInstruction(instruction);
      expect(message.body.length, instruction.length);
      expect(message.body.endsWith('invoice'), isTrue);
      expect(message.body.startsWith('remind'), isTrue);
    });

    test('an empty instruction makes an empty body, not a placeholder', () {
      expect(_forInstruction('   ').body, isEmpty);
    });
  });

  group('the subject is the time and only the time', () {
    test('the documented form', () {
      expect(
        AssistantMessage.subjectFor(DateTime(2026, 9, 18, 14, 32)),
        'Voice note - 18 Sep 2026, 14:32',
      );
    });

    test('the clock is zero padded and the day is not', () {
      expect(
        AssistantMessage.subjectFor(DateTime(2026, 9, 9, 9, 5)),
        'Voice note - 9 Sep 2026, 09:05',
      );
      expect(
        AssistantMessage.subjectFor(DateTime(2026, 1, 1, 0, 0)),
        'Voice note - 1 Jan 2026, 00:00',
      );
      expect(
        AssistantMessage.subjectFor(DateTime(2026, 12, 31, 23, 59)),
        'Voice note - 31 Dec 2026, 23:59',
      );
    });

    test('it is 24-hour, so an evening note is not read as a morning one', () {
      expect(
        AssistantMessage.subjectFor(DateTime(2026, 9, 18, 18, 5)),
        'Voice note - 18 Sep 2026, 18:05',
      );
    });

    test('the subject repeats none of the instruction', () {
      final message =
          _forInstruction('remind me to call Priya about the invoice');
      expect(message.subject, 'Voice note - 18 Sep 2026, 14:32');
      expect(message.subject, isNot(contains('remind')));
      expect(message.subject, isNot(contains('call')));
      expect(message.subject, isNot(contains('Priya')));
      expect(message.subject, isNot(contains('about')));
      expect(message.subject, isNot(contains('invoice')));
    });
  });

  group('the envelope', () {
    test('from and to are passed through unchanged', () {
      final message = _forInstruction('remind me at six');
      expect(message.from, _sender);
      expect(message.to, testAssistant);
      expect(message.to, 'bo1dx6@mail.instinct.com');
    });

    test('an odd address is not rewritten or trimmed on the way through', () {
      const odd = '  Someone.Else+tag@example.org  ';
      final message = AssistantMessage.forInstruction(
        instruction: 'hello',
        spokenAt: _spokenAt,
        from: odd,
        to: odd,
      );
      expect(message.from, odd);
      expect(message.to, odd);
    });
  });

  group('toString leaks nothing', () {
    test('it prints no word of the body', () {
      final message =
          _forInstruction('remind me to call Priya about the invoice');
      final printed = message.toString();
      expect(printed, isNot(contains('remind')));
      expect(printed, isNot(contains('call')));
      expect(printed, isNot(contains('Priya')));
      expect(printed, isNot(contains('about')));
      expect(printed, isNot(contains('invoice')));
      expect(printed, contains('41 chars'));
    });

    test('it prints no word of a Devanagari body', () {
      final message = _forInstruction('मुझे छह बजे याद दिलाना');
      final printed = message.toString();
      expect(printed, isNot(contains('मुझे')));
      expect(printed, isNot(contains('याद')));
      expect(printed, isNot(contains('दिलाना')));
    });

    test('a password that was never given to it cannot appear in it', () {
      final message = _forInstruction('remind me at six');
      expect(message.toString(), isNot(contains(testAccount.password)));
      expect(message.body, isNot(contains(testAccount.password)));
      expect(message.subject, isNot(contains(testAccount.password)));
    });
  });

  group('value semantics', () {
    test('two messages with the same four strings are equal', () {
      final one = _forInstruction('remind me at six');
      final two = _forInstruction('remind me at six');
      expect(one, two);
      expect(one.hashCode, two.hashCode);
    });

    test('a different body is a different message', () {
      expect(
        _forInstruction('remind me at six'),
        isNot(_forInstruction('remind me at seven')),
      );
    });

    test('a different recipient is a different message', () {
      final mine = _forInstruction('remind me at six');
      final theirs = AssistantMessage.forInstruction(
        instruction: 'remind me at six',
        spokenAt: _spokenAt,
        from: _sender,
        to: 'someone.else@example.org',
      );
      expect(mine, isNot(theirs));
    });

    test('a different sender or subject is a different message', () {
      const base = AssistantMessage(
        from: _sender,
        to: testAssistant,
        subject: 'Voice note - 18 Sep 2026, 14:32',
        body: 'remind me at six',
      );
      expect(base, isNot(base.copyFrom(from: 'other@example.org')));
      expect(base, isNot(base.copyFrom(subject: 'Voice note - 1 Jan 2026, 00:00')));
    });
  });
}

extension on AssistantMessage {
  /// A local helper: these tests need a message that differs in one field
  /// only, and the class itself has no copyWith.
  AssistantMessage copyFrom({String? from, String? subject}) =>
      AssistantMessage(
        from: from ?? this.from,
        to: to,
        subject: subject ?? this.subject,
        body: body,
      );
}
