import 'package:flutter/foundation.dart';

import '../model/speaker_names.dart';
import 'app_controller.dart';

/// What the Speakers sheet needs from the app, and nothing else.
///
/// THE SEAM BETWEEN THE SCREEN AND THE DIARIZATION PIPELINE. The sheet is
/// built against this interface, so it can be driven by a fake in a test and
/// by [AppController] on a phone. Every method here has the name and the
/// signature of the [AppController] method behind it, so the real one -
/// [AppControllerSpeakers] - is plain delegation, and there is nothing for
/// the two of them to disagree about.
abstract interface class SpeakersController implements Listenable {
  /// The note's speaker labels (`S1`, `S2`, ...) in the order they first
  /// speak. Empty for a note with no speakers.
  ///
  /// This is what the pipeline calls the note's `speakerLabels`.
  List<String> speakerLabelsFor(String recordingPath);

  /// The names the user gave those labels.
  SpeakerNames speakerNamesFor(String recordingPath);

  /// Renames speakers of the note at [recordingPath] - label to name. A blank
  /// name clears that speaker's name, so it falls back to `Speaker N`.
  Future<void> renameSpeakers(String recordingPath, Map<String, String> names);

  /// Folds [from] into [into]: both speakers' lines end up under one name,
  /// and [from] is gone from [speakerLabelsFor].
  Future<void> mergeSpeakers(String recordingPath, String from, String into);

  /// How many people the user says spoke: null for Auto, or 2, 3 or 4, where
  /// 4 means "4 or more".
  int? speakerCountFor(String recordingPath);

  /// Sets that, and re-runs detection for the note. Takes time - watch
  /// [detectionProgressFor] while it does.
  Future<void> setSpeakerCount(String recordingPath, int? count);

  /// How far that re-run has got: null when nothing is running for this note,
  /// otherwise 0..1 (0 before the work has reported a figure).
  ///
  /// The re-run is a transcription - the words are decoded again - so this is
  /// the transcription's own progress, separation pass included, and only for
  /// the note that is running.
  double? detectionProgressFor(String recordingPath);
}

/// [SpeakersController] over the real [AppController].
///
/// PLAIN DELEGATION. Every method is the controller's own method of the same
/// name; nothing about a speaker is remembered here, so the sheet and the note
/// screen can never disagree about a note. The one method that is not a
/// controller method is [detectionProgressFor], which turns the running
/// transcription's window count into the fraction the sheet draws.
class AppControllerSpeakers implements SpeakersController {
  AppControllerSpeakers(this._app);

  final AppController _app;

  @override
  void addListener(VoidCallback listener) => _app.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _app.removeListener(listener);

  @override
  List<String> speakerLabelsFor(String recordingPath) =>
      _app.speakerLabelsFor(recordingPath);

  @override
  SpeakerNames speakerNamesFor(String recordingPath) =>
      _app.speakerNamesFor(recordingPath);

  @override
  Future<void> renameSpeakers(
    String recordingPath,
    Map<String, String> names,
  ) =>
      _app.renameSpeakers(recordingPath, names);

  @override
  Future<void> mergeSpeakers(String recordingPath, String from, String into) =>
      _app.mergeSpeakers(recordingPath, from, into);

  @override
  int? speakerCountFor(String recordingPath) =>
      _app.speakerCountFor(recordingPath);

  @override
  Future<void> setSpeakerCount(String recordingPath, int? count) =>
      _app.setSpeakerCount(recordingPath, count);

  /// THE RE-RUN IS A TRANSCRIPTION. Changing the count moves the turn
  /// boundaries, so the words are decoded again, and the separation pass and
  /// the decoding report through one progress figure - see
  /// [AppController.transcriptionProgressFor], which is null for every note
  /// but the one running.
  @override
  double? detectionProgressFor(String recordingPath) =>
      _app.transcriptionProgressFor(recordingPath);
}
