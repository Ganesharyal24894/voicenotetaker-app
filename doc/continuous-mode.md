# Always listening (continuous notetaking)

The wearer keeps the recorder on all day and notes appear in the library by
themselves, without taking the phone out. The firmware streams only speech; the
phone turns that stream into ordinary recordings and transcribes them as soon
as they are closed - off screen too, on Android, when the battery allows (see
*Background transcription*) - or otherwise the next time the app is opened.

The switch, **Always listening**, lives in the recorder sheet that Home's
header status line opens (see `today-and-summaries.md`); the sheet shows one
status line:
*Always listening*, *Hearing speech*, *Muted on device*, *Device not
connected*, *Needs firmware update*. The Android notification shows the same
line, from the same resolver (`ContinuousStatus.resolve`).

## Architecture

```
view/home_view.dart         AlwaysListeningCard (in the recorder sheet): switch, status, permission dialog
view/app_root.dart          Home stays up without a link while it is on;
                            lifecycle -> appForegrounded / appBackgrounded
controller/app_controller   ALWAYS LISTENING section: settings, reconnect with
                            backoff, one ContinuousSession per link, the
                            foreground-service notification text.
                            BACKGROUND TRANSCRIPTION section: the queue.
services/continuous/
  continuous_session.dart   one link: fe08=1, fe01 + fe08 subscribed, decode,
                            60 s keep-alive read, feeds the writer
  note_writer.dart          PURE: PCM + arrival times -> WAV notes
  continuous_settings_store on/off + remembered device id, one JSON file in
                            the app support directory
services/wav_repair.dart    startup pass: patch headers left behind by a kill
services/transcription/
  transcription_queue.dart  PURE: newest first, skip done/failed/writing/no audio
services/audio_retention_service.dart  24 h audio sweep + keep markers
model/background_transcription_policy.dart  PURE: may transcription run now
model/audio_retention.dart  PURE: may this WAV be removed
drivers/phone_power*.dart   battery/charger/saver (battery_plus) + thermal
model/capture_flags.dart    fe08 wire format (read flags, write commands)
model/continuous_status.dart  the one status, and its copy
model/reconnect_backoff.dart  0, 2, 5, 15, 30, 60, 60 ... s; 20 s per attempt
drivers/background_mode*.dart  foreground service over a MethodChannel
android/.../ListeningService.kt, EngineHolder.kt, MainActivity.kt
```

Nothing in this list runs while the switch is off: no session, no timer, no
service, and the app behaves as it did before the mode existed.

## Device protocol contract (`fe08`)

`6e40fe08-b5a3-f393-e0a9-e50e24dcca9e`, in the `fe00` service.

| Direction | Value |
|---|---|
| READ / NOTIFY, 1 byte | bit0 muted, bit1 audio flowing, bit2 speech gate enabled; other bits reserved (a value with one set is refused, as for `fe04`/`fe05`) |
| WRITE, 1 byte | `0` gate disabled (stream everything), `1` speech only, `2` mute, `3` unmute. `4..255` -> ATT `0x13`, wrong length -> `0x0D` |

As implemented by the firmware, and relied on here:

- **bit1 is "audio flowing"**: `fe01` subscribed AND not muted AND (gate
  disabled OR gate open). With the gate disabled it is set whenever `fe01` is
  subscribed, so the app treats it as *Hearing speech* only together with bit2
  (`CaptureFlags.hearingSpeech`).
- **The gate resets to disabled on every connect and disconnect.** A new
  `ContinuousSession` is made for every link and writes `1` again.
- Subscribing to `fe08` notifies the current value immediately. Changes are
  sampled every 20 ms (100 ms while muted); two changes in one tick arrive as
  the final state.
- Mute/unmute writes are ACKed at once and applied within ~100 ms; the notify
  is the confirmation. The app has the driver call (`writeCapture`) but no
  control yet: muting is a double tap on the device.
- The device can **boot muted**; the first read already says so.
- **Liveness**: the firmware drops a link with no ATT activity from the phone
  for 10 minutes. The session reads `fe08` every 60 s; any read counts.
- While the gate is closed no `fe01` packets arrive and **no sequence numbers
  are consumed**, so sequence gaps are still real radio loss.
- At gate open the 500 ms pre-roll is flushed at ~3x real time, so arrival
  times at speech onset are compressed. Arrival times are used only to find
  pauses; every length is counted in samples.
- **Old firmware** has no `fe08`. `BleTransport.supportsCapture` answers from
  the service discovery done at connect (no radio time). The status is then
  *Needs firmware update*, and manual Record keeps working.
- A manual recording on new firmware writes `0` before subscribing to `fe01`.

## Notes on disk

Same folder (`<documents>/recordings`), same name
(`voicenote-YYYYMMDD-HHMMSS.wav`, the time the first speech arrived), same
44-byte header - library, playback and transcription need no changes.

