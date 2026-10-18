import '../model/speaker_embedding.dart';

/// Voice embeddings: one fixed-length fingerprint per stretch of speech.
///
/// Interface only, in plain Dart and `lib/model/` types, like
/// `SpeakerDiarizer` beside it. The engine - today `sherpa_onnx`, in
/// `speaker_embedder_sherpa.dart` - is named in that one file.
///
/// NOTHING IS KEPT WARM. Embedding runs once per note, after the diarizer has
/// exited and before the speech model loads; no two of the three are ever in
/// memory together. An implementation frees its network by the time the
/// stream closes, and [release] exists only to clean up after a job that was
/// abandoned.
///
/// Implementations must not run on the calling isolate: each turn is
/// blocking native work.
abstract class SpeakerEmbedder {
  /// Embeds every turn of [job].
  ///
  /// The stream emits one [EmbedderModelLoaded], then for each turn in order
  /// a [TurnEmbedded] (unless the turn was too short to embed) followed by an
  /// [EmbeddingProgress], then exactly one [EmbeddingFinished], then closes.
  /// Results arrive as they are made, one turn at a time. A failure is
  /// delivered as a [SpeakerEmbedderException] and closes the stream; the
  /// network has been freed by then.
  ///
  /// One job at a time: a second stream listened to while one is running
  /// fails with a [SpeakerEmbedderException].
  ///
  /// Cancelling the subscription stops the job after the turn in hand and
  /// completes once the network is freed.
  Stream<SpeakerEmbeddingEvent> embed(SpeakerEmbeddingJob job);

  /// Frees anything still loaded, stopping a running job first. Completes once
  /// the memory is gone. Nothing loaded is not an error.
  Future<void> release();
}

/// Failure raised by a [SpeakerEmbedder] implementation.
class SpeakerEmbedderException implements Exception {
  const SpeakerEmbedderException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'SpeakerEmbedderException: $message${cause == null ? '' : ' ($cause)'}';
}
