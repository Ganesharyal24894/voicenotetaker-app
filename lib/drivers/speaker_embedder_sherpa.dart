import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../model/speaker_embedding.dart';
import '../model/transcription.dart';
import 'process_memory.dart';
import 'speaker_embedder.dart';
import 'speech_recognizer.dart' show pcm16leToFloat32;

/// [SpeakerEmbedder] backed by `sherpa_onnx`'s `SpeakerEmbeddingExtractor`,
/// running the diarization pack's 3D-Speaker CAM++ network (192 values per
/// embedding).
///
/// One of the files in the app that may name `sherpa_onnx`, beside the
/// recognizer and the diarizer. Everything it accepts and emits is a
/// `lib/model/` type.
///
/// WHY A SEPARATE PASS. The diarizer computes these very embeddings inside
/// its one native call and hands back only start, end and cluster number, so
/// the voices have to be embedded again here - from the same network, so they
/// mean the same thing.
///
/// ISOLATION, AND NOTHING LEFT BEHIND - the diarizer's design. Each job gets
/// its own worker isolate: it loads only `campplus.onnx`, embeds the turns,
/// frees the network, asks the allocator to hand the pages back and exits.
///
/// NEVER THE WHOLE WAVEFORM. Each piece is read at its own byte offset, a
/// second at a time, straight into the turn's stream; at most one turn's
/// audio (8 s, half a megabyte as floats) is held in Dart at once, whatever
/// the note's length.
///
/// RESULTS AS THEY COME. Each turn's embedding is sent the moment it is made,
/// so a cancelled job has still delivered everything before the cancel, and
/// the caller never holds more than it has asked for.
class SherpaOnnxSpeakerEmbedder implements SpeakerEmbedder {
  SherpaOnnxSpeakerEmbedder({this.returnFreedMemory = true});

  /// Whether the worker asks the native allocator to return freed pages to the
  /// operating system before it exits; see
  /// [ProcessMemory.releaseFreedNativeMemory].
  final bool returnFreedMemory;

  _Worker? _running;

