import AppKit
import Foundation

let args = CommandLine.arguments

// `LimitBar --probe` asks each active source once and prints what limitbar would show, as JSON:
// state (ok / missing / untrusted / signedOut / failed), plan, windows. Nothing else of the account.
if args.contains("--probe") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    var all: [String: Snapshot] = [:]
    // Parked host fixtures require explicit overrides for every source; never native credentials.
    let diagnostic = args.contains("--muse-host-diagnostic") &&
        ["-claudePath", "-agyPath", "-codexPath", "-cursorUsagePath", "-musePath"].allSatisfy { args.contains($0) }
    for v in diagnostic ? Vendor.allCases : Vendor.activeVendors {
        switch v {
        case .claude:
            var s: Snapshot
            let (bin, why) = Fetch.binary(.claude)
            if bin == nil { s = why! }
            else if let acct = Fetch.claudeAccount(), !acct.signedIn { s = .status(.claude, .signedOut) }
            else { s = Fetch.claudeFile() ?? Fetch.claudeUsage(); s.plan = Fetch.claudeAccount()?.plan ?? s.plan }
            all[v.rawValue] = s
        case .gemini: all[v.rawValue] = Fetch.gemini()
        case .codex: all[v.rawValue] = Fetch.codexFromServer()
        case .cursor: all[v.rawValue] = Fetch.cursor()
        case .muse:
            // Explicit diagnostic with an explicit trusted binary only; default probe never reads Muse secrets/HTTP.
            all[v.rawValue] = args.contains("--muse-host-diagnostic") && args.contains("-musePath")
                ? Fetch.museHost() : Fetch.muse()
        }
    }
    print(String(decoding: (try? enc.encode(all)) ?? Data(), as: UTF8.self))
    exit(0)
}

// `LimitBar --statusline` — optional Claude Code status line (see README). Claude Code pipes a JSON blob
// with the current rate limits to it on every refresh; we keep only the limits, in
// ~/Library/Caches/limitbar/claude-status.json, and print one short line, e.g. "5h 23% · 7d 41%".
// The menu bar then reads Claude's numbers for free instead of running `claude -p /usage`.
if args.contains("--statusline") {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let blob = Fetch.json(input) ?? [:]
    let rl = (blob["rate_limits"] ?? blob["rateLimits"]) as? [String: Any] ?? [:]
    var limits: [String: Any] = [:]
    for (kind, value) in rl {
        guard let w = value as? [String: Any] else { continue }
        var pct = ["used_percentage", "used_percent", "percentUsed", "percent", "utilization"].lazy
            .compactMap { number(w[$0]) }.first
        if let p = pct, p <= 1, w["utilization"] != nil { pct = p * 100 }
        guard let p = percent(pct) else { continue }
        limits[kind] = ["percent": p, "resets_at": w["resets_at"] ?? w["resetsAt"] ?? w["reset_at"] ?? NSNull()]
    }
    if !limits.isEmpty,   // only a refresh that carries limits replaces the last good file
       let d = try? JSONSerialization.data(withJSONObject: ["at": Date().timeIntervalSince1970, "limits": limits]) {
        Paths.write(d, to: Fetch.claudeFilePath)
    }
    let parts = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { k, label -> String? in
        guard let p = (limits[k] as? [String: Any])?["percent"] as? Double else { return nil }
        return "\(label) \(percentText(p))%"
    }
    let model = ((blob["model"] as? [String: Any])?["display_name"] as? String) ?? "Claude"
    print(([model] + parts).joined(separator: " · "))
    exit(0)
}

// `LimitBar --render-preview <snapshots.json> <out.png> [--dark]` draws the menu-bar item and the panel for
// the given snapshots (the --probe format) into a PNG, offscreen: no status item, no fetch, no cache. A
// check of layout and wording only — the real panel's glass and the menu bar itself are not in the picture.
if let i = args.firstIndex(of: "--render-preview"), i + 2 < args.count {
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    guard let d = FileManager.default.contents(atPath: args[i + 1]),
          let all = try? dec.decode([String: Snapshot].self, from: d) else { print("unreadable snapshots"); exit(1) }
    var snaps: [Vendor: Snapshot] = [:]
    for (k, v) in all { if let vendor = Vendor(rawValue: k) { snaps[vendor] = v } }
    let ok = MainActor.assumeIsolated { renderPreview(snaps, to: args[i + 2], dark: args.contains("--dark")) }
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
