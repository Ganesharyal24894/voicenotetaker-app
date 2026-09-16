import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/speaker_diarizer.dart';
import 'package:voicenotetaker_app/drivers/speech_recognizer.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/language_router.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

import 'library_service_test.dart' show InMemoryFileStore;

/// Speaker separation through the transcription service, with a fake engine at
/// each seam: what the windows become, what the segments are labelled, what
/// happens in what order, and what a missing model costs.
void main() {
  const model = SpeechModels.indicConformerHindiInt8;
  const english = SpeechModels.parakeetTdtEnglishInt8;
  const speakers = DiarizationModels.pyannoteCamPlus;
  const modelsDir = '/support/models';
  const wavPath = '/rec/voicenote-20260916-120000.wav';
  const rate = 16000;

  int s(double seconds) => (seconds * rate).round();

  /// A WAV of [seconds], loud everywhere except in [quiet], which is where a
  /// split is expected to land.
  Uint8List wav(double seconds, {List<double> quiet = const <double>[]}) {
    final samples = s(seconds);
    final pcm = Uint8List(samples * 2);
    final view = ByteData.sublistView(pcm);
    for (var i = 0; i < samples; i++) {
      final at = i / rate;
      final hushed =
          quiet.any((start) => at >= start && at < start + 0.2);
      view.setInt16(i * 2, hushed ? 1 : (i.isEven ? 8000 : -8000), Endian.little);
    }
    return WavWriter.wrapPcm(pcm, sampleRateHz: rate, channels: 1,
        bitsPerSample: 16);
  }

  void installSpeechModel(InMemoryFileStore store) {
    for (final file in model.files) {
      store.put(
        '$modelsDir/${model.directoryName}/${file.name}',
        Uint8List(file.sizeBytes),
      );
    }
  }

  void installEnglishModel(InMemoryFileStore store) {
    for (final file in english.files) {
      store.put(
        '$modelsDir/${english.directoryName}/${file.name}',
        Uint8List(file.sizeBytes),
      );
    }
  }

  void installSpeakerModels(InMemoryFileStore store, {int? segmentationBytes}) {
    store
      ..put(
        '$modelsDir/${speakers.directoryName}/${speakers.segmentationFile.name}',
        Uint8List(segmentationBytes ?? speakers.segmentationFile.sizeBytes),
      )
      ..put(
        '$modelsDir/${speakers.directoryName}/${speakers.embeddingFile.name}',
        Uint8List(speakers.embeddingFile.sizeBytes),
      );
  }

  late InMemoryFileStore store;
  late List<String> log;
  late FakeRecognizer engine;
  late FakeDiarizer diarizer;

  TranscriptionService serviceWith({SpeakerDiarizer? separator}) =>
      TranscriptionService(
        fileStore: store,
        models: SpeechModelStore(fileStore: store, modelsDirectory: modelsDir),
        recognizer: engine,
        diarizer: separator,
      );

  setUp(() {
    store = InMemoryFileStore();
    log = <String>[];
    engine = FakeRecognizer(log);
    diarizer = FakeDiarizer(log);
    store.put(wavPath, wav(20));
    installSpeechModel(store);
  });

  group('when it does not run', () {
    test('a build with no diarizer transcribes exactly as before', () async {
      final result = await serviceWith().transcribe(wavPath);

      expect(result.segments, hasLength(3));
      expect(result.segments.every((s) => s.speaker == null), isTrue);
      expect(engine.job!.windows.first, SampleRange(0, s(8)));
    });

    test('models not installed: skipped silently, transcript as today',
        () async {
      final result = await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(diarizer.calls, 0);
      expect(result.segments, hasLength(3));
      expect(result.segments.every((s) => s.speaker == null), isTrue);
    });

    test('a half-installed pair is not a failure either', () async {
      installSpeakerModels(store, segmentationBytes: 10);

      final result = await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(diarizer.calls, 0);
      expect(result.segments.every((s) => s.speaker == null), isTrue);
    });

    test('an engine failure costs the labels, not the transcript', () async {
      installSpeakerModels(store);
      diarizer.failWith = const SpeakerDiarizerException('boom');

      final result = await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(result.segments, hasLength(3));
      expect(result.segments.every((s) => s.speaker == null), isTrue);
      expect(diarizer.releases, greaterThan(0));
    });

    test('nothing heard at all falls back to the grid', () async {
      installSpeakerModels(store);
      diarizer.turns = const <SpeakerTurn>[];

      final result = await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(result.segments, hasLength(3));
      expect(result.segments.every((s) => s.speaker == null), isTrue);
    });
  });

  group('when it runs', () {
    setUp(() => installSpeakerModels(store));

    test('the windows follow the turns, and segments carry the label',
        () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(7), speaker: 3),
        SpeakerTurn(start: s(7), end: s(20), speaker: 1),
      ];
      engine.texts = <int, String>{0: 'नमस्ते', 1: 'हाँ जी', 2: 'ठीक है'};

      final result = await serviceWith(separator: diarizer).transcribe(wavPath);

      // Two turns, the second of them too long for one window.
      expect(engine.job!.windows.first, SampleRange(0, s(7)));
      expect(result.segments.map((seg) => seg.speaker).toList(),
          <String>['S1', 'S2', 'S2']);
      // S1 is whoever spoke first, not the engine's own cluster number.
      expect(result.segments.first.speaker, 'S1');
    });

    test('the count the user chose is passed to the engine', () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(10), speaker: 0),
        SpeakerTurn(start: s(10), end: s(20), speaker: 1),
      ];

      await serviceWith(separator: diarizer)
          .transcribe(wavPath, speakerCount: 3);

      expect(diarizer.job!.numClusters, 3);
    });

    test('auto asks for no particular number', () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(20), speaker: 0),
      ];

      await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(diarizer.job!.numClusters, isNull);
    });

    test('one speaker is not labelled at all', () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(9), speaker: 0),
        SpeakerTurn(start: s(9), end: s(20), speaker: 0),
      ];

      final result = await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(result.segments.every((seg) => seg.speaker == null), isTrue);
      // The windows are still the turn's, cut where the speech model can take
      // them.
      expect(result.segments.length, greaterThan(1));
    });

    test('a speaker heard for a moment is not a second speaker', () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(9), speaker: 0),
        SpeakerTurn(start: s(9), end: s(9.5), speaker: 1),
        SpeakerTurn(start: s(9.5), end: s(20), speaker: 0),
      ];

      final result = await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(result.segments.every((seg) => seg.speaker == null), isTrue);
    });

    test('a turn longer than a window is cut at the quietest moment',
        () async {
      store.put(wavPath, wav(20, quiet: <double>[6.5]));
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(20), speaker: 0),
      ];

      await serviceWith(separator: diarizer).transcribe(wavPath);

      // The hush runs 6.5 s - 6.7 s, so the cut is in the middle of it.
      expect(engine.job!.windows.first.end, closeTo(s(6.6), rate ~/ 10));
    });

    test('no audio is dropped: the windows cover the whole recording',
        () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: s(2), end: s(6), speaker: 0),
        SpeakerTurn(start: s(9), end: s(15), speaker: 1),
      ];

      final result = await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(result.segments.first.start, Duration.zero);
      expect(
        result.segments.last.end.inMilliseconds,
        closeTo(20000, 2),
      );
    });

    test('voice-activity segmentation is not run as well', () async {
      store.put(
        '$modelsDir/${SpeechModels.sileroVad.directoryName}/'
        '${SpeechModels.sileroVad.file.name}',
        Uint8List(SpeechModels.sileroVad.file.sizeBytes),
      );
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(10), speaker: 0),
        SpeakerTurn(start: s(10), end: s(20), speaker: 1),
      ];
      final service = TranscriptionService(
        fileStore: store,
        models: SpeechModelStore(fileStore: store, modelsDirectory: modelsDir),
        recognizer: engine,
        diarizer: diarizer,
        useVoiceActivitySegmentation: true,
      );

      await service.transcribe(wavPath);

      expect(engine.job!.vad, isNull);
    });
  });

  group('memory: never two models at once', () {
    setUp(() => installSpeakerModels(store));

    test('the speech model is freed first, and the diarizer before the load',
        () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(10), speaker: 0),
        SpeakerTurn(start: s(10), end: s(20), speaker: 1),
      ];

      await serviceWith(separator: diarizer).transcribe(wavPath);

      expect(log, <String>[
        'recognizer.release',
        'diarizer.run',
        'diarizer.release',
        'recognizer.transcribe',
      ]);
    });

    test('releasing the engine frees the diarizer too', () async {
      await serviceWith(separator: diarizer).releaseEngine();

      expect(diarizer.releases, 1);
    });
  });

  group('progress', () {
    setUp(() => installSpeakerModels(store));

    test('the speaker pass is a tenth of the work, and comes first', () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(10), speaker: 0),
        SpeakerTurn(start: s(10), end: s(20), speaker: 1),
      ];
      diarizer.progress = <double>[0.5, 1];
      final seen = <List<int>>[];

      final result = await serviceWith(separator: diarizer).transcribe(
        wavPath,
        onProgress: (done, total) => seen.add(<int>[done, total]),
      );

      // Three windows on the fixed grid means one step for the speaker pass.
      expect(seen.first, <int>[0, 4]);
      // It never goes backwards, and it ends full.
      var last = 0;
      for (final step in seen) {
        expect(step[0], greaterThanOrEqualTo(last));
        last = step[0];
      }
      expect(seen.last, <int>[1 + result.segments.length,
          1 + result.segments.length]);
    });

    test('without the speaker pass the fractions are what they always were',
        () async {
      final seen = <List<int>>[];

      await serviceWith().transcribe(
        wavPath,
        onProgress: (done, total) => seen.add(<int>[done, total]),
      );

      expect(seen.first, <int>[0, 3]);
      expect(seen.last, <int>[3, 3]);
    });
  });

  group('languages', () {
    setUp(() {
      installSpeakerModels(store);
      installEnglishModel(store);
    });

    test('an English turn is decoded again, and keeps its speaker', () async {
      diarizer.turns = <SpeakerTurn>[
        SpeakerTurn(start: 0, end: s(10), speaker: 0),
        SpeakerTurn(start: s(10), end: s(20), speaker: 1),
      ];
      engine.texts = <int, String>{
        0: 'हाँ जी मैं आ रहा हूँ अभी',
        1: 'कुछ नहीं हुआ है यहाँ पर',
        2: 'दिस इस दी फाइनल रिपोर्ट फॉर टुडे',
      };
      engine.englishTexts = <int, String>{0: 'this is the final report today'};

      final result = await serviceWith(separator: diarizer).transcribe(
        wavPath,
        language: TranscriptionLanguage.auto,
      );

      final routed = result.segments[2];
      expect(routed.languageCode, 'en');
      expect(routed.modelId, english.id);
      expect(routed.text, 'this is the final report today');
      // Whoever was talking is still whoever was talking: the second turn's
      // speaker, not the first's.
      expect(routed.speaker, 'S2');
      expect(result.segments.first.speaker, 'S1');
    });
  });
}

