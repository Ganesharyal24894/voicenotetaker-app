/// Speaker separation data: which models, what one job asks for, what came
/// back.
///
/// Pure data, exactly like `transcription.dart`: no logic beyond arithmetic on
/// its own fields, no I/O, no package types. The diarizer driver is written
/// against these, so swapping the engine never moves anything here.
library;

import 'transcription.dart';

/// A speaker-separation model pair the app knows how to run.
///
/// TWO NETWORKS, ONE STEP. Segmentation says WHEN somebody is speaking and how
/// many voices overlap; the embedding model turns each of those pieces into a
/// voice fingerprint, and the fingerprints are clustered into speakers. Both
/// files must be present for either to be of any use, which is why they are
/// one catalogue entry.
class DiarizationModel {
  const DiarizationModel({
    required this.id,
    required this.displayName,
    required this.directoryName,
    required this.segmentationFile,
    required this.embeddingFile,
    required this.sampleRateHz,
    required this.threshold,
    required this.windowShiftRatio,
    required this.minDurationOn,
    required this.minDurationOff,
  });

  /// Stable identifier, safe for logs and file names.
  final String id;

  final String displayName;

  /// Sub-directory of the app's model directory holding [files].
  final String directoryName;

  /// Pyannote segmentation network.
  final SpeechModelFile segmentationFile;

  /// Speaker-embedding network.
  final SpeechModelFile embeddingFile;

  /// The only sample rate these models accept.
  final int sampleRateHz;

  /// Cosine distance above which two voices are called different people, when
  /// nobody has said how many speakers there are.
  final double threshold;

  /// How far the segmentation window moves each step, as a fraction of its
  /// length. Smaller is more careful and slower.
  final double windowShiftRatio;

  /// Speech shorter than this is not a turn.
  final Duration minDurationOn;

  /// A pause shorter than this does not end a turn.
  final Duration minDurationOff;

  List<SpeechModelFile> get files =>
      <SpeechModelFile>[segmentationFile, embeddingFile];

  int get totalBytes =>
      files.fold<int>(0, (sum, file) => sum + file.sizeBytes);

  @override
  String toString() => 'DiarizationModel($id)';
}

/// The speaker-separation models the app ships support for.
abstract final class DiarizationModels {
  /// pyannote `segmentation-3.0` (MIT) plus 3D-Speaker CAM++ `zh_en advanced`
  /// (Apache-2.0), both as published by sherpa-onnx.
  ///
  /// THE FLOAT SEGMENTATION MODEL ON PURPOSE. The int8 export of the same
  /// network misses quiet speech - a second voice answering softly simply is
  /// not there - and 6 MB is not worth that. The embedding model is int8-free
  /// too and small enough (28 MB) that there is nothing to gain.
  ///
  /// THE DEFAULTS are what the laptop spike settled on: see
  /// `doc/agentFindings/on-device-stt.md`.
  static const DiarizationModel pyannoteCamPlus = DiarizationModel(
    id: 'pyannote-segmentation-3-campplus',
    displayName: 'Speaker separation (pyannote + CAM++)',
    directoryName: 'diarization',
    segmentationFile: SpeechModelFile(
      name: 'segmentation.onnx',
      sizeBytes: 5992913,
    ),
    embeddingFile: SpeechModelFile(
      name: 'campplus.onnx',
      sizeBytes: 28281164,
    ),
    sampleRateHz: 16000,
    threshold: 0.9,
    windowShiftRatio: 0.5,
    minDurationOn: Duration(milliseconds: 300),
    minDurationOff: Duration(milliseconds: 500),
  );
}

/// Everything a diarizer driver needs to separate the speakers in one file.
///
/// The audio is described, not carried - the driver reads it from [audioPath]
/// itself - so nothing large crosses an isolate boundary on the way in.
class DiarizationJob {
  const DiarizationJob({
    required this.model,
    required this.segmentationPath,
    required this.embeddingPath,
    required this.audioPath,
    required this.dataOffset,
    required this.sampleRateHz,
    required this.totalSamples,
    this.numThreads = 1,
    this.numClusters,
  });

