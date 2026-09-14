/// Reads an AI app's reply back into summary sections.
///
/// PURE and TOLERANT. The prompt asks for exact `##` headings and pipe-
/// separated to-dos, and real replies drift from that in every way an AI app
/// can: bold or numbered headings, "To-do list" instead of "To-dos", `[x]`,
/// bullets without pipes, fields as "Who: Priya", a friendly paragraph before
/// and after, Windows line endings, a markdown table. Anything it cannot
/// place is skipped rather than guessed; a reply with nothing placeable is
/// null, and the screen says so in plain words.
library;

import 'day_summary.dart';
import 'note_time.dart';

abstract final class ReplyParser {
  /// The sections in [reply], or null when there is nothing usable in it.
  static Map<SummarySection, List<SummaryItem>>? parse(String reply) {
    final lines = reply
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final sections = <SummarySection, List<SummaryItem>>{};
    SummarySection? current;
    // Inside a section, whether a bullet has been seen and whether a blank
    // line followed it: prose after that is the AI signing off, not an item.
    var sawBullet = false;
    var blankAfterBullet = false;
    var sawHeading = false;
    final looseChecks = <SummaryItem>[];

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        if (sawBullet) blankAfterBullet = true;
        continue;
      }
      if (_isRule(line)) continue;

      final heading = _heading(line);
      if (heading != null) {
        sawHeading = true;
        current = heading.$1;
        sawBullet = false;
        blankAfterBullet = false;
        // "**Summary:** Busy day, mostly the client demo." - the words after
        // the heading on the same line are the first item.
        final rest = heading.$2;
        if (current != null && rest.isNotEmpty) {
          _add(sections, current, rest, bullet: false);
        }
        continue;
      }

      final bullet = _bullet(line);
      final table = bullet == null ? _tableRow(line) : null;
      if (current == null) {
        // Before any heading, or under one this app does not keep. A checkbox
        // line is still a to-do: some replies skip the headings entirely.
        final check = _checkbox(bullet ?? line.trim());
        if (check != null && !sawHeading) {
          final item = _item(SummarySection.todos, check.$1, done: check.$2);
          if (item != null) looseChecks.add(item);
        }
        continue;
      }

      if (table != null) {
        if (table.isEmpty) continue; // header or separator row
        _add(sections, current, table.join(' | '), bullet: true);
        sawBullet = true;
        blankAfterBullet = false;
        continue;
      }

      if (bullet != null) {
        _add(sections, current, bullet, bullet: true);
        sawBullet = true;
        blankAfterBullet = false;
        continue;
      }

