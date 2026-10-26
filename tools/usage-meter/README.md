# Usage Meter (Packaged Tool)

Local collector for Cursor, Codex, Antigravity, and Claude subscription quota percentages. Writes a JSON snapshot consumed by LimitBar and local agents.

> **Source note:** Packaged from `usage-meter` at commit `f190de5` (`f190de5cc8b88ff522c27c6e1f6dec773c13693d`).

## Usage

From this checkout directory:

```bash
python3 tools/usage-meter/collect.py --self-test
python3 tools/usage-meter/collect.py --json
```

Or run directly from the tool folder:

```bash
cd tools/usage-meter
python3 collect.py --json
```

## Legacy SwiftBar status

SwiftBar integration is optional and legacy. For LimitBar users, LimitBar's bundled `usage-meter-refresh.py` helper runs this collector directly every 5 minutes (see [LOCAL-ADAPTERS.md](../../LOCAL-ADAPTERS.md)), without requiring SwiftBar.

## JSON snapshot contract

The collector discovers the local Cursor account store dynamically:
- `~/Library/Application Support/Cursor/AgentStores/cursor_agent_stores/<account>/files/usage.json` (when exactly one matching account exists)
- `/cursor/stores/user/usage.json` (fallback path when `/cursor/stores/user` exists)

When multiple matching account stores exist, the collector does not choose one; it writes only the shared fallback when that location is available. LimitBar’s `cursorUsagePath` preference selects which snapshot the app reads; it does not select the collector’s output path.

Agents and LimitBar read `checked_at`, `stale_after_seconds` (default 900), and `pools`:
- `cursor_models`: Included Cursor models quota
- `cursor_other`: Other Cursor models quota
- `codex_5h`: 5-hour Codex window
- `codex_7d`: 7-day Codex weekly window
- `antigravity`: Google AI Pro Gemini 5-hour quota
- `claude_5h`: 5-hour Claude subscription window
- `claude_7d`: 7-day Claude subscription window

A snapshot older than `stale_after_seconds` is treated as stale/unknown, never 0%.

## Authentication (local only)

- **Cursor:** Discovered automatically from Cursor CLI/agent credentials or `state.vscdb`. If needed, run `bin/setup-cursor-session` once from this directory to save the session token locally in `~/.config/usage-meter/cursor-session` (mode 0600) and macOS Keychain.
- **Codex:** Reads `~/.codex/auth.json` and queries `codex app-server`.
- **Claude:** Reads `Claude Code-credentials` from macOS Keychain or `~/.claude/.credentials.json`.
- **Antigravity:** Uses local Google OAuth tokens (`~/.gemini/antigravity-cli/antigravity-oauth-token` or `~/.gemini/jetski-standalone-oauth-token`).

Credentials stay local to this Mac. Never commit tokens, session cookies, or Keychain values.
