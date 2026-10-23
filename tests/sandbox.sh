#!/bin/bash
# Proves Resources/cli.sb, the sandbox codex, agy and muse run in: only the CLI's own program may start,
# and nothing in $HOME but its own state folder can be read or written; shared temp is closed too.
# /bin/bash stands in for the CLI, so this needs no AI CLI installed. Only shell builtins run inside —
# any external command would be blocked by the exec rule itself.
set -euo pipefail
cd "$(dirname "$0")/.."
SB=Resources/cli.sb
real() { /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
H="$(real "$HOME")"; STATE="$H/.limitbar-sandbox-test-$$"; PT="$(real "$(mktemp -d)")"
mkdir -p "$STATE"; P=probe-$$
echo x > "$STATE/$P"; echo x > "$H/$P"; echo x > "/private/tmp/$P"
trap 'rm -rf "$STATE" "$H/$P" "$H/$P.new" "/private/tmp/$P" "$PT"' EXIT
run() { /usr/bin/sandbox-exec -f "$SB" -D HOME="$H" -D EXEC=/bin/bash -D INTERP=/bin/bash -D EXECDIR=/nonexistent \
          -D STATE="$STATE" -D STATE2=/nonexistent -D PTMP="$PT" -D HELPER=/nonexistent -D KEYCHAINS=/nonexistent \
          -D SHAREDTMP=/nonexistent /bin/bash -c "$1" 2>/dev/null; }
fail=0
check() { if run "$2"; then r=allowed; else r=denied; fi; [[ "$r" == "$1" ]] && echo "ok   $3: $r" || { echo "FAIL $3: $r"; fail=1; }; }
check denied  '/usr/bin/true'                   "start another program"
check denied  ": < '$H/$P'"                     "read a file in ~"
check denied  "echo y >> '$H/$P'"               "write a file in ~"
check denied  "echo y > '$H/$P.new'"            "create a file in ~"
check denied  ": < '/private/tmp/$P'"           "read shared /tmp"
check allowed ": < '$STATE/$P'"                 "read its own state folder"
check allowed "echo y >> '$STATE/$P'"           "write its own state folder"
check allowed "echo y > '$PT/$P'"               "write LimitBar's private temp"
[[ $fail -eq 0 ]] && echo "PASS: cli.sb" || { echo "cli.sb FAILED"; exit 1; }
