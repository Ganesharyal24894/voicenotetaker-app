import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/note_voices.dart';
import '../library_service.dart';

/// Each note's voices, `voicenote-X.voices.json` beside its recording, and
/// its background marker, `voicenote-X.background.json`.
///
/// Domain logic over [FileStore], like the other sidecar stores. Both paths
/// come from [RecordingNaming], which is also what `LibraryService` deletes
/// with the recording and reads the marker back from.
class NoteVoicesStore {
  NoteVoicesStore({required this._fileStore});

  final FileStore _fileStore;

  /// The voices of the note at [audioPath]; null when there are none or the
  /// file is damaged. Never throws: a note that cannot be matched is shown.
  Future<NoteVoices?> load(String audioPath) async {
    try {
      final path = RecordingNaming.voicesPathOf(audioPath);
      if (await _fileStore.stat(path) == null) return null;
      return NoteVoices.decode(utf8.decode(await _fileStore.read(path)));
    } on Object {
      return null;
    }
  }

  Future<void> save(String audioPath, NoteVoices voices) =>
      _fileStore.writeBytes(
        RecordingNaming.voicesPathOf(audioPath),
        utf8.encode(jsonEncode(voices.toJson())),
      );

  Future<bool> isBackground(String audioPath) async =>
      await _fileStore.stat(RecordingNaming.backgroundPathOf(audioPath)) !=
      null;

  /// Sets or clears the marker. EMPTY ON PURPOSE: its presence is the flag,
  /// so there is nothing half-written to read after a kill. Answers whether
  /// anything changed.
  Future<bool> setBackground(String audioPath, bool background) async {
    if (await isBackground(audioPath) == background) return false;
    final path = RecordingNaming.backgroundPathOf(audioPath);
    if (background) {
      await _fileStore.writeBytes(path, const <int>[]);
    } else {
      await _fileStore.delete(path);
    }
    return true;
  }
}
