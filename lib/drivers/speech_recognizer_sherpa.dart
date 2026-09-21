import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../model/speech_presence.dart';
import '../model/speech_windows.dart';
import '../model/transcription.dart';
import 'keep_warm_recognizer.dart';
import 'note_noise_floor.dart';
import 'process_memory.dart';
import 'speech_recognizer.dart';

/// [SpeechRecognizer] backed by `sherpa_onnx` (k2-fsa, Apache-2.0).
///
/// This is the ONLY file in the app that may name `sherpa_onnx`. Everything it
/// accepts and emits is a `lib/model/` type.
///
/// THE CONFIGURATION (see [_load] for the English transducer). An OFFLINE
/// recognizer with a NeMo CTC model, 80 mel
/// bins, greedy search, 16 kHz - the Dart spelling of the Python
/// `OfflineRecognizer.from_nemo_ctc(model, tokens, num_threads, sample_rate=
/// 16000, feature_dim=80, decoding_method="greedy_search")` that was verified
/// against this model. The model card's own example configures an ONLINE
/// TRANSDUCER with an empty decoder and joiner; that is wrong for this CTC
/// export and must not be copied.
///
/// ISOLATION. The recognizer lives in a worker isolate: created there, used
/// there and freed there, so the UI isolate never blocks on inference.
/// `sherpa_onnx` keeps its FFI bindings per isolate, which is why
/// [sherpa.initBindings] is called inside the worker.
///
/// TWO MODELS, NEVER TOGETHER. A worker holds one [RecognizerConfig]; a job for
/// the other model (Hindi then English in one note) makes
/// [KeepWarmSpeechRecognizer] shut this worker down - native free, allocator
/// purge, isolate exit - before a new one loads.
///
/// SILENCE IS NOT DECODED. Before the first window, the worker measures the
/// note's own noise floor once ([measureNoiseFloor]); a window that never
/// rises above it is answered with the same "" a decode would have produced
/// ([SpeechPresence]). Measured on the owner's 13.6 hours of recordings that
/// is 0 windows - their empty segments are audible, not silent - so this is a
/// floor under the cost of dead air, not a saving to plan around.
///
/// LIFETIME. One worker serves consecutive jobs with one load, and frees the
/// model and exits after [idleTimeout] without work, on [releaseModel], or
/// when a job needs another configuration - the rules are
/// [KeepWarmSpeechRecognizer]'s, tested there. After the free the worker asks
/// the allocator to return the pages ([returnFreedMemory]).
class SherpaOnnxSpeechRecognizer implements SpeechRecognizer {
  SherpaOnnxSpeechRecognizer({
    this.returnFreedMemory = true,
    Duration idleTimeout = KeepWarmSpeechRecognizer.defaultIdleTimeout,
  }) {
    _inner = KeepWarmSpeechRecognizer(
      idleTimeout: idleTimeout,
      spawn: (config) => _IsolateWorker(config, returnFreedMemory),
    );
  }

  /// Whether the worker asks the native allocator to hand freed pages back to
  /// the operating system once the model has been released.
  ///
  /// On by default: it makes the release immediate instead of a second or two
  /// later (see `doc/agentFindings/on-device-stt.md`). Switchable so that
  /// measurement can be repeated with and without it.
  final bool returnFreedMemory;

  late final KeepWarmSpeechRecognizer _inner;

  @override
  Stream<RecognitionEvent> transcribe(RecognitionJob job) =>
      _inner.transcribe(job);

  @override
  Future<void> releaseModel() => _inner.releaseModel();
}

/// One worker isolate holding one recognizer.
class _IsolateWorker implements RecognizerWorker {
  _IsolateWorker(this._config, this._returnFreedMemory);

  final RecognizerConfig _config;
  final bool _returnFreedMemory;

  final ReceivePort _fromWorker = ReceivePort();
  final Completer<void> _exited = Completer<void>();
  final Completer<SendPort> _hello = Completer<SendPort>();
  Future<SendPort>? _started;
  bool _gone = false;
  int _nextId = 0;
  _RunningJob? _job;

  Future<SendPort> _start() => _started ??= _spawn();

  Future<SendPort> _spawn() async {
    // Failing before the handshake must not surface as an uncaught error when
    // nobody is awaiting it yet; callers that are still get the error.
    _hello.future.ignore();
    _fromWorker.listen(_onMessage);
    try {
      await Isolate.spawn<_WorkerStart>(
        _workerMain,
        _WorkerStart(_config, _fromWorker.sendPort, _returnFreedMemory),
        onExit: _fromWorker.sendPort,
        debugName: 'speech-recognizer',
      );
    } on Object {
      _workerGone();
      rethrow;
    }
    return _hello.future;
  }

