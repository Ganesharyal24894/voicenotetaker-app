/// Speech-to-text data: what a model is, what a job asks for, what came back.
///
/// Pure data. No logic beyond arithmetic on its own fields, no I/O, no package
/// types - the recognizer driver is written against these, so swapping the
/// engine never moves anything here.
library;

import 'decode_window.dart';

/// One file a speech model needs on disk.
class SpeechModelFile {
  const SpeechModelFile({required this.name, required this.sizeBytes});

  /// File name inside the model's directory.
  final String name;

  /// Exact size of a good copy.
  ///
  /// Checked before a load, so a truncated `adb push` or an interrupted
  /// download is reported as "the model is incomplete" instead of surfacing as
  /// an opaque native error from inside the runtime.
  final int sizeBytes;

  @override
  String toString() => 'SpeechModelFile($name, $sizeBytes B)';
}

/// How a speech model's network is put together, which decides how the engine
/// is configured to load it.
enum SpeechModelArchitecture {
  /// One NeMo CTC network ([SpeechModel.modelFile]).
  nemoCtc,

  /// A NeMo transducer (RNN-T / TDT): [SpeechModel.modelFile] is the encoder,
  /// with a separate decoder and joiner.
  nemoTransducer,
}

/// A speech model the app knows how to run.
///
/// The catalogue entry, not the files: [directoryName] is where the files are
/// expected under the app's model directory, and [files] is what must be there.
/// A download-on-demand path fills that directory; nothing else changes.
class SpeechModel {
  const SpeechModel({
    required this.id,
    required this.displayName,
    required this.languageCode,
    required this.directoryName,
    required this.modelFile,
    required this.tokensFile,
    required this.sampleRateHz,
    required this.featureDim,
    required this.maxWindow,
    this.architecture = SpeechModelArchitecture.nemoCtc,
    this.decoderFile,
    this.joinerFile,
  });

  /// Stable identifier, safe for logs and file names.
  final String id;

  final String displayName;

  /// BCP-47 code of the one language this model is run for, e.g. `hi`.
  final String languageCode;

  /// Sub-directory of the app's model directory holding [files].
  final String directoryName;

  /// The ONNX network - for a transducer, its encoder.
  final SpeechModelFile modelFile;

  final SpeechModelArchitecture architecture;

  /// A transducer's decoder network; null for CTC.
  final SpeechModelFile? decoderFile;

  /// A transducer's joiner network; null for CTC.
  final SpeechModelFile? joinerFile;

  /// The token table the network's output indices refer to.
  final SpeechModelFile tokensFile;

  /// The only sample rate the model accepts.
  final int sampleRateHz;

  /// Mel filterbank bins the model was trained on.
  final int featureDim;

  /// Longest stretch of audio decoded in one call.
  ///
  /// Always [DecodeWindow.standard]: both models are decoded in the same
  /// windows so a routed English re-decode lands on the same segment times.
  /// A single job may use a shorter one when the phone is short of memory -
  /// see [DecodeWindow.forAvailableMemory] - so this is the longest a window
  /// can be, not the length of every window.
  final Duration maxWindow;

  List<SpeechModelFile> get files => <SpeechModelFile>[
        modelFile,
        ?decoderFile,
        ?joinerFile,
        tokensFile,
      ];

  int get totalBytes =>
      files.fold<int>(0, (sum, file) => sum + file.sizeBytes);

  @override
  String toString() => 'SpeechModel($id)';
}

/// The models the app ships support for.
abstract final class SpeechModels {
  /// AI4Bharat IndicConformer (Hindi), NeMo hybrid CTC/RNN-T, CTC head,
  /// int8-quantised ONNX export for sherpa-onnx. MIT licence.
  ///
  /// Source: Hugging Face `meetsync/indic-conformer-onnx-sherpa`, files
  /// `model.int8.onnx` and `tokens.txt`, byte sizes as downloaded.
  ///
  /// CHOSEN OVER WHISPER on purpose: Whisper-family models invent fluent
  /// sentences that were never said and loop on long audio. A CTC model does
  /// neither - a notetaker is better served by a visibly garbled word than by
  /// a confident fabrication.
  ///
  /// WINDOWING IS LOAD-BEARING. Decoding a long clip in one call with this
  /// export silently drops the middle of it; the audio is always handed over
  /// in pieces. The LENGTH of those pieces is a measured tuning constant, and
  /// it lives in one place: [DecodeWindow.standard], 16 s since the accuracy
  /// evaluation of Sep 2026.
  static const SpeechModel indicConformerHindiInt8 = SpeechModel(
    id: 'indicconformer-hi-int8',
    displayName: 'IndicConformer Hindi (int8)',
    languageCode: 'hi',
    directoryName: 'indicconformer-hi-int8',
    modelFile: SpeechModelFile(name: 'model.int8.onnx', sizeBytes: 196977855),
    tokensFile: SpeechModelFile(name: 'tokens.txt', sizeBytes: 73238),
    sampleRateHz: 16000,
    featureDim: 80,
    maxWindow: DecodeWindow.standard,
  );

