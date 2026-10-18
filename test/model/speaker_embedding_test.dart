import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/speaker_embedder.dart';
import 'package:voicenotetaker_app/model/speaker_embedding.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

import '../fakes/fake_speaker_embedder.dart';

/// The embedding job's data, and the order of events the fake promises the
/// services that will be tested against it.
void main() {
  SpeakerEmbeddingJob job(List<EmbeddingTurn> turns) => SpeakerEmbeddingJob(
    embeddingPath: '/models/diarization/campplus.onnx',
    audioPath: '/rec/a.wav',
    dataOffset: 44,
    sampleRateHz: 16000,
    turns: turns,
  );

  test('a turn counts the samples of all its pieces', () {
    final turn = EmbeddingTurn(
      index: 3,
      pieces: const <SampleRange>[SampleRange(0, 100), SampleRange(200, 250)],
    );
    expect(turn.samples, 150);
  });

  test('progress is a fraction, and nothing to do counts as done', () {
    expect(const EmbeddingProgress(done: 1, total: 4).fraction, 0.25);
    expect(const EmbeddingProgress(done: 9, total: 4).fraction, 1);
    expect(const EmbeddingProgress(done: 0, total: 0).fraction, 1);
  });

  test(
    'the fake reports loaded, a result and progress per turn, finished',
    () async {
      final embedder = FakeSpeakerEmbedder(dim: 4)
        ..vectors = <int, List<double>>{
          7: <double>[0, 0, 1, 0],
        }
        ..tooShort = <int>{8};
      final events = await embedder
          .embed(
            job(<EmbeddingTurn>[
              EmbeddingTurn(index: 7, pieces: const <SampleRange>[]),
              EmbeddingTurn(index: 8, pieces: const <SampleRange>[]),
            ]),
          )
          .toList();
      expect(events.map((e) => e.runtimeType), <Type>[
        EmbedderModelLoaded,
        TurnEmbedded,
        EmbeddingProgress,
        EmbeddingProgress,
        EmbeddingFinished,
      ]);
      expect((events[1] as TurnEmbedded).index, 7);
      expect((events[1] as TurnEmbedded).embedding, <double>[0, 0, 1, 0]);
    },
  );

  test('the fake fails part way the way the real one does', () async {
    final embedder = FakeSpeakerEmbedder(dim: 4)
      ..failWith = 'boom'
      ..failAfter = 1;
    final events = <SpeakerEmbeddingEvent>[];
    await expectLater(
      embedder
          .embed(
            job(<EmbeddingTurn>[
              EmbeddingTurn(index: 0, pieces: const <SampleRange>[]),
              EmbeddingTurn(index: 1, pieces: const <SampleRange>[]),
            ]),
          )
          .forEach(events.add),
      throwsA(isA<SpeakerEmbedderException>()),
    );
    expect(events.whereType<TurnEmbedded>(), hasLength(1));
  });
}
