import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/transcript.dart';
import '../library_service.dart';

/// Saved transcripts, one JSON file beside each recording.
///
/// Domain logic only, reached through [FileStore], so it runs in tests against
/// an in-memory store. The file name comes from
/// [RecordingNaming.transcriptPathOf], which is also what `LibraryService`
/// deletes - the two cannot disagree about where a transcript is.
class TranscriptStore {
  TranscriptStore({required this._fileStore});

  final FileStore _fileStore;

  /// Where the transcript of [audioPath] is, or would be.
  String pathFor(String audioPath) =>
      RecordingNaming.transcriptPathOf(audioPath);

  /// The saved transcript of [audioPath], or `null` when there is none.
  ///
  /// A file that cannot be read or parsed also answers `null`, so the worst a
  /// damaged file costs is transcribing the recording again. Never throws.
  Future<Transcript?> load(String audioPath) async {
    try {
      final path = pathFor(audioPath);
      if (await _fileStore.stat(path) == null) return null;
      final bytes = await _fileStore.read(path);
      return Transcript.fromJson(jsonDecode(utf8.decode(bytes)));
    } on Object {
      return null;
    }
  }

  /// Saves [transcript] as the transcript of [audioPath], replacing any other.
  Future<void> save(String audioPath, Transcript transcript) =>
      _fileStore.writeBytes(
        pathFor(audioPath),
        utf8.encode(jsonEncode(transcript.toJson())),
      );

  /// Removes the transcript of [audioPath]. Nothing there is not an error.
  Future<void> delete(String audioPath) => _fileStore.delete(pathFor(audioPath));
}
