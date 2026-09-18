#!/usr/bin/env python3
"""Decode a source JSON the way SideStore does, and fail if it would not load.

WHY THIS EXISTS
---------------
A source that SideStore cannot decode does not degrade gracefully. There is no
partial load and no app-by-app skipping: one bad field anywhere throws, and the
user sees "Decoding failed: Data corrupted" with nothing installable behind it.
That happened to this source once already, and it is invisible from a machine
with no iPhone on it -- `json.load()` is perfectly happy with a document
SideStore refuses.

So this is a line-by-line mirror of SideStore's own Codable implementations,
read from the code rather than from the docs (the docs describe AltStore 2.x and
SideStore is a fork of the 1.x line, which is how this source went wrong):

  AltStore/Core/Model/Source.swift      Source.init(from:)
  AltStore/Core/Model/StoreApp.swift    StoreApp.init(from:), decodeVersions,
                                        setVersions, createNewAppVersion
  AltStore/Core/Model/AppVersion.swift  AppVersion.init(from:)
  AltStore/Core/Model/AppPermission.swift   AppPermissions.init(from:)
  AltStore/Core/Model/AppScreenshot.swift   AppScreenshots.init(from:)
  Shared/Extensions/UIColor+Hex.swift   UIColor(hexString:)
  SideStore/Core/Operations/StandaloneOperations/FetchSourceOperation.swift
                                        the JSONDecoder and its date strategy
  (github.com/SideStore/SideStore, branch develop, and tag 0.6.3 -- the decoder
  is the same in both.)

It checks the things that make that decoder THROW, in its order, and reports the
coding path the way SideStore would. It is deliberately strict where SideStore is
strict and quiet where SideStore is lenient; being stricter than SideStore would
be its own kind of wrong.

Usage:  check_altstore_source.py apps.json
"""

import json
import re
import sys

# Every value SideStore decodes as `Date` goes through one ISO8601DateFormatter
# with formatOptions [.withFullDate, .withFullTime, .withTimeZone], then a
# second pass with [.withFullDate] alone. Anything else throws
# DecodingError.dataCorrupted("Date is in invalid format.") and takes the whole
# source with it.
#
# The pattern below was NARROWED to match reality, not the option names. A first
# guess at it rejected "+00:00" on the theory that .withColonSeparatorInTimeZone
# was absent -- and then rejected SideStore's own community source, which is
# full of "+00:00" and loads fine. .withTimeZone parses Z, +HHMM and +HH:MM
# alike; the colon option only controls how dates are WRITTEN. Fractional
# seconds are not accepted unless .withFractionalSeconds is set, and it is not.
FULL = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:?\d{2})$")
DATE_ONLY = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# The eight AltStore accepts. Anything else is not an error -- StoreApp stores
# the raw lowercased string -- but it will not land in a category either.
CATEGORIES = {"developer", "entertainment", "games", "lifestyle", "other",
              "photo-video", "social", "utilities"}

problems = []
warnings = []


def fail(path, msg):
    problems.append(f"{path}: {msg}")


def check_date(value, path):
    if not isinstance(value, str):
        return fail(path, f"date must be a string, got {type(value).__name__}")
    if not (FULL.match(value) or DATE_ONLY.match(value)):
        fail(path, f"'{value}' is not a date SideStore's ISO8601 formatter "
                   "accepts: YYYY-MM-DD, or YYYY-MM-DDTHH:MM:SS with a Z or a "
                   "+HHMM/+HH:MM offset, and no fractional seconds")


def check_hex(value, path):
    # UIColor(hexString:) trims non-alphanumerics from both ends, then requires
    # exactly 3, 6 or 8 hex digits. Anything else returns nil, and the decoder
    # turns a nil colour into dataCorrupted("Hex code is invalid.").
    if not isinstance(value, str):
        return fail(path, "tintColor must be a string")
    hexpart = re.sub(r"^[^0-9A-Fa-f]+|[^0-9A-Fa-f]+$", "", value)
    if len(hexpart) not in (3, 6, 8) or not re.fullmatch(r"[0-9A-Fa-f]+", hexpart):
        fail(path, f"'{value}' is not a 3, 6 or 8 digit hex colour")


