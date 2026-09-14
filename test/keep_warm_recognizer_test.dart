import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/keep_warm_recognizer.dart';
import 'package:voicenotetaker_app/drivers/speech_recognizer.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

/// A worker that "loads" on its first job and reports the rest as reused, the
/// way the isolate worker does. Every worker ever spawned is kept in [log].
class FakeWorker implements RecognizerWorker {
  FakeWorker(this.config, this.log);

  final RecognizerConfig config;
  final List<String> log;
  bool loaded = false;
  bool shutDown = false;
  int jobs = 0;

  /// When set, the next job holds before its first window until completed.
  Completer<void>? gate;

  /// When set, the next job fails after loading.
  Object? failWith;

  /// Completes the shutdown; null shuts down at once.
  Completer<void>? shutdownGate;

  @override
  Stream<RecognitionEvent> run(RecognitionJob job) {
    late final StreamController<RecognitionEvent> controller;
    var stopped = false;
    final ended = Completer<void>();
    controller = StreamController<RecognitionEvent>(
      onListen: () async {
        jobs++;
        final reused = loaded;
        if (!loaded) log.add('load ${config.numThreads}');
        loaded = true;
        controller.add(RecognitionModelLoaded(
          reused ? Duration.zero : const Duration(seconds: 2),
          reused: reused,
        ));
        final failure = failWith;
        if (failure != null) {
          loaded = false;
          log.add('free ${config.numThreads}');
          controller.addError(SpeechRecognizerException('boom', failure));
          ended.complete();
          unawaited(controller.close());
          return;
        }
        for (var i = 0; i < job.windows.length; i++) {
          final hold = gate;
          if (hold != null && i == 0) await hold.future;
          if (stopped) break;
          controller.add(RecognitionWindowDecoded(
              index: i, text: 'w$i', decodeTime: Duration.zero));
        }
        if (!stopped) {
          controller.add(const RecognitionReleased(
              rssBeforeLoadKb: 1, peakRssKb: 2, rssAfterReleaseKb: 3,
              keptLoaded: true));
        }
        // Stopped first, then closed without waiting: closing waits for the
        // listener's cancel, which waits for [ended].
        if (!ended.isCompleted) ended.complete();
        unawaited(controller.close());
      },
      onCancel: () async {
        stopped = true;
        final hold = gate;
        if (hold != null && !hold.isCompleted) hold.complete();
        await ended.future;
      },
    );
    return controller.stream;
  }

  @override
  Future<void> shutdown() async {
    if (shutDown) return;
    shutDown = true;
    final hold = shutdownGate;
    if (hold != null) await hold.future;
    if (loaded) log.add('free ${config.numThreads}');
    loaded = false;
  }
}

RecognitionJob job({int threads = 2, int windows = 2, String audio = '/a.wav'}) =>
    RecognitionJob(
      modelPath: '/m/model.onnx',
      tokensPath: '/m/tokens.txt',
      featureDim: 80,
      numThreads: threads,
      audioPath: audio,
      dataOffset: 44,
      sampleRateHz: 16000,
      windows: <SampleRange>[
        for (var i = 0; i < windows; i++) SampleRange(i * 10, (i + 1) * 10),
      ],
    );

