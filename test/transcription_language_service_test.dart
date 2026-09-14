import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/keep_warm_recognizer.dart';
import 'package:voicenotetaker_app/drivers/speech_recognizer.dart';
import 'package:voicenotetaker_app/model/language_router.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

import 'keep_warm_recognizer_test.dart' show FakeWorker;
import 'library_service_test.dart' show InMemoryFileStore;

const hindi = SpeechModels.indicConformerHindiInt8;
const english = SpeechModels.parakeetTdtEnglishInt8;
const modelsDir = '/support/models';
const wavPath = '/rec/voicenote-20260915-120000.wav';
const second = 16000;

/// IndicConformer's text for each 8 s window of a 20 s note: Hinglish,
/// transliterated English, and a short tail that follows the (Hindi) note.
const hindiTexts = <int, String>{
  0: 'मेरे को ऑडियो नोट बनाना है',
  8 * second: 'इ अः प्ले सोम विडियो एंड अः यू क्नो',
  16 * second: 'दैट शुड',
};

/// Parakeet's text for the same windows.
const englishTexts = <int, String>{
  0: 'Verico audio note banana',
  8 * second: 'is play some video and you know',
  16 * second: 'that should',
};

/// A fake engine that tells the two models apart by path, logs every call,
/// and answers per window START sample, so a job over a subset of windows
/// gets the right text.
class RoutingRecognizer implements SpeechRecognizer {
  final List<String> log = <String>[];
  final List<RecognitionJob> jobs = <RecognitionJob>[];
  Map<int, String> hindiText = hindiTexts;
  Map<int, String> englishText = englishTexts;

  /// When set, the English job fails after its load.
  Object? failEnglish;

  /// When set, the English job holds before its first window.
  Completer<void>? englishGate;

  /// When set, the job with VAD reports these windows.
  List<SampleRange>? planned;

  static String nameOf(RecognitionJob job) =>
      job.architecture == SpeechModelArchitecture.nemoTransducer ? 'en' : 'hi';

  @override
  Future<void> releaseModel() async => log.add('release');

  @override
  Stream<RecognitionEvent> transcribe(RecognitionJob job) async* {
    final name = nameOf(job);
    jobs.add(job);
    var windows = job.windows;
    log.add('$name ${windows.map((w) => w.start ~/ second).join(',')}');
    yield const RecognitionModelLoaded(Duration(milliseconds: 1000));
    if (name == 'en' && failEnglish != null) throw failEnglish!;
    final plan = planned;
    if (job.vad != null && plan != null) {
      windows = plan;
      yield RecognitionWindowsPlanned(plan);
    }
    for (var i = 0; i < windows.length; i++) {
      if (name == 'en' && i == 0 && englishGate != null) {
        await englishGate!.future;
      }
      final texts = name == 'en' ? englishText : hindiText;
      yield RecognitionWindowDecoded(
        index: i,
        text: texts[windows[i].start] ?? '',
        decodeTime: const Duration(milliseconds: 100),
      );
    }
    yield RecognitionReleased(
      rssBeforeLoadKb: name == 'en' ? 200 : 100,
      peakRssKb: name == 'en' ? 450 : 500,
      rssAfterReleaseKb: name == 'en' ? 210 : 110,
      keptLoaded: true,
    );
  }
}

Uint8List wav(Duration length) => WavWriter.wrapPcm(
      Uint8List(length.inMilliseconds * second * 2 ~/ 1000),
      sampleRateHz: second,
      channels: 1,
      bitsPerSample: 16,
    );

void install(InMemoryFileStore store, SpeechModel model, {bool partly = false}) {
  for (final file in model.files) {
    store.put(
      '$modelsDir/${model.directoryName}/${file.name}',
      Uint8List(partly && file == model.modelFile ? 10 : file.sizeBytes),
    );
  }
}

