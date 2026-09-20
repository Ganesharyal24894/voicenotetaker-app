import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/battery_history.dart';

import 'battery_history_bytes.dart';

/// The `fe09` decoder against the firmware's documented byte layout.
void main() {
  test('decodes the header, the open record, the last charge and the ring', () {
    final b = HistoryBytes()
      ..nowFlags = 0x0F
      ..bootResetKind = 3
      ..uptime = 0x01020304
      ..current.addAll(HistoryBytes.onBattery(sleeps: 2, boots: 3, flags: 0x0013))
      ..charge.addAll(<int, (int, int)>{
        0: (1, 1),
        2: (2, 0x0080),
        4: (4, 7),
        8: (4, 5400),
        12: (4, 5000),
        16: (4, 4800),
        20: (2, 1),
        22: (2, 2),
        24: (2, 3600),
        26: (1, 5),
        27: (1, 100),
        28: (2, 4200),
        30: (2, 9),
      })
      ..ring.add(<int, (int, int)>{
        0: (4, 6),
        4: (1, 2),
        5: (1, 99),
        6: (2, 0x0011),
        8: (4, 33600),
        12: (4, 1),
        16: (4, 2),
        20: (4, 3),
        24: (2, 36),
        26: (2, 37),
        28: (2, 1),
        30: (2, 4150),
        32: (1, 95),
        33: (1, 0),
        34: (2, 3400),
        36: (2, 3350),
      })
      ..ring.add(<int, (int, int)>{0: (4, 5), 4: (1, 3), 5: (1, 0xFF), 32: (1, 0xFF), 33: (1, 0xFF)});

    final h = BatteryHistory.fromBytes(b.build());

    expect(h.version, BatteryHistory.layoutVersion);
    expect(h.storeUsable, isTrue);
    expect(h.externalPower, isTrue);
    expect(h.charging, isTrue);
    expect(h.plugFromChargeLine, isTrue);
    expect(h.bootResetKind, 3);
    expect(h.uptimeSeconds, 0x01020304);

    final c = h.current;
    expect(c.state, BatteryHistoryState.onBattery);
    expect(c.lastResetKind, 5);
    expect(c.flags, 0x0013);
    expect(c.has(BatteryHistoryFlags.startSettled), isTrue);
    expect(c.has(BatteryHistoryFlags.startUnseen), isTrue);
    expect(c.has(BatteryHistoryFlags.gap), isTrue);
    expect(c.has(BatteryHistoryFlags.resetSeen), isFalse);
    expect(c.sessionId, 7);
    expect(c.awakeSeconds, 3600);
    expect(c.micSeconds, 1800);
    expect(c.bleSeconds, 3000);
    expect(c.streamSeconds, 900);
    expect(c.chargingSeconds, 0);
    expect(c.sleeps, 2);
    expect(c.boots, 3);
    expect(c.resets, 0);
    expect(c.sleepSaves, 3);
    expect(c.edgeMv, 4180);
    expect(c.edgePercent, 100);
    expect(c.lastPercent, 62);
    expect(c.startMv, 4120);
    expect(c.startPercent, 96);
    expect(c.startStampSeconds, 61);
    expect(c.lastMv, 3800);
    expect(c.minMv, 3790);
    expect(c.lastStampSeconds, 3600);
    expect(c.saves, 4);
    expect(c.fullStampSeconds, isNull);

    final g = h.lastCharge!;
    expect(g.flags, 0x0080);
    expect(g.has(BatteryHistoryFlags.terminated), isTrue);
    expect(g.nextSessionId, 7);
    expect(g.awakeSeconds, 5400);
    expect(g.chargingSeconds, 5000);
    expect(g.fullStampSeconds, 4800);
    expect(g.sleeps, 1);
    expect(g.boots, 2);
    expect(g.inMv, 3600);
    expect(g.inPercent, 5);
    expect(g.outPercent, 100);
    expect(g.outMv, 4200);
    expect(g.resets, 9);

    expect(h.sessions, hasLength(2));
    final s = h.sessions.first;
    expect(s.sessionId, 6);
    expect(s.endReason, SessionEndReason.empty);
    expect(s.edgePercent, 99);
    expect(s.flags, 0x0011);
    expect(s.lowTrust, isTrue);
    expect(s.awakeSeconds, 33600);
    expect(s.micSeconds, 1);
    expect(s.bleSeconds, 2);
    expect(s.streamSeconds, 3);
    expect(s.sleeps, 36);
    expect(s.boots, 37);
    expect(s.resets, 1);
    expect(s.startMv, 4150);
    expect(s.startPercent, 95);
    expect(s.endPercent, 0, reason: '0 % is a reading, not unknown');
    expect(s.endMv, 3400);
    expect(s.minMv, 3350);

    final older = h.sessions.last;
    expect(older.endReason, SessionEndReason.powerLost);
    expect(older.edgePercent, isNull);
    expect(older.startPercent, isNull);
    expect(older.endPercent, isNull);
    expect(older.startMv, isNull);
    expect(older.lowTrust, isFalse);
  });

  test('unknown sentinels decode as null, never as zero or 255', () {
    final b = HistoryBytes()
      ..current.addAll(<int, (int, int)>{
        0: (1, 2),
        38: (1, 0xFF),
        39: (1, 0xFF),
        42: (1, 0xFF),
        44: (4, 0xFFFFFFFF),
        52: (4, 0xFFFFFFFF),
        60: (4, 0xFFFFFFFF),
      });
    final c = BatteryHistory.fromBytes(b.build()).current;
    expect(c.state, BatteryHistoryState.external);
    expect(c.edgeMv, isNull);
    expect(c.edgePercent, isNull);
    expect(c.lastPercent, isNull);
    expect(c.startMv, isNull);
    expect(c.startPercent, isNull);
    expect(c.startStampSeconds, isNull);
    expect(c.lastMv, isNull);
    expect(c.minMv, isNull);
    expect(c.lastStampSeconds, isNull);
    expect(c.fullStampSeconds, isNull);
  });

  test('a charge record marked invalid is no charge at all', () {
    final b = HistoryBytes()..current.addAll(HistoryBytes.onBattery());
    expect(BatteryHistory.fromBytes(b.build()).lastCharge, isNull);
    expect(BatteryHistory.fromBytes(b.build()).sessions, isEmpty);
  });

  test('an unknown end reason is kept as unknown', () {
    final b = HistoryBytes()
      ..current.addAll(HistoryBytes.onBattery())
      ..ring.add(<int, (int, int)>{0: (4, 1), 4: (1, 9)});
    expect(BatteryHistory.fromBytes(b.build()).sessions.single.endReason,
        SessionEndReason.unknown);
  });

  group('refused', () {
    test('shorter than the header', () {
      expect(() => BatteryHistory.fromBytes(<int>[1, 12, 64]), throwsFormatException);
      expect(() => BatteryHistory.fromBytes(<int>[]), throwsFormatException);
    });

    test('any layout version but this one', () {
      expect(() => BatteryHistory.fromBytes(HistoryBytes(version: 0).build()),
          throwsFormatException);
      expect(() => BatteryHistory.fromBytes(HistoryBytes(version: 2).build()),
          throwsFormatException,
          reason: 'there is no layout 2, so a value claiming one is a bug '
              'to see, not a value to half-read');
    });

    test('sections shorter than this layout', () {
      expect(() => BatteryHistory.fromBytes(HistoryBytes(headerLength: 11).build()),
          throwsFormatException);
      expect(() => BatteryHistory.fromBytes(HistoryBytes(currentLength: 60).build()),
          throwsFormatException);
      expect(() => BatteryHistory.fromBytes(HistoryBytes(chargeLength: 30).build()),
          throwsFormatException);
      expect(() => BatteryHistory.fromBytes(HistoryBytes(ringLength: 39).build()),
          throwsFormatException);
    });

    test('a value shorter than its header promises', () {
      final b = HistoryBytes()
        ..current.addAll(HistoryBytes.onBattery())
        ..ring.add(<int, (int, int)>{0: (4, 1), 4: (1, 1)});
      expect(() => BatteryHistory.fromBytes(b.build(truncateTo: 12 + 64 + 32 + 39)),
          throwsFormatException);
      expect(() => BatteryHistory.fromBytes(b.build(truncateTo: 50)), throwsFormatException);
    });

    test('more than eight ring entries', () {
      final b = HistoryBytes()..current.addAll(HistoryBytes.onBattery());
      for (var i = 0; i < 9; i++) {
        b.ring.add(<int, (int, int)>{0: (4, i + 1), 4: (1, 1)});
      }
      expect(() => BatteryHistory.fromBytes(b.build()), throwsFormatException);
    });

    test('an unknown state', () {
      final b = HistoryBytes()..current[0] = (1, 3);
      expect(() => BatteryHistory.fromBytes(b.build()), throwsFormatException);
    });
  });

  test('sections are read at the offsets the header gives, not at fixed ones',
      () {
    // The firmware publishes each section's length precisely so one can grow
    // without every offset after it moving. This is that rule, exercised at
    // the current layout version.
    final b = HistoryBytes(
      headerLength: 16,
      currentLength: 72,
      chargeLength: 36,
      ringLength: 48,
    )
      ..current.addAll(HistoryBytes.onBattery(sessionId: 42, lastPercent: 50))
      ..current[64] = (4, 0xDEADBEEF)
      ..charge.addAll(<int, (int, int)>{0: (1, 1), 4: (4, 42), 32: (4, 0xFFFFFFFF)})
      ..ring.add(<int, (int, int)>{0: (4, 41), 4: (1, 1), 40: (4, 0xFFFFFFFF)})
      ..ring.add(<int, (int, int)>{0: (4, 40), 4: (1, 2)});

    final h = BatteryHistory.fromBytes(b.build());
    expect(h.version, BatteryHistory.layoutVersion);
    expect(h.current.sessionId, 42);
    expect(h.current.lastPercent, 50);
    expect(h.lastCharge!.nextSessionId, 42);
    expect(h.sessions.map((s) => s.sessionId), <int>[41, 40]);
    expect(h.sessions.last.endReason, SessionEndReason.empty);
  });

  test('a full layout-1 value is exactly the documented maximum', () {
    final b = HistoryBytes()..current.addAll(HistoryBytes.onBattery());
    for (var i = 0; i < 8; i++) {
      b.ring.add(<int, (int, int)>{0: (4, i + 1), 4: (1, 1)});
    }
    final bytes = b.build();
    expect(bytes.length, BatteryHistory.maxBytes);
    expect(BatteryHistory.fromBytes(bytes).sessions, hasLength(8));
  });
}
