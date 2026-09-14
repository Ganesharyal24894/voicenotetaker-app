import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/summary/summary_range.dart';

void main() {
  final now = DateTime(2026, 9, 15, 0, 5);

  test('Today and Yesterday are local calendar days, not the last 24 hours', () {
    expect(SummaryRange.today.windowAt(now),
        DayWindow(DateTime(2026, 9, 15), DateTime(2026, 9, 16)));
    expect(SummaryRange.yesterday.windowAt(now),
        DayWindow(DateTime(2026, 9, 14), DateTime(2026, 9, 15)));
    expect(SummaryRange.today.windowAt(now).contains(DateTime(2026, 9, 14, 23, 59)), isFalse);
  });

  test('7 and 30 days include today', () {
    final week = SummaryRange.last7Days.windowAt(now);
    expect(week.start, DateTime(2026, 9, 9));
    expect(week.end, DateTime(2026, 9, 16));
    expect(week.days, hasLength(7));
    final month = SummaryRange.last30Days.windowAt(now);
    expect(month.start, DateTime(2026, 8, 17));
    expect(month.days, hasLength(30));
  });

  test('windows are half-open', () {
    final today = SummaryRange.today.windowAt(now);
    expect(today.contains(DateTime(2026, 9, 15)), isTrue);
    expect(today.contains(DateTime(2026, 9, 16)), isFalse);
  });

  test('labels, names and patterns', () {
    expect(SummaryRange.values.map((r) => r.label), <String>['Today', 'Yesterday', '7 days', '30 days']);
    expect(SummaryRange.byName('last7Days'), SummaryRange.last7Days);
    expect(SummaryRange.byName('nope'), isNull);
    expect(SummaryRange.today.asksForPatterns, isFalse);
    expect(SummaryRange.last30Days.asksForPatterns, isTrue);
  });
}
