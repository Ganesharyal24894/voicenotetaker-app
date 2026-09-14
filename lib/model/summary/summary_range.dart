/// Which stretch of notes a summary covers.
///
/// PURE: no clock of its own. Every window is built from a `now` the caller
/// passes, in LOCAL calendar days - "Yesterday" is the day before today on the
/// phone's calendar, not the 24 hours before now.
library;

/// The four ranges the Summarize sheet offers.
enum SummaryRange {
  today('Today', 1),
  yesterday('Yesterday', 1),
  last7Days('7 days', 7),
  last30Days('30 days', 30);

  const SummaryRange(this.label, this.dayCount);

  /// The segment label.
  final String label;

  /// How many calendar days the window spans.
  final int dayCount;

  /// Whether the prompt asks for patterns across days. One day has none worth
  /// asking about.
  bool get asksForPatterns => dayCount > 1;

  /// The window this range covers on the day of [now].
  DayWindow windowAt(DateTime now) {
    final today = DayWindow.midnight(now);
    return switch (this) {
      SummaryRange.today => DayWindow(today, _addDays(today, 1)),
      SummaryRange.yesterday => DayWindow(_addDays(today, -1), today),
      SummaryRange.last7Days => DayWindow(_addDays(today, -6), _addDays(today, 1)),
      SummaryRange.last30Days =>
        DayWindow(_addDays(today, -29), _addDays(today, 1)),
    };
  }

  /// By name, for JSON; null for anything unknown.
  static SummaryRange? byName(Object? name) {
    for (final range in values) {
      if (range.name == name) return range;
    }
    return null;
  }

  /// Calendar arithmetic through the constructor, so a DST change inside the
  /// window cannot shift a midnight to 23:00 or 01:00.
  static DateTime _addDays(DateTime day, int days) =>
      DateTime(day.year, day.month, day.day + days);
}

/// A half-open span of local time, `[start, end)`, on day boundaries.
class DayWindow {
  const DayWindow(this.start, this.end);

  final DateTime start;
  final DateTime end;

  static DateTime midnight(DateTime at) => DateTime(at.year, at.month, at.day);

  bool contains(DateTime at) => !at.isBefore(start) && at.isBefore(end);

  /// Every calendar day in the window, oldest first.
  List<DateTime> get days {
    final result = <DateTime>[];
    var day = midnight(start);
    while (day.isBefore(end)) {
      result.add(day);
      day = DateTime(day.year, day.month, day.day + 1);
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is DayWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'DayWindow($start - $end)';
}
