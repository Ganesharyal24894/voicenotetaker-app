# Agent findings

Research produced by subagents during development, kept so a future session
does not have to rediscover it.

## How to read these documents

**They are notes, not gospel.** Every claim carries a marker:

| Marker | Meaning |
|---|---|
| **[V]** | Verified — checked directly in this repo, the pub cache, the Flutter SDK source, or an official page that is cited. |
| **[I]** | Inferred — arithmetic or reasoning from something verified. Plausible, not confirmed. |
| **[?]** | Unverified or disputed. **Do not act on these without checking.** |

**Agents got things wrong in this project, and so did "what everyone says".**
The BLE package everyone recommends turned out to require a **paid commercial
licence** — found only by reading the actual licence text rather than a blog
post. Treat **[V]** with a citation as reliable, **[I]** as a starting point,
**[?]** as a question.

## Contents

| File | Subject |
|---|---|
| `flutter-ble-audio.md` | BLE package choice and its licensing trap, permissions, MTU, playback, background execution |
| `ios-without-mac.md` | Building, signing and shipping iOS with no Apple hardware |
| `on-device-stt.md` | Offline Hindi speech-to-text on the phone: sherpa_onnx + IndicConformer, measured on a Xiaomi |

The firmware repo has its own `doc/agentFindings/` covering the nRF52840,
the PDM microphone, and IMU/ML/power.

## Settled — do not re-litigate

- **`universal_ble`, not `flutter_blue_plus`.** The latter is proprietary and
  requires a paid licence for any for-profit use *including development*.
- **An ATT MTU must be requested on connect.** Without it Android stays at 23
  bytes and every audio frame is dropped. There is a regression test.
- **iOS cannot be built on Linux.** It is a source-level gate, not a flag.
- **A physical phone is required** — emulators and simulators have no
  Bluetooth radio.
