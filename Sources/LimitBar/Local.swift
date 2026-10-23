import Darwin
import Foundation

// Local additions to upstream limitbar: Cursor and Muse. Boundaries are written up in LOCAL-ADAPTERS.md.
// As everywhere else in limitbar, error texts are fixed strings of ours; nothing a source says is shown.

extension Fetch {
    // MARK: Cursor — the usage-meter snapshot (`usage.json`). Read-only: limitbar runs nothing for it.

    /// Where usage-meter writes its agent snapshot. The user-store folder name is an account id, so it is
    /// found, never written into this source. `defaults write … cursorUsagePath /abs/path` pins one file.
    static let cursorStoreRoot = "\(home)/Library/Application Support/Cursor/AgentStores/cursor_agent_stores"
    static let cursorSharedPath = "/cursor/stores/user/usage.json"
    static let cursorMaxBytes = 1 << 20

    enum Located { case ok(String), missing, ambiguous, untrusted }

    static func cursorFile() -> Located {
        let fm = FileManager.default
        if let p = UserDefaults.standard.string(forKey: "cursorUsagePath"), p.hasPrefix("/") {
            guard fm.fileExists(atPath: p) else { return .missing }
            return trustedData(p) ? .ok(p) : .untrusted
        }
        var found: [String] = []
        for d in (try? fm.contentsOfDirectory(atPath: cursorStoreRoot)) ?? [] {
            let p = "\(cursorStoreRoot)/\(d)/files/usage.json"
            if fm.fileExists(atPath: p) { found.append(p) }
        }
        if found.isEmpty, fm.fileExists(atPath: cursorSharedPath) { found = [cursorSharedPath] }
        guard found.count <= 1 else { return .ambiguous }      // never pick one account's file for you
        guard let p = found.first else { return .missing }
        return trustedData(p) ? .ok(p) : .untrusted
    }

    /// A data file we read: a regular file (not a link) of this user, writable by nobody else, in folders
    /// nobody else can change, and small.
    static func trustedData(_ p: String) -> Bool {
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= cursorMaxBytes,
              st.st_uid == getuid(), (st.st_mode & (S_IWGRP | S_IWOTH)) == 0, !CLI.aclGrantsWrite(p) else { return false }
        return CLI.safeChain((p as NSString).deletingLastPathComponent)
    }

    static func cursor() -> Snapshot {
        switch cursorFile() {
        case .missing: return .status(.cursor, .missing)
        case .ambiguous: return .status(.cursor, .failed, "several Cursor usage files — set cursorUsagePath (see README)")
        case .untrusted: return .status(.cursor, .untrusted, "usage.json could be changed by another account — not read")
        case .ok(let p):
            guard let d = FileManager.default.contents(atPath: p), d.count <= cursorMaxBytes else {
                return .status(.cursor, .failed, "usage-meter snapshot unreadable")
            }
            return cursorParse(d)
        }
    }

    /// The usage-meter contract (usage-meter/README.md): `checked_at`, `stale_after_seconds`, and the pools
    /// `cursor_models` (the plan's included pool) and `cursor_other` (other models). A pool that is null,
    /// malformed or out of range stays unknown; a snapshot older than its own stale_after_seconds makes both
    /// unknown. Never 0 in place of unknown. `measuredAt` is the collector's own `checked_at`.
    static func cursorParse(_ d: Data, now: Date = Date()) -> Snapshot {
        guard let o = json(d), let pools = o["pools"] as? [String: Any],
              let checked = date(o["checked_at"] as? String) else {
            return .status(.cursor, .failed, "usage-meter snapshot unreadable")
        }
        guard checked.timeIntervalSince(now) < 300 else {
            return .status(.cursor, .failed, "usage-meter snapshot is dated in the future — not used")
        }
        var staleAfter: TimeInterval = 900
        if let s = number(o["stale_after_seconds"]), s.isFinite, s >= 60, s <= 86_400 { staleAfter = s }
        let age = now.timeIntervalSince(checked)
        let stale = age > staleAfter
        var notes: [String] = [], authFailures = 0
        func win(_ key: String, _ label: String) -> Window {
            let p = pools[key] as? [String: Any] ?? [:]
            if (p["note"] as? String)?.hasPrefix("cursor-auth") == true { authFailures += 1 }
            var used: Double?
            if !stale, let v = overPercent(p["used_percent"]) {
                used = v.used
                if v.over { notes.append("\(label): over the included amount") }
            }
            return Window(label: label, short: "", used: used, resetsAt: date(p["reset_at"]))
        }
        let models = win("cursor_models", "Cursor models"), other = win("cursor_other", "Other models")
        var s = Snapshot(vendor: .cursor, bar: models, windows: [models, other], notes: notes, measuredAt: checked)
        if stale {
            s.error = "Snapshot is \(Int(age / 60)) min old — unknown until usage-meter refreshes it"
        } else if models.used == nil && other.used == nil {
            if authFailures == 2 { s.state = .signedOut; s.windows = []; s.bar = nil }
            else { s.error = "usage-meter could not read Cursor usage this time" }
        }
        return s
    }

