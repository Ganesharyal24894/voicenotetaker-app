import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/model/audio_retention.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/audio_retention_service.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/transcription/transcript_store.dart';

import 'library_service_test.dart' show InMemoryFileStore, wavOf;

/// The sweep that removes day-old audio and keeps transcripts.
void main() {
  const dir = '/documents/recordings';
  late InMemoryFileStore store;
  late AudioRetentionService retention;
  // Two days after the recordings below were made, whatever the local zone.
  final now = DateTime(2026, 9, 12, 12).toUtc();

  setUp(() {
    store = InMemoryFileStore();
    retention = AudioRetentionService(
      fileStore: store,
      directory: dir,
      transcripts: TranscriptStore(fileStore: store),
    );
  });

  List<int> transcript({String text = 'हाँ'}) => utf8.encode(jsonEncode(
        Transcript(
          languageCode: 'hi',
          modelId: 'm',
          createdAt: DateTime.utc(2026, 9, 10),
          audioDuration: const Duration(seconds: 30),
          segments: <TranscriptSegment>[
            TranscriptSegment(
                start: Duration.zero, end: const Duration(seconds: 8), text: text),
          ],
        ).toJson(),
      ));

  /// A recording made at [at] (local wall-clock time, as the app names them).
  String seed(
    DateTime at, {
    bool transcribed = true,
    String text = 'हाँ',
    bool failed = false,
    bool kept = false,
    DateTime? modified,
  }) {
    final path = '$dir/${RecordingNaming.fileName(at)}';
    store.put(path, wavOf(const Duration(seconds: 1)), at: modified ?? at);
    if (transcribed) {
      store.put(RecordingNaming.transcriptPathOf(path), transcript(text: text));
    }
    if (failed) {
      store.put(RecordingNaming.transcriptFailurePathOf(path), <int>[]);
    }
    if (kept) store.put(RecordingNaming.keepAudioPathOf(path), <int>[]);
    return path;
  }

  Future<RetentionSweepReport> sweep({
    bool Function(String)? inUse,
    DateTime? at,
  }) =>
      retention.sweep(now: at ?? now, isInUse: inUse ?? (_) => false);

  test('removes ONLY the WAV of an old transcribed recording, marker first',
      () async {
    final path = seed(DateTime(2026, 9, 10, 9));
    final transcriptBefore =
        store.files[RecordingNaming.transcriptPathOf(path)];

    final report = await sweep();

    expect(report.removed, <String>[path]);
    expect(store.files.containsKey(path), isFalse);
    expect(store.files[RecordingNaming.transcriptPathOf(path)],
        transcriptBefore);
    expect(store.files.containsKey(RecordingNaming.audioRemovedPathOf(path)),
        isTrue);

    // ...and the library still lists it, without audio.
    final library = LibraryService(fileStore: store, directory: dir);
    final listed = await library.refresh();
    expect(listed.single.path, path);
    expect(listed.single.hasAudio, isFalse);
    await library.dispose();
  });

  test('keeps everything the rules protect', () async {
    final young = seed(DateTime(2026, 9, 12, 3));
    final kept = seed(DateTime(2026, 9, 10, 9), kept: true);
    final untranscribed = seed(DateTime(2026, 9, 10, 10), transcribed: false);
    final failed = seed(DateTime(2026, 9, 10, 11), transcribed: false, failed: true);
    final failedButTranscribed = seed(DateTime(2026, 9, 10, 12), failed: true);
    final empty = seed(DateTime(2026, 9, 10, 13), text: '  ');
    final playing = seed(DateTime(2026, 9, 10, 14));
    final future = seed(DateTime(2027, 1, 1, 9));

    final report = await sweep(inUse: (p) => p == playing);

    expect(report.removed, isEmpty);
    expect(report.verdicts, <String, RetentionVerdict>{
      young: RetentionVerdict.tooRecent,
      kept: RetentionVerdict.kept,
      untranscribed: RetentionVerdict.noTranscript,
      failed: RetentionVerdict.transcriptFailed,
      failedButTranscribed: RetentionVerdict.transcriptFailed,
      empty: RetentionVerdict.transcriptEmpty,
      playing: RetentionVerdict.inUse,
      future: RetentionVerdict.timeInFuture,
    });
    for (final path in report.verdicts.keys) {
      expect(store.files.containsKey(path), isTrue, reason: path);
    }
  });

  test('an unreadable transcript is not a transcript', () async {
    final path = seed(DateTime(2026, 9, 10, 9));
    store.put(RecordingNaming.transcriptPathOf(path), <int>[1, 2, 3]);
    final report = await sweep();
    expect(report.verdicts[path], RetentionVerdict.noTranscript);
    expect(store.files.containsKey(path), isTrue);
  });

  test('a recent modification time postpones an old name', () async {
    final path = seed(DateTime(2026, 9, 10, 9),
        modified: DateTime(2026, 9, 12, 11));
    final report = await sweep();
    expect(report.verdicts[path], RetentionVerdict.tooRecent);
  });

  test('a file without a time in its name falls back to its mtime', () async {
    const path = '$dir/imported.wav';
    store
      ..put(path, wavOf(const Duration(seconds: 1)), at: DateTime(2026, 9, 1))
      ..put(RecordingNaming.transcriptPathOf(path), transcript());
    final report = await sweep();
    expect(report.removed, <String>[path]);
  });

  test('in use is asked again right before the delete', () async {
    final path = seed(DateTime(2026, 9, 10, 9));
    var asks = 0;
    // Free when judged, busy by the time of the delete.
    final report = await sweep(inUse: (_) => ++asks > 2);
    expect(report.removed, isEmpty);
    expect(report.verdicts[path], RetentionVerdict.inUse);
    expect(store.files.containsKey(path), isTrue);
  });

  test('a keep set after the listing is still honoured', () async {
    final path = seed(DateTime(2026, 9, 10, 9));
    var first = true;
    final report = await sweep(inUse: (_) {
      // The first question is asked while judging; mark it kept right then.
      if (first) {
        first = false;
        store.put(RecordingNaming.keepAudioPathOf(path), <int>[]);
      }
      return false;
    });
    expect(report.verdicts[path], RetentionVerdict.kept);
    expect(store.files.containsKey(path), isTrue);
  });

  test('killed after the marker: the WAV is still listed, and the next sweep '
      'removes it', () async {
    final path = seed(DateTime(2026, 9, 10, 9));
    store.put(RecordingNaming.audioRemovedPathOf(path), <int>[]);

    final library = LibraryService(fileStore: store, directory: dir);
    expect((await library.refresh()).single.hasAudio, isTrue);

    final report = await sweep();
    expect(report.removed, <String>[path]);
    expect((await library.refresh()).single.hasAudio, isFalse);
    await library.dispose();
  });

  test('a delete that fails is reported, not thrown, and retried next time',
      () async {
    final path = seed(DateTime(2026, 9, 10, 9));
    final failing = _FailingDeleteStore(store, path);
    final sweeper = AudioRetentionService(
      fileStore: failing,
      directory: dir,
      transcripts: TranscriptStore(fileStore: failing),
    );
    final report = await sweeper.sweep(now: now, isInUse: (_) => false);
    expect(report.failed, <String>[path]);
    expect(report.removed, isEmpty);

    expect((await sweep()).removed, <String>[path]);
  });

  test('setKeep writes and clears the marker, idempotently', () async {
    final path = seed(DateTime(2026, 9, 10, 9));
    await retention.setKeep(path, keep: true);
    await retention.setKeep(path, keep: true);
    expect(await retention.isKept(path), isTrue);
    expect((await sweep()).verdicts[path], RetentionVerdict.kept);

    await retention.setKeep(path, keep: false);
    await retention.setKeep(path, keep: false);
    expect(await retention.isKept(path), isFalse);
  });

  test('manual recordings follow the same rules as notes', () async {
    // Same naming either way: a manual capture made two days ago goes too.
    final manual = seed(DateTime(2026, 9, 10, 18, 30, 5));
    expect((await sweep()).removed, <String>[manual]);
  });

  group('settings', () {
    late AudioRetentionSettingsStore settings;
    setUp(() => settings =
        AudioRetentionSettingsStore(fileStore: store, directory: '/support'));

    test('off when never saved', () async {
      expect(await settings.loadAutoDeleteAudio(), isFalse);
    });

    test('round-trips', () async {
      await settings.saveAutoDeleteAudio(true);
      expect(await settings.loadAutoDeleteAudio(), isTrue);
      await settings.saveAutoDeleteAudio(false);
      expect(await settings.loadAutoDeleteAudio(), isFalse);
    });

    test('a damaged or other-version file reads as off', () async {
      store.put(settings.path, <int>[0, 1, 2]);
      expect(await settings.loadAutoDeleteAudio(), isFalse);
      store.put(settings.path,
          utf8.encode(jsonEncode({'version': 2, 'autoDeleteAudio': true})));
      expect(await settings.loadAutoDeleteAudio(), isFalse);
    });
  });
}

