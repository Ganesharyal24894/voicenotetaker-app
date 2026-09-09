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

  test('join does not double the separator', () async {
    final sep = Platform.pathSeparator;
    expect(store.join('/tmp', 'x'), '/tmp${sep}x');
    expect(store.join('/tmp$sep', 'x'), '/tmp${sep}x');
    expect(store.join('', 'x'), 'x');
  });
}
