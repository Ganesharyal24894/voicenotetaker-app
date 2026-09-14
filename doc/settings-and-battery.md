# Recorder settings and battery history

Two screens from the approved canvas (`Settings.dc.html`,
`BatteryHistory.dc.html`), plus the firmware contracts they read: `fe04`
auto-sleep durations and `fe09` battery-life history. The not-saving alert that
shares the same status is in `continuous-mode.md`.

## Pieces

| Piece | File |
|---|---|
| Recorder settings screen | `lib/view/settings_view.dart` (`SettingsView`, `AlwaysListeningCard`, `AutoSleepCard`) |
| Battery cards on Diagnostics | `lib/view/battery_card.dart`, copy in `lib/view/battery_copy.dart` |
| `fe04` wire format | `lib/model/auto_sleep.dart` (`AutoSleep`, `AutoSleepSetting`, `AutoSleepDuration`) |
| `fe09` decoder | `lib/model/battery_history.dart` |
| Anchor + store | `lib/model/battery_anchor.dart`, `lib/services/battery_anchor_store.dart` (`<support>/battery-anchors.json`) |
| What the app computes | `lib/model/battery_report.dart` (pure) |
| Controller | `AppController`: `setAutoSleepDuration`, `refreshBatteryHistory`, `batteryReport`, `batteryHistoryStatus` |
| Driver | `BleTransport.readAutoSleep` / `setAutoSleepDuration` / `readBatteryHistory` |

## Recorder settings

Reached from Home's status line **and** the header ⋮, in release builds on
both platforms. Back returns to Home.

- **Listening** - *Always listening* switch, with the same status line as the
  header (*Saving notes*, *Not saving — …*, *Muted on the recorder*). Turning
  it on uses the existing permission explanation. Under it, only while
  always-listening is off: **Disconnect** (connected) or **Connect a
  recorder** (not connected; leaves Settings and opens pairing over Home). These
  came from the interim recorder sheet, which is gone.
- **Auto-sleep** - *Sleep when still for*: 30 s / 1 min / 2 min / 5 min /
  Never. The recorder's own value is shown; nothing is selected until it has
  been read. Disabled with one line when not connected (*Connect your recorder
  to change this.*) or when the firmware only knows on/off (*Update your
  recorder to change this.*). A tap shows at once; a refused write puts the old
  choice back and shows *Couldn't change auto-sleep. Try again.*
- **Audio** - *Delete audio after 24 h* (`setAutoDeleteAudio`), with *Transcripts
  are kept. Notes you mark Keep are never deleted.* Still off by default.
- **Diagnostics** row - *Battery, connection, mic check*.
- **Pairing** section: **omitted** until pairing is built (no placeholder).

### `fe04` both ways

| Firmware | Read | App writes |
|---|---|---|
| older | 1 byte, bit 0 on/off | 1 byte (developer screen's On/Off only) |
| with durations | 2 bytes `[flags, code]`, code 0 off, 1 30 s, 2 1 min, 3 2 min, 4 5 min; flags bit 0 == code != 0 | 2 bytes for a duration; the 1-byte on/off write still works and is followed by a read-back, because the firmware keeps its stored duration |

The READ LENGTH decides which firmware this is. Anything else (length,
reserved bits, unknown code, flags disagreeing with code) is refused and the
setting reads as unknown.

## Battery history (Diagnostics)

The recorder has no clock. It counts awake seconds, sleeps and boots since the
last plug/unplug; the phone supplies wall time. Every `fe09` read is stored as
an **anchor** (phone UTC, state, session id, awake seconds, sleeps, boots,
resets, last %/mV, uptime, flags) in `battery-anchors.json`, at most 400,
oldest dropped. Doc rule 8 (awake seconds going back without a boot => a
reused id) drops the older anchors of that session.

**When it is read** - no timer of its own:

- at every connect;
- when Diagnostics opens;
- on a battery (`fe05`) notification or a return to the app, at most every
  30 min while connected.

**What is shown** (`BatteryReport.compute`, per the firmware doc's "What the
app must compute"):

| Line | Rule |
|---|---|
| `62% · on battery for 14 h` | current % and time since the unplug; *at least* when the unplug is a range |
| Line chart | this charge only: settled % at unplug, then each anchor's %; labels `Mon 23:50 · 96%` / `Now · 62%`; hidden with fewer than 2 points |
| Unplugged | settled % at unplug + time: exact (`utc − awake` of the first anchor with no sleeps/boots and START_UNSEEN clear), a range from the last anchor on external power, or *before …* when only the upper bound is known |
| Estimated runtime | remaining `≈ wall × last% / used`, shown as `~1 d 2 h at this rate` only when at least **10 points** were used, the settled start is known and the unplug uncertainty is under 25 % of the wall time; otherwise *Not enough data yet* |
| Footnote | *Estimate improves after a full discharge. Percent is estimated from voltage.* + *Some of this charge was not recorded.* when GAP / RESET_SEEN / HISTORY_RESET / AFTER_POWER_LOSS / SATURATED is set |
| On external power | `62% · charging` / `· plugged in`, nothing else |

**Last charges** (only when the ring has entries): `11 Sep 21:30 → 13 Sep 08:40`
(`~` on an approximate end, `Time not known` without anchors), then
`96% → 12% · 1 d 11 h · awake 9 h 20 m · 41 sleeps`, *partly recorded* for
low-trust sessions, pill **Ran flat** (amber) for EMPTY and **Power lost**
(neutral) for POWER_LOST.

**Unavailable states**: not connected (*Connect your recorder to see its
battery.*), no `fe09` (*Update your recorder to see battery history.*), a layout
this build cannot read (*Update the app to read this recorder's battery
history.*). A version above 1 whose sections are at least v1's length is read
by the header lengths (the known prefix of each section).

## Deviations from the canvas

- **Pairing section omitted** (later task).
- **Connect / Disconnect** under the Listening card (not on the canvas): the
  interim sheet they lived in is gone and they had to stay reachable.
- Settings title row: the canvas's empty header text next to the back chevron
  is not drawn.
- Unplugged / chart labels gain range forms (`Tue 20:50–23:50`, `before …`) and
  the headline *at least*, which the canvas has no example of.
- **Last charges** titles use the middle of each range; sessions with no
  anchors say *Time not known*; **Power lost** pill added next to *Ran flat*.
- Measured full runtime of a past EMPTY session is shown only as that row's
  duration; it does not replace the current estimate.

## Needs a real recorder and phone

- Read Blob of the 428-byte `fe09` at MTU 247 (Android) and 185 (iOS).
- Two-byte `fe04` reads/writes and the ATT errors on old firmware.
- That the anchors' times look right across a real unplug-while-asleep day.
