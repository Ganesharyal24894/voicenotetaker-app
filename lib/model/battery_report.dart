/// What the Diagnostics battery card says, worked out from one `fe09` read and
/// the anchors the phone has kept.
///
/// PURE. This is the firmware doc's "What the app must compute", steps 2-7,
/// and nothing else: no clock of its own ([now] is passed in), no storage, no
/// strings. The card decides the words.
///
/// HONESTY OVER PRECISION, in three places:
///
///   * a time the device could not see (it slept through the unplug) is a
///     RANGE, or an upper bound, never a made-up instant;
///   * the runtime estimate is withheld until the battery has dropped
///     [BatteryReport.minPointsUsed] points - mid-curve the percentage is only
///     good to a few points, so a smaller drop is mostly noise;
///   * low-trust sessions are marked, not hidden.
library;

import 'battery_anchor.dart';
import 'battery_history.dart';

/// When something happened, as the tightest bounds the anchors allow.
class TimeRange {
  const TimeRange(this.earliest, this.latest, {this.latestOnly = false});

  final DateTime earliest;
  final DateTime latest;

  /// Only the upper bound is known: it happened at [latest] or some unknown
  /// time before. [earliest] equals [latest] then.
  final bool latestOnly;

  /// Close enough to show as one time.
  bool get exact =>
      !latestOnly && latest.difference(earliest) <= const Duration(minutes: 2);

  DateTime get middle => earliest.add(latest.difference(earliest) ~/ 2);

  Duration get width => latest.difference(earliest);

  @override
  bool operator ==(Object other) =>
      other is TimeRange &&
      other.earliest == earliest &&
      other.latest == latest &&
      other.latestOnly == latestOnly;

  @override
  int get hashCode => Object.hash(earliest, latest, latestOnly);

  @override
  String toString() => 'TimeRange($earliest .. $latest'
      '${latestOnly ? ', latest only' : ''})';
}

/// One point on the current session's line.
class BatteryPoint {
  const BatteryPoint(this.at, this.percent);

  final DateTime at;
  final int percent;
}

/// Runtime extrapolated from this session's drain so far.
class RuntimeEstimate {
  const RuntimeEstimate({
    required this.remaining,
    required this.fullRuntime,
    required this.pointsUsed,
  });

  /// From the last reading to 0 %.
  final Duration remaining;

  /// From the unplug to 0 %.
  final Duration fullRuntime;

  /// Percentage points dropped since the unplug.
  final int pointsUsed;
}

/// One completed discharge session from the recorder's ring.
class PastSession {
  const PastSession({
    required this.sessionId,
    required this.endReason,
    required this.start,
    required this.end,
    required this.onBattery,
    required this.startPercent,
    required this.endPercent,
    required this.awake,
    required this.sleeps,
    required this.lowTrust,
  });

  final int sessionId;
  final SessionEndReason endReason;

  /// Unplug; null when the phone never read the history during the session.
  final TimeRange? start;

  /// Plug-in or power loss; null when it cannot be placed.
  final TimeRange? end;

  /// Wall time on battery, from the middles of [start] and [end].
  final Duration? onBattery;

  /// Settled % at unplug; null when it was never settled.
  final int? startPercent;
  final int? endPercent;
  final Duration awake;
  final int sleeps;
  final bool lowTrust;
}

class BatteryReport {
  const BatteryReport({
    required this.onBattery,
    required this.charging,
    required this.currentPercent,
    required this.percentAtUnplug,
    required this.unplugged,
    required this.onBatteryFor,
    required this.chart,
    required this.estimate,
    required this.lowTrust,
    required this.sessions,
  });

  /// Points the battery must have dropped before an estimate is shown.
  static const int minPointsUsed = 10;

  /// A range wider than this share of the time on battery makes the estimate
  /// more guess than measurement.
  static const double maxUnplugUncertainty = 0.25;

  final bool onBattery;
  final bool charging;
  final int? currentPercent;

  /// Settled % at unplug only - never the charger-held edge reading.
  final int? percentAtUnplug;

  final TimeRange? unplugged;

  /// True when [unplugged] is not one exact time.
  bool get unplugApproximate => unplugged != null && !unplugged!.exact;

  /// From the latest possible unplug to now: a lower bound when approximate.
  final Duration? onBatteryFor;

  /// The current session, oldest first. Empty off battery.
  final List<BatteryPoint> chart;

  final RuntimeEstimate? estimate;

  /// The open record's counters under-report or its history is discontinuous.
  final bool lowTrust;

  /// Newest first.
  final List<PastSession> sessions;

