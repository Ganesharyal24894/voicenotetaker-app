# On-device Hindi speech-to-text — feasibility spike

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
