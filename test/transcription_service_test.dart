import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/speech_recognizer.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

import 'library_service_test.dart' show InMemoryFileStore;

/// A fake engine: records the job it was given and answers from a script.
class FakeRecognizer implements SpeechRecognizer {
  RecognitionJob? job;
  int calls = 0;

  /// Text per window index; missing indices decode to ''.
  Map<int, String> texts = <int, String>{};

  /// When set, the stream fails after the load with this error.
  Object? failWith;

  /// When set, the stream closes after this many windows without releasing.
  int? stopAfter;

  /// Holds the job open until completed, for the one-at-a-time test.
  Completer<void>? gate;

  /// When set and the job asks for VAD, the windows the "detector" chose.
  List<SampleRange>? planned;

  int releases = 0;

  @override
  Future<void> releaseModel() async => releases++;

  @override
  Stream<RecognitionEvent> transcribe(RecognitionJob job) async* {
    this.job = job;
    calls++;
    if (gate != null) await gate!.future;
    yield const RecognitionModelLoaded(Duration(milliseconds: 1200));
    if (failWith != null) throw failWith!;
    var windows = job.windows;
    final plan = planned;
    if (job.vad != null && plan != null) {
      windows = plan;
      yield RecognitionWindowsPlanned(plan);
    }
    for (var i = 0; i < windows.length; i++) {
      if (stopAfter != null && i >= stopAfter!) return;
      yield RecognitionWindowDecoded(
        index: i,
        text: texts[i] ?? '',
        decodeTime: const Duration(milliseconds: 100),
      );
    }
    yield const RecognitionReleased(
      rssBeforeLoadKb: 100,
      peakRssKb: 500,
      rssAfterReleaseKb: 120,
    );
  }
}

const model = SpeechModels.indicConformerHindiInt8;
const modelsDir = '/support/models';
const wavPath = '/rec/voicenote-20260914-120000.wav';

Uint8List wav({
  required int samples,
  int rate = 16000,
  int channels = 1,
  int bits = 16,
}) => WavWriter.wrapPcm(
  Uint8List(samples * channels * (bits ~/ 8)),
  sampleRateHz: rate,
  channels: channels,
  bitsPerSample: bits,
);

void installModel(InMemoryFileStore store, {int? modelBytes}) {
  store
    ..put(
      '$modelsDir/${model.directoryName}/${model.modelFile.name}',
      Uint8List(modelBytes ?? model.modelFile.sizeBytes),
    )
    ..put(
      '$modelsDir/${model.directoryName}/${model.tokensFile.name}',
      Uint8List(model.tokensFile.sizeBytes),
    );
}

