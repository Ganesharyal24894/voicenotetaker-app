# Speech models: the catalogue, where they are hosted, and how to publish them

The engine ships in the app; the models do not. They are 368 MB in total, and
they are fetched onto the phone on demand.

Until this existed, the only way to get them onto a device was `adb push`,
which works on Android and does not exist on iOS — so on an iPhone
transcription and speaker detection were simply dead. `adb push` is still
documented and still the fastest path during development (see
`doc/agentFindings/on-device-stt.md`); the download below is how a real user
gets them, on either platform.

## The catalogue

`lib/model/model_download.dart`, pure and unit-tested
(`test/model_catalogue_test.dart`).

| Set | Enables | Files | Total |
|---|---|---|---|
| `indicconformer-hi-int8` | Hindi and Hinglish speech-to-text | `model.int8.onnx`, `tokens.txt` | 197 MB |
| `parakeet-tdt-110m-en-int8` | English written as English | `encoder/decoder/joiner.int8.onnx`, `tokens.txt` | 136 MB |
| `diarization` | Who said what | `segmentation.onnx`, `campplus.onnx` | 34 MB |

**It repeats no byte size.** Every entry takes its file names and exact sizes
from the catalogue the *engine* already uses — `SpeechModels` in
`lib/model/transcription.dart` and `DiarizationModels` in
`lib/model/diarization.dart` — and adds only the two things a download needs
and a load does not: a **sha256** and a **URL**. A test asserts they are the
same objects, so "what the downloader fetches" and "what the loader checks"
cannot drift apart.

A set is one thing. A transducer without its joiner decodes nothing, so the
unit the user installs, sees and deletes is the set, never a file.

## Hosting: our own release, uncompressed, one asset per file

`https://github.com/Ganesharyal24894/voicenotetaker-app/releases/download/models-v1/<set>--<file>`

**Why not download the upstream archives and unpack them on the phone.** The
sherpa-onnx releases publish these as `.tar.bz2`. Unpacking one on a phone
means:

* **bzip2 in Dart.** The `archive` package has a pure-Dart `BZip2Decoder`. Pure
  Dart bzip2 over a 180 MB member takes minutes on a mid-range phone, on top of
  the download.
* **A second copy in memory.** `archive` decodes into memory, so a 197 MB
  member means about 200 MB of heap on a device where
  `doc/agentFindings/on-device-stt.md` already records a 350 MB retained-memory
  problem with the model alone. The two would meet.
* **Disk for three copies.** The archive, the unpacked file, and whatever the
  extractor buffers — on a phone that may not have had room for one.
* **It does not even cover everything.** The Hindi model is not in a
  sherpa-onnx release at all; it comes from Hugging Face
  (`meetsync/indic-conformer-onnx-sherpa`), and the speaker embedding model is
  published as a bare `.onnx`. Two hosts and two shapes.

Re-hosting per file removes the whole step. The phone streams bytes straight to
disk, checks one sha256 and renames — no decompression, no second copy, no
temporary archive. GitHub releases are free, public, unauthenticated, allow
2 GB per asset, and — verified against the real host — **honour HTTP `Range`
through the 302 redirect** to `release-assets.githubusercontent.com`, which is
what makes a resumed download possible.

The cost is one upload of 368 MB when the models change, and the licences
travel with the files (IndicConformer MIT, Parakeet CC-BY-4.0, pyannote
segmentation MIT, CAM++ Apache-2.0 — all redistributable). Who made each one,
where it came from and the attribution it asks for is
**[`MODEL-CREDITS.md`](../MODEL-CREDITS.md)**, which is also the release notes.

**Assets are never replaced in place.** Different bytes mean a new tag and a
new `ModelCatalogue.releaseTag`, so a phone half way through a download can
never be handed different bytes under the same URL.

## Publishing a release

1. Gather the files into one directory, one sub-directory per set, named as the
   catalogue's `directoryName`:

   ```
   models/
     indicconformer-hi-int8/     model.int8.onnx  tokens.txt
     parakeet-tdt-110m-en-int8/  encoder.int8.onnx  decoder.int8.onnx
                                 joiner.int8.onnx   tokens.txt
     diarization/                segmentation.onnx  campplus.onnx
   ```

   Where each comes from is in `doc/agentFindings/on-device-stt.md`
   ("Model delivery"). In short:

   ```sh
   # Hindi
   huggingface-cli download meetsync/indic-conformer-onnx-sherpa \
     model.int8.onnx tokens.txt --local-dir indicconformer-hi-int8

   # English
   curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8.tar.bz2
   tar xjf sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8.tar.bz2

   # Speakers - the FLOAT segmentation model, not model.int8.onnx
   curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
   tar xjf sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
   cp sherpa-onnx-pyannote-segmentation-3-0/model.onnx diarization/segmentation.onnx
   curl -L -o diarization/campplus.onnx \
     https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
   ```

