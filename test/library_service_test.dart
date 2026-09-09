import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

/// In-memory [FileStore], hand-written like the recording service's own: the
/// library is domain logic and must be exercisable with no filesystem at all.
class InMemoryFileStore implements FileStore {
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, DateTime> modified = <String, DateTime>{};

  /// Paths whose reads must fail, for the unreadable-file case.
  final Set<String> unreadable = <String>{};

  int readRangeCalls = 0;
  int largestReadRange = 0;

  void put(String path, List<int> bytes, {DateTime? at}) {
    files[path] = Uint8List.fromList(bytes);
    modified[path] = at ?? DateTime(2026, 1, 1);
  }

  @override
  Future<FileSink> openWrite(String path) async =>
      throw UnimplementedError('the library never writes');

  @override
  Future<Uint8List> read(String path) async {
    if (unreadable.contains(path)) throw StateError('unreadable: $path');
    final bytes = files[path];
    if (bytes == null) throw StateError('no such file: $path');
    return bytes;
  }

  @override
  Future<Uint8List> readRange(String path, int start, int end) async {
    readRangeCalls++;
    if (end - start > largestReadRange) largestReadRange = end - start;
    final bytes = await read(path);
    final from = start.clamp(0, bytes.length);
    final to = end.clamp(from, bytes.length);
    return Uint8List.sublistView(bytes, from, to);
  }

