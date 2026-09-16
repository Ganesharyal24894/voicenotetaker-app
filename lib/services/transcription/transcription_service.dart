import 'dart:async';
import 'dart:typed_data';

import '../../drivers/file_store.dart';
import '../../drivers/speaker_diarizer.dart';
import '../../drivers/speech_recognizer.dart';
import '../../model/diarization.dart';
import '../../model/language_router.dart';
import '../../model/loudness_profile.dart';
import '../../model/speaker_turns.dart';
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
///
/// SPEAKERS, WHEN THE MODELS ARE THERE. A [SpeakerDiarizer] runs FIRST, over
/// the whole recording, and is freed before any speech model is loaded: the
/// two must never be resident together. Its turns become the windows - cleaned
/// up by [SpeakerTurns], and a turn longer than the model's window cut at the
/// quietest moment in it - so every window has exactly one speaker, and every
/// segment comes back labelled `S1`, `S2`. A note with ONE speaker is not
/// labelled at all. No diarizer, or its models not installed: nothing changes,
/// and the transcript is what it always was.
class TranscriptionService {
  TranscriptionService({
    required this._fileStore,
    required this._models,
    required this._recognizer,
    this._diarizer,
    this._model = SpeechModels.indicConformerHindiInt8,
    this._englishModel = SpeechModels.parakeetTdtEnglishInt8,
    this._vadModel = SpeechModels.sileroVad,
    this._diarizationModel = DiarizationModels.pyannoteCamPlus,
    this.useVoiceActivitySegmentation = false,
    Stopwatch Function()? clock,
  }) : _clock = clock ?? Stopwatch.new;

  final FileStore _fileStore;
  final SpeechModelStore _models;
  final SpeechRecognizer _recognizer;
  final SpeakerDiarizer? _diarizer;
  final SpeechModel _model;
  final SpeechModel _englishModel;
  final VadModel _vadModel;
  final DiarizationModel _diarizationModel;
  final Stopwatch Function() _clock;

  /// How much of a job's progress the speaker pass is worth: a tenth, which is
  /// what it costs - about 0.10x real time against the speech model's ~1x.
  ///
  /// The progress fraction is `(speakerSteps + windowsDone) / (speakerSteps +
  /// windows)`, so a note with 20 windows spends its first 2 steps separating
  /// speakers and the other 20 decoding. The TOTAL changes once, when the
  /// speaker turns replace the fixed grid and there turn out to be a different
  /// number of windows - the English pass already moves it the same way.
  static const int speakerWorkShare = 10;

  /// Off by default until its CER and on-phone cost are measured - see
  /// `doc/agentFindings/on-device-stt.md`.
  final bool useVoiceActivitySegmentation;

  bool _busy = false;

  /// Set by [cancel]; checked at every step before the engine is running.
  bool _cancelRequested = false;

  /// The engine's event stream while it runs, so [cancel] can end it.
  StreamSubscription<RecognitionEvent>? _engine;

  /// The diarizer's event stream while it runs, for the same reason.
  StreamSubscription<DiarizationEvent>? _diarizing;

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

  /// Whether this build has a speaker-separation engine at all.
  bool get diarizationAvailable => _diarizer != null;

  /// The speaker-separation models this service would use.
  DiarizationModel get diarizationModel => _diarizationModel;

