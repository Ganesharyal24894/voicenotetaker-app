import '../../model/summary/day_summary.dart';
import '../../model/summary/prompt_builder.dart';
import '../../model/summary/summary_range.dart';
import '../format.dart';

/// The strings the Home tabs and Summarize sheets show. Presentation only.
abstract final class HomeFormat {
  static String _two(int value) => value.toString().padLeft(2, '0');

  /// `2 h 05 min`, `45 min`, `0 min` - the TODAY strip.
  static String speech(Duration d) {
    final minutes = d.inMinutes;
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60} h ${_two(minutes % 60)} min';
  }

  /// `11 min`, `under 1 min`, `2 min so far`.
  static String noteLength(Duration d, {bool writing = false}) {
    final base = PromptBuilder.minutes(d);
    return writing ? '$base so far' : base;
  }

  /// `12 notes · 1 h 20 min · about 9,800 words`.
  static String promptCount(int notes, Duration speech, int words) =>
      '${notes == 1 ? '1 note' : '$notes notes'} · '
      '${PromptBuilder.minutes(speech)} · ${PromptBuilder.aboutWords(words)}';

  /// `YOUR DAY` / `YOUR WEEK` / `YOUR MONTH` over the summary card.
  static String summaryCaption(SummaryRange range) => switch (range) {
        SummaryRange.today || SummaryRange.yesterday => 'Your day',
        SummaryRange.last7Days => 'Your week',
        SummaryRange.last30Days => 'Your month',
      };

  /// `from your AI · 18:30`, `from your AI · yesterday 18:30`,
  /// `from your AI · Mon 18:30`.
  static String provenance(DaySummary summary, DateTime now) {
    final who = switch (summary.source) {
      SummarySource.pasted => 'from your AI',
      SummarySource.automatic => 'summarized',
    };
    final at = summary.createdAt;
    final day = Fmt.day(at, now: now);
    final when = switch (day) {
      'Today' => Fmt.timeOfDay(at),
      'Yesterday' => 'yesterday ${Fmt.timeOfDay(at)}',
      _ => '$day ${Fmt.timeOfDay(at)}',
    };
    return '$who · $when';
  }

  /// The one paragraph on the summary card, from the Summary bullets.
  static String summaryParagraph(List<SummaryItem> items) => items
      .map((item) => item.text.trim())
      .where((text) => text.isNotEmpty)
      .map((text) => RegExp(r'[.!?।]$').hasMatch(text) ? text : '$text.')
      .join(' ');

  /// `Priya · tonight`, or null when the reply gave neither.
  static String? whoAndDue(SummaryItem item) {
    final parts = <String>[?item.who, ?item.due];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
