"""Fixtures for the local Cursor and Muse sources and the usage-meter refresh helper (LOCAL-ADAPTERS.md).

Everything is fake: snapshot files, a fake `muse serve` (shell builtins only, so it also runs under
Resources/cli.sb) and a fake usage-meter collect.py. Nothing reads real sign-ins, sessions or snapshots.
Usage: python3 -I tests/local.py <path to LimitBar.app>
"""

import datetime
import fcntl
import json
import math
import os
import subprocess
import sys
import tempfile

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents/MacOS/LimitBar")
HELPER = os.path.join(APP, "Contents/Resources/usage-meter-refresh.py")
T = tempfile.mkdtemp(prefix="limitbar-local-")
NOW = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
SECRETS = ["sk-ant-api03-FAKEFAKEFAKEFAKEFAKEFAKE", "LLM|FAKEMUSEINFERENCEKEY0000", "someone@example.com", "u000000000"]
NONE = ["-claudePath", "/nonexistent/claude", "-codexPath", "/nonexistent/codex", "-agyPath", "/nonexistent/agy"]
failed = 0


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def ms(dt):
    return int(dt.timestamp() * 1000)


def probe(*args):
    out = subprocess.run([BIN, "--probe", "--muse-host-diagnostic", *NONE, *args], capture_output=True, timeout=120).stdout.decode()
    return json.loads(out), out


def check(name, cond, detail=""):
    global failed
    safe = str(detail)
    for secret in SECRETS:
        safe = safe.replace(secret, "[redacted synthetic credential]")
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + safe))
    if not cond:
        failed += 1


def parse(d):
    return datetime.datetime.strptime(d, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc) if d else None


def no_secrets(name, text):
    check(name + ": no credential or identifier in output", not any(s in text for s in SECRETS),
          "synthetic credential marker detected (values suppressed)")


# ---------------------------------------------------------------- Cursor (usage-meter snapshot)

def cursor(name, payload, mode=0o600, raw=None):
    p = os.path.join(T, name + ".json")
    with open(p, "w") as f:
        f.write(raw if raw is not None else json.dumps(payload))
    os.chmod(p, mode)
    d, out = probe("-cursorUsagePath", p, "-musePath", "/nonexistent/muse")
    return d["cursor"], out


def pool(used, reset=None, ok=None, **extra):
    return dict(used_percent=used, reset_at=reset, ok=ok, **extra)


cycle_end = NOW + datetime.timedelta(days=10)
s, out = cursor("numeric", {"checked_at": iso(NOW - datetime.timedelta(minutes=2)), "stale_after_seconds": 900,
                            "token": SECRETS[0], "email": SECRETS[2], "store": SECRETS[3],
                            "pools": {"cursor_models": pool(42, iso(cycle_end) .replace("Z", ".000Z"), True, note=SECRETS[2]),
                                      "cursor_other": pool(100, iso(cycle_end), False),
                                      "codex_7d": pool(6, None, True)}})
check("cursor numeric: state ok", s["state"] == "ok", s)
check("cursor numeric: both pools", [(w["label"], w.get("used")) for w in s["windows"]] == [("Cursor models", 42), ("Other models", 100)], s["windows"])
check("cursor numeric: bar is the plan pool", s["bar"]["label"] == "Cursor models", s.get("bar"))
check("cursor numeric: measuredAt is the collector's checked_at", parse(s["measuredAt"]) == NOW - datetime.timedelta(minutes=2), s.get("measuredAt"))
check("cursor numeric: reset kept", parse(s["windows"][0].get("resetsAt")) == cycle_end, s["windows"][0])
no_secrets("cursor numeric", out)

old = NOW - datetime.timedelta(minutes=20)
s, _ = cursor("stale", {"checked_at": iso(old), "stale_after_seconds": 900,
                        "pools": {"cursor_models": pool(42, iso(cycle_end)), "cursor_other": pool(7, iso(cycle_end))}})
check("cursor stale: numbers unknown, never 0", [w.get("used") for w in s["windows"]] == [None, None], s["windows"])
check("cursor stale: original measuredAt kept", parse(s["measuredAt"]) == old, s.get("measuredAt"))
check("cursor stale: says why", "min old" in (s.get("error") or ""), s.get("error"))

s, _ = cursor("staleflag", {"checked_at": iso(NOW - datetime.timedelta(minutes=10)), "stale_after_seconds": True,
                            "pools": {"cursor_models": pool(5), "cursor_other": pool(6)}})
check("cursor: boolean stale_after_seconds falls back to 900", [w.get("used") for w in s["windows"]] == [5, 6], s["windows"])

s, _ = cursor("invalid", {"checked_at": iso(NOW), "pools": {"cursor_models": pool(True), "cursor_other": pool("50")}})
check("cursor invalid: boolean and string stay unknown", [w.get("used") for w in s["windows"]] == [None, None], s["windows"])
check("cursor invalid: says so", "could not read" in (s.get("error") or ""), s.get("error"))

