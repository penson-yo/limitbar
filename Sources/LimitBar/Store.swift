import AppKit
import Combine
import Foundation

/// Keeps one Snapshot per vendor fresh at the lowest cost:
/// - one CLI at a time on a serial queue, hard 20–40 s deadlines, whole process group killed;
/// - a source is re-polled only when its own activity files moved since the last poll (or its reset time
///   passed), plus a slow safety interval; hovering refreshes anything older than 90 s except Muse;
/// - Claude reads the opt-in statusline file for free and runs `claude -p /usage` at most every 20 min
///   when that file is missing or stale;
/// - Cursor is the usage-meter snapshot (a file read), re-read when it moves; with `usageMeterCollector` set,
///   the collector itself is run every 5 min on its own queue so it never holds up the CLIs;
/// - Muse uses the native quota API only after Connect succeeds: at least 30 min after completion;
///   hover, force, wake, reset and activity never shorten that floor;
/// - paused while the Mac sleeps, refreshed on wake; last good values cached on disk, never shown as 0.
final class Store: ObservableObject {
    @Published private(set) var snaps: [Vendor: Snapshot] = [:]
    @Published private(set) var busy: Set<Vendor> = []

    private let queue = DispatchQueue(label: "limitbar.fetch", qos: .utility)
    private var timer: Timer?
    private var asleep = false
    private var lastPoll: [Vendor: Date] = [:]
    // Monotonic completion time: wall-clock changes cannot shorten Muse's start budget in this process.
    private var lastMuseCompletion: TimeInterval?
    private let museInterval: TimeInterval = 30 * 60
    enum MuseSource { case off, direct }
    private var museSource: MuseSource = .off
    private var museClient = MuseNative.Client()
    private var museActionsAllowed = false // offscreen preview cannot connect
    private var museConnectAttempted = false
    private var persistMuse: (Bool) -> Void = { UserDefaults.standard.set($0, forKey: "museDirectQuota") }

