import 'dart:async';

import '../../drivers/file_store.dart';
import '../../drivers/speech_recognizer.dart';
import '../../model/transcription.dart';
import '../wav_reader.dart';
import 'speech_model_store.dart';
import 'window_planner.dart';

/// Why a transcription did not produce a result.
enum TranscriptionFailure {
  /// The model is not installed on this device.
  modelMissing,

  /// The model is partly installed or a file is the wrong size.
  modelIncomplete,

  /// The recording could not be read or has no valid WAV header.
  unreadableAudio,

  /// The recording is valid but not 16-bit mono PCM at the model's rate.
  unsupportedAudio,

  /// Another transcription is already running.
  busy,

  /// The engine failed while loading or decoding.
  recognizerFailed,

  /// [TranscriptionService.cancel] was called. Not a failure anyone needs to
  /// be told about.
  cancelled,
}

class TranscriptionException implements Exception {
  const TranscriptionException(this.failure, this.message, [this.cause]);

  final TranscriptionFailure failure;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'TranscriptionException(${failure.name}): $message'
      '${cause == null ? '' : ' ($cause)'}';
}

/// Transcribes a saved recording, and measures what that cost.
///
/// Domain logic only: the file is reached through [FileStore], the model's
/// presence through [SpeechModelStore], and the engine through the
/// [SpeechRecognizer] interface - so all of it runs in tests with an in-memory
/// store and a fake engine, and none of it names `sherpa_onnx`.
///
/// ONE AT A TIME. A second request while one is running is refused rather than
/// queued or run alongside: two jobs would mean two copies of a 188 MB model in
/// memory. The recognizer keeps the model loaded between consecutive jobs and
/// frees it on its own idle timeout, or at once through [releaseEngine].
///
/// WINDOWS. The fixed 8 s grid by default, which is what was measured. With
/// [useVoiceActivitySegmentation] on AND the VAD model installed, the job also
/// asks the recognizer to cut windows in the pauses; if the VAD model is
/// absent, or cannot run, the fixed grid is used unchanged.
class TranscriptionService {
  TranscriptionService({
    required this._fileStore,
    required this._models,
    required this._recognizer,
    this._model = SpeechModels.indicConformerHindiInt8,
    this._vadModel = SpeechModels.sileroVad,
    this.useVoiceActivitySegmentation = false,
    Stopwatch Function()? clock,
  }) : _clock = clock ?? Stopwatch.new;

  final FileStore _fileStore;
  final SpeechModelStore _models;
  final SpeechRecognizer _recognizer;
  final SpeechModel _model;
  final VadModel _vadModel;
  final Stopwatch Function() _clock;

  /// Off by default until its CER and on-phone cost are measured - see
  /// `doc/agentFindings/on-device-stt.md`.
  final bool useVoiceActivitySegmentation;

  bool _busy = false;

  /// Set by [cancel]; checked at every step before the engine is running.
  bool _cancelRequested = false;

  /// The engine's event stream while it runs, so [cancel] can end it.
  StreamSubscription<RecognitionEvent>? _engine;

  /// Completes when the running engine stream has finished, one way or another.
  Completer<void>? _engineDone;

  SpeechModel get model => _model;

  bool get isBusy => _busy;

  /// Whether the model this service uses is installed.
  Future<SpeechModelStatus> modelStatus() => _models.status(_model);

  /// Transcribes the WAV file at [path] with [numThreads] CPU threads.
  ///
  /// [onProgress] is called after each window with how many of how many are
  /// done. Throws [TranscriptionException]; never anything else.
  Future<TranscriptionResult> transcribe(
    String path, {
    int numThreads = 2,
    void Function(int done, int total)? onProgress,
  }) async {
    if (numThreads <= 0) {
      throw ArgumentError.value(numThreads, 'numThreads', 'must be > 0');
    }
    if (_busy) {
      throw const TranscriptionException(
        TranscriptionFailure.busy,
        'a transcription is already running',
      );
    }
    _busy = true;
    _cancelRequested = false;
    try {
      return await _run(path, numThreads, onProgress);
    } finally {
      _busy = false;
      _cancelRequested = false;
    }
  }

