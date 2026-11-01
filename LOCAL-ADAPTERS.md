# Local adapters: Cursor and Muse (and no Grok)

This build has five active providers: Claude, Codex, Antigravity (Gemini), Cursor and Muse.
Cursor reads the local usage-meter snapshot; Muse asks its official CLI. Grok is removed.

## Cursor

**What LimitBar reads.** The agent snapshot written by the in-repo *usage-meter* collector
(`usage.json`, located in `tools/usage-meter/collect.py`, contract in [tools/usage-meter/README.md](tools/usage-meter/README.md)): `checked_at`, `stale_after_seconds` and the pools
`cursor_models` (the plan's included pool) and `cursor_other` (other models). Nothing else in the file
is used; the other pools, notes and any other fields are ignored and never shown or cached.

**Where.** Found under `~/Library/Application Support/Cursor/AgentStores/cursor_agent_stores/*/files/usage.json`
(the folder name is an account id, so it is discovered, never written into the source), else
`/cursor/stores/user/usage.json`. More than one file → LimitBar picks none and asks for
`defaults write io.github.dancik.limitbar cursorUsagePath /abs/path/usage.json`.

**Checks.** The file must be a regular file (not a link), owned by you, writable by nobody else, with no
write ACL, ≤ 1 MiB, in folders nobody else can change; otherwise it is `untrusted` and not read.

**Unknown is never 0.**

- A pool whose `used_percent` is null, a boolean, a string, negative, non-finite or above 1000 is unknown (`—`).
- 100–1000 shows as 100 with an "over the included amount" note.
- If the snapshot is older than its own `stale_after_seconds` (900 unless that field is a sane number), both pools show `—` with "Snapshot is N min old". The original `checked_at` stays the "updated" time.
- A snapshot dated more than 5 minutes in the future is not used.
- When both pools carry usage-meter's `cursor-auth-*` note, the state is signed out, with usage-meter's setup hint.
- A `reset_at` in the past shows "reset — awaiting update", as upstream does for every vendor.

**Cadence.** The file is re-read whenever it changes, at most every 30 s, and at least every 60 s.

### Keeping usage.json fresh with bundled helper (opt-in)

The usage-meter collector is packaged directly in this repository at `tools/usage-meter/collect.py`.
LimitBar runs the bundled `usage-meter-refresh.py` helper every 5 minutes to keep `usage.json` fresh:

Point LimitBar at the packaged collector in your checkout:

```bash
defaults write io.github.dancik.limitbar usageMeterCollector /path/to/limitbar/tools/usage-meter/collect.py
# optional, default /usr/bin/python3 (must pass LimitBar's trust check)
defaults write io.github.dancik.limitbar usageMeterPython /usr/bin/python3
```

If migrating from an existing legacy SwiftBar plugin installation, disable the SwiftBar plugin first to avoid uncoordinated runs (the legacy plugin does not take this helper's lock).

Then, every 5 minutes on its own queue (never holding up the CLI fetches), LimitBar runs the bundled
`Contents/Resources/usage-meter-refresh.py` with `python3 -I -B` and LimitBar's allowlisted environment. That
helper:

1. only runs a file named `collect.py` that is a regular file of yours, writable by nobody else, with no extended ACL granting write/delete/security changes on the file or its ancestors, in folders nobody else can change (`untrusted` otherwise);
2. takes an exclusive lock (`~/Library/Caches/limitbar/usage-meter.lock`), so helper runs never overlap (`locked-skip`), but the legacy plugin does not take this lock;
3. skips the run when the newest existing `usage.json` was checked less than 240 s ago (`fresh-skip`). This reduces redundant helper work; it cannot coordinate the legacy plugin;
4. otherwise calls exactly what the plugin calls: `collect._ensure_path()`, `collect.collect_snapshot()`, `collect.write_snapshot()`. The JSON paths and shape are the collector's own, unchanged;
5. sends the collector's stdout and stderr (including OS descriptor writes and inherited subprocess output) to /dev/null and prints one line, `{"status": …, "written": n, "known_pools": n}`. It never prints paths, numbers, identifiers or anything the collector says. LimitBar shows only a fixed note under Cursor when a run fails.

**Boundary.** This helper is **not sandboxed**. The collector is your own code. It reads Cursor's session, the Codex/Claude/Antigravity
sign-ins and the Keychain, refreshes the Antigravity access token as it already does under SwiftBar, and
talks to the vendors' usage endpoints. LimitBar adds no new credential access. It moves the existing 5-minute caller from SwiftBar to LimitBar. Nothing runs while `usageMeterCollector` is unset.

## Muse Code

**Source.** Muse 1.4.13 or later provides `muse usage --json`, a dedicated allowance query with no model turn. LimitBar runs the trusted native binary under its existing CLI sandbox, with a 20-second deadline and an allowlisted environment. For the self-updating shell launcher, it resolves the native binary named in `.muse-version` instead of running the updater. Sign-in and Keychain access stay inside the official CLI; LimitBar does not read credentials or call the native key-issuing API.

**Quota.** Schema version 1 supplies `allowance.asOfMs`, `window` and `weekly` with `usedPercent` and `resetsAtMs`. The five-hour window appears above weekly. Only canonical plan names, quota numbers, reset times and the provider observation time are retained. Missing/malformed caps stay unknown; booleans, strings, negative/nonfinite/extreme values never become zero. Readings dated in the future or older than 45 minutes, unsupported schemas, nonzero exits and responses with a reason/hint fail closed. Passed resets retain the existing awaiting-update display.

**Cadence.** Automatic reads start without a Connect step. Every read, including failed/missing reads, observes a 30-minute floor after completion using monotonic uptime. Hover, force, wake, reset and activity do not shorten it; relaunch starts a new process budget. `museDirectQuota` and `museHost` preferences never select the normal source.

**Legacy diagnostics.** The old native adapter and MSP host code remain isolated fixture support. Normal Store and default probe cannot select the native credential/HTTP adapter. A synthetic host diagnostic requires `--muse-host-diagnostic`, explicit source path overrides for all five providers and `-museHost YES`; it is not used for normal quota polling.

## Grok

Removed: no `grok` vendor, fetcher, sandbox case, search path (`~/.grok/bin`), mark, tests or docs. An upstream
cache entry `"grok"` in `~/Library/Caches/limitbar/state.json` is skipped on load, not fatal.

## Tests

- `tests/states.sh <app>`: the five vendors' missing / signed-out / untrusted / setup states, with fake CLIs.
- `tests/local.sh <app>`: Cursor snapshot parsing (numeric, stale, booleans, strings, negative, non-finite, over 100, out of range, reset passed, future-dated, garbage, signed out, group-writable, symlink), Muse host fixtures (numeric, push, invalid, over-quota, reset passed, bad time, nothing observed, off), the refresh helper (refreshed, fresh-skip, locked-skip, untrusted, import-failed, collect-failed, name check), and that no fake token, key, email or account id ever reaches the output.
- `tests/fixes.py <app>` (also run by `tests/local.sh`): targeted synthetic ACL, overlap/drained cutover, descriptor-output, numeric/date-boundary, actual Store cache/scheduling and immutable-note regressions. The Swift harness redirects `Paths.cache` in temporary source copies explicitly; HOME alone is not cache isolation. It constructs only `Store(preview:)`, never normal timers/fetch startup.
- `tests/muse-usage.py <app>` (also run by `tests/native-muse.py`): current CLI command/gate, schema validation, missing/invalid/stale/future allowance, error fields, partial caps, exhausted quota, retained timestamps/resets and private-field suppression. All sources have explicit fake paths.
- `tests/native-muse.py <app>` (also run by `tests/local.sh`): the CLI checks plus isolated legacy credential/transport/parser fixtures with injected secrets/network only; no production Connect path.
- `tests/sandbox.sh`: unchanged checks of `Resources/cli.sb` with the new `STATE2` parameter.
- `LimitBar --render-preview <snapshots.json> <out.png> [--dark]`: draws the item and panel offscreen for a layout/wording check. The real menu bar and the panel's glass are not in that picture.
