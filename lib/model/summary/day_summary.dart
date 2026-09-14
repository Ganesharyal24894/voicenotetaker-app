/// What an AI made of a stretch of notes: the model the Today tab renders.
///
/// PURE data, JSON in and out. DESIGNED FOR TWO WRITERS: today it is filled by
/// pasting an AI app's reply (`SummarySource.pasted`); an AI running inside
/// the app later writes exactly the same shape with
/// `SummarySource.automatic`, and nothing that reads it changes.
library;

import 'note_time.dart';
import 'summary_range.dart';

/// Who produced a summary.
enum SummarySource {
  /// The user pasted an AI app's reply.
  pasted,

  /// Made on the phone without a round trip. Not produced yet.
  automatic,
}

/// The reply headings, in the order the prompt asks for them.
enum SummarySection {
  summary('Summary'),
  todos('To-dos'),
  workDone('Work done'),
  decisions('Decisions'),
  waiting('Waiting on others'),
  people('People'),
  ideas('Ideas'),
  openQuestions('Open questions'),
  patterns('Patterns');

  const SummarySection(this.heading);

  /// The heading the prompt asks the AI to use.
  final String heading;

  static SummarySection? byName(Object? name) {
    for (final section in values) {
      if (section.name == name) return section;
    }
    return null;
  }
}

/// One line under a heading. Only [text] is always there; to-dos and waiting
/// items may carry who, when it is due and the note time.
class SummaryItem {
  const SummaryItem({
    required this.text,
    this.who,
    this.due,
    this.noteTime,
    this.done = false,
  });

  final String text;
  final String? who;
  final String? due;
  final NoteTime? noteTime;

  /// Ticked. Meaningful for to-dos only.
  final bool done;

  SummaryItem copyWith({bool? done}) => SummaryItem(
        text: text,
        who: who,
        due: due,
        noteTime: noteTime,
        done: done ?? this.done,
      );

  /// What identifies a to-do across two replies about the same day: its words,
  /// ignoring case, punctuation and spacing, plus the note time it came from.
  /// A newer reply that rewords a task slightly is a new task - guessing
  /// otherwise would tick things the user never ticked.
  String get key => '${normalize(text)}@${noteTime?.clock ?? ''}';

  static String normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        if (who != null) 'who': who,
        if (due != null) 'due': due,
        if (noteTime != null) 'noteTime': noteTime!.label,
        if (done) 'done': true,
      };

  static SummaryItem? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final text = json['text'];
    if (text is! String) return null;
    final who = json['who'];
    final due = json['due'];
    final time = json['noteTime'];
    return SummaryItem(
      text: text,
      who: who is String ? who : null,
      due: due is String ? due : null,
      noteTime: time is String ? NoteTime.tryParse(time) : null,
      done: json['done'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SummaryItem &&
      other.text == text &&
      other.who == who &&
      other.due == due &&
      other.noteTime == noteTime &&
      other.done == done;

  @override
  int get hashCode => Object.hash(text, who, due, noteTime, done);

  @override
  String toString() =>
      'SummaryItem($text | $who | $due | ${noteTime?.label}${done ? ' | done' : ''})';
}

/// A whole summary.
class DaySummary {
  const DaySummary({
    required this.source,
    required this.createdAt,
    required this.range,
    required this.window,
    required this.sections,
  });

  static const int formatVersion = 1;

  final SummarySource source;
  final DateTime createdAt;
  final SummaryRange range;

  /// The notes it covers; note-time chips are matched inside this.
  final DayWindow window;

  /// Only headings that had something under them.
  final Map<SummarySection, List<SummaryItem>> sections;

  List<SummaryItem> itemsOf(SummarySection section) =>
      sections[section] ?? const <SummaryItem>[];

  List<SummaryItem> get todos => itemsOf(SummarySection.todos);

  bool get isEmpty => sections.values.every((items) => items.isEmpty);

  /// Made on an earlier calendar day than [now].
  bool isStaleAt(DateTime now) =>
      DayWindow.midnight(createdAt).isBefore(DayWindow.midnight(now));

  /// A copy with each to-do's tick taken from [doneKeys].
  DaySummary withTicks(Set<String> doneKeys) => DaySummary(
        source: source,
        createdAt: createdAt,
        range: range,
        window: window,
        sections: <SummarySection, List<SummaryItem>>{
          for (final entry in sections.entries)
            entry.key: entry.key == SummarySection.todos
                ? <SummaryItem>[
                    for (final item in entry.value)
                      item.copyWith(done: doneKeys.contains(item.key)),
                  ]
                : entry.value,
        },
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': formatVersion,
        'source': source.name,
        'createdAt': createdAt.toIso8601String(),
        'range': range.name,
        'windowStart': window.start.toIso8601String(),
        'windowEnd': window.end.toIso8601String(),
        'sections': <String, Object?>{
          for (final entry in sections.entries)
            entry.key.name: <Object?>[
              for (final item in entry.value) item.toJson(),
            ],
        },
      };

  /// The summary in [json], or null when this build cannot read it. Never
  /// throws.
  static DaySummary? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    if (json['version'] != formatVersion) return null;
    final source = switch (json['source']) {
      'pasted' => SummarySource.pasted,
      'automatic' => SummarySource.automatic,
      _ => null,
    };
    final range = SummaryRange.byName(json['range']);
    final created = DateTime.tryParse('${json['createdAt']}');
    final start = DateTime.tryParse('${json['windowStart']}');
    final end = DateTime.tryParse('${json['windowEnd']}');
    final rawSections = json['sections'];
    if (source == null ||
        range == null ||
        created == null ||
        start == null ||
        end == null ||
        rawSections is! Map<String, Object?>) {
      return null;
    }
    final sections = <SummarySection, List<SummaryItem>>{};
    for (final entry in rawSections.entries) {
      final section = SummarySection.byName(entry.key);
      final rawItems = entry.value;
      if (section == null || rawItems is! List<Object?>) continue;
      sections[section] = <SummaryItem>[
        for (final raw in rawItems) ?SummaryItem.fromJson(raw),
      ];
    }
    return DaySummary(
      source: source,
      createdAt: created,
      range: range,
      window: DayWindow(start, end),
      sections: sections,
    );
  }
}
