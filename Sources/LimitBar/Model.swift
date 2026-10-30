import Foundation

enum Vendor: String, CaseIterable, Codable {
    case claude, gemini, codex, cursor, muse

    // Approved application sources. Muse stays compiled for isolated diagnostics only.
    static let activeVendors: [Vendor] = [.claude, .gemini, .codex, .cursor]

    var name: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .muse: "Muse"
        }
    }
    /// The CLI limitbar asks, and what the panel suggests when it is missing or signed out. Cursor has no CLI
    /// here: its numbers come from the local usage-meter snapshot (Fetch.cursor).
    var cli: String {
        switch self {
        case .claude: "claude"
        case .gemini: "agy"
        case .codex: "codex"
        case .cursor: "usage-meter"
        case .muse: "muse"
        }
    }
    var product: String {
        switch self {
        case .claude: "Claude Code"
        case .gemini: "Google Antigravity CLI"
        case .codex: "Codex CLI"
        case .cursor: "Cursor usage meter"
        case .muse: "Muse Code"
        }
    }
    var loginHint: String {
        switch self {
        case .claude: "run `claude`, then /login"
        case .gemini: "run `agy` once and sign in"
        case .codex: "run `codex login`"
        case .cursor: "run usage-meter's bin/setup-cursor-session"
        case .muse: "run `muse login`"
        }
    }
    var mark: String {
        switch self {
        case .claude: "claude"
        case .gemini: "gemini"
        case .codex: "openai"
        case .cursor: "cursor"
        case .muse: "meta"
        }
    }
}

/// Why a vendor shows no numbers. `ok` = the CLI answered.
enum VendorState: String, Codable {
    case ok
    case missing        // CLI not found: hidden from the menu bar, listed in the panel
    case untrusted      // found, but owned by another account or group/world-writable: never run
    case signedOut      // the CLI says nobody is signed in
    case failed         // it ran and did not give limits (timeout, error, changed format)
    case permissionNeeded // native Muse needs an explicit Connect action
    case setup          // signed in, but its quota source is off until you turn it on (see README)
}

/// One limit window as the vendor reports it. `used` is percent USED, 0–100.
struct Window: Codable, Equatable {
    var label: String            // "5-hour", "Week", "Weekly credits", …
    var short: String            // window kind, e.g. "5h" or "w"
    var used: Double?
    var resetsAt: Date?

    /// The reset time has passed since we read it: the old percent is obsolete, not "0 %".
    var resetPassed: Bool { (resetsAt.map { $0 < Date() }) ?? false }
}

enum TrayStatus: String {
    case gettingClose, goodToGo, nearlyExhausted, unknown
}

struct Snapshot: Codable, Equatable {
    var vendor: Vendor
    var state: VendorState = .ok
    var plan: String = ""         // from the CLI's own answer: "Max", "ChatGPT Plus", "X Premium+"
    var bar: Window?              // the window the menu bar shows for this vendor
    var windows: [Window] = []    // everything shown in the panel, bar window first
    var notes: [String] = []      // e.g. "2 free full resets · next expires Fri 3 Jan"
    var measuredAt: Date?         // when the vendor's numbers were taken (not when we looked)
    var error: String?            // last failure, shown dimmed; previous numbers are kept

    /// Whether another current window of this vendor is at least 90 % used.
    var otherHot: Bool {
        windows.contains { $0 != bar && !$0.resetPassed && ($0.used ?? 0) >= 90 }
    }

    /// Only a current, usable reading can claim a quota state. Keep exact percentages in the panel.
    func trayStatus(at now: Date = Date()) -> TrayStatus {
        guard state == .ok, error == nil, let measuredAt,
              (0...45 * 60).contains(now.timeIntervalSince(measuredAt)),
              let bar, bar.resetsAt.map({ $0 > now }) ?? true,
              let used = bar.used, used.isFinite, (0...100).contains(used) else { return .unknown }
        if used >= 99 { return .nearlyExhausted }
        return used > 80 ? .gettingClose : .goodToGo
    }

    static func status(_ v: Vendor, _ state: VendorState, _ error: String? = nil) -> Snapshot {
        Snapshot(vendor: v, state: state, error: error)
    }
}

/// A plain JSON number: booleans (which JSONSerialization also hands over as NSNumber) are not numbers.
func number(_ any: Any?) -> Double? {
    guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return n.doubleValue
}

/// A percentage from a CLI is only used when it is a finite number in 0…100.
func percent(_ any: Any?) -> Double? {
    guard let x = number(any), x.isFinite, x >= 0, x <= 100 else { return nil }
    return x
}

/// A percentage that may honestly exceed 100 (Muse reports over-quota use; Cursor's usage meter passes on
/// what Cursor says). Over 100 shows as 100 and is flagged; anything else out of range is unknown.
func overPercent(_ any: Any?) -> (used: Double, over: Bool)? {
    guard let x = number(any), x.isFinite, x >= 0, x <= 1000 else { return nil }
    return (min(x, 100), x > 100)
}

/// Numeric detail: rounded, but 99.6 % must never read as 100 %.
func percentText(_ v: Double?) -> String {
    guard let v = v else { return "—" }
    let r = v.rounded()
    return String(Int(r >= 100 && v < 100 ? 99 : r))
}
