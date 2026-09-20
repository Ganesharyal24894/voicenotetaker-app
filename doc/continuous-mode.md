# Always listening (continuous notetaking)

The wearer keeps the recorder on all day and notes appear in the library by
themselves, without taking the phone out. The firmware streams only speech; the
phone turns that stream into ordinary recordings and transcribes them as soon
as they are closed - off screen too, on Android, when the battery allows (see
*Background transcription*) - or otherwise the next time the app is opened.

The switch, **Always listening**, lives on **Recorder settings**, which Home's
header status line and its menu open (see `settings-and-battery.md`). Home's
header, the settings card and the not-saving alert all answer one question -
*are my notes being saved?* - from one derivation
(`ContinuousStatus.resolve` -> `NotesSaving.from` -> `HomeStatus.resolve`):
*Saving notes*, *Privacy mode on*, *Recorder asleep — pick it up to wake it*,
*Not saving — recorder disconnected*, *Not saving — mic off to save battery*,
*Not saving — recorder needs an update*. The Android notification shows the
`ContinuousStatus` label (*Always listening*, *Hearing speech*, *Privacy
mode*, *Recorder asleep*, *Mic off to save battery*, *Device not connected*,
*Needs firmware update*) - except while the not-saving alert is up, below.

## Architecture

```
view/settings_view.dart     AlwaysListeningCard (Recorder settings): switch, status, permission dialog
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
model/notes_saving.dart     PURE: saving / privacy mode / asleep / mic off / disconnected / SD "saving on recorder"
model/not_saving_alert.dart PURE: when to buzz (30 s grace, 1 buzz per 10 min)
drivers/haptics*.dart       the buzz (Android vibrator over the background channel)
model/recorder_sleep.dart   PURE: asleep or gone? drop reason + what happened since
model/reconnect_backoff.dart  0, 2, 5, 15, 30, 60, 60 ... s; 20 s per attempt;
                            asleep: one standing 2 min wait, 10 s apart
drivers/background_mode*.dart  foreground service over a MethodChannel
android/.../ListeningService.kt, EngineHolder.kt, MainActivity.kt
```

Nothing in this list runs while the switch is off: no session, no timer, no
service, and the app behaves as it did before the mode existed.

## Device protocol contract (`fe08`)

`6e40fe08-b5a3-f393-e0a9-e50e24dcca9e`, in the `fe00` service.

| Direction | Value |
|---|---|
| READ / NOTIFY, 1 byte | bit0 privacy mode (`muted` on the wire), bit1 audio flowing, bit2 speech gate enabled, bit3 mic off for power (no `fe01` subscriber for 2 min on a recorder without storage; clears on subscribe); bits 4-7 reserved (a value with one set is refused, as for `fe04`/`fe05`) |
| WRITE, 1 byte | `0` gate disabled (stream everything), `1` speech only, `2` privacy mode on (`CAPTURE_CMD_MUTE`), `3` privacy mode off (`CAPTURE_CMD_UNMUTE`). `4..255` -> ATT `0x13`, wrong length -> `0x0D` |

As implemented by the firmware, and relied on here:

- **The wire keeps the old name.** Bit 0 and the write values `2`/`3` are
  called *mute* / *unmute* in the firmware and are left that way here; the
  feature is **privacy mode** in everything the wearer reads.
- **bit0 (privacy mode) and bit3 (mic off) are different things.** Bit 0 is
  the wearer's deliberate choice - a double tap, or a command from the app.
  Bit 3 is the firmware saving power after 2 minutes with no `fe01`
  subscriber; nobody asked for it, and the app says *Mic off to save battery*,
  not *Privacy mode on*.
- **bit1 is "audio flowing"**: `fe01` subscribed AND not in privacy mode AND
  (gate disabled OR gate open). With the gate disabled it is set whenever `fe01` is
  subscribed, so the app treats it as *Hearing speech* only together with bit2
  (`CaptureFlags.hearingSpeech`).
- **The gate resets to disabled on every connect and disconnect.** A new
  `ContinuousSession` is made for every link and writes `1` again.
- Subscribing to `fe08` notifies the current value immediately. Changes are
  sampled every 20 ms (100 ms in privacy mode); two changes in one tick arrive as
  the final state.
- Privacy-mode writes are ACKed at once and applied within ~100 ms; the
  notify is the confirmation. The app has the driver call (`writeCapture`) but
  no control yet: privacy mode is a double tap on the device.
- The device can **boot in privacy mode**; the first read already says so.
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

## Not-saving alert

