# Putting the app on your iPhone

You do not need a Mac, and you do not need to pay Apple anything. You do need
about twenty minutes the first time.

**The address to paste, once you get to it:**

```
https://ganesharyal24894.github.io/voicenotetaker-app/apps.json
```

Or open <https://ganesharyal24894.github.io/voicenotetaker-app/> on the iPhone
itself and tap **Add to SideStore**.

## What SideStore is

Apple only lets you install an app from the App Store — unless *you* are the
developer. Then Xcode can put your own app on your own phone for a week at a
time. That is the door SideStore uses.

SideStore is an app on your iPhone that does what Xcode would do. You sign in
with your Apple ID, it signs the app with your Apple ID, and it installs it.
Apple is not involved beyond checking that the Apple ID is real. Nothing is
reviewed, nothing is published, nobody else gets a copy.

So the app on your phone is signed as **you**. It is not the same file as
anyone else's, and it is not on anyone's store.

## Two things to know before you start

**It expires after 7 days.** A free Apple ID gets a 7-day certificate. On day
8 the app stops opening — it does not delete itself, and it does not lose your
notes, it just refuses to launch until SideStore signs it again. SideStore has
a Refresh button, and it can refresh in the background if you leave it running.
Get into the habit of opening SideStore once a week.

**A free Apple ID allows 3 sideloaded apps at a time.** SideStore itself is one
of the three. So this app plus SideStore is two, and you have one slot left.
If you hit the limit, remove something before installing.

## Installing it, start to finish

1. **Get SideStore onto the phone.** Follow the official instructions at
   <https://docs.sidestore.io/> — they change, and they are the people who
   would know. This is the fiddly part; the rest is a few taps.
2. **Open SideStore → Browse → Sources → +.**
3. **Paste the address at the top of this page.** voiceNotetaker appears.
4. **Tap it, then Install.** Enter your Apple ID when asked. Use an
   app-specific password if you have two-factor on, which you should.
5. **Trust the certificate.** iPhone Settings → General → VPN & Device
   Management → tap your Apple ID → Trust. iOS will not open the app until you
   do, and the error it gives instead ("Untrusted Developer") does not say so
   clearly.
6. **Open the app.** It will ask for Bluetooth. Say yes, or it cannot find the
   recorder.

## When there is a new build

Every push to `master` that passes the tests publishes a new build, and the
source updates itself within a minute or two. Nothing needs to be re-added.

On the phone: **SideStore → Browse → Sources → voiceNotetaker → Refresh**, and
the new version appears with an **Update** button. Your notes stay where they
are; an update replaces the app, not its files.

Each build is named `1.0.0.N`, where `N` is the CI run that made it. Higher is
newer. The version SideStore shows you is the same one iPhone Settings shows
for the app, so you can always tell what is actually on the phone.

If you want an older build, SideStore lists the last ten under the app's
version history and will install any of them.

## Getting your notes onto a computer

Your recordings and their transcripts live in the app's own **Documents**
folder on the phone. From build **1.0.0.34** that folder is open, so there are
three ways to get at it. Nothing here uploads anything anywhere - every route
below is the phone handing a file to something you chose.

### 1. The Files app, on the phone itself

Open **Files -> Browse -> On My iPhone -> voiceNotetaker -> recordings**.

Every note is there: `voicenote-20260918-143005.wav` plus small `.json` files
beside it holding its transcript and its speaker names. You can play one, copy
it, AirDrop it, or move the lot into iCloud Drive or a Dropbox folder if you
want to. Deleting from here deletes for real - the app has no second copy.

### 2. Over a cable, which is what testing uses

Plug the phone into a Linux or macOS machine and copy everything across in one
command. On this laptop, once:

```
sudo apt install libimobiledevice-utils ifuse
```

Then, with the phone plugged in and unlocked:

```
cd ~/personalProjects/voicenotetaker-app
tool/pull_iphone_notes.sh
```

The first time, the phone asks **"Trust This Computer?"**. Tap Trust and type
the passcode, then run it again.

It lands everything in a new folder named for the moment you pulled it:

```
~/personalProjects/notetaker-data/iphone-20260918-2115/
  recordings/     every .wav and every .json beside it
  MANIFEST.tsv    size, time and sha256 of each file
  SUMMARY.txt     what was copied, and from which phone
```

It copies. It never deletes anything on the phone, and it has no code that
could: the phone is mounted read-only. If the counts or the byte totals do not
match it says so and stops with a non-zero exit, and running it again is the
right response. To put the copy somewhere else, pass a directory:
`tool/pull_iphone_notes.sh ~/somewhere-else`.