2. Upload, which also prints the catalogue entries with their sizes and
   hashes:

   ```sh
   tool/publish_models.sh ./models models-v1
   ```

   It creates the release if it is not there (`gh release create`) and uploads
   each file as `<set>--<file>` (`gh release upload`). The set id is part of
   the asset name because a release is one flat list and two sets both carry a
   `tokens.txt`.

   **The asset prefix is the set's `id`, not its directory.** They are the
   same string for the two speech sets and they are not for the speaker one:
   it lives in `diarization/` and its id — the one
   `ModelCatalogue.assetName` builds the URL from — is
   `pyannote-segmentation-3-campplus`.

   **`gh release upload` cannot do this.** In `gh`, the text after `#` is a
   display *label*; the asset is always named after the file's basename. Using
   it here uploads `tokens.txt` twice, the second overwrites the first, and the
   Hindi set silently gets Parakeet's tokens. The REST upload endpoint is the
   only place `name` can be set, so the script uses that, and by hand it is:

   ```sh
   gh release create models-v1 --title "Speech models models-v1" \
     --notes "Model files for on-device transcription and speaker detection."
   id=$(gh api repos/Ganesharyal24894/voicenotetaker-app/releases/tags/models-v1 --jq .id)
   upload() {  # upload <path> <asset-name>
     gh api --method POST \
       "https://uploads.github.com/repos/Ganesharyal24894/voicenotetaker-app/releases/$id/assets?name=$2" \
       -H 'Content-Type: application/octet-stream' --input "$1"
   }
   upload models/indicconformer-hi-int8/model.int8.onnx    indicconformer-hi-int8--model.int8.onnx
   upload models/indicconformer-hi-int8/tokens.txt         indicconformer-hi-int8--tokens.txt
   upload models/parakeet-tdt-110m-en-int8/encoder.int8.onnx parakeet-tdt-110m-en-int8--encoder.int8.onnx
   upload models/parakeet-tdt-110m-en-int8/decoder.int8.onnx parakeet-tdt-110m-en-int8--decoder.int8.onnx
   upload models/parakeet-tdt-110m-en-int8/joiner.int8.onnx  parakeet-tdt-110m-en-int8--joiner.int8.onnx
   upload models/parakeet-tdt-110m-en-int8/tokens.txt        parakeet-tdt-110m-en-int8--tokens.txt
   upload models/diarization/segmentation.onnx pyannote-segmentation-3-campplus--segmentation.onnx
   upload models/diarization/campplus.onnx     pyannote-segmentation-3-campplus--campplus.onnx
   ```

3. Paste the printed sizes and hashes into `ModelCatalogue`, and set
   `releaseTag` if it changed.

4. Check every URL answers, and that one set really downloads end to end:

   ```sh
   dart run tool/verify_download.dart --all --head-only
   dart run tool/verify_download.dart --set pyannote-segmentation-3-campplus
   ```

   The second one interrupts itself a third of the way through and resumes, so
   it proves the `Range` request as well as the hash. It uses the real
   `ModelDownloadService`; it is a script, not a test, and `flutter test` never
   touches the network.

## How a download behaves on the phone

`lib/services/transcription/model_download_service.dart`.

* **A half file is never a model.** Bytes go to `<name>.part`; the file takes
  the name the engine loads only after its sha256 matches, by a rename inside
  one directory. Nothing looks for `.part`.
* **A kill is survivable.** The `.part` file *is* the resume state — there is
  no journal to fall out of step with it. Next time it is resumed with a
  `Range` request, or thrown away because it is longer than the file it claims
  to be.
* **A wrong hash is thrown away, not resumed.** Resuming corrupt bytes only
  wastes the rest.
* **Free space is checked first**, counting only what is still to come, with
  64 MB of headroom so installing a model does not leave the phone with
  nowhere to write the next recording. A platform that will not report its disk
  lets the download run — losing the feature on a phone that cannot answer
  would be worse.
