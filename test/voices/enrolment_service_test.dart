import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/enrolment_check.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/voices/enrolment_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

import '../fakes/fake_speaker_embedder.dart';
import '../library_service_test.dart' show InMemoryFileStore;
import '../speaker_diarization_service_test.dart' show FakeDiarizer;

/// The enrolment check with both engines faked: what runs, in what order,
/// and what each kind of recording comes back as.
void main() {
  const pack = DiarizationModels.pyannoteCamPlus;
  const modelsDir = '/support/models';
  const wavPath = '/support/voices/enrol-1.wav';
  const rate = 16000;
  int s(double seconds) => (seconds * rate).round();

  late InMemoryFileStore store;
  late List<String> log;
  late FakeDiarizer diarizer;
  late FakeSpeakerEmbedder embedder;
  late EnrolmentService service;

  void install() {
    for (final file in pack.files) {
      store.put(
        '$modelsDir/${pack.directoryName}/${file.name}',
        Uint8List(file.sizeBytes),
      );
    }
  }

  setUp(() {
    store = InMemoryFileStore();
    log = <String>[];
    diarizer = FakeDiarizer(log);
    embedder = FakeSpeakerEmbedder(log: log)
      ..vectors = <int, List<double>>{
        for (var i = 0; i < 20; i++)
          i: List<double>.generate(192, (d) => d == 0 ? 1.0 : 0.0),
      };
    service = EnrolmentService(
      fileStore: store,
      models: SpeechModelStore(fileStore: store, modelsDirectory: modelsDir),
      diarizer: diarizer,
      embedder: embedder,
    );
    store.put(
      wavPath,
      WavWriter.wrapPcm(
        Uint8List(s(62) * 2),
        sampleRateHz: rate,
        channels: 1,
        bitsPerSample: 16,
      ),
    );
    install();
    diarizer.turns = <SpeakerTurn>[
      SpeakerTurn(start: 0, end: s(30), speaker: 0),
      SpeakerTurn(start: s(31), end: s(61), speaker: 0),
    ];
  });

  test('a minute alone: diarized, then embedded in chunks, then taken',
      () async {
    final seen = <double>[];

    final verdict = await service.check(wavPath, onProgress: seen.add);

    expect(verdict.ok, isTrue);
    expect(verdict.embedding![0], closeTo(1, 1e-6));
    expect(log, <String>[
      'diarizer.run',
      'diarizer.release',
      'embedder.embed',
      'embedder.finished',
      'embedder.release',
    ]);
    expect(embedder.job!.turns, hasLength(10));
    expect(diarizer.job!.totalSamples, s(62));
    expect(seen.last, 1);
  });

  test('too short is said without loading the embedder', () async {
    diarizer.turns = <SpeakerTurn>[
      SpeakerTurn(start: 0, end: s(20), speaker: 0),
    ];

    final verdict = await service.check(wavPath);

    expect(verdict.problem, EnrolmentProblem.tooShort);
    expect(verdict.speech, const Duration(seconds: 20));
    expect(embedder.calls, 0);
  });

  test('two people is not alone', () async {
    diarizer.turns = <SpeakerTurn>[
      SpeakerTurn(start: 0, end: s(30), speaker: 0),
      SpeakerTurn(start: s(30), end: s(61), speaker: 1),
    ];

    expect((await service.check(wavPath)).problem, EnrolmentProblem.notAlone);
  });

  test('a lost link is the verdict, and nothing is loaded', () async {
    final verdict = await service.check(wavPath, linkLost: true);

    expect(verdict.problem, EnrolmentProblem.linkLost);
    expect(diarizer.calls, 0);
  });

  test('no speaker pack: nothing can be checked', () async {
    store.files.removeWhere((path, _) => path.startsWith(modelsDir));

    expect(await service.modelsReady(), isFalse);
    expect(
      (await service.check(wavPath)).problem,
      EnrolmentProblem.couldNotCheck,
    );
  });

  test('an engine failing is "could not check", not an exception', () async {
    embedder.failWith = StateError('boom');

    final verdict = await service.check(wavPath);

    expect(verdict.problem, EnrolmentProblem.couldNotCheck);
    expect(embedder.releases, 1);
  });

  test('a file that is not 16 kHz mono is not checked', () async {
    store.put(
      wavPath,
      WavWriter.wrapPcm(
        Uint8List(s(62) * 2),
        sampleRateHz: 8000,
        channels: 1,
        bitsPerSample: 16,
      ),
    );

    expect(
      (await service.check(wavPath)).problem,
      EnrolmentProblem.couldNotCheck,
    );
    expect(diarizer.calls, 0);
  });
}
