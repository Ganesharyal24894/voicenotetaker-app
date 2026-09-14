import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/battery_history.dart';
import 'package:voicenotetaker_app/model/battery_report.dart';
import 'package:voicenotetaker_app/view/battery_card.dart';
import 'package:voicenotetaker_app/view/battery_copy.dart';

import '../battery_history_bytes.dart';
import 'harness.dart';

/// The Diagnostics battery cards - `BatteryHistory.dc.html` - and their copy.
void main() {
  setUpAll(registerViewFallbacks);

  // Local times, so the strings do not depend on the machine's time zone.
  final now = DateTime(2026, 9, 17, 13, 50).toUtc(); // a Thursday
  final unplug = DateTime(2026, 9, 15, 23, 50).toUtc(); // Tuesday

  BatteryReport report({
    RuntimeEstimate? estimate,
    TimeRange? unplugged,
    bool lowTrust = false,
    List<PastSession> sessions = const <PastSession>[],
  }) =>
      BatteryReport(
        onBattery: true,
        charging: false,
        currentPercent: 62,
        percentAtUnplug: 96,
        unplugged: unplugged ?? TimeRange(unplug, unplug),
        onBatteryFor: const Duration(hours: 14),
        chart: <BatteryPoint>[BatteryPoint(unplug, 96), BatteryPoint(now, 62)],
        estimate: estimate,
        lowTrust: lowTrust,
        sessions: sessions,
      );

  group('BatteryCopy', () {
    test('spans read like the canvas', () {
      expect(BatteryCopy.roughSpan(const Duration(hours: 14)), '14 h');
      expect(BatteryCopy.roughSpan(const Duration(hours: 26, minutes: 30)), '1 d 2 h');
      expect(BatteryCopy.roughSpan(const Duration(minutes: 40)), '40 m');
      expect(BatteryCopy.hoursMinutes(const Duration(hours: 9, minutes: 20)), '9 h 20 m');
    });

    test('headline: time on battery, "at least" when the unplug is a range', () {
      expect(BatteryCopy.headlineDetail(report()), ' · on battery for 14 h');
      expect(
        BatteryCopy.headlineDetail(report(
          unplugged: TimeRange(unplug.subtract(const Duration(hours: 2)), unplug),
        )),
        ' · on battery for at least 14 h',
      );
    });

    test('unplugged: exact, range, or only "before"', () {
      expect(BatteryCopy.unplugged(report(), now), '96% · Tue 23:50');
      expect(
        BatteryCopy.unplugged(
          report(unplugged: TimeRange(unplug.subtract(const Duration(hours: 3)), unplug)),
          now,
        ),
        '96% · Tue 20:50–23:50',
      );
      expect(
        BatteryCopy.unplugged(
          report(unplugged: TimeRange(unplug, unplug, latestOnly: true)),
          now,
        ),
        '96% · before Tue 23:50',
      );
    });

    test('an estimate only with enough behind it', () {
      expect(BatteryCopy.estimate(report()), 'Not enough data yet');
      expect(
        BatteryCopy.estimate(report(
          estimate: const RuntimeEstimate(
            remaining: Duration(hours: 26, minutes: 10),
            fullRuntime: Duration(hours: 40),
            pointsUsed: 34,
          ),
        )),
        '~1 d 2 h at this rate',
      );
    });

    test('past charges: dates, percentages, awake time, sleeps, and trust', () {
      final session = PastSession(
        sessionId: 5,
        endReason: SessionEndReason.empty,
        start: TimeRange(DateTime(2026, 9, 9, 22, 10).toUtc(), DateTime(2026, 9, 9, 22, 10).toUtc()),
        end: TimeRange(DateTime(2026, 9, 11, 7, 50).toUtc(), DateTime(2026, 9, 11, 7, 50).toUtc()),
        onBattery: const Duration(hours: 33, minutes: 40),
        startPercent: 95,
        endPercent: 0,
        awake: const Duration(hours: 11, minutes: 5),
        sleeps: 36,
        lowTrust: false,
      );
      expect(BatteryCopy.sessionTitle(session), '9 Sep 22:10 → 11 Sep 07:50');
      expect(BatteryCopy.sessionMeta(session), '95% → 0% · 1 d 9 h · awake 11 h 5 m · 36 sleeps');
      expect(BatteryCopy.sessionPill(session), 'Ran flat');

      const unknown = PastSession(
        sessionId: 4,
        endReason: SessionEndReason.powerLost,
        start: null,
        end: null,
        onBattery: null,
        startPercent: null,
        endPercent: 40,
        awake: Duration(minutes: 45),
        sleeps: 1,
        lowTrust: true,
      );
      expect(BatteryCopy.sessionTitle(unknown), 'Time not known');
      expect(BatteryCopy.sessionMeta(unknown), '— → 40% · awake 45 m · 1 sleep · partly recorded');
      expect(BatteryCopy.sessionPill(unknown), 'Power lost');
    });
  });

  group('BatteryCard', () {
    testWidgets('not connected says so', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await pumpScreen(tester, Scaffold(body: BatteryCard(controller: harness.controller)));
      expect(find.text(BatteryCopy.notConnected), findsOneWidget);
    });

    testWidgets('older firmware says to update the recorder', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      await harness.connect(tester);
      await pumpScreen(tester, Scaffold(body: BatteryCard(controller: harness.controller)));
      expect(find.text(BatteryCopy.notSupported), findsOneWidget);
    });

    testWidgets('a recorder on battery: headline, rows and the footnote',
        (tester) async {
      final harness = ViewHarness(clock: () => now);
      addTearDown(harness.dispose);
      when(() => harness.transport.readBatteryHistory(any())).thenAnswer(
        (_) async => (HistoryBytes()
              ..current.addAll(HistoryBytes.onBattery(awake: 14 * 3600)))
            .build(),
      );
      await harness.connect(tester);
      await pumpScreen(
        tester,
        Scaffold(body: BatteryCard(controller: harness.controller, now: now)),
      );

      expect(find.textContaining('62%'), findsWidgets);
      expect(find.text('Unplugged'), findsOneWidget);
      expect(find.text('Estimated runtime'), findsOneWidget);
      expect(find.text(BatteryCopy.footnote), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('last charges list marks a flat battery', (tester) async {
      final session = PastSession(
        sessionId: 5,
        endReason: SessionEndReason.empty,
        start: TimeRange(unplug, unplug),
        end: TimeRange(now, now),
        onBattery: const Duration(hours: 14),
        startPercent: 95,
        endPercent: 0,
        awake: const Duration(hours: 3),
        sleeps: 2,
        lowTrust: false,
      );
      await pumpScreen(
        tester,
        Scaffold(body: LastChargesCard(sessions: <PastSession>[session, session])),
      );
      expect(find.text('LAST CHARGES'), findsOneWidget);
      expect(find.text('Ran flat'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