| Rule | Value | Why |
|---|---|---|
| New note after no audio for | 2 min | Pauses inside a conversation run to tens of seconds; longer runs separate conversations together. Omi defaults to 120 s. |
| A pause >= 1 s is written as | 300 ms of silence | The firmware removed the silence; putting minutes back makes a tedious file, nothing at all runs sentences together. Below 1 s is BLE burstiness, not a pause. |
| Maximum note length | 60 min, then roll over | One meeting should not be one unplayable, untranscribable file. |
| Discard notes with less speech than | 2 s | Coughs and doors. Inserted silence does not count. |
| Header patched every | 5 s of audio | A kill loses at most 5 s of *header*, never audio... |
| Startup repair (`WavRepair`) | every launch, before the library is read | ...and this fixes the rest: a header claiming less than the file holds (placeholder `0` included) is patched to the whole samples on disk. |
| Muting on the device | ends the note at once | A double tap is the wearer drawing a line. |

The note being written is marked *Writing...* in the library, cannot be
deleted, and is never transcribed.

## Connection

- On: the connected device is remembered (id + name, persisted). With a link,
  the session starts at once; without one, the controller reconnects.
- Reconnect: after a drop, after Bluetooth comes back on, and after app
  restart. First attempt immediately (inside the disconnect callback, the one
  moment the CPU is certainly awake), then 2, 5, 15, 30, 60 s, then every
  60 s; each attempt is a direct connect with a 20 s timeout. No failure
  screen: Home says *Device not connected*.
- Record is disabled while listening ("Notes save on their own"): both need
  the single `fe01` subscription. Disconnect is hidden; turning the switch off
  (or `disconnect()`) stops listening and writes `fe08=0`.
- The mic check and the diagnostics link counters stand down while listening,
  for the same reason.

## Background transcription

- If the Hindi model is installed: all recordings with no transcript, no saved
  failure and their audio still present, newest first, one at a time.
- **When it runs** (`BackgroundTranscriptionPolicy`, pure, unit tested):
  - app on screen: always;
  - app off screen: only on Android (`backgroundTranscription`, set in
    `main.dart`) AND with always-listening on, because its foreground service
    is what keeps the process alive - and then only if the phone is **on a
    charger**, or at **>= 30% battery with battery saver off**; never at
    thermal status **MODERATE or hotter** (charger or not); anything the
    phone does not report counts as "no".
  - Asked before every job, and every **60 s** while a job runs off screen.
    A "no" puts the running job back at the front, frees the model, and
    listens for charger events; the next finished note or opening the app
    also re-checks. Thermal cooling and battery saver being switched off are
    only noticed at those moments.
- So a note is transcribed as soon as it is closed, screen off included, when
  the policy allows. A process Android restarts headless for always-listening
  resumes its queue under the same rule.
- Battery, charger and saver come from `battery_plus` behind
  `drivers/phone_power.dart`; thermal status from
  `PowerManager.getCurrentThermalStatus()` over the existing background channel
  (`thermalStatus`, API 29+, null below).
- **No wake lock** (unchanged): with the screen off Android may suspend the CPU
  between BLE events, so background decoding can run in bursts and take longer
  than its RTF suggests. Not measured.
- The model is loaded once for a run of jobs; see
  `doc/agentFindings/on-device-stt.md` ("Model kept loaded between jobs").
- **iOS:** background execution is not guaranteed, so nothing changes there -
  leaving the app cancels the job, frees the model, and the queue runs again
  on open (`TranscriptionPermit.noKeepAlive`).
- Opening a recording that is waiting moves it to the front; the playback card
  shows *Waiting to transcribe...*, then the live progress, then the text.
- Failures that would repeat (`unsupported`, engine `failed`) are saved as
  `<name>.transcript-failed.json` beside the recording and skipped by the
  queue; the Transcribe button still works and clears the marker on success.
  Deleting a recording deletes the marker too.
- UI not built yet: `AppController.transcriptionPermit` says why the queue is
  paused (e.g. "Waiting for charger").

## Audio retention (logic only, off by default)

`autoDeleteAudio` (persisted in `audio-retention-settings.json`, default
**false**; no UI yet). When on, a sweep runs at start, on every return to the
app, when the setting is turned on, and after every saved transcript. It
removes **only the WAV** when ALL hold (`AudioRetention`, pure, unit tested):

| Rule | Detail |
|---|---|
| Age | >= **24 h** since the later of the file-name time and the file mtime, compared in **UTC**. The name is the start; mtime can only postpone (time-zone change, DST hour). No time at all: kept. |
| Clock moved back | a time more than **5 min** in the future: kept until real time passes it. |
| Transcript | a saved transcript **with words**. No transcript, a saved failure, an unreadable or empty transcript: kept. |
| Keep | no `<name>.keep-audio.json` marker. |
| In use | not the note being written, not being transcribed, not loaded in the player, no manual capture running (asked again right before the delete). |

- The keep flag is a **presence-only sidecar**, not a transcript field: it can
  be set before a transcript exists, older files read as "not kept", and no
  transcript format bump is needed.
- Before deleting, the sweep writes `<name>.audio-removed.json`. The library
  lists a note with that marker and a transcript but no WAV as
  `RecordingInfo.hasAudio == false` (duration from the transcript). A stray
  transcript without the marker stays hidden, as before. Killed between marker
  and delete: the WAV is still listed normally and the next sweep removes it.
