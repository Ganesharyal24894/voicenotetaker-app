import 'dart:typed_data';

import 'package:voicenotetaker_app/drivers/speaker_embedder.dart';
import 'package:voicenotetaker_app/model/speaker_embedding.dart';

/// A [SpeakerEmbedder] that hands back canned vectors, in the order and shape
/// the real one does: loaded, then a result and a progress per turn, then
/// finished.
class FakeSpeakerEmbedder implements SpeakerEmbedder {
  FakeSpeakerEmbedder({List<String>? log, this.dim = 192})
    : log = log ?? <String>[];

  final List<String> log;
  final int dim;

  /// The vector for a turn, by [EmbeddingTurn.index]. A turn with none gets a
  /// unit vector along axis `index % dim`, so different turns differ.
  Map<int, List<double>> vectors = <int, List<double>>{};

  /// Turns, by index, that produce no embedding - as a too-short one does.
  Set<int> tooShort = <int>{};

  /// Thrown after this many turns, when set.
  Object? failWith;
  int failAfter = 0;

  SpeakerEmbeddingJob? job;
  int calls = 0;
  int releases = 0;

  @override
  Future<void> release() async {
    releases++;
    log.add('embedder.release');
  }

  @override
  Stream<SpeakerEmbeddingEvent> embed(SpeakerEmbeddingJob job) async* {
    this.job = job;
    calls++;
    log.add('embedder.embed');
    yield EmbedderModelLoaded(
      loadTime: const Duration(milliseconds: 200),
      dim: dim,
    );
    final total = job.turns.length;
    for (var done = 0; done < total; done++) {
      if (failWith != null && done == failAfter) {
        throw SpeakerEmbedderException('fake failure', failWith);
      }
      final turn = job.turns[done];
      if (!tooShort.contains(turn.index)) {
        yield TurnEmbedded(
          index: turn.index,
          embedding: _vectorFor(turn.index),
        );
      }
      yield EmbeddingProgress(done: done + 1, total: total);
    }
    log.add('embedder.finished');
    yield const EmbeddingFinished();
  }

  Float32List _vectorFor(int index) {
    final canned = vectors[index];
    if (canned != null) return Float32List.fromList(canned);
    return Float32List(dim)..[index % dim] = 1;
  }
}
