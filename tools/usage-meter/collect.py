#!/usr/bin/env python3
"""Collect Cursor, Codex, Claude, and Antigravity quota snapshots.

Writes the agent-readable JSON contract. Never prints session cookies, JWTs,
or API keys.
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

STALE_AFTER_SECONDS = 900
CURSOR_SUMMARY_URL = "https://cursor.com/api/usage-summary"
CURSOR_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_KEYCHAIN_SERVICE = "Claude Code-credentials"
ANTIGRAVITY_CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal"
ANTIGRAVITY_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
ANTIGRAVITY_UA = "usage-meter/0.1 (antigravity)"
HOMEBREW_BIN = "/opt/homebrew/bin"

HOME = Path.home()
CURSOR_DB = (
    HOME
    / "Library"
    / "Application Support"
    / "Cursor"
    / "User"
    / "globalStorage"
    / "state.vscdb"
)
CURSOR_AGENT_AUTH = HOME / ".config" / "cursor" / "auth.json"
CURSOR_AGENT_AUTH_PATHS = [
    HOME / ".cursor" / "auth.json",
    CURSOR_AGENT_AUTH,
]
CURSOR_AGENT_KEYCHAIN_SERVICE = "cursor-access-token"
CURSOR_AGENT_KEYCHAIN_ACCOUNT = "cursor-user"
LOCAL_CURSOR_SESSION = HOME / ".config" / "usage-meter" / "cursor-session"
CODEX_AUTH = HOME / ".codex" / "auth.json"
CLAUDE_AUTH = HOME / ".claude" / ".credentials.json"
ANTIGRAVITY_TOKEN_PATHS = [
    HOME / ".gemini" / "antigravity-cli" / "antigravity-oauth-token",
    HOME / ".gemini" / "jetski-standalone-oauth-token",
]
ANTIGRAVITY_CLIENT_BINARIES = [
    Path("/Applications/Antigravity.app/Contents/Resources/bin/language_server"),
    HOME / ".local" / "bin" / "agy",
    Path("/opt/homebrew/bin/agy"),
    Path("/usr/local/bin/agy"),
]
CURSOR_AGENT_STORES_ROOT = (
    HOME
    / "Library"
    / "Application Support"
    / "Cursor"
    / "AgentStores"
    / "cursor_agent_stores"
)
CURSOR_SHARED_PATH = Path("/cursor/stores/user/usage.json")


def discover_cursor_usage_json_paths(
    stores_root: Optional[Path] = None,
    shared_path: Optional[Path] = None,
) -> list[Path]:
    """Safely discover existing Cursor account-store usage.json paths.

    Preserves active existing output path for single matching account and
    /cursor fallback behavior. Never arbitrarily chooses among multiple accounts.
    """
    root = stores_root if stores_root is not None else CURSOR_AGENT_STORES_ROOT
    shared = shared_path if shared_path is not None else CURSOR_SHARED_PATH

    found: list[Path] = []
    if root.is_dir():
        try:
            for entry in sorted(root.iterdir()):
                if entry.name.startswith("."):
                    continue
                p = entry / "files" / "usage.json"
                if p.is_file():
                    found.append(p)
        except OSError:
            pass

    account_path: Optional[Path] = None
    if len(found) == 1:
        account_path = found[0]
    elif len(found) > 1:
        # Multiple accounts with usage.json: never arbitrarily choose among them.
        account_path = None
    else:
        # No existing usage.json; check if there is a single candidate account store
        candidates: list[Path] = []
        if root.is_dir():
            try:
                for entry in sorted(root.iterdir()):
                    if entry.name.startswith("."):
                        continue
                    if entry.is_dir() and (entry / "files").is_dir():
                        candidates.append(entry / "files" / "usage.json")
            except OSError:
                pass
        if len(candidates) == 1:
            account_path = candidates[0]
        else:
            account_path = None

    paths: list[Path] = []
    if account_path is not None:
        paths.append(account_path)
    paths.append(shared)
    return paths


USAGE_JSON_PATHS = discover_cursor_usage_json_paths()
KEYCHAIN_SERVICE = "usage-meter"
KEYCHAIN_ACCOUNT = "cursor-session"


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def _round_pct(value: Any) -> Optional[int]:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number != number:  # NaN
        return None
    return int(round(max(0.0, number)))


def _pool(
    used_percent: Optional[int] = None,
    reset_at: Optional[str] = None,
    ok: Optional[bool] = None,
    note: Optional[str] = None,
) -> dict[str, Any]:
    if ok is None and used_percent is not None:
        ok = used_percent < 100
    payload: dict[str, Any] = {"used_percent": used_percent, "ok": ok}
    if reset_at is not None:
        payload["reset_at"] = reset_at
    elif used_percent is not None:
        payload["reset_at"] = None
    if note is not None:
        payload["note"] = note
    return payload


def _unset_pool(note: str) -> dict[str, Any]:
    return {"used_percent": None, "ok": None, "note": note}


def _ensure_path() -> None:
    path = os.environ.get("PATH", "")
    prefix = f"{HOMEBREW_BIN}:/usr/local/bin:"
    if not path.startswith(prefix):
        os.environ["PATH"] = prefix + path


def _decode_jwt_claims(token: str) -> Optional[dict[str, Any]]:
    parts = token.split(".")
    if len(parts) < 2:
        return None
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except (ValueError, json.JSONDecodeError, OSError):
        return None


def _cookie_from_access_token(token: str) -> Optional[str]:
    token = token.strip().strip('"')
    if not token:
        return None
    if "%3A%3A" in token or "::" in token.split(".")[0]:
        return token.replace("::", "%3A%3A", 1) if "::" in token and "%3A%3A" not in token else token
    claims = _decode_jwt_claims(token)
    if not claims:
        return None
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub.strip():
        return None
    user_id = sub.split("|", 1)[1] if "|" in sub else sub
    if not user_id:
        return None
    return f"{user_id}%3A%3A{token}"


def _read_file_secret(path: Path) -> Optional[str]:
    try:
        if not path.is_file():
            return None
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not text:
        return None
    if text.startswith("{"):
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return text
        for key in ("WorkosCursorSessionToken", "session", "cookie", "accessToken"):
            value = data.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        return None
    return text.splitlines()[0].strip()


def _read_keychain_session() -> Optional[str]:
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def _read_cursor_db_token(db_path: Path = CURSOR_DB) -> Optional[str]:
    if not db_path.is_file():
        return None
    uri = f"file:{db_path}?mode=ro"
    try:
        con = sqlite3.connect(uri, uri=True, timeout=3)
        try:
            row = con.execute(
                "SELECT value FROM ItemTable WHERE key = ?",
                ("cursorAuth/accessToken",),
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    if not row or row[0] is None:
        return None
    value = row[0]
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="ignore")
    if not isinstance(value, str):
        return None
    value = value.strip()
    if value.startswith("cursor-safe-storage:"):
        return None
    return value or None


def _read_cursor_agent_keychain_token() -> Optional[str]:
    """Read native Cursor CLI / agent credentials from macOS Keychain."""
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                CURSOR_AGENT_KEYCHAIN_SERVICE,
                "-a",
                CURSOR_AGENT_KEYCHAIN_ACCOUNT,
                "-w",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            value = result.stdout.strip()
            if value:
                return value
        fallback = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                CURSOR_AGENT_KEYCHAIN_SERVICE,
                "-w",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if fallback.returncode == 0:
            value = fallback.stdout.strip()
            if value:
                return value
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def _read_cursor_agent_token() -> Optional[str]:
    """Read Cursor CLI / agent credentials from macOS Keychain or file-based auth."""
    keychain_token = _read_cursor_agent_keychain_token()
    if keychain_token:
        return keychain_token
    for path in CURSOR_AGENT_AUTH_PATHS:
        data_text = _read_file_secret(path)
        if not data_text:
            continue
        if data_text.startswith("{"):
            try:
                data = json.loads(data_text)
            except json.JSONDecodeError:
                continue
            token = data.get("accessToken")
            if isinstance(token, str) and token.strip():
                return token.strip()
        else:
            return data_text
    return None


def resolve_cursor_cookie() -> tuple[Optional[str], str]:
    env = os.environ.get("USAGE_METER_CURSOR_SESSION", "").strip()
    if env:
        cookie = _cookie_from_access_token(env) or env
        return cookie, "env"
    file_secret = _read_file_secret(LOCAL_CURSOR_SESSION)
    if file_secret:
        return _cookie_from_access_token(file_secret) or file_secret, "config-file"
    keychain = _read_keychain_session()
    if keychain:
        return _cookie_from_access_token(keychain) or keychain, "keychain"
    db_token = _read_cursor_db_token()
    if db_token:
        cookie = _cookie_from_access_token(db_token)
        if cookie:
            return cookie, "cursor-db"
    agent_token = _read_cursor_agent_token()
    if agent_token:
        cookie = _cookie_from_access_token(agent_token)
        if cookie:
            return cookie, "cursor-agent"
    return None, "missing"


def _http_json(
    url: str,
    headers: dict[str, str],
    timeout: float = 15,
    payload: Optional[dict[str, Any]] = None,
) -> tuple[Optional[int], Optional[dict[str, Any]], str]:
    data_bytes: Optional[bytes] = None
    method = "GET"
    request_headers = dict(headers)
    if payload is not None:
        method = "POST"
        data_bytes = json.dumps(payload).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")
    request = urllib.request.Request(
        url, data=data_bytes, headers=request_headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            status = getattr(response, "status", 200)
    except urllib.error.HTTPError as exc:
        return exc.code, None, f"http-{exc.code}"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return None, None, f"network:{exc.__class__.__name__}"
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return status, None, "invalid-json"
    if not isinstance(data, dict):
        return status, None, "unexpected-json"
    return status, data, "ok"


def _parse_percent_message(message: Optional[str]) -> Optional[int]:
    if not message:
        return None
    match = re.search(r"(\d+(?:\.\d+)?)\s*%", message)
    if not match:
        return None
    return _round_pct(match.group(1))


def _iso_from_reset(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str) and value.strip():
        text = value.strip()
        if text.endswith("+00:00"):
            return text[:-6] + "Z"
        return text
    if isinstance(value, (int, float)) and value > 0:
        return datetime.fromtimestamp(float(value), tz=timezone.utc).replace(
            microsecond=0
        ).isoformat().replace("+00:00", "Z")
    return None


def parse_cursor_summary(data: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    reset_at = _iso_from_reset(data.get("billingCycleEnd"))
    if data.get("isUnlimited"):
        unlimited = _pool(0, reset_at, True, "unlimited")
        return unlimited, dict(unlimited)

    individual = data.get("individualUsage") or {}
    plan = individual.get("plan") or {}
    models = _round_pct(plan.get("autoPercentUsed"))
    other = _round_pct(plan.get("apiPercentUsed"))
    if models is None:
        models = _parse_percent_message(data.get("autoModelSelectedDisplayMessage"))
    if other is None:
        other = _parse_percent_message(data.get("namedModelSelectedDisplayMessage"))

    models_pool = (
        _pool(models, reset_at) if models is not None else _unset_pool("cursor-unparsed")
    )
    other_pool = (
        _pool(other, reset_at) if other is not None else _unset_pool("cursor-unparsed")
    )
    return models_pool, other_pool


def fetch_cursor() -> tuple[dict[str, Any], dict[str, Any]]:
    cookie, source = resolve_cursor_cookie()
    if not cookie:
        note = "cursor-auth-missing"
        return _unset_pool(note), _unset_pool(note)
    status, data, detail = _http_json(
        CURSOR_SUMMARY_URL,
        {
            "Cookie": f"WorkosCursorSessionToken={cookie}",
            "Origin": "https://cursor.com",
            "Referer": "https://cursor.com/dashboard",
            "User-Agent": CURSOR_UA,
            "Accept": "application/json",
        },
    )
    if status in (401, 403) or data is None:
        note = "cursor-auth-failed" if status in (401, 403) else f"cursor-{detail}"
        if source in {"cursor-db", "cursor-agent"}:
            note += "; run bin/setup-cursor-session"
        return _unset_pool(note), _unset_pool(note)
    return parse_cursor_summary(data)


def _read_jsonl(stream: Any, deadline: float) -> Optional[dict[str, Any]]:
    while time.time() < deadline:
        line = stream.readline()
        if line == "":
            return None
        line = line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def fetch_codex_app_server(timeout: float = 20) -> Optional[dict[str, Any]]:
    _ensure_path()
    codex = os.path.join(HOMEBREW_BIN, "codex")
    if not os.path.isfile(codex):
        which = subprocess.run(
            ["which", "codex"], check=False, capture_output=True, text=True
        )
        if which.returncode != 0:
            return None
        codex = which.stdout.strip()
    try:
        proc = subprocess.Popen(
            [codex, "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except OSError:
        return None
    assert proc.stdin is not None
    assert proc.stdout is not None
    deadline = time.time() + timeout
    result: Optional[dict[str, Any]] = None
    try:
        init = {
            "method": "initialize",
            "id": 0,
            "params": {
                "clientInfo": {
                    "name": "usage-meter",
                    "title": "Usage Meter",
                    "version": "0.1.0",
                },
                "capabilities": {"experimentalApi": True},
            },
        }
        proc.stdin.write(json.dumps(init) + "\n")
        proc.stdin.flush()
        while time.time() < deadline:
            message = _read_jsonl(proc.stdout, deadline)
            if message is None:
                break
            if message.get("id") == 0:
                if "error" in message:
                    return None
                break
        proc.stdin.write(json.dumps({"method": "initialized"}) + "\n")
        proc.stdin.write(
            json.dumps({"method": "account/rateLimits/read", "id": 1, "params": {}})
            + "\n"
        )
        proc.stdin.flush()
        while time.time() < deadline:
            message = _read_jsonl(proc.stdout, deadline)
            if message is None:
                break
            if message.get("id") == 1:
                if "error" in message:
                    return None
                maybe = message.get("result")
                if isinstance(maybe, dict):
                    result = maybe
                break
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass
    return result


def _limit_id(snapshot: dict[str, Any]) -> Optional[str]:
    value = snapshot.get("limitId") or snapshot.get("limit_id")
    return value if isinstance(value, str) and value else None


def _codex_snapshot_from_app_server(data: dict[str, Any]) -> Optional[dict[str, Any]]:
    """Use only the Codex product snapshot, not gpt-reserve / other limit ids."""
    by_id = data.get("rateLimitsByLimitId") or data.get("rate_limits_by_limit_id")
    if isinstance(by_id, dict):
        preferred = by_id.get("codex")
        if isinstance(preferred, dict):
            return preferred
        for snapshot in by_id.values():
            if isinstance(snapshot, dict) and _limit_id(snapshot) == "codex":
                return snapshot
    rate_limits = data.get("rateLimits") or data.get("rate_limits")
    if isinstance(rate_limits, dict) and _limit_id(rate_limits) in (None, "codex"):
        return rate_limits
    if isinstance(rate_limits, list):
        fallback = None
        for item in rate_limits:
            if not isinstance(item, dict):
                continue
            if _limit_id(item) == "codex":
                return item
            if fallback is None:
                fallback = item
        return fallback
    return None


def _codex_windows_from_app_server(data: dict[str, Any]) -> list[dict[str, Any]]:
    snapshot = _codex_snapshot_from_app_server(data)
    if not snapshot:
        return []
    windows: list[dict[str, Any]] = []
    for key in ("primary", "secondary"):
        window = snapshot.get(key)
        if isinstance(window, dict):
            windows.append(window)
    return windows


def _classify_codex_window(window: dict[str, Any]) -> Optional[str]:
    minutes = window.get("windowDurationMins") or window.get("window_duration_mins")
    seconds = window.get("limit_window_seconds") or window.get("limitWindowSeconds")
    try:
        if minutes is None and seconds is not None:
            minutes = float(seconds) / 60.0
        if minutes is None:
            return None
        minutes = float(minutes)
    except (TypeError, ValueError):
        return None
    if 240 <= minutes <= 420:
        return "codex_5h"
    if 9000 <= minutes <= 12000:
        return "codex_7d"
    return None


def _window_to_pool(window: dict[str, Any]) -> dict[str, Any]:
    used = _round_pct(
        window.get("usedPercent")
        if "usedPercent" in window
        else window.get("used_percent")
    )
    reset_at = _iso_from_reset(
        window.get("resetsAt")
        if "resetsAt" in window
        else window.get("resets_at") or window.get("reset_at")
    )
    if used is None:
        return _unset_pool("codex-unparsed")
    return _pool(used, reset_at)


def parse_codex_app_server(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    pools = {
        "codex_5h": _unset_pool("codex-window-missing"),
        "codex_7d": _unset_pool("codex-window-missing"),
    }
    for window in _codex_windows_from_app_server(data):
        kind = _classify_codex_window(window)
        if kind:
            pools[kind] = _window_to_pool(window)
    return pools


def parse_codex_http(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    pools = {
        "codex_5h": _unset_pool("codex-window-missing"),
        "codex_7d": _unset_pool("codex-window-missing"),
    }
    rate = data.get("rate_limit") or {}
    windows = []
    for key in ("primary_window", "secondary_window"):
        window = rate.get(key)
        if isinstance(window, dict):
            windows.append(window)
    # additional_rate_limits is gpt-reserve / other meters, not Codex 5h+7d.
    for window in windows:
        mapped = {
            "usedPercent": window.get("used_percent"),
            "windowDurationMins": None,
            "resetsAt": window.get("reset_at"),
            "limit_window_seconds": window.get("limit_window_seconds"),
        }
        kind = _classify_codex_window(mapped)
        if kind:
            pools[kind] = _window_to_pool(mapped)
    return pools


def fetch_codex_http() -> Optional[dict[str, Any]]:
    if not CODEX_AUTH.is_file():
        return None
    try:
        auth = json.loads(CODEX_AUTH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    tokens = auth.get("tokens") or {}
    access = tokens.get("access_token")
    account = tokens.get("account_id")
    if not isinstance(access, str) or not access:
        return None
    headers = {
        "Authorization": f"Bearer {access}",
        "Accept": "application/json",
        "User-Agent": "usage-meter/0.1",
    }
    if isinstance(account, str) and account:
        headers["ChatGPT-Account-ID"] = account
    status, data, _detail = _http_json(CODEX_USAGE_URL, headers)
    if status == 200 and isinstance(data, dict):
        return data
    return None


def fetch_codex() -> dict[str, dict[str, Any]]:
    app_server = fetch_codex_app_server()
    if app_server:
        parsed = parse_codex_app_server(app_server)
        if any(parsed[key].get("used_percent") is not None for key in parsed):
            return parsed
    http_data = fetch_codex_http()
    if http_data:
        parsed = parse_codex_http(http_data)
        if any(parsed[key].get("used_percent") is not None for key in parsed):
            return parsed
        return {
            "codex_5h": _unset_pool("codex-unparsed"),
            "codex_7d": _unset_pool("codex-unparsed"),
        }
    note = "codex-unavailable"
    if not CODEX_AUTH.is_file():
        note = "codex-auth-missing"
    return {"codex_5h": _unset_pool(note), "codex_7d": _unset_pool(note)}


def _read_claude_auth() -> list[dict[str, Any]]:
    """Read existing Claude Code credentials; never copy or modify them."""
    candidates: list[dict[str, Any]] = []
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", CLAUDE_KEYCHAIN_SERVICE, "-w"],
            check=False, capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            if isinstance(data, dict) and isinstance(data.get("claudeAiOauth"), dict):
                candidates.append(data["claudeAiOauth"])
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    try:
        data = json.loads(CLAUDE_AUTH.read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("claudeAiOauth"), dict):
            candidates.append(data["claudeAiOauth"])
    except (OSError, json.JSONDecodeError):
        pass
    return candidates


def parse_claude_usage(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    pools: dict[str, dict[str, Any]] = {}
    for key, window_key in (("claude_5h", "five_hour"), ("claude_7d", "seven_day")):
        window = data.get(window_key)
        if not isinstance(window, dict):
            pools[key] = _unset_pool("claude-window-missing")
            continue
        used = window.get("utilization")
        if (
            isinstance(used, bool) or not isinstance(used, (int, float))
            or not math.isfinite(used) or not 0 <= used <= 100
        ):
            pools[key] = _unset_pool("claude-unparsed")
            continue
        pools[key] = _pool(_round_pct(used), _iso_from_reset(window.get("resets_at")))
    return pools


def fetch_claude() -> dict[str, dict[str, Any]]:
    note = "claude-auth-missing; run claude auth login"
    seen: set[str] = set()
    for auth in _read_claude_auth():
        token = auth.get("accessToken")
        if not isinstance(token, str) or not token.strip() or token in seen:
            continue
        seen.add(token)
        expiry = auth.get("expiresAt")
        if isinstance(expiry, (int, float)) and expiry > 0 and expiry <= time.time() * 1000:
            note = "claude-auth-expired; run claude auth login"
            continue
        status, data, detail = _http_json(
            CLAUDE_USAGE_URL,
            {
                "Authorization": f"Bearer {token}",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
                "User-Agent": "usage-meter/0.1",
            },
        )
        if status == 200 and data is not None:
            return parse_claude_usage(data)
        if status in (401, 403):
            note = "claude-auth-failed; run claude auth login"
            continue
        note = "claude-rate-limited" if status == 429 else f"claude-{detail}"
        break
    return {"claude_5h": _unset_pool(note), "claude_7d": _unset_pool(note)}


def _antigravity_token_payload(auth: dict[str, Any]) -> dict[str, Any]:
    token = auth.get("token")
    return token if isinstance(token, dict) else auth


def _read_antigravity_auth() -> tuple[Optional[Path], Optional[dict[str, Any]]]:
    for path in ANTIGRAVITY_TOKEN_PATHS:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            return path, data
    return None, None


def _antigravity_access_token(auth: dict[str, Any]) -> Optional[str]:
    payload = _antigravity_token_payload(auth)
    token = payload.get("access_token") or auth.get("access_token")
    return token.strip() if isinstance(token, str) and token.strip() else None


def _antigravity_refresh_token(auth: dict[str, Any]) -> Optional[str]:
    payload = _antigravity_token_payload(auth)
    token = payload.get("refresh_token") or auth.get("refresh_token")
    return token.strip() if isinstance(token, str) and token.strip() else None


def _antigravity_token_expired(auth: dict[str, Any], skew_seconds: int = 60) -> bool:
    payload = _antigravity_token_payload(auth)
    expiry = payload.get("expiry")
    if not isinstance(expiry, str) or not expiry.strip():
        return False
    text = expiry.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return False
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed <= datetime.now(timezone.utc) + timedelta(seconds=skew_seconds)


def _write_antigravity_auth(path: Path, auth: dict[str, Any]) -> None:
    payload = json.dumps(auth, indent=2) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix="antigravity.", suffix=".token", dir=str(path.parent)
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def _antigravity_oauth_clients() -> list[tuple[str, str]]:
    """Read Google OAuth client metadata from local Antigravity binaries only."""
    client_ids: list[str] = []
    secrets: list[str] = []
    secret_prefix = b"GO" + b"CSPX-"
    secret_re = re.compile(re.escape(secret_prefix) + rb"[A-Za-z0-9_-]{28}")
    client_re = re.compile(rb"\d+-[a-z0-9]+\.apps\.googleusercontent\.com")
    seen_binaries: set[str] = set()
    for binary in ANTIGRAVITY_CLIENT_BINARIES:
        try:
            resolved = str(binary.resolve()) if binary.is_file() else ""
        except OSError:
            continue
        if not resolved or resolved in seen_binaries:
            continue
        seen_binaries.add(resolved)
        try:
            blob = binary.read_bytes()
        except OSError:
            continue
        client_ids.extend(match.group(0).decode("ascii") for match in client_re.finditer(blob))
        secrets.extend(match.group(0).decode("ascii") for match in secret_re.finditer(blob))
    pairs: list[tuple[str, str]] = []
    for client_id in dict.fromkeys(reversed(client_ids)):
        for secret in dict.fromkeys(secrets):
            pair = (client_id, secret)
            if pair not in pairs:
                pairs.append(pair)
    return pairs


def _refresh_antigravity_auth(path: Path, auth: dict[str, Any]) -> Optional[dict[str, Any]]:
    refresh = _antigravity_refresh_token(auth)
    if not refresh:
        return None
    for client_id, client_secret in _antigravity_oauth_clients():
        body = urllib.parse.urlencode(
            {
                "client_id": client_id,
                "client_secret": client_secret,
                "grant_type": "refresh_token",
                "refresh_token": refresh,
            }
        ).encode("utf-8")
        request = urllib.request.Request(
            ANTIGRAVITY_OAUTH_TOKEN_URL,
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                result = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code in (400, 401):
                continue
            return None
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError):
            return None
        if not isinstance(result, dict) or not isinstance(result.get("access_token"), str):
            continue
        payload = dict(_antigravity_token_payload(auth))
        payload["access_token"] = result["access_token"]
        payload["token_type"] = result.get("token_type", payload.get("token_type", "Bearer"))
        if isinstance(result.get("refresh_token"), str) and result["refresh_token"]:
            payload["refresh_token"] = result["refresh_token"]
        expires_in = result.get("expires_in", 3600)
        try:
            seconds = int(expires_in)
        except (TypeError, ValueError):
            seconds = 3600
        payload["expiry"] = (
            datetime.now(timezone.utc) + timedelta(seconds=seconds)
        ).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        updated = dict(auth)
        if isinstance(auth.get("token"), dict):
            updated["token"] = payload
        else:
            updated.update(payload)
        try:
            _write_antigravity_auth(path, updated)
        except OSError:
            return updated
        return updated
    return None


def _resolve_antigravity_auth() -> tuple[Optional[str], str]:
    path, auth = _read_antigravity_auth()
    if auth is None or path is None:
        return None, "antigravity-auth-missing"
    if _antigravity_token_expired(auth):
        refreshed = _refresh_antigravity_auth(path, auth)
        if refreshed is None:
            return None, "antigravity-auth-expired"
        auth = refreshed
    token = _antigravity_access_token(auth)
    if not token:
        return None, "antigravity-auth-missing"
    return token, "ok"


def _antigravity_remaining_fraction(bucket: dict[str, Any]) -> Optional[float]:
    value = bucket.get("remainingFraction")
    if value is None:
        remaining = bucket.get("remaining")
        if isinstance(remaining, dict):
            value = remaining.get("remainingFraction")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if number != number:
        return None
    return max(0.0, min(1.0, number))


def _classify_antigravity_bucket(bucket: dict[str, Any]) -> Optional[str]:
    parts = " ".join(
        str(bucket.get(key) or "")
        for key in ("bucketId", "displayName", "window")
    ).lower()
    if "5h" in parts or "five hour" in parts:
        return "5h"
    if "week" in parts:
        return "weekly"
    return None


def parse_antigravity_summary(data: dict[str, Any]) -> dict[str, Any]:
    """Google AI Pro Gemini pool (5h, else weekly). Not Cursor Other Models."""
    groups = data.get("groups")
    if not isinstance(groups, list):
        return _unset_pool("antigravity-unparsed")
    chosen: Optional[dict[str, Any]] = None
    chosen_kind: Optional[str] = None
    weekly: Optional[dict[str, Any]] = None
    for group in groups:
        if not isinstance(group, dict):
            continue
        name = str(group.get("displayName") or group.get("name") or "").lower()
        if "gemini" not in name:
            continue
        for bucket in group.get("buckets") or []:
            if not isinstance(bucket, dict) or bucket.get("disabled"):
                continue
            kind = _classify_antigravity_bucket(bucket)
            if kind == "5h":
                chosen = bucket
                chosen_kind = "5h"
            elif kind == "weekly":
                weekly = bucket
    if chosen is None:
        chosen = weekly
        chosen_kind = "weekly" if weekly is not None else None
    if chosen is None:
        return _unset_pool("antigravity-window-missing")
    remaining = _antigravity_remaining_fraction(chosen)
    if remaining is None:
        return _unset_pool("antigravity-unparsed")
    used = _round_pct((1.0 - remaining) * 100.0)
    reset_at = _iso_from_reset(chosen.get("resetTime") or chosen.get("reset_time"))
    note = f"gemini-{chosen_kind}" if chosen_kind else "gemini"
    return _pool(used, reset_at, note=note)


def _fetch_antigravity_summary(access_token: str) -> tuple[Optional[dict[str, Any]], str]:
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Accept": "application/json",
        "User-Agent": ANTIGRAVITY_UA,
    }
    status, loaded, detail = _http_json(
        f"{ANTIGRAVITY_CODE_ASSIST_URL}:loadCodeAssist",
        headers,
        payload={"metadata": {"ideType": "ANTIGRAVITY"}},
    )
    if status in (401, 403):
        return None, "antigravity-auth-failed"
    if not isinstance(loaded, dict):
        return None, f"antigravity-{detail}"
    project = loaded.get("cloudaicompanionProject")
    if not isinstance(project, str) or not project:
        return None, "antigravity-project-missing"
    status, summary, detail = _http_json(
        f"{ANTIGRAVITY_CODE_ASSIST_URL}:retrieveUserQuotaSummary",
        headers,
        payload={"project": project},
    )
    if status in (401, 403):
        return None, "antigravity-auth-failed"
    if not isinstance(summary, dict):
        return None, f"antigravity-{detail}"
    return summary, "ok"


def fetch_antigravity() -> dict[str, Any]:
    token, source = _resolve_antigravity_auth()
    if not token:
        return _unset_pool(source)
    summary, detail = _fetch_antigravity_summary(token)
    if summary is None and detail == "antigravity-auth-failed":
        path, auth = _read_antigravity_auth()
        if path is not None and auth is not None:
            refreshed = _refresh_antigravity_auth(path, auth)
            token = _antigravity_access_token(refreshed) if refreshed else None
            if token:
                summary, detail = _fetch_antigravity_summary(token)
    if summary is None:
        return _unset_pool(detail)
    return parse_antigravity_summary(summary)


def collect_snapshot() -> dict[str, Any]:
    cursor_models, cursor_other = fetch_cursor()
    codex = fetch_codex()
    claude = fetch_claude()
    return {
        "checked_at": _utc_now(),
        "stale_after_seconds": STALE_AFTER_SECONDS,
        "pools": {
            "cursor_models": cursor_models,
            "cursor_other": cursor_other,
            "codex_5h": codex["codex_5h"],
            "codex_7d": codex["codex_7d"],
            "antigravity": fetch_antigravity(),
            "claude_5h": claude["claude_5h"],
            "claude_7d": claude["claude_7d"],
        },
    }


def _atomic_write(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="usage.", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def write_snapshot(snapshot: dict[str, Any]) -> list[str]:
    payload = json.dumps(snapshot, indent=2) + "\n"
    written: list[str] = []
    seen = set()
    for path in USAGE_JSON_PATHS:
        try:
            resolved = str(path.expanduser())
            if resolved in seen:
                continue
            if path == Path("/cursor/stores/user/usage.json") and not path.parent.exists():
                continue
            _atomic_write(path, payload)
            seen.add(resolved)
            written.append(resolved)
        except OSError:
            continue
    return written


def _fmt_pct(pool: dict[str, Any]) -> str:
    used = pool.get("used_percent")
    if used is None:
        return "—"
    return f"{int(used)}%"


def _fmt_compact(pool: dict[str, Any]) -> str:
    used = pool.get("used_percent")
    if used is None:
        return "–"
    return str(int(used))


def menubar_line(snapshot: dict[str, Any]) -> str:
    """Short digit run for the status item. Labels live in the dropdown."""
    pools = snapshot.get("pools") or {}
    return "·".join(
        (
            _fmt_compact(pools.get("cursor_models") or {}),
            _fmt_compact(pools.get("cursor_other") or {}),
            _fmt_compact(pools.get("codex_7d") or {}),
            _fmt_compact(pools.get("antigravity") or {}),
            _fmt_compact(pools.get("claude_7d") or {}),
        )
    )


def plugin_text(snapshot: dict[str, Any]) -> str:
    pools = snapshot.get("pools") or {}
    lines = [
        f"{menubar_line(snapshot)} | size=10",
        "---",
        f"C Cursor Models: {_fmt_pct(pools.get('cursor_models') or {})}",
        f"O Other Models: {_fmt_pct(pools.get('cursor_other') or {})}",
        f"Codex 5h: {_fmt_pct(pools.get('codex_5h') or {})}",
        f"X Codex 7d (weekly): {_fmt_pct(pools.get('codex_7d') or {})}",
        f"G Antigravity 5h: {_fmt_pct(pools.get('antigravity') or {})}",
        f"Claude 5h: {_fmt_pct(pools.get('claude_5h') or {})}",
        f"A Claude 7d (weekly): {_fmt_pct(pools.get('claude_7d') or {})}",
        f"Checked {snapshot.get('checked_at') or 'unknown'}",
        "---",
        "Refresh | refresh=true",
        "Cursor usage dashboard | href=https://cursor.com/dashboard?tab=usage",
        "Codex | href=https://chatgpt.com/codex",
        "Antigravity | href=https://antigravity.google",
        "Claude usage | href=https://claude.ai/settings/usage",
    ]
    for key, label in (
        ("cursor_models", "Cursor Models"),
        ("cursor_other", "Other Models"),
        ("codex_5h", "Codex 5h"),
        ("codex_7d", "Codex 7d"),
        ("antigravity", "Antigravity"),
        ("claude_5h", "Claude 5h"),
        ("claude_7d", "Claude 7d"),
    ):
        note = (pools.get(key) or {}).get("note")
        if note:
            lines.append(f"{label} note: {note}")
    return "\n".join(lines) + "\n"


def _self_test() -> int:
    cursor_sample = {
        "billingCycleEnd": "2026-10-04T00:00:00.000Z",
        "isUnlimited": False,
        "individualUsage": {
            "plan": {
                "autoPercentUsed": 12.4,
                "apiPercentUsed": 100,
                "totalPercentUsed": 40,
            }
        },
    }
    models, other = parse_cursor_summary(cursor_sample)
    assert models["used_percent"] == 12 and models["ok"] is True
    assert other["used_percent"] == 100 and other["ok"] is False
    app_server_sample = {
        "rateLimits": {
            "limitId": "codex",
            "primary": {
                "usedPercent": 0,
                "windowDurationMins": 300,
                "resetsAt": 1780000000,
            },
            "secondary": {
                "usedPercent": 18,
                "windowDurationMins": 10080,
                "resetsAt": 1780600000,
            },
        },
        "rateLimitsByLimitId": {
            "base_model_inference": {
                "limitId": "base_model_inference",
                "limitName": "gpt-reserve",
                "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 10080,
                    "resetsAt": 1781000000,
                },
            },
            "codex": {
                "limitId": "codex",
                "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 300,
                    "resetsAt": 1780000000,
                },
                "secondary": {
                    "usedPercent": 18,
                    "windowDurationMins": 10080,
                    "resetsAt": 1780600000,
                },
            },
        },
    }
    parsed = parse_codex_app_server(app_server_sample)
    assert parsed["codex_5h"]["used_percent"] == 0
    assert parsed["codex_7d"]["used_percent"] == 18
    http_sample = {
        "rate_limit": {
            "primary_window": {
                "used_percent": 0,
                "limit_window_seconds": 18000,
                "reset_at": 1780000000,
            },
            "secondary_window": {
                "used_percent": 18,
                "limit_window_seconds": 604800,
                "reset_at": 1780600000,
            },
        },
        "additional_rate_limits": [
            {
                "limit_name": "gpt-reserve",
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 0,
                        "limit_window_seconds": 604800,
                    }
                },
            }
        ],
    }
    parsed_http = parse_codex_http(http_sample)
    assert parsed_http["codex_5h"]["used_percent"] == 0
    assert parsed_http["codex_7d"]["used_percent"] == 18
    antigravity_sample = {
        "groups": [
            {
                "displayName": "Gemini Models",
                "buckets": [
                    {
                        "bucketId": "gemini-weekly",
                        "displayName": "Weekly Limit Remaining",
                        "window": "weekly",
                        "remainingFraction": 0.82,
                        "resetTime": "2026-09-27T16:52:54Z",
                    },
                    {
                        "bucketId": "gemini-5h",
                        "displayName": "Five Hour Limit Remaining",
                        "window": "5h",
                        "remainingFraction": 0.625,
                        "resetTime": "2026-09-20T21:52:54Z",
                    },
                ],
            },
            {
                "displayName": "Claude and GPT models",
                "buckets": [
                    {
                        "bucketId": "3p-5h",
                        "window": "5h",
                        "remainingFraction": 0.1,
                    }
                ],
            },
        ]
    }
    antigravity = parse_antigravity_summary(antigravity_sample)
    assert antigravity["used_percent"] == 38
    assert antigravity["ok"] is True
    assert antigravity["note"] == "gemini-5h"
    claude_sample = {
        "five_hour": {"utilization": 12.4, "resets_at": "2026-10-08T21:00:00+00:00"},
        "seven_day": {"utilization": 100, "resets_at": "2026-10-15T21:00:00Z"},
        "seven_day_sonnet": {"utilization": 44},
    }
    claude = parse_claude_usage(claude_sample)
    assert claude["claude_5h"] == _pool(12, "2026-10-08T21:00:00Z")
    assert claude["claude_7d"] == _pool(100, "2026-10-15T21:00:00Z")
    assert parse_claude_usage({"five_hour": {"utilization": 0}})["claude_5h"]["ok"] is True
    assert parse_claude_usage({"seven_day": None})["claude_7d"]["ok"] is None
    for bad_value in (None, True, "25", float("nan"), float("inf"), -1, 101):
        assert parse_claude_usage({"five_hour": {"utilization": bad_value}})["claude_5h"]["used_percent"] is None
    from unittest.mock import patch
    with patch(__name__ + "._read_claude_auth", return_value=[]):
        assert fetch_claude()["claude_7d"]["ok"] is None
    expired = {"accessToken": "test-expired", "expiresAt": 1}
    with patch(__name__ + "._read_claude_auth", return_value=[expired]), patch(__name__ + "._http_json") as http:
        assert "expired" in fetch_claude()["claude_5h"]["note"]
        http.assert_not_called()
    valid = {"accessToken": "test-only"}
    with patch(__name__ + "._read_claude_auth", return_value=[valid]), patch(__name__ + "._http_json", return_value=(429, None, "http-429")) as http:
        assert fetch_claude()["claude_7d"] == _unset_pool("claude-rate-limited")
        assert http.call_count == 1
    with patch(__name__ + "._read_claude_auth", return_value=[expired, valid]), patch(__name__ + "._http_json", return_value=(200, claude_sample, "ok")):
        assert fetch_claude() == claude
    dummy_payload = base64.urlsafe_b64encode(json.dumps({"sub": "auth0|testuser"}).encode()).decode().rstrip("=")
    dummy_jwt = f"eyJhbGciOiJub25lIn0.{dummy_payload}.sig"
    assert _cookie_from_access_token(dummy_jwt) == f"testuser%3A%3A{dummy_jwt}"
    assert _cookie_from_access_token("direct%3A%3Acookie") == "direct%3A%3Acookie"
    assert _cookie_from_access_token("direct::cookie") == "direct%3A%3Acookie"
    assert _cookie_from_access_token("invalid") is None
    with patch(__name__ + "._read_cursor_db_token", return_value=None), \
         patch(__name__ + "._read_cursor_agent_token", return_value=dummy_jwt), \
         patch.dict(os.environ, {"USAGE_METER_CURSOR_SESSION": ""}, clear=False), \
         patch(__name__ + "._read_file_secret", return_value=None), \
         patch(__name__ + "._read_keychain_session", return_value=None):
        cookie, source = resolve_cursor_cookie()
        assert cookie == f"testuser%3A%3A{dummy_jwt}"
        assert source == "cursor-agent"
    snapshot = {
        "checked_at": "2026-09-18T11:40:00Z",
        "pools": {
            "cursor_models": models,
            "cursor_other": other,
            "codex_5h": parsed["codex_5h"],
            "codex_7d": parsed["codex_7d"],
            "antigravity": antigravity,
            **claude,
        },
    }
    assert menubar_line(snapshot) == "12·100·18·38·100"
    assert "Claude 5h: 12%" in plugin_text(snapshot)
    assert "A Claude 7d (weekly): 100%" in plugin_text(snapshot)
    unset_snapshot = {
        "pools": {
            "cursor_models": models,
            "cursor_other": other,
            "codex_7d": parsed["codex_7d"],
            "antigravity": _unset_pool("unset"),
        }
    }
    assert menubar_line(unset_snapshot) == "12·100·18·–·–"
    print("self-test ok")
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Collect local AI usage quotas")
    parser.add_argument("--json", action="store_true", help="print snapshot JSON")
    parser.add_argument("--plugin", action="store_true", help="print SwiftBar text")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    _ensure_path()
    if args.self_test:
        return _self_test()
    snapshot = collect_snapshot()
    write_snapshot(snapshot)
    if args.plugin:
        sys.stdout.write(plugin_text(snapshot))
        return 0
    if args.json or not args.plugin:
        json.dump(snapshot, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
