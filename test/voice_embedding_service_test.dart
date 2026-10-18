import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/speaker_embedder.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/speaker_embedding.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

import 'fakes/fake_speaker_embedder.dart';
import 'library_service_test.dart' show InMemoryFileStore;
import 'speaker_diarization_service_test.dart'
    show FakeDiarizer, FakeRecognizer;

/// The voice step inside a transcription: after the diarizer, before the
/// speech model, never at the transcript's expense.
void main() {
  const model = SpeechModels.indicConformerHindiInt8;
  const speakers = DiarizationModels.pyannoteCamPlus;
  const modelsDir = '/support/models';
  const wavPath = '/rec/voicenote-20261018-101500.wav';
  const rate = 16000;

  int s(double seconds) => (seconds * rate).round();

  late InMemoryFileStore store;
  late List<String> log;
  late FakeRecognizer engine;
  late FakeDiarizer diarizer;
  late FakeSpeakerEmbedder embedder;

  TranscriptionService service({SpeakerEmbedder? voices}) =>
      TranscriptionService(
        fileStore: store,
        models: SpeechModelStore(fileStore: store, modelsDirectory: modelsDir),
        recognizer: engine,
        diarizer: diarizer,
        embedder: voices,
      );

  setUp(() {
    store = InMemoryFileStore();
    log = <String>[];
    engine = FakeRecognizer(log);
    diarizer = FakeDiarizer(log);
    embedder = FakeSpeakerEmbedder(log: log);
    final pcm = Uint8List(s(40) * 2);
    final view = ByteData.sublistView(pcm);
    for (var i = 0; i < s(40); i++) {
      view.setInt16(i * 2, i.isEven ? 8000 : -8000, Endian.little);
    }
    store.put(
      wavPath,
      WavWriter.wrapPcm(pcm, sampleRateHz: rate, channels: 1, bitsPerSample: 16),
    );
    for (final file in model.files) {
      store.put(
        '$modelsDir/${model.directoryName}/${file.name}',
        Uint8List(file.sizeBytes),
      );
    }
    for (final file in speakers.files) {
      store.put(
        '$modelsDir/${speakers.directoryName}/${file.name}',
        Uint8List(file.sizeBytes),
      );
    }
    diarizer.turns = <SpeakerTurn>[
      SpeakerTurn(start: 0, end: s(20), speaker: 0),
      SpeakerTurn(start: s(20), end: s(40), speaker: 1),
    ];
  });

  test('order: the diarizer is gone before the embedder, and the embedder '
      'before the speech model loads', () async {
    await service(voices: embedder).transcribe(wavPath);

    expect(log, <String>[
      'recognizer.release',
      'diarizer.run',
      'diarizer.release',
      'embedder.embed',
      'embedder.finished',
      'embedder.release',
      'recognizer.transcribe',
    ]);
    expect(
      embedder.job!.embeddingPath,
      '$modelsDir/${speakers.directoryName}/${speakers.embeddingFile.name}',
    );
  });

  test('every turn gets its label and its embedding', () async {
    final result = await service(voices: embedder).transcribe(wavPath);

    final voices = result.voices!;
    expect(voices.model, speakers.id);
    expect(voices.dim, speakers.embeddingDim);
    expect(voices.turns.map((t) => t.label), <String>['S1', 'S2']);
    expect(voices.turns.every((t) => t.embedding != null), isTrue);
    expect(voices.turns.first.startMs, 0);
    expect(voices.turns.last.endMs, 40000);
    // At most eight seconds of each turn are embedded.
    expect(voices.turns.first.seconds, closeTo(8, 0.01));
  });

  test('one voice: the transcript is unlabelled, the voices are not',
      () async {
    diarizer.turns = <SpeakerTurn>[
      SpeakerTurn(start: 0, end: s(40), speaker: 4),
    ];

    final result = await service(voices: embedder).transcribe(wavPath);

    expect(result.segments.every((seg) => seg.speaker == null), isTrue);
    expect(result.voices!.turns.map((t) => t.label).toSet(), <String>{'S1'});
  });

  test('an embedder that fails leaves the transcript exactly the same',
      () async {
    const texts = <int, String>{0: 'नमस्ते', 1: 'हाँ जी'};
    engine.texts = texts;
    final plain = await service().transcribe(wavPath);
    // A fresh engine: the fake treats its second job as an English pass.
    engine = FakeRecognizer(log)..texts = texts;
    embedder.failWith = StateError('boom');

    final result = await service(voices: embedder).transcribe(wavPath);

    expect(result.voices, isNull);
    expect(
      result.segments.map((seg) => (seg.start, seg.end, seg.text, seg.speaker)),
      plain.segments.map((seg) => (seg.start, seg.end, seg.text, seg.speaker)),
    );
    expect(embedder.releases, 1);
    expect(log.last, 'recognizer.transcribe');
  });

  test('a network of another size is a failure, not stored voices', () async {
    final result = await service(
      voices: FakeSpeakerEmbedder(log: log, dim: 256),
    ).transcribe(wavPath);

    expect(result.voices, isNull);
    expect(result.segments, isNotEmpty);
  });

  test('without an embedder there are no voices and nothing else changes',
      () async {
    final result = await service().transcribe(wavPath);

    expect(result.voices, isNull);
    expect(result.segments.map((seg) => seg.speaker), contains('S2'));
  });

  test('nothing heard: no voices, and the embedder never loads', () async {
    diarizer.turns = const <SpeakerTurn>[];

    final result = await service(voices: embedder).transcribe(wavPath);

    expect(result.voices, isNull);
    expect(embedder.calls, 0);
  });

  test('turns too short to embed are kept, with no embedding and no load',
      () async {
    diarizer.turns = <SpeakerTurn>[
      SpeakerTurn(start: 0, end: s(1.2), speaker: 0),
    ];

    final result = await service(voices: embedder).transcribe(wavPath);

    expect(embedder.calls, 0);
    expect(result.voices!.turns.single.embedding, isNull);
  });

  test('cancelling while embedding cancels the job and loads nothing more',
      () async {
    final blocking = _BlockingEmbedder();
    final running = service(voices: blocking);
    final job = running.transcribe(wavPath);
    await blocking.started.future;

    await running.cancel();

    await expectLater(
      job,
      throwsA(
        isA<TranscriptionException>().having(
          (e) => e.failure,
          'failure',
          TranscriptionFailure.cancelled,
        ),
      ),
    );
    expect(blocking.cancelled, isTrue);
    expect(engine.calls, 0);
  });

  test('progress: diarizing and embedding share the speaker step, in order',
      () async {
    diarizer.progress = <double>[0.5, 1];
    final seen = <List<int>>[];

    final result = await service(voices: embedder).transcribe(
      wavPath,
      onProgress: (done, total) => seen.add(<int>[done, total]),
    );

    var last = 0;
    for (final step in seen) {
      expect(step[0], greaterThanOrEqualTo(last));
      last = step[0];
    }
    expect(seen.last, <int>[
      1 + result.segments.length,
      1 + result.segments.length,
    ]);
  });
}

/// Loads, then waits until the subscription is cancelled.
class _BlockingEmbedder implements SpeakerEmbedder {
  final Completer<void> started = Completer<void>();
  bool cancelled = false;

  @override
  Stream<SpeakerEmbeddingEvent> embed(SpeakerEmbeddingJob job) {
    late final StreamController<SpeakerEmbeddingEvent> controller;
    controller = StreamController<SpeakerEmbeddingEvent>(
      onListen: () {
        controller.add(const EmbedderModelLoaded(loadTime: Duration.zero,
            dim: 192));
        started.complete();
      },
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }

  @override
  Future<void> release() async {}
}
