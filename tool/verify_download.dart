// Proves the model-download path against the real internet, with the real
// service: `IoDownloadClient`, `IoFileStore`, `CryptoHashing` and
// `ModelDownloadService`, exactly as the app wires them.
//
// IT IS NOT A TEST AND IS NEVER RUN BY `flutter test`. The suite has no
// network in it; this is the one place bytes really move, run by hand when the
// release changes.
//
// USAGE
//
//   dart run tool/verify_download.dart                  # the smallest set
//   dart run tool/verify_download.dart --set <id>       # one set by id
//   dart run tool/verify_download.dart --all --head-only
//   dart run tool/verify_download.dart \
//       --url <https://...> --name <file> --size <bytes> --sha256 <hex>
//
// Options:
//   --head-only   ask for one byte of each file and report the status, the
//                 length and whether the server honours a Range request.
//                 Nothing is downloaded.
//   --no-resume   skip the interrupt-and-resume leg of the check.
//   --out <dir>   where to work; a temp directory by default, removed after.
//
// What a full run proves: the URL answers unauthenticated, the redirect to the
// storage host keeps the `Range` header, an interrupted download resumes from
// the byte it stopped on, the sha256 matches, and the file ends up under the
// name the engine loads with nothing left under `.part`.

import 'dart:io';

import 'package:voicenotetaker_app/drivers/download_client.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/hashing_crypto.dart';
import 'package:voicenotetaker_app/drivers/network_status.dart';
import 'package:voicenotetaker_app/model/model_download.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/model_download_service.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';

Future<int> main(List<String> args) async {
  final options = _Options.parse(args);
  final client = IoDownloadClient();
  try {
    final releases = options.releases();
    if (options.headOnly) {
      var ok = true;
      for (final release in releases) {
        for (final file in release.files) {
          ok = await _head(client, release, file) && ok;
        }
      }
      return ok ? 0 : 1;
    }

    final release = releases.single;
    final workingDirectory = options.outDirectory ??
        await Directory.systemTemp.createTemp('model-download-check-');
    stdout.writeln('Working in ${workingDirectory.path}');
    try {
      return await _download(client, release, workingDirectory, options);
    } finally {
      if (options.outDirectory == null) {
        await workingDirectory.delete(recursive: true);
      }
    }
  } finally {
    client.close();
  }
}

/// One byte of the file, to see whether the URL answers and whether the host
/// serves ranges.
Future<bool> _head(
  DownloadClient client,
  ModelRelease release,
  DownloadableFile file,
) async {
  stdout.write('${release.id}/${file.name} ... ');
  try {
    final response = await client.get(file.url, from: file.sizeBytes - 1);
    await response.abort();
    final ranged = response.isPartial;
    stdout.writeln(
      'HTTP ${response.statusCode}'
      '${ranged ? ', ranges honoured' : ', NO range support'}',
    );
    return ranged;
  } on DownloadException catch (error) {
    stdout.writeln('FAILED: ${error.message}');
    return false;
  }
}

