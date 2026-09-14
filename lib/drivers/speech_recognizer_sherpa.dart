import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../model/transcription.dart';
import 'process_memory.dart';
import 'speech_recognizer.dart';

/// [SpeechRecognizer] backed by `sherpa_onnx` (k2-fsa, Apache-2.0).
///
/// This is the ONLY file in the app that may name `sherpa_onnx`. Everything it
/// accepts and emits is a `lib/model/` type.
///
/// THE CONFIGURATION. An OFFLINE recognizer with a NeMo CTC model, 80 mel
/// bins, greedy search, 16 kHz - the Dart spelling of the Python
/// `OfflineRecognizer.from_nemo_ctc(model, tokens, num_threads, sample_rate=
/// 16000, feature_dim=80, decoding_method="greedy_search")` that was verified
/// against this model. The model card's own example configures an ONLINE
/// TRANSDUCER with an empty decoder and joiner; that is wrong for this CTC
/// export and must not be copied.
///
/// ISOLATION. Each job runs in a fresh isolate that is spawned for it and
/// exits when it is done: the native recognizer is created there, used there
/// and freed there, so the UI isolate never blocks on inference and no model
/// memory outlives the job. `sherpa_onnx` keeps its FFI bindings per isolate,
/// which is why [sherpa.initBindings] is called inside the worker.
class SherpaOnnxSpeechRecognizer implements SpeechRecognizer {
  const SherpaOnnxSpeechRecognizer({this.returnFreedMemory = true});

  /// Whether the worker asks the native allocator to hand freed pages back to
  /// the operating system once the model has been released.
  ///
  /// On by default: without it about 350 MB stayed resident after every job on
  /// the phone (see `doc/agentFindings/on-device-stt.md`). Switchable so that
  /// measurement can be repeated with and without it.
  final bool returnFreedMemory;

  @override
  Stream<RecognitionEvent> transcribe(RecognitionJob job) {
    late final StreamController<RecognitionEvent> controller;
    final fromWorker = ReceivePort();
    // Completes when the worker isolate has exited - which is after its
    // `finally` has freed the recognizer. Cancelling waits for this, so a
    // caller that cancels and starts another job never has two models loaded.
    final exited = Completer<void>();
    SendPort? toWorker;
    var listenerGone = false;

    // The per-job memory peak, sampled from THIS isolate while the worker is
    // busy in native code. The kernel's own high-water mark cannot be reset
    // from inside an Android app, so it would report the worst job the process
    // ever ran rather than this one. 50 ms is far shorter than a load or a
    // window decode, which is where the peak is.
    int? rssBeforeLoad;
    int? peakRss;
    Timer? sampler;
    void sample() {
      final now = ProcessMemory.residentKb();
      if (now != null && (peakRss == null || now > peakRss!)) peakRss = now;
    }

    void workerGone() {
      sampler?.cancel();
      fromWorker.close();
      if (!exited.isCompleted) exited.complete();
    }

    controller = StreamController<RecognitionEvent>(
      onListen: () async {
        rssBeforeLoad = ProcessMemory.residentKb();
        peakRss = rssBeforeLoad;
        sampler = Timer.periodic(
          const Duration(milliseconds: 50),
          (_) => sample(),
        );
        fromWorker.listen((Object? message) {
          switch (message) {
            case SendPort port:
              toWorker = port;
              if (listenerGone) port.send(_cancel);
            case RecognitionReleased():
              sample();
              sampler?.cancel();
              final after = ProcessMemory.residentKb();
              controller.add(
                RecognitionReleased(
                  rssBeforeLoadKb: rssBeforeLoad,
                  peakRssKb: peakRss,
                  rssAfterReleaseKb: after,
                ),
              );
              unawaited(controller.close());
            case RecognitionEvent event:
              controller.add(event);
            case _WorkerFailure failure:
              controller.addError(
                SpeechRecognizerException(failure.message, failure.detail),
              );
              unawaited(controller.close());
            case null:
              // The worker exited. After a normal finish, a failure or a
              // cancel this only records the fact; if it died without
              // reporting anything, say so rather than hang.
              if (!controller.isClosed && !listenerGone) {
                controller.addError(
                  const SpeechRecognizerException(
                    'the recognizer isolate exited without a result',
                  ),
                );
                unawaited(controller.close());
              }
              workerGone();
          }
        });
        try {
          await Isolate.spawn<_WorkerStart>(
            _workerMain,
            _WorkerStart(job, fromWorker.sendPort, returnFreedMemory),
            onExit: fromWorker.sendPort,
            debugName: 'speech-recognizer',
          );
        } on Object catch (error) {
          controller.addError(
            SpeechRecognizerException('could not start the recognizer', error),
          );
          await controller.close();
          workerGone();
        }
      },
      onCancel: () {
        // Ask, do not kill: killing the isolate mid-job would skip the native
        // free() and leave the model's memory behind. The worker checks for
        // this between windows and releases before it exits. The returned
        // future is what `StreamSubscription.cancel()` waits on, so the caller
        // learns when the model is really gone. It also runs after a normal
        // finish, where the worker is already on its way out.
        listenerGone = true;
        toWorker?.send(_cancel);
        return exited.future;
      },
    );
    return controller.stream;
  }
}

