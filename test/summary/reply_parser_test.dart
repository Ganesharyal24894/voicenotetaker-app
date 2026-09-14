import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/summary/day_summary.dart';
import 'package:voicenotetaker_app/model/summary/note_time.dart';
import 'package:voicenotetaker_app/model/summary/reply_parser.dart';

Map<SummarySection, List<SummaryItem>> _parse(String text) {
  final result = ReplyParser.parse(text);
  expect(result, isNotNull, reason: 'expected a usable reply');
  return result!;
}

List<String> _texts(List<SummaryItem>? items) =>
    <String>[for (final item in items ?? const <SummaryItem>[]) item.text];

const NoteTime _t0914 = NoteTime(hour: 9, minute: 14);

void main() {
  group('the exact format the prompt asks for', () {
    const reply = '''
## Summary
- Deadline moved to Friday: testing by Wed, demo Thu.
- Staging access and the budget reply are blocking you.

## To-dos
- [ ] Get staging server access from IT | You promised | today 14:00 | 09:14
- [ ] Send budget follow-up to finance | You promised | this evening | 09:14
- [x] Share server migration plan | Your manager | this evening | 08:31
- [ ] Book car service | Note to self | - | 10:21

## Work done
- Finished the login screen | 11:52

## Decisions
- Client deadline moved to Friday | 09:14

## Waiting on others
- Design files | Priya | 10:58
- Fix for the invoice issue | Rohit | 10:58

## People
- Priya — design files

## Ideas
- Try a shorter standup

## Open questions
- Who owns the vendor contract?
''';

    test('every section, every field', () {
      final s = _parse(reply);
      expect(_texts(s[SummarySection.summary]), <String>[
        'Deadline moved to Friday: testing by Wed, demo Thu.',
        'Staging access and the budget reply are blocking you.',
      ]);
      final todos = s[SummarySection.todos]!;
      expect(todos, hasLength(4));
      expect(todos[0], const SummaryItem(
        text: 'Get staging server access from IT',
        who: 'You promised',
        due: 'today 14:00',
        noteTime: _t0914,
      ));
      expect(todos[2].done, isTrue);
      expect(todos[2].noteTime, const NoteTime(hour: 8, minute: 31));
      expect(todos[3].due, isNull, reason: '"-" is an empty field');
      expect(todos[3].who, 'Note to self');
      expect(s[SummarySection.workDone]!.single.noteTime, const NoteTime(hour: 11, minute: 52));
      expect(s[SummarySection.decisions]!.single,
          const SummaryItem(text: 'Client deadline moved to Friday', noteTime: _t0914));
      final waiting = s[SummarySection.waiting]!;
      expect(waiting[0], const SummaryItem(text: 'Design files', who: 'Priya', noteTime: NoteTime(hour: 10, minute: 58)));
      expect(waiting[1].who, 'Rohit');
      expect(_texts(s[SummarySection.people]), <String>['Priya — design files']);
      expect(_texts(s[SummarySection.ideas]), <String>['Try a shorter standup']);
      expect(_texts(s[SummarySection.openQuestions]), <String>['Who owns the vendor contract?']);
      expect(s.containsKey(SummarySection.patterns), isFalse);
    });

    test('CRLF line endings read the same', () {
      expect(_parse(reply.replaceAll('\n', '\r\n'))[SummarySection.todos], _parse(reply)[SummarySection.todos]);
    });
  });

  group('ChatGPT style', () {
    test('bold numbered headings, a friendly intro and outro, bullets with middots', () {
      final s = _parse('''
Here's a summary of your day based on the transcripts:

**1. Summary**
* The client moved the deadline to Friday.
* You need staging access before testing.

**2. To-do list**
* [ ] Get staging server access from IT · You promised · today 14:00 · 09:14
* [ ] Send budget follow-up · Finance asked · this evening · 09:14

**4. Decisions made**
* Deadline moved to Friday (09:14)

Let me know if you'd like me to turn these into calendar reminders!
''');
      expect(_texts(s[SummarySection.summary]), hasLength(2));
      expect(s[SummarySection.todos]![1], const SummaryItem(
        text: 'Send budget follow-up', who: 'Finance asked', due: 'this evening', noteTime: _t0914));
      expect(s[SummarySection.decisions]!.single,
          const SummaryItem(text: 'Deadline moved to Friday', noteTime: _t0914));
      expect(_texts(s[SummarySection.decisions]), isNot(contains(startsWith('Let me know'))));
    });

    test('a markdown table of to-dos', () {
      final s = _parse('''
### To-dos
| Task | Who asked | Due | Note time |
|------|-----------|-----|-----------|
| Get staging access | You promised | today | 09:14 |
| Book car service | Note to self | — | 10:21 |
''');
      final todos = s[SummarySection.todos]!;
      expect(todos, hasLength(2));
      expect(todos[0], const SummaryItem(text: 'Get staging access', who: 'You promised', due: 'today', noteTime: _t0914));
      expect(todos[1].due, isNull);
    });
  });

  group('Claude style', () {
    test('exact headings with labelled fields on wrapped lines', () {
      final s = _parse('''
I've gone through the notes carefully. A few words were unclear, so I've flagged them.

## Summary

Your day centred on the client deadline, which moved to Friday. Testing needs to wrap up by Wednesday.

## To-dos

- [ ] **Get staging server access from IT**
  Who asked: You promised — Due: today 14:00 — Note time: 09:14
- [ ] Follow up with finance on the budget email — Who asked: you — Due: this evening — 09:14

## Waiting on others

- Design files — Priya — 10:58

## Open questions

None.
''');
      expect(_texts(s[SummarySection.summary]), <String>[
        'Your day centred on the client deadline, which moved to Friday. Testing needs to wrap up by Wednesday.',
      ]);
      final todos = s[SummarySection.todos]!;
      expect(todos[0], const SummaryItem(
        text: 'Get staging server access from IT', who: 'You promised', due: 'today 14:00', noteTime: _t0914));
      expect(todos[1], const SummaryItem(
        text: 'Follow up with finance on the budget email', who: 'you', due: 'this evening', noteTime: _t0914));
      expect(s[SummarySection.waiting]!.single.noteTime, const NoteTime(hour: 10, minute: 58));
      expect(s.containsKey(SummarySection.openQuestions), isFalse, reason: '"None." is not an item');
    });
  });

  group('Gemini style', () {
    test('headings with trailing colons, numbered items, 12-hour times', () {
      final s = _parse('''
**Summary:** A busy day focused on the client demo.

**To-dos:**
1. [ ] Get staging access (You promised, 9:14 AM)
2. [X] Share migration plan (Your manager, 8:31 am)

**Waiting on others:**
1. Fix for the invoice issue (Rohit, 10:58)

**Patterns:**
- Deadlines keep slipping on Fridays.
''');
      expect(_texts(s[SummarySection.summary]), <String>['A busy day focused on the client demo.']);
      final todos = s[SummarySection.todos]!;
      expect(todos[0], const SummaryItem(text: 'Get staging access', who: 'You promised', noteTime: _t0914));
      expect(todos[1].done, isTrue);
      expect(todos[1].noteTime, const NoteTime(hour: 8, minute: 31));
      expect(s[SummarySection.waiting]!.single, const SummaryItem(
          text: 'Fix for the invoice issue', who: 'Rohit', noteTime: NoteTime(hour: 10, minute: 58)));
      expect(_texts(s[SummarySection.patterns]), <String>['Deadlines keep slipping on Fridays.']);
    });

    test('plain title lines with emoji and "Action items"', () {
      final s = _parse('''
📝 Summary
The deadline moved.

✅ Action items
• Book car service — 10:21 pm
''');
      expect(_texts(s[SummarySection.summary]), <String>['The deadline moved.']);
      expect(s[SummarySection.todos]!.single,
          const SummaryItem(text: 'Book car service', noteTime: NoteTime(hour: 22, minute: 21)));
    });
  });

  group('tolerance', () {
    test('"To-do list", "Decisions made", "Waiting on" and "Ideas and notes to self" map to their sections', () {
      final s = _parse('''
# To-do list
- task one
# Decisions made
- decided
# Waiting on
- thing | Asha
# Ideas and notes to self
- idea
# Follow-ups
- ask again
# Work done / progress
- shipped
''');
      expect(s.keys, containsAll(<SummarySection>[
        SummarySection.todos, SummarySection.decisions, SummarySection.waiting,
        SummarySection.ideas, SummarySection.openQuestions, SummarySection.workDone,
      ]));
      expect(s[SummarySection.waiting]!.single.who, 'Asha');
    });

    test('bullets without pipes or times are kept as plain text', () {
      final s = _parse('## To-dos\n- Call the plumber\n- [ ] Pay rent');
      expect(s[SummarySection.todos], const <SummaryItem>[
        SummaryItem(text: 'Call the plumber'),
        SummaryItem(text: 'Pay rent'),
      ]);
    });

    test('missing fields: only a time', () {
      final s = _parse('## To-dos\n- [ ] Send invoice | | | 16:05');
      expect(s[SummarySection.todos]!.single,
          const SummaryItem(text: 'Send invoice', noteTime: NoteTime(hour: 16, minute: 5)));
    });

    test('a day before the time for multi-day replies', () {
      final s = _parse('## Decisions\n- Hire a tester | Mon 09:14\n- Pause ads | 14 Sep 17:02');
      expect(s[SummarySection.decisions]![0].noteTime, const NoteTime(hour: 9, minute: 14, weekday: 1));
      expect(s[SummarySection.decisions]![1].noteTime, const NoteTime(hour: 17, minute: 2, day: 14, month: 9));
    });

    test('a heading this app does not keep does not leak its lines into the one above', () {
      final s = _parse('''
## Decisions
- Ship on Friday
**Key points by speaker**
- Speaker 1: wants Friday
## Open questions
- Budget?
''');
      expect(_texts(s[SummarySection.decisions]), <String>['Ship on Friday']);
      expect(_texts(s[SummarySection.openQuestions]), <String>['Budget?']);
    });

    test('checkboxes with no headings at all still become to-dos', () {
      final s = _parse('Sure! Here you go:\n- [ ] Call Priya | Priya | 10:58\n- [x] Pay rent');
      expect(s[SummarySection.todos], hasLength(2));
      expect(s[SummarySection.todos]![1].done, isTrue);
    });

    test('horizontal rules and blank lines are ignored', () {
      final s = _parse('## Summary\n\n---\n\n- One\n\n***\n## Ideas\n\n- Two');
      expect(_texts(s[SummarySection.summary]), <String>['One']);
      expect(_texts(s[SummarySection.ideas]), <String>['Two']);
    });

    test('an echoed heading instruction is still the heading', () {
      final s = _parse('## To-dos (one per line: - [ ] task | who asked | due | note time)\n- [ ] A | B | C | 07:00');
      expect(s[SummarySection.todos]!.single.who, 'B');
    });

    test('prose that merely mentions a section is not a heading', () {
      final s = _parse('## Summary\nDecisions were made quickly after lunch today.\n## Ideas\n- x');
      expect(_texts(s[SummarySection.summary]), <String>['Decisions were made quickly after lunch today.']);
    });

    test('a price is not a time', () {
      expect(NoteTime.tryParse('3.50'), isNull);
      expect(NoteTime.tryParse('09.14'), const NoteTime(hour: 9, minute: 14));
      expect(NoteTime.tryParse('25:00'), isNull);
      expect(NoteTime.tryParse('12:30 am'), const NoteTime(hour: 0, minute: 30));
      expect(NoteTime.tryParse('[09:14]'), _t0914);
      expect(NoteTime.tryParse('Note time: 09:14'), _t0914);
    });
  });

  group('nothing usable', () {
    for (final text in <String>[
      '',
      '   \n\n',
      'Sorry, I cannot help with that.',
      'Here is a poem about your day.\nRoses are red.',
      '## Summary\nNone\n## To-dos\n- None\n- N/A',
    ]) {
      test('"${text.replaceAll('\n', r'\n')}"', () {
        expect(ReplyParser.parse(text), isNull);
      });
    }
  });
}
