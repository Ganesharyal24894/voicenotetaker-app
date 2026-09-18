import 'dart:convert';

import '../../drivers/file_store.dart';

/// The one choice a model download asks the user to make, in one small JSON
/// file beside the other settings.
///
/// FALSE UNLESS SAID OTHERWISE, and false again if the file is missing,
/// unreadable or written by a build that knew something else: spending
/// someone's data allowance on 197 MB is not a default.
class ModelDownloadSettingsStore {
  ModelDownloadSettingsStore({
    required FileStore fileStore,
    required String directory,
  })  : _fileStore = fileStore,
        path = fileStore.join(directory, fileName);

  static const String fileName = 'model-download-settings.json';

  final FileStore _fileStore;
  final String path;

  /// Whether the user has said models may download on mobile data. Never
  /// throws.
  Future<bool> loadAllowMobileData() async {
    try {
      if (await _fileStore.stat(path) == null) return false;
      final json = jsonDecode(utf8.decode(await _fileStore.read(path)));
      if (json is! Map<String, Object?> || json['version'] != 1) return false;
      return json['allowMobileData'] == true;
    } on Object {
      return false;
    }
  }

  Future<void> saveAllowMobileData(bool allowed) => _fileStore.writeBytes(
        path,
        utf8.encode(jsonEncode(<String, Object?>{
          'version': 1,
          'allowMobileData': allowed,
        })),
      );
}