  /// Whether the speaker-separation models are installed.
  Future<DiarizationModelStatus> diarizationStatus() =>
      _models.diarizationStatus(_diarizationModel);

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
  ///
  /// [speakerCount] - how many people are talking, when the user has said;
  /// null lets the clustering decide. Ignored when there is no diarizer or its
  /// models are not installed, which is also when segments come back with no
  /// speaker at all.
  Future<TranscriptionResult> transcribe(
    String path, {
    int numThreads = 2,
    void Function(int done, int total)? onProgress,
    TranscriptionLanguage language = TranscriptionLanguage.auto,
    int? speakerCount,
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
      return await _run(path, numThreads, onProgress, language, speakerCount);
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
    await _diarizer?.release();
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
    final speakers = _diarizing;
    if (speakers != null) {
      _diarizing = null;
      await speakers.cancel();
    }
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
    int? speakerCount,
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

    // WHO IS TALKING, BEFORE ANYTHING IS LOADED TO HEAR THEM WITH.
    final speakers = await _separateSpeakers(
      path: path,
      header: header,
      totalSamples: totalSamples,
      numThreads: numThreads,
      speakerCount: speakerCount,
      gridWindows: grid.length,
      onProgress: onProgress,
    );
    _throwIfCancelled();

    await _requireModel(primary);

    VadSegmentation? vad;
    // Turns from the diarizer already end in pauses and already cover the
    // whole recording, so the voice-activity pass has nothing left to add -
    // and running it would cut windows across speakers again.
    if (speakers.windows.isEmpty &&
        useVoiceActivitySegmentation &&
        await _models.isVadReady(_vadModel)) {
      vad = VadSegmentation(
        modelPath: _models.vadPathOf(_vadModel),
        model: _vadModel,
        maxWindowSamples:
            primary.maxWindow.inMicroseconds * primary.sampleRateHz ~/ 1000000,
      );
    }
    _throwIfCancelled();

    final steps = speakers.steps;
    final planned =
        speakers.windows.isEmpty ? grid : speakers.windows;
    final first = await _runPass(
      _jobFor(primary, path, header, numThreads, planned, vad),
      (done, total) => onProgress?.call(steps + done, steps + total),
      allowPlanning: speakers.windows.isEmpty,
    );
    final windows = first.windows;
    // The voice-activity pass may have replaced the windows; it only runs when
    // there are no speaker windows, so there is nothing to re-map.
    final speakerOf = speakers.labels.length == windows.length
        ? speakers.labels
        : List<String?>.filled(windows.length, null);
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
            (done, _) => onProgress?.call(
              steps + windows.length + done,
              steps + total,
            ),
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
            speaker: speakerOf[i],
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

  /// Separates the speakers, cleans up what came back, and turns it into the
  /// windows to decode.
  ///
  /// SILENT WHEN IT CANNOT RUN. No diarizer, models not installed, the engine
  /// failing, or nothing heard at all: the answer is "no speakers", the caller
  /// falls back to the fixed grid, and the note is transcribed exactly as it
  /// was before this existed. Only a CANCEL is passed on, because the user
  /// asked for it.
  Future<_Speakers> _separateSpeakers({
    required String path,
    required WavHeader header,
    required int totalSamples,
    required int numThreads,
    required int? speakerCount,
    required int gridWindows,
    required void Function(int done, int total)? onProgress,
  }) async {
    final diarizer = _diarizer;
    if (diarizer == null) return _Speakers.none;
    _throwIfCancelled();
    final status = await _models.diarizationStatus(_diarizationModel);
    _throwIfCancelled();
    if (!status.isReady) return _Speakers.none;
    if (header.sampleRateHz != _diarizationModel.sampleRateHz) {
      return _Speakers.none;
    }

    final steps = _speakerSteps(gridWindows);
    onProgress?.call(0, steps + gridWindows);

    // NOTHING ELSE IN MEMORY. The recognizer may be holding 188 MB from the
    // note before this one; both speaker networks plus the whole recording as
    // floats are about to be.
    await _recognizer.releaseModel();
    _throwIfCancelled();

    final List<SpeakerTurn> turns;
    try {
      turns = await _diarize(
        diarizer,
        DiarizationJob(
          model: _diarizationModel,
          segmentationPath: _models.diarizationPathOf(
            _diarizationModel,
            _diarizationModel.segmentationFile,
          ),
          embeddingPath: _models.diarizationPathOf(
            _diarizationModel,
            _diarizationModel.embeddingFile,
          ),
          audioPath: path,
          dataOffset: header.dataOffset,
          sampleRateHz: header.sampleRateHz,
          totalSamples: totalSamples,
          numThreads: numThreads,
          numClusters: speakerCount,
        ),
        (fraction) => onProgress?.call(
          (fraction * steps).round(),
          steps + gridWindows,
        ),
      );
    } on TranscriptionException {
      rethrow;
    } on Object {
      // A speaker pass that failed is not a transcription that failed.
      await diarizer.release();
      return _Speakers(steps: steps);
    }
    // The driver frees its models before the stream closes; this is for a job
    // that ended badly.
    await diarizer.release();
    _throwIfCancelled();

    final cleaned = SpeakerTurns.clean(
      turns: turns,
      totalSamples: totalSamples,
      sampleRateHz: header.sampleRateHz,
    );
    if (cleaned.isEmpty) return _Speakers(steps: steps);

    final names = SpeakerTurns.labels(cleaned);
    // ONE VOICE, NO LABELS. A note where only one person spoke reads as plain
    // paragraphs; "Speaker 1" in front of every one of them is noise.
    final labelled = names.length > 1;

    final maxWindowSamples = _model.maxWindow.inMicroseconds *
        header.sampleRateHz ~/
        1000000;
    final profile = cleaned.any((turn) => turn.length > maxWindowSamples)
        ? await _loudness(path, header, totalSamples)
        : LoudnessProfile.empty;
    final probeSamples = SpeakerTurns.splitProbe.inMicroseconds *
        header.sampleRateHz ~/
        1000000;
    final windows = SpeakerTurns.planForModel(
      turns: cleaned,
      model: _model,
      quietestSplit: profile.isEmpty
          ? null
          : (start, end) => profile.quietestSplit(start, end, probeSamples),
    );
    return _Speakers(
      steps: steps,
      windows: <SampleRange>[for (final window in windows) window.range],
      labels: <String?>[
        for (final window in windows)
          labelled ? names[window.speaker] : null,
      ],
    );
  }

  /// How many progress steps the speaker pass is worth - see
  /// [speakerWorkShare]. At least one, so a one-window note still moves.
  static int _speakerSteps(int gridWindows) {
    final steps = (gridWindows + speakerWorkShare - 1) ~/ speakerWorkShare;
    return steps < 1 ? 1 : steps;
  }

  /// Runs one diarization to the end and collects the turns it found.
  Future<List<SpeakerTurn>> _diarize(
    SpeakerDiarizer diarizer,
    DiarizationJob job,
    void Function(double fraction) onProgress,
  ) async {
    final done = Completer<List<SpeakerTurn>>();
    final subscription = diarizer.diarize(job).listen(
      (event) {
        switch (event) {
          case DiarizationModelsLoaded():
            break;
          case DiarizationProgress():
            onProgress(event.fraction);
          case DiarizationFinished():
            if (!done.isCompleted) done.complete(event.turns);
        }
      },
      onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(
            const SpeakerDiarizerException(
              'the speaker engine finished without a result',
            ),
          );
        }
      },
      cancelOnError: true,
    );
    _diarizing = subscription;
    try {
      final turns = await done.future;
      _throwIfCancelled();
      return turns;
    } finally {
      if (identical(_diarizing, subscription)) _diarizing = null;
      await subscription.cancel();
    }
  }

