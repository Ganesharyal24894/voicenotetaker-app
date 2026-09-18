#!/usr/bin/env bash
#
# Copies the voice notes off a USB-connected iPhone onto this computer.
#
#   tool/pull_iphone_notes.sh [destination-root]
#
# Default destination root: ~/personalProjects/notetaker-data, or $NOTETAKER_DATA.
# Each run writes a new directory under it:
#
#   notetaker-data/iphone-20260918-2115/
#     recordings/     voicenote-*.wav and every sidecar beside them
#     MANIFEST.tsv    one line per file: size, mtime, sha256, name
#     SUMMARY.txt     counts, bytes, and what was skipped
#
# NOTHING ON THE PHONE IS TOUCHED. The mount is read-only and this script has
# no delete path at all; the phone keeps every note it had. Emptying the phone
# is a thing you do in the app, on purpose, after you have checked the copy.
#
# HOW IT REACHES THE FILES. The app sets UIFileSharingEnabled, so iOS exposes
# its Documents directory over AFC - the same channel Finder's "Files" tab
# uses. `ifuse` mounts that as a normal folder. No jailbreak, no backup, no
# developer account; the phone just has to be unlocked and to have trusted
# this computer once.
#
# WHAT YOU NEED INSTALLED (Debian/Ubuntu):
#
#   sudo apt install libimobiledevice-utils ifuse
#
# On a first connection the iPhone asks "Trust This Computer?". Say yes with
# the phone unlocked, then run this again.
#
# LINUX. It uses GNU `find -printf`, `stat -c` and `date -r`, so it wants GNU
# coreutils. On a Mac there is no need for any of this: Finder shows the same
# folder under the phone's "Files" tab - see doc/ios-install.md.

set -euo pipefail

readonly BUNDLE_ID='com.ganeshsharma.voicenotetakerApp'
readonly APP_NAME='voiceNotetaker'

DEST_ROOT="${1:-${NOTETAKER_DATA:-$HOME/personalProjects/notetaker-data}}"

# Set by mount_documents; read by the EXIT trap, which is why they are global.
MOUNT_POINT=''
MOUNTED=0

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# -- 1. the tools -------------------------------------------------------------
#
# Checked together and reported together: being told about one missing package
# per run, three runs in a row, is a worse morning than being told once.

require_tools() {
  local missing=()
  local tool
  for tool in idevice_id ideviceinfo ifuse; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]})); then
    die "$(cat <<EOF
these commands are not installed: ${missing[*]}

Install them and run this again:

    sudo apt install libimobiledevice-utils ifuse

(ifuse is the one that mounts the phone; libimobiledevice-utils is idevice_id
and ideviceinfo, which find it and check it trusts this computer.)
EOF
)"
  fi
  command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is not installed.'
}

# -- 2. the phone -------------------------------------------------------------

find_device() {
  local udids
  udids=$(idevice_id -l 2>/dev/null || true)

  if [[ -z "${udids//[[:space:]]/}" ]]; then
    die "$(cat <<'EOF'
no iPhone is connected.

  * Plug it in with a cable that carries data, not a charge-only one.
  * Unlock the phone.
  * If it asks "Trust This Computer?", tap Trust and type the passcode.

Then run this again.
EOF
)"
  fi

  local count
  count=$(printf '%s\n' "$udids" | grep -c . || true)
  if ((count > 1)); then
    say "more than one device is plugged in:"
    printf '  %s\n' $udids
    die 'unplug the ones you do not want, then run this again.'
  fi

  UDID=$(printf '%s\n' "$udids" | head -1)
}

check_trusted() {
  local name
  if ! name=$(ideviceinfo -u "$UDID" -k DeviceName 2>&1); then
    die "$(cat <<EOF
the phone is plugged in but this computer is not trusted by it.

ideviceinfo said: ${name}

Unlock the phone, unplug it and plug it back in, and tap Trust on the
"Trust This Computer?" prompt. It only appears while the phone is unlocked.
EOF
)"
  fi
  DEVICE_NAME="$name"
  say "phone: ${DEVICE_NAME} (${UDID})"
}

# -- 3. the mount -------------------------------------------------------------

# MOUNTED IS CLEARED ONLY AFTER THE UNMOUNT ACTUALLY WORKED. If it is cleared
# first, an unmount that failed - a shell still sitting inside the mount, a
# straggling reader - looks like a success, and the EXIT trap then returns at
# the first line instead of trying again. The phone stays mounted on a temp
# directory until somebody notices.
unmount_documents() {
  ((MOUNTED)) || return 0
  # fusermount3 on current Debian/Ubuntu, fusermount on older ones.
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -u "$MOUNT_POINT" 2>/dev/null || return 0
  else
    fusermount -u "$MOUNT_POINT" 2>/dev/null || return 0
  fi
  MOUNTED=0
  # Only ever removes a directory this script made and left empty.
  rmdir "$MOUNT_POINT" 2>/dev/null || true
}

# A handler that RETURNS is fine on EXIT and wrong on a signal: bash runs it
# and then carries on where it was. Ctrl-C and a kill each unmount and then
# leave, with the exit code the shell convention asks for.
trap unmount_documents EXIT
trap 'unmount_documents; exit 130' INT
trap 'unmount_documents; exit 143' TERM

