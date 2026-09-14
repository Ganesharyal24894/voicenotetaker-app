# voicenotetaker-app

Companion Flutter app for the **voiceNotetaker** nRF52840 recorder. It scans for
the device, connects, pulls the audio stream off a custom GATT service, decodes
it and writes a WAV file.

> **The UI is built to the approved design.** `design/Main.dc.html` and
> `design/Palette.dc.html` are the source of truth, and `lib/view/` implements
> them screen for screen. What still has no service behind it — transcription,
> the battery reading, and the link figures on the developer screen — is
> rendered from clearly marked placeholder state in
> `lib/view/placeholder_data.dart`, never from an invented service.

## The device

Fixed peripheral; the app adapts to it, never the other way around.

| | |
|---|---|
| Advertised name | `voiceNotetaker` |
| Service | `6e40fe00-b5a3-f393-e0a9-e50e24dcca9e` |
| `fe01` | NOTIFY — audio frames |
| `fe02` | READ — stream info |
| `fe03` | WRITE — 1 byte codec select |
| `fe08` | READ/NOTIFY/WRITE — capture state: mute, speech gate (always listening; see `doc/continuous-mode.md`) |

**Pairing.** Recorder firmware that pairs to one phone requires an encrypted
link for every characteristic and advertises its status in the scan response
(manufacturer data, company `0xFFFF`, `[0x01, flags]`: bit 0 has an owner,
bit 1 pairing window open). The app bonds on Android, pairs on the first
encrypted read on iOS, and shows *Paired to another phone* with the charger
double-tap instructions when the recorder refuses it. Firmware without the
field connects exactly as before. See `doc/pairing.md`.

**Every notification** starts with a 2-byte little-endian sequence number,
followed by the payload. Gaps in that sequence are packets dropped on the link
and are counted separately from audio quality, so a bad radio environment is
never mistaken for a bad codec.

**`fe02` stream info**, packed little-endian, 8 bytes:

```
offset size field
0      4    uint32 sampleRateHz
4      1    uint8  bitsPerSample
5      1    uint8  channels
6      1    uint8  codec
7      1    uint8  reserved
```

**Codec 0 — raw PCM.** s16le, split across notifications, concatenated verbatim.

**Codec 1 — IMA ADPCM** (the device default). Each notification is ONE
self-contained block: a 4-byte header (`int16` predictor LE, `uint8` step index,
`uint8` reserved) followed by 4-bit nibbles, **low nibble first**, 320 samples
per block → 164 bytes on air. Decoded output is 16 kHz, 16-bit, mono. Because
each block carries its own predictor state, a dropped packet costs exactly one
block instead of desynchronising the decoder for the rest of the stream.

## Architecture

The same four-layer scheme the firmware uses. Dependencies point one way only:
`view → controller → services → drivers → model`.

