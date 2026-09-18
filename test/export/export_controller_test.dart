import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/export_controller.dart';
import 'package:voicenotetaker_app/drivers/disk_space.dart';
import 'package:voicenotetaker_app/services/export/note_export_plan.dart';
import 'package:voicenotetaker_app/services/export/note_export_service.dart';

import '../summary/fakes.dart';
import 'export_fakes.dart';

const String recordings = '/documents/recordings';
const String exports = '/support/exports';

Uint8List audio(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 17 + 3) & 0xFF));

void main() {
  late MemoryFileStore store;
  late FakeShareSheet share;

  final now = DateTime(2026, 9, 18, 21);

  ExportController controllerWith({
    DiskSpace diskSpace = const FixedDiskSpace(),
    bool withShare = true,
  }) =>
      ExportController(
        exports: NoteExportService(
          fileStore: store,
          recordingsDirectory: recordings,
          exportsDirectory: exports,
          diskSpace: diskSpace,
        ),
        shareSheet: withShare ? share : null,
        now: () => now,
      );

  setUp(() {
    share = FakeShareSheet();
    store = MemoryFileStore()
      ..put('$recordings/voicenote-20260918-090000.wav', audio(40000))
      ..put('$recordings/voicenote-20260918-090000.transcript.json',
          '{"segments":[]}'.codeUnits)
      ..put('$recordings/voicenote-20260901-090000.wav', audio(20000));
  });

  test('opens on Today and counts it', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    expect(controller.range, ExportRange.today);
    expect(controller.plan, isNull);

    await controller.choose(ExportRange.today);
    expect(controller.plan!.noteCount, 1);
    expect(controller.phase, ExportPhase.choosing);
  });

  test('picking another range recounts', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.everything);
    expect(controller.range, ExportRange.everything);
    expect(controller.plan!.noteCount, 2);
  });

  test('a count that arrives for a range nobody is looking at is dropped',
      () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    final first = controller.choose(ExportRange.today);
    final second = controller.choose(ExportRange.everything);
    await Future.wait(<Future<void>>[first, second]);

    expect(controller.range, ExportRange.everything);
    expect(controller.plan!.noteCount, 2);
  });

  test('running writes the zip and moves to ready', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.everything);
    await controller.run();

    expect(controller.phase, ExportPhase.ready);
    expect(controller.result!.ok, isTrue);
    expect(controller.progress, 1.0);
    expect(readZip(store.bytesOf(controller.result!.path!)), hasLength(3));
  });

  test('progress is determinate from the first frame', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.today);
    expect(controller.progress, 0.0);
    final seen = <double>[];
    controller.addListener(() => seen.add(controller.progress));
    await controller.run();

    expect(seen, isNotEmpty);
    expect(seen.every((p) => p >= 0.0 && p <= 1.0), isTrue);
    expect(seen.last, 1.0);
  });

  test('a refusal goes back to the buttons and says why', () async {
    final controller = controllerWith(diskSpace: const FixedDiskSpace(10));
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.today);
    await controller.run();

    expect(controller.phase, ExportPhase.choosing);
    expect(controller.failure, ExportFailure.noRoom);
    expect(controller.result!.freeBytes, 10);
  });

  test('sharing hands the share sheet the file that was written', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.today);
    await controller.run();
    await controller.share();

    expect(share.sharedFiles.single,
        <String>['$exports/voicenotetaker-20260918.zip']);
    expect(share.shared, isEmpty, reason: 'a zip is not text');
  });

  test('sharing before there is a zip does nothing', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.today);
    await controller.share();
    expect(share.sharedFiles, isEmpty);
  });

  test('with no share sheet wired in there is nowhere to send it', () async {
    final controller = controllerWith(withShare: false);
    addTearDown(controller.dispose);

    expect(controller.canShare, isFalse);
    await controller.choose(ExportRange.today);
    await controller.run();
    await controller.share();
    expect(share.sharedFiles, isEmpty);
  });

  test('a zip that was handed to the share sheet survives close', () async {
    final controller = controllerWith();

    await controller.choose(ExportRange.today);
    await controller.run();
    await controller.share();
    await controller.close();

    // AirDrop may still be reading it. The next opening of the sheet sweeps.
    expect(store.files.keys.where((k) => k.startsWith(exports)), hasLength(1));
  });

  test('a zip that was never shared does not survive close', () async {
    final controller = controllerWith();

    await controller.choose(ExportRange.today);
    await controller.run();
    await controller.close();

    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
  });

  test('Stop shows itself immediately', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.today);
    expect(controller.stopping, isFalse);

    var notified = 0;
    controller.addListener(() => notified++);
    final running = controller.run();
    controller.cancel();
    expect(controller.stopping, isTrue);
    expect(notified, greaterThan(0));
    await running;
    expect(controller.stopping, isFalse);
  });

  test('discard removes the zip but not the notes', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.today);
    await controller.run();
    await controller.discard();

    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
    expect(store.files.keys.where((k) => k.startsWith(recordings)),
        hasLength(3));
  });

  test('disposing mid-export cancels it and leaves no file', () async {
    final controller = controllerWith();
    await controller.choose(ExportRange.today);
    controller.dispose();
    await controller.run();

    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
  });

  test('close waits for a running write before it sweeps', () async {
    final controller = controllerWith();
    await controller.choose(ExportRange.everything);

    // Started but not awaited: `close` has to wait for it, or it would delete
    // the zip while the write was still adding to it.
    final running = controller.run();
    await controller.close();
    await running;

    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
    expect(store.files.keys.where((k) => k.startsWith(recordings)),
        hasLength(3));
  });

  test('close on a controller that never ran is not an error', () async {
    final controller = controllerWith();
    await expectLater(controller.close(), completes);
    await expectLater(controller.close(), completes);
  });

  test('cancel only bites while a write is running', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.choose(ExportRange.today);
    controller.cancel();
    await controller.run();

    expect(controller.phase, ExportPhase.ready,
        reason: 'a cancel before the write started is not remembered');
  });

  test('run with nothing counted yet does nothing', () async {
    final controller = controllerWith();
    addTearDown(controller.dispose);

    await controller.run();
    expect(controller.phase, ExportPhase.choosing);
    expect(controller.result, isNull);
  });
}
