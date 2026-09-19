# Speaking to your assistant: the app's only outbound path

Say **"Instinct, remind me to call the bank at six"** into the recorder. The
note is saved and transcribed offline as always; because the transcript begins
with the wake phrase, the instruction is emailed to the user's AI assistant.

This is the **only** thing this app ever sends anywhere by itself. Everything
else is offline (transcription, diarization) or user-driven (the export zip
goes to the share sheet; the summary prompt goes through the clipboard; the
model download pulls files *in*).

**It is off until the user sets it up.** A fresh install has the switch off and
no sending account, and in that state no code in this feature opens a socket.

## What is sent, when, and to whom

| | |
|---|---|
| **What** | One plain-text email. The body is the transcript **with the wake phrase stripped**, and nothing else - no signature, no note id, no file name, no device name, no other note, and no audio. The subject is the note's time (`Voice note - 18 Sep 2026, 14:32`), deliberately without any of the instruction's words, because a subject line is what shows on a lock screen. No attachments. No HTML part. |
| **When** | Five seconds after the transcript is saved, if the user has not tapped **Undo**. Never during that window, never after an undo, and never twice for the same note. |
| **To whom** | The assistant's own mailbox - `bo1dx6@mail.instinct.com` by default, changeable in Settings. |
| **From** | The user's own Gmail account (`giftinjsr@gmail.com` by default), over SMTP to `smtp.gmail.com:465` with TLS from the first byte. No third party, no API key, no server of ours. |
| **What is never sent** | The audio. The raw transcript. Any other note. Any identifier. Anything at all while the feature is off or no account is set up. |

The assistant replies by email from any sending address, once that address has
been authorised once from the user's chat with it. There is no verification
step on this side beyond the **Send a test email** button in setup.

## The one place it happens

`AssistantOutbox._deliver` in `lib/services/assistant/assistant_outbox.dart` is
the only caller of `EmailSender.send` in the whole app, and
`AssistantMessage.forInstruction` is the only thing that decides what goes in
the body. The setup screen's test email goes through `AssistantOutbox.sendOnce`
for the same reason: one call site, so "here is every byte that leaves the
phone" is something anyone can check in one file.

`lib/drivers/email_sender_mailer.dart` is the only file that opens the socket.

## The pieces

| Piece | File |
|---|---|
| Wake-phrase detector (pure) | `lib/model/assistant/wake_phrase.dart` |
| The message (pure) | `lib/model/assistant/assistant_message.dart` |
| Queue entry, statuses, retry policy (pure) | `lib/model/assistant/assistant_send.dart` |
| Settings (pure) | `lib/model/assistant/assistant_settings.dart` |
| The outbox | `lib/services/assistant/assistant_outbox.dart` |
| Settings file | `lib/services/assistant/assistant_settings_store.dart` |
| Account, in the keystore | `lib/services/assistant/assistant_account_store.dart` |
| Controller (everything the UI touches) | `lib/controller/assistant_controller.dart` |
| SMTP seam / implementation | `lib/drivers/email_sender.dart`, `email_sender_mailer.dart` |
| Keystore seam / implementation | `lib/drivers/secret_store.dart`, `secret_store_secure.dart` |

`AppController` is joined to none of it except one hook: `onTranscriptSaved`,
called in `transcribe()` the moment a transcript lands, wired in `main.dart`.
The recorder knows nothing about instructions.

## The wake phrase

The transcript comes from the on-device models, which have never heard of
"Instinct": IndicConformer writes it in Devanagari and spells it however it
sounded, Parakeet writes it in Latin and often splits or clips it. So the match
is fuzzy, on the **first one to three tokens only**:

* normalise: lower case, punctuation and the danda dropped, Devanagari folded
  to the Latin letters it sounds like (`इंस्टिंक्ट` -> `instinkt`);
* join those tokens, and accept the closest run within **Levenshtein 2** of the
  normalised phrase;
* but only if the candidate also reproduces the phrase's first **60%** of
  characters - five of the eight letters of "instinct".