```
lib/
  model/       Pure DATA. Classes and enums for stream info, codec, frames,
               device state, recording metadata, the auto-sleep flag's one-byte
               wire format, and the device's fixed GATT identifiers. No logic,
               no I/O, no Flutter imports.

  drivers/     PLATFORM LAYER. All external-world access lives here, and only
               here. Each driver is an abstract interface that names no package
               type, plus a concrete implementation.

                 ble_transport.dart            abstract: scan / connect /
                                               disconnect / subscribe frames /
                                               read info / select codec /
                                               read + write auto-sleep
                 ble_transport_universal.dart  universal_ble implementation
                 audio_player.dart             abstract playback
                 audio_player_just_audio.dart  just_audio implementation
                 file_store.dart               abstract file write/read/stat
                                               + IoFileStore (dart:io)
                 app_directories.dart          abstract "where may I write?"
                                               + path_provider implementation
                 speech_recognizer.dart        abstract offline STT: one job =
                                               load, decode windows, release
                 speech_recognizer_sherpa.dart sherpa_onnx implementation, in
                                               its own isolate per job
                 process_memory.dart           /proc RSS probe (Linux/Android)
                 background_mode.dart          abstract keep-alive while always
                                               listening + MethodChannel impl
                                               (Android foreground service)

  services/    Domain logic on top of the driver interfaces. No package
               imports, no dart:io.

                 codec/adpcm_decoder.dart  pure Dart IMA ADPCM decoder
                 frame_reassembler.dart    strips the sequence header,
                                           detects gaps, counts loss
                 wav_writer.dart           44-byte RIFF header + s16le
                 wav_reader.dart           reads that header back; malformed
                                           and truncated files return null
                 recording_service.dart    capture -> decode -> file
                 library_service.dart      lists saved recordings, newest
                                           first, with real metadata; delete
                 level_meter.dart          peak / RMS dBFS of the PCM the
                                           app already decodes
                 pairing/                  pairing to one phone: bond, secure,
                                           remembered owners. See
                                           doc/pairing.md
                 continuous/               always listening: one session per
                                           link, speech -> notes, settings.
                                           See doc/continuous-mode.md
                 wav_repair.dart           startup fix for headers left by a
                                           capture the app was killed in
                 transcription/            offline speech-to-text: window
                                           planning (8 s), model presence
                                           check, the transcription service.
                                           SPIKE - see doc/agentFindings/
                                           on-device-stt.md

  controller/  app_controller.dart — orchestration and app state.
  view/        THE UI, built to `design/Main.dc.html`. May use controller/
               and model/, and drivers/ only through their abstract
               interfaces - it never imports universal_ble or any other
               package plugin.

                 theme.dart            all colour and type tokens, and the
                                       contrast rule that governs them
                 app_root.dart         picks the screen from the device state
                 scan_view.dart        1. scan / pair
                 pair_new_phone_view.dart  "Pair a new phone" (from Settings)
                 home_view.dart        2. home
                 recording_view.dart   3. capture in progress
                 all_notes_view.dart   4. all notes (see doc/notes.md)
                 note_view.dart        5. a note: transcript, audio panel
                 developer_view.dart   6. diagnostics, DEBUG BUILDS ONLY
                 widgets/              icons (CustomPainter, no icon font),
                                       waveforms, shared chrome
  main.dart    Minimal; wires concrete drivers in and hands off.
```

### Why `drivers/` is the swap layer

`universal_ble` appears in exactly one file: `lib/drivers/ble_transport_universal.dart`.
Nothing above it knows the package exists. The interface in `ble_transport.dart`
is written entirely in `lib/model/` types — `DiscoveredDevice`, `StreamInfo`,
`BleConnectionStatus`, `Uint8List` — so:

* **Replacing the BLE package** means writing one new file next to the existing
  implementation and changing one line in `main.dart`. Nothing in `services/`,
  `controller/` or the tests moves.
* **Adding a platform** that `universal_ble` does not cover is the same shape of
  change.
* **Testing is free.** `RecordingService` is exercised against a `mocktail`
  fake of `BleTransport` and an in-memory `FileStore`, with no radio, no
  filesystem and no platform channels involved.

The same applies to `FileStore` (`services/` never imports `dart:io`), to
`AppDirectories` (`path_provider` is named in one file) and to `AudioPlayer`,
whose `just_audio` implementation sits beside the interface: nothing outside
`lib/drivers/` names a playback package, and the interface itself is written in
plain Dart and `lib/model/` types.

Two things live in `model/` that might look like they belong in `drivers/`, and
they are there on purpose: the GATT UUIDs (`DeviceProfile`) and the packed
byte layout of the stream-info characteristic (`StreamInfo.fromBytes`). Both
describe the *device protocol*, not the BLE stack — putting them in `drivers/`
would mean re-implementing them on every package swap, which is exactly what
the swap layer exists to prevent.

## Running the tests

```sh
source ~/development/flutter-env.sh
flutter pub get
flutter analyze     # must be clean
flutter test        # must be all green
```

| File | Covers |
|---|---|
| `test/adpcm_decoder_test.dart` | cross-language golden vectors + edge cases |
| `test/frame_reassembler_test.dart` | sequence gaps, 16-bit wraparound, loss counting |
| `test/wav_writer_test.dart` | exact 44-byte header, field by field at its offset |
| `test/recording_service_test.dart` | orchestration against a `mocktail` fake transport |
| `test/file_store_test.dart` | the real `dart:io` sink, including header patching, `readRange` and `stat` |
| `test/wav_reader_test.dart` | the reader against the writer's own bytes, plus every malformed case |
| `test/library_service_test.dart` | listing order, metadata, duration from the header, broken files, delete |
| `test/level_meter_test.dart` | silence, full scale, a sine of known amplitude, and the empty block |
| `test/audio_player_test.dart` | the playback state machine against a fake, and the controller driving it |
| `test/stream_info_test.dart` | `fe02` byte layout, codec mapping, device constants |
| `test/view/theme_test.dart` | every design token, and the measured contrast ratios the palette rests on |
| `test/view/*_view_test.dart` | each screen in its main states, against a `mocktail` fake transport |
| `test/view/app_root_test.dart` | which screen the device state selects, and navigation between them |

