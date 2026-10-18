import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/firmware_update.dart';

/// What the last release check found, and when - one small JSON file beside
/// the other settings.
///
/// It is what makes "at most once a day" survive the app being closed, and
/// what lets a known update be shown at launch without asking GitHub again.
/// A missing, unreadable or foreign file reads as "never checked", which
/// costs one request.
class FirmwareCheckStore {
  FirmwareCheckStore({required FileStore fileStore, required String directory})
      : _fileStore = fileStore,
        path = fileStore.join(directory, fileName);

  static const String fileName = 'firmware-check.json';

  final FileStore _fileStore;
  final String path;

  /// Never throws.
  Future<FirmwareCheck?> load() async {
    try {
      if (await _fileStore.stat(path) == null) return null;
      final json = jsonDecode(utf8.decode(await _fileStore.read(path)));
      if (json is! Map<String, Object?> || json['version'] != 1) return null;
      final checkedAt = DateTime.tryParse('${json['checkedAt']}');
      if (checkedAt == null) return null;
      return FirmwareCheck(
        checkedAt: checkedAt,
        latest: FirmwareRelease.fromJson(json['latest']),
      );
    } on Object {
      return null;
    }
  }

  Future<void> save(FirmwareCheck check) => _fileStore.writeBytes(
        path,
        utf8.encode(jsonEncode(<String, Object?>{
          'version': 1,
          'checkedAt': check.checkedAt.toUtc().toIso8601String(),
          'latest': check.latest?.toJson(),
        })),
      );
}

/// One completed release check. [latest] is null when it found nothing.
class FirmwareCheck {
  const FirmwareCheck({required this.checkedAt, required this.latest});

  final DateTime checkedAt;
  final FirmwareRelease? latest;
}
