import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../model/diarization.dart';
import 'process_memory.dart';
import 'speaker_diarizer.dart';
import 'speech_recognizer.dart' show pcm16leToFloat32;

/// [SpeakerDiarizer] backed by `sherpa_onnx` (k2-fsa, Apache-2.0).
///
/// One of the TWO files in the app that may name `sherpa_onnx` - the other is
/// `speech_recognizer_sherpa.dart`. Everything it accepts and emits is a
/// `lib/model/` type.
///
/// THE CONFIGURATION. `OfflineSpeakerDiarization` with a pyannote
/// segmentation model and a 3D-Speaker CAM++ embedding model, `FastClustering`
/// with either a threshold (nobody has said how many speakers there are) or an
/// exact `numClusters` (they have). `windowShiftRatio`, `minDurationOn` and
/// `minDurationOff` come from the model entry - see [DiarizationModels].
///
/// ISOLATION, AND NOTHING LEFT BEHIND. Each job gets its own worker isolate:
/// it loads both networks, reads the recording, runs the one blocking native
/// call, frees the networks, asks the allocator to hand the pages back
/// (`M_PURGE`, the same fix the speech model needed) and exits. By the time
/// the stream closes the memory is gone, which is the point: the speech model
/// is loaded straight afterwards and the two must never be resident together.
///
/// THE WAVEFORM IS HELD WHOLE. The engine takes the entire recording as one
/// Float32List - 4 bytes a sample, so about 38 MB for ten minutes, plus the
/// same again in the native copy it makes. That is the cost of diarizing at
/// all with this API, and it is why the worker exits as soon as it is done.
class SherpaOnnxSpeakerDiarizer implements SpeakerDiarizer {
  SherpaOnnxSpeakerDiarizer({this.returnFreedMemory = true});

  /// Whether the worker asks the native allocator to return freed pages to the
  /// operating system before it exits. On by default, for the reason in
  /// [ProcessMemory.releaseFreedNativeMemory].
  final bool returnFreedMemory;

  _Worker? _running;

  @override
  Stream<DiarizationEvent> diarize(DiarizationJob job) {
    late final StreamController<DiarizationEvent> controller;
    _Worker? worker;
    controller = StreamController<DiarizationEvent>(
      onListen: () async {
        if (_running != null) {
          controller.addError(
            const SpeakerDiarizerException('a diarization is already running'),
          );
          await controller.close();
          return;
        }
        final started = _Worker(controller, returnFreedMemory);
        worker = started;
        _running = started;
        try {
          await started.run(job);
        } finally {
          if (identical(_running, started)) _running = null;
        }
      },
      onCancel: () async {
        await worker?.stop();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> release() async {
    await _running?.stop();
    _running = null;
  }
}

/// One job's isolate, and the memory sampled while it runs.
class _Worker {
  _Worker(this._controller, this._returnFreedMemory);

  final StreamController<DiarizationEvent> _controller;
  final bool _returnFreedMemory;
  final Completer<void> _done = Completer<void>();

  bool _stopped = false;
  List<SpeakerTurn>? _turns;
  int? _rssBefore;
  int? _peakRss;
  Timer? _sampler;

  Future<void> run(DiarizationJob job) async {
    final fromWorker = ReceivePort();
    _rssBefore = ProcessMemory.residentKb();
    _peakRss = _rssBefore;
    _sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final now = ProcessMemory.residentKb();
      if (now != null && (_peakRss == null || now > _peakRss!)) _peakRss = now;
    });
    fromWorker.listen((Object? message) {
      switch (message) {
        case _Loaded loaded:
          _emit(DiarizationModelsLoaded(loaded.loadTime));
        case _Progress progress:
          _emit(
            DiarizationProgress(done: progress.done, total: progress.total),
          );
        case _Turns turns:
          // HELD BACK UNTIL THE WORKER IS GONE, so the interface's promise -
          // the models are freed by the time the stream closes - is true, and
          // so the memory figure is measured after the free and the purge
          // rather than before them.
          _sample();
          _turns = turns.turns;
        case _Failure failure:
          _fail(
            SpeakerDiarizerException(failure.message, failure.detail),
          );
        case null:
          // The worker has exited: freed, purged, gone.
          final found = _turns;
          if (found != null) {
            _turns = null;
            _emit(
              DiarizationFinished(
                turns: found,
                rssBeforeLoadKb: _rssBefore,
                peakRssKb: _peakRss,
                rssAfterReleaseKb: ProcessMemory.residentKb(),
              ),
            );
          }
          _finish();
      }
    });
    try {
      await Isolate.spawn<_Start>(
        _workerMain,
        _Start(job, fromWorker.sendPort, _returnFreedMemory),
        onExit: fromWorker.sendPort,
        debugName: 'speaker-diarizer',
      );
    } on Object catch (error) {
      _fail(
        SpeakerDiarizerException('could not start the diarizer', error),
      );
      _finish();
    }
    await _done.future;
    fromWorker.close();
  }

  void _sample() {
    final now = ProcessMemory.residentKb();
    if (now != null && (_peakRss == null || now > _peakRss!)) _peakRss = now;
  }

  void _emit(DiarizationEvent event) {
    if (_stopped || _controller.isClosed) return;
    _controller.add(event);
  }

  void _fail(SpeakerDiarizerException error) {
    if (_stopped || _controller.isClosed) return;
    _controller.addError(error);
  }

  void _finish() {
    _sampler?.cancel();
    _sampler = null;
    if (!_controller.isClosed) unawaited(_controller.close());
    if (!_done.isCompleted) _done.complete();
  }

  /// Stops emitting and waits for the worker to exit on its own, so the native
  /// free and the purge still run. A kill would leave both networks in memory.
  Future<void> stop() async {
    _stopped = true;
    if (_done.isCompleted) return;
    await _done.future;
  }
}

class _Start {
  const _Start(this.job, this.replies, this.returnFreedMemory);