  /// Frees the speech model now rather than at the recognizer's idle timeout,
  /// stopping a running job first. Completes once the memory is released.
  ///
  /// For when nothing more will run for a while: the app left the foreground
  /// where it may not work there, the background queue drained, teardown.
  Future<void> releaseEngine() async {
    await cancel();
    await _recognizer.releaseModel();
  }

  /// Stops the running transcription, if there is one.
  ///
  /// The job then fails with [TranscriptionFailure.cancelled]. The returned
  /// future completes once the engine has STOPPED - not merely been asked to -
  /// so a new job started straight after never runs alongside it. A window
  /// already being decoded is finished first, which bounds the wait to about
  /// one window's decode time. The model may stay loaded for the next job;
  /// [releaseEngine] frees it.
  Future<void> cancel() async {
    if (!_busy) return;
    _cancelRequested = true;
    final engine = _engine;
    final done = _engineDone;
    if (engine == null || done == null) return;
    _engine = null;
    await engine.cancel();
    if (!done.isCompleted) {
      done.completeError(
        const TranscriptionException(
          TranscriptionFailure.cancelled,
          'cancelled',
        ),
      );
    }
  }

  void _throwIfCancelled() {
    if (_cancelRequested) {
      throw const TranscriptionException(
        TranscriptionFailure.cancelled,
        'cancelled',
      );
    }
  }

