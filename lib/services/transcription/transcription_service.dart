import 'dart:async';

import '../../drivers/file_store.dart';
import '../../drivers/speech_recognizer.dart';
import '../../model/language_router.dart';
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
///
/// LANGUAGES. See [transcribe]: in Auto, Hindi first, then English windows
/// again with the English model - loaded only after the Hindi one is freed.
class TranscriptionService {
  TranscriptionService({
    required this._fileStore,
    required this._models,
    required this._recognizer,
    this._model = SpeechModels.indicConformerHindiInt8,
    this._englishModel = SpeechModels.parakeetTdtEnglishInt8,
    this._vadModel = SpeechModels.sileroVad,
    this.useVoiceActivitySegmentation = false,
    Stopwatch Function()? clock,
  }) : _clock = clock ?? Stopwatch.new;

  final FileStore _fileStore;
  final SpeechModelStore _models;
  final SpeechRecognizer _recognizer;
  final SpeechModel _model;
  final SpeechModel _englishModel;
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

  /// The Hindi model: every window's first decode, unless the language is
  /// English.
  SpeechModel get model => _model;

  /// The English model, for windows routed English.
  SpeechModel get englishModel => _englishModel;

  bool get isBusy => _busy;

  /// Whether the model this service uses is installed.
  Future<SpeechModelStatus> modelStatus() => _models.status(_model);

  /// Whether the English model is installed.
  Future<SpeechModelStatus> englishModelStatus() =>
      _models.status(_englishModel);

  /// Transcribes the WAV file at [path] with [numThreads] CPU threads.
  ///
  /// [onProgress] is called after each window with how many of how many are
  /// done. Throws [TranscriptionException]; never anything else.
  ///
  /// [language] - see [TranscriptionLanguage]. In [TranscriptionLanguage.auto]
  /// every window is decoded by the Hindi model first; windows
  /// [LanguageRouter] calls English are then decoded again by the English
  /// model, after the Hindi one is freed. Progress then counts on past the
  /// first pass: `N/(N+k)` up to `(N+k)/(N+k)` for `k` English windows.
  /// A missing English model is not a failure: those windows stay Hindi and
  /// the result says [TranscriptionResult.englishModelMissing].
  Future<TranscriptionResult> transcribe(
    String path, {
    int numThreads = 2,
    void Function(int done, int total)? onProgress,
    TranscriptionLanguage language = TranscriptionLanguage.auto,
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
      return await _run(path, numThreads, onProgress, language);
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
    TranscriptionLanguage language,
  ) async {
    final wall = _clock()..start();
    // The model every window is decoded with first: IndicConformer, except
    // when the setting is English.
    final primary =
        language == TranscriptionLanguage.english ? _englishModel : _model;

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
        header.sampleRateHz != primary.sampleRateHz) {
      throw TranscriptionException(
        TranscriptionFailure.unsupportedAudio,
        'expected 16-bit mono PCM at ${primary.sampleRateHz} Hz, got $header',
      );
    }

    final totalSamples = payloadBytes <= 0 ? 0 : payloadBytes ~/ 2;
    final audioDuration = Duration(
      microseconds: totalSamples * 1000000 ~/ primary.sampleRateHz,
    );
    final grid = WindowPlanner.forModel(primary, totalSamples);

    // Nothing to hear, nothing to load.
    if (grid.isEmpty) {
      wall.stop();
      return TranscriptionResult(
        audioPath: path,
        modelId: primary.id,
        numThreads: numThreads,
        audioDuration: Duration.zero,
        segments: const <TranscriptSegment>[],
        loadTime: Duration.zero,
        decodeTime: Duration.zero,
        wallTime: wall.elapsed,
        languageCode: primary.languageCode,
      );
    }

    await _requireModel(primary);

    VadSegmentation? vad;
    if (useVoiceActivitySegmentation && await _models.isVadReady(_vadModel)) {
      vad = VadSegmentation(
        modelPath: _models.vadPathOf(_vadModel),
        model: _vadModel,
        maxWindowSamples:
            primary.maxWindow.inMicroseconds * primary.sampleRateHz ~/ 1000000,
      );
    }
    _throwIfCancelled();

    final first = await _runPass(
      _jobFor(primary, path, header, numThreads, grid, vad),
      onProgress,
    );
    final windows = first.windows;
    final texts = List<String>.of(first.texts);
    final languages = List<String>.filled(windows.length, primary.languageCode);
    final models = List<String>.filled(windows.length, primary.id);
    final passes = <_Pass>[first];
    var englishModelMissing = false;

    if (language == TranscriptionLanguage.auto) {
      final routes = LanguageRouter.route(texts);
      final english = <int>[
        for (var i = 0; i < routes.length; i++)
          if (routes[i] == WindowLanguage.english) i,
      ];
      if (english.isNotEmpty) {
        _throwIfCancelled();
        final status = await _models.status(_englishModel);
        _throwIfCancelled();
        if (!status.isReady) {
          // Hindi transliteration is still better than nothing; the note can
          // say why once there is a screen for it.
          englishModelMissing = true;
        } else {
          // ONE MODEL IN MEMORY AT A TIME: IndicConformer is freed before
          // Parakeet loads, not left for the recognizer's idle timeout.
          await _recognizer.releaseModel();
          _throwIfCancelled();
          final total = windows.length + english.length;
          final second = await _runPass(
            _jobFor(
              _englishModel,
              path,
              header,
              numThreads,
              <SampleRange>[for (final i in english) windows[i]],
              null,
            ),
            (done, _) => onProgress?.call(windows.length + done, total),
            // Its windows are the first pass's, never re-planned.
            allowPlanning: false,
          );
          passes.add(second);
          for (var j = 0; j < english.length; j++) {
            texts[english[j]] = second.texts[j];
            languages[english[j]] = _englishModel.languageCode;
            models[english[j]] = _englishModel.id;
          }
        }
      }
    }

    wall.stop();
    Duration samplesToTime(int samples) =>
        Duration(microseconds: samples * 1000000 ~/ primary.sampleRateHz);
    final spoken = <String>{
      for (var i = 0; i < texts.length; i++)
        if (texts[i].trim().isNotEmpty) languages[i],
    };
    int? peak;
    for (final pass in passes) {
      final value = pass.released.peakRssKb;
      if (value != null && (peak == null || value > peak)) peak = value;
    }
    return TranscriptionResult(
      audioPath: path,
      modelId: models.toSet().join('+'),
      numThreads: numThreads,
      audioDuration: audioDuration,
      segments: <TranscriptSegment>[
        for (var i = 0; i < windows.length; i++)
          TranscriptSegment(
            start: samplesToTime(windows[i].start),
            end: samplesToTime(windows[i].end),
            text: texts[i],
            languageCode: languages[i],
            modelId: models[i],
          ),
      ],
      loadTime: passes.fold(Duration.zero, (sum, pass) => sum + pass.loadTime),
      decodeTime:
          passes.fold(Duration.zero, (sum, pass) => sum + pass.decodeTime),
      wallTime: wall.elapsed,
      rssBeforeLoadKb: first.released.rssBeforeLoadKb,
      peakRssKb: peak,
      rssAfterReleaseKb: passes.last.released.rssAfterReleaseKb,
      languageCode: spoken.length == 1
          ? spoken.single
          : spoken.isEmpty
              ? primary.languageCode
              : 'auto',
      englishModelMissing: englishModelMissing,
    );
  }

