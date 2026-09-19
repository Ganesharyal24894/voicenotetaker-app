import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/assistant/wake_phrase.dart';

const WakePhraseDetector detector = WakePhraseDetector();

/// The match, with a readable failure when the phrase was not heard at all.
WakePhraseMatch heard(String transcript) {
  final match = detector.match(transcript);
  expect(match, isNotNull,
      reason: '"$transcript" should have been addressed to the assistant');
  return match!;
}

void main() {
  group('the phrase at the front, however the recogniser spelled it', () {
    test('the way it is written, with a comma and a capital', () {
      final match = heard('Instinct, remind me at six.');
      expect(match.spoken, 'Instinct,');
      expect(match.instruction, 'remind me at six.');
      expect(match.hasInstruction, isTrue);
    });

    test('no comma and no capital, which is what Parakeet usually writes', () {
      expect(heard('instinct remind me to call mum').instruction,
          'remind me to call mum');
    });

    test('a clipped final t', () {
      final match = heard('instinc remind me at six');
      expect(match.spoken, 'instinc');
      expect(match.instruction, 'remind me at six');
    });

    test('split into two tokens', () {
      final match = heard('In stinct, remind me at six.');
      expect(match.spoken, 'In stinct,');
      expect(match.instruction, 'remind me at six.');
    });

    test('split into two tokens with no punctuation at all', () {
      expect(heard('in stinct remind me').instruction, 'remind me');
    });

    test('a k where the c was', () {
      expect(heard('Instinkt, add milk to the list').instruction,
          'add milk to the list');
    });

    test('Devanagari, the spelling IndicConformer writes most often', () {
      final match = heard('इंस्टिंक्ट, मुझे छह बजे याद दिलाना');
      expect(match.spoken, 'इंस्टिंक्ट,');
      expect(match.instruction, 'मुझे छह बजे याद दिलाना');
    });

    test('Devanagari with the nasal written as a full letter', () {
      expect(heard('इनस्टिंक्ट मुझे छह बजे याद दिलाना').instruction,
          'मुझे छह बजे याद दिलाना');
    });

    test('Devanagari with a virama instead of the nasal dot', () {
      expect(heard('इन्स्टिंक्ट, कल सुबह जगाना').instruction, 'कल सुबह जगाना');
    });

    test('a danda after the phrase is not part of the instruction', () {
      final match = heard('इंस्टिंक्ट। मुझे याद दिलाना');
      expect(match.spoken, 'इंस्टिंक्ट।');
      expect(match.instruction, 'मुझे याद दिलाना');
    });

    test('whitespace around the note is not part of either half', () {
      final match = heard('  Instinct,  remind me  ');
      expect(match.spoken, 'Instinct,');
      expect(match.instruction, 'remind me');
    });

    test('spoken keeps the raw leading text, not the normalised one', () {
      expect(heard('INSTINKT  remind me').spoken, 'INSTINKT');
      expect(heard('In  stinct remind me').spoken, 'In  stinct');
    });

    test('the instruction keeps the first word it was given', () {
      // A one- or two-letter first word is still the instruction's, not the
      // wake phrase's - this is the only outbound path, so nothing may be
      // quietly trimmed off the front of it.
      expect(heard('Instinct, go home now').instruction, 'go home now');
      expect(heard('Instinct, at six remind me').instruction,
          'at six remind me');
      expect(heard('instinct do the thing').instruction, 'do the thing');
    });
  });

  group('notes that merely sound like it', () {
    for (final transcript in <String>[
      'In six minutes I need to leave',
      'Instant coffee is fine',
      'instantly call the bank',
      'I trust my instinct, it says no',
      'Ask instinct about the invoice',
      'instructions for the new hire',
      'installing the new app',
      'in the morning, instinct will know',
      'in a bit, remind me to call the bank',
      'instinctively I knew the answer',
      '',
      '   ',
    ]) {
      test('"$transcript" is a note, not an instruction', () {
        expect(detector.match(transcript), isNull);
      });
    }
  });

  group('accepted forms we know about', () {
    test('the plural matches too', () {
      // "Instincts tell me no" is one edit from the phrase, so it goes out.
      // Accepted deliberately: the 5-second undo covers the rare case.
      final match = heard('Instincts tell me no');
      expect(match.instruction, 'tell me no');
    });
  });

  group('the phrase and nothing after it', () {
    test('matches, but there is nothing to send', () {
      final match = heard('Instinct.');
      expect(match.spoken, 'Instinct.');
      expect(match.instruction, '');
      expect(match.hasInstruction, isFalse);
    });
  });

  group('a phrase of the user\'s own', () {
    const WakePhraseDetector buddy = WakePhraseDetector(phrase: 'Hey Buddy');

    test('matches the words it was given, spaced or not', () {
      expect(buddy.match('hey buddy, do the thing')?.instruction,
          'do the thing');
      expect(buddy.match('heybuddy do the thing')?.instruction, 'do the thing');
    });

    test('the old phrase stops working once it is changed', () {
      expect(buddy.match('Instinct, do the thing'), isNull);
      expect(detector.match('hey buddy, do the thing'), isNull);
    });

    test('a phrase the user emptied out matches nothing at all', () {
      for (final phrase in <String>['', '   ', 'a', 'ok', 'हा']) {
        final cleared = WakePhraseDetector(phrase: phrase);
        expect(cleared.isUsable, isFalse, reason: 'phrase "$phrase"');
        expect(cleared.match('remind me at six'), isNull);
        expect(cleared.match('Instinct, remind me at six'), isNull);
        expect(cleared.match(''), isNull);
      }
    });

    test('the default phrase is usable', () {
      expect(detector.isUsable, isTrue);
      expect(WakePhraseDetector.normalise(WakePhraseDetector.defaultPhrase),
          'instinct');
    });
  });

  group('normalise', () {
    test('folds case and throws punctuation away', () {
      expect(WakePhraseDetector.normalise('Instinct,'), 'instinct');
      expect(WakePhraseDetector.normalise('INSTINCT!'), 'instinct');
      expect(WakePhraseDetector.normalise('  Hello,   World!  '),
          'hello world');
    });

    test('folds Devanagari to the letters it sounds like', () {
      expect(WakePhraseDetector.normalise('इंस्टिंक्ट'), 'instinkt');
      expect(WakePhraseDetector.normalise('इनस्टिंक्ट'), 'instinkt');
      expect(WakePhraseDetector.normalise('इन्स्टिंक्ट'), 'instinkt');
    });

    test('keeps digits, in either script', () {
      expect(WakePhraseDetector.normalise('Room 101'), 'room 101');
      expect(WakePhraseDetector.normalise('१२३'), '123');
    });

    test('nothing in, nothing out', () {
      expect(WakePhraseDetector.normalise(''), '');
      expect(WakePhraseDetector.normalise('...'), '');
    });
  });

  group('levenshtein', () {
    test('identical strings are no edits apart', () {
      expect(WakePhraseDetector.levenshtein('instinct', 'instinct'), 0);
      expect(WakePhraseDetector.levenshtein('', ''), 0);
    });

    test('an empty string costs the whole of the other one', () {
      expect(WakePhraseDetector.levenshtein('', 'instinct'), 8);
      expect(WakePhraseDetector.levenshtein('instinct', ''), 8);
    });

    test('"instant" is two edits from "instinct", which is why the prefix '
        'rule exists', () {
      expect(WakePhraseDetector.levenshtein('instinct', 'instant'), 2);
      expect(WakePhraseDetector.levenshtein('instinct', 'instinc'), 1);
      expect(WakePhraseDetector.levenshtein('instinct', 'instinkt'), 1);
    });

    test('it is symmetric', () {
      expect(WakePhraseDetector.levenshtein('instant', 'instinct'),
          WakePhraseDetector.levenshtein('instinct', 'instant'));
    });
  });

  group('odd input', () {
    for (final transcript in <String>[
      '🙂🙂🙂',
      'Instinct 😀 remind me',
      '1234567890',
      '०१२३४५६७८९',
      '\n\t  \r\n',
      'इंस्टिंक्ट hello مرحبا 123',
      ',,,,,,',
      '्ंँ',
    ]) {
      test('"${transcript.replaceAll('\n', r'\n').replaceAll('\t', r'\t').replaceAll('\r', r'\r')}" does not throw', () {
        expect(() => detector.match(transcript), returnsNormally);
      });
    }

    test('a very long single token does not throw and does not match', () {
      expect(detector.match('instinct${'x' * 20000}'), isNull);
      expect(detector.match('x' * 20000), isNull);
    });

    test('a very long note behind the phrase keeps all of it', () {
      final long = 'remind me ${'again ' * 5000}please';
      expect(heard('Instinct, $long').instruction, long.trim());
    });
  });
}