      // A plain line. Indented under a bullet, it continues that item.
      final items = sections[current];
      final indented = raw.startsWith('  ') || raw.startsWith('\t');
      if (indented && sawBullet && items != null && items.isNotEmpty) {
        final last = items.removeLast();
        items.add(_merge(last, line.trim()));
        continue;
      }
      if (sawBullet && (blankAfterBullet || current != SummarySection.summary)) {
        // Prose after a list: "Let me know if you want more detail!"
        if (blankAfterBullet) current = null;
        continue;
      }
      _add(sections, current, line.trim(), bullet: false);
    }

    if (!sections.containsKey(SummarySection.todos) && looseChecks.isNotEmpty) {
      sections[SummarySection.todos] = looseChecks;
    }
    sections.removeWhere((_, items) => items.isEmpty);
    return sections.isEmpty ? null : sections;
  }

  // ---------------------------------------------------------------------------

  static bool _isRule(String line) =>
      RegExp(r'^\s*([-*_=]\s*){3,}$').hasMatch(line);

  /// A heading line: the section it names (null for a heading this app does
  /// not keep) and any words after it on the same line. Null when the line is
  /// not a heading at all.
  static (SummarySection?, String)? _heading(String line) {
    var text = line.trim();
    final hashes = RegExp(r'^#{1,6}\s*').firstMatch(text);
    final strong = hashes != null;
    if (strong) text = text.substring(hashes.end);

    // Bold or underlined, possibly with a number: "**2. To-do list:**",
    // "__Decisions__", "3) Work done:".
    var rest = '';
    final bold = RegExp(r'^(\*\*|__)(.+?)\1\s*:?\s*(.*)$').firstMatch(text);
    var decorated = strong;
    if (bold != null) {
      decorated = true;
      text = bold.group(2)!.trim();
      rest = bold.group(3)!.trim();
    }
    // An undecorated bullet or numbered line is an item, whatever it says:
    // "- Tasks for Priya" is a to-do, not a heading.
    if (!decorated && RegExp(r'^(?:[-*•+▪‣◦]|\d{1,3}[.)])\s+').hasMatch(text)) {
      return null;
    }
    text = text.replaceFirst(RegExp(r'^\d{1,2}[.)]\s*'), '');
    // "To-dos (one per line: ...)" echoed back, and emoji decoration.
    text = text.replaceAll(RegExp(r'\s*\(.*?\)\s*'), ' ').trim();
    text = text.replaceAll(RegExp(r'[^\p{L}\p{N}\s&/:\-]', unicode: true), '').trim();
    var colon = false;
    if (text.endsWith(':')) {
      colon = true;
      text = text.substring(0, text.length - 1).trim();
    } else if (!decorated) {
      // "Summary: Busy day" - a known title, a colon, then words.
      final inline = RegExp(r'^([\p{L}\s&/\-]{3,40}):\s+(.+)$', unicode: true)
          .firstMatch(text);
      if (inline != null && _sectionFor(inline.group(1)!) != null) {
        return (_sectionFor(inline.group(1)!), inline.group(2)!.trim());
      }
    }
    if (text.isEmpty) return null;
    final words = text.split(RegExp(r'\s+')).length;
    if (words > 6) return null;
    final section = _sectionFor(text);
    // A markdown heading, or a whole line in bold, is a heading even when it
    // names nothing this app keeps ("**Key points by speaker**"): its lines
    // must not land in the section above it.
    if (strong || (bold != null && rest.isEmpty)) return (section, rest);
    // Weaker forms count only when they name a section outright, so a bold
    // phrase inside the prose does not end a list.
    if (section == null) return null;
    if (decorated || colon || words <= 4) {
      // A bare "Decisions" line is a heading; "Decisions were made quickly"
      // is not, and has more than a title's words or no decoration.
      if (!decorated && !colon && words > 3) return null;
      return (section, rest);
    }
    return null;
  }

  static SummarySection? _sectionFor(String title) {
    final t = ' ${title.toLowerCase().replaceAll('&', ' and ').replaceAll(RegExp(r'[^a-z]+'), ' ').trim()} ';
    bool has(String word) => t.contains(' $word ') || t.contains(' $word');
    if (has('waiting') || has('others promised') || has('blocked on')) {
      return SummarySection.waiting;
    }
    if (has('to do') || has('todo') || has('to dos') || has('task') ||
        has('action item') || has('action point') || has('checklist') ||
        has('next step')) {
      return SummarySection.todos;
    }
    if (has('decision')) return SummarySection.decisions;
    if (has('work done') || has('completed') || has('progress') ||
        has('accomplish') || t.trim() == 'done') {
      return SummarySection.workDone;
    }
    if (has('open question') || has('question') || has('follow up') ||
        has('unclear')) {
      return SummarySection.openQuestions;
    }
    if (has('idea') || has('notes to self') || has('note to self')) {
      return SummarySection.ideas;
    }
    if (has('pattern') || has('recurring') || has('theme') || has('trend')) {
      return SummarySection.patterns;
    }
    if (has('people') || has('who i talked') || has('contacts')) {
      return SummarySection.people;
    }
    if (has('summary') || has('overview') || has('tl dr') || has('tldr') ||
        has('highlights')) {
      return SummarySection.summary;
    }
    return null;
  }

  /// The text of a bullet or numbered line, or null.
  static String? _bullet(String line) {
    final match =
        RegExp(r'^\s*(?:[-*•+▪‣◦]|\d{1,3}[.)])\s+(.*)$').firstMatch(line);
    if (match != null) return match.group(1)!.trim();
    // "[ ] task" and "☐ task" with no bullet in front.
    if (_checkbox(line.trim()) != null) return line.trim();
    return null;
  }

  /// Cells of a markdown table row; empty for its header or separator row;
  /// null when the line is not a table row.
  static List<String>? _tableRow(String line) {
    final text = line.trim();
    if (!text.startsWith('|') || !text.endsWith('|') || text.length < 3) {
      return null;
    }
    final cells = text
        .substring(1, text.length - 1)
        .split('|')
        .map((c) => c.trim())
        .toList();
    if (cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c) || c.isEmpty)) {
      return const <String>[];
    }
    final lower = cells.map((c) => c.toLowerCase()).toList();
    if (lower.any((c) => c == 'task' || c == 'item' || c == 'to-do' || c == 'todo') &&
        lower.any((c) => c.contains('time') || c.contains('who') || c.contains('due'))) {
      return const <String>[];
    }
    return cells;
  }

  /// `[ ] text` / `[x] text` / `☐` / `☑` / `✅`: the text and whether ticked.
  static (String, bool)? _checkbox(String text) {
    final match = RegExp(r'^(?:\[([ xX✓✔]?)\]|([☐☑✅✔✓]))\s*(.*)$').firstMatch(text);
    if (match == null) return null;
    final box = match.group(1);
    final glyph = match.group(2);
    final done = (box != null && box.trim().isNotEmpty) ||
        (glyph != null && glyph != '☐');
    return (match.group(3)!.trim(), done);
  }

  static void _add(
    Map<SummarySection, List<SummaryItem>> sections,
    SummarySection section,
    String text, {
    required bool bullet,
  }) {
    var body = text;
    var done = false;
    final check = _checkbox(body);
    if (check != null) {
      body = check.$1;
      done = check.$2;
    }
    final item = _item(section, body, done: done);
    if (item == null) return;
    (sections[section] ??= <SummaryItem>[]).add(item);
  }

  static SummaryItem _merge(SummaryItem item, String more) {
    // A wrapped line may carry the fields: "  Who: Priya · 10:58".
    final extra = _item(SummarySection.todos, '${item.text} | $more', done: item.done);
    if (extra == null) return item;
    return SummaryItem(
      text: item.text,
      who: item.who ?? extra.who,
      due: item.due ?? extra.due,
      noteTime: item.noteTime ?? extra.noteTime,
      done: item.done,
    );
  }

  static final RegExp _labelPattern = RegExp(
    r'^(who\s*asked|asked\s*by|requested\s*by|who|owner|from|person|by\s*whom|'
    r'due\s*date|due|deadline|when|by|note\s*time|time|at)\s*[:=\-–]\s*(.*)$',
    caseSensitive: false,
  );

  /// Builds one item from a line's text, or null for "None" and friends.
  static SummaryItem? _item(SummarySection section, String text, {required bool done}) {
    var body = _stripMarkdown(text);
    if (body.isEmpty || _isNothing(body) || _isSignOff(body)) return null;

    final List<String> firstCut;
    if (body.contains('|')) {
      firstCut = body.split('|');
    } else if (body.contains(' · ')) {
      firstCut = body.split(' · ');
    } else {
      firstCut = <String>[body];
    }
    // "Task — Who asked: Priya — Due: Friday — 09:14": dashes separate fields
    // only when what follows them is a labelled field or a time; otherwise a
    // dash is part of the sentence.
    var cells = <String>[
      for (final cell in firstCut)
        if (RegExp(r' [—–-] ').hasMatch(cell) &&
            cell.split(RegExp(r' [—–-] ')).skip(1).any(
                  (c) => _labelPattern.hasMatch(c.trim()) || NoteTime.tryParse(c) != null,
                ))
          ...cell.split(RegExp(r' [—–-] '))
        else
          cell,
    ];
    cells = cells.map((c) => c.trim()).where((c) => c.isNotEmpty).toList();
    if (cells.isEmpty) return null;

    String? who;
    String? due;
    NoteTime? time;
    final plain = <String>[];
    for (final cell in cells) {
      final labelled = _labelPattern.firstMatch(cell);
      if (labelled != null && plain.isNotEmpty) {
        final label = labelled.group(1)!.toLowerCase().replaceAll(RegExp(r'\s+'), '');
        final value = labelled.group(2)!.trim();
        if (label.contains('time') || label == 'at') {
          time ??= NoteTime.tryParse(value);
        } else if (label.startsWith('due') || label == 'deadline' || label == 'when' || label == 'by') {
          due ??= _value(value);
        } else {
          who ??= _value(value);
        }
        continue;
      }
      final asTime = NoteTime.tryParse(cell);
      if (asTime != null && plain.isNotEmpty) {
        time ??= asTime;
        continue;
      }
      plain.add(cell);
    }
    if (plain.isEmpty) return null;

    var main = plain.first;
    // "Design files (Priya, 10:58)" - a trailing group of short fields.
    final group = RegExp(r'^(.*?)\s*\(([^()]{1,60})\)\s*$').firstMatch(main);
    if (group != null && (section == SummarySection.todos || section == SummarySection.waiting)) {
      final inner = group.group(2)!.split(RegExp(r'[,;·]')).map((s) => s.trim()).toList();
      final innerTime = inner.map(NoteTime.tryParse).whereType<NoteTime>().firstOrNull;
      if (innerTime != null || inner.length > 1) {
        main = group.group(1)!.trim();
        time ??= innerTime;
        final others = inner.where((s) => NoteTime.tryParse(s) == null).toList();
        if (others.isNotEmpty) who ??= _value(others.first);
        if (others.length > 1) due ??= _value(others[1]);
      }
    }
    if (time == null) {
      final trailing = NoteTime.trailingIn(main);
      if (trailing != null && trailing.$1.isNotEmpty) {
        main = trailing.$1;
        time = trailing.$2;
      }
    }
    main = main.replaceFirst(RegExp(r'[\s,;:—–-]+$'), '').trim();
    if (main.isEmpty || _isNothing(main)) return null;

    final hasFields = section == SummarySection.todos || section == SummarySection.waiting;
    if (hasFields) {
      final rest = plain.skip(1).toList();
      if (rest.isNotEmpty) who ??= _value(rest[0]);
      if (rest.length > 1) due ??= _value(rest[1]);
    } else if (plain.length > 1 && who == null) {
      // "Priya | design files" under People: keep all of it as the text.
      main = plain.join(' · ');
    }
    return SummaryItem(
      text: main,
      who: hasFields ? who : null,
      due: hasFields ? due : null,
      noteTime: time,
      done: section == SummarySection.todos && done,
    );
  }

  static String _stripMarkdown(String text) => text
      .replaceAll(RegExp(r'(\*\*|__|`)'), '')
      .replaceAll(RegExp(r'(?<![\p{L}\p{N}])[*_](?=\S)|(?<=\S)[*_](?![\p{L}\p{N}])', unicode: true), '')
      .replaceAll(RegExp(r'~~(.*?)~~'), r'$1')
      .trim();

  static const Set<String> _nothing = <String>{
    'none', 'nothing', 'n a', 'na', 'nil', 'not mentioned', 'none mentioned',
    'none identified', 'nothing yet', 'no items', 'not applicable', 'unknown',
  };

  static bool _isSignOff(String text) => RegExp(
        "^(let me know|hope this|i hope|feel free|if you('d| would)? like|"
        "would you like|want me to|happy to help|here is|here's)",
        caseSensitive: false,
      ).hasMatch(text);

  static bool _isNothing(String text) => _nothing.contains(SummaryItem.normalize(text));

  /// A field value, or null for the placeholders AI apps put in empty fields.
  static String? _value(String text) {
    final value = text.trim();
    if (value.isEmpty) return null;
    final normal = SummaryItem.normalize(value);
    if (normal.isEmpty || _nothing.contains(normal)) return null;
    if (<String>{'no date', 'no due date', 'not specified', 'unspecified', 'tbd', 'unclear', 'not given'}
        .contains(normal)) {
      return null;
    }
    return value;
  }
}
