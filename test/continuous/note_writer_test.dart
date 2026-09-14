import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';
import 'package:voicenotetaker_app/services/continuous/note_writer.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/wav_reader.dart';

import '../view/harness.dart';

/// Always-listening's notes: where one ends, what goes in the gaps, what is
/// thrown away, and that a header is never far behind its file.
void main() {
  const dir = '/notes';
  const format = StreamInfo.fallback; // 16 kHz, 16-bit, mono: 32 000 B/s.
  const bytesPerSecond = 32000;
  final t0 = DateTime(2026, 9, 14, 10, 0, 0);

  late MemoryFileStore store;
  late List<NoteChange> changes;
  late ContinuousNoteWriter writer;

  setUp(() {
    store = MemoryFileStore();
    changes = <NoteChange>[];
    writer = ContinuousNoteWriter(
      fileStore: store,
      directory: dir,
      format: format,
      onChange: changes.add,
    );
  });

  /// [seconds] of non-zero audio in 20 ms blocks starting at [from], each
  /// block arriving 20 ms after the last. Returns the time after the last.
  Future<DateTime> speak(DateTime from, double seconds) async {
    final blocks = (seconds * 50).round();
    var at = from;
    for (var i = 0; i < blocks; i++) {
      await writer.addAudio(Uint8List(640)..fillRange(0, 640, 7), at);
      at = at.add(const Duration(milliseconds: 20));
    }
    return at;
  }

  WavHeader headerOf(String path) =>
      WavReader.parse(Uint8List.fromList(store.files[path]!))!;

  int payloadOf(String path) => store.files[path]!.length - 44;

  test('a note is named for the time its first speech arrived', () async {
    await speak(t0, 3);
    await writer.finish();

    final path = '$dir/${RecordingNaming.fileName(t0)}';
    expect(store.files.keys, <String>[path]);
    expect(changes.map((c) => c.kind),
        <NoteChangeKind>[NoteChangeKind.started, NoteChangeKind.finished]);
    expect(headerOf(path).dataLength, 3 * bytesPerSecond);
  });

  test('a pause under a second is written as it came, with no padding',
      () async {
    final end = await speak(t0, 2);
    await speak(end.add(const Duration(milliseconds: 500)), 2);
    await writer.finish();

    expect(payloadOf(store.files.keys.single), 4 * bytesPerSecond);
  });

  test('a longer pause becomes 300 ms of silence, however long it was',
      () async {
    final end = await speak(t0, 2);
    await speak(end.add(const Duration(seconds: 90)), 2);
    await writer.finish();

    final path = store.files.keys.single;
    const gap = bytesPerSecond * 300 ~/ 1000;
    expect(payloadOf(path), 4 * bytesPerSecond + gap);
    // The silence is zeroes, exactly where the pause was.
    final bytes = store.files[path]!;
    final gapStart = 44 + 2 * bytesPerSecond;
    expect(bytes.sublist(gapStart, gapStart + gap).every((b) => b == 0),
        isTrue);
    expect(bytes[gapStart + gap], 7);
    expect(headerOf(path).dataLength, payloadOf(path));
  });

  test('two minutes without audio starts a new note', () async {
    final end = await speak(t0, 3);
    final next = end.add(ContinuousNoteWriter.newNoteAfter);
    await speak(next, 3);
    await writer.finish();

    expect(store.files.keys, hasLength(2));
    expect(store.files.keys,
        contains('$dir/${RecordingNaming.fileName(next)}'));
    for (final path in store.files.keys) {
      expect(payloadOf(path), 3 * bytesPerSecond);
      expect(headerOf(path).dataLength, 3 * bytesPerSecond);
    }
  });

  test('tick closes a note that has gone quiet, and only then', () async {
    final end = await speak(t0, 3);

    await writer.tick(end.add(const Duration(seconds: 119)));
    expect(writer.isWriting, isTrue);

    await writer.tick(end.add(const Duration(minutes: 2)));
    expect(writer.isWriting, isFalse);
    expect(changes.last.kind, NoteChangeKind.finished);
  });

  test('a note under two seconds of speech is deleted when it closes',
      () async {
    await speak(t0, 1.5);
    await writer.finish();

    expect(store.files, isEmpty);
    expect(changes.last.kind, NoteChangeKind.discarded);
  });

  test('inserted silence does not count towards the two seconds', () async {
    var at = await speak(t0, 0.6);
    for (var i = 0; i < 3; i++) {
      at = await speak(at.add(const Duration(seconds: 5)), 0.4);
    }
    await writer.finish();

    // 1.8 s of speech and 0.9 s of inserted silence: still not a note.
    expect(store.files, isEmpty);
  });

  test('an hour-long note rolls over into a new one', () async {
    // Sizes only: an hour of audio held as a list of ints would not fit in a
    // test's memory.
    final sizes = _SizeOnlyStore();
    final long = ContinuousNoteWriter(
      fileStore: sizes,
      directory: dir,
      format: format,
    );
    // One minute of audio per call, arriving under a second apart so no
    // silence is inserted between them.
    var at = t0;
    final minute = Uint8List(60 * bytesPerSecond);
    for (var i = 0; i < 61; i++) {
      await long.addAudio(minute, at);
      at = at.add(const Duration(milliseconds: 900));
    }
    await long.finish();

    final payloads = sizes.bytes.values.map((b) => b - 44).toList()..sort();
    expect(payloads, <int>[60 * bytesPerSecond, 60 * 60 * bytesPerSecond]);
  });

  test('the header keeps up while the note is still being written', () async {
    await speak(t0, 12);
    final path = writer.currentPath!;

    // Never more than five seconds behind, even though nothing was closed.
    final claimed = headerOf(path).dataLength;
    expect(claimed, greaterThan(0));
    expect(payloadOf(path) - claimed,
        lessThanOrEqualTo(5 * bytesPerSecond));
  });

  test('a taken name is never overwritten', () async {
    final taken = '$dir/${RecordingNaming.fileName(t0)}';
    store.files[taken] = <int>[1, 2, 3];

    await speak(t0, 3);
    await writer.finish();

    expect(store.files[taken], <int>[1, 2, 3]);
    expect(store.files.keys, contains(
        '$dir/${RecordingNaming.fileName(t0.add(const Duration(seconds: 1)))}'));
  });

  test('finish between notes does nothing', () async {
    await writer.finish();
    expect(changes, isEmpty);
    expect(store.files, isEmpty);
  });
}

/// Records how many bytes each file received, and nothing else.
class _SizeOnlyStore extends MemoryFileStore {
  final Map<String, int> bytes = <String, int>{};

  @override
  Future<FileSink> openWrite(String path) async {
    bytes[path] = 0;
    return _CountingSink(this, path);
  }

  @override
  Future<bool> exists(String path) async => bytes.containsKey(path);
}

class _CountingSink implements FileSink {
  _CountingSink(this._store, this._path);

  final _SizeOnlyStore _store;
  final String _path;

  @override
  int get bytesWritten => _store.bytes[_path]!;

  @override
  Future<void> add(List<int> bytes) async =>
      _store.bytes[_path] = _store.bytes[_path]! + bytes.length;

  @override
  Future<void> patch(int offset, List<int> bytes) async {}

  @override
  Future<void> close() async {}
}