  /// NVIDIA NeMo Parakeet TDT 110M (English), transducer, int8 ONNX export
  /// for sherpa-onnx (CC-BY-4.0). Source: the sherpa-onnx GitHub release
  /// `asr-models/sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8`
  /// `.tar.bz2`, byte sizes as unpacked.
  ///
  /// Run only for windows the language router calls English (or every window
  /// when the language setting is English): IndicConformer writes English as
  /// Devanagari transliteration. Loaded AFTER IndicConformer is freed - never
  /// both in memory. Decoded in the same windows so segment times match.
  /// See `doc/agentFindings/on-device-stt.md`.
  static const SpeechModel parakeetTdtEnglishInt8 = SpeechModel(
    id: 'parakeet-tdt-110m-en-int8',
    displayName: 'Parakeet TDT 110M English (int8)',
    languageCode: 'en',
    directoryName: 'parakeet-tdt-110m-en-int8',
    architecture: SpeechModelArchitecture.nemoTransducer,
    modelFile: SpeechModelFile(name: 'encoder.int8.onnx', sizeBytes: 131113202),
    decoderFile: SpeechModelFile(name: 'decoder.int8.onnx', sizeBytes: 3955863),
    joinerFile: SpeechModelFile(name: 'joiner.int8.onnx', sizeBytes: 1411403),
    tokensFile: SpeechModelFile(name: 'tokens.txt', sizeBytes: 9953),
    sampleRateHz: 16000,
    featureDim: 80,
    maxWindow: DecodeWindow.standard,
  );

  /// Silero VAD v4 as published by sherpa-onnx (MIT). Source: GitHub release
  /// `k2-fsa/sherpa-onnx` `asr-models/silero_vad.onnx`, byte size as served.
  ///
  /// The settings are sherpa-onnx's defaults except [VadModel.minSilence],
  /// shortened from 0.5 s to 0.25 s so that the 300 ms pauses always-listening
  /// writes between utterances are boundaries too. None of them is measured
  /// on this model's CER yet; see `doc/agentFindings/on-device-stt.md`.
  static const VadModel sileroVad = VadModel(
    id: 'silero-vad',
    directoryName: 'silero-vad',
    file: SpeechModelFile(name: 'silero_vad.onnx', sizeBytes: 643854),
    threshold: 0.5,
    minSilence: Duration(milliseconds: 250),
    minSpeech: Duration(milliseconds: 250),
    padding: Duration(milliseconds: 200),
  );
}

/// A voice-activity model: finds where speech is, so windows can be cut at
/// pauses instead of on a fixed grid.
///
/// Optional. Delivered exactly like the speech model - its file is placed under
/// the app's model directory - and when it is absent transcription falls back
/// to the fixed grid, which is what was measured.
class VadModel {
  const VadModel({
    required this.id,
    required this.directoryName,
    required this.file,
    required this.threshold,
    required this.minSilence,
    required this.minSpeech,
    required this.padding,
  });

  final String id;

  /// Sub-directory of the app's model directory holding [file].
  final String directoryName;

  final SpeechModelFile file;

  /// Speech probability above which a frame counts as speech.
  final double threshold;

  /// A pause at least this long ends a speech segment.
  final Duration minSilence;

  /// A burst shorter than this is not speech.
  final Duration minSpeech;

  /// Silence kept either side of a segment, so a word's onset and release are
  /// not clipped. Never more than half the gap to the next segment.
  final Duration padding;

  @override
  String toString() => 'VadModel($id)';
}

/// Voice-activity segmentation for one job: which model, with what settings.
///
/// Carried by a [RecognitionJob] when the VAD model is installed and the
/// feature is switched on. The recognizer runs it over the audio before
/// decoding and reports the windows it chose with [RecognitionWindowsPlanned];
/// if it cannot run, the job's fixed windows are used unchanged.
class VadSegmentation {
  const VadSegmentation({
    required this.modelPath,
    required this.model,
    required this.maxWindowSamples,
  });

  final String modelPath;
  final VadModel model;

  /// The speech model's longest window, in samples: no planned window is
  /// longer.
  final int maxWindowSamples;
}

