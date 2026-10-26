# Local adapters: Cursor active, Muse parked (and no Grok)

This build has exactly four active providers: Claude, Codex, Antigravity (Gemini) and Cursor. Muse code and tests are parked, reversible source only. No runtime toggle enables it; old museDirectQuota/museHost preferences and cached Muse entries cannot add rows, Connect, polling, credential reads, HTTP or CLI work.

This local branch of LimitBar removes Grok Build and retains two sources upstream does not have. Upstream's
rule is "ask the vendor's official CLI; never open a credential". Both additions step outside that rule in
narrow ways, written down here so they can be reviewed and turned on deliberately.

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

**Parked in this build.** The implementation below describes retained source, not an available product feature. The static `Vendor.activeVendors` list excludes Muse from Store startup/cache, polling/scheduling, Connect, tray, panel and missing rows. `Vendor.allCases` still contains all five cases. No preferences are changed or needed. Isolated legacy Swift fixture copies explicitly include all cases to keep cadence/security coverage.

**Retained implementation (inactive): Connect Muse.** The native adapter does not need a running Muse CLI or Python permission.
Before a successful connection, normal startup, hover, wake and Refresh do not read Muse credentials
or call its API. `museHost` never selects the normal provider anymore.

**Intentional connection.** The native button is visible only in setup or permission-needed state.
It sets the same busy state/spinner as other native reads and serializes work off main. Only this action
allows a Keychain prompt. If access is declined, fixed inline feedback appears and background reads stop.
An initial manual connection may run without waiting for a disabled-source setup check. Subsequent
Connect attempts and every enabled automatic poll respect the r6 30-minute floor after completion;
force, hover, wake, reset and activity cannot bypass it. Busy blocks overlap. Timing uses monotonic uptime
within one running process; relaunch does not preserve the floor.

HTTP 200 with strictly validated active subscription/payment flags opts into automatic reads via the
nonsecret `museDirectQuota` preference. This includes an active login whose answer omits quota: its safe
plan remains visible, quota stays unknown, and no measurement time is invented. Connection failures do
not enable polling. An explicit failed reconnect disables it. No preference was changed during authoring.

**Credential boundary.** `Muse.swift` owns all native Muse secret I/O. It reads only the existing
`~/.config/muse/auth.json` (trusted regular owner-only file, no group/other permissions or write ACL, bounded at 1 MiB) and the exact
Keychain generic-password service `ai.meta.dev.credentials`, account `meta`. A nonblank inline
`providers.meta.access_token` wins, matching upstream precedence; malformed/unrelated auth JSON falls
back to the Keychain, but an unusable nonblank inline token does not. Keychain JSON uses `access_token`.
Only bounded printable `dca:` device-login tokens qualify. No environment token override or secret CLI
argument exists. No credential, hash, identifier, email, returned inference key or payment field is stored.

Background uses `kSecUseAuthenticationUIFail` and a query-specific `LAContext` with interaction disabled.
Because legacy Keychain ACLs can require prompts, it first inspects the exact item's decrypt ACL without
requesting its secret. Unknown ACL access fails closed; permission-required status is distinct from
missing login, declined access, malformed JSON, unusable token and unavailable Keychain. No global
Security interaction switch changes other providers. No ACL is edited by the adapter. Only the human
may approve an OS prompt after installing the reviewed app; ad-hoc build identity/path changes may
require a new grant. Grant/prompt behavior remains a human acceptance gate.

**Network boundary.** One native ephemeral URLSession task per poll: hardcoded HTTPS
`https://api.meta.ai/muse-code/key`, POST `{}`, Authorization Bearer existing login token,
`x-api-version: 1.0.0`, 15-second absolute deadline, standard TLS, redirects denied, no cookies,
credential storage, environment proxies or URL cache, response at most 1 MiB. No retry/refresh/model
call, CLI startup, login/logout, credential write or inference-key persistence exists. This endpoint
**may issue an inference key**: direct quota does not establish nonrotation or old-key validity.

