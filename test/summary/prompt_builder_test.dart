import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/summary/prompt_builder.dart';
import 'package:voicenotetaker_app/model/summary/prompt_note.dart';
import 'package:voicenotetaker_app/model/summary/summary_range.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

final DateTime _now = DateTime(2026, 9, 15, 18, 30);

PromptNote _note(
  int hour,
  int minute, {
  int minutes = 12,
  int? speakers,
  List<PromptLine>? lines,
  DateTime? day,
}) {
  final d = day ?? _now;
  return PromptNote(
    startedAt: DateTime(d.year, d.month, d.day, hour, minute),
    duration: Duration(minutes: minutes),
    speakerCount: speakers,
    lines: lines ?? const <PromptLine>[PromptLine(text: 'कल की मीटिंग में क्लाइंट ने डेडलाइन बढ़ा दी')],
  );
}

void main() {
  group('the range prompt, as PromptReady shows it', () {
    test('Today: the exact wording, caveat, sections and reply headings', () {
      final prompt = PromptBuilder.range(
        range: SummaryRange.today,
        now: _now,
        notes: <PromptNote>[
          _note(9, 14, speakers: 2, lines: const <PromptLine>[
            PromptLine(text: 'हाँ, सुनो — डेडलाइन शुक्रवार तक बढ़ा दी।', speaker: 'Speaker 1'),
            PromptLine(text: 'अच्छा, ये तो अच्छी न्यूज़ है।', speaker: 'Speaker 2'),
          ]),
          _note(8, 31, minutes: 4, speakers: 2, lines: const <PromptLine>[
            PromptLine(text: 'गुड मॉर्निंग सर', speaker: 'Speaker 1'),
          ]),
        ],
      );

      expect(prompt.whole, '''
You are my productivity assistant. Below are transcripts of my recorded conversations and voice notes from Today, 15 Sep 2026. They were transcribed automatically from Hindi/Hinglish speech, so expect spelling mistakes and wrong words; infer meaning carefully and do not invent facts. Speakers are labelled Speaker 1, Speaker 2… per note (labels are not the same person across notes). Reply in English.

Give me:
1. Summary — 3 to 5 bullets of what my day was about.
2. To-do list — every task, promise or request, as a checkbox list: task · who asked · due date if mentioned · note time.
3. Work done — what I finished or progressed.
4. Decisions made.
5. Waiting on others — things others promised me.
6. People — who I talked with and what about.
7. Ideas and notes to self.
8. Open questions — anything unclear I should follow up on.
Keep it short. Quote the note time (e.g. 09:14) for each item.
Reply using exactly these headings so my app can read it: ## Summary, ## To-dos (one per line: - [ ] task | who asked | due | note time), ## Work done, ## Decisions, ## Waiting on others (- item | who | note time), ## People, ## Ideas, ## Open questions.

--- Notes ---
[08:31 · 4 min · 2 speakers]
Speaker 1: गुड मॉर्निंग सर
[09:14 · 12 min · 2 speakers]
Speaker 1: हाँ, सुनो — डेडलाइन शुक्रवार तक बढ़ा दी।
Speaker 2: अच्छा, ये तो अच्छी न्यूज़ है।''');
      expect(prompt.noteCount, 2);
      expect(prompt.speech, const Duration(minutes: 16));
      expect(prompt.isLong, isFalse);
      expect(prompt.parts, <String>[prompt.whole]);
    });

    test('no Patterns for one day; Patterns for 7 and 30 days', () {
      for (final range in SummaryRange.values) {
        final text = PromptBuilder.range(range: range, now: _now, notes: <PromptNote>[
          _note(9, 14, day: range == SummaryRange.yesterday ? DateTime(2026, 9, 14) : null),
        ]).whole;
        final multi = range == SummaryRange.last7Days || range == SummaryRange.last30Days;
        expect(text.contains('9. Patterns'), multi, reason: range.name);
        expect(text.contains('## Patterns'), multi, reason: range.name);
      }
    });

    test('a transcript without speakers: plain text, no speaker sentence', () {
      final text = PromptBuilder.range(
        range: SummaryRange.today,
        now: _now,
        notes: <PromptNote>[_note(10, 21, minutes: 3)],
      ).whole;
      expect(text, contains('[10:21 · 3 min]\nकल की मीटिंग में'));
      expect(text, isNot(contains('Speakers are labelled')));
      expect(text, contains('so expect spelling mistakes and wrong words'));
    });

    test('one speaker is singular, under a minute says so', () {
      expect(PromptBuilder.noteHeader(_note(9, 0, minutes: 0, speakers: 1)),
          '[09:00 · under 1 min · 1 speaker]');
      expect(PromptBuilder.minutes(const Duration(minutes: 80)), '1 h 20 min');
    });

    test('notes without words are left out and not counted', () {
      final prompt = PromptBuilder.range(
        range: SummaryRange.today,
        now: _now,
        notes: <PromptNote>[
          _note(9, 14),
          _note(11, 0, lines: const <PromptLine>[PromptLine(text: '  ')]),
        ],
      );
      expect(prompt.noteCount, 1);
      expect(prompt.whole, isNot(contains('[11:00')));
    });

    test('Yesterday, 7 and 30 days name their dates in local calendar days', () {
      expect(
        PromptBuilder.rangePhrase(SummaryRange.yesterday, SummaryRange.yesterday.windowAt(_now), _now),
        'Yesterday, 14 Sep 2026',
      );
      expect(
        PromptBuilder.rangePhrase(SummaryRange.last7Days, SummaryRange.last7Days.windowAt(_now), _now),
        'the last 7 days, 9 Sep – 15 Sep 2026',
      );
      expect(
        PromptBuilder.rangePhrase(SummaryRange.last30Days, SummaryRange.last30Days.windowAt(_now), _now),
        'the last 30 days, 17 Aug – 15 Sep 2026',
      );
      final newYear = DateTime(2027, 1, 3, 9);
      expect(
        PromptBuilder.rangePhrase(SummaryRange.last7Days, SummaryRange.last7Days.windowAt(newYear), newYear),
        'the last 7 days, 28 Dec 2026 – 3 Jan 2027',
      );
    });

    test('multi-day prompts put a day line before each day and ask for the day', () {
      final text = PromptBuilder.range(
        range: SummaryRange.last7Days,
        now: _now,
        notes: <PromptNote>[
          _note(9, 14, day: DateTime(2026, 9, 14)),
          _note(10, 0, day: DateTime(2026, 9, 14)),
          _note(8, 0),
        ],
      ).whole;
      expect(text, contains('--- Mon 14 Sep ---\n[09:14 · 12 min]'));
      expect('--- Mon 14 Sep ---'.allMatches(text), hasLength(1));
      expect(text, contains('--- Tue 15 Sep ---\n[08:00 · 12 min]'));
      expect(text, contains('Quote the day and note time (e.g. Mon 09:14)'));
      expect(text, contains('bullets of what these days were about'));
    });
  });

  group('word counts', () {
    test('about N words rounds like the sheet shows it', () {
      expect(PromptBuilder.aboutWords(1), '1 word');
      expect(PromptBuilder.aboutWords(42), '42 words');
      expect(PromptBuilder.aboutWords(1449), 'about 1,400 words');
      expect(PromptBuilder.aboutWords(1450), 'about 1,500 words');
      expect(PromptBuilder.aboutWords(9812), 'about 9,800 words');
      expect(PromptBuilder.aboutWords(123), 'about 120 words');
      expect(PromptBuilder.aboutWords(1234567), 'about 1,234,600 words');
    });

    test('counts transcript words only', () {
      final prompt = PromptBuilder.range(
        range: SummaryRange.today,
        now: _now,
        notes: <PromptNote>[
          _note(9, 0, lines: const <PromptLine>[PromptLine(text: 'one two  three')]),
          _note(10, 0, lines: const <PromptLine>[PromptLine(text: 'four', speaker: 'Speaker 1')]),
        ],
      );
      expect(prompt.wordCount, 4);
    });
  });

  group('splitting a long prompt', () {
    List<PromptNote> manyNotes(int count, int wordsEach) => <PromptNote>[
          for (var i = 0; i < count; i++)
            _note(8 + i ~/ 6, (i * 10) % 60, lines: <PromptLine>[
              PromptLine(text: List<String>.filled(wordsEach, 'शब्द').join(' ')),
            ]),
        ];

    test('under the limits it is one message', () {
      final prompt = PromptBuilder.range(range: SummaryRange.today, now: _now, notes: manyNotes(10, 700));
      expect(prompt.wordCount, 7000);
      expect(prompt.isLong, isFalse);
    });

    test('over 8,000 words it splits into numbered parts that each carry the instructions', () {
      final prompt = PromptBuilder.range(range: SummaryRange.today, now: _now, notes: manyNotes(12, 800));
      expect(prompt.isLong, isTrue);
      expect(prompt.parts, hasLength(2));
      expect(prompt.parts[0], startsWith('Part 1 of 2. My notes are too long for one message. Do not answer yet: reply only "Got it" and wait for part 2.'));
      expect(prompt.parts[1], startsWith('Part 2 of 2 (the last part). Now answer using the notes from all 2 parts.'));
      for (final part in prompt.parts) {
        expect(part, contains('You are my productivity assistant.'));
        expect(part, contains('## To-dos (one per line: - [ ] task | who asked | due | note time)'));
        expect(part, contains('--- Notes ---'));
      }
      // Every note appears exactly once across the parts, whole.
      final all = prompt.parts.join('\n');
      for (final note in manyNotes(12, 800)) {
        expect(PromptBuilder.noteHeader(note).allMatches(all), hasLength(1));
      }
      // Roughly balanced.
      expect((prompt.parts[0].length - prompt.parts[1].length).abs(),
          lessThan(prompt.whole.length ~/ 3));
    });

    test('over 60,000 characters splits even under the word limit', () {
      // Long words: few of them, many characters.
      final notes = <PromptNote>[
        for (var i = 0; i < 8; i++)
          _note(9, i, lines: <PromptLine>[PromptLine(text: List<String>.filled(500, 'अ' * 16).join(' '))]),
      ];
      final prompt = PromptBuilder.range(range: SummaryRange.today, now: _now, notes: notes);
      expect(prompt.wordCount, 4000);
      expect(prompt.whole.length, greaterThan(PromptBuilder.longCharacters));
      expect(prompt.parts.length, greaterThanOrEqualTo(2));
    });

    test('one note longer than a part is cut at line breaks and marked continued', () {
      final lines = <PromptLine>[
        for (var i = 0; i < 40; i++) PromptLine(text: List<String>.filled(500, 'शब्द').join(' ')),
      ];
      final prompt = PromptBuilder.range(
        range: SummaryRange.today,
        now: _now,
        notes: <PromptNote>[_note(9, 14, minutes: 70, lines: lines)],
      );
      expect(prompt.parts.length, greaterThanOrEqualTo(2));
      expect(prompt.parts[1], contains('[09:14 · 1 h 10 min] (continued)'));
      final words = prompt.parts
          .map((p) => p.split('--- Notes ---').last)
          .fold(0, (sum, notes) => sum + 'शब्द'.allMatches(notes).length);
      expect(words, 20000);
    });
  });

  group('the single-note prompt, as NoteSummarize shows it', () {
    test('exact wording with speakers and timestamps', () {
      final text = PromptBuilder.note(
        now: _now,
        note: PromptNote(
          startedAt: DateTime(2026, 9, 15, 9, 14),
          duration: const Duration(minutes: 12),
          speakerCount: 2,
          lines: const <PromptLine>[
            PromptLine(text: 'हाँ, सुनो — कल की मीटिंग में क्लाइंट ने डेडलाइन शुक्रवार तक बढ़ा दी।', speaker: 'Speaker 1', at: Duration.zero),
            PromptLine(text: 'अच्छा।', speaker: 'Speaker 2', at: Duration(seconds: 9)),
          ],
        ),
      );
      expect(text, '''
You are my productivity assistant. Below is the transcript of one recorded conversation from Today, 15 Sep 2026 at 09:14 (12 min, 2 speakers). It was transcribed automatically from Hindi/Hinglish speech, so expect spelling mistakes and wrong words; infer meaning carefully and do not invent facts. Reply in English.

Give me:
1. Summary — 3 to 5 bullets.
2. To-dos — as a checkbox list: task · who asked · due date if mentioned · time in the note.
3. Decisions made.
4. Key points by speaker.
5. Open questions.
Keep it short.

--- Transcript ---
[00:00] Speaker 1: हाँ, सुनो — कल की मीटिंग में क्लाइंट ने डेडलाइन शुक्रवार तक बढ़ा दी।
[00:09] Speaker 2: अच्छा।''');
    });

    test('without speakers: no speaker count, "Key points.", plain lines', () {
      final text = PromptBuilder.note(
        now: _now,
        note: PromptNote(
          startedAt: DateTime(2026, 9, 13, 9, 14),
          duration: const Duration(minutes: 3),
          lines: const <PromptLine>[PromptLine(text: 'कुछ', at: Duration(minutes: 61, seconds: 5))],
        ),
      );
      expect(text, contains('from Sun, 13 Sep 2026 at 09:14 (3 min).'));
      expect(text, contains('4. Key points.\n'));
      expect(text, endsWith('--- Transcript ---\n[1:01:05] कुछ'));
    });

    test('Yesterday is named', () {
      expect(PromptBuilder.dayPhrase(DateTime(2026, 9, 14, 23, 59), _now), 'Yesterday, 14 Sep 2026');
    });
  });

  group('PromptNote from a saved transcript', () {
    test('joins ~8 s windows into ~30 s lines, skipping silence', () {
      final transcript = Transcript(
        languageCode: 'hi',
        modelId: 'm',
        createdAt: _now,
        audioDuration: const Duration(seconds: 48),
        segments: <TranscriptSegment>[
          for (var i = 0; i < 6; i++)
            TranscriptSegment(
              start: Duration(seconds: i * 8),
              end: Duration(seconds: (i + 1) * 8),
              text: i == 2 ? ' ' : 'w$i',
            ),
        ],
      );
      final note = PromptNote.fromTranscript(
        startedAt: _now,
        duration: const Duration(seconds: 48),
        transcript: transcript,
      );
      expect(note.lines.map((l) => l.text), <String>['w0 w1 w3', 'w4 w5']);
      expect(note.lines.map((l) => l.at), <Duration>[Duration.zero, const Duration(seconds: 32)]);
      expect(note.wordCount, 5);
      expect(note.hasSpeakers, isFalse);
    });
  });
}