/// The part of a [RecognitionJob] that decides which model is in memory.
///
/// Two jobs with an equal config can share one loaded recognizer; a job with
/// a different one needs the old recognizer freed first.
class RecognizerConfig {
  const RecognizerConfig({
    required this.modelPath,
    required this.tokensPath,
    required this.featureDim,
    required this.numThreads,
    required this.sampleRateHz,
    this.architecture = SpeechModelArchitecture.nemoCtc,
    this.decoderPath = '',
    this.joinerPath = '',
  });

  /// The CTC network, or a transducer's encoder.
  final String modelPath;
  final String tokensPath;
  final int featureDim;
  final int numThreads;
  final int sampleRateHz;
  final SpeechModelArchitecture architecture;

  /// A transducer's decoder and joiner; empty for CTC.
  final String decoderPath;
  final String joinerPath;

  @override
  bool operator ==(Object other) =>
      other is RecognizerConfig &&
      other.architecture == architecture &&
      other.decoderPath == decoderPath &&
      other.joinerPath == joinerPath &&
      other.modelPath == modelPath &&
      other.tokensPath == tokensPath &&
      other.featureDim == featureDim &&
      other.numThreads == numThreads &&
      other.sampleRateHz == sampleRateHz;

  @override
  int get hashCode => Object.hash(
        modelPath,
        tokensPath,
        featureDim,
        numThreads,
        sampleRateHz,
        architecture,
        decoderPath,
        joinerPath,
      );

  @override
  String toString() =>
      'RecognizerConfig($modelPath, $numThreads threads, $sampleRateHz Hz)';
}

/// A half-open range of samples, `[start, end)`.
class SampleRange {
  const SampleRange(this.start, this.end)
    : assert(start >= 0),
      assert(end >= start);

  final int start;
  final int end;

  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is SampleRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SampleRange($start, $end)';
}

/// Everything a recognizer driver needs to transcribe one file.
///
/// The audio is described, not carried: the driver reads each window straight
/// from [audioPath] when it gets to it, so an hour-long recording is never
/// held in memory, and nothing large is copied between isolates.
class RecognitionJob {
  const RecognitionJob({
    required this.modelPath,
    required this.tokensPath,
    required this.featureDim,
    required this.numThreads,
    required this.audioPath,
    required this.dataOffset,
    required this.sampleRateHz,
    required this.windows,
    this.vad,
    this.architecture = SpeechModelArchitecture.nemoCtc,
    this.decoderPath = '',
    this.joinerPath = '',
  });

  /// The CTC network, or a transducer's encoder.
  final String modelPath;
  final SpeechModelArchitecture architecture;

  /// A transducer's decoder and joiner; empty for CTC.
  final String decoderPath;
  final String joinerPath;
  final String tokensPath;
  final int featureDim;

  /// CPU threads for inference. More is faster and costs more battery.
  final int numThreads;

  /// A file of 16-bit little-endian MONO PCM starting at [dataOffset].
  final String audioPath;
  final int dataOffset;
  final int sampleRateHz;

  /// Windows to decode, in order. Sample indices, not byte offsets.
  ///
  /// The fixed grid. When [vad] is set and runs, the recognizer replaces these
  /// with windows cut at pauses and says so with [RecognitionWindowsPlanned].
  final List<SampleRange> windows;

  /// Voice-activity segmentation to try first; null for the fixed grid.
  final VadSegmentation? vad;

  /// What must be loaded to run this job.
  RecognizerConfig get recognizerConfig => RecognizerConfig(
        modelPath: modelPath,
        tokensPath: tokensPath,
        featureDim: featureDim,
        numThreads: numThreads,
        sampleRateHz: sampleRateHz,
        architecture: architecture,
        decoderPath: decoderPath,
        joinerPath: joinerPath,
      );
}

/// What a recognizer driver reports while a job runs.
sealed class RecognitionEvent {
  const RecognitionEvent();
}

/// The model is in memory and ready.
class RecognitionModelLoaded extends RecognitionEvent {
  const RecognitionModelLoaded(this.loadTime, {this.reused = false});

  /// Zero when [reused].
  final Duration loadTime;

  /// True when the model was already loaded by an earlier job and kept.
  final bool reused;
}

/// Voice-activity segmentation ran and chose these windows, replacing the
/// job's fixed grid. Arrives after [RecognitionModelLoaded] and before the
/// first [RecognitionWindowDecoded], whose indices then refer to this list.
/// Empty when no speech was found.
class RecognitionWindowsPlanned extends RecognitionEvent {
  const RecognitionWindowsPlanned(this.windows);

  final List<SampleRange> windows;
}

/// One window has been decoded.
class RecognitionWindowDecoded extends RecognitionEvent {
  const RecognitionWindowDecoded({
    required this.index,
    required this.text,
    required this.decodeTime,
  });

  /// Position in [RecognitionJob.windows].
  final int index;

  /// The hypothesis for this window alone, possibly empty (silence).
  final String text;

