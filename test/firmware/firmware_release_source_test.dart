import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/firmware_release_source.dart';
import 'package:voicenotetaker_app/model/firmware_update.dart';

import 'firmware_fakes.dart';

const String api =
    'https://api.github.com/repos/${GitHubFirmwareReleaseSource.defaultRepository}'
    '/releases?per_page=${GitHubFirmwareReleaseSource.pageSize}';
const String sha =
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

Map<String, Object?> asset(String name, {int size = 123}) => <String, Object?>{
      'name': name,
      'size': size,
      'browser_download_url': 'https://github.test/dl/$name',
    };

Map<String, Object?> release(
  String tag,
  List<Map<String, Object?>> assets, {
  bool draft = false,
  bool prerelease = false,
  String body = '',
}) =>
    <String, Object?>{
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'published_at': '2026-10-18T10:00:00Z',
      'body': body,
      'assets': assets,
    };

List<Map<String, Object?>> firmwareAssets(String version, {String suffix = ''}) =>
    [
      asset('voiceNotetaker-$version$suffix.zip', size: 4096),
      asset('voiceNotetaker-$version$suffix.zip.sha256'),
    ];

void main() {
  late FakeDownloadClient client;

  setUp(() => client = FakeDownloadClient());

  void publish(List<Map<String, Object?>> releases) =>
      client.text(api, jsonEncode(releases));

  void digestFor(String zip, [String line = '$sha  ']) => client.text(
        'https://github.test/dl/$zip.sha256',
        line.endsWith('  ') ? '$line$zip\n' : line,
      );

  test('reads the zip, its size, its digest and the notes', () async {
    publish([
      release('fw-v0.2.0', firmwareAssets('0.2.0'), body: 'Faster sync.'),
    ]);
    digestFor('voiceNotetaker-0.2.0.zip');
    final latest =
        await GitHubFirmwareReleaseSource(client: client).latest();
    expect(latest!.version, FirmwareVersion.tryParse('0.2.0'));
    expect(latest.zipName, 'voiceNotetaker-0.2.0.zip');
    expect(latest.zipUrl, 'https://github.test/dl/voiceNotetaker-0.2.0.zip');
    expect(latest.sizeBytes, 4096);
    expect(latest.sha256, sha);
    expect(latest.notes, 'Faster sync.');
    expect(latest.publishedAt, DateTime.utc(2026, 10, 18, 10));
  });

  test('the highest firmware wins, not the newest release', () async {
    publish([
      release('models-v2', [asset('encoder.onnx')]),
      release('fw-v0.1.0', firmwareAssets('0.1.0')),
      release('fw-v0.10.0', firmwareAssets('0.10.0')),
      release('fw-v0.9.0', firmwareAssets('0.9.0')),
    ]);
    digestFor('voiceNotetaker-0.10.0.zip');
    final latest =
        await GitHubFirmwareReleaseSource(client: client).latest();
    expect('${latest!.version}', '0.10.0');
  });

  test('drafts, pre-releases and a zip without its digest are skipped',
      () async {
    publish([
      release('a', firmwareAssets('0.5.0'), draft: true),
      release('b', firmwareAssets('0.4.0'), prerelease: true),
      release('c', [asset('voiceNotetaker-0.3.0.zip')]),
      release('d', firmwareAssets('0.2.0')),
    ]);
    digestFor('voiceNotetaker-0.2.0.zip');
    final latest =
        await GitHubFirmwareReleaseSource(client: client).latest();
    expect('${latest!.version}', '0.2.0');
  });

  test('the SD build is never taken for the default one, nor the reverse',
      () async {
    publish([
      release('e', [
        ...firmwareAssets('0.3.0', suffix: '-sd'),
        ...firmwareAssets('0.2.0'),
      ]),
    ]);
    digestFor('voiceNotetaker-0.2.0.zip');
    digestFor('voiceNotetaker-0.3.0-sd.zip');
    final plain = (await GitHubFirmwareReleaseSource(client: client).latest())!;
    expect(plain.zipName, 'voiceNotetaker-0.2.0.zip');
    expect(plain.version.variant, isNull);
    final sd =
        await GitHubFirmwareReleaseSource(client: client).latest(variant: 'sd');
    expect(sd!.zipName, 'voiceNotetaker-0.3.0-sd.zip');
    expect(sd.version.full, '0.3.0+sd');
  });

  test('each variant gets only its own zip, and none means none', () async {
    publish([
      release('g', [
        ...firmwareAssets('0.4.0', suffix: '-nostorage'),
        ...firmwareAssets('0.3.0', suffix: '-sd'),
      ]),
    ]);
    digestFor('voiceNotetaker-0.4.0-nostorage.zip');
    digestFor('voiceNotetaker-0.3.0-sd.zip');
    final source = GitHubFirmwareReleaseSource(client: client);
    expect(await source.latest(), isNull, reason: 'no default zip published');
    expect((await source.latest(variant: 'sd'))!.zipName,
        'voiceNotetaker-0.3.0-sd.zip');
    expect((await source.latest(variant: 'nostorage'))!.zipName,
        'voiceNotetaker-0.4.0-nostorage.zip');
  });

  test('model releases in the same list are ignored, whatever their tag',
      () async {
    publish([
      release('models-v1', [
        asset('sherpa_encoder.onnx'),
        asset('sherpa_tokens.txt'),
        asset('voiceNotetaker-notes.zip'),
        asset('voiceNotetaker-notes.zip.sha256'),
      ]),
      release('fw-v0.2.0', firmwareAssets('0.2.0')),
      release('models-v2', [asset('voiceNotetaker.zip')]),
    ]);
    digestFor('voiceNotetaker-0.2.0.zip');
    final latest = await GitHubFirmwareReleaseSource(client: client).latest();
    expect(latest!.zipName, 'voiceNotetaker-0.2.0.zip');
  });

  test('firmware on a release tagged like the models is still found',
      () async {
    publish([
      release('models-v1', [asset('encoder.onnx'), ...firmwareAssets('0.3.0')]),
      release('models-v0', firmwareAssets('0.1.0')),
    ]);
    digestFor('voiceNotetaker-0.3.0.zip');
    final latest = await GitHubFirmwareReleaseSource(client: client).latest();
    expect('${latest!.version}', '0.3.0');
  });

  test('no network is no release, not an exception', () async {
    client.offline = true;
    expect(await GitHubFirmwareReleaseSource(client: client).latest(), isNull);
  });

  test('a rate limit, a 404 or garbage is no release', () async {
    client.text(api, '{"message":"API rate limit exceeded"}', status: 403);
    expect(await GitHubFirmwareReleaseSource(client: client).latest(), isNull);
    client.text(api, 'not json');
    expect(await GitHubFirmwareReleaseSource(client: client).latest(), isNull);
    client.text(api, '{"message":"Not Found"}');
    expect(await GitHubFirmwareReleaseSource(client: client).latest(), isNull);
  });

  test('a digest file that does not name the zip is no release', () async {
    publish([release('f', firmwareAssets('0.2.0'))]);
    digestFor('voiceNotetaker-0.2.0.zip', '$sha  something-else.zip\n');
    expect(await GitHubFirmwareReleaseSource(client: client).latest(), isNull);
  });

  group('parseSha256File', () {
    String? parse(String text) => GitHubFirmwareReleaseSource.parseSha256File(
        text, 'voiceNotetaker-0.2.0.zip');

    test('reads sha256sum output, text or binary mode', () {
      expect(parse('$sha  voiceNotetaker-0.2.0.zip\n'), sha);
      expect(parse('$sha *voiceNotetaker-0.2.0.zip'), sha);
      expect(parse(sha.toUpperCase()), sha);
    });

    test('refuses a short or non-hex digest', () {
      expect(parse('abc  voiceNotetaker-0.2.0.zip'), isNull);
      expect(parse('${'g' * 64}  voiceNotetaker-0.2.0.zip'), isNull);
      expect(parse(''), isNull);
    });
  });
}
