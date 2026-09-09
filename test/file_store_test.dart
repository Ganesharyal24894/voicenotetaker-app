import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

/// Exercises the real `dart:io` store, in particular [FileSink.patch]: the
/// recording service relies on being able to rewrite the WAV length fields
/// after the payload has been streamed, and a broken patch produces files that
/// look fine on disk but decode to the wrong length.
void main() {
  late Directory temp;
  const store = IoFileStore();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('voicenotetaker_test_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  String path(String name) => store.join(temp.path, name);

  test('openWrite creates missing parent directories', () async {
    final nested = store.join(store.join(temp.path, 'a'), 'b.bin');
    final sink = await store.openWrite(nested);
    await sink.add([1, 2, 3]);
    await sink.close();
    expect(await store.exists(nested), isTrue);
    expect(await store.read(nested), equals(Uint8List.fromList([1, 2, 3])));
  });

  test('sequential adds append in order', () async {
    final p = path('append.bin');
    final sink = await store.openWrite(p);
    await sink.add([1, 2]);
    await sink.add([3, 4]);
    await sink.add([5]);
    await sink.close();
    expect(await store.read(p), equals(Uint8List.fromList([1, 2, 3, 4, 5])));
    expect(sink.bytesWritten, 5);
  });

  test('adds issued without awaiting still land in order', () async {
    // The recording service fires writes without awaiting so disk I/O never
    // stalls the notification stream; the sink must serialise them itself.
    final p = path('unawaited.bin');
    final sink = await store.openWrite(p);
    final futures = [
      for (var i = 0; i < 50; i++) sink.add([i]),
    ];
    await Future.wait(futures);
    await sink.close();
    expect(
      await store.read(p),
      equals(Uint8List.fromList(List<int>.generate(50, (i) => i))),
    );
  });

  test('patch overwrites in place without moving the append cursor', () async {
    final p = path('patch.bin');
    final sink = await store.openWrite(p);
    await sink.add([0, 0, 0, 0, 9, 9]);
    await sink.patch(1, [0xAA, 0xBB]);
    await sink.add([7]);
    await sink.close();
    expect(
      await store.read(p),
      equals(Uint8List.fromList([0, 0xAA, 0xBB, 0, 9, 9, 7])),
    );
  });

  test('a streamed WAV ends up byte-identical to a one-shot WAV', () async {
    final pcm = Uint8List.fromList(List<int>.generate(2048, (i) => i & 0xFF));
    final p = path('stream.wav');

    final sink = await store.openWrite(p);
    await sink.add(WavWriter.buildHeader(
      sampleRateHz: 16000,
      channels: 1,
      bitsPerSample: 16,
    ));
    for (var offset = 0; offset < pcm.length; offset += 164) {
      final end = (offset + 164).clamp(0, pcm.length);
      await sink.add(pcm.sublist(offset, end));
    }
    await sink.patch(
      WavWriter.chunkSizeOffset,
      WavWriter.chunkSizeBytes(pcm.length),
    );
    await sink.patch(
      WavWriter.dataSizeOffset,
      WavWriter.dataSizeBytes(pcm.length),
    );
    await sink.close();

    expect(
      await store.read(p),
      equals(WavWriter.wrapPcm(
        pcm,
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      )),
    );
  });

  test('openWrite truncates an existing file', () async {
    final p = path('truncate.bin');
    await store.writeBytes(p, List<int>.filled(100, 0xFF));
    final sink = await store.openWrite(p);
    await sink.add([1]);
    await sink.close();
    expect(await store.read(p), equals(Uint8List.fromList([1])));
  });

  test('adding to a closed sink throws', () async {
    final sink = await store.openWrite(path('closed.bin'));
    await sink.close();
    expect(() => sink.add([1]), throwsStateError);
    expect(() => sink.patch(0, [1]), throwsStateError);
  });

  test('list returns the files in a directory, sorted', () async {
    await store.writeBytes(path('b.wav'), [1]);
    await store.writeBytes(path('a.wav'), [1]);
    expect(
      await store.list(temp.path),
      equals([path('a.wav'), path('b.wav')]),
    );
  });

  test('list of a missing directory is empty', () async {
    expect(await store.list(store.join(temp.path, 'nope')), isEmpty);
  });

  test('delete removes a file and is safe when it is already gone', () async {
    final p = path('gone.bin');
    await store.writeBytes(p, [1]);
    await store.delete(p);
    expect(await store.exists(p), isFalse);
    await expectLater(store.delete(p), completes);
  });

  group('readRange, which the library uses to read WAV headers', () {
    test('returns exactly the bytes asked for', () async {
      final p = path('range.bin');
      await store.writeBytes(p, List<int>.generate(100, (i) => i));

      expect(await store.readRange(p, 0, 4), equals([0, 1, 2, 3]));
      expect(await store.readRange(p, 40, 44), equals([40, 41, 42, 43]));
      expect(await store.readRange(p, 99, 100), equals([99]));
    });

    test('does not read the rest of the file', () async {
      // The point of the method: a 10 MB recording must not be pulled into
      // memory to look at its 44-byte header.
      final p = path('big.bin');
      await store.writeBytes(p, Uint8List(10 * 1024 * 1024));
      final head = await store.readRange(p, 0, 44);
      expect(head, hasLength(44));
    });

    test('is clamped to the end of the file', () async {
      final p = path('short.bin');
      await store.writeBytes(p, [1, 2, 3]);
      expect(await store.readRange(p, 0, 4096), equals([1, 2, 3]));
      expect(await store.readRange(p, 3, 4096), isEmpty);
      expect(await store.readRange(p, 10, 20), isEmpty);
    });

    test('an empty range reads nothing', () async {
      final p = path('empty-range.bin');
      await store.writeBytes(p, [1, 2, 3]);
      expect(await store.readRange(p, 2, 2), isEmpty);
    });

    test('rejects a nonsense range', () async {
      final p = path('bad-range.bin');
      await store.writeBytes(p, [1, 2, 3]);
      expect(() => store.readRange(p, -1, 2), throwsArgumentError);
      expect(() => store.readRange(p, 2, 1), throwsArgumentError);
    });

    test('a missing file throws rather than pretending to be empty', () async {
      await expectLater(
        store.readRange(path('nope.bin'), 0, 4),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('stat', () {
    test('reports the size and modification time', () async {
      final p = path('stat.bin');
      final before = DateTime.now().subtract(const Duration(seconds: 2));
      await store.writeBytes(p, List<int>.filled(1234, 7));

      final info = (await store.stat(p))!;
      expect(info.path, p);
      expect(info.sizeBytes, 1234);
      expect(info.modifiedAt.isAfter(before), isTrue);
      expect(info.toString(), contains('1234 B'));
    });

    test('sees a file grow as it is written', () async {
      final p = path('growing.wav');
      final sink = await store.openWrite(p);
      await sink.add(List<int>.filled(44, 0));
      await sink.close();

      expect((await store.stat(p))!.sizeBytes, 44);
    });

    test('a missing file has no stat', () async {
      expect(await store.stat(path('missing.bin')), isNull);
    });
  });

  test('join does not double the separator', () async {
    final sep = Platform.pathSeparator;
    expect(store.join('/tmp', 'x'), '/tmp${sep}x');
    expect(store.join('/tmp$sep', 'x'), '/tmp${sep}x');
    expect(store.join('', 'x'), 'x');
  });
}
