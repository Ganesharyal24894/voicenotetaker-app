import 'dart:typed_data';

import '../model/transcription.dart';

/// Offline speech-to-text.
///
/// Interface only, written in plain Dart and `lib/model/` types. The engine -
/// today `sherpa_onnx`, in `speech_recognizer_sherpa.dart` - is named in exactly
/// one file beside this one, so swapping it means writing one new class here
/// and changing one line in `main.dart`.
///
/// ONE MODEL, KEPT ONLY WHILE THERE IS WORK. Loading the model costs 1.2-4.9 s
/// on the owner's phone - more than decoding a short note - so a queue of notes
/// must not pay it per note. An implementation may keep the model loaded after
/// a job so the next one reuses it, but it must free it by itself once no job
/// has arrived for a short idle timeout, and at once on [releaseModel]. There
/// is still no "load" call a caller could forget to pair: [transcribe] loads
/// when needed, and the idle timeout is what releases in the end. A 188 MB
/// network sitting in memory with nothing to do is not free on a phone, and
/// the owner's standing rule is that nothing runs when it is not needed.
///
/// Implementations must not decode on the calling isolate; a model this size
/// would freeze the UI for seconds.
abstract class SpeechRecognizer {
  /// Runs [job] and reports its progress.
  ///
  /// The stream emits exactly one [RecognitionModelLoaded], then - only when
  /// the job asked for voice-activity segmentation and it ran - one
  /// [RecognitionWindowsPlanned], then one [RecognitionWindowDecoded] per
  /// window in order, then [RecognitionReleased], then closes. A failure is
  /// delivered as a [SpeechRecognizerException] error and closes the stream;
  /// the model has been released by then.
  ///
  /// One job at a time: a second stream listened to while one is running
  /// fails with a [SpeechRecognizerException].
  ///
  /// Cancelling the subscription stops the job at the next window boundary;
  /// the returned future completes once it has stopped. It does not interrupt
  /// a window already being decoded, and it does not by itself free a model
  /// the implementation keeps - see [releaseModel].
  Stream<RecognitionEvent> transcribe(RecognitionJob job);

  /// Frees the model now instead of at the idle timeout: stops a job still
  /// running (at its next window boundary), releases the model and completes
  /// once its memory is gone. Nothing loaded is not an error.
  Future<void> releaseModel();
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