  static BatteryReport compute({
    required BatteryHistory history,
    required List<BatteryAnchor> anchors,
    required DateTime now,
  }) {
    final current = history.current;
    final sorted = <BatteryAnchor>[...anchors]
      ..sort((a, b) => a.utc.compareTo(b.utc));
    final pastSessions = List<PastSession>.unmodifiable(<PastSession>[
      for (final session in history.sessions) _past(session, sorted),
    ]);
    final lowTrust = current.flags & BatteryHistoryFlags.lowTrustMask != 0;

    if (current.state != BatteryHistoryState.onBattery) {
      return BatteryReport(
        onBattery: false,
        charging: history.charging,
        currentPercent: current.lastPercent,
        percentAtUnplug: null,
        unplugged: null,
        onBatteryFor: null,
        chart: const <BatteryPoint>[],
        estimate: null,
        lowTrust: lowTrust,
        sessions: pastSessions,
      );
    }

    // The read being reported is an anchor too, whether or not the caller has
    // stored it yet.
    final alreadyStored = sorted.any(
      (a) =>
          a.state == BatteryHistoryState.onBattery &&
          a.sessionId == current.sessionId &&
          a.awakeSeconds == current.awakeSeconds &&
          a.boots == current.boots,
    );
    if (!alreadyStored) {
      sorted
        ..add(BatteryAnchor.fromHistory(history, now))
        ..sort((a, b) => a.utc.compareTo(b.utc));
    }

    final id = current.sessionId;
    final unplugged = _startOf(id, sorted);
    final percentAtUnplug = current.has(BatteryHistoryFlags.startSettled)
        ? current.startPercent
        : null;
    final onSession = <BatteryAnchor>[
      for (final a in sorted)
        if (a.state == BatteryHistoryState.onBattery && a.sessionId == id) a,
    ];

    final chart = <BatteryPoint>[
      if (unplugged != null && percentAtUnplug != null)
        BatteryPoint(unplugged.middle, percentAtUnplug),
      for (final a in onSession)
        if (a.lastPercent != null) BatteryPoint(a.utc, a.lastPercent!),
    ]..sort((a, b) => a.at.compareTo(b.at));

    BatteryAnchor? last;
    for (final a in onSession) {
      if (a.lastPercent != null) last = a;
    }

    RuntimeEstimate? estimate;
    if (last != null &&
        percentAtUnplug != null &&
        unplugged != null &&
        !unplugged.latestOnly) {
      final used = percentAtUnplug - last.lastPercent!;
      final wall = last.utc.difference(unplugged.middle);
      if (used >= minPointsUsed &&
          wall > Duration.zero &&
          unplugged.width.inSeconds <= wall.inSeconds * maxUnplugUncertainty) {
        estimate = RuntimeEstimate(
          remaining: wall * (last.lastPercent! / used),
          fullRuntime: wall * (percentAtUnplug / used),
          pointsUsed: used,
        );
      }
    }

    final since = unplugged == null ? null : now.difference(unplugged.latest);
    return BatteryReport(
      onBattery: true,
      charging: history.charging,
      currentPercent: current.lastPercent,
      percentAtUnplug: percentAtUnplug,
      unplugged: unplugged,
      onBatteryFor: since == null || since.isNegative ? null : since,
      chart: List<BatteryPoint>.unmodifiable(chart),
      estimate: estimate,
      lowTrust: lowTrust,
      sessions: pastSessions,
    );
  }

  /// Step 2: when session [id] began.
  static TimeRange? _startOf(int id, List<BatteryAnchor> sorted) {
    BatteryAnchor? first;
    for (final a in sorted) {
      if (a.state == BatteryHistoryState.onBattery && a.sessionId == id) {
        first = a;
        break;
      }
    }
    if (first == null) return null;
    final upper = first.utc.subtract(Duration(seconds: first.awakeSeconds));
    if (first.sleeps == 0 &&
        first.boots == 0 &&
        !first.has(BatteryHistoryFlags.startUnseen)) {
      return TimeRange(upper, upper);
    }
    DateTime? lower;
    for (final a in sorted) {
      if (!a.utc.isBefore(first.utc)) break;
      if (a.state == BatteryHistoryState.external || a.sessionId < id) {
        lower = a.utc;
      }
    }
    if (lower != null && !lower.isAfter(upper)) return TimeRange(lower, upper);
    return TimeRange(upper, upper, latestOnly: true);
  }

  /// Step 3: when session [id] ended - between its last on-battery anchor and
  /// the first later anchor that shows it over.
  static TimeRange? _endOf(int id, List<BatteryAnchor> sorted) {
    BatteryAnchor? lastOn;
    for (final a in sorted) {
      if (a.state == BatteryHistoryState.onBattery && a.sessionId == id) {
        lastOn = a;
      }
    }
    if (lastOn == null) return null;
    BatteryAnchor? next;
    for (final a in sorted) {
      if (!a.utc.isAfter(lastOn.utc)) continue;
      final over = (a.state == BatteryHistoryState.external && a.sessionId >= id) ||
          a.sessionId > id;
      if (over) {
        next = a;
        break;
      }
    }
    if (next == null) return null;
    // Awake seconds are a lower bound on time since the edge that began the
    // later state, so its edge - and the end before it - is no later than this.
    final upper = next.utc.subtract(Duration(seconds: next.awakeSeconds));
    if (next.state == BatteryHistoryState.external &&
        next.sleeps == 0 &&
        next.boots == 0 &&
        !next.has(BatteryHistoryFlags.startUnseen)) {
      return TimeRange(upper, upper);
    }
    if (!lastOn.utc.isAfter(upper)) return TimeRange(lastOn.utc, upper);
    return TimeRange(upper, upper, latestOnly: true);
  }

  static PastSession _past(
    BatteryHistorySession session,
    List<BatteryAnchor> sorted,
  ) {
    final start = _startOf(session.sessionId, sorted);
    final end = _endOf(session.sessionId, sorted);
    Duration? onBattery;
    if (start != null && end != null) {
      final wall = end.middle.difference(start.middle);
      if (!wall.isNegative) onBattery = wall;
    }
    return PastSession(
      sessionId: session.sessionId,
      endReason: session.endReason,
      start: start,
      end: end,
      onBattery: onBattery,
      startPercent: session.has(BatteryHistoryFlags.startSettled)
          ? session.startPercent
          : null,
      endPercent: session.endPercent,
      awake: Duration(seconds: session.awakeSeconds),
      sleeps: session.sleeps,
      lowTrust: session.lowTrust,
    );
  }
}
