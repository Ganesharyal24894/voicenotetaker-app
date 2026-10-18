import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/hashing_crypto.dart';
import 'package:voicenotetaker_app/services/firmware/firmware_download.dart';

import 'firmware_fakes.dart';

void main() {
  late Directory temp;
  late FakeDownloadClient client;
  late FirmwareDownload download;
  const store = IoFileStore();
  final release = releaseOf('0.2.0');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('firmware_download_test');
    client = FakeDownloadClient();
    client.routes[release.zipUrl] = (200, packageBytes);
    download = FirmwareDownload(
      fileStore: store,
      client: client,
      hashing: const CryptoHashing(),
      directory: temp.path,
    );
  });

  tearDown(() => temp.delete(recursive: true));

  test('a verified package takes its real name; a second fetch is free',
      () async {
    final path = await download.fetch(release);
    expect(await File(path).readAsBytes(), packageBytes);
    expect(await download.verifiedPath(release), path);
    await download.fetch(release);
    expect(client.requested, hasLength(1));
  });

  test('a partial file is resumed from where it stopped', () async {
    await store.writeBytes(
        '${download.pathOf(release)}.part', packageBytes.sublist(0, 1000));
    await download.fetch(release);
    expect(await File(download.pathOf(release)).readAsBytes(), packageBytes);
  });

  test('a body that ends early is kept to resume, not called corrupt',
      () async {
    client.routes[release.zipUrl] = (200, packageBytes.sublist(0, 500));
    await expectLater(
      download.fetch(release),
      throwsA(isA<FirmwareDownloadException>().having(
          (e) => e.fault, 'fault', FirmwareDownloadFault.network)),
    );
    expect(
        await store.stat('${download.pathOf(release)}.part'), isNotNull);
  });

  test('no network is a network fault', () async {
    client.offline = true;
    await expectLater(
      download.fetch(release),
      throwsA(isA<FirmwareDownloadException>().having(
          (e) => e.fault, 'fault', FirmwareDownloadFault.network)),
    );
  });

  test('a tampered package on disk is not trusted', () async {
    await download.fetch(release);
    await store.writeBytes(download.pathOf(release), List<int>.filled(3000, 0));
    expect(await download.verifiedPath(release), isNull);
    expect(await store.stat(download.pathOf(release)), isNull);
  });

  test('prune keeps only the package asked for', () async {
    await download.fetch(release);
    await store.writeBytes(store.join(temp.path, 'voiceNotetaker-0.1.0.zip'),
        const <int>[1]);
    await download.prune(keep: release);
    expect(await store.list(temp.path), [download.pathOf(release)]);
  });
}

