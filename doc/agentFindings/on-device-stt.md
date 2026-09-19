# On-device Hindi speech-to-text — feasibility spike, then the feature

> **Update 2026-09-14 (later the same day): the spike is now a feature.** See
> *The feature* at the end. The spike sections below are kept as the record of
> what was measured; where they are out of date, the new section says so.

> **Update 2026-09-19: the decode window is 16 s, not 8 s.** Every "8 s window"
> below is the historical record. The length now lives in one place,
> `lib/model/decode_window.dart`, and the measurement that chose it is in *The
> decode window: 8 s → 16 s* at the end.

**Question:** can offline Hindi/Hinglish speech-to-text with native Devanagari
output run on the owner's Android phone, inside this app?

**Answer: yes.** **[V]** On a Xiaomi M2007J20CI (Snapdragon 732G, Android 12),
the int8 IndicConformer model loads in about **1.2 s** and decodes at a
real-time factor of about **0.14**. One minute of audio takes about 9–10 s. The
output is Devanagari and matches the laptop's output almost word for word. The
open problem is memory: see *Memory* below.

Measured 2026-09-14. Markers as in `README.md`: **[V]** verified, **[I]**
inferred, **[?]** unverified.

## Settled before this spike — not re-derived here

- **IndicConformer (CTC), not Whisper.** Whisper-family models invent fluent
  sentences and loop on long audio. CTC does neither. (Prior research on the
  laptop.)
- **int8 (188 MB) is acceptable.** It is about 1–2 CER points worse than the
  471 MB float model, and it still needs chunking. (Laptop measurement by a
  separate agent, reported to this one. Not measured here.)
- **Chunking is load-bearing.** Decoding a long clip in one call silently drops
  the middle. Where the chunk grid falls moved CER by **13 points** in the
  laptop run, so segmentation quality matters (see *Next*).

## The Dart API — verified in the package source

Package `sherpa_onnx` **1.13.8** (k2-fsa, Apache-2.0), pinned exactly. Read
from `~/.pub-cache/hosted/pub.dev/sherpa_onnx-1.13.8/lib/src/`:

```dart
sherpa.initBindings();               // per isolate — sherpa_onnx.dart doc comment
final recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
  feat: sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
  model: sherpa.OfflineModelConfig(
    nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: modelPath),
    tokens: tokensPath, numThreads: n, provider: 'cpu', debug: false),
  decodingMethod: 'greedy_search'));
final stream = recognizer.createStream();
stream.acceptWaveform(samples: float32Samples, sampleRate: 16000);
recognizer.decode(stream);
final text = recognizer.getResult(stream).text;
stream.free(); recognizer.free();
```

- **[V]** `OfflineNemoEncDecCtcModelConfig` has one field, `model`
  (`offline_recognizer_config.dart:60`). `FeatureConfig` defaults to 16000/80
  (`feature_config.dart:8`).
- **[V]** It works: identical transcripts on laptop x64 and on phone arm64.
- **[V]** The model card's online-transducer config is wrong for this export
  and was not used.
- **[V]** `initBindings()` has to be called in every isolate that uses the
  package (library doc comment). On Android it opens
  `libsherpa-onnx-c-api.so` from the APK (`init_native.dart`).
- **[V]** On the Linux desktop (`flutter test`) the `.so` is not found unless
  `LD_LIBRARY_PATH=~/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64`
  is set. That setting is only for the laptop test.

## How it is built

| Layer | File | Role |
|---|---|---|
| model | `lib/model/transcription.dart` | `SpeechModel` catalogue entry (file names, **exact byte sizes**, 16 kHz, 80 bins, 8 s window), `RecognitionJob`, events, `TranscriptionResult` (text, segments, load/decode/wall, RTF, RSS) |
| drivers | `speech_recognizer.dart` | Abstract `SpeechRecognizer.transcribe(job) → Stream<RecognitionEvent>`, plus `pcm16leToFloat32` |
| drivers | `speech_recognizer_sherpa.dart` | **The only file that imports `sherpa_onnx`.** A test enforces this (`test/speech_recognizer_test.dart`). |
| drivers | `process_memory.dart` | `/proc/self/status` RSS probe |
| services | `transcription/window_planner.dart` | Fixed 8 s windows, no overlap, nothing dropped |
| services | `transcription/speech_model_store.dart` | Is the model installed? Checks presence and exact size. |
| services | `transcription/transcription_service.dart` | Validates the WAV, then plans windows, then checks the model, then runs the engine and assembles the result. One job at a time. |
| controller | `app_controller.dart` | `transcribe(recording, numThreads:)`, state, and `STT ...` logcat lines |
| view | `developer_view.dart` | "Transcription spike" card: pick a recording, 2 or 4 threads, run, see the numbers and the text |

Design decisions:

- **One job, one load.** **[V]** The interface has no separate load and unload
  calls. `transcribe` loads the model, decodes, frees it and finishes. This
  follows the power rule by construction.
- **Off the UI isolate.** **[V]** Each job runs in a fresh `Isolate.spawn`
  worker, which exits when the job ends. The worker reads each window straight
  from the WAV file, so no audio buffer is copied between isolates and long
  recordings are never held in memory.
- **Cancellation** asks the worker to stop between windows, rather than killing
  the isolate, so native `free()` still runs. **[?]** This path is not exercised
  by any test or run.
- **The audio is checked before the model**, so a bad file never costs a
  188 MB load. **[V]** Unit tested.

## Model delivery (spike)

> **The cable is no longer the only way.** Every `adb` recipe below still works
> and is still the quickest thing to do at a desk, so it is kept. What it could
> never do is reach an iPhone — see *Downloading the models* at the end and
> `doc/models.md`.

**[V]** The model is not bundled in the APK. For the spike it was streamed from
the laptop into the app's private support directory:

```sh
P=com.ganeshsharma.voicenotetaker_app
D=files/models/indicconformer-hi-int8
adb shell run-as $P mkdir -p $D
adb exec-in run-as $P sh -c "cat > $D/tokens.txt"      < tokens.txt
adb exec-in run-as $P sh -c "cat > $D/model.int8.onnx" < model.int8.onnx
adb shell run-as $P sh -c "'chmod 700 files/models $D && chmod 600 $D/*'"
```

- **[V]** The on-phone sha256 matched the laptop copy
  (`b99a0183…075d` / `743aeb75…4882`). The transfer took a few seconds over USB.
- **[V]** The resolved path is
  `/data/user/0/com.ganeshsharma.voicenotetaker_app/files/models/indicconformer-hi-int8/`,
  which is `getApplicationSupportDirectory()`. `AppDirectories` gained
  `supportDirectory()` for this.
- **[V]** *(2026-09-18)* That is exactly what the downloader does: it fills
  that directory, `SpeechModelStore.status` is unchanged, and the sha256 is
  verified once, when the download finishes. The runtime check is still size
  only.
- **[V]** Adding the package increases the APK by roughly **27 MB per ABI**
  (onnxruntime 22 MB plus sherpa 4.9 MB on arm64). The debug APK also carries
  armeabi-v7a and x86_64 copies. **[I]** A release build with `--split-per-abi`
  or an app bundle would ship only one.

## Measurements on the phone

Device: **[V]** Xiaomi M2007J20CI "karna", Qualcomm SDMMAGPIE (Snapdragon 732G:
2× Cortex-A76 + 6× A55 by `CPU part`), 5.5 GB RAM, Android 12. Debug build,
run through `integration_test/transcription_on_device_test.dart` on the
USB-connected phone, which exercises the same service and driver wiring as
`main.dart`. Every WAV was transcribed at 2 and 4 threads, twice.

The test clips:

- **Owner recordings:** three device recordings from the phone, 11.5 s, 7.0 s
  and 3.1 s.
- **Hinglish:** a 16 s TTS clip (Gemini "Aoede"), resampled to 16 kHz mono s16.
- **Hinglish ×4:** the same clip repeated four times (64 s), to exercise
  chunking (8 windows).

### Load and decode — [V]