void main() {
  late InMemoryFileStore store;
  late FakeRecognizer engine;
  late TranscriptionService service;

  setUp(() {
    store = InMemoryFileStore();
    engine = FakeRecognizer();
    service = TranscriptionService(
      fileStore: store,
      models: SpeechModelStore(fileStore: store, modelsDirectory: modelsDir),
      recognizer: engine,
    );
  });

  Future<TranscriptionFailure> failureOf(Future<Object?> future) async {
    try {
      await future;
    } on TranscriptionException catch (e) {
      return e.failure;
    }
    fail('expected a TranscriptionException');
  }

  group('model status', () {
    test('missing when nothing is installed', () async {
      final status = await service.modelStatus();
      expect(status.availability, SpeechModelAvailability.missing);
      expect(status.problems, hasLength(2));
      expect(status.directory, '$modelsDir/${model.directoryName}');
    });

    test('incomplete when a file is truncated', () async {
      installModel(store, modelBytes: 1000);
      final status = await service.modelStatus();
      expect(status.availability, SpeechModelAvailability.incomplete);
      expect(status.problems.single, contains('model.int8.onnx'));
    });

    test('ready when every file is its exact size', () async {
      installModel(store);
      expect((await service.modelStatus()).isReady, isTrue);
    });
  });

  group('transcribe', () {
    test('plans 8 s windows and hands the engine the model config', () async {
      installModel(store);
      store.put(wavPath, wav(samples: 20 * 16000));
      engine.texts = <int, String>{0: 'नमस्ते', 1: ' दोस्त ', 2: 'कहानी'};

      final progress = <String>[];
      final result = await service.transcribe(
        wavPath,
        numThreads: 4,
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      final job = engine.job!;
      expect(
        job.modelPath,
        '$modelsDir/${model.directoryName}/model.int8.onnx',
      );
      expect(job.tokensPath, '$modelsDir/${model.directoryName}/tokens.txt');
      expect(job.featureDim, 80);
      expect(job.sampleRateHz, 16000);
      expect(job.numThreads, 4);
      expect(job.dataOffset, WavWriter.headerLength);
      expect(job.windows, const <SampleRange>[
        SampleRange(0, 128000),
        SampleRange(128000, 256000),
        SampleRange(256000, 320000),
      ]);

      // 0/3 first: the total is known before the model loads, so a progress
      // bar can show a real "0 of 3" rather than spinning.
      expect(progress, <String>['0/3', '1/3', '2/3', '3/3']);
      expect(result.text, 'नमस्ते दोस्त कहानी');
      expect(result.segments[1].start, const Duration(seconds: 8));
      expect(result.segments[2].end, const Duration(seconds: 20));
      expect(result.audioDuration, const Duration(seconds: 20));
      expect(result.loadTime, const Duration(milliseconds: 1200));
      expect(result.decodeTime, const Duration(milliseconds: 300));
      expect(result.realTimeFactor, closeTo(0.015, 1e-9));
      expect(result.peakRssKb, 500);
    });

    test('empty windows are skipped when joining the text', () async {
      installModel(store);
      store.put(wavPath, wav(samples: 17 * 16000));
      engine.texts = <int, String>{0: 'एक', 2: 'तीन'};
      final result = await service.transcribe(wavPath);
      expect(result.text, 'एक तीन');
      expect(result.segments, hasLength(3));
    });

    test(
      'a file shorter than its header claims decodes what is there',
      () async {
        installModel(store);
        final bytes = wav(samples: 16000);
        WavWriter.patchLengths(bytes, 10 * 16000 * 2); // claims 10 s
        store.put(wavPath, bytes);
        final result = await service.transcribe(wavPath);
        expect(engine.job!.windows, const <SampleRange>[SampleRange(0, 16000)]);
        expect(result.audioDuration, const Duration(seconds: 1));
      },
    );

    test('an empty recording never loads the model', () async {
      store.put(wavPath, wav(samples: 0));
      final result = await service.transcribe(wavPath);
      expect(engine.calls, 0);
      expect(result.text, isEmpty);
      expect(result.realTimeFactor, isNull);
    });

    test('bad audio is refused before the model is even checked', () async {
      // No model installed: the audio error must win.
      store.put(wavPath, wav(samples: 16000, rate: 8000));
      expect(
        await failureOf(service.transcribe(wavPath)),
        TranscriptionFailure.unsupportedAudio,
      );
      store.put(wavPath, wav(samples: 16000, channels: 2));
      expect(
        await failureOf(service.transcribe(wavPath)),
        TranscriptionFailure.unsupportedAudio,
      );
      store.put(wavPath, Uint8List.fromList(List<int>.filled(100, 7)));
      expect(
        await failureOf(service.transcribe(wavPath)),
        TranscriptionFailure.unreadableAudio,
      );
      expect(
        await failureOf(service.transcribe('/rec/nope.wav')),
        TranscriptionFailure.unreadableAudio,
      );
      expect(engine.calls, 0);
    });

    test('a missing or partial model is reported, not loaded', () async {
      store.put(wavPath, wav(samples: 16000));
      expect(
        await failureOf(service.transcribe(wavPath)),
        TranscriptionFailure.modelMissing,
      );
      installModel(store, modelBytes: 5);
      expect(
        await failureOf(service.transcribe(wavPath)),
        TranscriptionFailure.modelIncomplete,
      );
      expect(engine.calls, 0);
    });

    test('engine errors become recognizerFailed', () async {
      installModel(store);
      store.put(wavPath, wav(samples: 16000));
      engine.failWith = const SpeechRecognizerException('boom');
      expect(
        await failureOf(service.transcribe(wavPath)),
        TranscriptionFailure.recognizerFailed,
      );
      expect(service.isBusy, isFalse);
    });

    test(
      'an engine that stops early is a failure, not a short transcript',
      () async {
        installModel(store);
        store.put(wavPath, wav(samples: 20 * 16000));
        engine.stopAfter = 1;
        expect(
          await failureOf(service.transcribe(wavPath)),
          TranscriptionFailure.recognizerFailed,
        );
      },
    );

    test('one job at a time: a second request is refused', () async {
      installModel(store);
      store.put(wavPath, wav(samples: 16000));
      engine.gate = Completer<void>();
      final first = service.transcribe(wavPath);
      await Future<void>.delayed(Duration.zero);
      expect(service.isBusy, isTrue);
      expect(
        await failureOf(service.transcribe(wavPath)),
        TranscriptionFailure.busy,
      );
      engine.gate!.complete();
      await first;
      expect(service.isBusy, isFalse);
      expect(engine.calls, 1);
    });

    test('cancel stops a running job and waits for the engine to let go',
        () async {
      installModel(store);
      store.put(wavPath, wav(samples: 40 * 16000));
      final engine = HoldingRecognizer();
      final service = TranscriptionService(
        fileStore: store,
        models: SpeechModelStore(fileStore: store, modelsDirectory: modelsDir),
        recognizer: engine,
      );

      final job = failureOf(service.transcribe(wavPath));
      await engine.started.future;
      expect(service.isBusy, isTrue);

      var cancelReturned = false;
      final cancel = service.cancel().then((_) => cancelReturned = true);
      await Future<void>.delayed(Duration.zero);

      // Asked, but the engine has not released the model yet: still busy, so
      // no second model can be loaded alongside it.
      expect(engine.cancelRequested, isTrue);
      expect(cancelReturned, isFalse);
      expect(service.isBusy, isTrue);

      engine.release.complete();
      await cancel;

      expect(await job, TranscriptionFailure.cancelled);
      expect(service.isBusy, isFalse);
    });

    test('cancel before the engine starts means it never starts', () async {
      installModel(store);
      store.put(wavPath, wav(samples: 16000));

      final job = failureOf(service.transcribe(wavPath));
      await service.cancel();

      expect(await job, TranscriptionFailure.cancelled);
      expect(engine.calls, 0);
      expect(service.isBusy, isFalse);
    });

    test('a job after a cancelled one runs normally', () async {
      installModel(store);
      store.put(wavPath, wav(samples: 16000));
      engine.texts = <int, String>{0: 'हैलो'};

      final first = failureOf(service.transcribe(wavPath));
      await service.cancel();
      await first;

      final result = await service.transcribe(wavPath);
      expect(result.text, 'हैलो');
    });

    test('cancel with nothing running does nothing', () async {
      await service.cancel();
      expect(service.isBusy, isFalse);
    });

    test('rejects a non-positive thread count', () {
      expect(
        () => service.transcribe(wavPath, numThreads: 0),
        throwsArgumentError,
      );
    });
  });

  group('voice-activity segmentation', () {
    const vad = SpeechModels.sileroVad;
    void installVad(InMemoryFileStore store, {int? bytes}) => store.put(
          '$modelsDir/${vad.directoryName}/${vad.file.name}',
          Uint8List(bytes ?? vad.file.sizeBytes),
        );

    TranscriptionService withVad({required bool enabled}) =>
        TranscriptionService(
          fileStore: store,
          models: SpeechModelStore(fileStore: store, modelsDirectory: modelsDir),
          recognizer: engine,
          useVoiceActivitySegmentation: enabled,
        );

    test('off by default: the fixed grid, even with the VAD model installed',
        () async {
      installModel(store);
      installVad(store);
      store.put(wavPath, wav(samples: 20 * 16000));
      await service.transcribe(wavPath);
      expect(service.useVoiceActivitySegmentation, isFalse);
      expect(engine.job!.vad, isNull);
    });

    test('on but the VAD model absent or truncated: the fixed grid', () async {
      installModel(store);
      store.put(wavPath, wav(samples: 20 * 16000));
      final vadService = withVad(enabled: true);
      await vadService.transcribe(wavPath);
      expect(engine.job!.vad, isNull);

      installVad(store, bytes: 10);
      await vadService.transcribe(wavPath);
      expect(engine.job!.vad, isNull);
    });

    test('on and installed: the job asks for it, with the grid as fallback',
        () async {
      installModel(store);
      installVad(store);
      store.put(wavPath, wav(samples: 20 * 16000));
      await withVad(enabled: true).transcribe(wavPath);
      final job = engine.job!;
      expect(job.vad!.modelPath,
          '$modelsDir/${vad.directoryName}/silero_vad.onnx');
      expect(job.vad!.maxWindowSamples, 8 * 16000);
      expect(job.windows, hasLength(3), reason: 'fixed grid still carried');
    });

    test('planned windows replace the grid: progress, text and timings follow',
        () async {
      installModel(store);
      installVad(store);
      store.put(wavPath, wav(samples: 20 * 16000));
      engine
        ..planned = const <SampleRange>[
          SampleRange(16000, 64000),
          SampleRange(200000, 300000),
        ]
        ..texts = <int, String>{0: 'पहला', 1: 'दूसरा'};
      final progress = <String>[];

      final result = await withVad(enabled: true).transcribe(
        wavPath,
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(progress, <String>['0/3', '0/2', '1/2', '2/2']);
      expect(result.text, 'पहला दूसरा');
      expect(result.segments, hasLength(2));
      expect(result.segments[0].start, const Duration(seconds: 1));
      expect(result.segments[1].end, const Duration(milliseconds: 18750));
      expect(result.audioDuration, const Duration(seconds: 20));
    });

    test('no speech found: an empty result, not a failure', () async {
      installModel(store);
      installVad(store);
      store.put(wavPath, wav(samples: 20 * 16000));
      engine.planned = const <SampleRange>[];
      final result = await withVad(enabled: true).transcribe(wavPath);
      expect(result.segments, isEmpty);
      expect(result.text, isEmpty);
    });
  });

  group('releaseEngine', () {
    test('asks the recognizer to free its model', () async {
      await service.releaseEngine();
      expect(engine.releases, 1);
    });
  });
}


/// An engine that loads, then holds until cancelled, and only lets go of the
/// model when the test says so - the way the real isolate finishes the window
/// it is decoding before it frees.
class HoldingRecognizer implements SpeechRecognizer {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool cancelRequested = false;

  @override
  Future<void> releaseModel() async {}

  @override
  Stream<RecognitionEvent> transcribe(RecognitionJob job) {
    late final StreamController<RecognitionEvent> controller;
    controller = StreamController<RecognitionEvent>(
      onListen: () {
        controller.add(const RecognitionModelLoaded(Duration(milliseconds: 1)));
        started.complete();
      },
      onCancel: () {
        cancelRequested = true;
        return release.future;
      },
    );
    return controller.stream;
  }
}
