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
