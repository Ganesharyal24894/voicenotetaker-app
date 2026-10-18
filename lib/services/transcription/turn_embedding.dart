import 'dart:async';
import 'dart:typed_data';

import '../../drivers/speaker_embedder.dart';
import '../../model/diarization.dart';
import '../../model/note_voices.dart';
import '../../model/speaker_embedding.dart';
import '../../model/speaker_turns.dart';
import '../../model/voice_turns.dart';
import '../wav_reader.dart';

/// Thrown by [TurnEmbedding.run] after [TurnEmbedding.cancel].
class TurnEmbeddingCancelled implements Exception {
  const TurnEmbeddingCancelled();

  @override
  String toString() => 'TurnEmbeddingCancelled';
}

/// Turns the voices of one note into embeddings: one per cleaned turn.
///
/// The step between speaker separation and speech recognition. It sits apart
/// from `TranscriptionService` because that file is already long, and because
/// everything here - which audio to embed, how the answers come back, what the
/// note's voices look like - is about voices, not words.
///
/// LABELS FOR EVERY NOTE, ONE VOICE INCLUDED. The transcript leaves a
/// one-voice note unlabelled (a "Speaker 1" on every paragraph is noise), but
/// the voices must still say which turn is whose, so a note where only the
/// owner - or only a television - spoke can be matched like any other.
///
/// One job at a time, like the embedder it drives.
class TurnEmbedding {
  TurnEmbedding(
    this._embedder, {
    required this.model,
    required this.embeddingPath,
  });

  final SpeakerEmbedder _embedder;

  /// The pack the voices are embedded with. Its id goes in the result, so the
  /// numbers are only ever compared with numbers from the same network.
  final DiarizationModel model;

  /// Where [model]'s embedding network is installed.
  final String embeddingPath;

  StreamSubscription<SpeakerEmbeddingEvent>? _running;
  Completer<void>? _done;
  bool _cancelled = false;

  /// Embeds the turns of [cleaned] - the speech of each one's own speaker in
  /// [raw], picked by [VoiceTurns.select] - from the 16-bit mono WAV at
  /// [audioPath], and returns the note's voices. [onProgress] gets
  /// `0.0`-`1.0`.
  ///
  /// Throws [TurnEmbeddingCancelled] after [cancel], and whatever the embedder
  /// failed with otherwise; the caller decides what a failure costs.
  Future<NoteVoices> run(
    String audioPath,
    WavHeader header,
    List<SpeakerTurn> raw,
    List<SpeakerTurn> cleaned, {
    int numThreads = 1,
    void Function(double fraction)? onProgress,
  }) async {
    _cancelled = false;
    final sampleRateHz = header.sampleRateHz;
    final picks = VoiceTurns.select(
      raw: raw,
      cleaned: cleaned,
      sampleRateHz: sampleRateHz,
    );
    final turns = <EmbeddingTurn>[
      for (var i = 0; i < picks.length; i++)
        if (picks[i].pieces.isNotEmpty)
          EmbeddingTurn(index: i, pieces: picks[i].pieces),
    ];
    final embeddings = <int, Float32List>{};
    // Nothing long enough to embed: no network is loaded to learn that.
    if (turns.isNotEmpty) {
      await _collect(
        SpeakerEmbeddingJob(
          embeddingPath: embeddingPath,
          audioPath: audioPath,
          dataOffset: header.dataOffset,
          sampleRateHz: sampleRateHz,
          turns: turns,
          numThreads: numThreads,
        ),
        model.embeddingDim,
        embeddings,
        onProgress,
      );
    }
    onProgress?.call(1);

    final labels = SpeakerTurns.labels(cleaned);
    int ms(int samples) => samples * 1000 ~/ sampleRateHz;
    return NoteVoices(
      model: model.id,
      dim: model.embeddingDim,
      turns: <VoiceTurn>[
        for (var i = 0; i < picks.length; i++)
          VoiceTurn(
            startMs: ms(picks[i].turn.start),
            endMs: ms(picks[i].turn.end),
            label: labels[picks[i].turn.speaker]!,
            seconds: picks[i].samples / sampleRateHz,
            embedding: embeddings[i],
          ),
      ],
    );
  }

  /// Stops the running job after the turn in hand. Completes once the
  /// embedder has let go of it; [run] then throws [TurnEmbeddingCancelled].
  Future<void> cancel() async {
    _cancelled = true;
    final running = _running;
    _running = null;
    await running?.cancel();
    final done = _done;
    if (done != null && !done.isCompleted) {
      done.completeError(const TurnEmbeddingCancelled());
    }
  }

  Future<void> _collect(
    SpeakerEmbeddingJob job,
    int dim,
    Map<int, Float32List> into,
    void Function(double fraction)? onProgress,
  ) async {
    if (_cancelled) throw const TurnEmbeddingCancelled();
    final done = Completer<void>();
    _done = done;
    void fail(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    final subscription = _embedder
        .embed(job)
        .listen(
          (event) {
            switch (event) {
              case EmbedderModelLoaded():
                // A network of another size is another network: its numbers
                // would be stored as if they meant what CAM++'s mean.
                if (event.dim != dim) {
                  fail(
                    SpeakerEmbedderException(
                      'expected $dim values per embedding, got ${event.dim}',
                    ),
                  );
                }
              case TurnEmbedded():
                if (event.embedding.length == dim) {
                  into[event.index] = event.embedding;
                }
              case EmbeddingProgress():
                onProgress?.call(event.fraction);
              case EmbeddingFinished():
                if (!done.isCompleted) done.complete();
            }
          },
          onError: fail,
          onDone: () => fail(
            const SpeakerEmbedderException(
              'the embedder finished without saying so',
            ),
          ),
          cancelOnError: true,
        );
    _running = subscription;
    try {
      await done.future;
      if (_cancelled) throw const TurnEmbeddingCancelled();
    } finally {
      if (identical(_running, subscription)) _running = null;
      _done = null;
      await subscription.cancel();
    }
  }
}
