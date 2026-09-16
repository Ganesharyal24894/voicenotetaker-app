import 'package:flutter/foundation.dart';

import '../model/speaker_names.dart';
import '../model/transcript_paragraphs.dart';
import 'app_controller.dart';

/// What the Speakers sheet needs from the app, and nothing else.
///
/// THE SEAM BETWEEN THE SCREEN AND THE DIARIZATION PIPELINE. The sheet is
/// built against this interface, so it can be driven by a fake in a test and
/// by [AppController] on a phone. Every method here matches the name and
/// signature the pipeline is implementing on [AppController], so once that
/// lands [AppControllerSpeakers] becomes plain delegation - see the TODOs on
/// it for the three calls that are still local.
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
  /// NOT PART OF THE PIPELINE'S PUBLISHED API - the sheet needs a way to be
  /// honest about a slow job, so it is declared here. The pipeline's own
  /// progress reporting can be wired to it in one line.
  double? detectionProgressFor(String recordingPath);
}

/// [SpeakersController] over the real [AppController].
///
/// Renaming and reading is already the controller's job and is passed
/// straight through. The three diarization calls are held locally until the
/// pipeline lands - see each TODO.
class AppControllerSpeakers implements SpeakersController {
  AppControllerSpeakers(this._app);

  final AppController _app;

  /// TODO(speakers-pipeline): delete this map. The chosen count belongs to
  /// the controller, which saves it beside the note; it is kept here only so
  /// the segmented control is not a dead one on this branch.
  final Map<String, int?> _counts = <String, int?>{};

  @override
  void addListener(VoidCallback listener) => _app.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _app.removeListener(listener);

  @override
  List<String> speakerLabelsFor(String recordingPath) {
    final transcript = _app.transcriptAtPath(recordingPath);
    if (transcript == null) return const <String>[];
    return TranscriptLayout.speakers(transcript);
  }

  @override
  SpeakerNames speakerNamesFor(String recordingPath) =>
      _app.speakerNamesFor(recordingPath);

  @override
  Future<void> renameSpeakers(
    String recordingPath,
    Map<String, String> names,
  ) =>
      _app.renameSpeakers(recordingPath, names);

  /// TODO(speakers-pipeline): `=> _app.mergeSpeakers(path, from, into);`
  /// Until then a merge does nothing rather than pretending: the transcript
  /// on disk is the only place the labels live, and rewriting it is the
  /// pipeline's job.
  @override
  Future<void> mergeSpeakers(
    String recordingPath,
    String from,
    String into,
  ) async {}

  /// TODO(speakers-pipeline): `=> _app.speakerCountFor(path);`
  @override
  int? speakerCountFor(String recordingPath) => _counts[recordingPath];

  /// TODO(speakers-pipeline): `=> _app.setSpeakerCount(path, count);`
  /// The choice is remembered so the control behaves; nothing is re-detected.
  @override
  Future<void> setSpeakerCount(String recordingPath, int? count) async {
    _counts[recordingPath] = count;
  }

  /// TODO(speakers-pipeline): report the re-run's progress here.
  @override
  double? detectionProgressFor(String recordingPath) => null;
}