  Future<TranscriptionResult> _run(
    String path,
    int numThreads,
    void Function(int done, int total)? onProgress,
  ) async {
    final wall = _clock()..start();

    // The audio is checked BEFORE the model: a bad file must never cost a
    // 188 MB load to discover.
    final WavHeader header;
    final int payloadBytes;
    try {
      final info = await _fileStore.stat(path);
      if (info == null) {
        throw TranscriptionException(
          TranscriptionFailure.unreadableAudio,
          'no such recording: $path',
        );
      }
      final probe = await _fileStore.readRange(path, 0, WavReader.probeLength);
      final parsed = WavReader.parse(probe);
      if (parsed == null) {
        throw TranscriptionException(
          TranscriptionFailure.unreadableAudio,
          'not a readable WAV file: $path',
        );
      }
      header = parsed;
      // A recording cut short by a crash is shorter on disk than its header
      // claims; decode what is really there.
      final onDisk = info.sizeBytes - header.dataOffset;
      payloadBytes = onDisk < header.dataLength ? onDisk : header.dataLength;
    } on TranscriptionException {
      rethrow;
    } on Object catch (error) {
      throw TranscriptionException(
        TranscriptionFailure.unreadableAudio,
        'could not read $path',
        error,
      );
    }

    if (header.audioFormat != 1 ||
        header.channels != 1 ||
        header.bitsPerSample != 16 ||
        header.sampleRateHz != _model.sampleRateHz) {
      throw TranscriptionException(
        TranscriptionFailure.unsupportedAudio,
        'expected 16-bit mono PCM at ${_model.sampleRateHz} Hz, got $header',
      );
    }

    final totalSamples = payloadBytes <= 0 ? 0 : payloadBytes ~/ 2;
    final audioDuration = Duration(
      microseconds: totalSamples * 1000000 ~/ _model.sampleRateHz,
    );
    var windows = WindowPlanner.forModel(_model, totalSamples);

    // Nothing to hear, nothing to load.
    if (windows.isEmpty) {
      wall.stop();
      return TranscriptionResult(
        audioPath: path,
        modelId: _model.id,
        numThreads: numThreads,
        audioDuration: Duration.zero,
        segments: const <TranscriptSegment>[],
        loadTime: Duration.zero,
        decodeTime: Duration.zero,
        wallTime: wall.elapsed,
      );
    }

    _throwIfCancelled();
    final status = await _models.status(_model);
    _throwIfCancelled();
    if (!status.isReady) {
      throw TranscriptionException(
        status.availability == SpeechModelAvailability.missing
            ? TranscriptionFailure.modelMissing
            : TranscriptionFailure.modelIncomplete,
        '${_model.displayName} is not installed in ${status.directory}'
        '${status.problems.isEmpty ? '' : ': ${status.problems.join('; ')}'}',
      );
    }

    VadSegmentation? vad;
    if (useVoiceActivitySegmentation && await _models.isVadReady(_vadModel)) {
      vad = VadSegmentation(
        modelPath: _models.vadPathOf(_vadModel),
        model: _vadModel,
        maxWindowSamples:
            _model.maxWindow.inMicroseconds * _model.sampleRateHz ~/ 1000000,
      );
    }
    _throwIfCancelled();

    final job = RecognitionJob(
      modelPath: _models.pathOf(_model, _model.modelFile),
      tokensPath: _models.pathOf(_model, _model.tokensFile),
      featureDim: _model.featureDim,
      numThreads: numThreads,
      audioPath: path,
      dataOffset: header.dataOffset,
      sampleRateHz: header.sampleRateHz,
      windows: windows,
      vad: vad,
    );

    Duration? loadTime;
    var decodeTime = Duration.zero;
    var texts = List<String?>.filled(windows.length, null);
    RecognitionReleased? released;
    onProgress?.call(0, windows.length);
    final done = Completer<void>();
    _engineDone = done;
    try {
      _engine = _recognizer.transcribe(job).listen(
        (event) {
          switch (event) {
            case RecognitionModelLoaded():
              loadTime = event.loadTime;
            case RecognitionWindowsPlanned():
              // Voice-activity segmentation replaced the grid; indices from
              // here on refer to these windows.
              windows = event.windows;
              texts = List<String?>.filled(windows.length, null);
              onProgress?.call(0, windows.length);
            case RecognitionWindowDecoded():
              texts[event.index] = event.text;
              decodeTime += event.decodeTime;
              onProgress?.call(event.index + 1, windows.length);
            case RecognitionReleased():
              released = event;
          }
        },
        onError: (Object error) {
          if (!done.isCompleted) done.completeError(error);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;
    } on TranscriptionException {
      rethrow;
    } on Object catch (error) {
      throw TranscriptionException(
        TranscriptionFailure.recognizerFailed,
        'the speech engine failed',
        error,
      );
    } finally {
      _engine = null;
      _engineDone = null;
    }

    final missing = <int>[
      for (var i = 0; i < texts.length; i++)
        if (texts[i] == null) i,
    ];
    final loaded = loadTime;
    final release = released;
    if (loaded == null || release == null || missing.isNotEmpty) {
      throw TranscriptionException(
        TranscriptionFailure.recognizerFailed,
        'the speech engine finished early'
        '${missing.isEmpty ? '' : ' - windows $missing were never decoded'}',
      );
    }

    wall.stop();
    Duration samplesToTime(int samples) =>
        Duration(microseconds: samples * 1000000 ~/ _model.sampleRateHz);
    return TranscriptionResult(
      audioPath: path,
      modelId: _model.id,
      numThreads: numThreads,
      audioDuration: audioDuration,
      segments: <TranscriptSegment>[
        for (var i = 0; i < windows.length; i++)
          TranscriptSegment(
            start: samplesToTime(windows[i].start),
            end: samplesToTime(windows[i].end),
            text: texts[i]!,
          ),
      ],
      loadTime: loaded,
      decodeTime: decodeTime,
      wallTime: wall.elapsed,
      rssBeforeLoadKb: release.rssBeforeLoadKb,
      peakRssKb: release.peakRssKb,
      rssAfterReleaseKb: release.rssAfterReleaseKb,
    );
  }
}