  final DiarizationModel model;
  final String segmentationPath;
  final String embeddingPath;

  /// A file of 16-bit little-endian MONO PCM starting at [dataOffset].
  final String audioPath;
  final int dataOffset;
  final int sampleRateHz;
  final int totalSamples;

  /// CPU threads for both networks.
  final int numThreads;

  /// How many speakers there are, when the user has said; null lets the
  /// clustering decide from [DiarizationModel.threshold].
  ///
  /// "4 or more" is 4: the engine takes a number, and a note with five voices
  /// separated into four is still far better than one paragraph.
  final int? numClusters;
}

/// What a diarizer driver reports while a job runs.
sealed class DiarizationEvent {
  const DiarizationEvent();
}

/// Both networks are in memory and ready.
class DiarizationModelsLoaded extends DiarizationEvent {
  const DiarizationModelsLoaded(this.loadTime);

  final Duration loadTime;
}

/// How much of the recording has been looked at.
class DiarizationProgress extends DiarizationEvent {
  const DiarizationProgress({required this.done, required this.total});

  final int done;
  final int total;

  /// `0.0`-`1.0`; zero when the engine has not said how much there is.
  double get fraction {
    if (total <= 0) return 0;
    final value = done / total;
    return value < 0
        ? 0
        : value > 1
            ? 1
            : value;
  }
}

/// The job is over: the turns it found, and the models have been freed.
///
/// Always the last event of a job that did not fail. [turns] is empty when
/// nothing was heard.
class DiarizationFinished extends DiarizationEvent {
  const DiarizationFinished({
    required this.turns,
    this.rssBeforeLoadKb,
    this.peakRssKb,
    this.rssAfterReleaseKb,
  });

  /// Sorted by start, with the engine's own cluster numbers.
  final List<SpeakerTurn> turns;

  final int? rssBeforeLoadKb;
  final int? peakRssKb;
  final int? rssAfterReleaseKb;
}

/// One stretch of audio one person speaks through, in sample indices.
///
/// [speaker] is the ENGINE'S cluster number - 0, 1, 2 - not what the screen
/// shows. Display labels (`S1`, `S2`) are given by [SpeakerTurns.labels] after
/// the turns have been cleaned up, so they are in the order people first speak
/// rather than in whatever order the clustering happened to number them.
class SpeakerTurn {
  const SpeakerTurn({
    required this.start,
    required this.end,
    required this.speaker,
  })  : assert(start >= 0),
        assert(end >= start);

  /// From a diarizer's seconds.
  factory SpeakerTurn.fromSeconds({
    required double start,
    required double end,
    required int speaker,
    required int sampleRateHz,
  }) {
    final from = (start * sampleRateHz).round();
    final to = (end * sampleRateHz).round();
    return SpeakerTurn(
      start: from < 0 ? 0 : from,
      end: to < from ? from : to,
      speaker: speaker,
    );
  }

  final int start;
  final int end;
  final int speaker;

  int get length => end - start;

  SampleRange get range => SampleRange(start, end);

  SpeakerTurn copyWith({int? start, int? end, int? speaker}) => SpeakerTurn(
        start: start ?? this.start,
        end: end ?? this.end,
        speaker: speaker ?? this.speaker,
      );

  @override
  bool operator ==(Object other) =>
      other is SpeakerTurn &&
      other.start == start &&
      other.end == end &&
      other.speaker == speaker;

  @override
  int get hashCode => Object.hash(start, end, speaker);

  @override
  String toString() => 'SpeakerTurn($start-$end, speaker $speaker)';
}

/// One window to decode, and who is speaking in it.
class SpeakerWindow {
  const SpeakerWindow({required this.range, required this.speaker});

  final SampleRange range;

  /// The engine's cluster number, carried through from the turn this window
  /// was cut out of.
  final int speaker;

  @override
  bool operator ==(Object other) =>
      other is SpeakerWindow &&
      other.range == range &&
      other.speaker == speaker;

  @override
  int get hashCode => Object.hash(range, speaker);

  @override
  String toString() => 'SpeakerWindow($range, speaker $speaker)';
}