    // MARK: Muse — `usage/read` on the CLI's own MSP host (`muse serve`), only when turned on.

    /// Muse 1.4's launcher (`~/.local/bin/muse`) is a shell script that checks for and installs updates before
    /// starting the native binary it keeps beside itself. The sandbox cannot let it update, so limitbar runs
    /// the native binary named by the launcher's `.muse-version` instead — checked like any other CLI.
    static func museBinary() -> (String?, Snapshot?) {
        let link: String
        switch CLI.find(Vendor.muse.cli) {
        case .ok(let p): link = p
        case .missing: return (nil, .status(.muse, .missing))
        case .untrusted: return (nil, .status(.muse, .untrusted, "muse could be replaced by another account — not run"))
        }
        let plain = { binary(.muse) }     // anything but the launcher: the usual checks, interpreter included
        guard let real = Sandbox.real(link), let h = FileHandle(forReadingAtPath: real) else { return plain() }
        let head = h.readData(ofLength: 2); try? h.close()
        guard head == Data("#!".utf8) else { return plain() }
        let dir = (real as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: "\(dir)/.muse-version") else { return plain() }   // not the launcher
        guard CLI.safeNode("\(dir)/.muse-version", isLink: false),
              let raw = try? String(contentsOfFile: "\(dir)/.muse-version", encoding: .utf8) else {
            return (nil, .status(.muse, .failed, "muse launcher without its native binary — not run"))
        }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^[0-9A-Za-z.\-]{1,40}$"#, options: .regularExpression) != nil else {
            return (nil, .status(.muse, .failed, "muse launcher without its native binary — not run"))
        }
        let native = "\(dir)/muse-bin-\(version)"
        guard FileManager.default.isExecutableFile(atPath: native) else {
            return (nil, .status(.muse, .failed, "muse launcher without its native binary — not run"))
        }
        guard CLI.trusted(native) else {
            return (nil, .status(.muse, .untrusted, "muse could be replaced by another account — not run"))
        }
        return (native, nil)
    }

    /// Whether host reads are on: `defaults write io.github.dancik.limitbar museHost -bool YES`. Off by
    /// default because starting the host may mint a key or update CLI-managed credentials. Startup-auth
    /// machinery exists, but its `serve` call path is unverified (LOCAL-ADAPTERS.md).
    static var museHostEnabled: Bool { UserDefaults.standard.bool(forKey: "museHost") }

    static func muse() -> Snapshot { MuseNative.setup }

    /// Explicit legacy diagnostic only. Never called by Store/native polling.
    static func museHost() -> Snapshot {
        let (b, why) = museBinary()
        guard let bin = b else { return why! }
        guard museHostEnabled else {
            return .status(.muse, .setup, "Quota reads are off: starting Muse may mint a key or update CLI credentials (see README)")
        }
        guard let box = Sandbox.wrap(.muse, bin, ["serve", "--provider", "meta", "--no-session-log",
                                                  "--disable-shell", "--disable-write"]) else {
            return .status(.muse, .failed, "sandbox unavailable — muse not run")
        }
        switch CLI.rpcPoll(box.argv, binary: box.binary,
                           initialize: ["clientInfo": ["name": "limitbar", "version": "1"]], notify: "initialized",
                           method: "usage/read", ready: { $0["usage"] != nil }, changed: "usage/changed",
                           timeout: 25, extraEnv: box.env) {
        case .failed(let e):
            return .status(.muse, signedOutText(e) ? .signedOut : .failed, signedOutText(e) ? nil : "muse gave no usage")
        case .ok(let r):
            guard let u = r["usage"] as? [String: Any] else {
                // Absence describes the host's observation state, not authentication or an idle window.
                return .status(.muse, .failed, "Muse host has not observed quota; sign-in status unverified")
            }
            return museParse(u)
        }
    }

    /// MSP `SubscriptionUsage` (muse schema, ADR 32563 D2): `window` {usedPercent, windowDurationMins,
    /// resetsAtMs}, `weekly` {usedPercent, resetsAtMs}, `tier`, `observedAtMs`. Percentages are integers ≥ 0
    /// and may exceed 100 (shown as 100, flagged). `measuredAt` is Muse's own observation stamp.
    static func museParse(_ u: [String: Any], now: Date = Date()) -> Snapshot {
        guard let ms = number(u["observedAtMs"]), let observed = supportedDate(seconds: ms / 1000) else {
            return .status(.muse, .failed, "muse usage without a time — not used")
        }
        guard observed.timeIntervalSince(now) < 300 else {
            return .status(.muse, .failed, "muse usage is dated in the future — not used")
        }
        func reset(_ o: [String: Any]) -> Date? {
            guard let r = number(o["resetsAtMs"]) else { return nil }
            return supportedDate(seconds: r / 1000)
        }
        var notes: [String] = []
        func used(_ o: [String: Any], _ label: String) -> Double? {
            guard let v = overPercent(o["usedPercent"]) else { return nil }
            if v.over { notes.append("\(label): over the limit") }
            return v.used
        }
        var windows: [Window] = []
        if let w = u["window"] as? [String: Any] {
            // Explicitly invalid durations do not become an invented 5-hour window. Fractional minutes
            // are supported, from one second through one week; format only bounded values (no Int trap).
            var label = "Window", short = ""
            if let m = number(w["windowDurationMins"]), m.isFinite, m >= 1.0 / 60, m <= 10_080 {
                let h = m / 60
                let value = h == h.rounded() ? h : m
                let text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
                    .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
                label = "\(text)-" + (h == h.rounded() ? "hour" : "minute")
                short = text + (h == h.rounded() ? "h" : "m")
            }
            windows.append(Window(label: label, short: short, used: used(w, label), resetsAt: reset(w)))
        }
        if let w = u["weekly"] as? [String: Any] {
            windows.append(Window(label: "Week", short: "w", used: used(w, "Week"), resetsAt: reset(w)))
        }
        guard windows.contains(where: { $0.used != nil }) else {
            return .status(.muse, .failed, "no usable numbers in muse's usage answer")
        }
        return Snapshot(vendor: .muse, plan: musePlan(u["tier"]), bar: windows.first { $0.used != nil },
                        windows: windows, notes: notes, measuredAt: observed)
    }

    /// Diagnostic host plans use the same safe canonical names as native quota responses.
    static func musePlan(_ any: Any?) -> String { MuseNative.plan(any) }

}

