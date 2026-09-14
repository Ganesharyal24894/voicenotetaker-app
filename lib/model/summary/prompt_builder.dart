/// The prompts the user pastes into their own AI app.
///
/// PURE: text in, text out, every rule a unit test. No AI runs in the app; the
/// wording here is the whole contract with the AI, and the reply headings at
/// the end of the range prompt are the contract with `ReplyParser`.
library;

import 'prompt_note.dart';
import 'summary_range.dart';

/// A range prompt, whole or in parts.
class RangePrompt {
  const RangePrompt({
    required this.range,
    required this.window,
    required this.whole,
    required this.parts,
    required this.noteCount,
    required this.speech,
    required this.wordCount,
  });

  final SummaryRange range;
  final DayWindow window;

  /// The prompt as one message.
  final String whole;

  /// The prompt as numbered parts, each with the instructions. One element
  /// when it is not long.
  final List<String> parts;

  /// Notes with words in them - the ones in the prompt.
  final int noteCount;

  /// Their total length.
  final Duration speech;

  /// Words of transcript, instructions not counted.
  final int wordCount;

  /// Long enough that some AI apps cut it off or refuse it.
  bool get isLong => parts.length > 1;
}

abstract final class PromptBuilder {
  /// LONG = more than this many words of transcript. From the design: past
  /// ~8,000 words the free tiers of the common AI apps start truncating the
  /// paste or ignoring the start of it.
  static const int longWords = 8000;

  /// ...or more than this many characters in the whole prompt. Devanagari is
  /// dense in tokens (often one token per one or two characters), so a
  /// prompt under the word limit can still be ~30-60k tokens here, and 60k
  /// characters is also around where paste boxes start turning text into an
  /// attachment. Whichever limit is hit first splits.
  static const int longCharacters = 60000;

  static const String _caveat =
      'They were transcribed automatically from Hindi/Hinglish speech, so '
      'expect spelling mistakes and wrong words; infer meaning carefully and '
      'do not invent facts.';

  static const String _speakers =
      'Speakers are labelled Speaker 1, Speaker 2… per note (labels are not '
      'the same person across notes).';

  /// The Summarize-with-your-AI prompt for [notes] in [range].
  ///
  /// Notes without words are left out; the order is oldest first, the way a
  /// day is read.
  static RangePrompt range({
    required SummaryRange range,
    required DateTime now,
    required List<PromptNote> notes,
  }) {
    final window = range.windowAt(now);
    final used = notes.where((n) => n.hasWords).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final words = used.fold(0, (sum, n) => sum + n.wordCount);
    final speech = used.fold(Duration.zero, (sum, n) => sum + n.duration);
    final blocks = _noteBlocks(used, multiDay: range.dayCount > 1);
    final whole = _rangeText(range, window, now, used, blocks, null);

    var parts = <String>[whole];
    if (words > longWords || whole.length > longCharacters) {
      final count = _partCount(words, whole.length);
      final groups = _split(blocks, count);
      parts = <String>[
        for (var i = 0; i < groups.length; i++)
          _rangeText(range, window, now, used, groups[i], (i + 1, groups.length)),
      ];
    }
    return RangePrompt(
      range: range,
      window: window,
      whole: whole,
      parts: parts,
      noteCount: used.length,
      speech: speech,
      wordCount: words,
    );
  }

  /// The "Summarize this note" prompt.
  static String note({required PromptNote note, required DateTime now}) {
    final speakers = note.speakerCount;
    final details = speakers == null
        ? minutes(note.duration)
        : '${minutes(note.duration)}, ${speakerLabel(speakers)}';
    final buffer = StringBuffer()
      ..writeln(
        'You are my productivity assistant. Below is the transcript of one '
        'recorded conversation from ${dayPhrase(note.startedAt, now)} at '
        '${clock(note.startedAt)} ($details). It was transcribed automatically '
        'from Hindi/Hinglish speech, so expect spelling mistakes and wrong '
        'words; infer meaning carefully and do not invent facts. Reply in '
        'English.',
      )
      ..writeln()
      ..writeln('Give me:')
      ..writeln('1. Summary — 3 to 5 bullets.')
      ..writeln(
        '2. To-dos — as a checkbox list: task · who asked · due date if '
        'mentioned · time in the note.',
      )
      ..writeln('3. Decisions made.')
      ..writeln(note.hasSpeakers ? '4. Key points by speaker.' : '4. Key points.')
      ..writeln('5. Open questions.')
      ..writeln('Keep it short.')
      ..writeln()
      ..writeln('--- Transcript ---');
    for (final line in note.lines) {
      final at = line.at == null ? '' : '[${offset(line.at!)}] ';
      final who = line.speaker == null ? '' : '${line.speaker}: ';
      buffer.writeln('$at$who${line.text.trim()}');
    }
    return buffer.toString().trimRight();
  }

