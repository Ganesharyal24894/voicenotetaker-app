# Home: Today and Notes, and summaries from your own AI

Home is two tabs under one header. No AI runs in the app: **Summarize with your
AI** builds a prompt the user pastes into ChatGPT, Claude or Gemini, and
**Paste AI reply** reads the answer back into the Today tab.

## Screens

| Piece | File |
|---|---|
| Shell: header, tabs, recorder sheet | `lib/view/home_view.dart` |
| Today tab + first run (`TodayEmpty`) | `lib/view/home/today_tab.dart` |
| Notes tab | `lib/view/home/notes_tab.dart` |
| Range sheet, copied state, single-note sheet | `lib/view/home/summarize_sheet.dart` |
| Shared bits (tab bar, checkbox, note-time chip, pills, sheet frame) | `lib/view/widgets/home_widgets.dart`, `home_icons.dart` |
| Controller | `lib/controller/summary_controller.dart` |
| Pure models | `lib/model/summary/*`, `lib/model/notes_overview.dart`, `lib/model/home_status.dart` |
| Persistence | `lib/services/summary/day_summary_store.dart` (`<support>/day-summaries.json`) |
| Drivers | `lib/drivers/clipboard_text.dart`, `share_sheet.dart`, `share_sheet_share_plus.dart` |

### Header (both tabs)

Device name; the status line (`HomeStatus.resolve`): *Saving notes* (green,
breathing) while always-listening works, amber *Not saving — recorder
disconnected* / *Not saving — recorder needs an update* / *Muted on the
recorder*, otherwise *Connected* / *Charging* / *Not connected*. Tapping it opens
the **recorder sheet**: the Always-listening switch, Disconnect (connected,
listening off) or Connect a recorder (nothing connected, listening off). Then
battery bars (no percentage, as before), the mic (manual recording; explains
in words when it cannot start) and ⋮ (Diagnostics, for now).

### When Home shows without a recorder (`AppRoot`)

Home is shown when connected, when always-listening is on (unchanged), **or
when there are notes** - unless the link dropped by itself (the
connection-lost screen keeps priority). With no notes the app still starts on
the scan screen. "Connect a recorder" puts the scan screen on top of Home with
a Back control, and connecting returns to Home.

### Today

- Newest summary; card "Your day" (week/month for 7/30 days) with provenance
  `from your AI · 18:30`, `· yesterday 18:30`, `· Mon 18:30`.
- To-dos: open first. A tick settles in place for 700 ms (instant with reduce
  motion) then folds into **Done (n)** (collapsed). Waiting on others;
  Decisions (2, then "Show all n"); everything else (work done, people, ideas,
  open questions, patterns) behind one **More from your AI**.
- A summary made on an earlier day stays, and the footer's left action becomes
  **Summarize today**.
- Note-time chip → `NoteTimeMatcher`: a note in the summary's window that
  contains the time, else the nearest within 3 h (a weekday/date in the time
  picks that day; ties go to the most recent); none → "Couldn't find that note."

### Notes

- **Needs you**, only when something does: notes whose audio the 24 h sweep
  removes within 6 h (only while auto-delete is on) → Review (library); notes
  that couldn't be transcribed → Open (one) / Review (several).
- **Today**: speech time (sum of today's note lengths - always-listening keeps
  only speech), notes. *Conversations* = notes always-listening made on its
  own; nothing on disk tells those from manual recordings yet, so it is
  unknown and hidden (it is also hidden whenever it equals the note count).
- **Notes today**: time, length (`2 min so far` while writing), pill: Writing…,
  Transcribing 40%, Waiting, Couldn't transcribe. Search and All notes open the
  library; a row opens the note.

## Prompts (`PromptBuilder`, pure)

Range prompt per the canvas (PromptReady): caveat about automatic
Hindi/Hinglish transcription, 8 sections (+ `9. Patterns` for 7/30 days), the
reply-headings line (`## Patterns` only for 7/30 days), then `--- Notes ---`
with `[09:14 · 12 min · 2 speakers]` headers (speakers omitted when unknown)
and lines (`Speaker 1: …` when the transcript has speakers, plain text
otherwise). The speaker sentence appears only when some note has speakers.
Multi-day ranges add `--- Mon 14 Sep ---` day lines and ask for `Mon 09:14`.
Ranges are local calendar days: Today, Yesterday, last 7 / 30 days incl. today.

**Long** = more than 8,000 transcript words (the design note) or more than
60,000 characters in the prompt (Devanagari is token-dense, and around there
paste boxes start truncating or turning text into attachments). Then the sheet
offers **Split into N parts**: whole notes balanced across parts (a single
over-long note is cut at line breaks and marked `(continued)`), each part
carrying the full instructions and `Part 1 of 2 … reply only "Got it"` /
`Part 2 of 2 (the last part). Now answer …`.

Single-note prompt per NoteSummarize; `4. Key points.` when there are no
speakers; lines are ~30 s groups of the transcript windows with `[mm:ss]`.

Hook for the note screen: `showNoteSummarizeSheet(context, recording)` finds the
controller through `SummaryScope` (installed by `AppRoot`).

## Reading a reply (`ReplyParser`, pure)

Tolerates `#`/bold/numbered/colon headings, heading aliases (To-do list, Action
items, Decisions made, Waiting on, Ideas and notes to self, Follow-ups …),
`- [ ]`/`[x]`/☐/✅, bullets or numbers, fields split by `|`, ` · `, or
labelled ` — Who: … — Due: …`, trailing `(Priya, 10:58)`, 12-hour times,
markdown tables, wrapped continuation lines, `None`/`N/A`, prose before and
after, CRLF. Unknown `#`/bold headings end the previous section. No usable item
→ "Couldn't read this reply. Copy the whole answer from your AI and try again."

## Stored model (`DaySummary`)

`{source: pasted|automatic, createdAt, range, windowStart, windowEnd,
sections: {summary, todos, workDone, decisions, waiting, people, ideas,
openQuestions, patterns: [{text, who?, due?, noteTime?, done?}]}}`. An in-app AI
later writes the same shape with `source: automatic`. The file keeps the last
30 summaries, the ticked to-do keys, and the last copied range (a paste within
36 h is taken to be about it; otherwise about today).

Ticks are stored as keys (normalised task text + note time) apart from the
summaries, so they survive pasting a newer reply for the same day; a reworded
task is a new task.
