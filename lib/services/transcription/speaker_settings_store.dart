import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/speaker_settings.dart';
import '../library_service.dart';

/// The speaker count and merges of each note, one small JSON file beside its
/// recording.
///
/// Domain logic over [FileStore], exactly like [SpeakerNamesStore]. The path is
/// [RecordingNaming.speakerSettingsPathOf], which is also what `LibraryService`
/// deletes with the recording.
class SpeakerSettingsStore {
  SpeakerSettingsStore({required this._fileStore});

  final FileStore _fileStore;

  /// The saved settings for [audioPath]; [SpeakerSettings.empty] when there
  /// are none or the file cannot be read. Never throws.
  Future<SpeakerSettings> load(String audioPath) async {
    try {
      final path = RecordingNaming.speakerSettingsPathOf(audioPath);
      if (await _fileStore.stat(path) == null) return SpeakerSettings.empty;
      return SpeakerSettings.fromJson(
        jsonDecode(utf8.decode(await _fileStore.read(path))),
      );
    } on Object {
      return SpeakerSettings.empty;
    }
  }

  /// Saves [settings] for [audioPath]. Nothing chosen removes the file.
  Future<void> save(String audioPath, SpeakerSettings settings) {
    final path = RecordingNaming.speakerSettingsPathOf(audioPath);
    if (settings.isEmpty) return _fileStore.delete(path);
    return _fileStore.writeBytes(
      path,
      utf8.encode(jsonEncode(settings.toJson())),
    );
  }
}
