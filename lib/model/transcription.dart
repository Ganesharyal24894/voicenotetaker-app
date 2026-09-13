/// Speech-to-text data: what a model is, what a job asks for, what came back.
///
/// Pure data. No logic beyond arithmetic on its own fields, no I/O, no package
/// types - the recognizer driver is written against these, so swapping the
/// engine never moves anything here.
library;

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

/// A speech model the app knows how to run.
///
/// The catalogue entry, not the files: [directoryName] is where the files are
/// expected under the app's model directory, and [files] is what must be there.
/// A download-on-demand path fills that directory; nothing else changes.
class SpeechModel {
  const SpeechModel({
    required this.id,
    required this.displayName,
    required this.directoryName,
    required this.modelFile,
    required this.tokensFile,
    required this.sampleRateHz,
    required this.featureDim,
    required this.maxWindow,
  });

  /// Stable identifier, safe for logs and file names.
  final String id;

  final String displayName;

  /// Sub-directory of the app's model directory holding [files].
  final String directoryName;

  /// The ONNX network.
  final SpeechModelFile modelFile;

  /// The token table the network's output indices refer to.
  final SpeechModelFile tokensFile;

  /// The only sample rate the model accepts.
  final int sampleRateHz;

  /// Mel filterbank bins the model was trained on.
  final int featureDim;

  /// Longest stretch of audio decoded in one call.
  ///
  /// A property of the MODEL EXPORT, not a tuning knob: see
  /// [SpeechModels.indicConformerHindiInt8].
  final Duration maxWindow;

  List<SpeechModelFile> get files => <SpeechModelFile>[modelFile, tokensFile];

  int get totalBytes => modelFile.sizeBytes + tokensFile.sizeBytes;

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
  /// THE 8-SECOND WINDOW IS LOAD-BEARING. Decoding a long clip in one call
  /// with this export silently drops the middle of it; prior research decoded
  /// fixed 8 s windows and got complete transcripts.
  static const SpeechModel indicConformerHindiInt8 = SpeechModel(
    id: 'indicconformer-hi-int8',
    displayName: 'IndicConformer Hindi (int8)',
    directoryName: 'indicconformer-hi-int8',
    modelFile: SpeechModelFile(name: 'model.int8.onnx', sizeBytes: 196977855),
    tokensFile: SpeechModelFile(name: 'tokens.txt', sizeBytes: 73238),
    sampleRateHz: 16000,
    featureDim: 80,
    maxWindow: Duration(seconds: 8),
  );
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
  });

  final String modelPath;
  final String tokensPath;
  final int featureDim;

  /// CPU threads for inference. More is faster and costs more battery.
  final int numThreads;

  /// A file of 16-bit little-endian MONO PCM starting at [dataOffset].
  final String audioPath;
  final int dataOffset;
  final int sampleRateHz;

  /// Windows to decode, in order. Sample indices, not byte offsets.
  final List<SampleRange> windows;
}

/// What a recognizer driver reports while a job runs.
sealed class RecognitionEvent {
  const RecognitionEvent();
}

/// The model is in memory and ready.
class RecognitionModelLoaded extends RecognitionEvent {
  const RecognitionModelLoaded(this.loadTime);

  final Duration loadTime;
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

/// The model has been released; nothing is held any more.
///
/// Always the last event of a job that did not fail. The memory figures are
/// the whole process's resident set as the kernel reports it, `null` where the
/// platform does not say.
class RecognitionReleased extends RecognitionEvent {
  const RecognitionReleased({
    this.rssBeforeLoadKb,
    this.peakRssKb,
    this.rssAfterReleaseKb,
  });

  /// Just before the model was loaded.
  final int? rssBeforeLoadKb;

  /// The highest point reached during the job.
  final int? peakRssKb;

  /// After the model was released - what the job left behind.
  final int? rssAfterReleaseKb;
}

/// One decoded window, placed on the recording's timeline.
class TranscriptSegment {
  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;

  @override
  String toString() => 'TranscriptSegment($start-$end: $text)';
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
  });

  final String audioPath;
  final String modelId;
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
      'TranscriptionResult($modelId, $numThreads threads, '
      'audio ${audioDuration.inMilliseconds} ms, load ${loadTime.inMilliseconds} '
      'ms, decode ${decodeTime.inMilliseconds} ms, wall '
      '${wallTime.inMilliseconds} ms, rss $rssBeforeLoadKb -> peak $peakRssKb '
      '-> $rssAfterReleaseKb kB)';
}
