import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/empty_note_policy.dart';

void main() {
  EmptyNoteVerdict decide({
    bool hasAudio = true,
    EmptyNoteTranscript transcript = EmptyNoteTranscript.empty,
    bool failed = false,
    bool keep = false,
    bool writing = false,
    bool capturing = false,
    bool open = false,
    bool transcribing = false,
  }) =>
      EmptyNotePolicy.decide(EmptyNoteFacts(
        hasAudio: hasAudio,
        transcript: transcript,
        failed: failed,
        keep: keep,
        writing: writing,
        capturing: capturing,
        open: open,
        transcribing: transcribing,
      ));

  test('a successful transcript with nothing in it deletes the note', () {
    expect(decide(), EmptyNoteVerdict.delete);
  });

  test('words keep it', () {
    expect(decide(transcript: EmptyNoteTranscript.speech),
        EmptyNoteVerdict.hasSpeech);
  });

  test('no transcript keeps it', () {
    expect(decide(transcript: EmptyNoteTranscript.none),
        EmptyNoteVerdict.noTranscript);
  });

  test('a saved failure keeps it, even beside an empty transcript', () {
    expect(decide(failed: true), EmptyNoteVerdict.failed);
  });

  test('Keep keeps it', () {
    expect(decide(keep: true), EmptyNoteVerdict.kept);
  });

  test('in use: deferred, whatever else is true', () {
    expect(decide(writing: true), EmptyNoteVerdict.deferWriting);
    expect(decide(capturing: true), EmptyNoteVerdict.deferCapturing);
    expect(decide(open: true), EmptyNoteVerdict.deferOpen);
    expect(decide(transcribing: true), EmptyNoteVerdict.deferTranscribing);
    expect(decide(open: true, keep: true), EmptyNoteVerdict.deferOpen);
    for (final verdict in <EmptyNoteVerdict>[
      EmptyNoteVerdict.deferWriting,
      EmptyNoteVerdict.deferCapturing,
      EmptyNoteVerdict.deferOpen,
      EmptyNoteVerdict.deferTranscribing,
    ]) {
      expect(verdict.isDeferred, isTrue);
    }
    expect(EmptyNoteVerdict.delete.isDeferred, isFalse);
    expect(EmptyNoteVerdict.kept.isDeferred, isFalse);
  });

  test('a deletion already under way finishes', () {
    // Killed after the WAV and the transcript went: only sidecars are left.
    expect(
      decide(hasAudio: false, transcript: EmptyNoteTranscript.none, keep: true),
      EmptyNoteVerdict.delete,
    );
    // Killed after the WAV only: the transcript still says empty.
    expect(decide(hasAudio: false), EmptyNoteVerdict.delete);
  });

  test('a note whose audio was removed but has words is kept', () {
    expect(
      decide(hasAudio: false, transcript: EmptyNoteTranscript.speech),
      EmptyNoteVerdict.hasSpeech,
    );
  });
}