  final DiarizationJob job;
  final SendPort replies;
  final bool returnFreedMemory;
}

class _Loaded {
  const _Loaded(this.loadTime);

  final Duration loadTime;
}

class _Progress {
  const _Progress(this.done, this.total);

  final int done;
  final int total;
}

class _Turns {
  const _Turns(this.turns);

  final List<SpeakerTurn> turns;
}

class _Failure {
  const _Failure(this.message, this.detail);

  final String message;
  final String detail;
}

Future<void> _workerMain(_Start start) async {
  final replies = start.replies;
  final job = start.job;
  sherpa.OfflineSpeakerDiarization? diarizer;
  try {
    sherpa.initBindings();
    final clock = Stopwatch()..start();
    diarizer = sherpa.OfflineSpeakerDiarization(
      sherpa.OfflineSpeakerDiarizationConfig(
        segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
          pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
            model: job.segmentationPath,
            windowShiftRatio: job.model.windowShiftRatio,
          ),
          numThreads: job.numThreads,
          debug: false,
        ),
        embedding: sherpa.SpeakerEmbeddingExtractorConfig(
          model: job.embeddingPath,
          numThreads: job.numThreads,
          debug: false,
        ),
        clustering: sherpa.FastClusteringConfig(
          // -1 means "work it out from the threshold"; a number the user gave
          // means exactly that many, and then the threshold is not consulted.
          numClusters: job.numClusters ?? -1,
          threshold: job.model.threshold,
        ),
        minDurationOn: job.model.minDurationOn.inMicroseconds / 1e6,
        minDurationOff: job.model.minDurationOff.inMicroseconds / 1e6,
      ),
    );
    clock.stop();
    replies.send(_Loaded(clock.elapsed));

    final samples = _readAll(job);
    final segments = diarizer.processWithCallback(
      samples: samples,
      callback: (done, total) {
        replies.send(_Progress(done, total));
        // Zero is "carry on": there is no way to stop this call part way, and
        // the caller does not need one - it is one pass over the file.
        return 0;
      },
    );
    replies.send(
      _Turns(<SpeakerTurn>[
        for (final segment in segments)
          SpeakerTurn.fromSeconds(
            start: segment.start,
            end: segment.end,
            speaker: segment.speaker,
            sampleRateHz: job.sampleRateHz,
          ),
      ]),
    );
  } on Object catch (error, stack) {
    replies.send(
      _Failure(
        diarizer == null
            ? 'could not load the speaker models'
            : 'speaker separation failed',
        '$error\n$stack',
      ),
    );
  } finally {
    diarizer?.free();
    if (diarizer != null && start.returnFreedMemory) {
      ProcessMemory.releaseFreedNativeMemory();
    }
  }
}

/// The whole recording as floats, read a megabyte at a time so the s16 bytes
/// and the floats are never both held whole.
Float32List _readAll(DiarizationJob job) {
  final out = Float32List(job.totalSamples);
  final file = File(job.audioPath).openSync();
  try {
    file.setPositionSync(job.dataOffset);
    const chunkSamples = 512 * 1024;
    var at = 0;
    while (at < job.totalSamples) {
      final count = at + chunkSamples < job.totalSamples
          ? chunkSamples
          : job.totalSamples - at;
      final bytes = file.readSync(count * 2);
      if (bytes.isEmpty) break;
      out.setAll(at, pcm16leToFloat32(bytes));
      at += bytes.length ~/ 2;
    }
  } finally {
    file.closeSync();
  }
  return out;
}
