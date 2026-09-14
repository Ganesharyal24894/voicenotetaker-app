import '../../drivers/file_store.dart';
import '../../model/transcription.dart';

/// Whether a speech model can be loaded right now.
enum SpeechModelAvailability {
  /// Every file is present at its exact expected size.
  ready,

  /// No file of the model is present - it has never been installed.
  missing,

  /// Some files are present but not all, or one has the wrong size: an
  /// interrupted download or a truncated copy.
  incomplete,
}

/// The on-disk state of one model, file by file.
class SpeechModelStatus {
  const SpeechModelStatus({
    required this.model,
    required this.directory,
    required this.availability,
    required this.problems,
  });

  final SpeechModel model;

  /// Where the files are expected.
  final String directory;

  final SpeechModelAvailability availability;

  /// One human-readable line per file that is absent or the wrong size; empty
  /// when [availability] is [SpeechModelAvailability.ready].
  final List<String> problems;

  bool get isReady => availability == SpeechModelAvailability.ready;
}

/// Where speech models live on this device, and whether they are usable.
///
/// It only LOOKS: installing a model is someone else's job. During the
/// feasibility spike that is `adb push`; later it is a download-on-demand
/// service that writes into [directoryFor] and is done when [status] says
/// [SpeechModelAvailability.ready]. Nothing here changes when that lands.
class SpeechModelStore {
  SpeechModelStore({required this._fileStore, required this._modelsDirectory});

  final FileStore _fileStore;
  final String _modelsDirectory;

  /// Parent of every model's directory.
  String get modelsDirectory => _modelsDirectory;

  String directoryFor(SpeechModel model) =>
      _fileStore.join(_modelsDirectory, model.directoryName);

  String pathOf(SpeechModel model, SpeechModelFile file) =>
      _fileStore.join(directoryFor(model), file.name);

  String vadDirectoryFor(VadModel model) =>
      _fileStore.join(_modelsDirectory, model.directoryName);

  String vadPathOf(VadModel model) =>
      _fileStore.join(vadDirectoryFor(model), model.file.name);

  /// Whether the voice-activity model's one file is present at its exact size.
  /// Never throws: anything unreadable is "not ready", and transcription then
  /// uses the fixed grid.
  Future<bool> isVadReady(VadModel model) async {
    try {
      final info = await _fileStore.stat(vadPathOf(model));
      return info != null && info.sizeBytes == model.file.sizeBytes;
    } on Object {
      return false;
    }
  }

  /// Checks every file of [model] for presence and exact size.
  ///
  /// Size, not a checksum: hashing 188 MB on a phone before every job would
  /// cost more than the check is worth, and a wrong size is what a truncated
  /// copy actually looks like. A downloader should verify a hash once, when it
  /// finishes.
  Future<SpeechModelStatus> status(SpeechModel model) async {
    final problems = <String>[];
    var present = 0;
    for (final file in model.files) {
      final info = await _fileStore.stat(pathOf(model, file));
      if (info == null) {
        problems.add('${file.name}: not found');
      } else {
        present++;
        if (info.sizeBytes != file.sizeBytes) {
          problems.add(
            '${file.name}: ${info.sizeBytes} B, expected '
            '${file.sizeBytes} B',
          );
        }
      }
    }
    return SpeechModelStatus(
      model: model,
      directory: directoryFor(model),
      availability: problems.isEmpty
          ? SpeechModelAvailability.ready
          : present == 0
          ? SpeechModelAvailability.missing
          : SpeechModelAvailability.incomplete,
      problems: List<String>.unmodifiable(problems),
    );
  }
}