  /// Time spent reading, converting and decoding this window.
  final Duration decodeTime;
}

/// The job is over: the model has been released, or kept for the next job.
///
/// Always the last event of a job that did not fail. The memory figures are
/// the whole process's resident set as the kernel reports it, `null` where the
/// platform does not say.
class RecognitionReleased extends RecognitionEvent {
  const RecognitionReleased({
    this.rssBeforeLoadKb,
    this.peakRssKb,
    this.rssAfterReleaseKb,
    this.keptLoaded = false,
  });

  /// Just before the job started (before the load, when there was one).
  final int? rssBeforeLoadKb;

  /// The highest point reached during the job.
  final int? peakRssKb;

  /// At the end of the job - after the release, unless [keptLoaded].
  final int? rssAfterReleaseKb;

  /// True when the model stays in memory for the next job. The recognizer
  /// frees it by itself after its idle timeout, or when asked to with
  /// `SpeechRecognizer.releaseModel`.
  final bool keptLoaded;
}

/// One decoded window, placed on the recording's timeline.
class TranscriptSegment {
  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
    this.languageCode,
    this.modelId,
  });

  final Duration start;
  final Duration end;
  final String text;

  /// The language this window was decoded as, `hi` or `en`; null in a
  /// transcript from before language routing, which was all Hindi.
  final String? languageCode;

  /// The [SpeechModel.id] that produced [text]; null in a transcript from
  /// before language routing (the transcript's own model then made it).
  final String? modelId;

  /// Who is talking, as a stable label from speaker separation (`S1`, `S2`),
  /// or null when nobody has worked that out. Always null today: speaker
  /// separation is a later step, and the note screen shows plain paragraphs
  /// until it lands. Display names live beside the recording - see
  /// `SpeakerNames` - so they survive a transcript being made again.
  final String? speaker;

  @override
  String toString() => speaker == null
      ? 'TranscriptSegment($start-$end: $text)'
      : 'TranscriptSegment($start-$end $speaker: $text)';

  /// This segment with its language and model set.
  TranscriptSegment withSource({
    required String languageCode,
    required String modelId,
  }) =>
      TranscriptSegment(
        start: start,
        end: end,
        text: text,
        speaker: speaker,
        languageCode: languageCode,
        modelId: modelId,
      );
}

/// The result of transcribing one recording, with the numbers that describe
/// what it cost.
class TranscriptionResult {
  const TranscriptionResult({
    required this.audioPath,
    required this.modelId,
    required this.numThreads,
    required this.audioDuration,
    required this.segments,
    required this.loadTime,
    required this.decodeTime,
    required this.wallTime,
    this.rssBeforeLoadKb,
    this.peakRssKb,
    this.rssAfterReleaseKb,
    this.languageCode = 'hi',
    this.englishModelMissing = false,
  });

  final String audioPath;

  /// The model that produced the transcript; both ids joined with `+` when
  /// windows were routed to two.
  final String modelId;

  /// `hi` or `en` when every segment is that language, `auto` when they mix.
  final String languageCode;

  /// Some windows sounded English but the English model is not installed, so
  /// they were kept as Hindi (Devanagari transliteration).
  final bool englishModelMissing;
  final int numThreads;
  final Duration audioDuration;
  final List<TranscriptSegment> segments;

  /// Model file to ready recognizer.
  final Duration loadTime;

  /// Sum of every window's decode time; excludes [loadTime].
  final Duration decodeTime;

  /// Request to result, everything included: isolate start, load, decode,
  /// release.
  final Duration wallTime;

  /// Resident memory of the process before the load, at its peak during the
  /// job, and after the release. `null` when unknown.
  final int? rssBeforeLoadKb;
  final int? peakRssKb;
  final int? rssAfterReleaseKb;

  /// The segments' text joined with single spaces, empty windows skipped.
  String get text => segments
      .map((segment) => segment.text.trim())
      .where((text) => text.isNotEmpty)
      .join(' ');

  /// Decode time over audio time. Below 1 is faster than real time.
  ///
  /// `null` for an empty recording, where the ratio has no meaning.
  double? get realTimeFactor {
    if (audioDuration.inMicroseconds <= 0) return null;
    return decodeTime.inMicroseconds / audioDuration.inMicroseconds;
  }

  @override
  String toString() =>
      'TranscriptionResult($modelId, $languageCode, $numThreads threads, '
      'audio ${audioDuration.inMilliseconds} ms, load ${loadTime.inMilliseconds} '
      'ms, decode ${decodeTime.inMilliseconds} ms, wall '
      '${wallTime.inMilliseconds} ms, rss $rssBeforeLoadKb -> peak $peakRssKb '
      '-> $rssAfterReleaseKb kB)';
}