  @override
  Stream<SpeakerEmbeddingEvent> embed(SpeakerEmbeddingJob job) {
    late final StreamController<SpeakerEmbeddingEvent> controller;
    _Worker? worker;
    controller = StreamController<SpeakerEmbeddingEvent>(
      onListen: () async {
        if (_running != null) {
          controller.addError(
            const SpeakerEmbedderException(
              'an embedding job is already running',
            ),
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

  final StreamController<SpeakerEmbeddingEvent> _controller;
  final bool _returnFreedMemory;
  final Completer<void> _done = Completer<void>();

  bool _stopped = false;
  bool _failed = false;
  SendPort? _commands;
  int? _rssBefore;
  int? _peakRss;
  Timer? _sampler;

  Future<void> run(SpeakerEmbeddingJob job) async {
    final fromWorker = ReceivePort();
    _rssBefore = ProcessMemory.residentKb();
    _peakRss = _rssBefore;
    _sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _sample();
    });
    fromWorker.listen((Object? message) {
      switch (message) {
        case SendPort commands:
          _commands = commands;
          // A stop that came before the worker could hear it.
          if (_stopped) commands.send(null);
        case EmbedderModelLoaded loaded:
          _emit(loaded);
        case TurnEmbedded turn:
          _sample();
          _emit(turn);
        case EmbeddingProgress progress:
          _emit(progress);
        case _Failure failure:
          _failed = true;
          if (!_stopped && !_controller.isClosed) {
            _controller.addError(
              SpeakerEmbedderException(failure.message, failure.detail),
            );
          }
        case null:
          // The worker has exited: freed, purged, gone. Only now is the
          // promise that the network is freed by the end of the stream true.
          if (!_failed) {
            _emit(
              EmbeddingFinished(
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
        debugName: 'speaker-embedder',
      );
    } on Object catch (error) {
      if (!_stopped && !_controller.isClosed) {
        _controller.addError(
          SpeakerEmbedderException('could not start the embedder', error),
        );
      }
      _finish();
    }
    await _done.future;
    fromWorker.close();
  }

  void _sample() {
    final now = ProcessMemory.residentKb();
    if (now != null && (_peakRss == null || now > _peakRss!)) _peakRss = now;
  }

  void _emit(SpeakerEmbeddingEvent event) {
    if (_stopped || _controller.isClosed) return;
    _controller.add(event);
  }

  void _finish() {
    _sampler?.cancel();
    _sampler = null;
    if (!_controller.isClosed) unawaited(_controller.close());
    if (!_done.isCompleted) _done.complete();
  }

  /// Asks the worker to stop after the turn in hand and waits for it to exit
  /// on its own, so the native free and the purge still run. A kill would
  /// leave the network in memory.
  Future<void> stop() async {
    _stopped = true;
    _commands?.send(null);
    if (_done.isCompleted) return;
    await _done.future;
  }
}

class _Start {
  const _Start(this.job, this.replies, this.returnFreedMemory);

  final SpeakerEmbeddingJob job;
  final SendPort replies;
  final bool returnFreedMemory;
}

class _Failure {
  const _Failure(this.message, this.detail);

  final String message;
  final String detail;
}

/// Samples read from the file per step: one second at 16 kHz.
const int _chunkSamples = 16000;

Future<void> _workerMain(_Start start) async {
  final replies = start.replies;
  final job = start.job;
  var stopped = false;
  final commands = ReceivePort();
  commands.listen((_) => stopped = true);
  replies.send(commands.sendPort);

  sherpa.SpeakerEmbeddingExtractor? extractor;
  RandomAccessFile? file;
  try {
    sherpa.initBindings();
    final clock = Stopwatch()..start();
    extractor = sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(
        model: job.embeddingPath,
        numThreads: job.numThreads,
        debug: false,
      ),
    );
    clock.stop();
    replies.send(
      EmbedderModelLoaded(loadTime: clock.elapsed, dim: extractor.dim),
    );

    file = File(job.audioPath).openSync();
    final total = job.turns.length;
    for (var done = 0; done < total; done++) {
      // Lets the stop message in: the loop is otherwise all synchronous.
      await Future<void>.delayed(Duration.zero);
      if (stopped) break;
      final turn = job.turns[done];
      final embedding = _embed(extractor, file, job, turn.pieces);
      if (embedding != null) {
        replies.send(TurnEmbedded(index: turn.index, embedding: embedding));
      }
      replies.send(EmbeddingProgress(done: done + 1, total: total));
    }
  } on Object catch (error, stack) {
    replies.send(
      _Failure(
        extractor == null
            ? 'could not load the speaker embedding model'
            : 'speaker embedding failed',
        '$error\n$stack',
      ),
    );
  } finally {
    file?.closeSync();
    extractor?.free();
    if (extractor != null && start.returnFreedMemory) {
      ProcessMemory.releaseFreedNativeMemory();
    }
    commands.close();
  }
}

/// One embedding for [pieces] fed through one stream, or null when the
/// network needed more audio than there was.
Float32List? _embed(
  sherpa.SpeakerEmbeddingExtractor extractor,
  RandomAccessFile file,
  SpeakerEmbeddingJob job,
  List<SampleRange> pieces,
) {
  final stream = extractor.createStream();
  try {
    for (final piece in pieces) {
      var at = piece.start;
      while (at < piece.end) {
        final count = piece.end - at < _chunkSamples
            ? piece.end - at
            : _chunkSamples;
        file.setPositionSync(job.dataOffset + at * 2);
        final bytes = file.readSync(count * 2);
        if (bytes.length < 2) break;
        stream.acceptWaveform(
          samples: pcm16leToFloat32(bytes),
          sampleRate: job.sampleRateHz,
        );
        at += bytes.length ~/ 2;
      }
    }
    stream.inputFinished();
    if (!extractor.isReady(stream)) return null;
    final embedding = extractor.compute(stream);
    return embedding.isEmpty ? null : embedding;
  } finally {
    stream.free();
  }
}