  void _onMessage(Object? message) {
    final job = _job;
    switch (message) {
      case SendPort port:
        if (!_hello.isCompleted) _hello.complete(port);
      case _Tagged tagged:
        if (job != null && job.id == tagged.id) job.add(tagged.event);
      case _JobEnded ended:
        if (job != null && job.id == ended.id) {
          _job = null;
          job.end();
        }
      case _WorkerFailure failure:
        if (job != null) {
          _job = null;
          job.fail(SpeechRecognizerException(failure.message, failure.detail));
        }
      case null:
        // The worker exited - after a shutdown, a failure, or a crash. If a
        // job was still waiting, say so rather than hang.
        if (job != null) {
          _job = null;
          job.fail(
            const SpeechRecognizerException(
              'the recognizer isolate exited without a result',
            ),
          );
        }
        _workerGone();
    }
  }

  void _workerGone() {
    _gone = true;
    _fromWorker.close();
    if (!_hello.isCompleted) {
      _hello.completeError(
        const SpeechRecognizerException('the recognizer isolate is gone'),
      );
    }
    if (!_exited.isCompleted) _exited.complete();
  }

  @override
  Stream<RecognitionEvent> run(RecognitionJob job) {
    late final StreamController<RecognitionEvent> controller;
    late final _RunningJob running;
    controller = StreamController<RecognitionEvent>(
      onListen: () async {
        if (_gone) {
          running.fail(
            const SpeechRecognizerException('the recognizer isolate is gone'),
          );
          return;
        }
        final SendPort port;
        try {
          port = await _start();
        } on Object catch (error) {
          running.fail(
            SpeechRecognizerException('could not start the recognizer', error),
          );
          return;
        }
        if (running.cancelled) {
          running.end();
          return;
        }
        _job = running;
        running.startSampling();
        port.send(_RunJob(running.id, job));
      },
      onCancel: () async {
        // Ask, do not kill: killing the isolate mid-job would skip the native
        // free() and leave the model's memory behind. The worker checks for
        // this between windows.
        running.cancelled = true;
        if (identical(_job, running)) {
          try {
            (await _started)?.send(_CancelJob(running.id));
          } on Object {
            // The worker is gone, which stops the job just as well.
          }
        }
        await running.stopped.future;
      },
    );
    running = _RunningJob(_nextId++, controller);
    return controller.stream;
  }

  @override
  Future<void> shutdown() async {
    if (_gone) return;
    final started = _started;
    if (started == null) {
      _workerGone();
      return;
    }
    try {
      (await started).send(_shutdown);
    } on Object {
      return;
    }
    await _exited.future;
  }
}

/// The receiving side of one job: its stream, and the memory sampled while it
/// runs.
class _RunningJob {
  _RunningJob(this.id, this.controller);

  final int id;
  final StreamController<RecognitionEvent> controller;
  final Completer<void> stopped = Completer<void>();
  bool cancelled = false;

  // The per-job memory peak, sampled from THIS isolate while the worker is
  // busy in native code. The kernel's own high-water mark cannot be reset
  // from inside an Android app, so it would report the worst job the process
  // ever ran rather than this one. 50 ms is far shorter than a load or a
  // window decode, which is where the peak is.
  int? rssBefore;
  int? peakRss;
  Timer? sampler;

  void startSampling() {
    rssBefore = ProcessMemory.residentKb();
    peakRss = rssBefore;
    sampler = Timer.periodic(const Duration(milliseconds: 50), (_) => sample());
  }

  void sample() {
    final now = ProcessMemory.residentKb();
    if (now != null && (peakRss == null || now > peakRss!)) peakRss = now;
  }

  void add(RecognitionEvent event) {
    if (!controller.isClosed) controller.add(event);
  }

  void end() {
    sample();
    sampler?.cancel();
    if (!controller.isClosed && !cancelled) {
      controller.add(
        RecognitionReleased(
          rssBeforeLoadKb: rssBefore,
          peakRssKb: peakRss,
          rssAfterReleaseKb: ProcessMemory.residentKb(),
          keptLoaded: true,
        ),
      );
    }
    unawaited(controller.close());
    if (!stopped.isCompleted) stopped.complete();
  }

  void fail(SpeechRecognizerException error) {
    sampler?.cancel();
    if (!controller.isClosed && !cancelled) controller.addError(error);
    unawaited(controller.close());
    if (!stopped.isCompleted) stopped.complete();
  }
}