  // ---------------------------------------------------------------------------

  static String _rangeText(
    SummaryRange range,
    DayWindow window,
    DateTime now,
    List<PromptNote> used,
    List<String> blocks,
    (int, int)? part,
  ) {
    final multiDay = range.dayCount > 1;
    final buffer = StringBuffer();
    if (part != null) {
      final (index, total) = part;
      buffer.writeln(
        index < total
            ? 'Part $index of $total. My notes are too long for one message. '
                'Do not answer yet: reply only "Got it" and wait for part '
                '${index + 1}.'
            : 'Part $index of $total (the last part). Now answer using the '
                'notes from all $total parts.',
      );
      buffer.writeln();
    }
    buffer.writeln(
      'You are my productivity assistant. Below are transcripts of my recorded '
      'conversations and voice notes from ${rangePhrase(range, window, now)}. '
      '$_caveat${used.any((n) => n.hasSpeakers) ? ' $_speakers' : ''} Reply in '
      'English.',
    );
    buffer
      ..writeln()
      ..writeln('Give me:')
      ..writeln(
        multiDay
            ? '1. Summary — 3 to 5 bullets of what these days were about.'
            : '1. Summary — 3 to 5 bullets of what my day was about.',
      )
      ..writeln(
        '2. To-do list — every task, promise or request, as a checkbox list: '
        'task · who asked · due date if mentioned · note time.',
      )
      ..writeln('3. Work done — what I finished or progressed.')
      ..writeln('4. Decisions made.')
      ..writeln('5. Waiting on others — things others promised me.')
      ..writeln('6. People — who I talked with and what about.')
      ..writeln('7. Ideas and notes to self.')
      ..writeln(
        '8. Open questions — anything unclear I should follow up on.',
      );
    if (range.asksForPatterns) {
      buffer.writeln(
        '9. Patterns — themes, people or problems that keep coming up across '
        'these days.',
      );
    }
    buffer
      ..writeln(
        multiDay
            ? 'Keep it short. Quote the day and note time (e.g. Mon 09:14) for '
                'each item.'
            : 'Keep it short. Quote the note time (e.g. 09:14) for each item.',
      )
      ..writeln(
        'Reply using exactly these headings so my app can read it: '
        '## Summary, ## To-dos (one per line: - [ ] task | who asked | due | '
        'note time), ## Work done, ## Decisions, ## Waiting on others '
        '(- item | who | note time), ## People, ## Ideas, ## Open questions'
        '${range.asksForPatterns ? ', ## Patterns' : ''}.',
      )
      ..writeln()
      ..writeln('--- Notes ---');
    for (final block in blocks) {
      buffer.writeln(block);
    }
    return buffer.toString().trimRight();
  }

  /// One text block per note, with a day line before each new day when the
  /// range spans several.
  static List<String> _noteBlocks(List<PromptNote> notes, {required bool multiDay}) {
    final blocks = <String>[];
    DateTime? day;
    for (final note in notes) {
      final noteDay = DayWindow.midnight(note.startedAt);
      final buffer = StringBuffer();
      if (multiDay && noteDay != day) {
        buffer.writeln('--- ${weekdayDate(noteDay)} ---');
        day = noteDay;
      }
      buffer.write(noteHeader(note));
      for (final line in note.lines) {
        final text = line.text.trim();
        if (text.isEmpty) continue;
        buffer
          ..writeln()
          ..write(line.speaker == null ? text : '${line.speaker}: $text');
      }
      blocks.add(buffer.toString());
    }
    return blocks;
  }

  static int _partCount(int words, int characters) {
    final byWords = (words / longWords).ceil();
    final byCharacters = (characters / longCharacters).ceil();
    final count = byWords > byCharacters ? byWords : byCharacters;
    return count < 2 ? 2 : count;
  }