/// Delegates to [inner] but refuses to delete [path].
class _FailingDeleteStore implements FileStore {
  _FailingDeleteStore(this.inner, this.path);

  final InMemoryFileStore inner;
  final String path;

  @override
  Future<void> delete(String p) async {
    if (p == path) throw Exception('permission denied');
    await inner.delete(p);
  }

  @override
  Future<FileSink> openWrite(String p) => inner.openWrite(p);
  @override
  Future<FileSink> openAppend(String p) => inner.openAppend(p);
  @override
  Future<void> move(String from, String to) => inner.move(from, to);
  @override
  Future<Uint8List> read(String p) => inner.read(p);
  @override
  Future<Uint8List> readRange(String p, int start, int end) =>
      inner.readRange(p, start, end);
  @override
  Future<FileInfo?> stat(String p) => inner.stat(p);
  @override
  Future<void> writeBytes(String p, List<int> bytes) =>
      inner.writeBytes(p, bytes);
  @override
  Future<void> patchBytes(String p, int offset, List<int> bytes) =>
      inner.patchBytes(p, offset, bytes);
  @override
  Future<bool> exists(String p) => inner.exists(p);
  @override
  Future<List<String>> list(String directory) => inner.list(directory);
  @override
  String join(String directory, String name) => inner.join(directory, name);
}
