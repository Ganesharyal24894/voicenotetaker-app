# Flutter BLE and audio for the voiceNotetaker device

## The BLE package — a licensing trap worth knowing about

**[V] `flutter_blue_plus` is no longer free for commercial use.** Since v2.0.0
it ships under a proprietary licence. From pub.dev's licence page, verbatim:

> *"Use of the Software by any for-profit organization requires a commercial
> license under Section 3, regardless of how the Software was obtained."*
>
> *"Use of the Software during development, testing, or evaluation by a
> for-profit organization is considered commercial use and requires a
> commercial license."*

Free only for personal / nonprofit / educational use. Paid tiers by headcount.
**[V]** Last permissively-licensed version is **1.36.8** (BSD-3, ~Oct 2025),
but pinning it means bit-rot against new Android SDK / AGP / Kotlin.

**[V] Chosen instead: `universal_ble` ^2.3.0, BSD-3-Clause.** Has everything
needed: `requestMtu()`, `requestConnectionPriority()`, notify subscriptions,
`getMaximumNotifyLength()`. Smaller community than flutter_blue_plus.

**[?]** `flutter_reactive_ble` (BSD-3, Philips) is a viable alternative —
Android+iOS only, which matches our targets. Not evaluated in depth.

## ATT MTU — the bug that produced a 44-byte recording

**[V] Observed on hardware.** The app connected and recorded successfully, and
produced a WAV containing nothing but its 44-byte header. The device reported
`tx 0 B / drop 300800 B`.

Cause: nothing requested an ATT MTU, so the link stayed at Android's 23-byte
default, leaving **20 bytes** of notification payload. An ADPCM frame is
**166 bytes** and cannot fit, so the firmware correctly refused to send.

**[V] Fix:** `connect()` now calls `requestMtu(deviceId, 247)` and
`requestConnectionPriority(highPerformance)`. Both best-effort — iOS
negotiates on its own and the calls are no-ops there.

Platform behaviour:

| | Behaviour |
|---|---|
| Android | **[V]** Defaults to 23. **[V]** Since Android 14 the stack forces 517 on the first `requestMtu()` and ignores later ones, regardless of `targetSdk`. |
| iOS | **[V]** No API to request. Core Bluetooth negotiates automatically, commonly **~185** → 182 usable bytes. |
| Linux/BlueZ | **[V]** Offers 517. |

**Consequence for raw PCM:** a 244-byte notification does **not** fit iOS's
~185 MTU. Codec 0 is Android/Linux diagnostic only. This is an independent
reason ADPCM (166 bytes) is the default.

**[V] Regression test:** `test/ble_mtu_test.dart` pins the arithmetic so
lowering `desiredMtu`, or growing a frame past it, fails locally.

## Connection interval

**[V] Android (AOSP `config.xml`, values in 1.25 ms units):**

| Priority | min | max |
|---|---|---|
| HIGH | 11.25 ms | 15 ms |
| BALANCED (default) | 30 ms | 50 ms |
| LOW_POWER | 100 ms | 125 ms |

**[V] iOS gives the app no control at all.** The *peripheral* proposes
parameters and must satisfy Apple's Accessory Design Guidelines: interval min
≥ 15 ms and an integer multiple of 15 ms, interval max ≥ min + 15 ms, slave
latency ≤ 30, supervision timeout ≤ 6 s. **The firmware's connection-parameter
request is the only lever on iOS** — it must ask for a 15 ms multiple or iOS
rejects it and you stay slow.

**[V] Observed on Linux:** the host settled at 45 ms with DLE 251 negotiated.
ADPCM sails through; raw PCM at 45 ms is exactly why it measured short of
realtime.

## Permissions

**[V] Android manifest** (declared and verified working on Android 12):
`BLUETOOTH_SCAN` with **`neverForLocation`**, `BLUETOOTH_CONNECT`, legacy
`BLUETOOTH`/`BLUETOOTH_ADMIN`/`ACCESS_FINE_LOCATION` capped at
`maxSdkVersion="30"`.