If it cannot find the phone it will say which of the three usual things is
wrong - cable, lock screen, or Trust. If `ifuse` says `ApplicationLookupFailed`
the app on the phone is older than 1.0.0.34; refresh the source in SideStore
and update.

*(macOS instead of Linux: Finder shows the same folder. Plug the phone in,
open Finder, pick the phone in the sidebar, then the **Files** tab, and drag
`voiceNotetaker` out. Same files, same folder.)*

### 3. No cable: Export notes

**Recorder settings -> Export notes.** Pick **Today**, **Last 7 days** or
**Everything**; it tells you how many notes and how big the zip will be before
it makes one. Tap **Make the zip**, wait for the bar, then **Send it** - AirDrop
to a Mac, Save to Files, attach it to a message, whatever the phone offers.

The zip is uncompressed, so it weighs about what the notes weigh; a day of
continuous recording can be several hundred megabytes, and the phone needs room
for it as well as for the notes themselves. It says so rather than filling up.

The zip is a copy; your notes have not moved. It is thrown away when you close
the sheet without sending it, and if you did send it, the next time you open
**Export notes** - not the moment the sheet closes, because AirDrop of a big
file carries on after the sheet goes away and deleting it mid-flight would
break the transfer.

### About backups and iCloud

This is worth being clear about, because nothing here changed it.

The Documents folder has always been part of the iPhone's backup - the iCloud
backup if you have iCloud Backup on, or the Finder/iTunes backup if you back up
to a computer (that one is only encrypted if you ticked "Encrypt local
backup"). That was true before these builds and it is true now. Opening the
folder to the Files app changes who can **see** it on the phone; it does not
change where its bytes go.

So: if iCloud Backup is on, your recordings are in it, as they already were.
Nothing about them is separately synced to iCloud Drive, nothing is uploaded by
the app, and the app makes no network request that carries audio - the only
thing it ever downloads is the speech model, and the only thing it ever uploads
is nothing.

If you would rather your audio were not in the iCloud backup, turn iCloud
Backup off for this app in **Settings -> [your name] -> iCloud -> Manage
Storage -> Backups**, or leave **Delete audio after 24 h** on in Recorder
settings so there is little audio to back up. We have deliberately not excluded
the folder from backup in the app: that would mean a restored phone came back
with no notes, silently, which is a worse surprise than this one.

## What this app cannot do on an iPhone

None of these are bugs, and none of them are being worked around. They are what
iOS allows.

**No alert when recording stops.** On Android, if the recorder disconnects or
stops saving, the phone buzzes and shows a notification. On iPhone there is no
buzz and no notification. You will see the problem on the app's own screen the
next time you open it, and that is the only place it appears. The app does not
run a timer pretending otherwise.

**Transcripts finish when you open the app.** Notes keep saving while the
recorder is linked, but the transcription only runs while the app is on screen.
Open the app for a minute and it catches up.

**The speech model downloads inside the app, over Wi-Fi.** Transcription runs
entirely on the phone, so the language pack has to be on the phone. Open a note
that has not been written down and tap **Download the language pack**, or go to
**Recorder settings → Speech models**. Hindi is 197 MB and speaker detection is
34 MB; English is another 136 MB if you want it. It is a one-time download and
it works offline afterwards.

**A download pauses when you leave the app.** iOS suspends the app within
seconds of it going off screen, so the download stops where it is and carries
on from that byte when you come back. Nothing is lost, and nothing downloads
behind your back. (On Android it keeps going while the app is open.)

## If something goes wrong

**"Untrusted Developer" when you open it.** Step 5 above — the Trust step.

**It stopped opening.** Seven days passed. Open SideStore and refresh.

**"Maximum number of apps" during install.** Three-app limit. Remove one.

**The install fails with nothing useful on screen.** Check the source loaded a
build at all — open the address at the top of this page in Safari and look for
a `downloadURL`. If SideStore is holding a stale copy, remove the source and
add it again.

## How the build gets there (for the curious)

`.github/workflows/build.yml` runs the tests on Linux, then builds the iOS app
on a hosted Mac. The build is *unsigned* — CI has no Apple ID and needs none,
which is why no secret of yours is anywhere in this repo. The unsigned `.ipa`
goes out as a GitHub release, and `tool/altstore_source.py` rebuilds
`apps.json` from the list of releases and publishes it to GitHub Pages.

SideStore is what adds the signature, on your phone, with your Apple ID. That
step cannot happen anywhere else.
