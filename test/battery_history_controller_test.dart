import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/services/battery_anchor_store.dart';

import 'battery_history_bytes.dart';
import 'view/harness.dart';

/// `fe09` at the controller: when it is read, that every read is kept as an
/// anchor, and what is left behind when it cannot be read.
void main() {
  setUpAll(registerViewFallbacks);

  Uint8List onBattery({int awake = 3600}) =>
      (HistoryBytes()..current.addAll(HistoryBytes.onBattery(awake: awake)))
          .build();

  test('read at connect, kept as an anchor, and reported', () async {
    var now = DateTime.utc(2026, 9, 15, 14);
    final harness = ViewHarness(clock: () => now);
    addTearDown(harness.dispose);
    when(() => harness.transport.readBatteryHistory(any()))
        .thenAnswer((_) async => onBattery());

    await harness.controller.connect(knownDevice);

    expect(harness.controller.batteryHistoryStatus, BatteryHistoryStatus.ready);
    final report = harness.controller.batteryReport!;
    expect(report.onBattery, isTrue);
    expect(report.currentPercent, 62);
    expect(report.percentAtUnplug, 96);
    final path =
        '${ViewHarness.recordingsDirectory}/${BatteryAnchorStore.fileName}';
    expect(harness.fileStore.files.containsKey(path), isTrue);

    // Opening Diagnostics takes another anchor.
    now = now.add(const Duration(minutes: 5));
    await harness.controller.openDiagnostics();
    verify(() => harness.transport.readBatteryHistory(knownDevice.id)).called(2);
  });

  test('battery notifications take a fresh anchor at most every 30 min',
      () async {
    var now = DateTime.utc(2026, 9, 15, 14);
    final harness = ViewHarness(clock: () => now);
    addTearDown(harness.dispose);
    when(() => harness.transport.readBatteryHistory(any()))
        .thenAnswer((_) async => onBattery());
    await harness.controller.connect(knownDevice);
    clearInteractions(harness.transport);

    now = now.add(const Duration(minutes: 10));
    harness.battery.add(const BatteryStatus(percent: 61, charging: false));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    verifyNever(() => harness.transport.readBatteryHistory(any()));

    now = now.add(const Duration(minutes: 21));
    harness.battery.add(const BatteryStatus(percent: 61, charging: false));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    verify(() => harness.transport.readBatteryHistory(knownDevice.id)).called(1);
  });

  test('a recorder that does not answer fe09 is "not supported", not an error',
      () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);

    await harness.controller.connect(knownDevice);

    expect(harness.controller.batteryHistoryStatus,
        BatteryHistoryStatus.notSupported);
    expect(harness.controller.batteryReport, isNull);
    expect(harness.controller.errorMessage, isNull);
    expect(harness.controller.isConnected, isTrue);
  });

  test('a layout this build cannot read is said to be unreadable', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readBatteryHistory(any()))
        .thenAnswer((_) async => Uint8List.fromList(<int>[0, 12, 64]));

    await harness.controller.connect(knownDevice);

    expect(harness.controller.batteryHistoryStatus,
        BatteryHistoryStatus.unreadable);
    expect(harness.controller.batteryReport, isNull);
  });

  test('a link that goes drops the report', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readBatteryHistory(any()))
        .thenAnswer((_) async => onBattery());
    await harness.controller.connect(knownDevice);
    expect(harness.controller.batteryReport, isNotNull);

    await harness.controller.disconnect();

    expect(harness.controller.batteryReport, isNull);
    expect(harness.controller.batteryHistoryStatus, BatteryHistoryStatus.unknown);
  });

  test('a read failure is never thrown out of connect', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    when(() => harness.transport.readBatteryHistory(any()))
        .thenThrow(const BleTransportException('link dropped'));

    await harness.controller.connect(knownDevice);
    expect(harness.controller.phase, AppPhase.connected);
  });
}
