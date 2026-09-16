import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/speaker_diarizer_sherpa.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/speaker_turns.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/wav_reader.dart';

/// The REAL separation engine against the REAL models, on the development
/// machine.
///
/// Skipped unless both are pointed at, because the models are 34 MB and are
/// not in the repository:
///
/// ```sh
/// STT_MODELS_DIR=/path/containing/diarization \
/// STT_WAV=/path/to/a/16k-mono-s16.wav \
///   flutter test test/speaker_diarizer_sherpa_test.dart
/// ```
///
/// `STT_SPEAKERS=3` asks for exactly that many; without it the clustering
/// decides for itself.
///
/// It proves the Dart configuration loads this pair of models and separates
/// speakers off the calling isolate, and prints what it heard so a person can
/// read it. It says nothing about speed on a phone - that is measured on the
/// phone.
void main() {
  final modelsDir = Platform.environment['STT_MODELS_DIR'];
  final wav = Platform.environment['STT_WAV'];
  final speakers = int.tryParse(Platform.environment['STT_SPEAKERS'] ?? '');
  final skip = modelsDir == null || wav == null
      ? 'set STT_MODELS_DIR and STT_WAV to run the real engine'
      : null;

  test(
    'sherpa_onnx separates speakers with the pyannote + CAM++ configuration',
    () async {
      const fileStore = IoFileStore();
      const model = DiarizationModels.pyannoteCamPlus;
      final store = SpeechModelStore(
        fileStore: fileStore,
        modelsDirectory: modelsDir!,
      );
      final status = await store.diarizationStatus(model);
      expect(status.isReady, isTrue, reason: status.problems.join('; '));

      final info = await fileStore.stat(wav!);
      final header = WavReader.parse(
        await fileStore.readRange(wav, 0, WavReader.probeLength),
      )!;
      final totalSamples = (info!.sizeBytes - header.dataOffset) ~/ 2;

      final diarizer = SherpaOnnxSpeakerDiarizer();
      addTearDown(diarizer.release);
      final events = await diarizer
          .diarize(
            DiarizationJob(
              model: model,
              segmentationPath:
                  store.diarizationPathOf(model, model.segmentationFile),
              embeddingPath: store.diarizationPathOf(model, model.embeddingFile),
              audioPath: wav,
              dataOffset: header.dataOffset,
              sampleRateHz: header.sampleRateHz,
              totalSamples: totalSamples,
              numThreads: 2,
              numClusters: speakers,
            ),
          )
          .toList();

      final finished = events.whereType<DiarizationFinished>().single;
      final cleaned = SpeakerTurns.clean(
        turns: finished.turns,
        totalSamples: totalSamples,
        sampleRateHz: header.sampleRateHz,
      );
      final labels = SpeakerTurns.labels(cleaned);
      // Printed on purpose: this test exists to be read by a person.
      // ignore: avoid_print
      print(
        '$wav: ${totalSamples / header.sampleRateHz}s, '
        'asked for ${speakers ?? 'auto'}, '
        '${finished.turns.length} raw turns from '
        '${finished.turns.map((t) => t.speaker).toSet().length} cluster(s), '
        '${cleaned.length} cleaned, '
        '${labels.length} speaker(s), '
        'rss ${finished.rssBeforeLoadKb} -> peak ${finished.peakRssKb} -> '
        '${finished.rssAfterReleaseKb} kB',
      );
      for (final turn in cleaned) {
        // ignore: avoid_print
        print(
          '  ${labels[turn.speaker]} '
          '${(turn.start / header.sampleRateHz).toStringAsFixed(2)}s - '
          '${(turn.end / header.sampleRateHz).toStringAsFixed(2)}s',
        );
      }
      expect(events.whereType<DiarizationModelsLoaded>(), hasLength(1));
      expect(events.whereType<DiarizationProgress>(), isNotEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
