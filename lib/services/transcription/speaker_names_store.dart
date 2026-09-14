import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/speaker_names.dart';
import '../library_service.dart';

/// The speaker names of each note, one small JSON file beside its recording.
///
/// Domain logic over [FileStore]. The path is
/// [RecordingNaming.speakerNamesPathOf], which is also what `LibraryService`
/// deletes with the recording.
class SpeakerNamesStore {
  SpeakerNamesStore({required this._fileStore});

  final FileStore _fileStore;

  /// The saved names of [audioPath]'s speakers; [SpeakerNames.empty] when
  /// there are none or the file cannot be read. Never throws.
  Future<SpeakerNames> load(String audioPath) async {
    try {
      final path = RecordingNaming.speakerNamesPathOf(audioPath);
      if (await _fileStore.stat(path) == null) return SpeakerNames.empty;
      return SpeakerNames.fromJson(
        jsonDecode(utf8.decode(await _fileStore.read(path))),
      );
    } on Object {
      return SpeakerNames.empty;
    }
  }

  /// Saves [names] for [audioPath]. No names at all removes the file.
  Future<void> save(String audioPath, SpeakerNames names) {
    final path = RecordingNaming.speakerNamesPathOf(audioPath);
    if (names.isEmpty) return _fileStore.delete(path);
    return _fileStore.writeBytes(path, utf8.encode(jsonEncode(names.toJson())));
  }
}