s, _ = cursor("range", {"checked_at": iso(NOW), "pools": {"cursor_models": pool(-5), "cursor_other": pool(104)}})
check("cursor range: negative unknown, over 100 shown as 100", [w.get("used") for w in s["windows"]] == [None, 100], s["windows"])
check("cursor range: over-limit flagged", any("over the included" in n for n in s.get("notes", [])), s.get("notes"))

s, _ = cursor("huge", {"checked_at": iso(NOW), "pools": {"cursor_models": pool(1e9), "cursor_other": pool(None)}})
check("cursor out-of-range: unknown", [w.get("used") for w in s["windows"]] == [None, None], s["windows"])

s, _ = cursor("nonfinite", {}, raw='{"checked_at": "%s", "pools": {"cursor_models": {"used_percent": NaN}, '
                                  '"cursor_other": {"used_percent": Infinity}}}' % iso(NOW))
check("cursor non-finite: unknown (or rejected)", s["state"] == "failed" or [w.get("used") for w in s["windows"]] == [None, None], s)

past = NOW - datetime.timedelta(hours=1)
s, _ = cursor("reset", {"checked_at": iso(NOW), "pools": {"cursor_models": pool(80, iso(past)), "cursor_other": pool(3, iso(cycle_end))}})
check("cursor reset passed: reset time kept so the panel shows 'awaiting update'", parse(s["windows"][0].get("resetsAt")) == past, s["windows"][0])

s, _ = cursor("future", {"checked_at": iso(NOW + datetime.timedelta(hours=1)), "pools": {"cursor_models": pool(1), "cursor_other": pool(1)}})
check("cursor future-dated: not used", s["state"] == "failed", s)
s, _ = cursor("garbage", {}, raw="not json " + SECRETS[0])
check("cursor garbage: failed", s["state"] == "failed", s)
no_secrets("cursor garbage", json.dumps(s))
s, _ = cursor("signedout", {"checked_at": iso(NOW), "pools": {"cursor_models": pool(None, note="cursor-auth-missing"),
                                                              "cursor_other": pool(None, note="cursor-auth-missing")}})
check("cursor auth notes: signed out", s["state"] == "signedOut", s)
s, _ = cursor("groupwritable", {"checked_at": iso(NOW), "pools": {}}, mode=0o660)
check("cursor group-writable file: untrusted, not read", s["state"] == "untrusted", s)
link = os.path.join(T, "link.json")
os.symlink(os.path.join(T, "numeric.json"), link)
s = probe("-cursorUsagePath", link, "-musePath", "/nonexistent/muse")[0]["cursor"]
check("cursor symlinked file: untrusted, not read", s["state"] == "untrusted", s)

# ---------------------------------------------------------------- Muse (fake `muse serve`)

FAKE = """#!/bin/bash
read -r line
echo '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"muse","version":"0"},"leak":"%(secret)s"}}'
n=0
while read -r line; do
  [[ $line =~ \\"id\\":([0-9]+) ]] || continue
  id=${BASH_REMATCH[1]}; n=$((n+1))
  if [[ $n -eq 1 && -n '%(push)s' ]]; then
    printf '{"jsonrpc":"2.0","id":%%s,"result":{}}\\n' "$id"
    echo '{"jsonrpc":"2.0","method":"usage/changed","params":%(push)s}'
  else
    printf '{"jsonrpc":"2.0","id":%%s,"result":%%s}\\n' "$id" '%(result)s'
  fi
done
"""


def muse(name, result, push=""):
    p = os.path.join(T, "muse-" + name)
    with open(p, "w") as f:
        f.write(FAKE % {"result": json.dumps(result), "push": json.dumps(push) if push else "", "secret": SECRETS[1]})
    os.chmod(p, 0o755)
    d, out = probe("-cursorUsagePath", "/nonexistent/usage.json", "-musePath", p, "-museHost", "YES")
    return d["muse"], out


obs = NOW - datetime.timedelta(minutes=1)
five, week = NOW + datetime.timedelta(hours=2), NOW + datetime.timedelta(days=3)
usage = {"window": {"usedPercent": 37, "windowDurationMins": 300, "resetsAtMs": ms(five)},
         "weekly": {"usedPercent": 12, "resetsAtMs": ms(week)}, "tier": "power_usage", "observedAtMs": ms(obs),
         "apiKey": SECRETS[1], "user_email": SECRETS[2]}
s, out = muse("numeric", {"usage": usage})
check("muse numeric: state ok", s["state"] == "ok", s)
check("muse numeric: 5-hour and weekly", [(w["label"], w["short"], w.get("used")) for w in s["windows"]] == [("5-hour", "5h", 37), ("Week", "w", 12)], s["windows"])
check("muse numeric: measuredAt is Muse's observedAt", parse(s["measuredAt"]) == obs, s.get("measuredAt"))
check("muse numeric: resets kept", [parse(w.get("resetsAt")) for w in s["windows"]] == [five, week], s["windows"])
check("muse numeric: plan is the tier name only", s.get("plan", "") == "Power Usage", s.get("plan", ""))
no_secrets("muse numeric", out)

s, _ = muse("push", {}, push=usage)
check("muse usage/changed push: read", [w.get("used") for w in s["windows"]] == [37, 12], s)