    /// The only UI path allowed to request Keychain interaction. No force-refresh path calls this.
    func connectMuse() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Vendor.activeVendors.contains(.muse), museActionsAllowed, !asleep, !busy.contains(.muse),
              snaps[.muse]?.state == .setup || snaps[.muse]?.state == .permissionNeeded else { return }
        if museConnectAttempted || museSource == .direct {
            guard lastMuseCompletion.map({ ProcessInfo.processInfo.systemUptime - $0 >= museInterval }) ?? true else {
                snaps[.muse]?.error = "Muse can be checked again 30 minutes after the last attempt."
                return
            }
        }
        museConnectAttempted = true
        busy.insert(.muse)
        let client = museClient
        queue.async { [weak self] in
            let result = client.read(.connect)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy.remove(.muse)
                self.lastPoll[.muse] = Date()
                self.lastMuseCompletion = ProcessInfo.processInfo.systemUptime
                self.museSource = result.activeLogin ? .direct : .off
                self.persistMuse(result.activeLogin)
                var snapshot = result.snapshot
                if !result.activeLogin, snapshot.state == .failed { snapshot.state = .setup }
                self.apply(.muse, snapshot)
            }
        }
    }
    private var lastActivity: [Vendor: Date] = [:]
    private var lastClaudeUsage = Date.distantPast
    private var lastAccountCheck = Date.distantPast
    private var lastCodexServer = Date.distantPast
    private var claudeAccount: (signedIn: Bool, plan: String)?
    private let collectorQueue = DispatchQueue(label: "limitbar.collector", qos: .utility)
    private var collectorBusy = false
    private var lastCollector: Collector.Result?

    private var cacheFile: String { "\(Paths.cache)/state.json" }
    private let home = CLI.home

    /// Slow safety net per source even when nothing moved (another machine may spend the same quota).
    private let idleInterval: [Vendor: TimeInterval] = [.claude: 20 * 60, .gemini: 30 * 60, .codex: 30 * 60,
                                                        .cursor: 60, .muse: 30 * 60]
    /// Minimum gap between polls when activity moved.
    private let busyInterval: [Vendor: TimeInterval] = [.claude: 60, .gemini: 5 * 60, .codex: 60, .cursor: 30, .muse: 30 * 60]
    /// A missing CLI is looked for again this often (it may have just been installed).
    private let missingInterval: TimeInterval = 5 * 60

    /// Vendors the menu bar shows: everything whose CLI exists. Missing ones are listed in the panel only.
    var installed: [Vendor] {
        Vendor.activeVendors.filter { v in
            guard let s = snaps[v] else { return true }
            return s.state != .missing
        }
    }

    /// Fixed snapshots, no timers, no fetches, no cache: for `LimitBar --render-preview` only.
    init(preview: [Vendor: Snapshot]) { snaps = preview.filter { Vendor.activeVendors.contains($0.key) } }

    init() {
        if Vendor.activeVendors.contains(.muse) {
            museActionsAllowed = true
            museSource = UserDefaults.standard.bool(forKey: "museDirectQuota") ? .direct : .off
        }
        loadCache()
        if Vendor.activeVendors.contains(.muse), museSource == .off { snaps[.muse] = MuseNative.setup }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = true }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false; self?.refresh(force: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
        refresh(force: true)
    }

    /// Called by the timer (every 30 s, cheap checks only), on wake, on hover and from the panel.
    func refresh(force: Bool = false, olderThan: TimeInterval? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !asleep else { return }
        for v in Vendor.activeVendors where shouldPoll(v, force: force, olderThan: olderThan) {
            schedule(v, force: force)
        }
        runCollectorIfDue()
    }

    /// The opt-in usage-meter collector (Collector): at most every 5 min, never two at once; Cursor is
    /// re-read as soon as it finishes.
    private func runCollectorIfDue() {
        guard Collector.collectPath != nil, !collectorBusy,
              Date().timeIntervalSince(lastCollector?.at ?? .distantPast) > Collector.interval else { return }
        collectorBusy = true
        collectorQueue.async { [weak self] in
            let r = Collector.run()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.collectorBusy = false
                self.lastCollector = r
                if !self.busy.contains(.cursor) { self.schedule(.cursor, force: true) }
            }
        }
    }

    private func shouldPoll(_ v: Vendor, force: Bool, olderThan: TimeInterval?) -> Bool {
        guard Vendor.activeVendors.contains(v), !busy.contains(v) else { return false }
        // Before EVERY generic override. Missing/setup/failed reads also observe this floor; no manual
        // override. First poll in a new app process is eligible, and remains off unless explicitly enabled.
        if v == .muse {
            if museSource == .off, snaps[.muse] != nil { return false }
            return lastMuseCompletion.map { ProcessInfo.processInfo.systemUptime - $0 >= museInterval } ?? true
        }
        let last = lastPoll[v] ?? .distantPast
        let age = Date().timeIntervalSince(last)
        if force { return true }
        if let s = snaps[v], s.state == .missing || s.state == .untrusted || s.state == .setup { return age > missingInterval }
        if v == .claude { return age > 30 }      // the file read is free; the expensive part is gated inside
        if let o = olderThan { return age > o }
        if let s = snaps[v], s.windows.contains(where: { $0.resetPassed }) { return age > 60 }
        let act = activity(v)
        if let a = act, a > (lastActivity[v] ?? .distantPast), age > busyInterval[v]! { return true }
        return age > idleInterval[v]!
    }

    /// Newest mtime among the files that move when this vendor's quota is being spent.
    private func activity(_ v: Vendor) -> Date? {
        let fm = FileManager.default
        var candidates: [String]
        switch v {
        case .claude: candidates = [Fetch.claudeFilePath]
        case .gemini: candidates = ["\(home)/.gemini/antigravity-cli/conversations"]
        case .codex:
            // ~/.codex/sessions/YYYY/MM/DD: today's directory moves on every new session
            let c = Calendar.current, d = Date(), root = "\(home)/.codex/sessions"
            candidates = [root, String(format: "%@/%04d/%02d/%02d", root, c.component(.year, from: d),
                                       c.component(.month, from: d), c.component(.day, from: d))]
        case .cursor:
            if case .ok(let p) = Fetch.cursorFile() { candidates = [p] } else { candidates = [] }
        case .muse:
            // ~/.local/share/muse/sessions/YYYY/MM: a new session folder moves this month's directory
            let c = Calendar.current, d = Date(), root = "\(home)/.local/share/muse/sessions"
            candidates = [root, String(format: "%@/%04d/%02d", root, c.component(.year, from: d), c.component(.month, from: d))]
        }
        return candidates.compactMap { Fetch.mtime($0) }.max()
    }

    private func schedule(_ v: Vendor, force: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Vendor.activeVendors.contains(v) else { return }
        busy.insert(v)
        let act = activity(v)
        let prev = snaps[v]                        // read on main; fetch runs on the queue
        let museEnabled = museSource == .direct
        let note = v == .cursor ? collectorNote : nil   // immutable main-queue capture
        queue.async { [weak self] in
            guard let self = self else { return }
            let s = self.fetch(v, prev: prev, force: force, collectorNote: note, museEnabled: museEnabled)
            DispatchQueue.main.async {
                self.busy.remove(v)
                self.lastPoll[v] = Date()
                if v == .muse { self.lastMuseCompletion = ProcessInfo.processInfo.systemUptime }
                if let a = act { self.lastActivity[v] = a }
                self.apply(v, s)
            }
        }
    }

    /// Runs on the serial queue.
    private func fetch(_ v: Vendor, prev: Snapshot?, force: Bool, collectorNote: String?, museEnabled: Bool = false) -> Snapshot {
        switch v {
        case .claude:
            if case .missing = CLI.find("claude") { return .status(.claude, .missing) }
            if case .untrusted = CLI.find("claude") { return .status(.claude, .untrusted, "claude could be replaced by another account — not run") }
            if force || Date().timeIntervalSince(lastAccountCheck) > 30 * 60 {
                lastAccountCheck = Date()
                claudeAccount = Fetch.claudeAccount() ?? claudeAccount
            }
            if claudeAccount?.signedIn == false { return .status(.claude, .signedOut) }
            var s = Fetch.claudeFile()
            let fileAge = s?.measuredAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if fileAge > 20 * 60, force || Date().timeIntervalSince(lastClaudeUsage) > 20 * 60 {
                lastClaudeUsage = Date()
                s = Fetch.claudeUsage()
            }
            guard var out = s else { return prev ?? .status(.claude, .failed, "waiting for claude") }
            out.plan = claudeAccount?.plan ?? out.plan
            return out
        case .gemini:
            return Fetch.gemini()
        case .codex:
            // Session logs are free and exact; the app-server adds the reset credits, covers idle hours and
            // tells a signed-out CLI apart.
            if case .ok = CLI.find("codex"), !force, let logs = Fetch.codexFromLogs(),
               let m = logs.measuredAt, Date().timeIntervalSince(m) < 10 * 60,
               Date().timeIntervalSince(lastCodexServer) < 30 * 60 {
                var s = logs
                s.notes = prev?.notes ?? []
                return s
            }
            lastCodexServer = Date()
            let s = Fetch.codexFromServer()
            if s.state == .failed, let logs = Fetch.codexFromLogs() { return logs }
            return s
        case .cursor:
            var s = Fetch.cursor()
            if let note = collectorNote { s.notes.append(note) }
            return s
        case .muse:
            return museEnabled ? museClient.read(.background).snapshot : Fetch.muse()
        }
    }

    /// One quiet line under Cursor while the collector is on. Access only on main at scheduling time;
    /// the fetch queue receives an immutable copy, never lastCollector or its stored String.
    private var collectorNote: String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Collector.collectPath != nil else { return nil }
        guard let r = lastCollector else { return "usage-meter refresh: starting" }
        switch r.status {
        case "refreshed", "fresh-skip", "locked-skip": return nil
        case "untrusted": return "usage-meter refresh: collector could be changed by another account — not run"
        default: return "usage-meter refresh failed (\(r.status))"
        }
    }

    private func apply(_ v: Vendor, _ s: Snapshot) {
        var s = s
        if s.state == .failed, var old = snaps[v], old.state == .ok, !old.windows.isEmpty {
            old.error = "Couldn't read — showing last known values" + (s.error.map { " (\($0))" } ?? "")   // our own fixed texts
            s = old
        }
        if v != .muse, s.plan.isEmpty, s.state == .ok { s.plan = snaps[v]?.plan ?? "" }
        snaps[v] = s
        saveCache()
    }

    // MARK: cache — percentages, reset times and plan names only

    private func loadCache() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        // One entry at a time: a vendor this build does not know (e.g. upstream's "grok") is skipped, not fatal.
        guard let raw = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        for (k, any) in raw {
            guard let vendor = Vendor(rawValue: k), Vendor.activeVendors.contains(vendor), let object = any as? [String: Any],
                  let one = try? JSONSerialization.data(withJSONObject: object),
                  let v = try? dec.decode(Snapshot.self, from: one), v.vendor == vendor, v.state == .ok else { continue }
            var safe = v
            if vendor == .muse { safe.plan = MuseNative.plan(v.plan) }
            snaps[vendor] = safe
        }
    }

    private func saveCache() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dict = Dictionary(uniqueKeysWithValues: snaps.map { ($0.key.rawValue, $0.value) })
        if let d = try? enc.encode(dict) { Paths.write(d, to: cacheFile) }
    }
}