const String _shutdown = 'shutdown';

class _WorkerStart {
  const _WorkerStart(this.config, this.replies, this.returnFreedMemory);

  final RecognizerConfig config;
  final SendPort replies;
  final bool returnFreedMemory;
}

class _RunJob {
  const _RunJob(this.id, this.job);

  final int id;
  final RecognitionJob job;
}

class _CancelJob {
  const _CancelJob(this.id);

  final int id;
}

class _Tagged {
  const _Tagged(this.id, this.event);

  final int id;
  final RecognitionEvent event;
}

class _JobEnded {
  const _JobEnded(this.id);

  final int id;
}

class _WorkerFailure {
  const _WorkerFailure(this.message, this.detail);

  final String message;
  final String detail;
}

Future<void> _workerMain(_WorkerStart start) async {
  final replies = start.replies;
  final inbox = ReceivePort();
  final queue = <_RunJob>[];
  final cancelled = <int>{};
  var shuttingDown = false;
  Completer<void>? wake;
  inbox.listen((Object? message) {
    switch (message) {
      case _RunJob run:
        queue.add(run);
      case _CancelJob cancel:
        cancelled.add(cancel.id);
      case _shutdown:
        shuttingDown = true;
    }
    final waiting = wake;
    wake = null;
    waiting?.complete();
  });
  replies.send(inbox.sendPort);

  sherpa.OfflineRecognizer? recognizer;
  try {
    sherpa.initBindings();
    while (!shuttingDown) {
      if (queue.isEmpty) {
        final waiting = wake = Completer<void>();
        await waiting.future;
        continue;
      }
      final run = queue.removeAt(0);
      final id = run.id;
      final job = run.job;
      if (cancelled.remove(id)) {
        replies.send(_JobEnded(id));
        continue;
      }

      final reused = recognizer != null;
      final loadClock = Stopwatch()..start();
      recognizer ??= _load(start.config);
      loadClock.stop();
      replies.send(
        _Tagged(
          id,
          RecognitionModelLoaded(
            reused ? Duration.zero : loadClock.elapsed,
            reused: reused,
          ),
        ),
      );

      final audio = File(job.audioPath).openSync();
      try {
        var windows = job.windows;
        final vad = job.vad;
        if (vad != null) {
          final planned = await _planWithVad(
            job,
            vad,
            audio,
            () => cancelled.contains(id) || shuttingDown,
          );
          if (planned != null) {
            windows = planned;
            replies.send(_Tagged(id, RecognitionWindowsPlanned(planned)));
          }
        }
        // The note's own noise floor, measured once, so a window holding
        // nothing but it can be answered without a decode. Null means "not
        // measured": then nothing is skipped.
        final floor = await measureNoiseFloor(
          audio: audio,
          dataOffset: job.dataOffset,
          totalSamples: windows.isEmpty ? 0 : windows.last.end,
          sampleRateHz: job.sampleRateHz,
          stop: () => cancelled.contains(id) || shuttingDown,
        );
        for (var index = 0; index < windows.length; index++) {
          // Yield so a cancel message sent while the last window was decoding
          // is delivered before the next one starts.
          await Future<void>.delayed(Duration.zero);
          if (cancelled.contains(id) || shuttingDown) break;

          final window = windows[index];
          final clock = Stopwatch()..start();
          audio.setPositionSync(job.dataOffset + window.start * 2);
          final samples = pcm16leToFloat32(audio.readSync(window.length * 2));

          // NOTHING BUT THE FLOOR: hand back the same "" the recognizer would
          // have taken a full decode to produce. Indistinguishable downstream
          // - an empty window is an empty window however it was reached.
          if (!SpeechPresence.canContainSpeech(
            samples: samples,
            sampleRateHz: job.sampleRateHz,
            noiseFloorDbfs: floor,
          )) {
            clock.stop();
            replies.send(
              _Tagged(
                id,
                RecognitionWindowDecoded(
                  index: index,
                  text: '',
                  decodeTime: clock.elapsed,
                ),
              ),
            );
            continue;
          }

          final stream = recognizer.createStream();
          try {
            stream.acceptWaveform(
              samples: samples,
              sampleRate: job.sampleRateHz,
            );
            recognizer.decode(stream);
            final text = recognizer.getResult(stream).text;
            clock.stop();
            replies.send(
              _Tagged(
                id,
                RecognitionWindowDecoded(
                  index: index,
                  text: text,
                  decodeTime: clock.elapsed,
                ),
              ),
            );
          } finally {
            stream.free();
          }
        }
      } finally {
        audio.closeSync();
      }
      cancelled.remove(id);
      replies.send(_JobEnded(id));
    }
  } on Object catch (error, stack) {
    replies.send(
      _WorkerFailure(
        recognizer == null
            ? 'could not load the speech model'
            : 'speech recognition failed',
        '$error\n$stack',
      ),
    );
  } finally {
    recognizer?.free();
    // onnxruntime's allocations are back in the native allocator now, but the
    // allocator keeps the pages for a second or two; ask for them to be
    // returned to the OS at once.
    if (recognizer != null && start.returnFreedMemory) {
      ProcessMemory.releaseFreedNativeMemory();
    }
    inbox.close();
  }
}

