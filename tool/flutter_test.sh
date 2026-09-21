#!/usr/bin/env bash
# `flutter test`, with the ccache compiler shim taken off PATH.
#
#   tool/flutter_test.sh                 # the whole suite
#   tool/flutter_test.sh test/codec/     # anything flutter test accepts
#
# WHY. packages/opus_native compiles libopus from source in a Dart build hook,
# and under `flutter test` that hook finds its compiler with `which clang`. A
# shell that puts Debian's /usr/lib/ccache shim first on PATH hands it the
# ccache binary instead, and the build - and so every test - fails. The hook
# names the problem when it happens; this script just avoids it. Nothing else
# about the run changes, and CI does not need it.
set -euo pipefail

if [ -f ~/development/flutter-env.sh ]; then
    # shellcheck disable=SC1090
    source ~/development/flutter-env.sh
fi

PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/ccache$' | paste -sd: -)
export PATH

cd "$(dirname "$0")/.."
exec flutter test "$@"
