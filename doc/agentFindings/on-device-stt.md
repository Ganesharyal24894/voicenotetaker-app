# On-device Hindi speech-to-text — feasibility spike, then the feature

> **Update 2026-09-14 (later the same day): the spike is now a feature.** See
> *The feature* at the end. The spike sections below are kept as the record of
> what was measured; where they are out of date, the new section says so.

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
- **[I]** A download-on-demand path only has to fill that directory. The
  existing `SpeechModelStore.status` reports ready, missing or incomplete. The
  downloader should verify a sha256 once, when the download finishes. The
  runtime check is size only.
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
