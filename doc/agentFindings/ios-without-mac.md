# Shipping iOS from Linux with no Apple hardware

Researched Sept 2026. The developer machine is Ubuntu 24.04 and there is **no
Apple hardware of any kind**.

## The hard constraint

**No Mac *hardware* is required. A Mac *operating system* is.**

**[V] Verified in the local Flutter SDK source**, not just the docs —
`packages/flutter_tools/lib/src/ios/ios_workflow.dart:24`:

```dart
bool get appliesToHostPlatform => _featureFlags.isIOSEnabled && _platform.isMacOS;
```

**[V] And observable:** `flutter build --help` on this machine offers
`aar · apk · appbundle · bundle · linux · web`. **There is no `ios` or `ipa`
subcommand at all.** This is not a flag you can pass.

Xcode, `xcodebuild`, `codesign` and the Simulator runtimes ship only on macOS.
Flutter's iOS build is a thin wrapper around an Xcode project. **No supported
cross-compilation path exists.**

## Recommended setup — roughly $8–10/month

| Item | Cost |
|---|---|
| Apple Developer Program | $99/yr = **$8.25/mo** |
| Codemagic free tier (500 Mac mini M2 min/mo ≈ 35–60 builds) | **$0** |
| Overflow builds if needed | $0.095/min |

**The loop:** edit Dart + `ios/Runner/AppDelegate.swift` on Ubuntu → `git push`
→ Codemagic builds and signs on macOS (~10 min) → auto-uploads to TestFlight →
install on the iPhone.

## CI compared

| Service | Free macOS/month | Signing built in | TestFlight built in | Zero-Mac viable |
|---|---|---|---|---|
| **Codemagic** | **[V] 500 min (M2)** | **[V]** ASC API key, automatic | **[V]** one YAML flag | **yes, no blocker** |
| GitHub Actions | **[I]** ~200 min private (10× multiplier) / ∞ public | DIY | DIY | yes, with effort |
| Bitrise | **[I]** ~150 min | yes | yes | yes |
| CircleCI | **[V] 0** — macOS is gated behind a paid plan | yes | yes | **no** |
| Xcode Cloud | **[V]** 25 hrs (included with the $99) | native | native | **[V] NO** |

**[V] Xcode Cloud is disqualified** despite the most generous free tier: the
*first* workflow can only be created from **Xcode on a Mac**. Apple documents
exactly one entry point (Xcode → Product → Xcode Cloud → Create Workflow). The
web UI can edit workflows afterwards, but there is no browser-only bootstrap.
(Renting a Mac for one hour to create workflow #1, then never again, is a
legitimate trick.)

**[V] Pin `macos-15` or `macos-26`** if using GitHub Actions — `macos-14` is
fully unsupported from **2 Nov 2026**.

## Code signing — fully achievable from Linux

**[V] The only genuinely Mac-bound step is running `codesign` itself**, which
your CI does. Everything needed to *obtain* signing material works on Ubuntu:

```bash
openssl genrsa -out distribution.key 2048
openssl req -new -key distribution.key -out distribution.csr \
  -subj '/emailAddress=you@example.com, CN=Your Name, C=IN'
# upload the CSR at developer.apple.com, download the .cer   (BROWSER)
openssl x509 -inform der -in distribution.cer -out distribution.pem
openssl pkcs12 -export -legacy -out distribution.p12 \
  -inkey distribution.key -in distribution.pem -certfile AppleWWDRCAG4.pem
```

macOS Keychain does nothing magic — it generates an RSA keypair and a PKCS#10
CSR, which is what `openssl req` does.

**[V] Provisioning profiles and UDID registration are browser or REST API** —
`POST /v1/certificates`, `/v1/profiles`, `/v1/devices` on the App Store Connect
API (plain REST + JWT, callable from anywhere). The **ASC API key** (Key ID +
Issuer ID + `.p8`, created in a browser) is the credential that makes
cross-platform signing automation possible.

