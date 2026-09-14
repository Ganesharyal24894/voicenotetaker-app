import '../model/battery_history.dart';
import '../model/battery_report.dart';
import 'format.dart';

/// Every string the Diagnostics battery cards show, as pure functions.
///
/// Kept apart from the widgets so each wording is tested once, and so the
/// rules about honesty - an approximate time is said to be approximate, an
/// estimate with too little behind it is not shown - live in one place.
abstract final class BatteryCopy {
  static const String notConnected = 'Connect your recorder to see its battery.';
  static const String notSupported = 'Update your recorder to see battery history.';
  static const String unreadable = "Update the app to read this recorder's battery history.";
  static const String reading = 'Reading…';
  static const String notEnoughData = 'Not enough data yet';
  static const String footnote =
      'Estimate improves after a full discharge. Percent is estimated from voltage.';
  static const String partlyRecorded = 'Some of this charge was not recorded.';
  static const String info =
      'The recorder has no clock. Each time it connects, your phone notes the '
      'time, and that is how these times are worked out - so they get better '
      'the more often it connects.\n\n'
      'Percent is estimated from the battery voltage, so it moves in steps and '
      'reads a little high just after unplugging.';

  /// `1 d 2 h`, `14 h`, `40 m` - a rough span, largest two units at most.
  static String roughSpan(Duration d) {
    final minutes = d.inMinutes.abs();
    final days = minutes ~/ (24 * 60);
    final hours = (minutes % (24 * 60)) ~/ 60;
    if (days > 0) return hours == 0 ? '$days d' : '$days d $hours h';
    if (hours > 0) return '$hours h';
    return minutes < 1 ? 'under 1 m' : '$minutes m';
  }

  /// `9 h 20 m`, `45 m` - hours and minutes, for awake time.
  static String hoursMinutes(Duration d) {
    final minutes = d.inMinutes.abs();
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (hours == 0) return '$rest m';
    return rest == 0 ? '$hours h' : '$hours h $rest m';
  }

  /// `Mon 23:50` inside the last week, `11 Sep 23:50` before it.
  static String when(DateTime utc, DateTime now) {
    final local = utc.toLocal();
    final day = Fmt.day(local, now: now.toLocal());
    return '$day ${Fmt.timeOfDay(local)}';
  }

  /// `11 Sep 21:30`, always with the date - for the past charges list.
  static String date(DateTime utc) {
    final local = utc.toLocal();
    // A date far enough back that `Fmt.day` always answers with day + month.
    final day = Fmt.day(local, now: local.add(const Duration(days: 30)));
    return '$day ${Fmt.timeOfDay(local)}';
  }

  /// `62%`, or `—` when the recorder had no reading.
  static String percent(int? value) => value == null ? '—' : '$value%';

  /// What follows the percentage: ` · on battery for 14 h`, ` · charging`.
  static String headlineDetail(BatteryReport report) {
    if (!report.onBattery) return report.charging ? ' · charging' : ' · plugged in';
    final since = report.onBatteryFor;
    if (since == null) return ' · on battery';
    return report.unplugApproximate
        ? ' · on battery for at least ${roughSpan(since)}'
        : ' · on battery for ${roughSpan(since)}';
  }

  /// The Unplugged row: `96% · Mon 23:50`, `96% · Mon 20:10–23:50`,
  /// `96% · before Mon 23:50`. Null when there is nothing to say.
  static String? unplugged(BatteryReport report, DateTime now) {
    final range = report.unplugged;
    final pct = report.percentAtUnplug;
    String? time;
    if (range != null) {
      if (range.exact) {
        time = when(range.middle, now);
      } else if (range.latestOnly) {
        time = 'before ${when(range.latest, now)}';
      } else {
        time = '${when(range.earliest, now)}–${Fmt.timeOfDay(range.latest.toLocal())}';
        if (range.earliest.toLocal().day != range.latest.toLocal().day) {
          time = '${when(range.earliest, now)} – ${when(range.latest, now)}';
        }
      }
    }
    if (time == null && pct == null) return null;
    if (time == null) return '$pct%';
    if (pct == null) return time;
    return '$pct% · $time';
  }

  /// The Estimated runtime row: `~1 d 2 h at this rate`, or not enough data.
  static String estimate(BatteryReport report) {
    final estimate = report.estimate;
    if (estimate == null) return notEnoughData;
    return '~${roughSpan(estimate.remaining)} at this rate';
  }

  /// The chart's left and right labels: `Mon 23:50 · 96%`, `Now · 62%`.
  static String chartLabel(BatteryPoint point, DateTime now) {
    final isNow = now.difference(point.at).abs() <= const Duration(minutes: 2);
    return '${isNow ? 'Now' : when(point.at, now)} · ${point.percent}%';
  }

  /// A past charge's first line: `11 Sep 21:30 → 13 Sep 08:40`.
  static String sessionTitle(PastSession session) {
    final start = session.start;
    final end = session.end;
    if (start == null && end == null) return 'Time not known';
    String side(TimeRange? range) {
      if (range == null) return '…';
      final text = date(range.middle);
      return range.exact ? text : '~$text';
    }

    return '${side(start)} → ${side(end)}';
  }

  /// A past charge's second line:
  /// `96% → 12% · 1 d 11 h · awake 9 h 20 m · 41 sleeps`.
  static String sessionMeta(PastSession session) {
    final parts = <String>[
      if (session.startPercent != null || session.endPercent != null)
        '${percent(session.startPercent)} → ${percent(session.endPercent)}',
      if (session.onBattery != null) roughSpan(session.onBattery!),
      'awake ${hoursMinutes(session.awake)}',
      '${session.sleeps} ${session.sleeps == 1 ? 'sleep' : 'sleeps'}',
      if (session.lowTrust) 'partly recorded',
    ];
    return parts.join(' · ');
  }

  /// The pill beside a past charge, or null for an ordinary one.
  static String? sessionPill(PastSession session) => switch (session.endReason) {
        SessionEndReason.empty => 'Ran flat',
        SessionEndReason.powerLost => 'Power lost',
        _ => null,
      };
}
