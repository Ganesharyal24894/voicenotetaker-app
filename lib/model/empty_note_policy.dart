/// When a note in which nothing was said is deleted by itself.
///
/// PURE: no clock, no I/O. `services/empty_note_service.dart` gathers the
/// facts about each note and asks; every rule is a unit test.
library;

/// A note's saved transcript, as far as this policy cares.
enum EmptyNoteTranscript {
  /// No transcript file, or one that cannot be read.
  none,

  /// A transcript in which nothing was recognised in any window.
  empty,

  /// A transcript with words in it.
  speech,
}

/// Everything [EmptyNotePolicy.decide] needs to know about one note.
class EmptyNoteFacts {
  const EmptyNoteFacts({
    required this.hasAudio,
    required this.transcript,
    this.failed = false,
    this.keep = false,
    this.writing = false,
    this.capturing = false,
    this.open = false,
    this.transcribing = false,
  });

  /// Whether the WAV is still on disk.
  final bool hasAudio;

  final EmptyNoteTranscript transcript;

  /// A transcription failure is saved beside it.
  final bool failed;

  /// The user marked it Keep.
  final bool keep;

  /// Always-listening is still writing it.
  final bool writing;

  /// A manual recording is in progress.
  final bool capturing;

  /// Shown in the note screen, or playing.
  final bool open;

  /// Being transcribed now.
  final bool transcribing;
}

/// What happens to one note.
enum EmptyNoteVerdict {
  /// Nothing was said: delete the note and everything beside it.
  delete,

  /// Not now - it is written, recorded, open or transcribed. Asked again
  /// later.
  deferWriting,
  deferCapturing,
  deferOpen,
  deferTranscribing,

  /// Never, for this transcript: the user marked it Keep.
  kept,

  /// Never: transcription failed, which is not "nothing was said".
  failed,

  /// Never: there are words in it.
  hasSpeech,

  /// Never: there is no transcript to say it is empty.
  noTranscript;

  /// Try again later rather than forget the note.
  bool get isDeferred =>
      this == deferWriting ||
      this == deferCapturing ||
      this == deferOpen ||
      this == deferTranscribing;
}

/// The rules.
///
///   1. Only a SUCCESSFUL transcription that found nothing in any window
///      deletes a note: a saved failure, no transcript, or any words keep it.
///   2. Never when the user marked it Keep.
///   3. Not while it is written, while a manual recording runs, while it is
///      open in the note screen (or playing), or while it is transcribed -
///      deferred until that ends.
///   4. A deletion already under way finishes: with the audio and the
///      transcript both gone, there is nothing left to keep, only sidecars
///      to clear.
abstract final class EmptyNotePolicy {
  static EmptyNoteVerdict decide(EmptyNoteFacts facts) {
    if (!facts.hasAudio && facts.transcript == EmptyNoteTranscript.none) {
      return EmptyNoteVerdict.delete;
    }
    if (facts.writing) return EmptyNoteVerdict.deferWriting;
    if (facts.capturing) return EmptyNoteVerdict.deferCapturing;
    if (facts.open) return EmptyNoteVerdict.deferOpen;
    if (facts.transcribing) return EmptyNoteVerdict.deferTranscribing;
    if (facts.keep) return EmptyNoteVerdict.kept;
    if (facts.failed) return EmptyNoteVerdict.failed;
    return switch (facts.transcript) {
      EmptyNoteTranscript.none => EmptyNoteVerdict.noTranscript,
      EmptyNoteTranscript.speech => EmptyNoteVerdict.hasSpeech,
      EmptyNoteTranscript.empty => EmptyNoteVerdict.delete,
    };
  }
}