void main() {
  late InMemoryFileStore store;
  late RoutingRecognizer engine;
  late TranscriptionService service;

  TranscriptionService build(SpeechRecognizer recognizer, {bool vad = false}) =>
      TranscriptionService(
        fileStore: store,
        models: SpeechModelStore(fileStore: store, modelsDirectory: modelsDir),
        recognizer: recognizer,
        useVoiceActivitySegmentation: vad,
      );

  setUp(() {
    store = InMemoryFileStore();
    engine = RoutingRecognizer();
    service = build(engine);
    store.put(wavPath, wav(const Duration(seconds: 20)));
  });

  Future<TranscriptionFailure> failureOf(Future<Object?> future) async {
    try {
      await future;
    } on TranscriptionException catch (e) {
      return e.failure;
    }
    fail('expected a TranscriptionException');
  }

  group('auto', () {
    test('Hindi first, then the Hindi model is freed, then only the English '
        'windows are decoded again', () async {
      install(store, hindi);
      install(store, english);
      final progress = <String>[];

      final result = await service.transcribe(
        wavPath,
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(engine.log, <String>['hi 0,8,16', 'release', 'en 8']);
      final englishJob = engine.jobs.last;
      expect(englishJob.modelPath,
          '$modelsDir/${english.directoryName}/encoder.int8.onnx');
      expect(englishJob.decoderPath,
          '$modelsDir/${english.directoryName}/decoder.int8.onnx');
      expect(englishJob.joinerPath,
          '$modelsDir/${english.directoryName}/joiner.int8.onnx');
      expect(englishJob.tokensPath,
          '$modelsDir/${english.directoryName}/tokens.txt');
      expect(englishJob.vad, isNull);
      expect(engine.jobs.first.architecture, SpeechModelArchitecture.nemoCtc);
      expect(englishJob.recognizerConfig == engine.jobs.first.recognizerConfig,
          isFalse);

      expect(result.segments.map((s) => s.text), <String>[
        hindiTexts[0]!,
        englishTexts[8 * second]!,
        hindiTexts[16 * second]!,
      ]);
      expect(result.segments.map((s) => s.languageCode), <String>['hi', 'en', 'hi']);
      expect(result.segments.map((s) => s.modelId),
          <String>[hindi.id, english.id, hindi.id]);
      expect(result.segments[1].start, const Duration(seconds: 8));
      expect(result.segments[1].end, const Duration(seconds: 16));
      expect(result.languageCode, 'auto');
      expect(result.modelId, '${hindi.id}+${english.id}');
      expect(result.englishModelMissing, isFalse);
      expect(result.loadTime, const Duration(milliseconds: 2000));
      expect(result.decodeTime, const Duration(milliseconds: 400));
      expect(result.rssBeforeLoadKb, 100);
      expect(result.peakRssKb, 500);
      expect(result.rssAfterReleaseKb, 210);
      expect(progress,
          <String>['0/3', '1/3', '2/3', '3/3', '3/4', '4/4']);
    });

    test('an all-English note: every spoken window goes to Parakeet', () async {
      install(store, hindi);
      install(store, english);
      engine.hindiText = const <int, String>{
        0: 'थेश शुड बे गुड तो थे चट',
        8 * second: 'दैट शुड बीट',
      };

      final result = await service.transcribe(wavPath);

      // The silent last window is not decoded again.
      expect(engine.log, <String>['hi 0,8,16', 'release', 'en 0,8']);
      expect(result.segments.map((s) => s.languageCode), <String>['en', 'en', 'hi']);
      expect(result.languageCode, 'en');
      expect(result.text, 'Verico audio note banana is play some video and you know');
    });

    test('a Hindi note never loads, or even looks for, the English model',
        () async {
      install(store, hindi);
      engine.hindiText = const <int, String>{
        0: 'मेरे को ऑडियो नोट बनाना है',
        8 * second: 'तो पहले मेरे को फ़ोन चार्ज करना है',
      };

      final result = await service.transcribe(wavPath);

      expect(engine.log, <String>['hi 0,8,16']);
      expect(result.languageCode, 'hi');
      expect(result.modelId, hindi.id);
      expect(result.englishModelMissing, isFalse);
      expect(result.segments.every((s) => s.languageCode == 'hi'), isTrue);
    });

    test('English windows without the English model stay Hindi, and say so',
        () async {
      install(store, hindi);

      final result = await service.transcribe(wavPath);

      expect(engine.log, <String>['hi 0,8,16']);
      expect(result.englishModelMissing, isTrue);
      expect(result.segments.map((s) => s.text), <String>[
        hindiTexts[0]!,
        hindiTexts[8 * second]!,
        hindiTexts[16 * second]!,
      ]);
      expect(result.languageCode, 'hi');
    });

    test('a partly copied English model counts as missing', () async {
      install(store, hindi);
      install(store, english, partly: true);

      final result = await service.transcribe(wavPath);

      expect(engine.log, <String>['hi 0,8,16']);
      expect(result.englishModelMissing, isTrue);
    });

    test('without the Hindi model nothing runs', () async {
      install(store, english);
      expect(await failureOf(service.transcribe(wavPath)),
          TranscriptionFailure.modelMissing);
      expect(engine.log, isEmpty);
    });

    test('the English pass decodes the windows voice activity chose', () async {
      install(store, hindi);
      install(store, english);
      const vad = SpeechModels.sileroVad;
      store.put('$modelsDir/${vad.directoryName}/${vad.file.name}',
          Uint8List(vad.file.sizeBytes));
      engine.planned = const <SampleRange>[
        SampleRange(1 * second, 7 * second),
        SampleRange(9 * second, 15 * second),
      ];
      engine.hindiText = const <int, String>{
        1 * second: 'मेरे को ऑडियो नोट बनाना है',
        9 * second: 'इ अः प्ले सोम विडियो एंड अः यू क्नो',
      };
      engine.englishText = const <int, String>{9 * second: 'play some video'};

      final result = await build(engine, vad: true).transcribe(wavPath);

      expect(engine.log, <String>['hi 0,8,16', 'release', 'en 9']);
      expect(engine.jobs.last.windows,
          const <SampleRange>[SampleRange(9 * second, 15 * second)]);
      expect(result.segments.map((s) => s.start),
          const <Duration>[Duration(seconds: 1), Duration(seconds: 9)]);
      expect(result.segments.last.text, 'play some video');
    });

    test('an English pass that fails fails the transcription', () async {
      install(store, hindi);
      install(store, english);
      engine.failEnglish = StateError('boom');

      expect(await failureOf(service.transcribe(wavPath)),
          TranscriptionFailure.recognizerFailed);
      expect(engine.log, <String>['hi 0,8,16', 'release', 'en 8']);
      expect(service.isBusy, isFalse);
    });

    test('cancel during the English pass stops it', () async {
      install(store, hindi);
      install(store, english);
      engine.englishGate = Completer<void>();

      final job = failureOf(service.transcribe(wavPath));
      await pumpEventQueue();
      expect(engine.log.last, 'en 8');
      final cancel = service.cancel();
      // The fake is a generator: it sees the cancel at its next yield.
      engine.englishGate!.complete();
      await cancel;

      expect(await job, TranscriptionFailure.cancelled);
      expect(service.isBusy, isFalse);
    });
  });

  group('hindi', () {
    test('today\'s behaviour: one Hindi pass, no routing', () async {
      install(store, hindi);
      install(store, english);

      final result =
          await service.transcribe(wavPath, language: TranscriptionLanguage.hindi);

      expect(engine.log, <String>['hi 0,8,16']);
      expect(result.segments[1].text, hindiTexts[8 * second]);
      expect(result.segments.every((s) => s.languageCode == 'hi'), isTrue);
      expect(result.languageCode, 'hi');
      expect(result.englishModelMissing, isFalse);
    });
  });

  group('english', () {
    test('Parakeet for every window; the Hindi model is not needed', () async {
      install(store, english);
      final progress = <String>[];

      final result = await service.transcribe(
        wavPath,
        language: TranscriptionLanguage.english,
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(engine.log, <String>['en 0,8,16']);
      expect(result.segments.map((s) => s.text), englishTexts.values);
      expect(result.segments.every((s) => s.languageCode == 'en'), isTrue);
      expect(result.segments.every((s) => s.modelId == english.id), isTrue);
      expect(result.modelId, english.id);
      expect(result.languageCode, 'en');
      expect(progress, <String>['0/3', '1/3', '2/3', '3/3']);
    });

    test('without the English model it is reported missing', () async {
      install(store, hindi);
      expect(
        await failureOf(
          service.transcribe(wavPath, language: TranscriptionLanguage.english),
        ),
        TranscriptionFailure.modelMissing,
      );
      expect(engine.log, isEmpty);
    });

    test('silence in English mode is labelled English', () async {
      install(store, english);
      engine.englishText = const <int, String>{};
      final result = await service.transcribe(wavPath,
          language: TranscriptionLanguage.english);
      expect(result.text, isEmpty);
      expect(result.languageCode, 'en');
    });
  });

  group('with the keep-warm recognizer', () {
    test('one model in memory at a time: Hindi is freed before English loads, '
        'and English before the next note\'s Hindi', () async {
      install(store, hindi);
      install(store, english);
      final log = <String>[];
      final recognizer = KeepWarmSpeechRecognizer(
        spawn: (config) {
          final name = config.architecture == SpeechModelArchitecture.nemoCtc
              ? 'hi'
              : 'en';
          log.add('spawn $name');
          return _NamedWorker(name, FakeWorker(config, log));
        },
      );
      addTearDown(recognizer.releaseModel);
      final keepWarm = build(recognizer);

      // FakeWorker answers 'w<i>' per window: three one-word windows, too
      // short to judge, so the note stays Hindi and one model is loaded.
      final result = await keepWarm.transcribe(wavPath);
      expect(result.segments.every((s) => s.languageCode == 'hi'), isTrue);
      expect(log, <String>['spawn hi', 'load 2']);

      // English mode on the next note swaps the model.
      await keepWarm.transcribe(wavPath, language: TranscriptionLanguage.english);
      expect(log, <String>['spawn hi', 'load 2', 'free 2', 'spawn en', 'load 2']);
      expect(recognizer.isModelLoaded, isTrue);

      await keepWarm.transcribe(wavPath, language: TranscriptionLanguage.hindi);
      expect(log, <String>[
        'spawn hi', 'load 2', 'free 2', 'spawn en', 'load 2',
        'free 2', 'spawn hi', 'load 2',
      ]);
    });
  });
}

/// A [FakeWorker] under a name, for the log.
class _NamedWorker implements RecognizerWorker {
  _NamedWorker(this.name, this.inner);

  final String name;
  final FakeWorker inner;

  @override
  Stream<RecognitionEvent> run(RecognitionJob job) => inner.run(job);

  @override
  Future<void> shutdown() => inner.shutdown();
}