`neverForLocation` lets you drop the location permission entirely on Android
12+. **[V] Documented cost:** *"some BLE beacons are filtered from the scan
results."* Irrelevant here — the device advertises a custom 128-bit service
UUID, not an iBeacon/Eddystone frame.

**[V]** Requested at runtime via `UniversalBle.requestPermissions()`;
confirmed `granted=true, USER_SET` on device.

**[V] iOS Info.plist:** `NSBluetoothAlwaysUsageDescription` is **mandatory
since iOS 13** — omitting it is an App Store rejection (ITMS-90683). Add
`UIBackgroundModes: bluetooth-central` for background operation.
`NSMicrophoneUsageDescription` is **not** needed — the app never touches the
phone's mic.

## Audio playback of decoded PCM

**[V] `just_audio` and `audioplayers` cannot play headerless live PCM.**
`just_audio`'s `StreamAudioSource` runs a local HTTP proxy that the native
demuxer fetches from and needs a parseable container —
[just_audio#1028](https://github.com/ryanheise/just_audio/issues/1028)
confirms this exact scenario is unsupported.

**[V] For live streaming, `flutter_pcm_sound`** is the fit — its API *is*
"feed raw int16 PCM", it is event-driven with an explicit underrun signal, and
it is Unlicense. Android/iOS/macOS only. `flutter_sound` is the fallback if
desktop is ever needed (caveat: effectively maintenance-mode, bus factor 1).

**For saved files, write a real 44-byte RIFF header** — then any player works.
Implemented in `lib/services/wav_writer.dart`; the header field offsets are
asserted in `test/wav_writer_test.dart`.

**[?] Buffering:** iOS reportedly batches BLE notifications into bursts of 3–5
rather than delivering them evenly. Source is an Apple Developer Forums thread
with no Apple response. Plan a **≥60 ms jitter buffer**, but measure on real
hardware before designing around it.

## Background execution — the hard limits

**[V] Android: use `foregroundServiceType="connectedDevice"`.** It is
specifically **exempt** from the Android 15 six-hour-per-24h cap, which applies
only to `dataSync` and `mediaProcessing`. Using `dataSync` for an always-on
recorder would get it killed. An active foreground service also keeps the app
in the "active" App Standby bucket, exempt from Doze — **do not** additionally
request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, which Play policy restricts.

**[?] OEM battery killers are a real field risk** (dontkillmyapp.com lists
Xiaomi, Huawei, OnePlus, Oppo, Vivo, Samsung...). No API guarantees against
them. Budget engineering time; this is reportedly the #1 field complaint for
always-on Android recorders. **Directly relevant — the test phone is a Xiaomi.**

**[V] iOS: `bluetooth-central` keeps notifications flowing when backgrounded**,
but with hard limits: *"an app has around 10 seconds to complete a task"* on
wake, and the system may terminate it under memory pressure at any time.
**State restoration is mandatory, not optional** — and
`centralManager:willRestoreState:` **fires before the Flutter engine exists**,
so it cannot be a MethodChannel handler. That is native Swift in `AppDelegate`.

**[V] Do NOT use the `audio` background mode as a keep-alive** — App Store
Review Guideline 2.5.4, actively enforced.

## Testing

**[V] Wrap the plugin** — Flutter's own top-ranked strategy. `universal_ble`
exposes static methods, and **static methods cannot be mocked** by mockito or
mocktail (both work by subclassing). Hence `lib/drivers/ble_transport.dart` is
an abstract interface naming no package types, and tests fake that.

**[V] `mocktail`**, not mockito — codegen-free, no `build_runner` in CI.

## Could not verify

- **[?]** Real throughput to a phone. All phone-side numbers are third-party
  (Punch Through ~50 kB/s conservative on modern devices; Memfault). ADPCM at
  8.3 kB/s has wide margin either way; raw PCM at 32 kB/s does not.
- **[?]** Whether `flutter_reactive_ble` would have been a better choice.
- **[?]** iOS behaviour of any kind — **nothing in this document about iOS has
  been tested**, because iOS cannot be built on this machine. See
  `ios-without-mac.md`.
