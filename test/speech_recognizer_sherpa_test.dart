import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/speech_recognizer_sherpa.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_service.dart';

/// The REAL engine against the REAL model, on the development machine.
///
/// Skipped unless both are pointed at, because the model is 188 MB and is not
/// in the repository:
///
/// ```sh
/// STT_MODELS_DIR=/path/containing/indicconformer-hi-int8 \
/// STT_WAV=/path/to/a/16k-mono-s16.wav \
///   flutter test test/speech_recognizer_sherpa_test.dart
/// ```
///
/// It proves the Dart configuration loads this export and yields text off the
/// UI isolate. It says nothing about speed on a phone - that is measured on
/// the phone.
void main() {
  final modelsDir = Platform.environment['STT_MODELS_DIR'];
  final wav = Platform.environment['STT_WAV'];
  final skip = modelsDir == null || wav == null
      ? 'set STT_MODELS_DIR and STT_WAV to run the real engine'
      : null;

  test(
    'sherpa_onnx decodes a recording with the NeMo CTC configuration',
    () async {
      const fileStore = IoFileStore();
      final service = TranscriptionService(
        fileStore: fileStore,
        models: SpeechModelStore(
          fileStore: fileStore,
          modelsDirectory: modelsDir!,
        ),
        recognizer: SherpaOnnxSpeechRecognizer(),
      );
      expect((await service.modelStatus()).isReady, isTrue);

      for (final threads in <int>[2, 4]) {
        final result = await service.transcribe(wav!, numThreads: threads);
        // Printed on purpose: this test exists to be read by a person.
        // ignore: avoid_print
        print('$result\n${result.text}');
        expect(result.segments, isNotEmpty);
        expect(result.loadTime, greaterThan(Duration.zero));
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