**Truthful quota.** Strict booleans are required for `require_payment` and `is_subs_active`. Only safe
canonical documented plans (Everyday, High Usage, Power Usage, Maximum Usage, or Muse Code) reach the
UI/cache. Invalid percentages remain unknown; 100–1000 is bounded to 100 with an over-limit flag.
`window_duration_mins` uses r6's one-second through one-week guard and fractional formatting; invalid
duration retains the generic Window label. `resets_at` uses seconds and r6's UTC 2000–2100 bounds.
Only valid received quota gets the request-completion `measuredAt`. Missing/null `subs_usage` keeps the
active plan with a specific unknown-quota message. No browser-session or team fallback is implemented.
The native source note says “Muse quota API”; it makes no cross-account or key-validity claim.

**Retained diagnostic.** The old trust-checked `muse serve` implementation and sandbox are retained as
`Fetch.museHost()` for backward fixture coverage. `--probe` normally returns only the four active providers, even with legacy opt-ins. A separately authorized
legacy host diagnostic requires `--muse-host-diagnostic`, explicit path overrides for all five sources, and `-museHost YES`. Use only fully synthetic fixtures; native credentials are never enabled by this flag.
It may mint/update CLI credentials; do not use it for normal quota polling. Existing fake-host coverage
uses explicit synthetic paths and overrides all five sources. The old helper, CLI sources, sandbox,
other four providers and r6 cutover policy remain in place.

Primary references: [native credential precedence](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Muse/MuseCredentials.swift),
[upstream Muse API parser](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Resources/Plugins/muse.ts),
[Meta subscription plans](https://dev.meta.ai/docs/muse-code/subscriptions),
[Maximum Usage](https://dev.meta.ai/resources/blog/build-with-muse-wonder).

## Grok

Removed: no `grok` vendor, fetcher, sandbox case, search path (`~/.grok/bin`), mark, tests or docs. An upstream
cache entry `"grok"` in `~/Library/Caches/limitbar/state.json` is skipped on load, not fatal.

## Tests

- `tests/states.sh <app>`: the five vendors' missing / signed-out / untrusted / setup states, with fake CLIs.
- `tests/local.sh <app>`: Cursor snapshot parsing (numeric, stale, booleans, strings, negative, non-finite, over 100, out of range, reset passed, future-dated, garbage, signed out, group-writable, symlink), Muse host fixtures (numeric, push, invalid, over-quota, reset passed, bad time, nothing observed, off), the refresh helper (refreshed, fresh-skip, locked-skip, untrusted, import-failed, collect-failed, name check), and that no fake token, key, email or account id ever reaches the output.
- `tests/fixes.py <app>` (also run by `tests/local.sh`): targeted synthetic ACL, overlap/drained cutover, descriptor-output, numeric/date-boundary, actual Store cache/scheduling and immutable-note regressions. The Swift harness redirects `Paths.cache` in temporary source copies explicitly; HOME alone is not cache isolation. It constructs only `Store(preview:)`, never normal timers/fetch startup.
- `tests/native-muse.py <app> --four-only`: narrow production gate regression, normal Store startup/hover/force/wake/Connect with legacy defaults and cache, explicit fake home/Foundation cache, and byte-identical offscreen tray/panel/missing-row output for parked states.
- `tests/native-muse.py` (also run by `tests/local.sh`): native credential/status, no-UI/manual query, strict response, URLSession transport and Store connection/cadence tests. Explicit private cache and injected fake secrets/network only.
- `tests/sandbox.sh`: unchanged checks of `Resources/cli.sb` with the new `STATE2` parameter.
- `LimitBar --render-preview <snapshots.json> <out.png> [--dark]`: draws the item and panel offscreen for a layout/wording check. The real menu bar and the panel's glass are not in that picture.
