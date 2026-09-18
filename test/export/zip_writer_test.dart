import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/services/export/zip_writer.dart';

import 'export_fakes.dart';

Uint8List pattern(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 31 + 7) & 0xFF));

void main() {
  late MemoryFileStore store;

  setUp(() => store = MemoryFileStore());

  group('Crc32', () {
    test('matches the known CRC-32 of a short string', () {
      // The value every zip tool agrees on for "hello".
      expect(Crc32.of(utf8.encode('hello')), 0x3610A686);
      expect(Crc32.of(const <int>[]), 0);
    });

    test('a chunked CRC equals the whole-buffer one', () {
      final bytes = pattern(5000);
      final chunked = Crc32();
      for (var at = 0; at < bytes.length; at += 777) {
        final end = at + 777 > bytes.length ? bytes.length : at + 777;
        chunked.add(Uint8List.sublistView(bytes, at, end));
      }
      expect(chunked.value, Crc32.of(bytes));
    });
  });

  group('sizeOf', () {
    test('is the exact length of the archive it describes', () async {
      store
        ..put('/rec/a.wav', pattern(4096))
        ..put('/rec/b.json', utf8.encode('{"a":1}'));

      final expected = ZipWriter.sizeOf(
        names: <String>['recordings/a.wav', 'recordings/b.json'],
        sizes: <int>[4096, 7],
      );

      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await writer.addFile(
        name: 'recordings/a.wav',
        sourcePath: '/rec/a.wav',
        fileStore: store,
        sizeBytes: 4096,
        modifiedAt: DateTime(2026, 9, 18, 14, 30),
      );
      await writer.addFile(
        name: 'recordings/b.json',
        sourcePath: '/rec/b.json',
        fileStore: store,
        sizeBytes: 7,
        modifiedAt: DateTime(2026, 9, 18, 14, 30),
      );
      await writer.close();

      expect(store.bytesOf('/out/notes.zip').length, expected);
    });

    test('an empty archive is the 22-byte end record', () {
      expect(ZipWriter.sizeOf(names: <String>[], sizes: <int>[]), 22);
    });

    test('a longer name costs its bytes twice, once per header', () {
      final short = ZipWriter.sizeOf(names: <String>['a'], sizes: <int>[10]);
      final long = ZipWriter.sizeOf(names: <String>['abcd'], sizes: <int>[10]);
      expect(long - short, 6);
    });

    test('rejects mismatched lists and negative sizes', () {
      expect(
        () => ZipWriter.sizeOf(names: <String>['a'], sizes: <int>[]),
        throwsArgumentError,
      );
      expect(
        () => ZipWriter.sizeOf(names: <String>['a'], sizes: <int>[-1]),
        throwsArgumentError,
      );
    });
  });

  group('the archive it writes', () {
    test('reads back member for member, with the right CRCs', () async {
      final audio = pattern(300000);
      store
        ..put('/rec/voicenote-20260918-143005.wav', audio)
        ..put('/rec/voicenote-20260918-143005.transcript.json',
            utf8.encode('{"segments":[]}'));

      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await writer.addFile(
        name: 'recordings/voicenote-20260918-143005.wav',
        sourcePath: '/rec/voicenote-20260918-143005.wav',
        fileStore: store,
        sizeBytes: audio.length,
        modifiedAt: DateTime(2026, 9, 18, 14, 30, 6),
      );
      await writer.addFile(
        name: 'recordings/voicenote-20260918-143005.transcript.json',
        sourcePath: '/rec/voicenote-20260918-143005.transcript.json',
        fileStore: store,
        sizeBytes: 15,
        modifiedAt: DateTime(2026, 9, 18, 14, 30, 6),
      );
      await writer.close();

      final members = readZip(store.bytesOf('/out/notes.zip'));
      expect(members.map((m) => m.name), <String>[
        'recordings/voicenote-20260918-143005.wav',
        'recordings/voicenote-20260918-143005.transcript.json',
      ]);
      expect(members.first.bytes, audio);
      expect(members.first.crc, Crc32.of(audio));
      expect(utf8.decode(members.last.bytes), '{"segments":[]}');
    });

    test('never reads more than one chunk of a file at a time', () async {
      store.put('/rec/big.wav', pattern(2 * 1024 * 1024));
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await writer.addFile(
        name: 'big.wav',
        sourcePath: '/rec/big.wav',
        fileStore: store,
        sizeBytes: 2 * 1024 * 1024,
        modifiedAt: DateTime(2026),
        chunkBytes: 64 * 1024,
      );
      await writer.close();

      expect(store.largestReadRange, 64 * 1024);
      expect(readZip(store.bytesOf('/out/notes.zip')).single.bytes.length,
          2 * 1024 * 1024);
    });

    test('reports progress in bytes of the member being copied', () async {
      store.put('/rec/big.wav', pattern(1000));
      final seen = <int>[];
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await writer.addFile(
        name: 'big.wav',
        sourcePath: '/rec/big.wav',
        fileStore: store,
        sizeBytes: 1000,
        modifiedAt: DateTime(2026),
        chunkBytes: 250,
        onProgress: seen.add,
      );
      await writer.close();
      expect(seen, <int>[250, 500, 750, 1000]);
    });

    test('a file that vanishes mid-copy is padded, not truncated', () async {
      store.put('/rec/gone.wav', pattern(1000));
      store.unreadable.add('/rec/gone.wav');

      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await writer.addFile(
        name: 'gone.wav',
        sourcePath: '/rec/gone.wav',
        fileStore: store,
        sizeBytes: 1000,
        modifiedAt: DateTime(2026),
      );
      await writer.close();

      final member = readZip(store.bytesOf('/out/notes.zip')).single;
      expect(member.bytes.length, 1000, reason: 'the header must not lie');
      expect(member.bytes.every((b) => b == 0), isTrue);
      expect(member.crc, Crc32.of(Uint8List(1000)));
      expect(writer.incompleteMembers, 1,
          reason: 'the archive is valid, so the only way anyone learns the '
              'audio is missing is this count');
    });

    test('a whole archive that read cleanly reports nothing incomplete',
        () async {
      store.put('/rec/a.wav', pattern(1000));
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await writer.addFile(
        name: 'a.wav',
        sourcePath: '/rec/a.wav',
        fileStore: store,
        sizeBytes: 1000,
        modifiedAt: DateTime(2026),
      );
      await writer.close();
      expect(writer.incompleteMembers, 0);
    });

    test('close refuses an archive with a member it never finished', () async {
      store.put('/rec/big.wav', pattern(100000));
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await expectLater(
        writer.addFile(
          name: 'big.wav',
          sourcePath: '/rec/big.wav',
          fileStore: store,
          sizeBytes: 100000,
          modifiedAt: DateTime(2026),
          chunkBytes: 1024,
          isCancelled: () => true,
        ),
        throwsA(isA<ZipCancelledException>()),
      );
      await expectLater(writer.close(), throwsStateError);
      await writer.abort();
    });

    test('a stop takes effect inside a big member, not after it', () async {
      store.put('/rec/big.wav', pattern(1024 * 1024));
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      var chunks = 0;
      await expectLater(
        writer.addFile(
          name: 'big.wav',
          sourcePath: '/rec/big.wav',
          fileStore: store,
          sizeBytes: 1024 * 1024,
          modifiedAt: DateTime(2026),
          chunkBytes: 64 * 1024,
          isCancelled: () => chunks++ >= 2,
        ),
        throwsA(isA<ZipCancelledException>()),
      );
      expect(chunks, lessThan(6), reason: 'it did not copy the whole file');
      await writer.abort();
    });

    test('addBytes stores exactly what it was given', () async {
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await writer.addBytes(
        name: 'README.txt',
        bytes: utf8.encode('your notes'),
        modifiedAt: DateTime(2026, 9, 18),
      );
      await writer.close();

      final member = readZip(store.bytesOf('/out/notes.zip')).single;
      expect(utf8.decode(member.bytes), 'your notes');
    });

    test('an archive with no members still has an end record', () async {
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/empty.zip');
      await writer.close();
      expect(store.bytesOf('/out/empty.zip').length, 22);
      expect(readZip(store.bytesOf('/out/empty.zip')), isEmpty);
    });

    test('abort leaves the file unfinished and adds nothing more', () async {
      store.put('/rec/a.wav', pattern(100));
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/notes.zip');
      await writer.addFile(
        name: 'a.wav',
        sourcePath: '/rec/a.wav',
        fileStore: store,
        sizeBytes: 100,
        modifiedAt: DateTime(2026),
      );
      await writer.abort();

      expect(
        () => readZip(store.bytesOf('/out/notes.zip')),
        throwsStateError,
        reason: 'no central directory was written',
      );
      expect(
        () => writer.addBytes(
          name: 'b.txt',
          bytes: <int>[1],
          modifiedAt: DateTime(2026),
        ),
        throwsStateError,
      );
    });

    test('refuses to grow past what a plain zip can address', () async {
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/huge.zip');
      store.put('/rec/huge.wav', <int>[]);
      expect(
        () => writer.addFile(
          name: 'huge.wav',
          sourcePath: '/rec/huge.wav',
          fileStore: store,
          sizeBytes: ZipWriter.maxArchiveBytes,
          modifiedAt: DateTime(2026),
        ),
        throwsA(isA<ZipTooLargeException>()),
      );
    });

    test('dates past 2107 are clamped, not wrapped', () async {
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/future.zip');
      await writer.addBytes(
        name: 'a.txt',
        bytes: <int>[1],
        modifiedAt: DateTime(2200, 3, 4),
      );
      await writer.close();

      final bytes = store.bytesOf('/out/future.zip');
      final date = ByteData.sublistView(bytes).getUint16(12, Endian.little);
      expect(date >> 9, 2107 - 1980, reason: 'seven bits is all there is');
      expect((date >> 5) & 0x0F, 3);
      expect(date & 0x1F, 4);
    });

    test('the member limit stays clear of the ZIP64 sentinel', () {
      expect(ZipWriter.maxEntries, lessThan(0xFFFF));
    });

    test('dates before 1980 are clamped, not wrapped', () async {
      final writer =
          await ZipWriter.create(fileStore: store, path: '/out/old.zip');
      await writer.addBytes(
        name: 'a.txt',
        bytes: <int>[1],
        modifiedAt: DateTime(1970, 5, 6),
      );
      await writer.close();

      final bytes = store.bytesOf('/out/old.zip');
      final date = ByteData.sublistView(bytes).getUint16(12, Endian.little);
      expect(date >> 9, 0, reason: '1980 is year zero in a zip');
      expect((date >> 5) & 0x0F, 5);
      expect(date & 0x1F, 6);
    });
  });
}