  /// Throws unless every file of [model] is installed at its exact size.
  Future<void> _requireModel(SpeechModel model) async {
    _throwIfCancelled();
    final status = await _models.status(model);
    _throwIfCancelled();
    if (!status.isReady) {
      throw TranscriptionException(
        status.availability == SpeechModelAvailability.missing
            ? TranscriptionFailure.modelMissing
            : TranscriptionFailure.modelIncomplete,
        '${model.displayName} is not installed in ${status.directory}'
        '${status.problems.isEmpty ? '' : ': ${status.problems.join('; ')}'}',
      );
    }
  }

  RecognitionJob _jobFor(
    SpeechModel model,
    String path,
    WavHeader header,
    int numThreads,
    List<SampleRange> windows,
    VadSegmentation? vad,
  ) {
    final decoder = model.decoderFile;
    final joiner = model.joinerFile;
    return RecognitionJob(
      modelPath: _models.pathOf(model, model.modelFile),
      tokensPath: _models.pathOf(model, model.tokensFile),
      featureDim: model.featureDim,
      numThreads: numThreads,
      audioPath: path,
      dataOffset: header.dataOffset,
      sampleRateHz: header.sampleRateHz,
      windows: windows,
      vad: vad,
      architecture: model.architecture,
      decoderPath: decoder == null ? '' : _models.pathOf(model, decoder),
      joinerPath: joiner == null ? '' : _models.pathOf(model, joiner),
    );
  }

  /// Runs one job on the engine to the end, and collects every window's text.
  Future<_Pass> _runPass(
    RecognitionJob job,
    void Function(int done, int total)? onProgress, {
    bool allowPlanning = true,
  }) async {
    var windows = job.windows;
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
              if (!allowPlanning) break;
              // Voice-activity segmentation replaced the grid; indices from
              // here on refer to these windows.
              windows = event.windows;
              texts = List<String?>.filled(windows.length, null);
              onProgress?.call(0, windows.length);
            case RecognitionWindowDecoded():
              if (event.index < 0 || event.index >= texts.length) break;
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
    return _Pass(
      windows: windows,
      texts: <String>[for (final text in texts) text!],
      loadTime: loaded,
      decodeTime: decodeTime,
      released: release,
    );
  }
}

/// What one run of the engine produced.
class _Pass {
  const _Pass({
    required this.windows,
    required this.texts,
    required this.loadTime,
    required this.decodeTime,
    required this.released,
  });

  final List<SampleRange> windows;
  final List<String> texts;
  final Duration loadTime;
  final Duration decodeTime;
  final RecognitionReleased released;
}
