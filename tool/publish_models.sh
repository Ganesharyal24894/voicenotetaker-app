#!/usr/bin/env bash
#
# Publishes the speech-model files as assets of a GitHub release, and prints
# the catalogue entries - names, exact sizes and sha256s - to paste into
# `lib/model/model_download.dart`.
#
# WHY A RELEASE OF OUR OWN. The models come from sherpa-onnx releases as
# `.tar.bz2` archives, and the Hindi one from Hugging Face. Unpacking a 197 MB
# member of a bzip2 archive on a phone costs minutes of CPU and a second copy
# of the file in memory, on a device that already has a 350 MB problem. One
# uncompressed asset per file removes the whole step: the phone streams bytes
# to disk, checks one sha256 and renames. See `doc/models.md`.
#
# USAGE
#
#   tool/publish_models.sh <directory> [tag]
#
# <directory> holds one sub-directory per set, named as the catalogue's
# `directoryName`, each holding that set's files under their catalogue names:
#
#   models/
#     indicconformer-hi-int8/  model.int8.onnx  tokens.txt
#     parakeet-tdt-110m-en-int8/
#                              encoder.int8.onnx  decoder.int8.onnx
#                              joiner.int8.onnx   tokens.txt
#     diarization/             segmentation.onnx  campplus.onnx
#
# See `doc/agentFindings/on-device-stt.md` for where each file comes from.
#
# ASSETS ARE NEVER REPLACED IN PLACE. A different set of bytes means a new tag
# and a new `ModelCatalogue.releaseTag`, so a phone that is half way through a
# download can never be handed different bytes for the same URL.

set -euo pipefail

DIR=${1:-}
TAG=${2:-models-v1}
REPO=${REPO:-Ganesharyal24894/voicenotetaker-app}

if [[ -z "$DIR" || ! -d "$DIR" ]]; then
  echo "usage: tool/publish_models.sh <directory-of-models> [tag]" >&2
  exit 2
fi

# `<directory>:<set id>:<files>`. THE DIRECTORY IS NOT ALWAYS THE SET ID. The
# directory is the catalogue's `directoryName` - where the files live on the
# phone - and the asset prefix is the catalogue's `id`, which is what
# `ModelCatalogue.assetName` builds a URL from. They are the same string for
# the two speech sets and they are NOT for the speaker one: it lives in
# `diarization/` and its id is `pyannote-segmentation-3-campplus`.
SETS=(
  "indicconformer-hi-int8:indicconformer-hi-int8:model.int8.onnx tokens.txt"
  "parakeet-tdt-110m-en-int8:parakeet-tdt-110m-en-int8:encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt"
  "diarization:pyannote-segmentation-3-campplus:segmentation.onnx campplus.onnx"
)

# 1. Check every file is there before uploading any of them.
missing=0
for entry in "${SETS[@]}"; do
  rest=${entry#*:}
  dir=${entry%%:*}
  for name in ${rest#*:}; do
    if [[ ! -f "$DIR/$dir/$name" ]]; then
      echo "missing: $DIR/$dir/$name" >&2
      missing=1
    fi
  done
done
[[ $missing -eq 0 ]] || exit 1

# 2. Make the release if it is not there. Released, not a draft: the download
#    is unauthenticated, and a draft's assets are not.
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" \
    --repo "$REPO" \
    --title "Speech models $TAG" \
    --notes "Model files for on-device transcription and speaker detection.
Uncompressed, one asset per file, named <set>--<file>. See doc/models.md."
fi

release_id=$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.id')

# 3. Upload, and print the catalogue as we go.
echo
echo "--- catalogue entries -------------------------------------------------"
for entry in "${SETS[@]}"; do
  rest=${entry#*:}
  dir=${entry%%:*}
  set_id=${rest%%:*}
  total=0
  echo
  echo "// $set_id"
  for name in ${rest#*:}; do
    path="$DIR/$dir/$name"
    asset="$set_id--$name"
    size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path")
    hash=$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$path" | cut -d' ' -f1)
    total=$((total + size))

    # NOT `gh release upload "$path#$asset"`. In `gh`, the text after `#` is a
    # display LABEL, not the asset name - gh always names the asset after the
    # file's basename. That silently uploads `tokens.txt` twice and the second
    # one wins, so the Hindi tokens file would be the Parakeet one. The REST
    # upload endpoint is the only place `name` can be set, so use it.
    #
    # Re-running after a failed upload finishes the job: an asset already
    # there under this name is deleted first. A DIFFERENT set of bytes still
    # belongs in a new tag, not over these.
    old=$(gh api "repos/$REPO/releases/$release_id/assets" --paginate \
      --jq ".[] | select(.name == \"$asset\") | .id" | head -1)
    if [[ -n "$old" ]]; then
      gh api --method DELETE "repos/$REPO/releases/assets/$old" >/dev/null
    fi
    gh api --method POST \
      "https://uploads.github.com/repos/$REPO/releases/$release_id/assets?name=$asset" \
      -H 'Content-Type: application/octet-stream' \
      --input "$path" >/dev/null
    echo "uploaded $asset" >&2

    printf "//   %-20s %12s B  %s\n" "$name" "$size" "$hash"
  done
  printf "//   total %s B\n" "$total"
done

echo
echo "Set ModelCatalogue.releaseTag to '$TAG' if it is not already."
echo "Then check every URL answers, unauthenticated:"
echo "  dart run tool/verify_download.dart --all --head-only"
