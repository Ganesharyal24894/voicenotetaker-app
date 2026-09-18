#!/usr/bin/env python3
"""Generate the AltStore/SideStore source JSON for this repo's iOS builds.

WHY THIS EXISTS
---------------
SideStore installs an app by downloading a .ipa from a plain URL listed in a
"source" JSON file. A GitHub Actions *artifact* cannot be that URL: it needs a
logged-in session and it expires. A GitHub *release asset* on a public repo can
be -- it is an unauthenticated, permanent https URL. So every green master build
publishes a release, and this script turns the list of releases back into the
source JSON SideStore reads.

The history comes from the releases themselves, not from state kept in the repo:
each release carries a `build.json` asset describing exactly the .ipa sitting
next to it. Running this on a fresh checkout reproduces the whole `versions[]`
list, so the source can never drift from what is actually downloadable.

Shape of the output: AltStore "Sources v2", as specified at
  https://faq.altstore.io/developers/make-a-source
  https://faq.altstore.io/developers/updating-apps
(the older /distribute-your-apps/ paths now 404), cross-checked against two
sources that are live and consumed by real installs:
  https://apps.altstore.io                           (Riley Testut's own)
  https://quarksources.github.io/quantumsource.json
SideStore consumes the format unchanged -- https://docs.sidestore.io/docs/
advanced/app-sources says it "is fully compatible with AltStore Sources".

Three rules from those docs drive the whole design of this file:

  1. ORDER IS THE VERSION ORDERING. AltStore takes versions[0] as the latest,
     walks down only to skip entries the device's iOS is too old for, and asks
     "is this DIFFERENT from what is installed" -- not "is it greater". It does
     not compare dates and it does not parse semver. So this script sorts
     newest-first itself rather than trusting the order the API returned.

  2. version AND buildVersion ARE CHECKED AGAINST THE .ipa. AltStore 2.0
     "verifies downloaded app version matches source" and refuses to install
     when it does not. Both values here come from the Info.plist of the bundle
     that was actually zipped, recorded at build time -- never retyped.

  3. appPermissions IS CHECKED TOO: "AltStore will refuse to install any app
     whose permissions do not match". So it is read out of the built app, not
     written by hand here.

Usage:  altstore_source.py --repo OWNER/NAME --pages-url https://... > apps.json
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"

# Only releases whose tag starts with this are iOS builds. Namespaced so a
# future Android or firmware release in the same repo cannot wander into the
# source and offer SideStore something it cannot install.
TAG_PREFIX = "ios-v"

# SideStore shows a version history, so more than one entry is useful -- but an
# unbounded list means an unbounded number of releases to keep. Ten builds is
# far more history than a 7-day certificate makes meaningful, and it is the
# same number the workflow prunes to.
KEEP = 10


def api(path, token):
    req = urllib.request.Request(API + path)
    req.add_header("Accept", "application/vnd.github+json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def fetch_asset(url, token):
    req = urllib.request.Request(url)
    # A release asset's api.github.com URL returns the FILE only when asked for
    # octet-stream; the default Accept hands back the asset's metadata instead.
    req.add_header("Accept", "application/octet-stream")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    p.add_argument("--pages-url", required=True,
                   help="Base URL the source and icon are served from, no trailing slash.")
    args = p.parse_args()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    releases = api(f"/repos/{args.repo}/releases?per_page=100", token)

    versions = []
    newest = None
    for rel in releases:
        if rel.get("draft") or not rel.get("tag_name", "").startswith(TAG_PREFIX):
            continue
        assets = {a["name"]: a for a in rel.get("assets", [])}
        ipa = assets.get("voicenotetaker.ipa")
        meta_asset = assets.get("build.json")
        if not ipa or not meta_asset:
            # A release whose upload was interrupted. Leaving it out is right: a
            # versions[] entry whose downloadURL 404s makes SideStore fail the
            # install with nothing on screen to explain why.
            print(f"skipping {rel['tag_name']}: missing assets", file=sys.stderr)
            continue
        try:
            meta = fetch_asset(meta_asset["url"], token)
        except (urllib.error.URLError, ValueError) as e:
            print(f"skipping {rel['tag_name']}: build.json unreadable ({e})", file=sys.stderr)
            continue

        # `size` must be the real byte count of the file at downloadURL, and
        # GitHub is the authority on that -- not whatever the mac runner wrote
        # down before uploading. SideStore shows it before the download starts.
        size = ipa["size"]

        # GitHub computes its own sha256 for every release asset, returned as
        # "sha256:<hex>". Cross-checking it against the hash the build recorded
        # catches a truncated or replaced upload here, where it is a line in a
        # log, instead of on the phone as an unexplained install failure.
        digest = (ipa.get("digest") or "")
        digest = digest[7:] if digest.startswith("sha256:") else ""
        recorded = meta.get("sha256", "")
        if digest and recorded and digest != recorded:
            print(f"skipping {rel['tag_name']}: sha256 mismatch "
                  f"(build recorded {recorded}, GitHub has {digest})", file=sys.stderr)
            continue
        sha256 = digest or recorded

        versions.append({
            "version": meta["version"],
            "buildVersion": meta["buildVersion"],
            "date": meta["date"],
            "localizedDescription": meta.get("notes") or f"Build {meta['buildVersion']}.",
            "downloadURL": ipa["browser_download_url"],
            "size": size,
            "sha256": sha256,
            "minOSVersion": meta["minOSVersion"],
        })
        if newest is None or int(meta["buildVersion"]) > int(newest["buildVersion"]):
            newest = meta

    if not versions:
        sys.exit("no published iOS releases found -- nothing to put in the source")

    # Rule 1 from the header: position IS the ordering, so make it explicit.
    versions.sort(key=lambda v: int(v["buildVersion"]), reverse=True)
    versions = versions[:KEEP]

    icon = f"{args.pages_url}/icon.png"
    source = {
        "name": "voiceNotetaker",
        # Never change this. AltStore treats a source's identifier as its
        # identity: it refuses a source whose identifier changed on a refresh,
        # and refuses to add one that collides with a source already installed.
        "identifier": "com.ganeshsharma.voicenotetaker.source",
        "apiVersion": "v2",
        "subtitle": "The companion app for the voiceNotetaker recorder.",
        "description": (
            "Builds of the voiceNotetaker iPhone app, straight from CI. Each one "
            "is the build that passed the tests on the commit it is named after. "
            "You sign it with your own Apple ID when you install it, so the copy "
            "on your phone is yours and nobody else's."
        ),
        "iconURL": icon,
        "website": f"https://github.com/{args.repo}",
        "tintColor": "#8B5CF6",
        "featuredApps": [newest["bundleIdentifier"]],
        "apps": [{
            "name": "voiceNotetaker",
            "bundleIdentifier": newest["bundleIdentifier"],
            "developerName": "Ganesh Sharma",
            "subtitle": "Your recorder's notes, on your phone.",
            "localizedDescription": (
                "voiceNotetaker is the phone half of a small wearable recorder.\n"
                "\n"
                "It finds the recorder over Bluetooth, pulls the audio across as "
                "it is spoken, and writes each note to your phone. Notes are "
                "listed by what was said rather than by a file name, and you can "
                "search every word of them.\n"
                "\n"
                "Transcription runs on the phone itself. Nothing is uploaded, "
                "nothing needs an account, and it works with the network off.\n"
                "\n"
                "WHAT IS DIFFERENT ON IPHONE\n"
                "\n"
                "iOS does not let an app keep working in the background the way "
                "Android does, and this app does not pretend otherwise:\n"
                "\n"
                "• Notes keep saving while the recorder is linked, but "
                "transcripts finish when you open the app.\n"
                "• If something stops the recording you will see it on the "
                "screen when you next open the app. There is no alert and no "
                "buzz.\n"
                "• The speech model cannot be downloaded from inside the app "
                "yet, so transcripts report a missing model until that lands.\n"
                "\n"
                "This is a personal project built in the open. The code, and the "
                "build that produced this file, are on GitHub."
            ),
            "iconURL": icon,
            "tintColor": "#8B5CF6",
            # One of the eight values AltStore accepts (developer,
            # entertainment, games, lifestyle, other, photo-video, social,
            # utilities). Anything else silently becomes "other".
            "category": "utilities",
            # Empty on purpose, and honestly so: taking iPhone screenshots
            # needs the app running on a device or a simulator, and the only
            # machine that ever runs this app is the user's own phone.
            "screenshots": [],
            # Read out of the built app, never typed here -- AltStore compares
            # this against the .ipa and refuses the install if it disagrees.
            "appPermissions": newest["appPermissions"],
            "versions": versions,
        }],
        # Required by the spec's example even when there is nothing to say.
        "news": [],
    }
    json.dump(source, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