  /// One number per 20 ms of the recording, so a long turn can be cut in a
  /// pause. Empty when the audio cannot be read - the cut then falls on the
  /// window boundary, which is what the fixed grid always did.
  Future<LoudnessProfile> _loudness(
    String path,
    WavHeader header,
    int totalSamples,
  ) async {
    final frameSamples = header.sampleRateHz ~/ 50;
    if (frameSamples <= 0) return LoudnessProfile.empty;
    try {
      final frames = <int>[];
      // 64 frames at a time: 40 kB of s16 per read, whatever the note's length.
      final chunkSamples = frameSamples * 64;
      for (var at = 0; at + frameSamples <= totalSamples; at += chunkSamples) {
        _throwIfCancelled();
        final want = at + chunkSamples < totalSamples
            ? chunkSamples
            : totalSamples - at;
        final from = header.dataOffset + at * 2;
        final bytes = await _fileStore.readRange(path, from, from + want * 2);
        final data = ByteData.sublistView(bytes);
        final read = bytes.length ~/ 2;
        for (var frame = 0; frame + frameSamples <= read;
            frame += frameSamples) {
          var sum = 0;
          for (var i = frame; i < frame + frameSamples; i++) {
            sum += data.getInt16(i * 2, Endian.little).abs();
          }
          frames.add(sum ~/ frameSamples);
        }
        if (read < want) break;
      }
      return LoudnessProfile(frameSamples: frameSamples, frames: frames);
    } on TranscriptionException {
      rethrow;
    } on Object {
      return LoudnessProfile.empty;
    }
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

/// What the speaker pass produced for one job.
class _Speakers {
  const _Speakers({
    required this.steps,
    this.windows = const <SampleRange>[],
    this.labels = const <String?>[],
  });

  /// Nothing ran: no diarizer, or its models are not installed.
  static const _Speakers none = _Speakers(steps: 0);

  /// Progress steps the speaker pass took, and the offset every later step is
  /// reported at. Zero when it did not run at all.
  final int steps;

  /// The windows to decode, one speaker each; empty means "use the grid".
  final List<SampleRange> windows;

  /// The label of each window, or null throughout when only one person spoke.
  final List<String?> labels;
}
