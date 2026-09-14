import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/language_router.dart';

/// The transcription language setting, in one small JSON file beside the
/// other settings.
class TranscriptionSettingsStore {
  TranscriptionSettingsStore({
    required this._fileStore,
    required String directory,
  }) : path = _fileStore.join(directory, fileName);

  static const String fileName = 'transcription-settings.json';

  final FileStore _fileStore;
  final String path;

  /// The saved language; [TranscriptionLanguage.auto] when never saved,
  /// unreadable, or a value this build does not know. Never throws.
  Future<TranscriptionLanguage> loadLanguage() async {
    try {
      if (await _fileStore.stat(path) == null) {
        return TranscriptionLanguage.auto;
      }
      final json = jsonDecode(utf8.decode(await _fileStore.read(path)));
      if (json is! Map<String, Object?> || json['version'] != 1) {
        return TranscriptionLanguage.auto;
      }
      return TranscriptionLanguage.fromName(json['language']) ??
          TranscriptionLanguage.auto;
    } on Object {
      return TranscriptionLanguage.auto;
    }
  }

  Future<void> saveLanguage(TranscriptionLanguage language) =>
      _fileStore.writeBytes(
        path,
        utf8.encode(jsonEncode(<String, Object?>{
          'version': 1,
          'language': language.name,
        })),
      );
}
