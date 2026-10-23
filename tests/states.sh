#!/bin/bash
# What a user sees with each CLI missing, signed out or unsafe — with fake CLIs, so it needs no account
# and never touches real sessions. Usage: tests/states.sh <path to LimitBar.app>
set -euo pipefail
APP="${1:?usage: tests/states.sh <LimitBar.app>}"
BIN="$APP/Contents/MacOS/LimitBar"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Signed-out fakes, written the way each real CLI reports it.
cat > "$T/claude" <<'S'
#!/bin/bash
[[ "$1 $2" == "auth status" ]] && { echo '{"loggedIn":false}'; exit 1; }
echo "Not logged in · Please run /login"; exit 1
S
cat > "$T/agy" <<'S'
#!/bin/bash
echo "Error: not signed in. Please sign in by running agy."; exit 1
S
# Codex 0.163 signed out, verbatim: `login status` says it on stderr only; app-server answers with an error.
cat > "$T/codex" <<'S'
#!/bin/bash
[[ "$1 $2" == "login status" ]] && { echo "Not logged in" >&2; exit 1; }
read -r _; echo '{"jsonrpc":"2.0","id":1,"result":{}}'; read -r _; read -r _
echo '{"error":{"code":-32600,"message":"codex account authentication required to read rate limits"},"id":2}'
S
# Muse (opt-in host reads): `muse serve` answers initialize with an error when nobody is signed in. Runs under
# Resources/cli.sb like the real one, so only shell builtins.
cat > "$T/muse" <<'S'
#!/bin/bash
read -r _
echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Not authenticated"}}'
S
# Cursor: a fresh usage-meter snapshot whose collector could not sign in to Cursor.
now="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"checked_at":"%s","stale_after_seconds":900,"pools":{"cursor_models":{"used_percent":null,"ok":null,"note":"cursor-auth-failed; run bin/setup-cursor-session"},"cursor_other":{"used_percent":null,"ok":null,"note":"cursor-auth-failed; run bin/setup-cursor-session"}}}' "$now" > "$T/usage.json"
chmod 600 "$T/usage.json"
cp "$T/usage.json" "$T/usage-unsafe.json"; chmod 660 "$T/usage-unsafe.json"   # group-writable: never read
chmod 755 "$T/claude" "$T/agy" "$T/codex" "$T/muse"
cp "$T/codex" "$T/codex-unsafe"; chmod 775 "$T/codex-unsafe"     # group-writable file: must never run
mkdir "$T/shared"; chmod 777 "$T/shared"; cp "$T/codex" "$T/shared/codex"   # safe file, unsafe folder

probe() { "$BIN" --probe --muse-host-diagnostic "$@" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join("%s=%s" % (k, d[k]["state"]) for k in sorted(d)))'; }
expect() { local got; got="$(probe "${@:2}")"; [[ "$got" == "$1" ]] && echo "ok   $got" || { echo "FAIL got: $got"; echo "     want: $1"; exit 1; }; }

expect "claude=missing codex=missing cursor=missing gemini=missing muse=missing" \
  -claudePath /nonexistent/claude -agyPath /nonexistent/agy -cursorUsagePath /nonexistent/usage.json -musePath /nonexistent/muse -codexPath /nonexistent/codex
expect "claude=signedOut codex=signedOut cursor=signedOut gemini=signedOut muse=signedOut" \
  -claudePath "$T/claude" -codexPath "$T/codex" -agyPath "$T/agy" -cursorUsagePath "$T/usage.json" -musePath "$T/muse" -museHost YES
expect "claude=missing codex=missing cursor=untrusted gemini=missing muse=setup" \
  -claudePath /nonexistent/claude -agyPath /nonexistent/agy -codexPath /nonexistent/codex -cursorUsagePath "$T/usage-unsafe.json" -musePath "$T/muse" -museHost NO
expect "claude=missing codex=untrusted cursor=missing gemini=missing muse=missing" \
  -claudePath /nonexistent/claude -agyPath /nonexistent/agy -cursorUsagePath /nonexistent/usage.json -musePath /nonexistent/muse -codexPath "$T/codex-unsafe"
expect "claude=missing codex=untrusted cursor=missing gemini=missing muse=missing" \
  -claudePath /nonexistent/claude -agyPath /nonexistent/agy -cursorUsagePath /nonexistent/usage.json -musePath /nonexistent/muse -codexPath "$T/shared/codex"
mkdir "$T/badinterp"; chmod 777 "$T/badinterp"; cp /bin/bash "$T/badinterp/bash"
printf '#!%s/badinterp/bash\necho Not logged in\n' "$T" > "$T/codex-badinterp"; chmod 755 "$T/codex-badinterp"
expect "claude=missing codex=untrusted cursor=missing gemini=missing muse=missing" \
  -claudePath /nonexistent/claude -agyPath /nonexistent/agy -cursorUsagePath /nonexistent/usage.json -musePath /nonexistent/muse -codexPath "$T/codex-badinterp"
echo "PASS: states"
