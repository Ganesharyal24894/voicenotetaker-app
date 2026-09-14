import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/battery_anchor.dart';
import 'package:voicenotetaker_app/model/battery_history.dart';
import 'package:voicenotetaker_app/model/battery_report.dart';

import 'battery_history_bytes.dart';

/// The firmware doc's "What the app must compute", against hand-worked times.
void main() {
  final unplug = DateTime.utc(2026, 9, 14, 23, 50);

  BatteryHistory history({
    int state = 1,
    int sessionId = 7,
    int awake = 3600,
    int sleeps = 0,
    int boots = 0,
    int flags = 0x0001,
    int startPercent = 96,
    int lastPercent = 62,
    bool charging = false,
    List<Map<int, (int, int)>> ring = const <Map<int, (int, int)>>[],
  }) {
    final b = HistoryBytes()
      ..nowFlags = 0x01 | (charging ? 0x06 : 0)
      ..current.addAll(HistoryBytes.onBattery(
        state: state,
        sessionId: sessionId,
        awake: awake,
        sleeps: sleeps,
        boots: boots,
        flags: flags,
        startPercent: startPercent,
        lastPercent: lastPercent,
      ));
    b.ring.addAll(ring);
    return BatteryHistory.fromBytes(b.build());
  }

  BatteryAnchor anchor(
    DateTime utc, {
    BatteryHistoryState state = BatteryHistoryState.onBattery,
    int sessionId = 7,
    required int awake,
    int sleeps = 0,
    int boots = 0,
    int flags = 0x0001,
    int? lastPercent,
  }) =>
      BatteryAnchor(
        utc: utc,
        state: state,
        sessionId: sessionId,
        awakeSeconds: awake,
        sleeps: sleeps,
        boots: boots,
        resets: 0,
        uptimeSeconds: awake,
        flags: flags,
        lastPercent: lastPercent,
        startPercent: 96,
      );

  test('an unplug seen with no sleep since is one exact time', () {
    final now = unplug.add(const Duration(hours: 14));
    final report = BatteryReport.compute(
      history: history(awake: 14 * 3600, lastPercent: 62),
      anchors: <BatteryAnchor>[
        anchor(unplug.add(const Duration(minutes: 10)), awake: 600, lastPercent: 95),
      ],
      now: now,
    );

    expect(report.onBattery, isTrue);
    expect(report.unplugged!.exact, isTrue);
    expect(report.unplugApproximate, isFalse);
    expect(report.unplugged!.latest, unplug);
    expect(report.onBatteryFor, const Duration(hours: 14));
    expect(report.percentAtUnplug, 96);
    expect(report.currentPercent, 62);
    // The settled start, the stored anchor, and this read.
    expect(report.chart.map((p) => p.percent), <int>[96, 95, 62]);
    expect(report.chart.first.at, unplug);
    expect(report.chart.last.at, now);
  });

  test('estimate: 96 % to 62 % in 14 h leaves about 25.5 h', () {
    final now = unplug.add(const Duration(hours: 14));
    final report = BatteryReport.compute(
      history: history(awake: 5 * 3600, sleeps: 30, boots: 30, lastPercent: 62),
      anchors: <BatteryAnchor>[
        anchor(unplug.add(const Duration(seconds: 90)), awake: 90, lastPercent: 96),
      ],
      now: now,
    );

    final estimate = report.estimate!;
    expect(estimate.pointsUsed, 34);
    expect(estimate.remaining.inMinutes, closeTo(14 * 60 * 62 / 34, 1));
    expect(estimate.fullRuntime.inMinutes, closeTo(14 * 60 * 96 / 34, 1));
  });

  test('fewer than ten points used: no estimate yet', () {
    final report = BatteryReport.compute(
      history: history(awake: 3600, lastPercent: 88),
      anchors: <BatteryAnchor>[],
      now: unplug.add(const Duration(hours: 1)),
    );
    expect(report.unplugged!.exact, isTrue);
    expect(report.estimate, isNull);
  });

  test('no settled start: no % at unplug and no estimate', () {
    final report = BatteryReport.compute(
      history: history(flags: 0, lastPercent: 40),
      anchors: <BatteryAnchor>[],
      now: unplug.add(const Duration(hours: 1)),
    );
    expect(report.percentAtUnplug, isNull);
    expect(report.estimate, isNull);
  });

  test('an unplug slept through is a range from the last anchor on the charger',
      () {
    final charger = DateTime.utc(2026, 9, 14, 22);
    final firstOnBattery = DateTime.utc(2026, 9, 15, 8);
    final report = BatteryReport.compute(
      history: history(awake: 7200, sleeps: 12, boots: 12, flags: 0x0003),
      anchors: <BatteryAnchor>[
        anchor(charger, state: BatteryHistoryState.external, sessionId: 6, awake: 3000),
        anchor(firstOnBattery, awake: 1800, sleeps: 10, boots: 10, flags: 0x0003),
      ],
      now: DateTime.utc(2026, 9, 15, 9),
    );

    final range = report.unplugged!;
    expect(range.exact, isFalse);
    expect(report.unplugApproximate, isTrue);
    expect(range.earliest, charger);
    expect(range.latest, firstOnBattery.subtract(const Duration(seconds: 1800)));
    expect(report.onBatteryFor, DateTime.utc(2026, 9, 15, 9).difference(range.latest));
    expect(report.estimate, isNull, reason: 'the range is far wider than a quarter of the time');
  });

  test('an unplug slept through with nothing before it is an upper bound only', () {
    final now = DateTime.utc(2026, 9, 15, 9);
    final report = BatteryReport.compute(
      history: history(awake: 1800, sleeps: 3, boots: 3, lastPercent: 20),
      anchors: <BatteryAnchor>[],
      now: now,
    );
    expect(report.unplugged!.latestOnly, isTrue);
    expect(report.unplugged!.exact, isFalse);
    expect(report.unplugged!.latest, now.subtract(const Duration(seconds: 1800)));
    expect(report.estimate, isNull);
  });

  test('on external power: nothing about a discharge', () {
    final report = BatteryReport.compute(
      history: history(state: 2, charging: true, lastPercent: 80),
      anchors: <BatteryAnchor>[anchor(unplug, awake: 10, lastPercent: 90)],
      now: unplug.add(const Duration(hours: 1)),
    );
    expect(report.onBattery, isFalse);
    expect(report.charging, isTrue);
    expect(report.currentPercent, 80);
    expect(report.unplugged, isNull);
    expect(report.percentAtUnplug, isNull);
    expect(report.chart, isEmpty);
    expect(report.estimate, isNull);
  });

  test('low-trust flags on the open record are reported', () {
    final report = BatteryReport.compute(
      history: history(flags: 0x0001 | 0x0008),
      anchors: <BatteryAnchor>[],
      now: unplug.add(const Duration(hours: 1)),
    );
    expect(report.lowTrust, isTrue);
  });

  group('past sessions', () {
    final ring = <Map<int, (int, int)>>[
      <int, (int, int)>{
        0: (4, 6),
        4: (1, 2),
        6: (2, 0x0001),
        8: (4, 33600),
        24: (2, 36),
        32: (1, 95),
        33: (1, 0),
      },
      <int, (int, int)>{0: (4, 5), 4: (1, 3), 6: (2, 0x0010), 32: (1, 90), 33: (1, 70)},
    ];

    test('placed between the anchors around them', () {
      final start = DateTime.utc(2026, 9, 9, 22, 10);
      final lastOn = DateTime.utc(2026, 9, 11, 6);
      final plugged = DateTime.utc(2026, 9, 11, 9);
      final report = BatteryReport.compute(
        history: history(ring: ring),
        anchors: <BatteryAnchor>[
          anchor(start.add(const Duration(minutes: 5)), sessionId: 6, awake: 300),
          anchor(lastOn, sessionId: 6, awake: 30000, sleeps: 30, boots: 30),
          // On the charger, seen live since plug-in.
          anchor(plugged, state: BatteryHistoryState.external, sessionId: 6, awake: 600),
        ],
        now: unplug,
      );

      final session = report.sessions.first;
      expect(session.sessionId, 6);
      expect(session.endReason, SessionEndReason.empty);
      expect(session.start!.exact, isTrue);
      expect(session.start!.latest, start);
      expect(session.end!.exact, isTrue);
      expect(session.end!.latest, plugged.subtract(const Duration(minutes: 10)));
      expect(session.onBattery, session.end!.latest.difference(start));
      expect(session.startPercent, 95);
      expect(session.endPercent, 0);
      expect(session.awake, const Duration(seconds: 33600));
      expect(session.sleeps, 36);
      expect(session.lowTrust, isFalse);
    });

    test('an end the device slept through is a range', () {
      final lastOn = DateTime.utc(2026, 9, 11, 6);
      final seen = DateTime.utc(2026, 9, 11, 9);
      final report = BatteryReport.compute(
        history: history(ring: ring),
        anchors: <BatteryAnchor>[
          anchor(lastOn, sessionId: 6, awake: 30000, sleeps: 30, boots: 30),
          anchor(seen, state: BatteryHistoryState.external, sessionId: 6, awake: 600, sleeps: 2, boots: 2),
        ],
        now: unplug,
      );
      final end = report.sessions.first.end!;
      expect(end.exact, isFalse);
      expect(end.earliest, lastOn);
      expect(end.latest, seen.subtract(const Duration(minutes: 10)));
    });

    test('a session the phone never read has no times, and keeps its flags', () {
      final report = BatteryReport.compute(
        history: history(ring: ring),
        anchors: <BatteryAnchor>[],
        now: unplug,
      );
      final older = report.sessions.last;
      expect(older.sessionId, 5);
      expect(older.endReason, SessionEndReason.powerLost);
      expect(older.start, isNull);
      expect(older.end, isNull);
      expect(older.onBattery, isNull);
      expect(older.startPercent, isNull, reason: 'not settled');
      expect(older.lowTrust, isTrue);
    });
  });
}
