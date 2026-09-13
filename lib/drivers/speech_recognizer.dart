import 'dart:typed_data';

import '../model/transcription.dart';

/// Offline speech-to-text.
///
/// Interface only, written in plain Dart and `lib/model/` types. The engine -
/// today `sherpa_onnx`, in `speech_recognizer_sherpa.dart` - is named in exactly
/// one file beside this one, so swapping it means writing one new class here
/// and changing one line in `main.dart`.
///
/// ONE JOB, ONE LOAD. There is deliberately no "load the model" method that a
/// caller could forget to pair with a release: [transcribe] loads the model,
/// decodes every window, releases the model and only then finishes. A 188 MB
/// network sitting in memory between jobs is not free on a phone, and the
/// owner's standing rule is that nothing runs when it is not needed.
///
/// Implementations must not decode on the calling isolate; a model this size
/// would freeze the UI for seconds.
abstract class SpeechRecognizer {
  /// Runs [job] and reports its progress.
  ///
  /// The stream emits exactly one [RecognitionModelLoaded], then one
  /// [RecognitionWindowDecoded] per window in order, then
  /// [RecognitionReleased], then closes. A failure is delivered as a
  /// [SpeechRecognizerException] error and closes the stream; the model has
  /// been released by then.
  ///
  /// Cancelling the subscription stops the job at the next window boundary and
  /// releases the model. It does not interrupt a window already being decoded.
  Stream<RecognitionEvent> transcribe(RecognitionJob job);
}

/// Failure raised by a [SpeechRecognizer] implementation.
class SpeechRecognizerException implements Exception {
  const SpeechRecognizerException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'SpeechRecognizerException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Converts 16-bit little-endian PCM to floats in `[-1, 1)`.
///
/// Every engine this app is likely to use wants float samples, and every
/// recording the app writes is s16le, so the conversion lives beside the
/// interface rather than being re-derived inside each implementation. A
/// trailing odd byte - half a sample - is ignored.
Float32List pcm16leToFloat32(Uint8List bytes) {
  final count = bytes.length ~/ 2;
  final view = ByteData.sublistView(bytes);
  final out = Float32List(count);
  for (var i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