* **Wi-Fi only by default**, with an explicit "download on mobile data"
  setting, remembered in `model-download-settings.json`. A VPN or a transport
  the platform will not name counts as unmetered, because the alternative
  blocks the feature for anyone with a VPN profile.
* **One job per set.** A second tap starts nothing.
* **Retries** three times with 1 s, 2 s, 4 s backoff, resuming each time.
* **Cancel keeps what arrived**, so asking again carries on. Delete removes
  everything, `.part` files included.

### Off screen: it stops, on both platforms

A download runs only while the app is on screen. iOS suspends the process
within seconds whatever the app would prefer; on Android the foreground service
that keeps always-listening alive exists for the recorder, and finishing a
197 MB download unattended on mobile data or a low battery is not a favour. So
`appBackgrounded` pauses every job and `appForegrounded` resumes it from the
byte it stopped on. One behaviour to explain rather than two, and it costs the
user nothing that a locked screen was going to give them anyway.

## Where the pieces live

| Layer | File | Role |
|---|---|---|
| model | `lib/model/model_download.dart` | the catalogue, `ModelInstallStatus`, `ResumePlan`, failure copy, `formatBytes` |
| drivers | `lib/drivers/download_client.dart` | abstract ranged GET + `dart:io` `HttpClient` |
| drivers | `lib/drivers/hashing.dart` / `_crypto.dart` | chunked sha256; the only file naming `package:crypto` |
| drivers | `lib/drivers/network_status.dart` / `_connectivity.dart` | Wi-Fi or mobile; the only file naming `connectivity_plus` |
| drivers | `lib/drivers/disk_space.dart` / `_channel.dart` | free bytes, over the app's own `…/storage` channel |
| services | `model_download_service.dart` | the download itself |
| services | `model_download_settings_store.dart` | the mobile-data choice |
| services | `speech_model_store.dart` | where files go, and whether a set is installed — the SAME check the loader runs |
| controller | `app_controller.dart` | per-feature status, and re-planning the transcription queue when a model lands |
| controller | `models_controller.dart` | what a screen needs, and nothing else |

### No HTTP package

`http` was not a dependency and gives no way to abort a response mid-body;
`dio` would be a second HTTP stack and a second set of platform adapters for
two things `dart:io`'s own `HttpClient` already has — a `range` header and a
cancellable subscription. The abstract `DownloadClient` is about sixty lines
and is what the tests drive anyway, so the interface exists either way.

### The app now asks for INTERNET

`android.permission.INTERNET` was in the **debug** manifest only, put there by
the Flutter tool for hot reload — so a release build could not have downloaded
anything at all. It is now in `android/app/src/main/AndroidManifest.xml`, with
a comment saying what it is for: the models, on demand, from a public GitHub
release. Nothing else in this app touches the network; notes, audio and
transcripts never leave the phone. `ACCESS_NETWORK_STATE`, which the Wi-Fi rule
needs, arrives with `connectivity_plus`'s own manifest.

### Free space needs platform code

Dart has no free-space API at all. `MethodChannelDiskSpace` talks to
`…/storage`, answered by `StatFs.availableBytes` in `MainActivity.kt` and
`attributesOfFileSystem(forPath:)[.systemFreeSize]` in `AppDelegate.swift` —
about fifteen lines each, written the same way and for the same reason as
`MethodChannelPlatformSettings`. A platform with no handler answers null and
the download starts anyway.

## What the UI will need

`ModelsController` (`lib/controller/models_controller.dart`) is the whole
surface. One status per **feature**, never per file:

```dart
List<ModelInstallStatus> get modelStatuses;
ModelInstallStatus modelStatusFor(ModelFeature feature);
int get installedModelBytes;
bool get downloadOnMobileData;
Future<void> setDownloadOnMobileData(bool allowed);
Future<void> downloadModel(ModelFeature feature);
Future<void> cancelModelDownload(ModelFeature feature);
Future<void> deleteModel(ModelFeature feature);
Future<void> refreshModels();
```

`ModelInstallStatus` carries `state` (`notInstalled`, `downloading`,
`verifying`, `installed`, `failed`), `progress` (0..1), `bytesDone`,
`bytesTotal`, `bytesRemaining`, `currentFileName`, `paused`, and `failure`
(a `problem` plus a `message` already written in plain words — the screen
prints it, it does not compose one). `formatBytes` turns any of the byte counts
into `197 MB`.

There is no screen yet: the designs go to a canvas for approval first.