void main() {
  late List<String> log;
  late List<FakeWorker> workers;

  KeepWarmSpeechRecognizer recognizer({
    Duration idle = const Duration(seconds: 30),
  }) {
    log = <String>[];
    workers = <FakeWorker>[];
    return KeepWarmSpeechRecognizer(
      idleTimeout: idle,
      spawn: (config) {
        final worker = FakeWorker(config, log);
        workers.add(worker);
        return worker;
      },
    );
  }

  Future<List<RecognitionEvent>> runJob(
    SpeechRecognizer engine,
    RecognitionJob j,
  ) =>
      engine.transcribe(j).toList();

  test('consecutive jobs share one load', () async {
    final engine = recognizer();
    final first = await runJob(engine, job(audio: '/1.wav'));
    final second = await runJob(engine, job(audio: '/2.wav'));
    final third = await runJob(engine, job(audio: '/3.wav'));

    expect(log, <String>['load 2']);
    expect(workers, hasLength(1));
    expect(workers.single.jobs, 3);
    expect((first.first as RecognitionModelLoaded).reused, isFalse);
    expect((second.first as RecognitionModelLoaded).reused, isTrue);
    expect((third.first as RecognitionModelLoaded).loadTime, Duration.zero);
    expect((third.last as RecognitionReleased).keptLoaded, isTrue);
    expect(engine.isModelLoaded, isTrue);
    await engine.releaseModel();
  });

  test('the stream contract is unchanged: loaded, windows, released, done',
      () async {
    final engine = recognizer();
    final events = await runJob(engine, job(windows: 3));
    expect(events.map((e) => e.runtimeType.toString()), <String>[
      'RecognitionModelLoaded',
      'RecognitionWindowDecoded',
      'RecognitionWindowDecoded',
      'RecognitionWindowDecoded',
      'RecognitionReleased',
    ]);
    final released = events.last as RecognitionReleased;
    expect(released.peakRssKb, 2);
    await engine.releaseModel();
  });

  test('the model is freed after the idle timeout with no new job', () async {
    final engine = recognizer(idle: const Duration(milliseconds: 40));
    await runJob(engine, job());
    expect(engine.isModelLoaded, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(engine.isModelLoaded, isFalse);
    expect(log, <String>['load 2', 'free 2']);
  });

  test('a job inside the idle window resets it and reuses the model',
      () async {
    final engine = recognizer(idle: const Duration(milliseconds: 80));
    await runJob(engine, job());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await runJob(engine, job());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(engine.isModelLoaded, isTrue, reason: 'timer restarted by job 2');
    expect(log, <String>['load 2']);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(log, <String>['load 2', 'free 2']);
  });

  test('the model is not freed by the timer while a job runs', () async {
    final engine = recognizer(idle: const Duration(milliseconds: 20));
    await runJob(engine, job());
    // Start a long job just inside the window.
    final gate = Completer<void>();
    workers.single.gate = gate;
    final events = runJob(engine, job());
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(engine.isModelLoaded, isTrue);
    expect(log, <String>['load 2']);
    workers.single.gate = null;
    gate.complete();
    await events;
    await engine.releaseModel();
  });

  test('releaseModel frees at once and the next job loads again', () async {
    final engine = recognizer();
    await runJob(engine, job());
    await engine.releaseModel();
    expect(engine.isModelLoaded, isFalse);
    expect(log, <String>['load 2', 'free 2']);

    final again = await runJob(engine, job());
    expect((again.first as RecognitionModelLoaded).reused, isFalse);
    expect(log, <String>['load 2', 'free 2', 'load 2']);
    await engine.releaseModel();
  });

  test('releaseModel with nothing loaded is not an error', () async {
    final engine = recognizer();
    await engine.releaseModel();
    expect(log, isEmpty);
  });

  test('another configuration frees the old model BEFORE loading the new '
      'one - never two in memory', () async {
    final engine = recognizer();
    await runJob(engine, job(threads: 2));
    final hold = Completer<void>();
    workers.single.shutdownGate = hold;

    final second = runJob(engine, job(threads: 4));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(workers, hasLength(1), reason: 'no new worker until the old is gone');

    hold.complete();
    await second;
    expect(log, <String>['load 2', 'free 2', 'load 4']);
    await engine.releaseModel();
  });

  test('zero idle timeout frees after every job and says so', () async {
    final engine = recognizer(idle: Duration.zero);
    final first = await runJob(engine, job());
    final second = await runJob(engine, job());
    expect(log, <String>['load 2', 'free 2', 'load 2', 'free 2']);
    expect((first.last as RecognitionReleased).keptLoaded, isFalse);
    expect((second.first as RecognitionModelLoaded).reused, isFalse);
    expect(engine.isModelLoaded, isFalse);
  });

  test('a failed worker is not reused', () async {
    final engine = recognizer();
    await runJob(engine, job());
    workers.single.failWith = StateError('native');

    await expectLater(runJob(engine, job()),
        throwsA(isA<SpeechRecognizerException>()));
    expect(engine.isModelLoaded, isFalse);

    final next = await runJob(engine, job());
    expect(workers, hasLength(2));
    expect((next.first as RecognitionModelLoaded).reused, isFalse);
    await engine.releaseModel();
  });

  test('cancelling a job stops it and keeps the model for the next', () async {
    final engine = recognizer(idle: const Duration(milliseconds: 40));
    await runJob(engine, job());
    workers.single.gate = Completer<void>();
    final loaded = Completer<void>();
    final subscription = engine.transcribe(job()).listen((event) {
      if (event is RecognitionModelLoaded && !loaded.isCompleted) {
        loaded.complete();
      }
    });
    await loaded.future;

    await subscription.cancel();
    expect(engine.isModelLoaded, isTrue);
    expect(log, <String>['load 2']);

    // ...and the idle timer still applies after a cancel.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.isModelLoaded, isFalse);
  });

  test('releaseModel during a job stops it, frees, and ends its stream',
      () async {
    final engine = recognizer();
    workers = <FakeWorker>[];
    final events = <RecognitionEvent>[];
    Object? error;
    final done = Completer<void>();
    final started = Completer<void>();
    // The gate is set on the worker as soon as it exists.
    final engine2 = KeepWarmSpeechRecognizer(spawn: (config) {
      final worker = FakeWorker(config, log)..gate = Completer<void>();
      workers.add(worker);
      return worker;
    });
    engine2.transcribe(job()).listen(
      (event) {
        events.add(event);
        if (!started.isCompleted) started.complete();
      },
      onError: (Object e) => error = e,
      onDone: done.complete,
    );
    await started.future;

    await engine2.releaseModel();
    await done.future;

    expect(error, isA<SpeechRecognizerException>());
    expect(engine2.isModelLoaded, isFalse);
    expect(log, <String>['load 2', 'free 2']);
    await engine.releaseModel();
  });

  test('a second job while one runs is refused', () async {
    final engine = recognizer();
    await runJob(engine, job());
    final gate = Completer<void>();
    workers.single.gate = gate;
    final first = runJob(engine, job());
    await Future<void>.delayed(Duration.zero);

    await expectLater(runJob(engine, job()),
        throwsA(isA<SpeechRecognizerException>()));

    workers.single.gate = null;
    gate.complete();
    await first;
    expect(workers, hasLength(1));
    await engine.releaseModel();
  });

  test('the default idle timeout is 30 s', () {
    expect(KeepWarmSpeechRecognizer.defaultIdleTimeout,
        const Duration(seconds: 30));
  });
}
