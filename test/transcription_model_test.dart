import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

/// The decisions in `model/transcription.dart`, as opposed to the data.
///
/// `transcript_language_test.dart` pins the catalogue entries and
/// `RecognizerConfig`'s equality; `transcription_service_test.dart` drives whole
/// jobs. What neither asks is whether a job describes the model it needs
/// COMPLETELY - which is the question behind whether a loaded recognizer may be
/// reused for the next job, and the one place getting it wrong is silent.
void main() {
  group('what a job says must be loaded', () {
    const transducer = RecognitionJob(
      modelPath: '/models/en/encoder.int8.onnx',
      tokensPath: '/models/en/tokens.txt',
      featureDim: 80,
      numThreads: 2,
      audioPath: '/notes/one.wav',
      dataOffset: 44,
      sampleRateHz: 16000,
      windows: <SampleRange>[SampleRange(0, 16000)],
      architecture: SpeechModelArchitecture.nemoTransducer,
      decoderPath: '/models/en/decoder.int8.onnx',
      joinerPath: '/models/en/joiner.int8.onnx',
    );

    test('everything the engine needs, the transducer files included', () {
      // A config that quietly lost `architecture` would build a CTC recognizer
      // out of a transducer's encoder: not a crash, a transcript of nonsense.
      // Dropping decoderPath or joinerPath is the same bug one file along.
      final config = transducer.recognizerConfig;

      expect(config.modelPath, '/models/en/encoder.int8.onnx');
      expect(config.tokensPath, '/models/en/tokens.txt');
      expect(config.featureDim, 80);
      expect(config.numThreads, 2);
      expect(config.sampleRateHz, 16000);
      expect(config.architecture, SpeechModelArchitecture.nemoTransducer);
      expect(config.decoderPath, '/models/en/decoder.int8.onnx');
      expect(config.joinerPath, '/models/en/joiner.int8.onnx');
    });

    test('two jobs for the same model ask for the same load', () {
      // THE reuse test: this equality is how the keep-warm recognizer decides
      // it can skip a 2 s model load. It has to see through everything about a
      // job that is not the model - the audio, where in the file it starts,
      // which windows, whether VAD was planned.
      const next = RecognitionJob(
        modelPath: '/models/en/encoder.int8.onnx',
        tokensPath: '/models/en/tokens.txt',
        featureDim: 80,
        numThreads: 2,
        audioPath: '/notes/a different recording.wav',
        dataOffset: 78,
        sampleRateHz: 16000,
        windows: <SampleRange>[SampleRange(320, 640), SampleRange(640, 960)],
        architecture: SpeechModelArchitecture.nemoTransducer,
        decoderPath: '/models/en/decoder.int8.onnx',
        joinerPath: '/models/en/joiner.int8.onnx',
      );

      expect(next.recognizerConfig, transducer.recognizerConfig);
      expect(next.recognizerConfig.hashCode, transducer.recognizerConfig.hashCode);
    });

    test('a CTC job leaves the transducer paths empty rather than null', () {
      // Empty strings, because that is what sherpa-onnx's config takes. A null
      // here would be a null crossing into the native binding.
      const ctc = RecognitionJob(
        modelPath: '/models/hi/model.int8.onnx',
        tokensPath: '/models/hi/tokens.txt',
        featureDim: 80,
        numThreads: 2,
        audioPath: '/notes/one.wav',
        dataOffset: 44,
        sampleRateHz: 16000,
        windows: <SampleRange>[SampleRange(0, 16000)],
      );

      expect(ctc.architecture, SpeechModelArchitecture.nemoCtc);
      expect(ctc.recognizerConfig.decoderPath, '');
      expect(ctc.recognizerConfig.joinerPath, '');
      expect(ctc.recognizerConfig, isNot(transducer.recognizerConfig));
    });
  });

  group('a window of samples', () {
    test('its length is the half-open span', () {
      expect(const SampleRange(0, 16000).length, 16000);
      expect(const SampleRange(16000, 16000).length, 0);
      expect(const SampleRange(320, 960).length, 640);
    });

    test('it will not be built backwards or before the start of the file', () {
      // Every window is handed to a file read as an offset and a count. A
      // reversed or negative range would read the wrong part of the recording
      // rather than fail, so the invariant is checked where it is written.
      expect(() => SampleRange(-1, 5), throwsA(isA<AssertionError>()));
      expect(() => SampleRange(5, 4), throwsA(isA<AssertionError>()));
    });
  });

  group('the transcript the user reads', () {
    TranscriptionResult resultOf(List<String> texts) => TranscriptionResult(
          audioPath: '/notes/one.wav',
          modelId: 'indicconformer-hi-int8',
          numThreads: 2,
          audioDuration: const Duration(seconds: 4),
          segments: <TranscriptSegment>[
            for (final (index, text) in texts.indexed)
              TranscriptSegment(
                start: Duration(seconds: index),
                end: Duration(seconds: index + 1),
                text: text,
              ),
          ],
          loadTime: const Duration(seconds: 1),
          decodeTime: const Duration(milliseconds: 30),
          wallTime: const Duration(milliseconds: 1100),
        );

    test('windows are joined with one space', () {
      expect(resultOf(<String>['एक', 'दो', 'तीन']).text, 'एक दो तीन');
    });

    test('a window the recognizer had nothing for leaves no gap', () {
      // A silent window decodes to '' or to whitespace, and there are plenty of
      // them in a recording made by leaving a device on. Joining them in would
      // put runs of spaces through the middle of the note, the summary prompt
      // and every export.
      expect(resultOf(<String>['एक', '', 'तीन']).text, 'एक तीन');
      expect(resultOf(<String>['एक', '   ', 'तीन']).text, 'एक तीन');
      expect(resultOf(<String>['  एक  ', ' दो']).text, 'एक दो');
      expect(resultOf(<String>[]).text, '');
      expect(resultOf(<String>['', ' ']).text, '');
    });
  });
}
