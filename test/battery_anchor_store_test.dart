import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/battery_anchor.dart';
import 'package:voicenotetaker_app/model/battery_history.dart';
import 'package:voicenotetaker_app/services/battery_anchor_store.dart';

import 'battery_history_bytes.dart';
import 'view/harness.dart';

void main() {
  const directory = '/support';
  final t0 = DateTime.utc(2026, 9, 14, 8);

  BatteryAnchor anchor({
    Duration after = Duration.zero,
    int sessionId = 7,
    int awake = 100,
    int boots = 0,
    BatteryHistoryState state = BatteryHistoryState.onBattery,
  }) =>
      BatteryAnchor(
        utc: t0.add(after),
        state: state,
        sessionId: sessionId,
        awakeSeconds: awake,
        sleeps: 0,
        boots: boots,
        resets: 0,
        uptimeSeconds: awake,
        flags: 1,
        lastPercent: 80,
        lastMv: 3950,
        startPercent: 96,
      );

  test('an anchor round-trips through JSON, and is built from a read', () {
    final history = BatteryHistory.fromBytes(
      (HistoryBytes()..current.addAll(HistoryBytes.onBattery(sleeps: 2, boots: 3))).build(),
    );
    final a = BatteryAnchor.fromHistory(history, t0);
    expect(a.sessionId, 7);
    expect(a.awakeSeconds, 3600);
    expect(a.sleeps, 2);
    expect(a.boots, 3);
    expect(a.uptimeSeconds, 120);
    expect(a.lastPercent, 62);
    expect(a.startPercent, 96);
    expect(a.lastMv, 3800);

    final back = BatteryAnchor.fromJson(a.toJson())!;
    expect(back.utc, t0);
    expect(back.utc.isUtc, isTrue);
    expect(back.state, BatteryHistoryState.onBattery);
    expect(back.toJson(), a.toJson());
    expect(BatteryAnchor.fromJson('nope'), isNull);
    expect(BatteryAnchor.fromJson(<String, Object?>{'utcMs': 1}), isNull);
  });

  test('saves, and a new store reads the anchors back in time order', () async {
    final files = MemoryFileStore();
    final store = BatteryAnchorStore(fileStore: files, directory: directory);
    await store.add(anchor(after: const Duration(hours: 1), awake: 200));
    await store.add(anchor(awake: 100));

    final loaded = await BatteryAnchorStore(fileStore: files, directory: directory).load();
    expect(loaded.map((a) => a.awakeSeconds), <int>[100, 200]);
  });

  test('a missing or damaged file is no anchors, not a crash', () async {
    final files = MemoryFileStore();
    expect(await BatteryAnchorStore(fileStore: files, directory: directory).load(), isEmpty);
    files.files['$directory/${BatteryAnchorStore.fileName}'] = <int>[1, 2, 3];
    expect(await BatteryAnchorStore(fileStore: files, directory: directory).load(), isEmpty);
  });

  test('awake seconds that go down WITH more boots keep the older anchors', () async {
    final store = BatteryAnchorStore(fileStore: MemoryFileStore(), directory: directory);
    await store.add(anchor(awake: 900));
    final all = await store.add(anchor(after: const Duration(hours: 1), awake: 300, boots: 1));
    expect(all, hasLength(2));
  });

  test('awake seconds that go down WITHOUT more boots drop the reused id', () async {
    final store = BatteryAnchorStore(fileStore: MemoryFileStore(), directory: directory);
    await store.add(anchor(sessionId: 6, awake: 5000));
    await store.add(anchor(after: const Duration(minutes: 5), awake: 900));
    await store.add(anchor(after: const Duration(minutes: 10), awake: 1200));
    final all = await store.add(anchor(after: const Duration(hours: 1), awake: 300));
    expect(all.map((a) => (a.sessionId, a.awakeSeconds)), <(int, int)>[(6, 5000), (7, 300)]);
  });

  test('keeps at most the newest maxAnchors', () async {
    final store = BatteryAnchorStore(fileStore: MemoryFileStore(), directory: directory);
    late List<BatteryAnchor> all;
    for (var i = 0; i < BatteryAnchorStore.maxAnchors + 5; i++) {
      all = await store.add(anchor(after: Duration(minutes: i), awake: 100 + i));
    }
    expect(all, hasLength(BatteryAnchorStore.maxAnchors));
    expect(all.first.awakeSeconds, 105);
  });

  test('a failed save throws', () async {
    final files = MemoryFileStore()..readOnly = true;
    final store = BatteryAnchorStore(fileStore: files, directory: directory);
    await expectLater(store.add(anchor()), throwsA(anything));
  });
}