**[V] `fastlane match` does NOT work on Linux** — it shells out to macOS's
`security` binary and fails ([fastlane#15103]). The umbrella non-macOS issue
([fastlane#11687]) has been open since January 2018. Doesn't matter much, since
match runs on the CI's macOS machine — but do not plan a Linux-local fastlane
workflow.

**[V] Linux-native alternative:** `codemagic-cli-tools` (pure Python,
`pip install`). Its `app-store-connect` sub-tool creates certificates and
profiles and registers devices. Its `keychain`/`xcode-project` sub-tools are
macOS-only, but you don't need those from Linux.

**[V] UDID from Linux:**
`ideviceinfo -u $(idevice_id -l) | awk '/UniqueDeviceID:/ {print $2}'`
(`apt install libimobiledevice-utils`). Limit: **100 devices per product family
per membership year**.

## Apple Developer Program — $99/yr, unavoidable

**[V] The free tier is not a way to avoid this.** Free "Personal Team"
accounts cannot access the Certificates, Identifiers & Profiles portal at all;
the only thing that mints personal-team signing material is Xcode's automatic
signing, which needs a Mac. Free-tier profiles also expire in **7 days**, with
3 devices and 3 apps.

**⚠️ [V] India-specific:** *"Enrollment in India is only available through the
Apple Developer app."* You **must** enrol from an iPhone or iPad, with a
government photo ID scan, using a single device throughout. **You cannot enrol
from a browser.** It also bills as an auto-renewable subscription rather than a
one-off. Verification typically takes 24–48 hours.

## Getting builds onto the phone

**[V] TestFlight** is the clean path — the iPhone needs nothing but the
TestFlight app. **Internal testers (up to 100) get builds immediately, no
review.** External testers need Beta App Review (1–2 days). **Builds expire
after 90 days.**

**[V] Let CI do the upload.** `xcrun altool`/`notarytool` are Mac-only, Apple's
Transporter GUI is macOS-only, and fastlane `pilot` pushes through Java-based
iTMSTransporter which has a documented history of breaking on Linux
([fastlane#16996]).

**[V] Firebase App Distribution** has the best self-service UDID loop — the
tester opens a link on the iPhone, taps "Register device", installs a small
config profile that reports the UDID back.

**[V] Apple Configurator is Mac-only.** **[V] Sideloadly is Windows/macOS
only.** **[V] AltServer-Linux** and **SideStore** do work from Linux (pairing
file via `idevice_pair`), as free-Apple-ID sideloading workarounds with the
7-day expiry intact.

## Debugging an iPhone from Linux — better than expected

**[V] `idevicebtlogger` is the important one.** It talks to
`com.apple.bluetooth.BTPacketLogger` — **the same on-device service Apple's
PacketLogger uses** — and writes pcap:

```bash
# install Apple's "Bluetooth" logging profile on the iPhone first
# (developer.apple.com/bug-reporting/profiles-and-logs/)
idevicebtlogger -f pcap - | wireshark -k -i -
```

That gives host-side HCI visibility: connection events, GATT operations, **the
negotiated MTU**, disconnect reasons — most of what Xcode's Bluetooth
Instruments template shows. It is a lockdown-era service, so it is **not**
behind the iOS 17+ RemoteXPC wall that broke much of libimobiledevice.

**[V] `pymobiledevice3`** is the general Xcode replacement on Linux —
explicitly supports Linux, implements the iOS 17+ RemoteXPC tunnel, and covers
syslog, crash reports, port forwarding and DVT developer services.

**[V] Classic `libimobiledevice` is partially stale** — since iOS 17 the
developer service protocol moved to CoreDevice/RemoteXPC
([libimobiledevice#1490] open). `idevicepair`, `ideviceinfo`, `idevicesyslog`
still work.

**[V] An nRF Sniffer needs a SECOND nRF52840** — the project's board is the
device under test. **[V]** It also cannot passively decrypt LE Secure
Connections pairing (ECDH); use debug mode or supply the DH private key.

**[V] What is lost permanently:** the iOS Simulator (no workaround),
`flutter run -d <iphone>` / hot reload from Linux, and the Instruments GUI.
The Simulator matters little here — an app defined by talking to a real radio
was never testable on one.

## Core Bluetooth state restoration

**[V] The Swift compiles fine in CI.** `ios/Runner/AppDelegate.swift` already
exists and is registered in the Xcode project, so editing it needs only a text
editor. **[V] Adding a *new* Swift file** needs registration in
`project.pbxproj` — either put the class inside the existing `AppDelegate.swift`
(zero friction), or use the **`xcodeproj` Ruby gem**, which is pure Ruby and
runs on Linux.

## Do not

1. **Do not run macOS in a VM on the Ubuntu box.** Setting aside the licence
   (**[V]** macOS SLA §2.J: *"you agree not to… install, use or run the Apple
   Software on any non-Apple-branded computer"*; the §2.B(iii) two-VM
   allowance is scoped to *"each Apple-branded computer you own or control"*;
   upheld against a commercial reseller in *Apple v. Psystar*, 9th Cir. 2011),
   the engineering kills it first: **[V]** no GPU acceleration by the projects'
   own admission, and **[V] iPhone USB passthrough has an open unresolved
   failure report** — disqualifying for a BLE project.
2. **Do not plan on `fastlane match` from Linux.**

## Renting a Mac, if ever needed

**[V] The 24-hour minimum allocation is an Apple licence term**, not a vendor
policy — it applies everywhere. Cheapest occasional: **[I]** Scaleway M1
≈ €2.64 per 24 h block. **[I]** AWS `mac2.metal` ≈ $15.60/day. Cheapest
standing: **[V]** XcodeClub $25–34/mo; MacStadium from $109/mo.

Reach for this only when Instruments is genuinely needed (a memory leak or
energy problem the HCI log cannot explain) — and batch the work, since the
24-hour floor means a 40-minute session still costs a full day.

## Could not verify

- **[?]** Nothing in this document has been *executed* — no Apple Developer
  account exists yet, no build has been run on any CI, no iPhone has been
  connected. All of it is documentation research.
- **[?]** Bitrise pricing rendered as a summary rather than a clean table.
- **[?]** Whether `idevicebtlogger` ships in Ubuntu's `libimobiledevice-utils`
  package specifically — the package is available (1.3.0-8.1build3) but was
  not installed and its file list was not checked.