Future<int> _download(
  DownloadClient client,
  ModelRelease release,
  Directory workingDirectory,
  _Options options,
) async {
  const fileStore = IoFileStore();
  final models = SpeechModelStore(
    fileStore: fileStore,
    modelsDirectory: workingDirectory.path,
  );

  if (!options.skipResume) {
    // Leg one: stop part way, on purpose, so leg two has to resume.
    final file = release.files.first;
    final partPath = models.partPathOf(release, file);
    final wanted = file.sizeBytes ~/ 3;
    await Directory(models.releaseDirectory(release)).create(recursive: true);
    final response = await client.get(file.url);
    final sink = await fileStore.openAppend(partPath);
    var written = 0;
    await for (final chunk in response.body) {
      await sink.add(chunk);
      written += chunk.length;
      if (written >= wanted) break;
    }
    await sink.close();
    stdout.writeln(
      'Stopped ${file.name} on purpose after $written of '
      '${file.sizeBytes} B',
    );
  }

  final service = ModelDownloadService(
    fileStore: fileStore,
    models: models,
    client: client,
    hashing: const CryptoHashing(),
    // The laptop is on whatever it is on; the gate is the app's, not this
    // script's.
    network: const FixedNetworkStatus(NetworkKind.unknown),
    catalogue: <ModelRelease>[release],
  );

  var lastPercent = -1;
  service.changes.listen((status) {
    final percent = (status.progress * 100).round();
    if (percent != lastPercent && status.state == ModelInstallState.downloading) {
      lastPercent = percent;
      stdout.write(
        '\r${status.currentFileName ?? ''}  $percent%  '
        '${formatBytes(status.bytesDone)} / ${formatBytes(status.bytesTotal)}   ',
      );
    }
  });

  final started = DateTime.now();
  await service.download(release);
  final took = DateTime.now().difference(started);
  stdout.writeln();

  final status = service.statusOf(release);
  if (!status.isInstalled) {
    stderr.writeln('FAILED: ${status.failure?.message} '
        '(${status.failure?.detail ?? ''})');
    return 1;
  }

  // Check it ourselves, rather than believing the service that just wrote it.
  var ok = true;
  for (final file in release.files) {
    final path = models.releasePathOf(release, file);
    final size = await File(path).length();
    final digest = await _sha256Of(path);
    final good = size == file.sizeBytes && digest == file.sha256;
    ok = ok && good;
    stdout.writeln(
      '${good ? 'OK  ' : 'BAD '} ${file.name}  $size B  $digest',
    );
    if (await File('$path.part').exists()) {
      stdout.writeln('BAD  ${file.name}.part was left behind');
      ok = false;
    }
  }
  stdout.writeln(
    '${release.id}: ${formatBytes(release.totalBytes)} in '
    '${took.inSeconds} s',
  );
  return ok ? 0 : 1;
}

Future<String> _sha256Of(String path) async {
  final sink = const CryptoHashing().startSha256();
  await for (final chunk in File(path).openRead()) {
    sink.add(chunk);
  }
  return sink.finish();
}

class _Options {
  _Options({
    required this.headOnly,
    required this.all,
    required this.skipResume,
    required this.setId,
    required this.outDirectory,
    required this.oneOff,
  });

  factory _Options.parse(List<String> args) {
    String? value(String name) {
      final index = args.indexOf(name);
      return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
    }

    final url = value('--url');
    ModelRelease? oneOff;
    if (url != null) {
      final name = value('--name') ?? url.split('/').last;
      oneOff = ModelRelease(
        id: 'one-off',
        displayName: name,
        enables: 'Checks one URL.',
        directoryName: 'one-off',
        feature: ModelFeature.speakerDetection,
        files: <DownloadableFile>[
          DownloadableFile(
            file: SpeechModelFile(
              name: name,
              sizeBytes: int.parse(value('--size')!),
            ),
            sha256: value('--sha256')!,
            url: url,
          ),
        ],
      );
    }
    final out = value('--out');
    return _Options(
      headOnly: args.contains('--head-only'),
      all: args.contains('--all'),
      skipResume: args.contains('--no-resume'),
      setId: value('--set'),
      outDirectory: out == null ? null : Directory(out),
      oneOff: oneOff,
    );
  }

  final bool headOnly;
  final bool all;
  final bool skipResume;
  final String? setId;
  final Directory? outDirectory;
  final ModelRelease? oneOff;

  List<ModelRelease> releases() {
    final one = oneOff;
    if (one != null) return <ModelRelease>[one];
    if (all) return ModelCatalogue.all;
    final id = setId;
    if (id != null) {
      final release = ModelCatalogue.byId(id);
      if (release == null) {
        throw ArgumentError('no such set: $id');
      }
      return <ModelRelease>[release];
    }
    // The smallest set by default: enough to prove the scheme in 34 MB.
    return <ModelRelease>[ModelCatalogue.speakerDetection];
  }
}