### The cross-language golden test

This is the check that matters most. A codec mismatch between device and app
does not fail loudly — it degrades audio silently — so the Dart decoder is
asserted to reproduce the firmware's own Python reference **exactly**, sample
for sample.

`test/fixtures/adpcm_vectors.json` holds `(block bytes, expected int16 samples)`
pairs produced by running `host/adpcm.py` from the firmware repository. To
regenerate it:

```sh
/home/ganesh/personalProjects/nrf52840-sense/host/.venv/bin/python \
    tool/generate_adpcm_fixtures.py
```

Pass `--reference /path/to/adpcm.py` if the firmware repository moves. The
generator is checked in at `tool/generate_adpcm_fixtures.py`; the fixture file
is generated output and should never be edited by hand.

The vectors specifically cover:

* full 320-sample / 164-byte firmware blocks (tone, silence, white noise),
* **step-index clamping** at both table bounds — pinned at 0, pinned at 88, and
  an out-of-range header index clamped on entry,
* **predictor clamping** at ±32767/−32768, plus header predictors at the int16
  bounds,
* **low-nibble-first ordering**, via asymmetric nibble pairs where swapping the
  order changes every sample,
* **odd sample counts** (5 samples → 3 bytes → 6 decoded samples, the last of
  which is padding),
* **block independence** — identical nibbles under different headers must decode
  differently, and decoding one block must not affect the next.

## The UI layer

Six screens, built to `design/Main.dc.html` at its own measurements — the
mock's paddings, type sizes and tracking are lifted, not rounded to Material
defaults. Sora is bundled under `assets/fonts/` in the five weights the design
uses rather than fetched at runtime, so the app renders identically offline and
inside `flutter test`.

### The contrast rule

`#6D28D9` is the primary, and it measures **2.78:1** against the dark
background — below the 4.5:1 floor for text *and* the 3:1 floor for UI
elements. So:

* `#6D28D9` is a **fill** colour only: buttons, waveform bars, filled chips.
* Content on that fill is **light** (`#F4F1FB`, 6.37:1). Never a dark glyph on
  the purple.
* Purple **text and icons** on the dark background use `#A78BFA` (7.25:1).

The rule is written out at the top of `lib/view/theme.dart`, expressed in the
palette as `primaryFill` / `onPrimaryFill` / `purpleText`, and the three
measurements are asserted in `test/view/theme_test.dart` — if one of them
moves, the suite fails.

### The developer screen is not in release builds

`lib/view/developer_view.dart` exports `debugOnlyDeveloperView()`, the single
construction site of `DeveloperView`, guarded by `if (kDebugMode)`. Because
`kDebugMode` is a compile-time constant, the branch is dead code in a release
build and the screen is tree-shaken out. `flutter test` always runs a debug
build, so the release half cannot be exercised at runtime; instead the test
asserts the debug half, and asserts at source level that nothing else anywhere
in `lib/` constructs the screen.

### Not backed by a service yet

Transcription, the battery reading, and the ATT MTU / interval / PHY /
throughput / jitter figures on the developer screen still have nothing below
`view/` that can produce them. They render as marked placeholder content
(`lib/view/placeholder_data.dart`) or as `—`. No driver or service was invented
to fill the gap.

The recordings library and the peak level are no longer among them: the library
list comes from `LibraryService` through `AppController.recordings`, and the
peak readout on the recording screen comes from `LevelMeter` through
`AppController.peakDbfs`. The note screen's audio panel is bound to the real
player through `AppController.playbackState`.

## Package choices

### `universal_ble` — licensing rationale