bad = dict(usage, window={"usedPercent": True, "windowDurationMins": 300, "resetsAtMs": ms(five)},
           weekly={"usedPercent": -1, "resetsAtMs": ms(week)})
s, _ = muse("invalid", {"usage": bad})
check("muse boolean/negative: nothing usable -> failed, no numbers", s["state"] == "failed" and not s.get("windows"), s)
over = dict(usage, window={"usedPercent": 130, "windowDurationMins": 300, "resetsAtMs": ms(five)},
            weekly={"usedPercent": "12", "resetsAtMs": ms(week)})
s, _ = muse("over", {"usage": over})
check("muse over-quota: shown as 100 and flagged; string weekly unknown",
      [w.get("used") for w in s["windows"]] == [100, None] and any("over the limit" in n for n in s.get("notes", [])), s)
s, _ = muse("resetpassed", {"usage": dict(usage, window={"usedPercent": 90, "windowDurationMins": 300, "resetsAtMs": ms(NOW - datetime.timedelta(minutes=5))})})
check("muse reset passed: reset time kept (panel: awaiting update)", parse(s["windows"][0].get("resetsAt")) < NOW, s["windows"][0])
s, _ = muse("notime", {"usage": dict(usage, observedAtMs=True)})
check("muse boolean observedAt: not used", s["state"] == "failed", s)
s, _ = muse("absent", {})
check("muse nothing observed: failed, not 0", s["state"] == "failed" and not s.get("windows"), s)
check("muse nothing observed: sign-in status unverified", s.get("error") == "Muse host has not observed quota; sign-in status unverified")
s = probe("-cursorUsagePath", "/nonexistent/usage.json", "-musePath", os.path.join(T, "muse-numeric"), "-museHost", "NO")[0]["muse"]
check("muse host reads off: setup, nothing run", s["state"] == "setup" and not s.get("windows"), s)

# ---------------------------------------------------------------- usage-meter refresh helper

COLLECT = """
import json, datetime
from pathlib import Path
BASE = Path(__file__).resolve().parent
USAGE_JSON_PATHS = [BASE / "store" / "usage.json", Path("/nonexistent-limitbar/usage.json")]
def _ensure_path(): pass
def collect_snapshot():
    print("%(secret)s")
    %(raise)s
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return {"checked_at": now, "stale_after_seconds": 900,
            "pools": {"cursor_models": {"used_percent": 1, "ok": True}, "cursor_other": {"used_percent": None, "ok": None}}}
def write_snapshot(s):
    p = USAGE_JSON_PATHS[0]; p.parent.mkdir(exist_ok=True); p.write_text(json.dumps(s)); return [str(p)]
"""


def collector(name, raise_="", source=None, mode=0o644):
    d = os.path.join(T, "um-" + name)
    os.mkdir(d)
    p = os.path.join(d, "collect.py")
    with open(p, "w") as f:
        f.write(source if source is not None else COLLECT % {"secret": SECRETS[0] + " " + SECRETS[2], "raise": raise_})
    os.chmod(p, mode)
    return p


def helper(p, lock=None):
    r = subprocess.run(["/usr/bin/python3", "-I", "-B", HELPER, "--collector", p, "--min-age", "240",
                        "--lock", lock or os.path.join(T, "lock")], capture_output=True, timeout=60)
    out = r.stdout.decode()
    return json.loads(out.strip().splitlines()[-1]), out + r.stderr.decode()


p = collector("ok")
r, out = helper(p)
check("helper: refreshed, counts only", r == {"status": "refreshed", "written": 1, "known_pools": 1}, r)
no_secrets("helper", out)
check("helper: no paths in output", T not in out, out)
check("helper: wrote the snapshot", os.path.exists(os.path.join(os.path.dirname(p), "store", "usage.json")))
r, _ = helper(p)
check("helper: second run within 4 min is skipped", r["status"] == "fresh-skip", r)
lockp = os.path.join(T, "held.lock")
fd = os.open(lockp, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
r, _ = helper(collector("locked"), lock=lockp)
check("helper: lock held elsewhere -> skipped", r["status"] == "locked-skip", r)
os.close(fd)
r, _ = helper(collector("gw", mode=0o664))
check("helper: group-writable collector -> untrusted, not run", r["status"] == "untrusted", r)
r, _ = helper(collector("syntax", source="def broken(:\n"))
check("helper: broken collector -> import-failed", r["status"] == "import-failed", r)
r, out = helper(collector("boom", raise_="raise RuntimeError('%s')" % SECRETS[0]))
check("helper: collector exception -> collect-failed", r["status"] == "collect-failed", r)
no_secrets("helper exception", out)
other = os.path.join(os.path.dirname(collector("named")), "other.py")
os.rename(os.path.join(os.path.dirname(other), "collect.py"), other)
r, _ = helper(other)
check("helper: only a file named collect.py is run", r["status"] == "untrusted", r)

print("PASS: local" if not failed else "local FAILED (%d)" % failed)
sys.exit(1 if failed else 0)
