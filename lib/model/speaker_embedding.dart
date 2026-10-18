/// Voice embedding data: what one job asks for, and what comes back.
///
/// Pure data, like `diarization.dart`: no logic beyond arithmetic on its own
/// fields, no I/O, no package types. The embedder driver is written against
/// these, so swapping the engine never moves anything here.
library;

import 'dart:typed_data';

import 'transcription.dart';

/// One turn to embed: the pieces of it that are one person's speech.
class EmbeddingTurn {
  EmbeddingTurn({required this.index, required List<SampleRange> pieces})
    : pieces = List<SampleRange>.unmodifiable(pieces);

  /// The caller's own number for the turn, handed back with its embedding.
  final int index;

  /// Sample ranges of the recording, fed to the network one after another
  /// as one stretch of speech.
  final List<SampleRange> pieces;

  int get samples => pieces.fold<int>(0, (sum, p) => sum + p.length);
}

/// Everything an embedder driver needs for one note.
///
/// The audio is described, not carried - the driver reads each piece from
/// [audioPath] itself - so nothing large crosses an isolate boundary.
class SpeakerEmbeddingJob {
  SpeakerEmbeddingJob({
    required this.embeddingPath,
    required this.audioPath,
    required this.dataOffset,
    required this.sampleRateHz,
    required List<EmbeddingTurn> turns,
    this.numThreads = 1,
  }) : turns = List<EmbeddingTurn>.unmodifiable(turns);

  /// The speaker-embedding network: the diarization pack's `campplus.onnx`.
  final String embeddingPath;

  /// A file of 16-bit little-endian MONO PCM starting at [dataOffset].
  final String audioPath;
  final int dataOffset;
  final int sampleRateHz;

  /// Embedded in this order, one result each.
  final List<EmbeddingTurn> turns;

  final int numThreads;
}

/// What an embedder driver reports while a job runs.
sealed class SpeakerEmbeddingEvent {
  const SpeakerEmbeddingEvent();
}

/// The network is in memory and ready.
class EmbedderModelLoaded extends SpeakerEmbeddingEvent {
  const EmbedderModelLoaded({required this.loadTime, required this.dim});

  final Duration loadTime;

  /// Values per embedding.
  final int dim;
}

/// One turn's embedding, as the network gave it - not normalised.
class TurnEmbedded extends SpeakerEmbeddingEvent {
  const TurnEmbedded({required this.index, required this.embedding});

  /// [EmbeddingTurn.index] of the turn it came from.
  final int index;
  final Float32List embedding;
}

/// How many turns have been looked at, including any that gave no embedding
/// because the network needed more audio than they had.
class EmbeddingProgress extends SpeakerEmbeddingEvent {
  const EmbeddingProgress({required this.done, required this.total});

  final int done;
  final int total;

  /// `0.0`-`1.0`; one when there was nothing to do.
  double get fraction {
    if (total <= 0) return 1;
    final value = done / total;
    return value < 0
        ? 0
        : value > 1
        ? 1
        : value;
  }
}

/// The job is over and the network has been freed.
///
/// Always the last event of a job that did not fail, including one that was
/// cancelled part way.
class EmbeddingFinished extends SpeakerEmbeddingEvent {
  const EmbeddingFinished({
    this.rssBeforeLoadKb,
    this.peakRssKb,
    this.rssAfterReleaseKb,
  });

  final int? rssBeforeLoadKb;
  final int? peakRssKb;
  final int? rssAfterReleaseKb;
}