extension CLI {
    /// Like `rpc`, but asks `method` again (once a second) until `ready` accepts the answer, a `changed`
    /// notification arrives, or the deadline passes; the last answer wins. For hosts whose first reading
    /// lands a moment after start.
    static func rpcPoll(_ argv: [String], binary: String, initialize: [String: Any], notify: String?,
                        method: String, ready: ([String: Any]) -> Bool, changed: String?,
                        timeout: TimeInterval, extraEnv: [String: String]) -> RPCResult {
        guard let c = Child(argv, env: env(for: binary).merging(extraEnv) { $1 }) else { return .failed("could not start") }
        defer { c.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        func send(_ o: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
            c.write(String(decoding: d, as: UTF8.self) + "\n")
        }
        var pushed: [String: Any]?
        /// Lines until the answer to `id` (returned) or `until`; notes a `changed` push on the way.
        func listen(_ id: Int?, until: Date) -> [String: Any]? {
            while let line = c.readLine(until: min(until, deadline)) {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let m = changed, (o["method"] as? String) == m, let p = o["params"] as? [String: Any] { pushed = p }
                if let id = id, (o["id"] as? Int) == id { return o }
            }
            return nil
        }
        func failure(_ o: [String: Any]?) -> String {
            ((o?["error"] as? [String: Any])?["message"] as? String) ?? (Date() >= deadline ? "timed out" : "no answer")
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": initialize])
        let i = listen(1, until: deadline)
        guard i?["result"] != nil else { return .failed(failure(i)) }
        if let n = notify { send(["jsonrpc": "2.0", "method": n, "params": [String: Any]()]) }
        var last: [String: Any]?
        var id = 2
        while Date() < deadline {
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": [String: Any]()])
            let r = listen(id, until: Date().addingTimeInterval(5))
            if let p = pushed { return .ok(["usage": p]) }
            guard let res = r?["result"] as? [String: Any] else { return last.map { .ok($0) } ?? .failed(failure(r)) }
            last = res
            if ready(res) { return .ok(res) }
            id += 1
            _ = listen(nil, until: Date().addingTimeInterval(1))      // pace the next ask, but hear a push
            if let p = pushed { return .ok(["usage": p]) }
        }
        return last.map { .ok($0) } ?? .failed("timed out")
    }
}

// MARK: - usage-meter collector (opt-in): keeps the agents' usage.json fresh once SwiftBar is gone.

/// Runs `Resources/usage-meter-refresh.py` (bundled, so the app's signature covers it) with the system
/// Python every 5 minutes, but only after `defaults write io.github.dancik.limitbar usageMeterCollector
/// /abs/path/to/usage-meter/collect.py`. Fresh snapshots are skipped and helper runs share a lock. The
/// legacy SwiftBar plugin shares neither guard: disable it and drain its collection BEFORE enabling this.
/// This is not
/// sandboxed: the collector is the user's own code and needs the network, its sign-ins and the Cursor store.
enum Collector {
    struct Result: Equatable { let at: Date; let status: String }

    static var collectPath: String? {
        guard let p = UserDefaults.standard.string(forKey: "usageMeterCollector"), p.hasPrefix("/") else { return nil }
        return p
    }
    static let interval: TimeInterval = 5 * 60

    /// Status words the helper prints; anything else is reported as "failed".
    static let known: Set<String> = ["refreshed", "fresh-skip", "locked-skip", "untrusted", "import-failed",
                                     "collect-failed", "write-failed"]

    static func run() -> Result {
        guard let collect = collectPath else { return Result(at: Date(), status: "off") }
        guard let helper = Bundle.main.url(forResource: "usage-meter-refresh", withExtension: "py")?.path else {
            return Result(at: Date(), status: "helper-missing")
        }
        let python = UserDefaults.standard.string(forKey: "usageMeterPython") ?? "/usr/bin/python3"
        guard python.hasPrefix("/"), CLI.trusted(python), isReadableData(collect) else {
            return Result(at: Date(), status: "untrusted")
        }
        guard let out = CLI.run(python, ["-I", "-B", helper, "--collector", collect, "--min-age", "240",
                                         "--lock", "\(Paths.cache)/usage-meter.lock"], timeout: 120)
        else { return Result(at: Date(), status: "timed-out") }
        let word = (Fetch.json(out.data)?["status"] as? String) ?? ""
        return Result(at: Date(), status: known.contains(word) ? word : "failed")
    }

    /// collect.py is mode 0755 in usage-meter, but it only has to be a file nobody else can change.
    private static func isReadableData(_ p: String) -> Bool {
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              (st.st_mode & (S_IWGRP | S_IWOTH)) == 0, !CLI.aclGrantsWrite(p) else { return false }
        return CLI.safeChain((p as NSString).deletingLastPathComponent)
    }
}