const String _cancel = 'cancel';

class _WorkerStart {
  const _WorkerStart(this.job, this.replies, this.returnFreedMemory);

  final RecognitionJob job;
  final SendPort replies;
  final bool returnFreedMemory;
}

class _WorkerFailure {
  const _WorkerFailure(this.message, this.detail);

  final String message;
  final String detail;
}

Future<void> _workerMain(_WorkerStart start) async {
  final job = start.job;
  final replies = start.replies;
  final inbox = ReceivePort();
  var cancelled = false;
  inbox.listen((message) {
    if (message == _cancel) cancelled = true;
  });
  replies.send(inbox.sendPort);

  sherpa.OfflineRecognizer? recognizer;
  RandomAccessFile? audio;
  try {
    sherpa.initBindings();

    final loadClock = Stopwatch()..start();
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        feat: sherpa.FeatureConfig(
          sampleRate: job.sampleRateHz,
          featureDim: job.featureDim,
        ),
        model: sherpa.OfflineModelConfig(
          nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: job.modelPath),
          tokens: job.tokensPath,
          numThreads: job.numThreads,
          provider: 'cpu',
          debug: false,
        ),
        decodingMethod: 'greedy_search',
      ),
    );
    loadClock.stop();
    replies.send(RecognitionModelLoaded(loadClock.elapsed));

    audio = File(job.audioPath).openSync();
    for (var index = 0; index < job.windows.length; index++) {
      // Yield so a cancel message sent while the last window was decoding is
      // delivered before the next one starts.
      await Future<void>.delayed(Duration.zero);
      if (cancelled) break;

      final window = job.windows[index];
      final clock = Stopwatch()..start();
      audio.setPositionSync(job.dataOffset + window.start * 2);
      final bytes = audio.readSync(window.length * 2);
      final samples = pcm16leToFloat32(bytes);

      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: job.sampleRateHz);
        recognizer.decode(stream);
        final text = recognizer.getResult(stream).text;
        clock.stop();
        replies.send(
          RecognitionWindowDecoded(
            index: index,
            text: text,
            decodeTime: clock.elapsed,
          ),
        );
      } finally {
        stream.free();
      }
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
    return;
  } finally {
    audio?.closeSync();
    recognizer?.free();
    // onnxruntime's allocations are back in the native allocator now, but the
    // allocator keeps the pages; ask for them to be returned to the OS.
    if (recognizer != null && start.returnFreedMemory) {
      ProcessMemory.releaseFreedNativeMemory();
    }
    inbox.close();
  }
  // Memory figures are filled in on the receiving side, which has been
  // sampling throughout.
  replies.send(const RecognitionReleased());
}