def check_url(value, path):
    if not isinstance(value, str) or not value:
        return fail(path, "must be a non-empty URL string")
    if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", value):
        fail(path, f"'{value}' is not an absolute URL")


def main():
    raw = open(sys.argv[1], "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        fail("<file>", "starts with a UTF-8 BOM")
    try:
        src = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        print(f"FAIL <file>: not valid UTF-8 JSON ({e})")
        return 1

    # ---- Source.init(from:) -------------------------------------------------
    # `name` is the only unconditional decode(); everything else is
    # decodeIfPresent. `identifier` maps to groupID and is optional in the
    # decoder, but AltStore refuses a source whose identifier changes between
    # refreshes, so treat a missing one as a problem rather than a warning.
    if not isinstance(src.get("name"), str):
        fail("name", "required, and must be a string")
    if not isinstance(src.get("identifier"), str):
        fail("identifier", "required in practice: the client pins a source to "
                           "it and rejects one that changes")
    if "version" in src and not isinstance(src["version"], int):
        fail("version", "the SOURCE-level version is decoded as Int")
    if "tintColor" in src:
        check_hex(src["tintColor"], "tintColor")
    for key in ("iconURL", "headerURL", "website", "patreonURL"):
        if key in src:
            check_url(src[key], key)
    if "userInfo" in src and not all(isinstance(v, str) for v in src["userInfo"].values()):
        fail("userInfo", "decoded as [String: String]; every value must be a string")

    apps = src.get("apps", [])
    if not isinstance(apps, list):
        return _report(fail("apps", "must be an array"))
    if not apps:
        warnings.append("apps: empty, so the source shows nothing")

    ids = [a.get("bundleIdentifier") for a in apps]
    for dupe in {i for i in ids if ids.count(i) > 1}:
        fail("apps", f"two apps share bundleIdentifier '{dupe}'")

    for i, app in enumerate(apps):
        p = f"apps > {i}"
        # ---- StoreApp.init(from:) : the unconditional decodes -------------
        for key in ("name", "bundleIdentifier", "developerName",
                    "localizedDescription"):
            if not isinstance(app.get(key), str):
                fail(f"{p} > {key}", "required, and must be a string")
        if "iconURL" not in app:
            fail(f"{p} > iconURL", "required")
        else:
            check_url(app["iconURL"], f"{p} > iconURL")
        if "tintColor" in app:
            check_hex(app["tintColor"], f"{p} > tintColor")
        if "category" in app and app["category"].lower() not in CATEGORIES:
            warnings.append(f"{p} > category: '{app['category']}' is not one of "
                            f"{sorted(CATEGORIES)}; it will show as no category")

        # ---- appPermissions ------------------------------------------------
        perms = app.get("appPermissions")
        if perms is not None:
            ents = perms.get("entitlements")
            if ents is not None and not (
                    isinstance(ents, list) and
                    all(isinstance(e, (str, dict)) for e in ents)):
                fail(f"{p} > appPermissions > entitlements",
                     "must be a list of strings, a list of {name: ...} objects, "
                     "or an object keyed by entitlement")
            priv = perms.get("privacy")
            if priv is not None and not isinstance(priv, (list, dict)):
                fail(f"{p} > appPermissions > privacy",
                     "must be an object of key -> usage description, or the "
                     "legacy list of {name, usageDescription}")

        # ---- screenshots ---------------------------------------------------
        shots = app.get("screenshots")
        if shots is not None and not isinstance(shots, (list, dict)):
            fail(f"{p} > screenshots", "must be an array or an {iphone, ipad} object")

        # ---- decodeVersions / AppVersion.init(from:) -----------------------
        versions = app.get("versions")
        if versions is None:
            # Without versions[] the decoder builds one from the legacy fields,
            # and there every one of them is an unconditional decode().
            for key in ("version", "versionDate", "downloadURL", "size"):
                if key not in app:
                    fail(f"{p} > {key}", "required when there is no versions[]")
        else:
            if not isinstance(versions, list) or not versions:
                fail(f"{p} > versions", "must be a non-empty array "
                                        "(setVersions throws on an empty one)")
            for j, v in enumerate(versions or []):
                vp = f"{p} > versions > {j}"
                if not isinstance(v.get("version"), str):
                    fail(f"{vp} > version", "required, and must be a string")
                if "date" not in v:
                    fail(f"{vp} > date", "required")
                else:
                    check_date(v["date"], f"{vp} > date")
                if "downloadURL" not in v:
                    fail(f"{vp} > downloadURL", "required")
                else:
                    check_url(v["downloadURL"], f"{vp} > downloadURL")
                if not isinstance(v.get("size"), int) or isinstance(v.get("size"), bool):
                    fail(f"{vp} > size", "required, and must be a whole number "
                                         "of bytes (decoded as Int64)")
                elif v["size"] > 2_147_483_647:
                    fail(f"{vp} > size", "over Int32; SideStore 0.6.x narrows the "
                                         "app's size to Int32 and will trap")
                for key in ("buildVersion", "localizedDescription", "sha256",
                            "minOSVersion", "maxOSVersion"):
                    if key in v and not isinstance(v[key], str):
                        fail(f"{vp} > {key}", "must be a string if present")
                if "sha256" in v and not re.fullmatch(r"[0-9a-fA-F]{64}", v["sha256"]):
                    fail(f"{vp} > sha256", "must be 64 hex characters")

            # ---- the flat downloadURL, and why it is not optional ----------
            # StoreApp tries platformURLs, then this flat key, and only then
            # falls back to a Core Data property it just wrote -- a read its own
            # comment admits "might still be faulted". When that comes back nil
            # it throws dataCorrupted and the WHOLE SOURCE fails to load.
            if "platformURLs" not in app and "downloadURL" not in app:
                fail(f"{p} > downloadURL",
                     "missing. SideStore reaches for this before versions[] and "
                     "throws dataCorrupted when neither it nor platformURLs is "
                     "present. Mirror versions[0] into the legacy app-level "
                     "version / versionDate / versionDescription / downloadURL "
                     "/ size keys.")
            latest = versions[0] if versions else {}
            for legacy, modern in (("version", "version"),
                                   ("versionDate", "date"),
                                   ("downloadURL", "downloadURL"),
                                   ("size", "size")):
                if legacy not in app:
                    fail(f"{p} > {legacy}",
                         f"missing; mirror versions[0].{modern}")
                elif app[legacy] != latest.get(modern):
                    # Not fatal -- AltStore's own source freezes these at old
                    # releases deliberately -- but for a source generated from
                    # one build it means something has drifted.
                    warnings.append(
                        f"{p} > {legacy}: is {app[legacy]!r} but "
                        f"versions[0].{modern} is {latest.get(modern)!r}; a "
                        "client reading only the legacy fields would offer a "
                        "different build")
            if "versionDate" in app:
                check_date(app["versionDate"], f"{p} > versionDate")
            if "size" in app and not isinstance(app["size"], int):
                fail(f"{p} > size", "decoded as Int32; must be a whole number")

            builds = [int(v["buildVersion"]) for v in versions
                      if str(v.get("buildVersion", "")).isdigit()]
            if builds and builds != sorted(builds, reverse=True):
                fail(f"{p} > versions",
                     f"not newest-first {builds}. AltStore takes versions[0] as "
                     "the latest and never sorts, so the order IS the ordering")
            seen = set()
            for v in versions or []:
                key = (v.get("version"), v.get("buildVersion"))
                if key in seen:
                    fail(f"{p} > versions",
                         f"two entries share version/buildVersion {key}; each "
                         "must differ from the one before it")
                seen.add(key)

    featured = src.get("featuredApps")
    if featured is not None:
        known = {a.get("bundleIdentifier") for a in apps}
        for b in featured:
            if b not in known:
                warnings.append(f"featuredApps: '{b}' is not an app in this source")

    return _report()


def _report(_=None):
    for w in warnings:
        print(f"warn  {w}")
    for p in problems:
        print(f"FAIL  {p}")
    if problems:
        print(f"\n{len(problems)} problem(s): SideStore would refuse this source.")
        return 1
    print("SideStore would decode this source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
