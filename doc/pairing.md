# Pairing to one phone

The recorder bonds with **one** phone. The firmware side, the scan-response
layout and the two-phone hardware plan are in the firmware repo:
`nrf52840-sense/doc/pairing.md`. This page is the app's half.

## Pieces

| Piece | File |
|---|---|
| Scan-response flags (`05 FF FF FF 01 <flags>`) | `lib/model/pairing_advert.dart` |
| Card state: ready / yours / another phone / pairing mode | `lib/model/recorder_pairing.dart` |
| Error kinds, outcome classification | `lib/model/pairing_outcome.dart` |
| Connect → bond → secure state machine | `lib/model/pairing_flow.dart` |
| Runs the flow, remembers owners (`<support>/pairing.json`) | `lib/services/pairing/` |
| Driver seam | `lib/drivers/ble_pairing.dart`, implemented by `UniversalBleTransport` |
| Bonded identity addresses (Android) | `MainActivity.kt`, channel `…/bluetooth`, `bondedDevices` |
| Screens | `scan_view.dart` (cards, *Paired to another phone*, *Forget the old pairing*), `pair_new_phone_view.dart`, PAIRING in `settings_view.dart` |

## The flow

1. **Scan.** Each result's manufacturer data is parsed; a later result for the
   same id replaces the card (the scan response can arrive second). No field →
   older firmware → the card and the connect are exactly as before.
2. **Connect** with the transport as always.
3. **Bond** (Android only, and only for a recorder that pairs and is not
   bonded yet): `UniversalBle.pair` → `createBond`, waits for `BOND_BONDED`.
4. **Secure**: read `fe02` with a 40 s timeout. On iOS this is what shows the
   system pairing alert; on both it proves the link is encrypted.
5. Carry on with the usual session setup, which subscribes again on every
   connection (battery on connect, `fe08`/`fe01` per always-listening session).

Success on a recorder that pairs stores its id (and, on Android, the bonded
identity address) with the date - iOS has no "is bonded" API.

| Outcome | Shown |
|---|---|
| refused at connect (HCI `0x05`, or a drop within 2 s on flags `01`) | *Paired to another phone* + charger copy, **I've done that** |
| admitted, pairing refused | *Pair this phone again* + the same copy |
| key missing / peer removed pairing / encryption failed with a bond | *Forget the old pairing*: Android opens Bluetooth settings, iOS says where to go |
| timeout, anything else | the existing *Couldn't connect* |

Android knows its bonds, so tapping a recorder whose flags say *owned* while
the OS holds no bond goes straight to the instructions without connecting.
iOS cannot tell a reinstalled app on the owner phone from a stranger, so it
tries one connection first, as the firmware doc advises.

**I've done that** scans again and connects to the first recorder whose flags
show the window open (bit 1). If the 10 s scan sees none, the screen stays
with *Your recorder isn't ready to pair yet…*. **Not now** leaves.

## Always listening

Reconnects go through the bonded identity address on Android (the recorder
advertises a private address that rotates every 15 min). A pairing problem on
an automatic attempt sets the status to *Paired to another phone* or *Pairing
needs a reset*; from the second in a row the retry waits **10 min** instead of
a minute (`ReconnectBackoff.refusedDelay`). Success, or turning the mode off
and on, clears it.

## Settings

**PAIRING** shows only when this phone is known to own the recorder (connected
or remembered): *Paired to this phone*, *Since 2 Sep*, and **Pair a new
phone**, which explains what to do on the new phone.

## Known limits

- Error text is matched as text where the platform gives nothing else: iOS
  sends `localizedDescription` only, so on a non-English iPhone a disconnect
  reason may be missed; the 2 s drop rule still catches a refusal.
- `universal_ble` has no bonded-devices list; the app's own channel supplies
  it on Android. With two bonded recorders the remembered id is used as is.
- A stale bond cannot be removed by the app (`unpair` is a hidden Android API
  and does not exist on iOS); the user does it in Bluetooth settings.
