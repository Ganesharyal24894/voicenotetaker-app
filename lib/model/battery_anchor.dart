import 'battery_history.dart';

/// One read of `fe09`, pinned to the phone's clock.
///
/// The recorder has no wall clock, so this is the ONLY way its awake seconds
/// ever become a time of day: two anchors in the same session give the real
/// elapsed time, sleeps included. See the firmware's `doc/battery-history.md`,
/// "What the app must compute", step 1 - these are exactly the fields it lists.
class BatteryAnchor {
  const BatteryAnchor({
    required this.utc,
    required this.state,
    required this.sessionId,
    required this.awakeSeconds,
    required this.sleeps,
    required this.boots,
    required this.resets,
    required this.uptimeSeconds,
    required this.flags,
    this.lastPercent,
    this.lastMv,
    this.startPercent,
  });

  factory BatteryAnchor.fromHistory(BatteryHistory history, DateTime utc) {
    final current = history.current;
    return BatteryAnchor(
      utc: utc.toUtc(),
      state: current.state,
      sessionId: current.sessionId,
      awakeSeconds: current.awakeSeconds,
      sleeps: current.sleeps,
      boots: current.boots,
      resets: current.resets,
      uptimeSeconds: history.uptimeSeconds,
      flags: current.flags,
      lastPercent: current.lastPercent,
      lastMv: current.lastMv,
      startPercent: current.startPercent,
    );
  }

  /// Phone time of the read, UTC.
  final DateTime utc;
  final BatteryHistoryState state;
  final int sessionId;
  final int awakeSeconds;
  final int sleeps;
  final int boots;
  final int resets;
  final int uptimeSeconds;
  final int flags;
  final int? lastPercent;
  final int? lastMv;
  final int? startPercent;

  bool has(int flag) => flags & flag != 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'utcMs': utc.millisecondsSinceEpoch,
        'state': state.index,
        'sessionId': sessionId,
        'awake': awakeSeconds,
        'sleeps': sleeps,
        'boots': boots,
        'resets': resets,
        'uptime': uptimeSeconds,
        'flags': flags,
        'lastPercent': lastPercent,
        'lastMv': lastMv,
        'startPercent': startPercent,
      };

  /// Null for anything unreadable. Never throws.
  static BatteryAnchor? fromJson(Object? json) {
    if (json is! Map) return null;
    int? integer(String key) {
      final value = json[key];
      return value is int ? value : null;
    }

    final utcMs = integer('utcMs');
    final state = integer('state');
    final sessionId = integer('sessionId');
    final awake = integer('awake');
    final sleeps = integer('sleeps');
    final boots = integer('boots');
    if (utcMs == null ||
        state == null ||
        state < 0 ||
        state >= BatteryHistoryState.values.length ||
        sessionId == null ||
        awake == null ||
        sleeps == null ||
        boots == null) {
      return null;
    }
    return BatteryAnchor(
      utc: DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true),
      state: BatteryHistoryState.values[state],
      sessionId: sessionId,
      awakeSeconds: awake,
      sleeps: sleeps,
      boots: boots,
      resets: integer('resets') ?? 0,
      uptimeSeconds: integer('uptime') ?? 0,
      flags: integer('flags') ?? 0,
      lastPercent: integer('lastPercent'),
      lastMv: integer('lastMv'),
      startPercent: integer('startPercent'),
    );
  }
}