BLE is provided by [`universal_ble`](https://pub.dev/packages/universal_ble),
which is **BSD-3-Clause**: permissive, no commercial licence to buy, no
per-seat or per-app fee, and no obligation beyond attribution.

The obvious alternative, `flutter_blue_plus`, is **deliberately not used**: it
is proprietary and requires a paid commercial licence. Please do not "simplify"
the driver by swapping it in.

`universal_ble` also covers Android, iOS, macOS, Windows, Linux and Web from one
API, which keeps `ble_transport_universal.dart` a single file rather than one
per platform. If it ever has to go, see *Why `drivers/` is the swap layer*
above — the blast radius is one file.

### `mocktail`

Used for the fake `BleTransport` in `recording_service_test.dart`. Chosen for
being codegen-free: no `build_runner` step, no generated files in the tree, and
tests that keep working when an interface changes without a regeneration pass.

Note that `mocktail` needs `registerFallbackValue` for any enum used with
`any()` — see `setUpAllForMocktail()` in the recording service test.

### `flutter_lints`

Standard lint set, enabled via `analysis_options.yaml`. `flutter analyze` is
expected to be clean; treat a new warning as a build break.

### `just_audio` — licensing rationale

Playback is [`just_audio`](https://pub.dev/packages/just_audio), which is
**MIT**: permissive, no commercial licence to buy, no fee. Its own dependencies
are the same shape - `audio_session` and the `just_audio_*` platform packages
are MIT, `rxdart` is Apache-2.0, `uuid` and `synchronized` are MIT, and
`crypto` / `path` are BSD-3-Clause from the Dart team.

It appears in exactly one file, `lib/drivers/audio_player_just_audio.dart`.
Recordings are ordinary WAV files with a 44-byte RIFF header, so an off-the-
shelf file player handles them and no raw-PCM streaming source is needed.

### `path_provider` — licensing rationale

[`path_provider`](https://pub.dev/packages/path_provider) is **BSD-3-Clause**,
maintained by the Flutter team, and appears only in
`lib/drivers/app_directories.dart`.

## Platform status

| Platform | Status |
|---|---|
| Android | Supported, and `flutter build apk --debug` is verified green on this host. BLE permissions are declared in `android/app/src/main/AndroidManifest.xml` (`BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_CONNECT`, plus the pre-API-31 equivalents). |
| Linux | Supported by `universal_ble` (BlueZ) and useful for desktop testing, but `flutter build linux` needs the GTK 3 development headers (`libgtk-3-dev`), which are not installed on this host. |
| iOS | **Cannot be built here.** See below. |

### Known iOS constraint

**No iOS build is possible on this machine.** The iOS toolchain (Xcode,
CocoaPods, the iOS SDK, code signing) is macOS-only, and this project is
developed on Linux. `flutter doctor` reporting a missing iOS toolchain is
expected and is *not* a bug to fix.

The `ios/` directory is present and the required
`NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription`
keys are set in `ios/Runner/Info.plist`, but none of it has been compiled or run.
Producing an iOS build requires either a Mac or a macOS CI runner
(GitHub Actions `macos-latest`, Codemagic, or similar). Until that exists, treat
iOS as untested rather than as supported.

## Application id — note

The Android namespace / iOS bundle id is `com.ganeshsharma.voicenotetaker_app`.

It is a personal reverse-DNS rather than an employer domain, deliberately: a
bundle id cannot be changed after an App Store or Play Store release, so it
fixes ownership of the listing permanently.

One trap worth recording. The natural choice for a `.in` domain is
`in.<something>.*` -- and that does not work, because **`in` is a Java reserved
keyword**, so Gradle rejects the namespace outright:

```
Namespace '`in`.tohands.voicenotetaker_app' is not a valid Java package name
as '`in`' is not a valid Java identifier.
```

If the project owner wants a different id, change it in
`android/app/build.gradle.kts` (`namespace` and `applicationId`), the Kotlin
package under `android/app/src/main/kotlin/`, `linux/CMakeLists.txt`
(`APPLICATION_ID`) and the iOS `PRODUCT_BUNDLE_IDENTIFIER` — but it must remain
a valid Java package name.

## Storage location

Recordings go in `<app documents>/recordings`, resolved at startup through the
`AppDirectories` driver (`path_provider`'s `getApplicationDocumentsDirectory`).
On Android that is the app's private `app_flutter` directory and on iOS the
app's `Documents` directory - neither is a cache, so recordings survive an app
restart and are removed only when the app is uninstalled.

The previous `Directory.systemTemp` location was not viable: on Android it
resolves inside `code_cache`, which the OS is free to evict.

## Repository layout notes

* `design/` — design mockups owned by the project owner. Not touched by the app
  code, not built into anything.
* `tool/generate_adpcm_fixtures.py` — regenerates the golden vectors.
* Git is handled by the project owner. Nothing here initialises a repository
  or commits.