  @override
  Future<FileInfo?> stat(String path) async {
    final bytes = files[path];
    if (bytes == null) return null;
    return FileInfo(
      path: path,
      sizeBytes: bytes.length,
      modifiedAt: modified[path]!,
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async =>
      put(path, bytes);

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> delete(String path) async {
    files.remove(path);
    modified.remove(path);
  }

  @override
  Future<List<String>> list(String directory) async => files.keys
      .where((p) => p.startsWith('$directory/'))
      .toList()
    ..sort();

  @override
  String join(String directory, String name) => '$directory/$name';
}

const String dir = '/documents/recordings';

/// A real WAV file of [length] at the recorder's own format, header included.
Uint8List wavOf(Duration length, {int sampleRateHz = 16000, int channels = 1}) {
  final bytes = (length.inMilliseconds * sampleRateHz * channels * 2) ~/ 1000;
  return WavWriter.wrapPcm(
    Uint8List(bytes),
    sampleRateHz: sampleRateHz,
    channels: channels,
    bitsPerSample: 16,
  );
}

void main() {
  late InMemoryFileStore store;
  late LibraryService library;

  setUp(() {
    store = InMemoryFileStore();
    library = LibraryService(fileStore: store, directory: dir);
  });

  tearDown(() async => library.dispose());

  String seed(
    DateTime at, {
    Duration length = const Duration(seconds: 30),
    int sampleRateHz = 16000,
    int channels = 1,
  }) {
    final path = '$dir/${RecordingNaming.fileName(at)}';
    store.put(
      path,
      wavOf(length, sampleRateHz: sampleRateHz, channels: channels),
      at: at,
    );
    return path;
  }

  group('the file-name convention', () {
    test('a name round-trips through the writer and the reader', () {
      final when = DateTime(2026, 9, 10, 14, 30, 5);
      final name = RecordingNaming.fileName(when);

      expect(name, 'voicenote-20260910-143005.wav');
      expect(RecordingNaming.timestampOf(name), when);
    });

    test('midnight and single-digit fields keep their padding', () {
      expect(
        RecordingNaming.fileName(DateTime(2026, 1, 2, 0, 0, 0)),
        'voicenote-20260102-000000.wav',
      );
      expect(
        RecordingNaming.timestampOf('voicenote-20260102-000000.wav'),
        DateTime(2026, 1, 2),
      );
    });

    test('anything else is not one of ours', () {
      for (final name in <String>[
        'note.wav',
        'voicenote-2026091-143005.wav',
        'voicenote-20260910-143005.mp3',
        'voicenote-abcdefgh-143005.wav',
        'voicenote-20261345-990000.wav',
        'voicenote-.wav',
      ]) {
        expect(RecordingNaming.timestampOf(name), isNull, reason: name);
      }
    });
  });

  group('listing', () {
    test('is newest first, whatever order the store hands them over', () {
      seed(DateTime(2026, 9, 8, 11, 2));
      seed(DateTime(2026, 9, 10, 9, 14));
      seed(DateTime(2026, 9, 9, 16, 40));

      return library.refresh().then((recordings) {
        expect(
          recordings.map((r) => r.recordedAt).toList(),
          <DateTime>[
            DateTime(2026, 9, 10, 9, 14),
            DateTime(2026, 9, 9, 16, 40),
            DateTime(2026, 9, 8, 11, 2),
          ],
        );
      });
    });

    test('ignores everything that is not a .wav', () async {
      seed(DateTime(2026, 9, 10, 9, 14));
      store.put('$dir/notes.txt', <int>[1, 2, 3]);
      store.put('$dir/voicenote-20260910-101010.wav.tmp', <int>[1, 2, 3]);

      final recordings = await library.refresh();
      expect(recordings, hasLength(1));
      expect(recordings.single.name, 'voicenote-20260910-091400.wav');
    });

    test('does not reach outside its own directory', () async {
      seed(DateTime(2026, 9, 10, 9, 14));
      store.put('/documents/other/voicenote-20260910-101010.wav', wavOf(
        const Duration(seconds: 5),
      ));

      expect(await library.refresh(), hasLength(1));
    });

    test('an empty directory is empty, not an error', () async {
      expect(await library.refresh(), isEmpty);
      expect(library.current, isEmpty);
    });

    test('publishes each new list on the stream', () async {
      final published = <List<RecordingInfo>>[];
      final subscription = library.recordings.listen(published.add);

      seed(DateTime(2026, 9, 10, 9, 14));
      await library.refresh();
      seed(DateTime(2026, 9, 10, 10, 14));
      await library.refresh();
      await Future<void>.delayed(Duration.zero);

      expect(published.map((l) => l.length).toList(), <int>[1, 2]);
      await subscription.cancel();
    });

    test('current mirrors the last refresh and cannot be mutated', () async {
      seed(DateTime(2026, 9, 10, 9, 14));
      await library.refresh();

      expect(library.current, hasLength(1));
      expect(
        () => library.current.add(library.current.first),
        throwsUnsupportedError,
      );
    });
  });

  group('metadata', () {
    test('name, timestamp, size and duration come off the real file',
        () async {
      final path = seed(
        DateTime(2026, 9, 10, 9, 14),
        length: const Duration(minutes: 4, seconds: 12),
      );

      final info = (await library.refresh()).single;

      expect(info.path, path);
      expect(info.name, 'voicenote-20260910-091400.wav');
      expect(info.recordedAt, DateTime(2026, 9, 10, 9, 14));
      // 252 s * 16000 Hz * 2 B + the 44-byte header.
      expect(info.sizeBytes, 252 * 32000 + WavWriter.headerLength);
      expect(info.duration, const Duration(minutes: 4, seconds: 12));
      expect(info.sampleRateHz, 16000);
      expect(info.channels, 1);
    });

    test('the duration is read from the header, not guessed from the size',
        () async {
      // Two files of the SAME size whose headers declare different rates: a
      // size-based guess would call them equal.
      store.put(
        '$dir/voicenote-20260910-090000.wav',
        wavOf(const Duration(seconds: 10)),
      );
      store.put(
        '$dir/voicenote-20260910-080000.wav',
        WavWriter.wrapPcm(
          Uint8List(320000),
          sampleRateHz: 8000,
          channels: 1,
          bitsPerSample: 16,
        ),
      );

      final recordings = await library.refresh();
      expect(recordings.first.sizeBytes, recordings.last.sizeBytes);
      expect(recordings.first.duration, const Duration(seconds: 10));
      expect(recordings.last.duration, const Duration(seconds: 20));
    });

    test('stereo and other rates are described as the header says', () async {
      seed(
        DateTime(2026, 9, 10, 9, 14),
        length: const Duration(seconds: 3),
        sampleRateHz: 44100,
        channels: 2,
      );

      final info = (await library.refresh()).single;
      expect(info.sampleRateHz, 44100);
      expect(info.channels, 2);
      expect(info.duration, const Duration(seconds: 3));
    });

    test('a file this app did not name falls back to its modified time',
        () async {
      store.put(
        '$dir/imported.wav',
        wavOf(const Duration(seconds: 5)),
        at: DateTime(2026, 5, 4, 13, 45),
      );

      final info = (await library.refresh()).single;
      expect(info.recordedAt, DateTime(2026, 5, 4, 13, 45));
      expect(info.duration, const Duration(seconds: 5));
    });

    test('only the head of each file is read, never the whole thing', () async {
      seed(DateTime(2026, 9, 10, 9, 14), length: const Duration(minutes: 20));

      await library.refresh();
      expect(store.readRangeCalls, 1);
      // 20 minutes is 38 MB; the library must not pull that into memory.
      expect(store.largestReadRange, lessThanOrEqualTo(4096));
    });

    test('describe returns null for a file that is not there', () async {
      expect(await library.describe('$dir/missing.wav'), isNull);
    });
  });

  group('files that are wrong', () {
    test('a malformed header leaves the duration null, and still lists',
        () async {
      store.put(
        '$dir/voicenote-20260910-091400.wav',
        List<int>.filled(2000, 0x5A),
      );

      final info = (await library.refresh()).single;
      expect(info.duration, isNull);
      expect(info.sampleRateHz, isNull);
      expect(info.channels, isNull);
      // It exists on disk, so the user must be able to see and delete it.
      expect(info.sizeBytes, 2000);
    });

    test('a header truncated part-way through is not a length', () async {
      final file = wavOf(const Duration(seconds: 10));
      store.put(
        '$dir/voicenote-20260910-091400.wav',
        Uint8List.sublistView(file, 0, 30),
      );

      expect((await library.refresh()).single.duration, isNull);
    });

    test('an empty file is not a length', () async {
      store.put('$dir/voicenote-20260910-091400.wav', const <int>[]);

      final info = (await library.refresh()).single;
      expect(info.sizeBytes, 0);
      expect(info.duration, isNull);
    });

    test('a capture cut off mid-write is timed by the bytes it has', () async {
      // The header claims 10 s but the writer died after 2 s: the length must
      // describe the audio that is actually there.
      final file = wavOf(const Duration(seconds: 10));
      store.put(
        '$dir/voicenote-20260910-091400.wav',
        Uint8List.sublistView(file, 0, WavWriter.headerLength + 64000),
      );

      expect(
        (await library.refresh()).single.duration,
        const Duration(seconds: 2),
      );
    });

    test('a header with no payload at all is zero length', () async {
      store.put(
        '$dir/voicenote-20260910-091400.wav',
        WavWriter.buildHeader(
          sampleRateHz: 16000,
          channels: 1,
          bitsPerSample: 16,
        ),
      );

      expect((await library.refresh()).single.duration, Duration.zero);
    });

    test('an unreadable file does not take the whole library down', () async {
      seed(DateTime(2026, 9, 10, 9, 14));
      final broken = '$dir/voicenote-20260910-101010.wav';
      store.put(broken, wavOf(const Duration(seconds: 5)));
      store.unreadable.add(broken);

      final recordings = await library.refresh();
      expect(recordings, hasLength(2));
      expect(
        recordings.firstWhere((r) => r.path == broken).duration,
        isNull,
      );
    });
  });

  group('delete', () {
    test('removes the file and re-publishes the list', () async {
      final keep = seed(DateTime(2026, 9, 10, 9, 14));
      final drop = seed(DateTime(2026, 9, 10, 10, 14));
      await library.refresh();

      final published = <List<RecordingInfo>>[];
      final subscription = library.recordings.listen(published.add);

      await library.delete(drop);
      await Future<void>.delayed(Duration.zero);

      expect(await store.exists(drop), isFalse);
      expect(await store.exists(keep), isTrue);
      expect(library.current.map((r) => r.path), <String>[keep]);
      expect(published.single.map((r) => r.path), <String>[keep]);

      await subscription.cancel();
    });

    test('deleting the last recording empties the library', () async {
      final only = seed(DateTime(2026, 9, 10, 9, 14));
      await library.refresh();

      await library.delete(only);
      expect(library.current, isEmpty);
    });

    test('deleting something that is already gone is not an error', () async {
      seed(DateTime(2026, 9, 10, 9, 14));
      await library.refresh();

      await library.delete('$dir/never-existed.wav');
      expect(library.current, hasLength(1));
    });
  });
}
