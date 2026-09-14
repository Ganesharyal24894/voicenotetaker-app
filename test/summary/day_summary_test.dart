import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/summary/day_summary.dart';
import 'package:voicenotetaker_app/model/summary/note_time.dart';
import 'package:voicenotetaker_app/model/summary/summary_range.dart';

DaySummary _summary({DateTime? createdAt}) => DaySummary(
      source: SummarySource.pasted,
      createdAt: createdAt ?? DateTime(2026, 9, 15, 18, 30),
      range: SummaryRange.today,
      window: SummaryRange.today.windowAt(DateTime(2026, 9, 15)),
      sections: const <SummarySection, List<SummaryItem>>{
        SummarySection.summary: <SummaryItem>[SummaryItem(text: 'Busy day.')],
        SummarySection.todos: <SummaryItem>[
          SummaryItem(text: 'Get staging access', who: 'You promised', due: 'today', noteTime: NoteTime(hour: 9, minute: 14)),
          SummaryItem(text: 'Book car service', done: true),
        ],
        SummarySection.waiting: <SummaryItem>[
          SummaryItem(text: 'Design files', who: 'Priya', noteTime: NoteTime(hour: 10, minute: 58, weekday: 2)),
        ],
      },
    );

void main() {
  test('JSON round trip keeps every field, source included', () {
    final original = _summary();
    final restored = DaySummary.fromJson(jsonDecode(jsonEncode(original.toJson())))!;
    expect(restored.source, SummarySource.pasted);
    expect(restored.createdAt, original.createdAt);
    expect(restored.range, SummaryRange.today);
    expect(restored.window, original.window);
    expect(restored.sections, original.sections);
  });

  test('an automatic summary is the same shape', () {
    final json = _summary().toJson()..['source'] = 'automatic';
    expect(DaySummary.fromJson(json)!.source, SummarySource.automatic);
  });

  test('damaged or foreign JSON reads as nothing, never throws', () {
    expect(DaySummary.fromJson(null), isNull);
    expect(DaySummary.fromJson('x'), isNull);
    expect(DaySummary.fromJson(<String, Object?>{'version': 99}), isNull);
    final json = _summary().toJson()..['range'] = 'fortnight';
    expect(DaySummary.fromJson(json), isNull);
    final odd = _summary().toJson()..['sections'] = <String, Object?>{'nope': <Object?>[], 'todos': <Object?>[1, <String, Object?>{'text': 'ok'}]};
    expect(DaySummary.fromJson(odd)!.todos, const <SummaryItem>[SummaryItem(text: 'ok')]);
  });

  test('a to-do key ignores case, punctuation and spacing, and includes the note time', () {
    const a = SummaryItem(text: 'Get staging access!', noteTime: NoteTime(hour: 9, minute: 14));
    const b = SummaryItem(text: '  get   STAGING access', who: 'IT', noteTime: NoteTime(hour: 9, minute: 14, weekday: 2));
    const c = SummaryItem(text: 'Get staging access', noteTime: NoteTime(hour: 10, minute: 0));
    expect(a.key, b.key);
    expect(a.key, isNot(c.key));
    expect(const SummaryItem(text: 'स्टेजिंग एक्सेस').key, isNot(const SummaryItem(text: '').key));
  });

  test('withTicks sets to-dos from the keys and leaves other sections alone', () {
    final summary = _summary();
    final ticked = summary.withTicks(<String>{summary.todos.first.key});
    expect(ticked.todos.map((t) => t.done), <bool>[true, false]);
    expect(ticked.itemsOf(SummarySection.waiting), summary.itemsOf(SummarySection.waiting));
  });

  test('stale means made on an earlier calendar day', () {
    final summary = _summary(createdAt: DateTime(2026, 9, 14, 23, 59));
    expect(summary.isStaleAt(DateTime(2026, 9, 14, 23, 59, 30)), isFalse);
    expect(summary.isStaleAt(DateTime(2026, 9, 15, 0, 1)), isTrue);
  });
}
