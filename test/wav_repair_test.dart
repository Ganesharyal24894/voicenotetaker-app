import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/services/wav_reader.dart';
import 'package:voicenotetaker_app/services/wav_repair.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

import 'view/harness.dart';

/// The startup pass that makes an interrupted recording's header tell the
/// truth about the bytes on disk.
void main() {
  const dir = '/rec';

  List<int> wav({required int claimed, required int actual}) => <int>[
        ...WavWriter.buildHeader(
          sampleRateHz: 16000,
          channels: 1,
          bitsPerSample: 16,
          dataLength: claimed,
        ),
        ...List<int>.filled(actual, 3),
      ];

  WavHeader headerOf(MemoryFileStore store, String path) =>
      WavReader.parse(Uint8List.fromList(store.files[path]!))!;

  test('a placeholder header is patched to the audio on disk', () async {
    final store = MemoryFileStore();
    const path = '$dir/voicenote-20260914-100000.wav';
    store.files[path] = wav(claimed: 0, actual: 32000);

    expect(await WavRepair.repair(store, path), isTrue);

    final header = headerOf(store, path);
    expect(header.dataLength, 32000);
    expect(header.duration, const Duration(seconds: 1));
    final riff = ByteData.sublistView(Uint8List.fromList(store.files[path]!))
        .getUint32(4, Endian.little);
    expect(riff, 36 + 32000);
  });

  test('a header a few seconds behind is brought up to date', () async {
    final store = MemoryFileStore();
    const path = '$dir/a.wav';
    store.files[path] = wav(claimed: 16000, actual: 48000);

    expect(await WavRepair.repair(store, path), isTrue);
    expect(headerOf(store, path).dataLength, 48000);
  });

  test('a torn last sample is left out of the length', () async {
    final store = MemoryFileStore();
    const path = '$dir/a.wav';
    store.files[path] = wav(claimed: 0, actual: 32001);

    await WavRepair.repair(store, path);
    expect(headerOf(store, path).dataLength, 32000);
  });

  test('a header that is already right is not touched', () async {
    final store = MemoryFileStore();
    const path = '$dir/a.wav';
    store.files[path] = wav(claimed: 32000, actual: 32000);

    expect(await WavRepair.repair(store, path), isFalse);
    expect(store.patched, isEmpty);
  });

  test('a file that is not a WAV is left alone', () async {
    final store = MemoryFileStore();
    const path = '$dir/a.wav';
    store.files[path] = <int>[1, 2, 3, 4, 5];

    expect(await WavRepair.repair(store, path), isFalse);
    expect(store.files[path], <int>[1, 2, 3, 4, 5]);
  });

  test('the directory pass repairs recordings only and reports them',
      () async {
    final store = MemoryFileStore();
    store.files['$dir/broken.wav'] = wav(claimed: 0, actual: 3200);
    store.files['$dir/fine.wav'] = wav(claimed: 3200, actual: 3200);
    store.files['$dir/broken.transcript.json'] = <int>[123, 125];

    final repaired = await WavRepair.repairDirectory(store, dir);

    expect(repaired, <String>['$dir/broken.wav']);
    expect(store.patched.toSet(), <String>{'$dir/broken.wav'});
  });

  test('one file that cannot be patched does not stop the rest', () async {
    final store = _FailingPatchStore()
      ..failOn = '$dir/a.wav'
      ..files['$dir/a.wav'] = wav(claimed: 0, actual: 3200)
      ..files['$dir/b.wav'] = wav(claimed: 0, actual: 3200);

    final repaired = await WavRepair.repairDirectory(store, dir);

    expect(repaired, <String>['$dir/b.wav']);
  });

  test('IoFileStore.patchBytes rewrites in place without truncating',
      () async {
    final temp = await Directory.systemTemp.createTemp('wav_repair_');
    addTearDown(() => temp.delete(recursive: true));
    const store = IoFileStore();
    final path = store.join(temp.path, 'voicenote-20260914-100000.wav');
    await store.writeBytes(path, wav(claimed: 0, actual: 64000));

    expect(await WavRepair.repair(store, path), isTrue);

    final bytes = await store.read(path);
    expect(bytes.length, 44 + 64000);
    expect(WavReader.parse(bytes)!.dataLength, 64000);
    expect(bytes.last, 3);
  });
}

class _FailingPatchStore extends MemoryFileStore {
  String? failOn;

  @override
  Future<void> patchBytes(String path, int offset, List<int> bytes) {
    if (path == failOn) throw Exception('read-only: $path');
    return super.patchBytes(path, offset, bytes);
  }
}
