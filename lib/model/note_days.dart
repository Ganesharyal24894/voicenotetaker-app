import 'recording_info.dart';

/// How many notes sit on each day.
///
/// This is what greys out a day in the calendar and what counts the
/// `Show 12 notes` button. It is built in ONE PASS over the library listing
/// the app already holds in memory - `AppController.recordings` - so nothing
/// here touches the filesystem and nothing stats a file. The listing object
/// changes only when the library is re-read, so a caller can hold on to an
/// index and rebuild it exactly then; see `all_notes_view.dart`.
class NoteDayIndex {
  const NoteDayIndex._(this._counts, this.total);

  /// Counts [recordings] by the local day they were recorded on.
  ///
  /// A note whose audio was deleted by the retention sweep still counts: its
  /// transcript is still a note, it is still listed under that day, and a day
  /// that only holds such notes is a day worth picking.
  factory NoteDayIndex.of(Iterable<RecordingInfo> recordings) {
    final counts = <DateTime, int>{};
    var total = 0;
    for (final recording in recordings) {
      final day = dayOf(recording.recordedAt);
      counts[day] = (counts[day] ?? 0) + 1;
      total++;
    }
    return NoteDayIndex._(counts, total);
  }

  /// No notes at all.
  static const NoteDayIndex empty = NoteDayIndex._(<DateTime, int>{}, 0);

  final Map<DateTime, int> _counts;

  /// Every note the index was built from.
  final int total;

  /// Midnight of [at]'s day - how a day is keyed everywhere here, and the one
  /// place the "which day is this note on?" question is answered.
  static DateTime dayOf(DateTime at) => DateTime(at.year, at.month, at.day);

  /// How many notes [day] holds; 0 for a day with none.
  int countFor(DateTime day) => _counts[dayOf(day)] ?? 0;

  /// Whether [day] has anything to show - a day that has not is greyed.
  bool has(DateTime day) => countFor(day) > 0;

  /// How many notes [days] hold between them - the `Show 12 notes` number.
  int countForAll(Iterable<DateTime> days) {
    var sum = 0;
    for (final day in days) {
      sum += countFor(day);
    }
    return sum;
  }

  /// Whether any day of [month]'s month has notes. False is a bare month.
  bool hasMonth(DateTime month) {
    for (final day in _counts.keys) {
      if (day.year == month.year && day.month == month.month) return true;
    }
    return false;
  }

  /// The days that have notes, newest first.
  List<DateTime> get days =>
      _counts.keys.toList()..sort((a, b) => b.compareTo(a));

  /// The newest day with notes, or null when there are none.
  DateTime? get newestDay {
    DateTime? newest;
    for (final day in _counts.keys) {
      if (newest == null || day.isAfter(newest)) newest = day;
    }
    return newest;
  }
}
