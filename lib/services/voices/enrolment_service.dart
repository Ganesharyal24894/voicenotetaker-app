import 'dart:async';

import '../../drivers/file_store.dart';
import '../../drivers/speaker_diarizer.dart';
import '../../drivers/speaker_embedder.dart';
import '../../model/diarization.dart';
import '../../model/enrolment_check.dart';
import '../../model/speaker_embedding.dart';
import '../../model/transcription.dart';
import '../transcription/speech_model_store.dart';
import '../wav_reader.dart';

/// Checks the owner's guided recording and, when it is good, says what their
/// voice is.
///
/// The same two networks as a note's transcription, one after the other and
/// never together: the diarizer finds who talked when, exits, and only then
/// the embedder loads to embed the main voice in [EnrolmentCheck.chunk]s. The
/// verdict itself is [EnrolmentCheck]'s; this file only runs the engines.
///
/// NEVER THROWS. A recording that cannot be read, or an engine that fails, is
/// [EnrolmentProblem.couldNotCheck] - the screen offers another go either way.
class EnrolmentService {
  EnrolmentService({
    required this._fileStore,
    required this._models,
    required this._diarizer,
    required this._embedder,
    this._model = DiarizationModels.pyannoteCamPlus,
  });

  final FileStore _fileStore;
  final SpeechModelStore _models;
  final SpeakerDiarizer _diarizer;
  final SpeakerEmbedder _embedder;
  final DiarizationModel _model;

  /// Whether the speaker pack is installed; without it nothing can be
  /// checked, and the screen offers the download instead of a recording.
  Future<bool> modelsReady() async =>
      (await _models.diarizationStatus(_model)).isReady;

  /// The verdict on the WAV at [path]. [linkLost] is the recorder dropping
  /// part way, which decides it before anything is loaded. [onProgress] gets
  /// `0.0`-`1.0`.
  Future<EnrolmentVerdict> check(
    String path, {
    bool linkLost = false,
    void Function(double fraction)? onProgress,
  }) async {
    if (linkLost) {
      return const EnrolmentVerdict.retry(EnrolmentProblem.linkLost);
    }
    try {
      if (!await modelsReady()) {
        return const EnrolmentVerdict.retry(EnrolmentProblem.couldNotCheck);
      }
      final header = await _header(path);
      if (header == null) {
        return const EnrolmentVerdict.retry(EnrolmentProblem.couldNotCheck);
      }
      final rate = header.sampleRateHz;
      final List<SpeakerTurn> raw;
      try {
        raw = await _diarize(path, header, onProgress);
      } finally {
        // Gone before the embedder loads: never two networks at once. The
        // driver frees its own before the stream closes; this is for a job
        // that ended badly.
        await _diarizer.release();
      }
      onProgress?.call(0.6);
      final early = EnrolmentCheck.screen(raw: raw, sampleRateHz: rate);
      final chunks = early == null
          ? EnrolmentCheck.chunks(raw: raw, sampleRateHz: rate)
          : const <List<SampleRange>>[];
      var embedded = const <(List<double>, double)>[];
      if (chunks.isNotEmpty) {
        try {
          embedded = await _embed(path, header, chunks, onProgress);
        } finally {
          await _embedder.release();
        }
      }
      onProgress?.call(1);
      return EnrolmentCheck.verdict(
        raw: raw,
        sampleRateHz: rate,
        embedded: embedded,
      );
    } on Object {
      return const EnrolmentVerdict.retry(EnrolmentProblem.couldNotCheck);
    }
  }

  /// The recording's header, when it is the 16-bit mono PCM the networks
  /// take at their one rate; null otherwise.
  Future<WavHeader?> _header(String path) async {
    final info = await _fileStore.stat(path);
    if (info == null) return null;
    final header = WavReader.parse(
      await _fileStore.readRange(path, 0, WavReader.probeLength),
    );
    if (header == null ||
        header.audioFormat != 1 ||
        header.channels != 1 ||
        header.bitsPerSample != 16 ||
        header.sampleRateHz != _model.sampleRateHz) {
      return null;
    }
    return header;
  }

  Future<List<SpeakerTurn>> _diarize(
    String path,
    WavHeader header,
    void Function(double fraction)? onProgress,
  ) async {
    final info = await _fileStore.stat(path);
    final onDisk = (info?.sizeBytes ?? 0) - header.dataOffset;
    final bytes = onDisk < header.dataLength ? onDisk : header.dataLength;
    final job = DiarizationJob(
      model: _model,
      segmentationPath: _models.diarizationPathOf(
        _model,
        _model.segmentationFile,
      ),
      embeddingPath: _models.diarizationPathOf(_model, _model.embeddingFile),
      audioPath: path,
      dataOffset: header.dataOffset,
      sampleRateHz: header.sampleRateHz,
      totalSamples: bytes <= 0 ? 0 : bytes ~/ 2,
    );
    await for (final event in _diarizer.diarize(job)) {
      switch (event) {
        case DiarizationModelsLoaded():
          break;
        case DiarizationProgress():
          onProgress?.call(event.fraction * 0.6);
        case DiarizationFinished():
          return event.turns;
      }
    }
    throw const SpeakerDiarizerException('finished without a result');
  }

  Future<List<(List<double>, double)>> _embed(
    String path,
    WavHeader header,
    List<List<SampleRange>> chunks,
    void Function(double fraction)? onProgress,
  ) async {
    final rate = header.sampleRateHz;
    final job = SpeakerEmbeddingJob(
      embeddingPath: _models.diarizationPathOf(_model, _model.embeddingFile),
      audioPath: path,
      dataOffset: header.dataOffset,
      sampleRateHz: rate,
      turns: <EmbeddingTurn>[
        for (var i = 0; i < chunks.length; i++)
          EmbeddingTurn(index: i, pieces: chunks[i]),
      ],
    );
    final out = <(List<double>, double)>[];
    await for (final event in _embedder.embed(job)) {
      switch (event) {
        case EmbedderModelLoaded():
          if (event.dim != _model.embeddingDim) {
            throw SpeakerEmbedderException('unexpected size ${event.dim}');
          }
        case TurnEmbedded():
          final seconds = job.turns[event.index].samples / rate;
          out.add((event.embedding, seconds));
        case EmbeddingProgress():
          onProgress?.call(0.6 + event.fraction * 0.4);
        case EmbeddingFinished():
          return out;
      }
    }
    throw const SpeakerEmbedderException('finished without saying so');
  }
}