| Clip | Audio | Threads | Load (ms) | Decode (ms) pass 1 / 2 | RTF pass 1 / 2 |
|---|---|---|---|---|---|
| Hinglish ×4 | 64.0 s | 2 | 1155 / 1374 | 9277 / 9995 | 0.145 / 0.156 |
| Hinglish ×4 | 64.0 s | 4 | 1188 / 1233 | 8961 / 10208 | 0.140 / 0.159 |
| Hinglish | 16.0 s | 2 | 1350 / 1152 | 2322 / 2489 | 0.145 / 0.155 |
| Hinglish | 16.0 s | 4 | 1178 / 1179 | 2360 / 2307 | 0.147 / 0.144 |
| owner rec. | 11.5 s | 2 | 1178 / 1739 | 1616 / 1595 | 0.140 / 0.138 |
| owner rec. | 11.5 s | 4 | 1177 / 1178 | 1548 / 1616 | 0.134 / 0.140 |
| owner rec. | 7.0 s | 2 | 1161 / 1228 | 981 / 1054 | 0.140 / 0.150 |
| owner rec. | 7.0 s | 4 | 1178 / 1553 | 1001 / 1051 | 0.143 / 0.150 |
| owner rec. | 3.1 s | 2 | 1203 / 1286 | 437 / 401 | 0.140 / 0.129 |
| owner rec. | 3.1 s | 4 | 1163 / 1184 | 403 / 415 | 0.129 / 0.133 |

- **[V]** **RTF ≈ 0.13–0.16 on the phone**, about 2.3× slower than the
  laptop's own 0.06 figure. Decode time scales linearly with length, and the
  first window costs no more than later ones.
- **[V]** **Load ≈ 1.15–1.75 s, typically 1.18 s.** Load is paid on every job
  by design. For a 3 s note it is larger than the decode itself.
- **[V]** **4 threads gave no measurable speedup over 2 on this phone.** The
  differences are within the pass-to-pass noise. On the laptop, 4 threads was
  about 1.6× faster (64 s clip: 1611 ms at 2 threads, 1043 ms at 4).
  **[I]** The likely cause is the 2 big + 6 little core layout: threads 3 and 4
  land on A55 cores and add nothing, or the scheduler spreads threads across
  core types. **[?]** The per-thread CPU sampling that would confirm this did
  not run (see *Could not verify*). **Recommendation [I]:** use 2 threads. It is
  as fast here and should cost less battery.
- **[I]** Wall-clock cost of a transcript is about 1.2 s + 0.15 × audio length.
  A 1-hour recording would take about 9 minutes.

### Transcripts — [V] Devanagari

Owner recordings (spoken on the recorder; identical at 2 and 4 threads, and
identical to the laptop):

- 11.5 s: `चेक चेक ठीक है`
- 7.0 s: `हैलो ओन टू थ्री अच्छा`
- 3.1 s: `हैलो`