/// Loads the one model [config] names.
///
/// CTC: `OfflineNemoEncDecCtcModelConfig(model)`, as verified for
/// IndicConformer. TRANSDUCER: `OfflineTransducerModelConfig(encoder, decoder,
/// joiner)` with `modelType: 'nemo_transducer'` - the Dart spelling of the
/// Python `OfflineRecognizer.from_transducer(..., model_type=
/// "nemo_transducer")` the laptop evaluation ran Parakeet TDT 110M with.
sherpa.OfflineRecognizer _load(RecognizerConfig config) =>
    sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        feat: sherpa.FeatureConfig(
          sampleRate: config.sampleRateHz,
          featureDim: config.featureDim,
        ),
        model: switch (config.architecture) {
          SpeechModelArchitecture.nemoCtc => sherpa.OfflineModelConfig(
              nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(
                model: config.modelPath,
              ),
              tokens: config.tokensPath,
              numThreads: config.numThreads,
              provider: 'cpu',
              debug: false,
            ),
          SpeechModelArchitecture.nemoTransducer => sherpa.OfflineModelConfig(
              transducer: sherpa.OfflineTransducerModelConfig(
                encoder: config.modelPath,
                decoder: config.decoderPath,
                joiner: config.joinerPath,
              ),
              tokens: config.tokensPath,
              numThreads: config.numThreads,
              provider: 'cpu',
              modelType: 'nemo_transducer',
              debug: false,
            ),
        },
        decodingMethod: 'greedy_search',
      ),
    );

/// Runs Silero VAD over the whole recording and plans windows in its pauses.
///
/// Null when it could not run - the model would not load, or the job was
/// cancelled part way - and the caller keeps the fixed grid. The detector is
/// small (about 630 KB) and is loaded and freed per job.
Future<List<SampleRange>?> _planWithVad(
  RecognitionJob job,
  VadSegmentation vad,
  RandomAccessFile audio,
  bool Function() stop,
) async {
  final rate = job.sampleRateHz;
  final windowSamples = vad.maxWindowSamples;
  // The fixed grid covers the whole recording, so its end is the length.
  final totalSamples = job.windows.isEmpty ? 0 : job.windows.last.end;
  if (windowSamples <= 0 || totalSamples <= 0) return null;
  sherpa.VoiceActivityDetector? detector;
  try {
    detector = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vad.modelPath,
          threshold: vad.model.threshold,
          minSilenceDuration: vad.model.minSilence.inMicroseconds / 1e6,
          minSpeechDuration: vad.model.minSpeech.inMicroseconds / 1e6,
          // Asks the detector to find a split point itself in speech longer
          // than a window, which beats the planner's grid backstop.
          maxSpeechDuration: windowSamples / rate,
        ),
        sampleRate: rate,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 2 * windowSamples / rate + 2,
    );
    final speech = <SampleRange>[];
    void drain() {
      while (!detector!.isEmpty()) {
        final segment = detector.front();
        speech.add(
          SampleRange(segment.start, segment.start + segment.samples.length),
        );
        detector.pop();
      }
    }

    // One second at a time, yielding between, so a cancel is seen promptly.
    final chunk = rate;
    for (var start = 0; start < totalSamples; start += chunk) {
      await Future<void>.delayed(Duration.zero);
      if (stop()) return null;
      final count =
          start + chunk < totalSamples ? chunk : totalSamples - start;
      audio.setPositionSync(job.dataOffset + start * 2);
      detector.acceptWaveform(pcm16leToFloat32(audio.readSync(count * 2)));
      drain();
    }
    detector.flush();
    drain();
    return SpeechWindows.plan(
      speech: speech,
      totalSamples: totalSamples,
      maxWindowSamples: windowSamples,
      padSamples: vad.model.padding.inMicroseconds * rate ~/ 1000000,
    );
  } on Object {
    return null;
  } finally {
    detector?.free();
  }
}