- Deleting a note removes the WAV, transcript, failure, keep and removed
  markers (removed marker last).
- Controller: `setAutoDeleteAudio(bool)`, `setKeepAudio(path, bool)`,
  `keepAudioFor(path)`, `lastAudioSweep`. A note without audio is never played
  (a `playbackError` is set) or queued/transcribed.

## Android specifics

- **Foreground service** `ListeningService`, type `connectedDevice`, one
  `IMPORTANCE_LOW` notification ("voiceNotetaker - Always listening"), tapping
  it opens the app. Started when the switch is on (and at launch if it was
  left on); stopped when off.
- **Why native, not `flutter_foreground_task`**: that plugin runs its work in a
  second isolate/engine. The BLE link, decoding and open note live in the main
  isolate behind `AppController`; moving them would split the controller and
  put a message channel in the audio path. What is needed is a service that
  holds a notification plus an engine that outlives the activity - two small Kotlin
  files, no new dependency.
- **Engine outlives the activity** (`EngineHolder`): `MainActivity` takes its
  engine from `FlutterEngineCache` and does not destroy it, so swiping the app
  away keeps the Dart isolate - and the link and note - running while the
  service keeps the process. With the switch off the engine is released when
  the activity finishes, which is the old behaviour.
- **Sticky restart**: if the system kills the process, Android restarts the
  service; it starts the engine headless, `main()` runs, the controller reads
  the saved setting and reconnects. The transcription queue resumes headless
  only as `BackgroundTranscriptionPolicy` allows (see above).
- **Permissions** (manifest): `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_CONNECTED_DEVICE` (Android 14+, satisfied at runtime by
  the granted `BLUETOOTH_CONNECT`), `POST_NOTIFICATIONS` (runtime on 13+),
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. **No `WAKE_LOCK`.** The switch
  explains and asks for notifications + the battery exemption when missing.
- **Android 12+ background-start rule**: a foreground service may not be
  started from the background - except by an app exempt from battery
  optimisation. The exemption is what lets the sticky restart and a
  reconnect-driven restart work; without it the service starts again the next
  time the app is opened.
- **Doze and the keep-alive**: with no wake lock, the 60 s `fe08` read is a Dart
  timer that can slip while the CPU sleeps in deep Doze during a long silence.
  Audio notifications and disconnect callbacks wake the CPU by themselves. The
  worst case is the firmware dropping the link after 10 min of silence and the
  app reconnecting immediately from the disconnect callback. To be measured on
  the phone (see test plan) before adding a wake lock.

### MIUI / HyperOS (Xiaomi, Redmi, POCO)

MIUI kills background apps regardless of Android's rules. For always-listening
to survive a locked phone, the user must (menu names vary between MIUI
versions):

1. **Autostart**: Settings > Apps > Manage apps > voiceNotetaker > Autostart:
   on. The permission dialog offers an *Autostart* button on Xiaomi phones
   (opens `com.miui.securitycenter`'s autostart page, falls back to app info).
2. **Battery saver**: same page > Battery saver > **No restrictions** (the
   "Allow" in the app's dialog sets the Android exemption; MIUI has its own
   switch as well).
3. **Lock the app in Recents**: open Recents, long-press voiceNotetaker, tap the
   lock. Swipe-to-clear then leaves it alone.
4. Keep notifications allowed for the app, or MIUI hides the service and is
   more eager to kill it.

## iOS specifics (not built here - correct by inspection only)

- `Info.plist` declares `UIBackgroundModes: bluetooth-central`. With it,
  `universal_ble` creates its `CBCentralManager` with a restore identifier at
  launch, so iOS can relaunch the app in the background for a peripheral that
  had a live connection, and re-adopts it (`willRestoreState`).
- Notifications (`fe01`, `fe08`) keep arriving while backgrounded, so notes are
  written with the screen locked. There is no foreground-service notification;
  `MethodChannelBackgroundMode` has no iOS handler and answers "ready".
- Limits: **a user force-quit (swipe up in the app switcher) stops capture**
  and iOS will not relaunch it until the user opens the app. Dart timers do not
  run while suspended, so the 60 s keep-alive and backoff waits only run when a
  BLE event wakes the app; in a long silence the firmware may drop the link
  after 10 min, the disconnect wakes the app, and the immediate reconnect
  attempt runs. Reconnect by id after a restart uses
  `retrievePeripherals(withIdentifiers:)`, which works for a device iOS has
  seen before.

## Not done

- **On-device storage when the phone is away.** Speech while the phone is out
  of range or the link is down is lost; the firmware has nowhere to keep it.
- A mute/unmute control in the app (driver method exists).
- A dedicated mic-check blocker message for always-listening (it reuses "A
  recording is running").
- Wake-lock / `AlarmManager` keep-alive, pending the Doze measurement above.
- iOS build and on-device verification.
- Waveform envelope and speaker/segment boundaries inside a note.