/// A speech engine that answers from a script and writes down when it ran.
class FakeRecognizer implements SpeechRecognizer {
  FakeRecognizer(this.log);

  final List<String> log;
  RecognitionJob? job;
  int calls = 0;

  /// Text per window index for the first pass.
  Map<int, String> texts = <int, String>{};

  /// Text per window index of the SECOND pass, when one runs.
  Map<int, String> englishTexts = <int, String>{};

  int releases = 0;

  @override
  Future<void> releaseModel() async {
    releases++;
    log.add('recognizer.release');
  }

  @override
  Stream<RecognitionEvent> transcribe(RecognitionJob job) async* {
    this.job = job;
    final second = calls > 0;
    calls++;
    log.add('recognizer.transcribe');
    yield const RecognitionModelLoaded(Duration(milliseconds: 900));
    for (var i = 0; i < job.windows.length; i++) {
      yield RecognitionWindowDecoded(
        index: i,
        text: (second ? englishTexts[i] : texts[i]) ?? '',
        decodeTime: const Duration(milliseconds: 80),
      );
    }
    yield const RecognitionReleased(
      rssBeforeLoadKb: 100,
      peakRssKb: 500,
      rssAfterReleaseKb: 120,
    );
  }
}

/// A diarizer that answers from a script and writes down when it ran.
class FakeDiarizer implements SpeakerDiarizer {
  FakeDiarizer(this.log);

  final List<String> log;
  DiarizationJob? job;
  int calls = 0;
  int releases = 0;

  List<SpeakerTurn> turns = const <SpeakerTurn>[];
  List<double> progress = const <double>[1];
  Object? failWith;

  @override
  Future<void> release() async {
    releases++;
    log.add('diarizer.release');
  }

  @override
  Stream<DiarizationEvent> diarize(DiarizationJob job) async* {
    this.job = job;
    calls++;
    log.add('diarizer.run');
    yield const DiarizationModelsLoaded(Duration(milliseconds: 400));
    if (failWith != null) throw failWith!;
    for (final fraction in progress) {
      yield DiarizationProgress(done: (fraction * 100).round(), total: 100);
    }
    yield DiarizationFinished(turns: turns);
  }
}
