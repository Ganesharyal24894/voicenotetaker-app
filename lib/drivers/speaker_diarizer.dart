import '../model/diarization.dart';

/// Offline speaker separation: who spoke when, in one finished recording.
///
/// Interface only, written in plain Dart and `lib/model/` types, exactly like
/// [SpeechRecognizer] beside it. The engine - today `sherpa_onnx`, in
/// `speaker_diarizer_sherpa.dart` - is named in that one file, so swapping it
/// means writing one new class here and changing one line in `main.dart`.
///
/// NOTHING IS KEPT WARM. Unlike the speech recognizer, a diarizer loads for
/// one job and frees everything at the end of it: diarization runs ONCE per
/// note, before the speech model is loaded, and the two must never be resident
/// together - 34 MB of networks plus the recording as floats, on top of a
/// 188 MB speech model, is what gets an app killed on a mid-range phone. An
/// implementation therefore frees its models by the time the stream closes,
/// and [release] exists only to clean up after a job that was abandoned.
///
/// Implementations must not run on the calling isolate: diarization is
/// seconds of blocking native work.
abstract class SpeakerDiarizer {
  /// Separates the speakers in [job] and reports its progress.
  ///
  /// The stream emits one [DiarizationModelsLoaded], then any number of
  /// [DiarizationProgress], then exactly one [DiarizationFinished], then
  /// closes. A failure is delivered as a [SpeakerDiarizerException] and closes
  /// the stream; the models have been freed by then.
  ///
  /// One job at a time: a second stream listened to while one is running fails
  /// with a [SpeakerDiarizerException].
  ///
  /// Cancelling the subscription asks the job to stop and completes once it
  /// has. A diarization already running inside the engine cannot be
  /// interrupted part way - it is one native call over the whole recording -
  /// so the wait is up to that call's length; nothing more is decoded after
  /// it, and the models are freed.
  Stream<DiarizationEvent> diarize(DiarizationJob job);

  /// Frees anything still loaded, stopping a running job first. Completes once
  /// the memory is gone. Nothing loaded is not an error.
  Future<void> release();
}

/// Failure raised by a [SpeakerDiarizer] implementation.
class SpeakerDiarizerException implements Exception {
  const SpeakerDiarizerException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'SpeakerDiarizerException: $message${cause == null ? '' : ' ($cause)'}';
}