That last rule is what keeps the app quiet. "Instant coffee" is two edits from
"instinct" and would otherwise fire; its agreement runs out after four letters,
so it does not. Neither does "In six minutes...", "instructions...",
"installing...", or the word in the middle of a note ("I trust my instinct, it
says no"). What does fire: `instinct` / `instinc` / `in stinct` / `instinkt` /
`इंस्टिंक्ट` / `इनस्टिंक्ट` / `इन्स्टिंक्ट`, with or without a comma, in any
case. So does the plural, "Instincts tell me..." - the undo window covers it.

The phrase is configurable, and a phrase shorter than three characters is
refused: it would turn every note into an instruction.

## Undo, retries, and giving up

* **5 seconds** of Undo, on Android with one short vibration when the wake
  phrase is recognised. **On iOS there is no vibration** - an app in the
  background cannot vibrate on its own - so the banner on the next glance at
  the screen is the whole feedback. `AssistantController.canVibrate` says which
  phone this is; the settings screen should say so plainly rather than pretend.
* **Retries** on 10 s, 30 s, 2 m, 5 m, 5 m - six attempts over about 12½
  minutes - for a connection or a "not now" from the server. Then it stops and
  says so, and the user can tap to try again.
* **No retries at all** for a refused password or a refused address: waiting
  cannot change either answer.
* **Offline costs nothing.** With no connection the entry waits and no attempt
  is spent, so a tunnel does not use up the budget the user needs on the other
  side of it. It goes the moment the connection is back, through the same
  `NetworkStatus` the model downloader uses.
* **One note, one send.** The dedupe key is the recording's path. Re-transcribing
  a note, restarting the app, or a second wake phrase in the same note cannot
  produce a second email.
* **It survives being killed.** The queue is one JSON file written on every
  change, so an instruction queued in a pocket is still there afterwards. An
  undo window that expired while the app was dead closes on the next start and
  the instruction goes.

The one thing it cannot promise: a process killed in the milliseconds between
"the server took it" and "the file says sent" leaves an entry that is tried
again, and the assistant may see that instruction twice. Writing "sent" first
would lose instructions instead, which is worse.

## Where things are stored

| What | Where | Why |
|---|---|---|
| Switch, wake phrase, assistant's address | `<support>/assistant-settings.json` | Ordinary settings, beside the app's others. Reads fail **closed**: an unreadable file is "off". |
| The outbox: every queued, sent and failed instruction | `<support>/assistant-outbox.json` | Must survive the app being killed. Holds the instruction text. Capped at 200 finished entries, which is also the dedupe memory. |
| Sending address, app password, host, port, TLS | The **platform keystore** - Keychain on iOS (`first_unlock`, not iCloud-synced), a hardware-backed `AndroidKeyStore` key on Android - under the single key `assistant.smtp.account.v1` | A password does not go in a settings file: the app's directory is readable on a rooted phone and present in a device dump, and `SharedPreferences` is plain XML. One key, one value, one delete. |

The password is **never logged**. `SmtpAccount.toString()` prints neither it nor
the address; `AssistantMessage.toString()` and `AssistantSend.toString()` print
no word of the instruction; the mailer driver deliberately swallows exception
text, because an SMTP exception can carry the conversation and the conversation
carries the password. Nothing in this feature calls `debugPrint`.

**Removing it all:** `AssistantController.forgetEverything()` - off, account
deleted from the keystore, outbox emptied.

## What the screens have to do

The screens are built. They are all in `lib/view/assistant_view.dart`, and
every one of them reads `AssistantController` and nothing else - no store, no
service and no `AppController` field is touched.

| Screen | Where it is | What it is |
|---|---|---|
| The row into it | `settings_view.dart`, foot of Recorder settings | Not set up / On / Off |
| Setup, and the settled state | `AssistantView` | One screen: the form until there is an account, the switch and the history after |
| The Undo banner | `AssistantUndoBanner`, above Home's tab bar | The instruction, a countdown, Undo |
| The same thing with the app closed | `AssistantUndoNotifier` over `drivers/undo_notification.dart`, drawn by `android/.../UndoNotification.kt` | Android only |
| The mark on a note | `AssistantNoteMark`, above the note's title | Sent to Instinct / Couldn't send - Try again |
| The title in the notes list | `note_list.dart`, `quoteAs:` | `titleFor`, so the wake phrase is not the headline |

`main.dart` already builds the controller and hands it to `VoiceNotetakerApp`
as `assistant:`; it is a `ChangeNotifier`, so an
`AnimatedBuilder`/`ListenableBuilder` on it is enough.

**Setup, in Recorder settings.** Nothing but a placeholder until `isLoaded`.
Then:

| The screen shows | It reads | It calls |
|---|---|---|
| The switch | `enabled` | `setEnabled(bool)` |
| "Finish setting this up" | `needsSetup` | - |
| Sending account, or "Add account" | `hasAccount`, `senderAddress` | `saveAccount(address:, password:, host:, port:, useSsl:)` -> false when incomplete; `clearAccount()` |
| The assistant's address | `assistantAddress` | `setAssistantAddress(String)` -> false when it is not an address |
| The wake phrase | `wakePhrase` | `setWakePhrase(String)` -> false when it is too short |
| "This phone buzzes when I hear you" / "iPhone cannot buzz from the background" | `canVibrate` | - |
| Send a test email | `testState`, `testFailure?.message` | `sendTestEmail()` |
| Recent instructions | `recentSends([limit])`, `hasPending` | `retry(noteId)` |
| Remove all of this | - | `forgetEverything()` |

The password field is **write-only**: it goes in through `saveAccount` and
there is deliberately no getter that returns it. Prefill the address fields
with `AssistantController.defaultSenderAddress`,
`defaultAssistantAddress`, `defaultWakePhrase`, `defaultSmtpHost` and
`defaultSmtpPort`.

**The Undo banner.** After a note is transcribed, `statusFor(noteId)` is
`pendingUndo` for `undoWindow` (five seconds). Show the banner while
`undoRemaining(noteId) > Duration.zero`, drive a countdown from it, and call
`undo(noteId)` - it returns false if the window has already closed, and the
banner must then say it has gone rather than claim it was stopped.

**A note row or note screen.** `statusFor(noteId)` gives the badge;
`failureMessageFor(noteId)` gives one plain sentence when there is something
wrong, and `retry(noteId)` is the tap. `titleFor(transcript)` is what the
title should read - the wake phrase stripped - while the transcript on disk and
on the note screen keeps every word that was said.

**Nothing the UI does can send anything early.** The only send is the outbox's
own timer and `sendTestEmail()`.

## Tests

`test/assistant/` - the detector against realistic ASR output including the
near-miss negatives, the state machine and retry ladder rung by rung, the
outbox's undo / dedupe / persistence / backoff / offline behaviour, the
controller as a screen would use it, and the privacy assertions above
(exactly one keystore entry; no password or address in any settings file; the
body is the instruction and nothing else).
