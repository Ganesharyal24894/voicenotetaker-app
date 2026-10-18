import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/speaker_diarizer_sherpa.dart';
import 'package:voicenotetaker_app/drivers/speaker_embedder_sherpa.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/speaker_embedding.dart';
import 'package:voicenotetaker_app/model/speaker_turns.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/model/voice_match.dart';
import 'package:voicenotetaker_app/model/voice_turns.dart';
import 'package:voicenotetaker_app/model/voice_vector.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/wav_reader.dart';

/// The REAL embedding engine against the REAL CAM++ model, on the development
/// machine.
///
/// Skipped unless both are pointed at, exactly like
/// `speaker_diarizer_sherpa_test.dart`, because the models are not in the
/// repository:
///
/// ```sh
/// STT_MODELS_DIR=/path/containing/diarization \
/// STT_WAV=/path/to/a/16k-mono-s16.wav \
///   tool/flutter_test.sh test/speaker_embedder_sherpa_test.dart
/// ```
///
/// The recording is diarized first, so the halves compared below are one
/// voice by the diarizer's account. Prints the figures so a person can read
/// them; says nothing about speed or memory on a phone.
void main() {
  final modelsDir = Platform.environment['STT_MODELS_DIR'];
  final wav = Platform.environment['STT_WAV'];
  final skip = modelsDir == null || wav == null
      ? 'set STT_MODELS_DIR and STT_WAV to run the real engine'
      : null;

  const model = DiarizationModels.pyannoteCamPlus;
  late SpeechModelStore store;
  late WavHeader header;
  late List<VoiceTurnPick> picks;
  late List<SpeakerTurn> raw;

  SpeakerEmbeddingJob jobOf(List<EmbeddingTurn> turns) => SpeakerEmbeddingJob(
    embeddingPath: store.diarizationPathOf(model, model.embeddingFile),
    audioPath: wav!,
    dataOffset: header.dataOffset,
    sampleRateHz: header.sampleRateHz,
    turns: turns,
    numThreads: 2,
  );

  setUpAll(() async {
    if (skip != null) return;
    const fileStore = IoFileStore();
    store = SpeechModelStore(fileStore: fileStore, modelsDirectory: modelsDir!);
    final status = await store.diarizationStatus(model);
    expect(status.isReady, isTrue, reason: status.problems.join('; '));
    final info = await fileStore.stat(wav!);
    header = WavReader.parse(
      await fileStore.readRange(wav, 0, WavReader.probeLength),
    )!;
    final totalSamples = (info!.sizeBytes - header.dataOffset) ~/ 2;
    final diarizer = SherpaOnnxSpeakerDiarizer();
    final events = await diarizer
        .diarize(
          DiarizationJob(
            model: model,
            segmentationPath: store.diarizationPathOf(
              model,
              model.segmentationFile,
            ),
            embeddingPath: store.diarizationPathOf(model, model.embeddingFile),
            audioPath: wav,
            dataOffset: header.dataOffset,
            sampleRateHz: header.sampleRateHz,
            totalSamples: totalSamples,
            numThreads: 2,
          ),
        )
        .toList();
    raw = events.whereType<DiarizationFinished>().single.turns;
    final cleaned = SpeakerTurns.clean(
      turns: raw,
      totalSamples: totalSamples,
      sampleRateHz: header.sampleRateHz,
    );
    picks = VoiceTurns.select(
      raw: raw,
      cleaned: cleaned,
      sampleRateHz: header.sampleRateHz,
    );
  });

  test(
    'CAM++ gives 192 values per turn, the same twice, and one voice agrees '
    'with itself',
    () async {
      // The speaker with the most raw speech, its segments split into an
      // earlier and a later half: two independent stretches of one voice.
      // Raw segments rather than picked turns because a note with one voice
      // is ONE cleaned turn.
      final minPiece =
          VoiceMatch.minPiece.inMilliseconds * header.sampleRateHz ~/ 1000;
      final totals = <int, int>{};
      for (final segment in raw) {
        totals[segment.speaker] =
            (totals[segment.speaker] ?? 0) + segment.length;
      }
      final speaker = totals.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
      final segments = <SampleRange>[
        for (final segment in raw)
          if (segment.speaker == speaker && segment.length >= minPiece)
            segment.range,
      ];
      expect(
        segments.length,
        greaterThanOrEqualTo(4),
        reason: 'needs a recording where one voice speaks at some length',
      );
      final half = segments.length ~/ 2;
      final turns = <EmbeddingTurn>[
        EmbeddingTurn(index: 0, pieces: segments.take(half).toList()),
        EmbeddingTurn(index: 1, pieces: segments.skip(half).toList()),
        // Each picked turn on its own, to see per-turn figures.
        for (var i = 0; i < picks.length; i++)
          if (picks[i].pieces.isNotEmpty)
            EmbeddingTurn(index: 100 + i, pieces: picks[i].pieces),
      ];

      final embedder = SherpaOnnxSpeakerEmbedder();
      addTearDown(embedder.release);
      final first = await embedder.embed(jobOf(turns)).toList();
      final again = await embedder
          .embed(jobOf(turns.take(2).toList()))
          .toList();

      final loaded = first.whereType<EmbedderModelLoaded>().single;
      expect(loaded.dim, 192);
      final results = {
        for (final e in first.whereType<TurnEmbedded>()) e.index: e.embedding,
      };
      expect(results.values.every((e) => e.length == 192), isTrue);
      expect(first.whereType<EmbeddingProgress>().last.done, turns.length);
      expect(first.last, isA<EmbeddingFinished>());

      final repeat = {
        for (final e in again.whereType<TurnEmbedded>()) e.index: e.embedding,
      };
      expect(VoiceVector.cosine(results[0]!, repeat[0]!), closeTo(1, 1e-5));
      expect(VoiceVector.cosine(results[1]!, repeat[1]!), closeTo(1, 1e-5));

      final halves = VoiceVector.cosine(results[0]!, results[1]!);
      final finished = first.whereType<EmbeddingFinished>().single;
      // Printed on purpose: this test exists to be read by a person.
      // ignore: avoid_print
      print(
        '$wav: ${raw.length} raw segments, '
        '${picks.where((p) => p.pieces.isNotEmpty).length} of '
        '${picks.length} cleaned turns picked, main voice '
        '${segments.length} segments, '
        'halves cosine ${halves.toStringAsFixed(3)}, '
        'load ${loaded.loadTime.inMilliseconds} ms, '
        'rss ${finished.rssBeforeLoadKb} -> peak ${finished.peakRssKb} -> '
        '${finished.rssAfterReleaseKb} kB',
      );
      final mainMean = VoiceVector.weightedMean(<(List<double>, double)>[
        (results[0]!, 1),
        (results[1]!, 1),
      ], 192);
      for (var i = 0; i < picks.length; i++) {
        final e = results[100 + i];
        if (e == null) continue;
        // ignore: avoid_print
        print(
          '  speaker ${picks[i].turn.speaker} '
          '${(picks[i].turn.start / header.sampleRateHz).toStringAsFixed(1)}s '
          '${(picks[i].samples / header.sampleRateHz).toStringAsFixed(1)}s '
          'speech, cosine to main voice '
          '${VoiceVector.cosine(e, mainMean).toStringAsFixed(3)}',
        );
      }
      expect(halves, greaterThan(0.5));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a cancelled job stops after the turn in hand and leaves the embedder '
    'free for the next',
    () async {
      final turns = <EmbeddingTurn>[
        for (var i = 0; i < raw.length; i++)
          EmbeddingTurn(index: i, pieces: <SampleRange>[raw[i].range]),
      ];
      expect(turns.length, greaterThanOrEqualTo(3));
      final embedder = SherpaOnnxSpeakerEmbedder();
      addTearDown(embedder.release);

      final seen = <SpeakerEmbeddingEvent>[];
      final firstTurn = Completer<void>();
      final subscription = embedder.embed(jobOf(turns)).listen((event) {
        seen.add(event);
        if (event is TurnEmbedded && !firstTurn.isCompleted) {
          firstTurn.complete();
        }
      });
      await firstTurn.future;
      await subscription.cancel();
      expect(seen.whereType<TurnEmbedded>().length, lessThan(turns.length));

      final next = await embedder.embed(jobOf(turns.take(1).toList())).toList();
      expect(next.whereType<TurnEmbedded>(), hasLength(1));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
