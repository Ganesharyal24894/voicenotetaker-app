/// Which recording a note-time chip opens.
///
/// PURE. An AI quotes the time a note STARTED most of the time, sometimes a
/// moment inside it, and sometimes gets it a few minutes wrong. So: a note
/// that contains the time wins; otherwise the nearest note, as long as it is
/// within [NoteTimeMatcher.maxDistance] - further than that, the chip points
/// at nothing rather than at a note that has nothing to do with the item.
library;

import '../recording_info.dart';
import 'note_time.dart';
import 'summary_range.dart';

abstract final class NoteTimeMatcher {
  static const Duration maxDistance = Duration(hours: 3);

  static RecordingInfo? match({
    required NoteTime time,
    required DayWindow window,
    required List<RecordingInfo> recordings,
  }) {
    final candidates =
        recordings.where((r) => window.contains(r.recordedAt)).toList();
    if (candidates.isEmpty) return null;

    final targets = <DateTime>[
      for (final day in window.days)
        if (_dayMatches(time, day))
          DateTime(day.year, day.month, day.day, time.hour, time.minute),
    ];
    if (targets.isEmpty) return null;

    RecordingInfo? best;
    Duration? bestDistance;
    for (final recording in candidates) {
      final start = recording.recordedAt;
      // A minute of grace: "09:14" for a note that started at 09:14:40.
      final end = start
          .add(recording.duration ?? Duration.zero)
          .add(const Duration(minutes: 1));
      for (final target in targets) {
        final Duration distance;
        final grace = target.add(const Duration(minutes: 1));
        if (!grace.isBefore(start) && !target.isAfter(end)) {
          distance = Duration.zero;
        } else if (target.isBefore(start)) {
          distance = start.difference(target);
        } else {
          distance = target.difference(end);
        }
        final better = bestDistance == null ||
            distance < bestDistance ||
            // A tie goes to the more recent note.
            (distance == bestDistance && start.isAfter(best!.recordedAt));
        if (better) {
          best = recording;
          bestDistance = distance;
        }
      }
    }
    if (bestDistance == null || bestDistance > maxDistance) return null;
    return best;
  }

  static bool _dayMatches(NoteTime time, DateTime day) {
    if (time.day != null && time.month != null) {
      return day.day == time.day && day.month == time.month;
    }
    if (time.weekday != null) return day.weekday == time.weekday;
    return true;
  }
}
