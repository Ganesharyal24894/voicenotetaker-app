import 'dart:async';

import '../model/transcription.dart';
import 'speech_recognizer.dart';

/// One loaded recognizer that runs jobs one after another, then ends.
///
/// The seam between [KeepWarmSpeechRecognizer], which decides WHEN a model is
/// loaded, reused and freed, and an engine-specific worker (an isolate running
/// `sherpa_onnx`) that does the work. Tests supply a fake.
abstract class RecognizerWorker {
  /// Runs one job on this worker, loading the model on the first.
  ///
  /// The same stream contract as [SpeechRecognizer.transcribe], except that
  /// the closing [RecognitionReleased] has `keptLoaded: true` - the worker
  /// keeps its model until [shutdown]. An error means the worker has freed its
  /// model and is ending; it must not be given another job.
  ///
  /// Cancelling stops the job at its next window boundary and completes once
  /// it has stopped; the model stays loaded.
  Stream<RecognitionEvent> run(RecognitionJob job);

  /// Frees the model and ends the worker. Completes once it is gone. Safe to
  /// call more than once, and on a worker that already failed.
  Future<void> shutdown();
}

/// [SpeechRecognizer] that keeps the model loaded between jobs, and only then.
///
/// WHY. The background queue transcribes notes back to back. Loading the
/// 188 MB model costs 1.2-4.9 s on the owner's phone every time, which for a
/// typical short note is more than the decode. So while jobs keep arriving,
/// one worker - and one copy of the model - serves them all.
///
/// AND THEN IT LETS GO. The model is freed, and the worker ends, when:
///
///   * no job has arrived for [idleTimeout] after the last one ended;
///   * [releaseModel] is called (the app is leaving the foreground where it
///     may not work, the queue drained in the background, teardown);
///   * a job needs a different [RecognizerConfig] (another model, thread
///     count) - the old one is freed BEFORE the new one is loaded, so two
///     models are never in memory together;
///   * the worker fails.
///
/// [idleTimeout] of zero frees after every job: the old one-job-one-load
/// behaviour, which the on-device measurement tests use.
///
/// Engine-free on purpose - it names no package - so every one of those rules
/// is unit tested with a fake [RecognizerWorker].
class KeepWarmSpeechRecognizer implements SpeechRecognizer {
  KeepWarmSpeechRecognizer({
    required this._spawn,
    this.idleTimeout = defaultIdleTimeout,
  });

  /// Long enough to carry a queue from one note to the next (the controller
  /// starts the next job within milliseconds), short enough that a model loaded
  /// for one tap on Transcribe does not stay resident while the user reads.
  static const Duration defaultIdleTimeout = Duration(seconds: 30);

  final RecognizerWorker Function(RecognizerConfig config) _spawn;

  final Duration idleTimeout;

  RecognizerWorker? _worker;
  RecognizerConfig? _config;
  Timer? _idle;

  /// Completes when a shutdown in progress has finished.
  Future<void>? _stopping;

  /// The running job, so [releaseModel] can stop it.
  _Job? _job;

  /// Whether a model is in memory, or being loaded, right now.
  bool get isModelLoaded => _worker != null;

  @override
  Stream<RecognitionEvent> transcribe(RecognitionJob job) {
    late final StreamController<RecognitionEvent> controller;
    late final _Job current;
    controller = StreamController<RecognitionEvent>(
      onListen: () async {
        if (_job != null) {
          controller.addError(
            const SpeechRecognizerException('a job is already running'),
          );
          await controller.close();
          return;
        }
        _job = current;
        _idle?.cancel();
        _idle = null;
        try {
          final config = job.recognizerConfig;
          if (_worker != null && _config != config) await _stopWorker();
          final stopping = _stopping;
          if (stopping != null) await stopping;
          if (current.cancelled) {
            current.finish(this);
            return;
          }
          final worker = _worker ??= _spawn(config);
          _config = config;
          current.subscription = worker.run(job).listen(
            (event) {
              if (event is RecognitionReleased) {
                current.released = event;
              } else {
                controller.add(event);
              }
            },
            onError: (Object error) {
              // The worker freed its model and is ending; it is not reused.
              if (identical(_worker, worker)) {
                _worker = null;
                _config = null;
              }
              unawaited(worker.shutdown());
              current.failed = true;
              controller.addError(error);
              current.finish(this);
              unawaited(controller.close());
            },
            onDone: () async {
              if (current.failed) return;
              final released = current.released;
              if (idleTimeout <= Duration.zero) await _stopWorker();
              if (released != null) {
                controller.add(
                  RecognitionReleased(
                    rssBeforeLoadKb: released.rssBeforeLoadKb,
                    peakRssKb: released.peakRssKb,
                    rssAfterReleaseKb: released.rssAfterReleaseKb,
                    keptLoaded: _worker != null,
                  ),
                );
              }
              current.finish(this);
              await controller.close();
            },
            cancelOnError: true,
          );
        } on Object catch (error) {
          current.failed = true;
          controller.addError(
            SpeechRecognizerException('could not start the recognizer', error),
          );
          current.finish(this);
          await controller.close();
        }
      },
      onCancel: () async {
        current.cancelled = true;
        await current.subscription?.cancel();
        current.finish(this);
        await current.ended.future;
      },
    );
    current = _Job()..controller = controller;
    return controller.stream;
  }

  @override
  Future<void> releaseModel() async {
    _idle?.cancel();
    _idle = null;
    final job = _job;
    if (job != null) {
      job.cancelled = true;
      await job.subscription?.cancel();
      // Whoever was listening learns the job will not finish, rather than
      // waiting on a stream nothing will ever close.
      final listener = job.controller;
      if (listener != null && !listener.isClosed) {
        listener.addError(
          const SpeechRecognizerException('the model was released'),
        );
        unawaited(listener.close());
      }
      job.finish(this);
    }
    await _stopWorker();
  }

  /// Called once per job, however it ended.
  void _jobEnded(_Job job) {
    if (!identical(_job, job)) return;
    _job = null;
    if (_worker == null) return;
    if (idleTimeout <= Duration.zero) {
      unawaited(_stopWorker());
      return;
    }
    _idle?.cancel();
    _idle = Timer(idleTimeout, () {
      _idle = null;
      if (_job == null) unawaited(_stopWorker());
    });
  }

  Future<void> _stopWorker() async {
    final worker = _worker;
    _worker = null;
    _config = null;
    if (worker == null) {
      final stopping = _stopping;
      if (stopping != null) await stopping;
      return;
    }
    final stopping = worker.shutdown();
    _stopping = stopping;
    try {
      await stopping;
    } finally {
      if (identical(_stopping, stopping)) _stopping = null;
    }
  }
}

class _Job {
  StreamController<RecognitionEvent>? controller;
  StreamSubscription<RecognitionEvent>? subscription;
  RecognitionReleased? released;
  bool cancelled = false;
  bool failed = false;
  final Completer<void> ended = Completer<void>();

  void finish(KeepWarmSpeechRecognizer owner) {
    if (ended.isCompleted) return;
    ended.complete();
    owner._jobEnded(this);
  }
}
