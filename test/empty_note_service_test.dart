import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/empty_note_policy.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/empty_note_service.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/transcription/transcript_store.dart';

import 'library_service_test.dart' show InMemoryFileStore, dir, wavOf;

const settingsDir = '/support';
final now = DateTime.utc(2026, 9, 15, 12);

const NoteUse idle =
    (writing: false, capturing: false, open: false, transcribing: false);
const NoteUse opened =
    (writing: false, capturing: false, open: true, transcribing: false);

/// A store that runs [onWrite] after each write, to change the world between
/// the sweep's steps.
class HookedStore extends InMemoryFileStore {
  void Function(String path)? onWrite;
  Set<String> failDeletes = <String>{};

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    await super.writeBytes(path, bytes);
    onWrite?.call(path);
  }

  @override
  Future<void> delete(String path) async {
    if (failDeletes.contains(path)) throw StateError('cannot delete $path');
    await super.delete(path);
  }
}

void main() {
  late HookedStore store;
  late EmptyNoteService service;

  setUp(() {
    store = HookedStore();
    service = EmptyNoteService(
      fileStore: store,
      directory: dir,
      transcripts: TranscriptStore(fileStore: store),
      settingsDirectory: settingsDir,
    );
  });

  List<int> transcript(String text) => utf8.encode(jsonEncode(Transcript(
        languageCode: 'hi',
        modelId: 'indicconformer-hi-int8',
        createdAt: now,
        audioDuration: const Duration(seconds: 16),
        segments: <TranscriptSegment>[
          const TranscriptSegment(
              start: Duration.zero, end: Duration(seconds: 8), text: '  '),
          TranscriptSegment(
              start: const Duration(seconds: 8),
              end: const Duration(seconds: 16),
              text: text),
        ],
      ).toJson()));

  String note(String stamp, {String? text, bool marked = false}) {
    final path = '$dir/voicenote-$stamp.wav';
    store.put(path, wavOf(const Duration(seconds: 1)));
    if (text != null) {
      store.put(RecordingNaming.transcriptPathOf(path), transcript(text));
    }
    if (marked) store.put(RecordingNaming.emptyNotePathOf(path), <int>[1]);
    return path;
  }

  Iterable<String> filesOf(String audio) {
    final stem = audio.substring(0, audio.length - 4);
    return store.files.keys.where((p) => p.startsWith(stem));
  }

  test('a marked empty note is deleted with everything beside it', () async {
    final path = note('20260915-100000', text: '', marked: true);
    store
      ..put(RecordingNaming.speakerNamesPathOf(path), <int>[1])
      ..put('$dir/device-tests.json', <int>[1]);

    final report = await service.sweep(useOf: (_) => idle, now: now);

    expect(report.deleted, <String>[path]);
    expect(report.verdicts[path], EmptyNoteVerdict.delete);
    expect(filesOf(path), isEmpty);
    expect(store.files, contains('$dir/device-tests.json'));
    // The marker sweep is not the one-time sweep.
    expect(await service.isFullSweepDone(), isFalse);
  });

  test('markEmpty writes the marker the sweep acts on', () async {
    final path = note('20260915-100000', text: '');
    await service.markEmpty(path, now: now);
    expect(store.files, contains(RecordingNaming.emptyNotePathOf(path)));
    expect((await service.sweep(useOf: (_) => idle, now: now)).deleted,
        <String>[path]);
  });

  test('an unmarked empty note is left to the one-time sweep', () async {
    final path = note('20260915-100000', text: '');

    expect((await service.sweep(useOf: (_) => idle, now: now)).verdicts,
        isEmpty);
    expect(store.files, contains(path));

    final full =
        await service.sweep(useOf: (_) => idle, now: now, allNotes: true);
    expect(full.deleted, <String>[path]);
    expect(await service.isFullSweepDone(), isTrue);
    expect(store.files, contains('$settingsDir/${EmptyNoteService.sweepDoneFileName}'));
  });

  test('the one-time sweep leaves notes with words, none, or a failure',
      () async {
    final words = note('20260915-090000', text: 'ठीक है');
    final untranscribed = note('20260915-091000');
    final failed = note('20260915-092000', text: '');
    store.put(RecordingNaming.transcriptFailurePathOf(failed), <int>[1]);
    final damaged = note('20260915-093000');
    store.put(RecordingNaming.transcriptPathOf(damaged), utf8.encode('{'));

    final report =
        await service.sweep(useOf: (_) => idle, now: now, allNotes: true);

    expect(report.deleted, isEmpty);
    expect(report.verdicts[words], EmptyNoteVerdict.hasSpeech);
    expect(report.verdicts.containsKey(untranscribed), isFalse);
    // Filtered out by the listing: a failure is never a candidate.
    expect(report.verdicts.containsKey(failed), isFalse);
    expect(report.verdicts[damaged], EmptyNoteVerdict.noTranscript);
    for (final path in <String>[words, untranscribed, failed, damaged]) {
      expect(store.files, contains(path));
      expect(store.files, isNot(contains(RecordingNaming.emptyNotePathOf(path))));
    }
  });

  test('a marked note that now has words, a Keep or a failure keeps, and '
      'loses its marker', () async {
    final words = note('20260915-090000', text: 'hello', marked: true);
    final kept = note('20260915-091000', text: '', marked: true);
    store.put(RecordingNaming.keepAudioPathOf(kept), <int>[1]);
    final failed = note('20260915-092000', text: '', marked: true);
    store.put(RecordingNaming.transcriptFailurePathOf(failed), <int>[1]);

    final report = await service.sweep(useOf: (_) => idle, now: now);

    expect(report.deleted, isEmpty);
    expect(report.verdicts[words], EmptyNoteVerdict.hasSpeech);
    expect(report.verdicts[kept], EmptyNoteVerdict.kept);
    expect(report.verdicts[failed], EmptyNoteVerdict.failed);
    for (final path in <String>[words, kept, failed]) {
      expect(store.files, contains(path));
      expect(store.files, isNot(contains(RecordingNaming.emptyNotePathOf(path))));
    }
  });

  test('an open note is deferred, remembered, and deleted once closed',
      () async {
    final path = note('20260915-100000', text: '');

    final first = await service.sweep(
        useOf: (p) => p == path ? opened : idle, now: now, allNotes: true);
    expect(first.deferred, <String>[path]);
    expect(first.verdicts[path], EmptyNoteVerdict.deferOpen);
    expect(store.files, contains(path));
    // Marked, so a restart before it is closed still deletes it.
    expect(store.files, contains(RecordingNaming.emptyNotePathOf(path)));
    expect(await service.isFullSweepDone(), isTrue);

    final second = await service.sweep(useOf: (_) => idle, now: now);
    expect(second.deleted, <String>[path]);
    expect(filesOf(path), isEmpty);
  });

  test('writing, recording and transcribing defer too', () async {
    final path = note('20260915-100000', text: '', marked: true);
    for (final use in <NoteUse>[
      (writing: true, capturing: false, open: false, transcribing: false),
      (writing: false, capturing: true, open: false, transcribing: false),
      (writing: false, capturing: false, open: false, transcribing: true),
    ]) {
      final report = await service.sweep(useOf: (_) => use, now: now);
      expect(report.deferred, <String>[path]);
      expect(store.files, contains(path));
    }
  });

  test('opened between the judgment and the delete: not deleted', () async {
    final path = note('20260915-100000', text: '');
    var calls = 0;

    final report = await service.sweep(
      useOf: (_) => ++calls == 1 ? idle : opened,
      now: now,
      allNotes: true,
    );

    expect(report.deleted, isEmpty);
    expect(report.verdicts[path], EmptyNoteVerdict.deferOpen);
    expect(store.files, contains(path));
  });

  test('marked Keep between the judgment and the delete: kept', () async {
    final path = note('20260915-100000', text: '');
    store.onWrite = (written) {
      if (written == RecordingNaming.emptyNotePathOf(path)) {
        store.put(RecordingNaming.keepAudioPathOf(path), <int>[1]);
      }
    };

    final report =
        await service.sweep(useOf: (_) => idle, now: now, allNotes: true);

    expect(report.verdicts[path], EmptyNoteVerdict.kept);
    expect(store.files, contains(path));
    expect(store.files, isNot(contains(RecordingNaming.emptyNotePathOf(path))));
  });

  group('killed half way', () {
    test('after the WAV: the empty transcript finishes the job', () async {
      final path = note('20260915-100000', text: '', marked: true);
      store.files.remove(path);

      final report = await service.sweep(useOf: (_) => idle, now: now);

      expect(report.deleted, <String>[path]);
      expect(filesOf(path), isEmpty);
    });

    test('after the transcript: the leftover sidecars go', () async {
      final path = note('20260915-100000', marked: true);
      store.files.remove(path);
      store.put(RecordingNaming.speakerNamesPathOf(path), <int>[1]);
      store.put(RecordingNaming.keepAudioPathOf(path), <int>[1]);

      final report = await service.sweep(useOf: (_) => idle, now: now);

      expect(report.deleted, <String>[path]);
      expect(filesOf(path), isEmpty);
    });

    test('a delete that throws leaves the marker for next time', () async {
      final path = note('20260915-100000', text: '');
      store.failDeletes = <String>{RecordingNaming.transcriptPathOf(path)};

      final report =
          await service.sweep(useOf: (_) => idle, now: now, allNotes: true);

      expect(report.failed, <String>[path]);
      expect(store.files, isNot(contains(path)));
      expect(store.files, contains(RecordingNaming.emptyNotePathOf(path)));
      // Not remembered as done: the one-time sweep runs again.
      expect(await service.isFullSweepDone(), isFalse);

      store.failDeletes = <String>{};
      expect((await service.sweep(useOf: (_) => idle, now: now)).deleted,
          <String>[path]);
      expect(filesOf(path), isEmpty);
    });
  });

  test('the library lists a marked note until it is deleted, and deleting a '
      'recording by hand removes the marker', () async {
    final library = LibraryService(fileStore: store, directory: dir);
    final path = note('20260915-100000', text: '', marked: true);
    expect((await library.refresh()).map((r) => r.path), <String>[path]);

    await library.delete(path);

    expect(filesOf(path), isEmpty);
  });

  test('an unreadable directory is nothing to do', () async {
    final report = await EmptyNoteService(
      fileStore: _ThrowingList(),
      directory: dir,
      transcripts: TranscriptStore(fileStore: store),
      settingsDirectory: settingsDir,
    ).sweep(useOf: (_) => idle, now: now, allNotes: true);
    expect(report.verdicts, isEmpty);
  });
}

class _ThrowingList extends InMemoryFileStore {
  @override
  Future<List<String>> list(String directory) async =>
      throw StateError('no listing');
}
