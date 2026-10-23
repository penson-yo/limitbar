// Compiled against actual sources by fixes.py. Store/Paths access exists only in disposable copies.
import Foundation

var failures = 0
func check(_ name: String, _ value: @autoclosure () -> Bool) {
    let ok = value()
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

if CommandLine.arguments[1] == "trust" {
    print(Collector.fixtureTrusted(CommandLine.arguments[2]) ? "trusted" : "untrusted")
    exit(0)
}

let root = CommandLine.arguments[1]
let now = Date()
let usage: [String: Any] = ["observedAtMs": now.timeIntervalSince1970 * 1000,
                            "window": ["usedPercent": 37, "windowDurationMins": 300]]
func reading(_ duration: Any) -> Snapshot {
    var u = usage
    u["window"] = ["usedPercent": 37, "windowDurationMins": duration]
    return Fetch.museParse(u, now: now)
}
for (name, duration) in [("huge finite", 1e308), ("Int upper boundary", Double(Int.max)),
                         ("Int lower boundary", Double(Int.min)), ("negative", -1),
                         ("zero", 0), ("above week", 10_080.0001)] {
    let s = reading(duration)
    check("muse duration \(name): generic label, original quota", s.windows.first?.label == "Window" && s.bar?.used == 37)
}
for (duration, label, short) in [(0.5, "0.5-minute", "0.5m"), (30.25, "30.25-minute", "30.25m"),
                                (60, "1-hour", "1h"), (300, "5-hour", "5h"), (10_080, "168-hour", "168h")] {
    let s = reading(duration)
    check("muse duration \(duration): precise bounded label", s.windows.first?.label == label && s.windows.first?.short == short)
}
check("muse duration one second supported", reading(1.0 / 60).windows.first?.label != "Window")
check("muse duration boolean stays generic", reading(true).windows.first?.label == "Window")
check("muse duration string stays generic", reading("300").windows.first?.label == "Window")

check("dates reject huge finite, Int bounds and nonfinite", [1e308, Double(Int.max), Double(Int.min), .infinity, .nan].allSatisfy { Fetch.date($0) == nil })
check("dates enforce UTC 2000..2100 endpoints", Fetch.date(946_684_800) != nil && Fetch.date(946_684_799) == nil && Fetch.date(4_102_444_799) != nil && Fetch.date(4_102_444_800) == nil)
check("dates reject out-of-range ISO strings and booleans", Fetch.date("9999-01-01T00:00:00Z") == nil && Fetch.date("1999-12-31T23:59:59Z") == nil && Fetch.date(true) == nil)
var resetUsage = usage
resetUsage["window"] = ["usedPercent": 37, "resetsAtMs": 1e308]
resetUsage["weekly"] = ["usedPercent": NSNull(), "resetsAtMs": 4_102_444_800_000.0]
let reset = Fetch.museParse(resetUsage, now: now)
check("muse invalid reset dates omitted; unknown quota stays unknown", reset.windows.allSatisfy { $0.resetsAt == nil } && reset.windows[1].used == nil)
check("muse oversized observation rejected", Fetch.museParse(["observedAtMs": 1e308], now: now).state == .failed)

let store = Store(preview: [:])
let valid = Snapshot(vendor: .claude, windows: [Window(label: "Week", short: "w", used: 42)], measuredAt: now)
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let good = try JSONSerialization.jsonObject(with: encoder.encode(valid))
// Recognized bad entries are loaded beside one valid vendor and an obsolete Grok entry.
for (name, bad) in [("null", NSNull() as Any), ("string", "bad" as Any), ("number", 42 as Any),
                    ("boolean", true as Any), ("array", [] as Any)] {
    let data = try JSONSerialization.data(withJSONObject: ["claude": good, "cursor": bad, "grok": good])
    try data.write(to: URL(fileURLWithPath: "\(Paths.cache)/state.json"))
    let isolated = Store(preview: [:]); isolated.fixtureLoadCache()
    check("actual Store cache skips \(name) and Grok; valid vendor preserved", isolated.snaps.count == 1 && isolated.snaps[.claude]?.windows.first?.used == 42)
}

check("muse first poll eligible", store.fixturePoll(age: nil, force: true, olderThan: nil))
for (path, force, older, state, resetPassed) in [
    ("hover", false, 90.0 as Double?, VendorState.ok, false),
    ("force/panel", true, nil, .ok, false), ("wake", true, nil, .failed, false),
    ("passed reset", false, nil, .ok, true), ("activity/timer", false, nil, .ok, false),
    ("setup", true, nil, .setup, false), ("missing", true, nil, .missing, false)] {
    check("muse \(path): no poll before hard floor", !store.fixturePoll(age: 1799, force: force, olderThan: older, state: state, resetPassed: resetPassed))
    check("muse \(path): eligible after hard floor", store.fixturePoll(age: 1801, force: force, olderThan: older, state: state, resetPassed: resetPassed))
}
check("muse exact floor eligible", store.fixturePoll(age: 1800, force: true, olderThan: 0))
check("muse in-flight prevents duplicate", !store.fixturePoll(age: 1801, force: true, olderThan: nil, isBusy: true))
check("muse monotonic future completion refuses override", !store.fixturePoll(age: -10, force: true, olderThan: 0))
check("collector captured note survives main status replacement", store.fixtureCapturedNote())
print(failures == 0 ? "PASS: Swift fixes" : "Swift fixes FAILED")
exit(failures == 0 ? 0 : 1)
