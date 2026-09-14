# Notes: the list and the note screen

Built to `NoteDetail`, `NoteAudio` and `AllNotes` on the design canvas. They
replace the old recordings library and playback screen.

## All notes (`lib/view/all_notes_view.dart`)

- Rows are **transcript first**: the first paragraph of what was said, or where
  the transcript stands (*Waiting for transcript*, *No speech found*,
  *Couldn't transcribe*, *New note* while it is still being written).
- Meta: `09:14 · 12 min · 2 speakers` (speakers only when there are two or
  more). Badges only when useful: *Transcribing 40%*, *Audio deleted*, and
  *Audio kept* - the last only while audio auto-delete is on.
- Grouped *Today / Yesterday / weekday* (within a week) / `1 Sep` (`2025`
  added for another year).
- Search looks through every transcript and the time label, case-insensitive
  and safe for Devanagari (nukta letters match typed either way); 250 ms
  debounce; *No notes match* when nothing does. Opening the list reads every
  saved transcript once (`AppController.loadTranscripts`).
- No delete on rows: deleting is in the note's menu.

Pure pieces, unit tested: `NoteListItem`, `NoteList.filter/group`,
`NoteLabels` (`lib/view/note_list.dart`), `NoteSearch`
(`lib/model/note_search.dart`).

## A note (`lib/view/note_view.dart`)

- Header: back, day, menu (*Transcribe again* only when there is no transcript
  or it failed; *Delete note* with the shared confirmation).
- Title `09:14 · 12 min`; meta `Today · 2 speakers · 1,450 words`, leaving out
  whatever is unknown.
- Transcript as paragraphs (`TranscriptLayout.paragraphs`): consecutive
  segments joined, split on a speaker change, a pause of 2 s, or 30 s of one
  voice. Each paragraph shows its time, and its speaker when known.
- Every other transcript state fills the body with one line and, where it
  helps, one action: *Transcribing NN%* + bar, *Waiting to transcribe...*,
  *Not transcribed yet.* + Transcribe, *No speech found.*, model missing +
  Try again, *Couldn't transcribe this note.* + Try again.
- Audio row only while auto-delete is on (*Audio deletes in 18 h* + Keep,
  *Audio kept* + Don't keep), or once audio was deleted (*Audio deleted ·
  transcript kept*, and no Audio button).
- Bottom bar: **Summarize with your AI** (a callback; wired in
  `AppRoot._summarizeNote`), Copy (`[00:42] Speaker 2: ...` lines, "Copied"),
  Audio.

### Audio panel (`lib/view/note_audio_panel.dart`)

Opening it plays the note; closing it pauses; leaving the note stops. Compact
waveform, elapsed / remaining, skip 15 / 30, play-pause, speed. Values come
from `AppController.playbackState` only. While playing, the paragraph at the
playhead is lit (`TranscriptLayout.paragraphAt` - in a pause, the one just
heard) and scrolled into view once per paragraph, unless the user scrolled in
the last 4 s. Tapping a paragraph plays from its start.

## Speakers

`TranscriptSegment.speaker` is an optional label (`S1`). It is written to the
transcript JSON only when set, so the format stays version 1: older files load
with no speakers, and older builds ignore the key. Speaker separation itself is
not built; until it is, notes show plain paragraphs and no chips.

Names are a sidecar, `<name>.speakers.json` (`{"version":1,"names":{"S1":
"Priya"}}`), not a transcript field: transcribing again replaces the
transcript file whole, and names keyed by label survive that - labels the new
transcript still uses keep their names. Deleted with the note; untouched by
the retention sweep. `AppController.renameSpeakers / speakerNamesFor /
loadSpeakerNames`.
