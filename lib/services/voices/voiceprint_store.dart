import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/diarization.dart';
import '../../model/voiceprint.dart';

/// The known voices, in `<support>/voices/voiceprints.json`.
///
/// App data, beside the other settings, and never in the recordings folder:
/// that folder is what Export zips and what a cable pull copies, and a
/// voiceprint is biometric.
///
/// WRITTEN WHOLE OR NOT AT ALL. The file is the owner's enrolment and every
/// person they named; a kill half way through a plain write would leave
/// neither. It goes to a `.tmp` first and is moved over the old one, which
/// replaces it in one step.
class VoiceprintStore {
  VoiceprintStore({
    required this._fileStore,
    required this.directory,
    DiarizationModel model = DiarizationModels.pyannoteCamPlus,
  }) : model = model.id,
       dim = model.embeddingDim;

  static const String fileName = 'voiceprints.json';

  final FileStore _fileStore;

  /// `<support>/voices`.
  final String directory;

  /// The embedding model the voices must come from. A file written for
  /// another reads as empty - see [Voiceprints.fromJson].
  final String model;
  final int dim;

  String get path => _fileStore.join(directory, fileName);

  /// No voices yet, at [revision].
  Voiceprints empty([int revision = 0]) =>
      Voiceprints(revision: revision, model: model, dim: dim);

  /// The saved voices; empty when there are none or the file is damaged.
  /// Never throws: a damaged store costs the enrolment, never the app.
  Future<Voiceprints> load() async {
    try {
      if (await _fileStore.stat(path) == null) return empty();
      return Voiceprints.fromJson(
        jsonDecode(utf8.decode(await _fileStore.read(path))),
        model: model,
        dim: dim,
      );
    } on Object {
      return empty();
    }
  }

  /// Saves [prints] in place of whatever was there. Throws when it cannot.
  Future<void> save(Voiceprints prints) async {
    final temporary = '$path.tmp';
    await _fileStore.writeBytes(
      temporary,
      utf8.encode(jsonEncode(prints.toJson())),
    );
    await _fileStore.move(temporary, path);
  }
}
