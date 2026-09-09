# voicenotetaker-app

Companion Flutter app for the **voiceNotetaker** nRF52840 recorder. It scans for
the device, connects, pulls the audio stream off a custom GATT service, decodes
it and writes a WAV file.

> **The UI is built to the approved design.** `design/Main.dc.html` and
> `design/Palette.dc.html` are the source of truth, and `lib/view/` implements
> them screen for screen. Three things the design shows have no service behind
> them yet — the recordings library, playback and transcription — and those are
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
               device state, recording metadata, and the device's fixed GATT
               identifiers. No logic, no I/O, no Flutter imports.

  drivers/     PLATFORM LAYER. All external-world access lives here, and only
               here. Each driver is an abstract interface that names no package
               type, plus a concrete implementation.

                 ble_transport.dart            abstract: scan / connect /
                                               disconnect / subscribe frames /
                                               read info / select codec
                 ble_transport_universal.dart  universal_ble implementation
                 audio_player.dart             abstract playback (no impl yet)
                 file_store.dart               abstract file write/read
                                               + IoFileStore (dart:io)

  services/    Domain logic on top of the driver interfaces. No package
               imports, no dart:io.

                 codec/adpcm_decoder.dart  pure Dart IMA ADPCM decoder
                 frame_reassembler.dart    strips the sequence header,
                                           detects gaps, counts loss
                 wav_writer.dart           44-byte RIFF header + s16le
                 recording_service.dart    capture -> decode -> file

  controller/  app_controller.dart — orchestration and app state.
  view/        THE UI, built to `design/Main.dc.html`. May use controller/
               and model/, and drivers/ only through their abstract
               interfaces - it never imports universal_ble or any other
               package plugin.

                 theme.dart            all colour and type tokens, and the
                                       contrast rule that governs them
                 app_root.dart         picks the screen from the device state
                 scan_view.dart        1. scan / pair
                 home_view.dart        2. home
                 recording_view.dart   3. capture in progress
                 library_view.dart     4. recordings
                 playback_view.dart    5. playback
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

The same applies to `FileStore` (`services/` never imports `dart:io`) and to
`AudioPlayer`, which is deliberately interface-only: no playback package has
been chosen yet, so nothing outside `lib/drivers/` is allowed to assume one.

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
| `test/file_store_test.dart` | the real `dart:io` sink, including header patching |
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

Playback, transcription, a recordings library, the battery reading, and the ATT
MTU / interval / PHY / throughput / jitter figures on the developer screen have
nothing below `view/` that can produce them. They render as marked placeholder
content (`lib/view/placeholder_data.dart`) or as `—`, and the transport
controls tell the user plainly that nothing is playing. No driver or service
was invented to fill the gap.

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

### No audio playback package yet

Intentional. `lib/drivers/audio_player.dart` defines the interface only. When a
package is chosen, add `audio_player_<package>.dart` beside it and wire it in
`main.dart`.

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

## Storage location — open decision

`main.dart` currently writes recordings under `Directory.systemTemp`. That is a
placeholder: `path_provider` was deliberately not added before the storage
location is decided. See the `TODO(storage)` in `lib/main.dart`.

## Repository layout notes

* `design/` — design mockups owned by the project owner. Not touched by the app
  code, not built into anything.
* `tool/generate_adpcm_fixtures.py` — regenerates the golden vectors.
* Git is handled by the project owner. Nothing here initialises a repository
  or commits.
