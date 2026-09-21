# Research — where it lives

**The archive is in the firmware repo:
`/home/ganesh/personalProjects/nrf52840-sense/doc/research/`.**

One archive, not two, because most of what was investigated crosses the
boundary: the decode window is an app constant chosen by a laptop harness, the
speech gate is firmware tuned against the app's own recordings, and the codec
question is answered with the app's ASR pipeline. Splitting it would have meant
deciding twice where each finding belonged.

## The rule

> **Every investigation ends with a committed summary in the firmware repo's
> `doc/research/`.** Raw data may live outside git; the findings may not.

Research used to live only in `/home/ganesh/personalProjects/notetaker-data/`,
which is **not version controlled**, and a temp directory has already destroyed
work twice. The master TODO across both repos and the hardware is
`nrf52840-sense/doc/todo.md` — **the app's rows there are currently marked
paused**.

## What is over there that decided things in *this* repo

| File | Why an app session cares |
|---|---|
| `stt-on-device-and-window.md` | Why `lib/model/decode_window.dart` is 16 s: the largest measured accuracy win, and it costs 43–48 % *fewer* decodes. Also why `STT_VAD` stays off, and why Dolphin is ruled out |
| `language-router.md` | What is wrong with the shipped English test, the ~90-line fix that is written but **not merged**, and exactly what blocks it (ten hand-typed gold clips) |
| `diarization.md` | Speaker turns beat the fixed grid by ~4 WER and cost RTF 0.016–0.031 — but the threshold that suits a 4-minute note gives **27 speakers** on a one-hour one |
| `window-silence-skip.md` | Why `lib/model/speech_presence.dart` skips almost nothing: the app's 44.6 % empty segments are **not silence**, and no cheap check separates them from the windows that produced words |
| `speech-gate-and-noise.md` | **Do not ship a denoiser.** GTCRN made the transcript worse in 15 of 16 noisy cells and wrecks clean audio outright |
| `opus-vs-adpcm.md` | What the app would have to decode if the device ever offers Opus on `fe03`, and the packet-loss concealment neither side has built |
| `ios-background-and-sidestore.md` | What iOS actually permits in the background, and why state restoration is deliberately not built |
| `instinct-email.md` | Why the assistant integration is email and nothing else |
| `battery-life-estimate.md` | The assumptions behind the runtime line on the battery screen, and the awake-current figure the whole project disagrees with itself about |

## App-specific findings that live here

Longer, still-current write-ups are in [`../agentFindings/`](../agentFindings/):
`flutter-ble-audio.md`, `ios-without-mac.md`, `on-device-stt.md`. Their settled
points, in one place:

- **`universal_ble`, not `flutter_blue_plus`.** The package everyone recommends
  is proprietary and needs a paid licence for any for-profit use, **including
  development**. Found by reading the licence, not a blog post.
- **An ATT MTU must be requested on connect**, or Android stays at 23 bytes and
  every audio frame is dropped. There is a regression test.
- **A physical phone is required** for everything in this repo — emulators and
  simulators have no Bluetooth radio.
- **sherpa-onnx 1.13.8's Dart binding cannot reach CTC-FST decoding.** `lm`,
  `hotwordsFile` and `blankPenalty` exist on `OfflineRecognizerConfig` and do
  **nothing** for a CTC model: the C API does not carry
  `OfflineCtcFstDecoderConfig`. This is a C-API gap, not a version gap —
  upgrading does not fix it, and hotwords for proper names are only reachable
  by exporting our checkpoint's RNNT head.
- **On-phone performance, measured** on a Xiaomi M2007J20CI (Snapdragon 732G,
  Android 12): the int8 IndicConformer loads in ~1.2 s and decodes at RTF
  ≈ 0.14, with transcripts matching the laptop's almost word for word. **Memory
  is the open problem** — the 16 s window added +77 MB on x86 and has not been
  re-measured on a phone.
- **`flutter test integration_test/…` uninstalls the app** unless
  `--no-uninstall` is passed, wiping its private data. Back up `files/` before
  any on-device run.