Hinglish clip (script was *"Namaste dost! Main hoon Guru, tumhara naya dost. Hi
there! I'm Guru, and I'm so happy to meet you. Chalo, aaj hum kuch naya aur
exciting seekhte hain! What would you like to talk about — animals, space, ya
koi mazedaar kahani?"*), on the phone:

> नमस्ते दोस्त मैं हूँ गुरु तुम्हारा नया दोस्त हाय दे आई एम गुरु एंड आई एम सो
> हैप्पी टू मीट यू चलो आज हम कुछ नया और एक्साइटिंग सीखते हैं वॉट वोड यू लाइक टू
> टॉक अबाउट एनिमल्स स्पेस या कोई मज़ेदार कहानी

- **[V]** English words come out transliterated into Devanagari ("हैप्पी टू
  मीट यू"). That matches the native-script decision.
- **[V]** Nothing was invented and nothing looped over 64 s. The ×4 clip shows
  only small per-copy variations, which are the chunk-boundary effect: "वॉट वोड
  यू" / "व्ॉट वुड यू" / "एंड ई एम" / "वहाट वुड यू".
- **[V]** The phone's output differs from the laptop's in one word: "वोड"
  versus "वुड" in the 16 s clip. **[I]** This is int8 kernel differences
  between ARM and x86 onnxruntime.
- **[V]** The token table spans several Indic scripts (the first entries are
  Bengali/Assamese). Every Hindi output observed was Devanagari.
- **[?]** Accuracy on real, noisy, long recorder audio is not measured here.
  These clips are either very short or synthetic.

### Memory — [V] measured, and a real concern

Whole-process RSS for the integration-test app (a debug build, so the Dart
side is JIT and heavier than release):

| Point | RSS |
|---|---|
| App idle, before any job | **349 MB** |
| During the first load (sampled externally) | 590 → 676 MB |
| Highest sampled `VmRSS` | **815 MB** |
| Kernel high-water mark `VmHWM` over 20 jobs | **914 MB** |
| After the first job's `free()` and isolate exit | **705 MB** |
| Between later jobs | 668–766 MB, no growth trend over 20 jobs |

- **[V]** Peak process memory is about **0.8–0.9 GB** on a 5.5 GB phone. There
  was no OOM and no low-memory kill.
- **[V]** **Releasing the model did not return the memory to the OS.** RSS went
  from 349 MB to about 700 MB after the first job and stayed there. It did not
  keep growing, so this is retention, not a per-job leak. The laptop shows the
  same shape (130 → 405 MB, flat afterwards).
- **[?]** The cause is unknown. Candidates: the native allocator keeping freed
  pages, onnxruntime arenas, or an mmap of the model that stays resident.
  **This matters for the power rule.** "Load only when transcribing" is
  implemented, but an extra ~350 MB stays resident after the release. It needs
  investigating before this ships. Options include onnxruntime arena settings,
  or running the recognizer in a separate Android process or service that
  exits.
- **[V]** The kernel peak mark cannot be reset from inside the app:
  `/proc/self/clear_refs` is refused. The driver therefore samples `VmRSS` every
  50 ms from the main isolate during a job, and reports before, peak and after.
  That sampling code was changed after the phone run. It was re-verified on the
  laptop only.

## Segmentation

**[V]** The code uses fixed 8 s windows with no overlap
(`WindowPlanner.fixed`), as the brief required: working first, and measured on
the phone.

**[V]** `sherpa_onnx` 1.13.8 ships `VoiceActivityDetector` with Silero and TEN
VAD configs (`vad.dart`, `vad_config.dart`). It needs a second model file (for
example `silero_vad.onnx`, about 2 MB). That file is not cached on this laptop
and was not added.

**[I]** The laptop's 13-point CER swing from grid placement says VAD
segmentation is worth adding next. It fits the existing seams:

- a new planner mode;
- the window list computed inside the worker, which must read the audio anyway;
- the VAD file added to the `SpeechModel` catalogue;
- a speech segment longer than 8 s split by the same 8 s rule.

**[?]** Its CER gain and on-phone cost are not measured.

### Update 2026-09-15 — implemented behind a flag, default still the grid

- **[V]** `silero_vad.onnx` from the sherpa-onnx GitHub release
  (`asr-models/silero_vad.onnx`) is **643,854 B** (≈630 KB, Silero v4), not
  2 MB. Delivered like the ASR model: `files/models/silero-vad/silero_vad.onnx`
  (`SpeechModels.sileroVad`, exact-size check in `SpeechModelStore.isVadReady`).
- **[V]** Off unless built with `--dart-define=STT_VAD=true`
  (`TranscriptionService.useVoiceActivitySegmentation`). With the flag on and
  the file absent or the wrong size, the job carries no VAD and the fixed grid
  is used; if the detector fails inside the worker, the grid is used too.
- **[V]** The worker runs VAD over the WAV (1 s chunks, cancellable), then the
  pure `SpeechWindows.plan` (unit tested): merge, split > 8 s on the grid as a
  backstop, pad 200 ms into silence (never past half a gap), pack consecutive
  segments while the span fits 8 s. Silence between packed windows is not
  decoded. The detector's own `maxSpeechDuration` is set to 8 s so it chooses
  split points in long speech. `minSilenceDuration` 0.25 s (sherpa default 0.5)
  so always-listening's 300 ms inserted pauses are boundaries.
- **[V]** The recognizer reports the new plan with `RecognitionWindowsPlanned`;
  transcript segment times follow the planned windows.
- **[?]** CER against the grid, VAD cost per minute, and whether 0.25 s splits
  words on this speaker are all unmeasured. Measure before changing the
  default.

## Model kept loaded between jobs (2026-09-15)

- **[V] in unit tests with a fake worker, [?] on the phone.** The recognizer
  now keeps ONE worker isolate and ONE loaded model across consecutive jobs
  (`KeepWarmSpeechRecognizer` + the isolate worker in
  `speech_recognizer_sherpa.dart`). The second and later jobs report
  `RecognitionModelLoaded(reused: true)` and a zero load time.
- Freed (native `free()` in the worker, then `mallopt(M_PURGE)`, then isolate
  exit) when: 30 s pass with no job; `releaseModel()` is called; a job needs a
  different config (old freed BEFORE new loaded - never two copies); the
  worker fails. The controller also calls it as soon as the queue drains or
  pauses while the app is off screen (Dart timers are unreliable with the CPU
  asleep), on teardown, and when leaving the app where background work is not
  allowed.
- **[I]** Saves 1.2-4.9 s per note after the first in a run. Cost: the model's
  ~300 MB stays resident for up to 30 s after the last on-screen job.
- The on-device integration tests pass `idleTimeout: Duration.zero`, which
  restores load-per-job, so their numbers stay comparable with the tables above.

## Tests

- **Baseline:** **[V]** 806 passed. `flutter analyze` was clean.
- **After:** **[V]** 830 passed, 1 skipped. `flutter analyze` is clean.
- `test/window_planner_test.dart` covers coverage and non-overlap, the tail,
  and the 8 s / 16 kHz / 80-bin constants.
- `test/speech_recognizer_test.dart` covers PCM conversion, and checks that
  `sherpa_onnx` is imported by exactly one file.
- `test/transcription_service_test.dart` uses a fake engine and in-memory files
  to cover:
  - the job config and windows;
  - text joining and timings;
  - truncated files and empty recordings;
  - bad audio refused before the model is checked;
  - a missing or partial model;
  - engine failure and early stop;
  - one job at a time.
- `test/speech_recognizer_sherpa_test.dart` runs the real engine and the real
  model on the laptop. It is skipped unless `STT_MODELS_DIR` and `STT_WAV` are
  set (plus `LD_LIBRARY_PATH`, see above).
- `integration_test/transcription_on_device_test.dart` is the phone
  measurement. It takes `--dart-define` options `STT_THREADS`, `STT_MATCH`,
  `STT_PASSES` and `STT_IDLE_S`.

## ⚠️ Warning: `flutter test integration_test/…` uninstalls the app

**[V]** `flutter test` on a device **uninstalls the app when the run finishes**.
The `--uninstall` flag defaults to true
(`flutter_tools/lib/src/commands/test.dart:309`). **That wipes the app's private
data.** It happened during this spike and deleted:

- the owner's three recordings on the phone. Laptop copies had been pulled
  first, so they are recoverable;
- `app_flutter/recordings/device-tests.json`, the mic-check history
  (31,586 B). **It had not been backed up and is lost.**
- the pushed model.

**Always pass `--no-uninstall`**, and pull the data first.

**[V]** After the uninstall the Xiaomi refused a *fresh* USB install with
`INSTALL_FAILED_USER_RESTRICTED`. MIUI requires a tap on the phone to confirm
"install via USB". Replacing an already-installed app did not ask. The prompt
cannot be tapped over adb (`input tap` is denied with INJECT_EVENTS).

## Could not verify

- **[?]** **The Developer options card, on the phone.** Developer options are
  only reachable while connected to the recorder, and the recorder was not
  present. The measurement ran through the integration test, which uses the same
  service and driver the card calls. The card itself is analyzed and compiled
  (the string `Transcription spike` was confirmed inside the APK pulled back
  with `adb shell pm path` + `adb pull`, sha1 identical to the build). It was
  never tapped.
- **[?]** Thread scaling at 1 and 6 threads, per-thread CPU placement, and RSS
  after 60 s idle. That run failed because of the uninstall and install
  restriction above.
- **[?]** The rewritten memory sampler, and cancellation, on the phone.
- **[?]** Battery and thermal cost per minute of audio.
- **[?]** Release-build (AOT) numbers. Inference is native, so decode time
  should be similar **[I]**. Baseline RSS will be lower **[I]**.
- **[?]** iOS.

## Restoring the phone

1. Run `flutter install` or `adb install`, and **tap the confirmation on the
   phone**.
2. Push the model (commands above).
3. Restore the recordings from the laptop copies with
   `adb exec-in run-as $P sh -c "cat > app_flutter/recordings/<name>"`.
4. Run
   `flutter test integration_test/transcription_on_device_test.dart -d <id> --no-uninstall`.


---

## The feature (2026-09-14)

### What the user sees — [V] on the phone

Playback screen of a recording (the library is only reachable with the
recorder connected, so on the phone this was driven through
`integration_test/transcript_screen_on_device_test.dart`, which opens the real
`PlaybackView` with the real controller, engine and the owner's recording):

1. **Idle.** The existing purple **Transcribe** chip, bottom right. Nothing is
   loaded or run until it is tapped. Opening the screen only stats and reads
   the saved transcript file, if any.
2. **Running.** A card appears under the title: `HINDI TRANSCRIPT`,
   `Transcribing…`, a percentage, a thin determinate bar and **Cancel**. The
   chip goes away while a transcript exists or is being made.
3. **Done.** The card shows the Devanagari text, selectable, with **Copy**
   (snackbar "Copied."). A long transcript scrolls inside the card, which is
   capped at half the space under the title; the transport and speed row do
   not move off screen.
4. **No speech:** "No speech found." **Model missing:** "The Hindi model is
   not on this phone." (warning colour, with Try again). **Engine failure:**
   "Could not transcribe this recording." (error colour, with Try again).
   **Bad file:** "This recording cannot be transcribed." No exception text is
   ever shown. Tapping Transcribe while another recording is running shows
   "Another recording is being transcribed."

Transcript of `voicenote-20260910-042331.wav` on the phone through the UI:
`चेक चेक ठीक है` — identical to the spike. **[V]**

### How it is built

| Layer | File | Change |
|---|---|---|
| model | `lib/model/transcript.dart` | **New.** `Transcript` (language, model id, created, audio length, segments; JSON v1, parser never throws) and `TranscriptStatus` (checking/none/running/done/noSpeech/modelMissing/unsupported/failed). |
| model | `lib/model/transcription.dart` | `SpeechModel.languageCode` (`hi`). |
| services | `transcription/transcript_store.dart` | **New.** Load/save/delete the sidecar through `FileStore`. A damaged or other-version file reads as "no transcript". |
| services | `library_service.dart` | `RecordingNaming.transcriptPathOf`: `voicenote-X.wav` → `voicenote-X.transcript.json`, same folder. `LibraryService.delete` removes the recording, then its transcript. The library lists `.wav` only. |
| services | `transcription/transcription_service.dart` | `cancel()` — completes only after the engine has released the model; job fails with `TranscriptionFailure.cancelled`, which the UI treats as "back to idle", not an error. Progress reports `0/N` before the load. |
| drivers | `speech_recognizer_sherpa.dart` | Subscription cancel now **waits for the worker isolate to exit** (after its native `free()`), so cancel-then-start can never hold two models. Optional allocator purge after free (below). |
| drivers | `process_memory.dart` | `releaseFreedNativeMemory()` — `mallopt(M_PURGE)` via FFI on Android. |
| controller | `app_controller.dart` | Spike state replaced: `transcribe(recording)` (2 threads, fixed), `cancelTranscription()`, `loadTranscript`, `transcriptFor`, `transcriptStatusFor`. One job at a time. Deleting a recording cancels its job and forgets its transcript; teardown cancels. |
| view | `playback_view.dart` | Chip wired up; `_TranscriptCard`. |
| view | `developer_view.dart` | **Spike card removed.** Replaced by a read-only `LAST TRANSCRIPT` card: audio, load, decode, RTF, memory before/peak/after. No picker, no thread choice, no run button. |

- **Model missing / download later.** The controller maps `modelMissing` and
  `modelIncomplete` to one plain state. `SpeechModelStore.status` is still the
  single check; a downloader only has to fill
  `files/models/indicconformer-hi-int8/` and the card's Try again (or a future
  Download action in the same slot) will then run.
- **Still fixed 8 s windows**, no VAD — as asked.

### Memory — the "350 MB retained" problem, re-measured **[V]**

Same recording (11.5 s), same debug build, whole-process `VmRSS` sampled once a
second from the UI isolate, with the purge off (`STT_PURGE=false`) and on:

| Point | Purge off | Purge on | Purge on (final layout) |
|---|---|---|---|
| Idle, before tap | 373 MB | 375 MB | 372 MB |
| During (peak sampled at 50 ms by driver) | 694 MB | 726 MB | 713 MB |
| Driver's reading at the instant of release | **691 MB** | **405 MB** | **397 MB** |
| UI sample ~1 s after | 455 MB | 420 MB | 412 MB |
| 2–5 s after | 417–418 MB | ~420 MB | ~412 MB |
| 30 s after | 423 MB | 422 MB | 417 MB |
| `dumpsys meminfo` TOTAL RSS at ~30 s | 468 MB | 469 MB | 465 MB |

Findings:

- **[V] The model's memory is NOT retained.** Without the purge the RSS reads
  ~690 MB at the moment of release — that is the number the spike recorded —
  but it falls to ~455 MB within a second and ~418 MB within two, on its own.
  bionic's allocator returns the pages after a short decay.
- **[I] Why the spike saw 668–766 MB "between jobs":** its integration test ran
  jobs back to back and sampled right at release, inside the decay window.
- **[V] `mallopt(M_PURGE)` makes the release immediate** (691 → 405 MB at
  release) but **changes nothing 30 s later** (423 vs 422 MB; meminfo totals
  within 1 MB). It is kept, on by default, because it is cheap and makes the
  "after" figure honest; it is not a fix for a leak, because there was none.
- **[V] The isolate is not the cause:** it exits per job; cancel now waits for
  that exit.
- **[?] Residual ~45–50 MB** above the pre-tap idle figure persists at 30 s in
  both modes. Not attributed. Candidates: Dart heap growth and JIT code in
  this debug build (meminfo "Private Other" ~185 MB, "Code" ~72 MB are the big
  non-graphics buckets), and the new card being rendered. A release (AOT)
  build would be the right place to measure it.

### Tests

- **Before:** **[V]** 830 passed, 1 skipped. `flutter analyze` clean.
- **After:** **[V]** 869 passed, 1 skipped. `flutter analyze` clean.
- New: `test/transcript_store_test.dart` (path, round trip, no-speech,
  replace, damaged/other-version file, delete, not listed as a recording,
  deleting a recording deletes its transcript);
  `test/transcription_controller_test.dart` (nothing runs until asked, saved
  and reloaded without re-running, no speech, model missing and retry, engine
  failure, progress, one at a time, cancel, delete cancels and removes the
  sidecar); cancel tests in `transcription_service_test.dart`; playback view
  in every state (idle / running+cancel / done+copy / reopened / empty /
  failed+retry / model missing / long transcript / short transcript keeps the
  layout / busy elsewhere); developer card is readout-only.
- Test harness: `ScriptedRecognizer` in `test/view/harness.dart`.
- Phone: `integration_test/transcript_screen_on_device_test.dart`
  (`STT_MATCH`, `STT_HOLD_S`, `STT_PURGE`). **Always `--no-uninstall`.** Note
  that `flutter test` on the device replaces the installed app with the test
  build; reinstall the app's debug APK afterwards.

### Could not verify (feature)

- **[?]** The real route to the screen (library → recording) on the phone:
  it needs the recorder connected, and MIUI refuses `adb shell input`, so no
  tap could be injected. The screen itself, the controller and the engine were
  exercised on the phone in-process.
- **[?]** Cancel, Copy, the long-transcript scroll, and the failure states on
  the phone. Unit/widget tested only.
- **[?]** A minutes-long recording on the phone: the owner's longest restored
  recording is 11.5 s.
- **[?] Final install.** After the last on-phone run the phone re-enumerated
  on USB and adb reports "no permissions", so the final debug APK
  (`build/app/outputs/flutter-apk/app-debug.apk`, sha1 `c9a22e0e…2ea5`, the
  tree as left) was not installed. The phone was last seen running the
  integration-test build of the same code (identical `lib/`), with the model
  and the three recordings intact. To finish: replug, then
  `adb install -r build/app/outputs/flutter-apk/app-debug.apk` (a replacement
  install; no uninstall, no data loss), and delete
  `app_flutter/recordings/voicenote-20260910-042331.transcript.json` if the
  untranscribed state is wanted back.

---

## English, and notes with nothing in them (2026-09-15)

### The problem — [V] on the laptop

IndicConformer-hi writes English speech as Devanagari transliteration. The
owner's English note `voicenote-20260915-022908.wav` came out as
`थेश शुड बे गुड तो थे चट` ("The case should be good to touch ...").

### Evaluation — [V] laptop, sherpa-onnx 1.13.8 (Python), 2 threads

Scripts, per-window outputs and numbers:
`/tmp/claude-1000/-home-ganesh-personalProjects-nrf52840-sense/fa512cd6-0d57-4e9e-8bee-96c6a922220e/scratchpad/lang/`
(`ev.py` runs a model over 8 s windows into `out/asr.jsonl`; `route.py` is the
router; `lid.py` / `out/lid_*.jsonl` is the Whisper language-ID attempt).
Scratch space: it will not survive a reboot.

- Candidates run on the owner's 20 recordings plus the Hinglish TTS clip:
  Whisper tiny/base/small/turbo (+ `.en`), Moonshine tiny/base, Parakeet TDT
  0.6B v2/v3 and 110M, Zipformer GigaSpeech, Omnilingual 300M, Dolphin small,
  Qwen3-ASR 0.6B.
- **Whisper language ID per 8 s window was unreliable** on this audio
  (`lid_small_r.jsonl`: Hindi windows labelled `nn`, `ur`, `fr`, `pt`, `ta`),
  and it costs another model load.
- **Parakeet TDT 110M en int8** was chosen for English: good on the English
  windows ("is play some video and you know get into the details of Linux
  device driver."), 0.77 s load, +189 MB after load and ~+300 MB peak over
  base (IndicConformer: +256 / ~+345 MB), mean RTF 0.020 vs IndicConformer
  0.031 on the laptop. The 0.6B Parakeets need ~+870 MB: too big.
- **Router: Hindi function-word density** in IndicConformer's own output.
  Every Hinglish note scored 0.24–0.60; the English note 0.00. The
  English-heavy Hinglish TTS clip scored 0.16 (window 1: 0.09) and stays
  Hindi, which is what the owner wants for Hinglish.

### The design — [V] unit tests; [V] real engine on the laptop through Dart

| Setting | What runs |
|---|---|
| **Auto** (default) | IndicConformer on every window. `LanguageRouter.route` labels each window. If any is English: IndicConformer is **freed** (`releaseModel`, M_PURGE kept), then Parakeet decodes **only** the English windows (the same sample ranges, VAD-planned or grid). |
| Hindi | IndicConformer only - the behaviour before this change. |
| English | Parakeet on every window; IndicConformer is neither checked nor loaded. |

Router (`lib/model/language_router.dart`, ported from `route.py`):

- Words: split on whitespace (as `route.py`), punctuation trimmed from each
  end, punctuation-only tokens dropped (a deviation `route.py` never needed:
  IndicConformer emits no punctuation). Numbers count as words.
- The 59-word list is `route.py`'s exactly; थे and तो are deliberately absent
  (English "the"/"to").
- A window with **≥ 5 words** is English when density **< 0.08**.
- A window with 1–4 words follows the note: English when the whole note has
  ≥ 5 words and density < 0.08.
- A window with **no words stays Hindi** and is not re-decoded (deviation from
  "< 5 words follow the note": decoding silence again costs battery and gave
  empty text on the laptop too).

Missing English model in Auto: the Hindi text is kept and the transcript
records `englishModelMissing: true` (nothing on screen says so yet; the copy
will be "Add the English model to transcribe English"). English setting with
the model missing fails as `modelMissing`, like a missing Hindi model. A
failure of the English pass fails the whole job (saved as `failed`).

Transcript (still format v1, older builds read it): segment `lang` (`hi`/`en`)
and `model` (model id), both optional; transcript `language` is `hi` or `en`
when every spoken segment is that language, `auto` when they mix; `model` is
the id, or both joined with `+`. Progress in Auto counts on past the first
pass: `N/(N+k)` to `(N+k)/(N+k)`.

Engine: `RecognizerConfig`/`RecognitionJob` carry the architecture and the
decoder/joiner paths; the sherpa driver loads a transducer with
`OfflineTransducerModelConfig(encoder, decoder, joiner)` +
`modelType: 'nemo_transducer'`. `KeepWarmSpeechRecognizer` already frees the
old worker before spawning one for a different config, so a queue that
alternates models never holds two.

Laptop run through the app's Dart service and real engine
(`test/speech_recognizer_sherpa_test.dart` with `STT_LANGUAGE`):

- `voicenote-20260915-022908.wav`, Auto: window 1 → `en`, "The case should be
  good to touch at no sharp comments for you."; silent window 2 stays `hi`.
- `20260906-180032_s11.wav`, Auto: `hi, en, hi, en` - "हेलो सो ई एम ... पहला जो
  मेरे को काम करना है दैट / is play some video and you know get into the details
  of Linux device driver. / नेक्स्ट मेरे को ये करना है ... / And yeah, that should
  be it". Wall 2.3 s for 28 s of audio (two loads).
- Same file, English: all four windows Parakeet; Hindi: all four
  IndicConformer - both as expected.

**[?] Not measured on the phone:** Parakeet's load time, RTF and RSS; the
extra load per mixed note (~0.8–1.2 s [I]); whether the M_PURGE release
between passes keeps the peak at one model's size on Android.

### Model delivery (English)

Not bundled. Unpack the sherpa-onnx release
`sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8.tar.bz2`
(GitHub `k2-fsa/sherpa-onnx`, tag `asr-models`) and push these four files.
The app checks exact sizes (`SpeechModels.parakeetTdtEnglishInt8`):

| File | Bytes | sha256 (laptop copy) |
|---|---|---|
| `encoder.int8.onnx` | 131,113,202 | `0f35509d…1d657` |
| `decoder.int8.onnx` | 3,955,863 | `f7c331c5…1da19` |
| `joiner.int8.onnx` | 1,411,403 | `bf7dff69…2f6` |
| `tokens.txt` | 9,953 | `450e56bd…cd10` |

```sh
cd sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8
P=com.ganeshsharma.voicenotetaker_app
D=files/models/parakeet-tdt-110m-en-int8
adb shell run-as $P mkdir -p $D
adb exec-in run-as $P sh -c "cat > $D/encoder.int8.onnx" < encoder.int8.onnx
adb exec-in run-as $P sh -c "cat > $D/decoder.int8.onnx" < decoder.int8.onnx
adb exec-in run-as $P sh -c "cat > $D/joiner.int8.onnx"  < joiner.int8.onnx
adb exec-in run-as $P sh -c "cat > $D/tokens.txt"        < tokens.txt
adb shell run-as $P sh -c "'chmod 700 files/models $D && chmod 600 $D/*'"
adb shell run-as $P ls -l $D   # sizes must match the table
```

### Notes with nothing in them

- **Rule** (`lib/model/empty_note_policy.dart`, pure): a note whose
  transcription **succeeded** and found nothing in any window (every segment
  empty after trimming) is deleted - WAV, transcript and every sidecar -
  unless marked Keep. Never on a saved failure or no transcript. Deferred
  while it is written, while a manual recording runs (any capture: the
  recorder does not expose its path), while it is open in the note screen or
  playing, or while it is transcribed.
- **Crash-safe** (`lib/services/empty_note_service.dart`): the marker
  `voicenote-X.empty-note.json` is written when the transcript is saved empty
  (and before any file goes), removed last by `LibraryService.deleteFiles`.
  Every start sweeps marked notes; a marker beside a note that now has words,
  a Keep or a failure is dropped. A delete killed half way finishes next start
  (audio and transcript both gone ⇒ only sidecars left).
- **One-time sweep:** the first start with this build also reads every saved
  transcript and applies the same rules, then writes
  `empty-notes-sweep.json` in the settings directory.
- **Controller:** `noteOpened`/`noteClosed` (called by `NoteView`
  `initState`/`dispose`) defer; the sweep re-runs on note close, recording
  stop, transcription end and return to the app, only while something is
  pending. Deleted notes leave the queue, the caches and the library (one
  refresh).

### Tests

- Before: 1189 passed, 1 skipped.
- New: `language_router_test.dart` (laptop windows: Hinglish, English,
  mixed, short-follows-note, boundaries, punctuation/numbers),
  `transcript_language_test.dart` (v1 back-compat both ways, catalogue sizes,
  config equality, setting store), `transcription_language_service_test.dart`
  (swap order hi → release → en, subset windows, VAD windows, missing/partial
  English model, English and Hindi modes, English-pass failure and cancel,
  keep-warm frees before loading), `empty_note_policy_test.dart`,
  `empty_note_service_test.dart` (marker, one-time sweep, keep/failure/words,
  defer and re-check, kill recovery, failed delete),
  `empty_notes_controller_test.dart` (after transcription, open until closed,
  restart, start sweeps, language persistence and English mode), and the note
  screen's "no speech found" now checks the note goes only after the screen
  closes. Three older tests were adjusted because empty notes are now deleted.

## Who said what — speaker separation (2026-09-16)

### The problem

A meeting note transcribed as one wall of text is hard to read and impossible
to act on: "who agreed to that?" is the question the note is for. Separation is
offline like everything else here — nothing leaves the phone.

### The spike — [V] laptop, sherpa-onnx 1.13.8 (Dart)

`sherpa_onnx` 1.13.8 has `OfflineSpeakerDiarization`, `processWithCallback`
(progress), `FastClusteringConfig(numClusters, threshold)` and
`windowShiftRatio`. Two models, both needed:

| File | Bytes | sha256 |
|---|---|---|
| `segmentation.onnx` (pyannote segmentation-3.0, FLOAT) | 5,992,913 | `220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079` |
| `campplus.onnx` (3D-Speaker CAM++ zh_en advanced) | 28,281,164 | `aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2` |

**The FLOAT segmentation model on purpose:** its int8 export misses quiet
speech — a second voice answering softly is simply not there — and 4.5 MB is
not worth that.

Settled defaults (`DiarizationModels.pyannoteCamPlus`): `threshold` 0.9,
`windowShiftRatio` 0.5, `minDurationOn` 0.3 s, `minDurationOff` 0.5 s.
Expected phone cost about **0.10x real time on top** of the ~1x the speech
model already costs — a tenth more, which is what the progress bar is told.

### The design

**Order, and it is load-bearing.** Separate FIRST, over the whole recording,
free everything, and only then load the speech model. The diarizer's two
networks (34 MB) plus the recording as floats (4 bytes a sample — 38 MB for
ten minutes, and the engine copies it natively) must never be resident
alongside a 188 MB speech model. `TranscriptionService._separateSpeakers`
therefore calls `SpeechRecognizer.releaseModel()` BEFORE the diarizer starts
(the keep-warm recognizer may still be holding the previous note's model), and
the diarizer's worker isolate frees its models, runs `mallopt(M_PURGE)` and
exits before `DiarizationFinished` is even delivered. The order is a test:
`recognizer.release`, `diarizer.run`, `diarizer.release`,
`recognizer.transcribe`.

**Cleaning up what the engine said** (`lib/model/speaker_turns.dart`, pure, one
test per rule):

1. overlapping turns are cut at the middle of the overlap — a window can only
   be decoded once — and a turn sitting wholly inside another leaves the rest
   of that turn behind it;
2. the same speaker either side of a pause under **1 s** is one turn;
3. a turn under **1 s** is folded into a neighbour — the closer one, on a tie
   the longer one;
4. a speaker heard for under **2 s** in the whole note is not a speaker, and
   is folded away the same way;
5. boundaries are stretched so **no audio is dropped**: the first turn starts
   at 0, the last ends at the end, and every gap is split at its midpoint;
6. whatever became the same speaker back to back is merged.

**Windows** (`SpeakerTurns.plan`): one per turn, so a window never spans two
people. A turn longer than the speech model's 8 s window is cut at the
**quietest 200 ms between 6 s and 8 s** from its start, found in a loudness
profile the service builds by reading the WAV 40 kB at a time (one mean
absolute value per 20 ms — about 25 kB for a ten-minute note,
`lib/model/loudness_profile.dart`). Without a profile the cut falls on 8 s,
which is what the fixed grid always did. Voice-activity segmentation is NOT
run as well: the turns already end in pauses, and it would cut across
speakers.

**Labels.** `S1`, `S2`, … in the order people first speak — not the
clustering's own numbering — so they are stable within a note. Stored in the
transcript's segments (`speaker`), which `Transcript` v1 has always allowed,
so no format bump and no note transcribed twice. **One speaker means NO
labels at all:** the note reads as plain paragraphs rather than "Speaker 1" in
front of every one of them.

**Language routing is unchanged** and still per window, so an English turn is
decoded again by Parakeet and keeps its speaker.

**Progress.** The separation pass is worth a tenth of the job, matching what it
costs: `steps = ceil(gridWindows / 10)`, at least 1, and the fraction is
`(steps + windowsDone) / (steps + windows)`. The TOTAL moves once, when the
turns replace the fixed grid and there turn out to be a different number of
windows — the English pass already moved it the same way.

**Nothing installed, nothing said.** No diarizer, models missing or
half-pushed, the engine failing, or nothing heard: the pass is skipped
silently and the note is transcribed exactly as it was before this existed.
Only a cancel is passed on.

### The controller API

- `speakerLabels(path)` / `speakerLabelsFor(path)` — the note's labels, in the
  order they first speak; empty when the note has none.
- `speakerCountFor(path)` — the stored override: null (Auto), 2, 3 or 4, where
  **4 means "four or more"** (the clustering takes a number, and five voices
  split into four still reads far better than one wall of text).
- `setSpeakerCount(path, count)` — saves it and **re-transcribes**. The turn
  boundaries move when the count changes, so the windows move, so the words
  have to be decoded again: there is nothing safe to reuse. A note whose audio
  the 24 h sweep removed keeps the choice and runs nothing.
- `mergeSpeakers(path, from, into)` — rewrites the saved transcript at once
  (no audio is touched) and remembers the merge, so a transcript made again
  comes back merged the same way. Merging into a label that was itself merged
  follows the chain. A merge that leaves ONE speaker leaves the note with no
  labels, like a note the engine only ever heard one person in.
- `renameSpeakers` / `speakerNamesFor` are unchanged; names and merges are
  different things and survive different events.
- Both are read by `loadSpeakerNames(path)` (and the count also by
  `loadTranscript`), and live in
  `voicenote-X.speaker-settings.json` beside the recording — a sidecar, so
  transcribing again cannot lose them, and `LibraryService.deleteFiles`
  removes it with the note.
- `transcriptionProgressFor(path)` — how far the job on that note has got,
  0..1, or null when it is not the one running. The re-run a count starts IS a
  transcription, and the separation pass and the decoding report through the
  same `onProgress`, so this one figure covers both passes. 0 rather than null
  until the recording has been measured: the job is running, it just has
  nothing to say yet.

### What the Speakers sheet is wired to — [V] 2026-09-16

The sheet (`lib/view/speakers_sheet.dart`) talks to `SpeakersController`, and
`AppControllerSpeakers` (`lib/controller/speakers_controller.dart`) is that
interface over the controller above — plain delegation, method for method,
with nothing about a speaker cached in the adapter. `detectionProgressFor` is
`transcriptionProgressFor`. So the labels the sheet shows are the saved
transcript's, the count and the merges are the sidecar's, and a re-run that
rewrites either redraws both the sheet and the note screen off one
`notifyListeners`.

### Model delivery (speakers)

Not bundled. From the sherpa-onnx GitHub release `k2-fsa/sherpa-onnx`:
`speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2`
(use `model.onnx`, NOT `model.int8.onnx`) and
`speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`
(sic — the release tag is spelled that way). The app checks exact sizes
(`DiarizationModels.pyannoteCamPlus`).

```sh
P=com.ganeshsharma.voicenotetaker_app
D=files/models/diarization
adb shell run-as $P mkdir -p $D
adb exec-in run-as $P sh -c "cat > $D/segmentation.onnx" \
  < sherpa-onnx-pyannote-segmentation-3-0/model.onnx
adb exec-in run-as $P sh -c "cat > $D/campplus.onnx" \
  < 3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
adb shell run-as $P sh -c "'chmod 700 files/models $D && chmod 600 $D/*'"
adb shell run-as $P ls -l $D   # 5992913 and 28281164 bytes
```

### Real engine on the laptop — [V] 2026-09-16

`test/speaker_diarizer_sherpa_test.dart`, the same shape as the recogniser's:

```sh
LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
STT_MODELS_DIR=/path/containing/diarization STT_WAV=/path/to/16k-mono.wav \
STT_SPEAKERS=3 \
  flutter test test/speaker_diarizer_sherpa_test.dart
```

(`LD_LIBRARY_PATH` is needed only for a host test: `flutter test` does not
bundle the native library the way an APK does.)

The Dart configuration loads this pair and separates off the calling isolate.
On the three recordings that were still on the laptop — all of them ONE voice,
the owner's — it answered one speaker every time, which is right:

| File | Length | Raw turns | Clusters | After cleanup | RSS before → peak → after |
|---|---|---|---|---|---|
| `voicenote.wav` | 20.1 s | 3 | 1 | 1 speaker | 129 → 246 → 217 MB |
| `fresh.wav` | 19.9 s | 2 | 1 | 1 speaker | 130 → 257 → 215 MB |
| `from_phone.wav` | 7.6 s | 2 | 1 | 1 speaker | 129 → 220 → 210 MB |

Two of them joined end to end (27.7 s, the same voice through two different
microphones) reads as **one** speaker on Auto — the threshold is doing its job
— and as **two** when the count is forced, split at 23.1 s against a true join
at 20.1 s. So the count override reaches the engine and changes the answer.
Asking for three on that file returns two: the engine gives what it can find,
it does not invent a third.

⚠️ **No two-person recording was available** (the spike's `rec/` and
`rec-0915/` were gone from this machine), so how well it tells two REAL people
apart is still unverified outside the spike's own report. The memory figures
are a Linux test VM, where `M_PURGE` does nothing — the phone's are the ones
that matter and have not been measured.

### Honest limits

- **Fast back-and-forth fails.** One-second exchanges are exactly what rules 3
  and 4 above fold away, on purpose: a label that flickers mid-sentence is
  worse than no label. A quick "haan… theek hai" from the other person will be
  attributed to whoever was talking around it.
- **Overlapping speech is a guess.** The overlap is cut down the middle and
  given half to each; nobody is transcribed twice, so one of the two voices is
  lost wherever they truly overlap.
- **Long notes over-split.** The clustering sees a voice change with the
  microphone, the room and the distance; an hour-long note can grow a speaker
  that is really the same person further from the recorder. That is what
  "How many people?" and merging are FOR, and why both are remembered.
- **Neither model was trained on Hindi.** CAM++ `zh_en` is Chinese and
  English; pyannote segmentation is multilingual but not tuned for Hindi or
  Hinglish. Voices still separate on timbre rather than words, so it works —
  but nobody has measured how well on Hindi, and it should be expected to be
  worse than the English numbers published for these models.
- **A note whose audio has been swept cannot be separated again**: the words
  are all that is left.

### Tests

- Before: 1417 passed, 1 skipped. After: 1499 passed, 1 skipped. Wiring the
  sheet to it (merged with the speakers UI): 1550 passed, 2 skipped.
- New: `speaker_turns_test.dart` (every cleanup rule, label stability, window
  planning and the 6–8 s split point, the loudness profile),
  `speaker_settings_test.dart` (count range, merges including into an
  already-merged label, chains and loops from a damaged file, the sidecar),
  `speaker_diarization_service_test.dart` (the whole pipeline with a fake
  diarizer: windows from turns, one-speaker suppression, count passed through,
  the quiet split point, no audio dropped, VAD not run as well, the memory
  order, progress fractions, missing/half-installed models, engine failure,
  English routing per turn), `speaker_controller_test.dart` (labels, count
  persistence and re-run, restart, audio gone, merges and their survival
  across a re-run, names untouched) and `speaker_diarizer_sherpa_test.dart`
  (the real engine, skipped without models).
- Wiring the sheet added `test/view/speakers_pipeline_test.dart` (the sheet
  over a real note screen and a real controller: a count re-runs detection and
  reports its progress, a merge rewrites the saved transcript, one person left
  takes the chips and Edit away) and grew
  `test/view/speakers_controller_test.dart` with the delegation itself.
- `speech_recognizer_test.dart`'s "sherpa_onnx is imported by exactly one
  file" is now "by the two driver files": the diarizer is the second, and the
  rule it protects — one file per engine seam — is unchanged.

## Downloading the models (2026-09-18)

### The problem

`adb push` is not a thing on an iPhone. Without a download there is no way for
a user — any user, on either platform — to get the model files onto the device,
so transcription and speaker detection existed only on a phone somebody had
plugged into this laptop.

### Where they are hosted — [V]

**Our own GitHub release, one uncompressed asset per file**, at
`releases/download/models-v1/<set>--<file>`. The full reasoning is in
`doc/models.md`; the short version is that the upstream files are `.tar.bz2`
archives, and unpacking a 197 MB member on the phone would cost minutes of
pure-Dart bzip2 and a second 200 MB copy in memory — on the same device this
document already records a 350 MB retained-memory problem on. Re-hosting per
file removes the step entirely: stream to disk, check one sha256, rename. It
also unifies two upstream shapes, because the Hindi model is not in a
sherpa-onnx release at all (Hugging Face) and the embedding model is a bare
`.onnx`.

**[V] Verified against the real host on 2026-09-18** with
`tool/verify_download.dart`, driving the real `ModelDownloadService` over the
real internet: a GitHub release asset answers unauthenticated, the 302 to
`release-assets.githubusercontent.com` **keeps the `Range` header**, a download
stopped on purpose at 9,432,013 of 28,281,164 B resumed from that byte, the
sha256 matched (`aa3cfc16…ceba2`) and the file landed under its final name with
no `.part` left behind. 28 MB in about a second on this connection.

The catalogue's hashes and sizes were all computed from the real files on this
laptop and match the tables above, file for file.

### How it is built

| Layer | File | Role |
|---|---|---|
| model | `lib/model/model_download.dart` | the catalogue (sha256 + URL only — names and sizes come from `SpeechModels`/`DiarizationModels`), `ModelInstallStatus`, `ResumePlan`, failure copy |
| drivers | `download_client.dart` | abstract ranged GET; `IoDownloadClient` over `dart:io`. No `http`, no `dio` |
| drivers | `hashing.dart` / `hashing_crypto.dart` | chunked sha256; the only file naming `package:crypto` |
| drivers | `network_status.dart` / `network_status_connectivity.dart` | Wi-Fi or mobile; the only file naming `connectivity_plus` |
| drivers | `disk_space.dart` / `disk_space_channel.dart` | free bytes, over the app's own `…/storage` channel (`StatFs` / `attributesOfFileSystem`) |
| services | `transcription/model_download_service.dart` | the download |
| services | `transcription/model_download_settings_store.dart` | the mobile-data choice |
| controller | `app_controller.dart` | per-feature status; the transcription queue is re-planned when a model lands |
| controller | `models_controller.dart` | the seam a screen is built against |
| tool | `tool/publish_models.sh`, `tool/verify_download.dart` | publishing a release, and checking one |

Design decisions:

- **A half file is never a model.** Bytes land in `<name>.part` and take the
  engine's name only after the sha256 matches, by a rename inside one
  directory. The `.part` file IS the resume state — there is no journal to fall
  out of step with it — and a `.part` longer than the file it claims to be is
  thrown away rather than resumed.
- **A wrong hash is discarded, not resumed.** Resuming corrupt bytes only
  wastes the rest.
- **Free space is checked before the first byte**, counting only what is still
  to come, with 64 MB of headroom. A platform that will not say lets the
  download run: losing the feature on a phone that cannot answer is worse.
- **Wi-Fi only by default**, with an explicit override the app remembers.
- **It does not run off screen, on EITHER platform.** iOS suspends the process
  anyway, and the Android foreground service is the recorder's, not this.
  `appBackgrounded` pauses, `appForegrounded` resumes from the same byte. One
  behaviour to explain rather than two.
- **[V] The app had no `INTERNET` permission.** It was in the *debug*
  manifest only, where the Flutter tool puts it for hot reload, so a release
  build could not have downloaded anything. It is now in the main manifest,
  with a comment saying the models are the only thing this app ever fetches.
- **`SpeechModelStore` was extended, not duplicated:** `directoryNamed`,
  `releasePathOf`, `partPathOf`, `missingFiles`, `installedBytes`. The
  downloader and the loader run the same presence-and-exact-size check, so they
  cannot disagree about what "installed" means.

### The controller API

- `modelStatuses` / `modelStatusFor(feature)` — per FEATURE, not per file:
  `notInstalled`, `downloading` (with `progress`, `bytesDone`, `bytesTotal`,
  `currentFileName`, `paused`), `verifying`, `installed`, or `failed` with a
  `ModelDownloadFailure` that already carries the sentence to print.
- `downloadModel(feature)` / `cancelModelDownload(feature)` /
  `deleteModel(feature)` / `refreshModels()`.
- `installedModelBytes` — what the models take up, for a Storage line.
- `downloadOnMobileData` / `setDownloadOnMobileData(bool)` — false until the
  user says otherwise, kept in `model-download-settings.json`.
- `ModelsController` (`lib/controller/models_controller.dart`) is that
  interface with nothing else on it; `AppControllerModels` is plain delegation,
  exactly like `AppControllerSpeakers`.

**Work that was blocked resumes by itself.** The controller watches the
downloader; the moment a set reports installed it re-plans the transcription
queue, so notes that piled up unqueued while the model was missing start
transcribing with nothing tapped.

### Tests

- Before: 1553 passed, 2 skipped. After: 1619 passed, 2 skipped.
- New: `model_catalogue_test.dart` (ids unique, one set per feature, every
  hash a real 64-hex sha256, every URL this release, asset names unique across
  sets, totals, the catalogue and the engine holding the SAME size objects,
  every `ResumePlan` rule, progress clamping, the failure copy and
  `formatBytes`); `model_download_service_test.dart` (clean install, state
  order, monotonic progress, skipping installed files, resume from a `.part`,
  an over-long `.part` discarded, a complete `.part` verified not re-fetched,
  a mid-transfer break retried from the byte it stopped on, a server that
  ignores `Range`, giving up after the attempts, a wrong sha256 and a wrong
  length both discarded, disk-full, the disk that will not say, only the
  remaining bytes counted, the Wi-Fi gate in all four network states, cancel
  keeping what arrived, cancel then resume, no two jobs for one set,
  pause/resume on leaving and returning, delete, and the refresh that finds a
  set pushed in by cable); `model_downloads_controller_test.dart` (what the
  screen is told, the adapter's delegation, the mobile-data choice and its
  persistence, a note transcribing itself when the model lands, and a
  background/foreground round trip).
- **No network in the suite.** The one real download is
  `tool/verify_download.dart`, run by hand.

### Could not verify

- **[?]** The iOS half of the storage channel (`AppDelegate.swift`) is not
  compiled here — there is no macOS on this machine. The Android half builds.
- **[?]** No download has been run on a phone: the release the catalogue points
  at does not exist yet, and creating it is the owner's call (`gh release
  create`, see `doc/models.md`). What has been proved is the scheme, against a
  real GitHub release asset of the same size as one of the files.
- **[?]** The VAD model (`silero-vad`, 644 kB) is NOT in the catalogue. It is
  off unless built with `--dart-define=STT_VAD=true`, so nothing asks for it
  yet; it wants an entry before that flag is turned on.

## The decode window: 8 s → 16 s (2026-09-19)

### The problem

`MAX_WINDOW_S` was 8 s and had been since the first spike, where it was chosen
because a long clip decoded in one call comes back with its middle missing. Why
*eight*, rather than any other length short enough to avoid that, was never
measured — it was the number the prior research happened to use.

### What was measured — **[V]**, by an evaluation agent, not here

The harness, every run and the prose are in
`/home/ganesh/personalProjects/notetaker-data/accuracy-20260918-205506/`
(`RESULTS.md`, `RECOMMENDATIONS.md` §0). It is this app's own pipeline ported to
Python against the same sherpa-onnx 1.13.8 and the same int8 IndicConformer
export: the same window planner, the same `SpeakerTurns.clean`, the same
quiet-point splitter, the same router.

| window | gramvaani-300, human refs, router off: WER / CER | MUCS code-switched WER | owner's notes, SHIPPED diarize-then-decode path: WER / CER / decodes | peak RSS, one note |
|---|---|---|---|---|
| **8 s** (shipped until now) | 30.45 / 15.74 | 52.05 | 59.41 / 52.90 / **189** | 432 MB |
| 12 s | 28.83 / 14.62 | — | — | — |
| **16 s** (now) | **28.65 / 14.49** | **50.73** | **57.53 / 50.62 / 116** | 509 MB |
| 24 s | 28.70 / 14.43 | — | — | 549 MB |
| 30 s | 28.63 / 14.42 | — | — | 735 MB |

16 s is the knee: past it accuracy stops moving and memory does not. It is the
largest single accuracy change in that whole report, and it makes the phone do
**less** work — 189 decodes become 116 on the same notes, because a speaker turn
that used to be cut in two is now decoded whole.

### What changed in the app

- **One constant.** `lib/model/decode_window.dart`: `DecodeWindow.standard`
  (16 s), with that table in its doc comment. Both `SpeechModel` catalogue
  entries take their `maxWindow` from it, so the grid
  (`WindowPlanner.forModel`), the speaker-turn splitter
  (`SpeakerTurns.planForModel`) and the voice-activity cap
  (`VadSegmentation.maxWindowSamples`) are all sized from the one number.
- **The job's window is decided once**, at the top of
  `TranscriptionService._run`, and passed down. Nothing below re-derives it.
- **The splitter's hunt was checked, and its floor left alone.**
  `SpeakerTurns.splitFrom` stays 6 s, so a turn over the window is now cut at
  the quietest 200 ms between **6 s and 16 s** instead of between 6 s and 8 s.
  Two reasons, written in the comment there: 6 s is the shortest piece worth
  decoding on its own, which the window's length does not change; and a wide
  hunt is what lets a 24 s turn be cut near its middle in a real pause rather
  than at 16 s leaving an 8 s tail. It is also the exact range the 16 s figures
  above were measured with (`diar16`), and the decode count fell 39 % under it,
  so it is not producing needlessly short windows.
- **The router did not move.** It reads text, not time. The longer window helps
  it anyway: on gramvaani, 8 s → 16 s cut the windows wrongly sent to English
  from 47 to 17 on its own. `minWords` is a floor on evidence, not on duration.
- **Progress accounting** needed nothing: it has always counted planned windows,
  and the speaker pass's share is a tenth of *that* count.

### Memory — the risk, reasoned and then measured **[V]**

What actually scales with the window:

- **The audio buffer**, linearly: `readSync(window.length * 2)` then a
  `Float32List` of the same samples. 8 s is 0.75 MB, 16 s is 1.5 MB. Nothing.
- **Features**, linearly: 80 bins every 10 ms, 256 kB at 8 s, 512 kB at 16 s.
- **The encoder's activations**, worse than linearly — a conformer's attention
  matrix is O(T²) in the window's frames. This is the real cost, and it is paid
  inside onnxruntime's arena, which sizes itself to the **largest** shapes it has
  ever seen and does not give them back. So the window sets a floor on RSS for
  the rest of the job.
- **Nothing else.** The recogniser holds one model (unchanged, 188 MB), one
  stream at a time, and is freed the same way. The loudness profile, the
  diarizer and the WAV reader are sized by the recording, not the window. The
  VAD detector's ring buffer is `2 × window + 2 s` — 1.2 MB against 0.6 MB, and
  it is off by default.

Measured here on this laptop, same harness, real owner notes, `VmHWM` of a
process that decoded exactly one note:

| note | path | 8 s | 16 s | 24 s |
|---|---|---|---|---|
| `…210618` (172 s) | fixed grid, decode only | 413 MB (22 windows) | **503 MB** (11) | 530 MB (8) |
| `…210618` (172 s) | diarize-then-decode (shipped) | 403 MB (28) | 405 MB (17) | — |
| `…164616` (147 s) | diarize-then-decode | 396 MB (22) | 422 MB (13) | — |
| `…124222` (144 s) | diarize-then-decode, English pass too | 359 MB (22) | 419 MB (14) | — |

The grid row reproduces the evaluation's +77 MB (here +90 MB). The interesting
row is the shipped one: **on the diarize path the extra costs less** — 2 to
60 MB rather than 90 — because the diarization pass, which holds two networks
and the whole recording as floats, has usually already set the high-water mark
the decode then fits inside.

### The guard — **[V]** unit tested, **[?]** never yet triggered on a phone

Known: the app peaks near **700–726 MB** on the owner's Xiaomi during a job
(debug build, idle 373 MB), and a background isolate can be killed. So the
window is not unconditional:

- `ProcessMemory.availableKb()` reads `MemAvailable` from `/proc/meminfo` —
  system-wide, which is what the kernel weighs when it picks something to kill.
- `DecodeWindow.forAvailableMemory` returns `lowMemory` (8 s — what shipped for
  months, 3.4 WER worse, known to run inside the budget) below
  **512 MB** free, and `standard` otherwise.
- **`null` means the full window.** iOS and desktop have no `/proc`; every
  measurement motivating the fallback is Android's.
- It is read **once per job**, before anything is loaded, so it sees the phone's
  state and not this job's.

What was *not* built: a "the last job was killed, back off" memory. The
transcription queue is in-memory only, so knowing that would mean persisting a
job-started marker and a new class of stale state. The free-memory check is the
cheaper 90 % of it. If the phone ever does report a killed job,
`DecodeWindow.lowMemoryBelowKb` is the number to move first.

### Tests

`decode_window_test.dart` (the constant, both models cut from it, the
threshold's edges, unknown memory); `speaker_turns_test.dart` (a 17 s turn
splits once, a 15 s one does not, exactly 16 s is not split, the hunt is
6–16 s, no piece under the floor, the low-memory window);
`window_planner_test.dart` and `transcription_service_test.dart` (the grid, and
a job short of memory planning five short windows with progress to match). The
fixtures in `transcription_language_service_test.dart` and
`speaker_diarization_service_test.dart` moved to a 40 s note, so every one of
them still means what it used to relative to the window.

### Could not verify

- **[?] Peak RSS on the phone at 16 s.** Everything above is x86. The number to
  watch is `LAST TRANSCRIPT`'s peak in the developer card on a long, multi-speaker
  note — near 800 MB is expected, and a job that dies instead of finishing is
  the signal that `lowMemoryBelowKb` is set too low.
- **[?] The low-memory fallback on a real phone.** It is unit tested; no Android
  device has reported under 512 MB free here.
