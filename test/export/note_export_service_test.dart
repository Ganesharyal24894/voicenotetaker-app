import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/disk_space.dart';
import 'package:voicenotetaker_app/services/export/note_export_plan.dart';
import 'package:voicenotetaker_app/services/export/note_export_service.dart';

import 'export_fakes.dart';

const String recordings = '/documents/recordings';
const String exports = '/support/exports';

Uint8List audio(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 17 + 3) & 0xFF));

void main() {
  late MemoryFileStore store;

  NoteExportService serviceWith({DiskSpace diskSpace = const FixedDiskSpace()}) =>
      NoteExportService(
        fileStore: store,
        recordingsDirectory: recordings,
        exportsDirectory: exports,
        diskSpace: diskSpace,
      );

  setUp(() {
    store = MemoryFileStore()
      ..put('$recordings/voicenote-20260918-090000.wav', audio(40000))
      ..put('$recordings/voicenote-20260918-090000.transcript.json',
          utf8.encode('{"segments":[]}'))
      ..put('$recordings/voicenote-20260910-090000.wav', audio(20000));
  });

  final now = DateTime(2026, 9, 18, 21);

  test('plan reads the directory and answers what today holds', () async {
    final plan = await serviceWith().plan(ExportRange.today, now: now);
    expect(plan.noteCount, 1);
    expect(plan.files, hasLength(2));
    expect(plan.zipName, 'voicenotetaker-20260918.zip');
  });

  test('a written export is a readable zip of the planned files', () async {
    final service = serviceWith();
    final plan = await service.plan(ExportRange.everything, now: now);
    final result = await service.write(plan);

    expect(result.ok, isTrue);
    expect(result.path, '$exports/voicenotetaker-all-20260918.zip');
    expect(result.noteCount, 2);
    expect(result.sizeBytes, plan.zipBytes,
        reason: 'the size promised before the write is the size on disk');

    final members = readZip(store.bytesOf(result.path!));
    expect(members.map((m) => m.name), <String>[
      'recordings/voicenote-20260910-090000.wav',
      'recordings/voicenote-20260918-090000.wav',
      'recordings/voicenote-20260918-090000.transcript.json',
    ]);
    expect(members[1].bytes, audio(40000));
    expect(utf8.decode(members.last.bytes), '{"segments":[]}');
  });

  test('nothing on the phone is touched by an export', () async {
    final before = Map<String, int>.fromEntries(
      store.files.entries
          .where((e) => e.key.startsWith(recordings))
          .map((e) => MapEntry<String, int>(e.key, e.value.bytes.length)),
    );

    final service = serviceWith();
    await service.write(await service.plan(ExportRange.everything, now: now));

    final after = Map<String, int>.fromEntries(
      store.files.entries
          .where((e) => e.key.startsWith(recordings))
          .map((e) => MapEntry<String, int>(e.key, e.value.bytes.length)),
    );
    expect(after, before);
  });

  test('progress runs from nothing to the planned total', () async {
    final service = serviceWith();
    final plan = await service.plan(ExportRange.everything, now: now);
    final seen = <int>[];
    await service.write(plan, onProgress: (written, total) {
      expect(total, plan.zipBytes);
      seen.add(written);
    });

    expect(seen.first, lessThan(plan.zipBytes));
    expect(seen.last, plan.zipBytes);
    // Never backwards: a bar that jumps back reads as a stall.
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });

  test('an empty range is refused, and writes no file', () async {
    final service = serviceWith();
    final plan = await service.plan(
      ExportRange.today,
      now: DateTime(2027, 1, 1),
    );
    final result = await service.write(plan);

    expect(result.ok, isFalse);
    expect(result.failure, ExportFailure.nothingToExport);
    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
  });

  test('a phone with no room is told before anything is written', () async {
    final service = serviceWith(diskSpace: const FixedDiskSpace(1000));
    final plan = await service.plan(ExportRange.everything, now: now);
    final result = await service.write(plan);

    expect(result.failure, ExportFailure.noRoom);
    expect(result.freeBytes, 1000);
    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
  });

  test('a phone that will not say how much room it has is not stopped',
      () async {
    final service = serviceWith();
    final result =
        await service.write(await service.plan(ExportRange.everything, now: now));
    expect(result.ok, isTrue);
  });

  test('room is judged with headroom, not to the last byte', () async {
    final service = serviceWith();
    final plan = await service.plan(ExportRange.everything, now: now);

    final exact = NoteExportService(
      fileStore: store,
      recordingsDirectory: recordings,
      exportsDirectory: exports,
      diskSpace: FixedDiskSpace(plan.zipBytes),
    );
    expect((await exact.write(plan)).failure, ExportFailure.noRoom);

    final roomy = NoteExportService(
      fileStore: store,
      recordingsDirectory: recordings,
      exportsDirectory: exports,
      diskSpace: FixedDiskSpace(plan.zipBytes + NoteExportService.headroomBytes),
    );
    expect((await roomy.write(plan)).ok, isTrue);
  });

  test('a cancelled export leaves no half file behind', () async {
    final service = serviceWith();
    final plan = await service.plan(ExportRange.everything, now: now);
    final result = await service.write(plan, isCancelled: () => true);

    expect(result.failure, ExportFailure.cancelled);
    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
  });

  test('cancelling part way through still leaves nothing behind', () async {
    final service = serviceWith();
    final plan = await service.plan(ExportRange.everything, now: now);
    var calls = 0;
    final result = await service.write(plan, isCancelled: () => calls++ > 0);

    expect(result.failure, ExportFailure.cancelled);
    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
  });

  test('the previous export is removed before a new one starts', () async {
    final service = serviceWith();
    store.put('$exports/voicenotetaker-20260101.zip', audio(5000));

    await service.write(await service.plan(ExportRange.today, now: now));

    expect(
      store.files.keys.where((k) => k.startsWith(exports)),
      <String>['$exports/voicenotetaker-20260918.zip'],
    );
  });

  test('clearExports removes the zip and nothing else', () async {
    final service = serviceWith();
    await service.write(await service.plan(ExportRange.today, now: now));
    await service.clearExports();

    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
    expect(
      store.files.keys.where((k) => k.startsWith(recordings)),
      hasLength(3),
    );
  });

  test('clearExports on a phone that has never exported is not an error',
      () async {
    await expectLater(serviceWith().clearExports(), completes);
  });

  test('a plan past what a zip can hold is refused', () async {
    store.put('$recordings/voicenote-20260918-100000.wav', audio(10));
    final service = serviceWith();
    final plan = await service.plan(ExportRange.today, now: now);
    final refused = await service.write(ExportPlan(
      range: plan.range,
      zipName: plan.zipName,
      files: plan.files,
      noteCount: plan.noteCount,
      audioBytes: plan.audioBytes,
      zipBytes: 5000000000,
      tooLarge: true,
    ));

    expect(refused.failure, ExportFailure.tooLarge);
    expect(store.files.keys.where((k) => k.startsWith(exports)), isEmpty);
  });

  test('a note that cannot be read does not produce a broken zip', () async {
    store.unreadable.add('$recordings/voicenote-20260918-090000.wav');
    final service = serviceWith();
    final result =
        await service.write(await service.plan(ExportRange.today, now: now));

    // The writer pads rather than truncating, so the archive is still sound
    // and its sizes still add up - the export succeeds and the one unreadable
    // note is silent rather than corrupting everything after it.
    expect(result.ok, isTrue);
    expect(result.unreadableFiles, 1,
        reason: 'the zip opens cleanly, so this is the only way to know');
    final members = readZip(store.bytesOf(result.path!));
    expect(members.first.bytes.length, 40000);
    expect(members.first.bytes.every((b) => b == 0), isTrue);
  });

  test('an export that read everything reports nothing unreadable', () async {
    final service = serviceWith();
    final result =
        await service.write(await service.plan(ExportRange.today, now: now));
    expect(result.unreadableFiles, 0);
  });

  test('a big note is never held in memory whole', () async {
    store.put('$recordings/voicenote-20260918-120000.wav', audio(4 * 1024 * 1024));
    final service = serviceWith();
    store.largestReadRange = 0;
    await service.write(await service.plan(ExportRange.today, now: now));

    expect(store.largestReadRange, lessThanOrEqualTo(512 * 1024));
  });
}