mount_documents() {
  MOUNT_POINT=$(mktemp -d "${TMPDIR:-/tmp}/iphone-notes-XXXXXX")
  local output
  if ! output=$(ifuse -u "$UDID" --documents "$BUNDLE_ID" -o ro "$MOUNT_POINT" 2>&1); then
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    die "$(cat <<EOF
could not open ${APP_NAME}'s files on the phone.

ifuse said: ${output:-(nothing)}

The usual causes, in the order worth checking:

  * The app is not installed on this phone, or SideStore's 7 days ran out and
    it was removed. Install or refresh it, open it once, and try again.
  * The build on the phone is older than the one that turned file sharing on.
    Open SideStore, refresh the source, and update to 1.0.0.34 or newer.
  * The phone is locked. Unlock it and run this again.
  * Your user is not allowed to use FUSE. Check you are in the 'fuse' group,
    or run this after: sudo usermod -aG fuse \$USER   (then log out and in).
EOF
)"
  fi
  MOUNTED=1
}

# -- 4. the copy --------------------------------------------------------------
#
# Copies the whole `recordings/` directory: the WAVs and every sidecar beside
# them, because a transcript without its recording and a recording without its
# speaker names are both half a note. Nothing is filtered by name - a sidecar
# added to the app later comes across without this script being changed.

copy_notes() {
  local source="$MOUNT_POINT/recordings"
  if [[ ! -d "$source" ]]; then
    die "$(cat <<EOF
${APP_NAME} is reachable on the phone, but it has no 'recordings' folder yet.

That means no note has been saved on this phone. Record one and try again.
(What is there: $(ls -A "$MOUNT_POINT" 2>/dev/null | tr '\n' ' ' || echo 'nothing'))
EOF
)"
  fi

  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  DEST="$DEST_ROOT/iphone-$stamp"
  mkdir -p "$DEST/recordings"

  step "copying from the phone"
  # -a keeps the modification times, which are the only record of when a note
  # was captured that does not depend on parsing its name. No --delete, ever:
  # this is one-way, phone to laptop.
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --info=progress2 "$source/" "$DEST/recordings/"
  else
    cp -a "$source/." "$DEST/recordings/"
  fi
}

# -- 5. the check -------------------------------------------------------------
#
# Counts and bytes on both sides, then sha256 of what landed. A copy off a
# phone over USB is not something to take on trust: AFC can hand back a short
# read if the phone suspends mid-transfer, and a truncated WAV plays fine for
# most of its length before it stops.

verify_copy() {
  local source="$MOUNT_POINT/recordings"

  local phone_files phone_bytes local_files local_bytes
  phone_files=$(find "$source" -maxdepth 1 -type f | wc -l)
  phone_bytes=$(find "$source" -maxdepth 1 -type f -printf '%s\n' | awk '{t+=$1} END {print t+0}')
  local_files=$(find "$DEST/recordings" -maxdepth 1 -type f | wc -l)
  local_bytes=$(find "$DEST/recordings" -maxdepth 1 -type f -printf '%s\n' | awk '{t+=$1} END {print t+0}')

  step "checking the copy"
  say "on the phone: ${phone_files} files, ${phone_bytes} bytes"
  say "copied here:  ${local_files} files, ${local_bytes} bytes"

  local wavs transcripts
  wavs=$(find "$DEST/recordings" -maxdepth 1 -name '*.wav' | wc -l)
  transcripts=$(find "$DEST/recordings" -maxdepth 1 -name '*.transcript.json' | wc -l)

  # sha256 of everything that landed, sorted by name so two pulls diff
  # cleanly. This is the file to compare when a transcript looks wrong and the
  # question is whether the audio changed.
  step "writing MANIFEST.tsv"
  {
    printf 'bytes\tmodified\tsha256\tname\n'
    find "$DEST/recordings" -maxdepth 1 -type f -print0 \
      | sort -z \
      | while IFS= read -r -d '' path; do
          # Each field falls back to '?' rather than to an empty column: this
          # runs in a pipeline subshell, where `set -e` would not stop the
          # loop, and a file that went away between the find and the read
          # would otherwise write a row that looks like a zero-byte file.
          printf '%s\t%s\t%s\t%s\n' \
            "$(stat -c %s "$path" 2>/dev/null || echo '?')" \
            "$(date -r "$path" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" \
            "$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1 || echo '?')" \
            "$(basename "$path")"
        done
  } > "$DEST/MANIFEST.tsv"

  {
    say "pulled  $(date -Iseconds)"
    say "phone   ${DEVICE_NAME} (${UDID})"
    say "app     ${BUNDLE_ID}"
    say "files   ${local_files} of ${phone_files} on the phone"
    say "bytes   ${local_bytes} of ${phone_bytes} on the phone"
    say "notes   ${wavs} recordings, ${transcripts} with a transcript"
    say ""
    say "Nothing was deleted from the phone. This copy is one way."
  } > "$DEST/SUMMARY.txt"

  if [[ "$local_files" -ne "$phone_files" || "$local_bytes" -ne "$phone_bytes" ]]; then
    say ""
    say "WARNING: the copy does not match the phone. Nothing on the phone was"
    say "touched, so running this again is safe and is what to do next."
    say "What did arrive is in: $DEST"
    exit 2
  fi

  step "done"
  say "$DEST"
  say "${wavs} recordings, ${transcripts} transcripts, ${local_bytes} bytes."
  say "The phone still has all of them."
}

main() {
  require_tools
  find_device
  check_trusted
  mount_documents
  copy_notes
  verify_copy
  unmount_documents
}

main "$@"
