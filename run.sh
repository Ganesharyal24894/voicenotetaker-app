#!/usr/bin/env bash
# Run the app on a connected phone with hot reload.
#
#   ./run.sh                 # debug, hot reload -- the normal loop
#   ./run.sh --release       # release build, for measuring real performance
#   ./run.sh --wireless      # pair over Wi-Fi first, then run untethered
#
# A PHYSICAL DEVICE IS REQUIRED. Android emulators have no Bluetooth radio,
# so nothing in this app can be exercised on one -- scanning finds nothing.

set -euo pipefail

# shellcheck disable=SC1090
source ~/development/flutter-env.sh

cd "$(dirname "$0")"

if [ "${1:-}" = "--wireless" ]; then
    shift
    echo "Wireless pairing (Android 11+):"
    echo "  1. Phone: Developer options > Wireless debugging > Pair device with pairing code"
    echo "  2. It shows an IP:PORT and a 6-digit code."
    read -r -p "  IP:PORT from the PAIRING dialog > " pair_addr
    read -r -p "  6-digit pairing code           > " pair_code
    adb pair "$pair_addr" "$pair_code"
    echo
    echo "  3. The Wireless debugging main screen shows a DIFFERENT IP:PORT."
    read -r -p "  IP:PORT from the MAIN screen   > " conn_addr
    adb connect "$conn_addr"
fi

echo "== devices =="
adb devices -l | sed '1d;/^$/d' || true

if ! adb devices | sed '1d' | grep -qw device; then
    cat >&2 <<'EOF'

No device found. Check:
  - Developer options enabled (tap Build number 7 times in About phone)
  - USB debugging on
  - The "Allow USB debugging?" prompt accepted on the phone
  - The cable carries data, not just power (a surprising number do not)

EOF
    exit 1
fi

echo
echo "Starting. In the console: r = hot reload, R = hot restart, q = quit."
exec flutter run "$@"