  /// Splits whole note blocks into [count] groups of about equal length. A
  /// note is never cut in half unless it alone is longer than a part, in which
  /// case it is cut at line breaks.
  static List<List<String>> _split(List<String> blocks, int count) {
    final total = blocks.fold(0, (sum, b) => sum + b.length + 1);
    final target = (total / count).ceil();
    final pieces = <String>[];
    for (final block in blocks) {
      if (block.length <= target) {
        pieces.add(block);
        continue;
      }
      final lines = block.split('\n');
      final header = lines.first.startsWith('---') && lines.length > 1
          ? '${lines[0]}\n${lines[1]}'
          : lines.first;
      final body = lines.skip(header.split('\n').length).toList();
      var chunk = StringBuffer(header);
      for (final line in body) {
        if (chunk.length + line.length + 1 > target && chunk.length > header.length) {
          pieces.add(chunk.toString());
          chunk = StringBuffer('${header.split('\n').last} (continued)');
        }
        chunk
          ..writeln()
          ..write(line);
      }
      pieces.add(chunk.toString());
    }
    final groups = <List<String>>[<String>[]];
    var size = 0;
    for (final piece in pieces) {
      if (size > 0 && size + piece.length > target && groups.length < count) {
        groups.add(<String>[]);
        size = 0;
      }
      groups.last.add(piece);
      size += piece.length + 1;
    }
    return groups;
  }

  // --- The strings, public so the sheets and the tests say the same thing. --

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String clock(DateTime at) => '${_two(at.hour)}:${_two(at.minute)}';

  /// `[09:14 · 12 min · 2 speakers]`, speakers left out when unknown.
  static String noteHeader(PromptNote note) {
    final speakers = note.speakerCount;
    return '[${clock(note.startedAt)} · ${minutes(note.duration)}'
        '${speakers == null ? '' : ' · ${speakerLabel(speakers)}'}]';
  }

  /// `12 min`, `1 h 05 min`, `under 1 min`.
  static String minutes(Duration d) {
    if (d.inSeconds < 60) return 'under 1 min';
    final total = (d.inSeconds / 60).round();
    if (total < 60) return '$total min';
    return '${total ~/ 60} h ${_two(total % 60)} min';
  }

  static String speakerLabel(int count) =>
      count == 1 ? '1 speaker' : '$count speakers';

  /// `00:42`, `1:02:05`.
  static String offset(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    return hours > 0
        ? '$hours:${_two(minutes)}:${_two(seconds)}'
        : '${_two(minutes)}:${_two(seconds)}';
  }

  static const List<String> _weekdays = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', //
  ];
  static const List<String> _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// `15 Sep 2026`.
  static String date(DateTime at) =>
      '${at.day} ${_months[at.month - 1]} ${at.year}';

  /// `Mon 14 Sep`.
  static String weekdayDate(DateTime at) =>
      '${_weekdays[at.weekday - 1]} ${at.day} ${_months[at.month - 1]}';

  /// `Today, 15 Sep 2026`, `Yesterday, 14 Sep 2026`, `Tue, 8 Sep 2026`.
  static String dayPhrase(DateTime at, DateTime now) {
    final days = DayWindow.midnight(now).difference(DayWindow.midnight(at)).inHours;
    // Hours rounded to days: a DST day is 23 or 25 hours long.
    final ago = (days / 24).round();
    if (ago == 0) return 'Today, ${date(at)}';
    if (ago == 1) return 'Yesterday, ${date(at)}';
    return '${_weekdays[at.weekday - 1]}, ${date(at)}';
  }

  /// `Today, 15 Sep 2026`, `the last 7 days, 9 Sep – 15 Sep 2026`.
  static String rangePhrase(SummaryRange range, DayWindow window, DateTime now) {
    switch (range) {
      case SummaryRange.today:
      case SummaryRange.yesterday:
        return dayPhrase(window.start, now);
      case SummaryRange.last7Days:
      case SummaryRange.last30Days:
        final first = window.start;
        final last = window.days.last;
        final firstText = first.year == last.year
            ? '${first.day} ${_months[first.month - 1]}'
            : date(first);
        return 'the last ${range.dayCount} days, $firstText – ${date(last)}';
    }
  }

  /// `about 9,800 words`: exact under 100, then to the nearest 10, then 100.
  static String aboutWords(int words) {
    final int rounded;
    if (words < 100) {
      rounded = words;
    } else if (words < 1000) {
      rounded = (words / 10).round() * 10;
    } else {
      rounded = (words / 100).round() * 100;
    }
    final text = rounded.toString().replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+(?!\d))'),
          (_) => ',',
        );
    if (words < 100) return words == 1 ? '1 word' : '$text words';
    return 'about $text words';
  }
}
