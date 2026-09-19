import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/assistant/assistant_settings.dart';

/// The assistant settings that are NOT secret, in one small JSON file beside
/// the app's other settings - the same shape as
/// `TranscriptionSettingsStore`.
///
/// What is in here: whether the feature is on, the wake phrase, and the
/// assistant's address. What is NOT in here, ever: the sending account's
/// password, which lives in [AssistantAccountStore] behind the platform
/// keystore.
class AssistantSettingsStore {
  AssistantSettingsStore({
    required FileStore fileStore,
    required String directory,
  })  : _fileStore = fileStore,
        path = fileStore.join(directory, fileName);

  static const String fileName = 'assistant-settings.json';

  final FileStore _fileStore;
  final String path;

  /// The saved settings, or the defaults - which are OFF - when there is no
  /// file, it cannot be read, or it is a version this build does not know.
  /// Never throws.
  Future<AssistantSettings> load() async {
    try {
      if (await _fileStore.stat(path) == null) {
        return const AssistantSettings();
      }
      return AssistantSettings.fromJson(
        jsonDecode(utf8.decode(await _fileStore.read(path))),
      );
    } on Object {
      return const AssistantSettings();
    }
  }

  Future<void> save(AssistantSettings settings) => _fileStore.writeBytes(
        path,
        utf8.encode(jsonEncode(settings.toJson())),
      );
}
