import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/language_router.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_settings_store.dart';

import 'library_service_test.dart' show InMemoryFileStore;

/// Language routing added fields to the saved transcript without a version
/// bump: both directions must still read.
void main() {
  group('transcript format v1 with languages', () {
    final created = DateTime.utc(2026, 9, 15, 3);

    test('a transcript from before routing still loads, as Hindi', () {
      final old = <String, Object?>{
        'version': 1,
        'language': 'hi',
        'model': 'indicconformer-hi-int8',
        'createdAt': created.toIso8601String(),
        'audioMs': 8000,
        'segments': <Object?>[
          <String, Object?>{'startMs': 0, 'endMs': 8000, 'text': 'ठीक है'},
        ],
      };
      final transcript = Transcript.fromJson(old)!;
      expect(transcript.languageCode, 'hi');
      expect(transcript.englishModelMissing, isFalse);
      expect(transcript.segments.single.languageCode, isNull);
      expect(transcript.segments.single.modelId, isNull);
      // Written back unchanged: no new keys appear for a note without them.
      expect(transcript.toJson(), old);
    });

    test('a mixed transcript round-trips its languages and models', () {
      final transcript = Transcript(
        languageCode: 'auto',
        modelId: 'indicconformer-hi-int8+parakeet-tdt-110m-en-int8',
        createdAt: created,
        audioDuration: const Duration(seconds: 16),
        segments: const <TranscriptSegment>[
          TranscriptSegment(
            start: Duration.zero,
            end: Duration(seconds: 8),
            text: 'मेरे को काम करना है',
            languageCode: 'hi',
            modelId: 'indicconformer-hi-int8',
          ),
          TranscriptSegment(
            start: Duration(seconds: 8),
            end: Duration(seconds: 16),
            text: 'details of Linux device driver.',
            languageCode: 'en',
            modelId: 'parakeet-tdt-110m-en-int8',
            speaker: 'S1',
          ),
        ],
      );
      final json = jsonDecode(jsonEncode(transcript.toJson()));
      expect((json as Map)['version'], 1);
      final back = Transcript.fromJson(json)!;
      expect(back.languageCode, 'auto');
      expect(back.modelId, transcript.modelId);
      expect(back.segments.map((s) => s.languageCode), <String>['hi', 'en']);
      expect(back.segments.map((s) => s.modelId),
          <String>['indicconformer-hi-int8', 'parakeet-tdt-110m-en-int8']);
      expect(back.segments.last.speaker, 'S1');
      expect(back.text, 'मेरे को काम करना है details of Linux device driver.');
      expect(back.englishModelMissing, isFalse);
      expect((json['segments'] as List).first, contains('lang'));
    });

    test('englishModelMissing is written only when true, and read back', () {
      final transcript = Transcript(
        languageCode: 'hi',
        modelId: 'indicconformer-hi-int8',
        createdAt: created,
        audioDuration: const Duration(seconds: 8),
        segments: const <TranscriptSegment>[],
        englishModelMissing: true,
      );
      final json = transcript.toJson();
      expect(json['englishModelMissing'], true);
      expect(Transcript.fromJson(json)!.englishModelMissing, isTrue);
    });

    test('language fields of the wrong type cost the field, not the note', () {
      final json = <String, Object?>{
        'version': 1,
        'language': 'en',
        'model': 'parakeet-tdt-110m-en-int8',
        'createdAt': created.toIso8601String(),
        'audioMs': 8000,
        'englishModelMissing': 'yes',
        'segments': <Object?>[
          <String, Object?>{
            'startMs': 0,
            'endMs': 8000,
            'text': 'hello',
            'lang': 7,
            'model': '',
          },
        ],
      };
      final transcript = Transcript.fromJson(json)!;
      expect(transcript.languageCode, 'en');
      expect(transcript.englishModelMissing, isFalse);
      expect(transcript.segments.single.languageCode, isNull);
      expect(transcript.segments.single.modelId, isNull);
    });

    test('fromResult takes the result\'s language and missing-model flag', () {
      const result = TranscriptionResult(
        audioPath: '/a.wav',
        modelId: 'indicconformer-hi-int8',
        numThreads: 2,
        audioDuration: Duration(seconds: 8),
        segments: <TranscriptSegment>[],
        loadTime: Duration.zero,
        decodeTime: Duration.zero,
        wallTime: Duration.zero,
        languageCode: 'en',
        englishModelMissing: true,
      );
      final transcript = Transcript.fromResult(result, createdAt: created);
      expect(transcript.languageCode, 'en');
      expect(transcript.englishModelMissing, isTrue);
      expect(
        Transcript.fromResult(result, languageCode: 'hi', createdAt: created)
            .languageCode,
        'hi',
      );
    });
  });

  group('the English model catalogue entry', () {
    const model = SpeechModels.parakeetTdtEnglishInt8;

    test('is a transducer with four files of exact sizes', () {
      expect(model.architecture, SpeechModelArchitecture.nemoTransducer);
      expect(model.languageCode, 'en');
      expect(model.directoryName, 'parakeet-tdt-110m-en-int8');
      expect(
        <String, int>{for (final f in model.files) f.name: f.sizeBytes},
        <String, int>{
          'encoder.int8.onnx': 131113202,
          'decoder.int8.onnx': 3955863,
          'joiner.int8.onnx': 1411403,
          'tokens.txt': 9953,
        },
      );
      expect(model.totalBytes, 136490421);
      expect(model.sampleRateHz, 16000);
      expect(model.maxWindow, const Duration(seconds: 8));
    });

    test('the Hindi model is still CTC with two files', () {
      const hindi = SpeechModels.indicConformerHindiInt8;
      expect(hindi.architecture, SpeechModelArchitecture.nemoCtc);
      expect(hindi.files, hasLength(2));
      expect(hindi.totalBytes, 196977855 + 73238);
    });

    test('recognizer configs of the two models differ', () {
      const a = RecognizerConfig(
        modelPath: '/m/e',
        tokensPath: '/m/t',
        featureDim: 80,
        numThreads: 2,
        sampleRateHz: 16000,
      );
      const b = RecognizerConfig(
        modelPath: '/m/e',
        tokensPath: '/m/t',
        featureDim: 80,
        numThreads: 2,
        sampleRateHz: 16000,
        architecture: SpeechModelArchitecture.nemoTransducer,
        decoderPath: '/m/d',
        joinerPath: '/m/j',
      );
      expect(a == b, isFalse);
      expect(
        b,
        const RecognizerConfig(
          modelPath: '/m/e',
          tokensPath: '/m/t',
          featureDim: 80,
          numThreads: 2,
          sampleRateHz: 16000,
          architecture: SpeechModelArchitecture.nemoTransducer,
          decoderPath: '/m/d',
          joinerPath: '/m/j',
        ),
      );
      expect(b.hashCode, isNot(a.hashCode));
    });
  });

  group('the language setting store', () {
    late InMemoryFileStore store;
    late TranscriptionSettingsStore settings;

    setUp(() {
      store = InMemoryFileStore();
      settings = TranscriptionSettingsStore(fileStore: store, directory: '/s');
    });

    test('auto when never saved', () async {
      expect(await settings.loadLanguage(), TranscriptionLanguage.auto);
    });

    test('saves and loads every value', () async {
      for (final value in TranscriptionLanguage.values) {
        await settings.saveLanguage(value);
        expect(await settings.loadLanguage(), value);
      }
      expect(settings.path, '/s/transcription-settings.json');
    });

    test('auto for a damaged file, another version or an unknown value',
        () async {
      store.put(settings.path, utf8.encode('{nope'));
      expect(await settings.loadLanguage(), TranscriptionLanguage.auto);
      store.put(settings.path,
          utf8.encode(jsonEncode({'version': 2, 'language': 'english'})));
      expect(await settings.loadLanguage(), TranscriptionLanguage.auto);
      store.put(settings.path,
          utf8.encode(jsonEncode({'version': 1, 'language': 'tamil'})));
      expect(await settings.loadLanguage(), TranscriptionLanguage.auto);
    });
  });
}
