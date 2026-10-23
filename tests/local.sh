#!/bin/bash
# The local Cursor and Muse sources and the usage-meter refresh helper, with fake inputs only (tests/local.py).
# Usage: tests/local.sh <path to LimitBar.app>
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/python3 -I -B tests/local.py "${1:?usage: tests/local.sh <LimitBar.app>}"
/usr/bin/python3 -I -B tests/fixes.py "$1"
exec /usr/bin/python3 -I -B tests/native-muse.py "$1"