While always-listening is on, the phone tells the wearer when notes stop
being saved - not on every disconnect.

| Rule | Value |
|---|---|
| Counts as "not saving" | `NotesSaving.isLosingNotes`: recorder disconnected (no storage on it), mic off to save battery (`fe08` bit 3), firmware needs an update |
| Never alerts | always-listening off; **privacy mode** (the wearer's choice); **a sleeping recorder** (its own doing - see *When the recorder sleeps*); an SD-card recorder away from the phone (*Saving on recorder · syncs when back*, grey) |
| Grace | 30 s without a break before the alert; the clock restarts when saving resumes, not when the reason changes |
| Alert | one 400 ms notification vibration + the listening notification becomes **"Notes not saving" / "Recorder disconnected"** (or *Mic off to save battery*, *Recorder needs an update*) |
| Flapping | at most one not-saving buzz per 10 min; later alerts in that window update the notification silently |
| Resume | one 60 ms buzz and the notification returns to normal - only after an alert that buzzed; after a silent one, silently |
| Off, privacy mode or a sleep during an alert | the notification returns to normal, no buzz |

- `NotSavingAlertPolicy` is pure and unit tested (timers, flapping, privacy
  mode, off,
  resume). The controller asks it on every change that passes through
  `_syncBackground` and holds ONE one-shot timer, only while notes are being
  lost and the grace has not run out. Nothing runs when a build has neither a
  notification nor a vibrator.
- Storage variant: `AppController.recorderStorage` is `RecorderStorage.none`
  for every recorder today. An SD recorder would answer `card` (from a future
  capability read) and a lost link then shows *Saving on recorder · syncs when
  back* with no alarm.
- **Android**: `EngineHolder.kt` `vibrate` over the background channel; the
  system vibrator with `VibrationAttributes.USAGE_NOTIFICATION` (13+) or
  `AudioAttributes.USAGE_NOTIFICATION` (8-12), and skipped outright in silent
  ringer mode or any Do Not Disturb filter. `VIBRATE` (normal permission) added
  to the manifest. The notification channel stays `IMPORTANCE_LOW`, so the text
  change itself is silent.
- **Doze**: the 30 s timer is a Dart timer. With the screen off and no BLE
  traffic (the link is gone) it can fire late; the disconnect callback and the
  reconnect attempts wake the CPU often enough in practice. Not measured.
- **iOS**: a local notification, not a buzz. A backgrounded app cannot vibrate
  by itself - there is no API - so `MethodChannelHaptics` still has no iOS
  handler and `main.dart` passes `haptics: null` there. What iOS does allow is
  a local notification, which `AppDelegate.swift` posts and withdraws on the
  `alert` flag of `BackgroundMode.start`; Apple names exactly this case ("a
  background app could ask the system to display an alert"). One identifier,
  replaced in place, so a flapping link does not pile up notifications. It
  needs notification permission, which the Keep listening sheet asks for.
  Dart timers still do not run while suspended, so the alert lands at the next
  BLE wake-up rather than exactly 30 s in; the header still says *Not saving*
  when the app is opened.

## When the recorder sleeps

The firmware powers itself off (System OFF) when it has been still and either
the wearer is in privacy mode or the link has been idle - see the firmware's
own `doc/continuous-mode.md`. **That is normal, not a fault**, and the app must
not buzz anybody at 02:00 for it. Three facts make it recognisable:

1. **It lets the link go on purpose** - HCI `0x13` *Remote User Terminated
   Connection*, not a supervision timeout.
2. **It then stops advertising entirely**, so nothing answers a connect.
3. **Only motion wakes it**, after which it reboots and advertises within
   milliseconds.

`model/recorder_sleep.dart` is where that is decided, purely:

| What the platform said | What the app does |
|---|---|
| Android `"Remote User Terminated Connection"`, iOS `"…has disconnected from us."` | settles 10 s, then **asleep** - or asleep at once if an attempt finds nothing |
| Android `"Connection Timeout"` (`0x08`), iOS `"The connection has timed out unexpectedly."` | **lost**: out of range, a flat cell, a crash. The alert still fires |
| Nothing at all (iOS can report a clean disconnect with no error) | settles 90 s before it counts as a sleep; a failed connect does NOT shorten it, because out of range sounds the same |
| Anything heard from it - an advertisement, a refusal, a link | **not asleep**, whatever it did a moment ago |

`universal_ble` 2.3.0 carries the reason through its one global connection
callback, so the driver records it (including "no reason", which is a fact) and
`BleTransport.lastDropReason` hands it over as a `LinkDropReason`.

**The alert.** Nothing buzzes while the recorder is asleep, and nothing buzzes
while a clean drop is still settling - `NotSavingAlertPolicy.update(atRest:)`.
An alert already showing when the answer turns out to be "asleep" ends
silently.

**The screen and the notification.** Home's header and the settings card read
*Recorder asleep — pick it up to wake it*, grey rather than amber; the
notification says *Recorder asleep*.

**The reconnect.** Hunting a device in System OFF cannot succeed: it answers
nothing until it is moved. So the backoff ladder is abandoned for **one
standing attempt that waits for the advertisement** -
`BleTransport.connect(waitForAdvertisement: true)`, which is Android's
`autoConnect` (the controller's own offloaded scan) and an iOS pending
connection that survives the app being suspended. It is armed for 2 minutes at
a time, 10 s apart, and cancelled before being re-armed so pending connections
cannot stack up. The cost is the point: a night of the old behaviour is ~480
hard 20 s connect attempts driving the phone's radio for nothing, against a
wait the platform was doing anyway - and the wearer picking the recorder up
still gets a link in about a second, because the wait was already armed.

**The 60 s `fe08` keep-alive is unchanged.** It is what holds the recorder
awake while the app is genuinely alive; dropping it to save phone battery would
make the recorder sleep under the app, which has to be a deliberate choice.

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
| Privacy mode on the device | ends the note at once | A double tap is the wearer drawing a line. |

The note being written is marked *Writing...* in the notes list, cannot be
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
  - app off screen: only where the process is actually being kept alive -
    on Android (`backgroundTranscription`, set in `main.dart`) AND with
    always-listening on, because its foreground service is what keeps the
    process; or on iOS **inside a granted `BGProcessingTask` window** (see
    below) - and then only if the phone is **on a charger**, or at
    **>= 30% battery with battery saver off**; never at thermal status
    **MODERATE or hotter** (charger or not); anything the phone does not
    report counts as "no".
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
- **A wake lock, for inference only.** A foreground service keeps the PROCESS,
  not the CPU: once the binder transaction that delivered a packet is done
  with, Android is free to suspend and a job on a worker thread is frozen until
  the next packet. So `EngineHolder.holdCpu` takes a `PARTIAL_WAKE_LOCK` when
  the first job of an off-screen run starts and releases it when the run ends -
  one lock per run, never on screen, never while the queue is idle, and always
  with a 30-minute timeout as a backstop. Receiving and writing a note still
  needs no lock: the incoming notification wakes the CPU by itself. In full
  Doze an app wake lock is ignored anyway, which the foreground service mostly
  keeps the app out of. Not measured on device.
- The model is loaded once for a run of jobs; see
  `doc/agentFindings/on-device-stt.md` ("Model kept loaded between jobs").
- **iOS:** `BGProcessingTask`, and nothing else. Leaving the app still cancels
  the running job and frees the model (`TranscriptionPermit.noKeepAlive`), and
  the queue runs again on open. In addition, `AppController._syncBackgroundWork`
  asks iOS for a processing window whenever the app leaves the screen with work
  queued (`BackgroundTaskPlan.plan`: only with work AND a model installed;
  `requiresExternalPower`, no network, `earliestBeginDate` 15 minutes out). When
  the system grants one, `AppDelegate.swift` calls `runWork` into Dart,
  `_runBackgroundWindow` sets `_backgroundWindow` so the SAME policy applies,
  and the window is handed back the moment the queue drains. `workExpiring`
  stops the run early - iOS kills an app that overruns, and iOS ends a
  processing task the moment the user picks the phone up.
  **Nothing depends on a window arriving.** It needs Background App Refresh on,
  the phone idle and plugged in, and it may never come; the queue is still
  there on the next foreground and the UI says so.
  **No `audio` background mode.** Apple's current wording for it is "the app
  plays audible content in the background", and every Apple doc ties it to an
  active `AVAudioSession`. This app receives audio bytes over BLE and neither
  captures nor plays them in the background, so the mode does not apply -
  claiming it is a guideline 2.5.4 ("background services ... for their intended
  purposes") risk and, more to the point, a permanently unsuspended app is a
  battery cost the owner would notice on their daily phone.
- Opening a note that is waiting moves it to the front; the note screen shows
  *Waiting to transcribe...*, then *Transcribing NN%*, then the text.
- Failures that would repeat (`unsupported`, engine `failed`) are saved as
  `<name>.transcript-failed.json` beside the recording and skipped by the
  queue; the Transcribe button still works and clears the marker on success.
  Deleting a recording deletes the marker too.
- UI not built yet: `AppController.transcriptionPermit` says why the queue is
  paused (e.g. "Waiting for charger").

## Audio retention (off by default)

`autoDeleteAudio` (persisted in `audio-retention-settings.json`, default
**false**; the *Delete audio after 24 h* switch on Recorder settings). When on, a sweep runs at start, on every return to the
app, when the setting is turned on, and after every saved transcript. It
removes **only the WAV** when ALL hold (`AudioRetention`, pure, unit tested):

| Rule | Detail |
|---|---|
| Age | >= **24 h** since the later of the file-name time and the file mtime, compared in **UTC**. The name is the start; mtime can only postpone (time-zone change, DST hour). No time at all: kept. |
| Clock moved back | a time more than **5 min** in the future: kept until real time passes it. |
| Transcript | a saved transcript **with words**. No transcript, a saved failure, an unreadable or empty transcript: kept. |
| Keep | no `<name>.keep-audio.json` marker. |
| In use | not the note being written, not being transcribed, not loaded in the player, no manual capture running (asked again right before the delete). |

- On screen: the note shows *Audio deletes in 18 h* with **Keep** only while
  the setting is on, *Audio kept* once kept, and *Audio deleted - transcript
  kept* after the sweep; see `doc/notes.md`.
- The keep flag is a **presence-only sidecar**, not a transcript field: it can
  be set before a transcript exists, older files read as "not kept", and no
  transcript format bump is needed.
- Before deleting, the sweep writes `<name>.audio-removed.json`. The library
  lists a note with that marker and a transcript but no WAV as
  `RecordingInfo.hasAudio == false` (duration from the transcript). A stray
  transcript without the marker stays hidden, as before. Killed between marker
  and delete: the WAV is still listed normally and the next sweep removes it.
- Deleting a note removes the WAV, transcript, failure, keep, speaker-name and
  removed markers (removed marker last).
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
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, and `WAKE_LOCK` - the last one for
  transcription and nothing else, see "Background transcription" above. The
  switch explains and asks for notifications + the battery exemption when
  missing, **one at a time**: `requestNotifications` does not answer its Dart
  call until `onRequestPermissionsResult` fires, so the battery-exemption
  Activity is not started on top of an open permission dialog.
- **A refused start is reported, not swallowed.** `ListeningService.start`
  returns false when Android refuses (background start with no exemption;
  `SecurityException` on 14+ when `BLUETOOTH_CONNECT` has been revoked, which
  the `connectedDevice` type requires), and `startForeground` failing inside
  `onStartCommand` calls `EngineHolder.reportKeepAliveStopped`, as does an
  `onDestroy` the app did not ask for. Either way Dart clears the notification
  text it believes is up, so the next status change - or `appForegrounded`,
  which now re-syncs first - asks again. Before this, a refusal was recorded as
  success and never retried, and the switch stayed green over nothing.
- **`EngineHolder.obtain` is called on every `onStartCommand`**, not only for
  the null intent of a sticky restart: the app can be swiped away between Dart
  asking for the service and the service starting, and `releaseIfIdle` would
  then destroy the engine behind a live notification.
- **`MainActivity.cleanUpFlutterEngine`** clears the three method-call handlers
  it installed. They close over the activity (`startActivity`,
  `getSystemService`), so leaving them on an engine that outlives it held a
  destroyed activity and its view hierarchy for as long as always-listening ran.
- **Android 15/16 six-hour FGS cap**: `dataSync` and `mediaProcessing` only.
  `connectedDevice` is not on that list, so no `Service.onTimeout` override is
  needed.
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

**What keeps working off screen**

- `Info.plist` declares `UIBackgroundModes: bluetooth-central` (and now
  `processing`, for the transcription window). With `bluetooth-central`, Apple:
  "the system wakes up your app when any of the `CBCentralManagerDelegate` or
  `CBPeripheralDelegate` delegate methods are invoked ... such as ... when a
  peripheral sends updated characteristic values". So `fe01` / `fe08`
  notifications keep arriving and notes are written with the screen locked and
  the app off screen. Nothing has to be started for this and nothing has to be
  granted.
- **The budget per wake-up is small.** Apple's only published number is in the
  (archived, 2013) Core Bluetooth background guide: "Upon being woken up, an
  app has around 10 seconds to complete a task ... Apps that spend too much
  time executing in the background can be throttled back by the system or
  killed." That is enough to decode and append a frame; it is nowhere near
  enough for speech inference, which is why the processing window exists.
- **`autoConnect: true` on iOS only** (`ble_transport_universal.dart`). On
  iOS 17+ `universal_ble` maps this to
  `CBConnectPeripheralOptionEnableAutoReconnect`, so Core Bluetooth
  re-establishes the link itself after an unexpected disconnect - including
  while the app is suspended, which is precisely the case the app cannot reach,
  because a suspended app has no timer to run its own backoff with. Not passed
  on Android, where the same flag becomes the platform `autoConnect` (slower
  first connection) and the foreground service lets the app's own backoff run.
- **No `CBConnectPeripheralOption NotifyOnConnection/Disconnection/Notification`.**
  Those ask iOS to show the USER an alert per event while the app is suspended;
  for a continuous audio stream that is a notification per packet.

**What is not possible, and why**

- **Force quit ends it.** TN3115's relaunch table is explicit: "App Force Quit
  by the user - No". Swipe the app out of the app switcher and iOS will not
  bring it back for Bluetooth; nothing is captured until the user opens it.
  There is no workaround.
- **State restoration is not reachable from this app's launch path, today.**
  `universal_ble` 2.3.0 *does* support it: when `bluetooth-central` is declared
  and Bluetooth permission is granted, it builds its `CBCentralManager` with
  `CBCentralManagerOptionRestoreIdentifierKey` and implements
  `centralManager(_:willRestoreState:)`
  (`UniversalBlePlugin.swift:75-89`, `:110-120`, `:561-578`). The problem is
  ours: Apple requires the restoring manager to exist before
  `application(_:didFinishLaunchingWithOptions:)` returns, and this app is
  scene-based with an *implicit* Flutter engine - `AppDelegate` registers
  plugins in `didInitializeImplicitFlutterEngine`, which the engine only calls
  from `FlutterViewController` initialisation, i.e. at scene connect. A
  Bluetooth background relaunch connects no scene, so no engine, no plugin
  registration, no central manager, and no Dart to receive anything.
  **What it would take:** create an explicit `FlutterEngine` in
  `didFinishLaunchingWithOptions`, run it and call
  `GeneratedPluginRegistrant.register` against it there, then hand that engine
  to a code-created `FlutterViewController` at scene connect (dropping
  `UIMainStoryboardFile`). That is a rewrite of the iOS launch path and must be
  validated on a device before it is trusted, so it is deliberately NOT done
  here.
  **And it may be moot on iOS 26**: TN3115 note 5 says "Starting in iOS 26 and
  iPadOS 26, only apps that use AccessorySetupKit to setup Bluetooth
  accessories will be relaunched." Apple's wording is ambiguous about exactly
  which rows that restricts; it needs a device test before anything is built
  on it.
- **Dart timers do not run while suspended**, so the 60 s keep-alive and the
  reconnect backoff only run when a BLE event wakes the app. In a long silence
  the firmware may drop the link after 10 min; the disconnect wakes the app and
  the immediate reconnect attempt runs - and on iOS 17+ Core Bluetooth's own
  auto-reconnect is now also in play.
- Reconnect by id after a restart uses `retrievePeripherals(withIdentifiers:)`,
  which works for a device iOS has seen before.
- **Background App Refresh gates the processing window**, and Low Power Mode
  switches Background App Refresh off (`UIApplication.backgroundRefreshStatus`:
  "Background App Refresh is disabled automatically when a device is operating
  in low-power mode"). Whether it also gates Core Bluetooth wake-ups is
  **undocumented either way** - worth a device test, not an assumption.

## Not done

- **On-device storage when the phone is away.** Speech while the phone is out
  of range or the link is down is lost; the firmware has nowhere to keep it.
- A privacy-mode control in the app (driver method exists).
- A "session could not start" state: a session that fails to start on a
  connected, capable recorder still reads *Saving notes*.
- A dedicated mic-check blocker message for always-listening (it reuses "A
  recording is running").
- `AlarmManager` keep-alive, pending the Doze measurement above. (The
  transcription wake lock is now in - see "Background transcription".)
- **A `BOOT_COMPLETED` receiver.** Nothing brings always-listening back after
  the phone restarts until the user opens the app. `connectedDevice` is not on
  Android 15's BOOT_COMPLETED-launch deny-list, so it is allowed; it is simply
  not built.
- **iOS Core Bluetooth state restoration** - see "iOS specifics" for exactly
  what it would take and why it is not done blind.
- iOS build and on-device verification. Everything in "iOS specifics" is
  correct by inspection and by Apple's documentation; none of it has been run
  on a phone from this repository.
- Waveform envelope and speaker/segment boundaries inside a note.
