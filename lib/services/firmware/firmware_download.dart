import '../../drivers/download_client.dart';
import '../../drivers/file_store.dart';
import '../../drivers/hashing.dart';
import '../../model/firmware_update.dart';
import '../../model/model_download.dart';

/// Why a package did not end up on the phone.
enum FirmwareDownloadFault { network, checksum, storage }

class FirmwareDownloadException implements Exception {
  const FirmwareDownloadException(this.fault, this.message);

  final FirmwareDownloadFault fault;
  final String message;

  @override
  String toString() => 'FirmwareDownloadException(${fault.name}): $message';
}

/// Puts a firmware package on the phone and proves it is the published one.
///
/// The same rules as the speech-model download, on the same [DownloadClient]
/// and [ResumePlan]: bytes land in `<name>.part`, and the file only takes its
/// real name after its size and sha256 match. So a zip under its real name
/// IS a verified zip, and nothing else needs remembering.
///
/// SIMPLER THAN THE MODEL DOWNLOAD ON PURPOSE. A package is a few hundred
/// kilobytes, not 197 MB: no backoff loop, no Wi-Fi rule and no free-space
/// check. One attempt, resumed if a `.part` is there; a failure is reported
/// and the user's retry is the next attempt.
class FirmwareDownload {
  FirmwareDownload({
    required this._fileStore,
    required this._client,
    required this._hashing,
    required this.directory,
  });

  final FileStore _fileStore;
  final DownloadClient _client;
  final Hashing _hashing;

  /// Where packages are kept: the app's support directory, never one the
  /// user can see or the OS may evict.
  final String directory;

  String pathOf(FirmwareRelease release) =>
      _fileStore.join(directory, release.zipName);

  String _partPathOf(FirmwareRelease release) => '${pathOf(release)}.part';

  /// The verified package's path, or null when it is not on the phone.
  ///
  /// Checked again rather than trusted: it is a few hundred kilobytes, and the
  /// bootloader erases the old image before it can find a bad one.
  Future<String?> verifiedPath(FirmwareRelease release) async {
    final path = pathOf(release);
    final info = await _fileStore.stat(path);
    if (info == null) return null;
    if (info.sizeBytes == release.sizeBytes &&
        await _digestOf(path) == release.sha256) {
      return path;
    }
    await _safeDelete(path);
    return null;
  }

  /// Downloads [release] unless it is already here, and returns its path.
  ///
  /// Throws [FirmwareDownloadException]. A checksum mismatch deletes what
  /// arrived, so the next attempt starts clean.
  Future<String> fetch(
    FirmwareRelease release, {
    void Function(int bytesDone)? onProgress,
  }) async {
    final existing = await verifiedPath(release);
    if (existing != null) return existing;

    final part = _partPathOf(release);
    final onDisk = (await _fileStore.stat(part))?.sizeBytes ?? 0;
    var plan = ResumePlan.decide(
      bytesOnDisk: onDisk,
      expectedBytes: release.sizeBytes,
    );
    if (plan.action == ResumeAction.discard) {
      await _safeDelete(part);
      plan = const ResumePlan(action: ResumeAction.fromStart, startAt: 0);
    }
    if (plan.action != ResumeAction.complete) {
      await _transfer(release, part, plan.startAt, onProgress);
    }

    final size = (await _fileStore.stat(part))?.sizeBytes ?? 0;
    if (size < release.sizeBytes) {
      // The body ended early. What arrived is kept and resumed next time.
      throw FirmwareDownloadException(
        FirmwareDownloadFault.network,
        '${release.zipName} stopped at $size of ${release.sizeBytes} bytes',
      );
    }
    if (size != release.sizeBytes || await _digestOf(part) != release.sha256) {
      await _safeDelete(part);
      throw FirmwareDownloadException(
        FirmwareDownloadFault.checksum,
        '${release.zipName} is not the published package',
      );
    }
    try {
      await _fileStore.move(part, pathOf(release));
    } on Object catch (error) {
      throw FirmwareDownloadException(FirmwareDownloadFault.storage, '$error');
    }
    return pathOf(release);
  }

  /// Deletes every package and partial download except [keep]'s.
  Future<void> prune({FirmwareRelease? keep}) async {
    final List<String> files;
    try {
      files = await _fileStore.list(directory);
    } on Object {
      return;
    }
    final kept = keep == null ? null : pathOf(keep);
    for (final file in files) {
      if (file != kept) await _safeDelete(file);
    }
  }

  Future<void> _transfer(
    FirmwareRelease release,
    String part,
    int startAt,
    void Function(int bytesDone)? onProgress,
  ) async {
    final DownloadResponse response;
    try {
      response = await _client.get(release.zipUrl, from: startAt);
    } on DownloadException catch (error) {
      throw FirmwareDownloadException(FirmwareDownloadFault.network, '$error');
    }
    var written = startAt;
    if (response.isWholeFile && startAt > 0) {
      // The server ignored the range: start the file again.
      await _safeDelete(part);
      written = 0;
    } else if (!(response.isWholeFile || (startAt > 0 && response.isPartial))) {
      await response.abort();
      throw FirmwareDownloadException(
        FirmwareDownloadFault.network,
        'the server answered ${response.statusCode}',
      );
    }
    final FileSink sink;
    try {
      sink = await _fileStore.openAppend(part);
    } on Object catch (error) {
      await response.abort();
      throw FirmwareDownloadException(FirmwareDownloadFault.storage, '$error');
    }
    try {
      await for (final chunk in response.body) {
        await sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written);
      }
    } on Object catch (error) {
      // What arrived stays on disk and is resumed by the next attempt.
      throw FirmwareDownloadException(FirmwareDownloadFault.network, '$error');
    } finally {
      try {
        await sink.close();
      } on Object {
        // The size check that follows is what reports a short file.
      }
    }
  }

  Future<String> _digestOf(String path) async {
    final sink = _hashing.startSha256()..add(await _fileStore.read(path));
    return sink.finish();
  }

  Future<void> _safeDelete(String path) async {
    try {
      await _fileStore.delete(path);
    } on Object {
      // A file that will not go is caught by the next size check.
    }
  }
}
