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
func traySnapshot(_ used: Double?) -> Snapshot {
    let window = Window(label: "5-hour", short: "5h", used: used, resetsAt: now.addingTimeInterval(3600))
    return Snapshot(vendor: .codex, bar: window, windows: [window], measuredAt: now)
}
for (used, expected) in [(0.0, TrayStatus.goodToGo), (20.0, .goodToGo), (80.0, .goodToGo), (80.001, .gettingClose), (90.0, .gettingClose), (98.999, .gettingClose), (99.0, .nearlyExhausted), (99.6, .nearlyExhausted), (100.0, .nearlyExhausted)] {
    check("tray \(used)%: \(expected)", traySnapshot(used).trayStatus(at: now) == expected)
}
for used: Double? in [nil, -1, 100.1, .nan, .infinity] {
    check("tray invalid quota stays unknown", traySnapshot(used).trayStatus(at: now) == .unknown)
}
for state in [VendorState.missing, .untrusted, .signedOut, .failed, .permissionNeeded, .setup] {
    var s = traySnapshot(100); s.state = state
    check("tray \(state): retained exhaustion stays unknown", s.trayStatus(at: now) == .unknown)
}
var tray = traySnapshot(100)
tray.bar?.resetsAt = now
check("tray at reset: no exhaustion claim", tray.trayStatus(at: now) == .unknown)
tray.bar?.resetsAt = now.addingTimeInterval(-1)
check("tray after reset: no exhaustion claim", tray.trayStatus(at: now) == .unknown)
tray = traySnapshot(100); tray.measuredAt = now.addingTimeInterval(-2700)
check("tray at freshness boundary: still current", tray.trayStatus(at: now) == .nearlyExhausted)
tray.measuredAt = now.addingTimeInterval(-2701)
check("tray stale exhaustion stays unknown", tray.trayStatus(at: now) == .unknown)
tray.measuredAt = nil
check("tray missing observation stays unknown", tray.trayStatus(at: now) == .unknown)
tray.measuredAt = now.addingTimeInterval(1)
check("tray future observation stays unknown", tray.trayStatus(at: now) == .unknown)
tray = traySnapshot(100); tray.bar = nil
check("tray missing window stays unknown", tray.trayStatus(at: now) == .unknown)
tray = traySnapshot(100); tray.error = "Couldn't read — showing last known values"
check("tray failed refresh with retained values stays unknown", tray.trayStatus(at: now) == .unknown)
tray = traySnapshot(20); tray.bar?.resetsAt = nil
check("tray known quota without reset is usable", tray.trayStatus(at: now) == .goodToGo)
check("numeric panel detail preserved", percentText(19.4) == "19" && percentText(99.6) == "99" && percentText(100) == "100")

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

func geminiJSON(_ groups: [[String: Any]]) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["command": ["data": ["groups": groups]]])) ?? Data()
}
let resetFormatter = ISO8601DateFormatter()
let fiveReset = resetFormatter.string(from: now.addingTimeInterval(4 * 3600))
let weekReset = resetFormatter.string(from: now.addingTimeInterval(5 * 86400))
let otherWeekReset = resetFormatter.string(from: now.addingTimeInterval(6 * 86400))
let argonReset = resetFormatter.string(from: now.addingTimeInterval(3 * 86400))
for (remaining, expected) in [(0.8, TrayStatus.goodToGo), (0.2, .goodToGo), (0.19999, .gettingClose),
                              (0.01001, .gettingClose), (0.01, .nearlyExhausted), (0.0, .nearlyExhausted)] {
    let parsed = Fetch.geminiParse(geminiJSON([
        ["name": "Gemini Models", "buckets": [
            ["window": "5h", "remaining_fraction": remaining, "reset_time": fiveReset],
        ]],
    ]), now: now)
    check("tray parser-derived \(remaining) remaining: \(expected)", parsed.trayStatus(at: now) == expected)
}
let fiveBuckets = Fetch.geminiParse(geminiJSON([
    ["name": "Gemini Models", "buckets": [
        ["window": "weekly", "remaining_fraction": 0.99, "reset_time": weekReset],
        ["window": "5h", "remaining_fraction": 1, "reset_time": fiveReset],
    ]],
    ["name": "Claude and GPT models", "buckets": [
        ["window": "weekly", "remaining_fraction": 1, "reset_time": otherWeekReset],
        ["window": "5h", "remaining_fraction": 1, "reset_time": fiveReset],
    ]],
    ["name": "Gemini 4 Argon", "buckets": [
        ["window": "weekly", "remaining_fraction": 0.72, "reset_time": argonReset],
    ]],
]), now: now)
check("gemini 5-bucket CLI shape: state ok and all 5 windows included",
      fiveBuckets.state == .ok && fiveBuckets.windows.count == 5 &&
      fiveBuckets.windows.map { "\($0.label):\($0.short):\(percentText($0.used))" } == [
          "Gemini Models:5h:0",
          "Gemini Models:w:1",
          "Claude and GPT models:5h:0",
          "Claude and GPT models:w:0",
          "Gemini 4 Argon:w:28",
      ])
check("gemini 5-bucket CLI shape: bar selects most-used Gemini bucket and keeps resets",
      fiveBuckets.bar?.label == "Gemini 4 Argon" && fiveBuckets.bar?.short == "w" &&
      percentText(fiveBuckets.bar?.used) == "28" && !fiveBuckets.otherHot &&
      fiveBuckets.windows.allSatisfy { $0.resetsAt != nil })

let nonzeroOther = Fetch.geminiParse(geminiJSON([
    ["name": "Gemini Models", "buckets": [
        ["window": "weekly", "remaining_fraction": 0.99, "reset_time": weekReset],
        ["window": "5h", "remaining_fraction": 0.85, "reset_time": fiveReset],
    ]],
    ["name": "Claude and GPT models", "buckets": [
        ["window": "weekly", "remaining_fraction": 0.20, "reset_time": otherWeekReset],
        ["window": "5h", "remaining_fraction": 0.05, "reset_time": fiveReset],
    ]],
    ["name": "Gemini 4 Argon", "buckets": [
        ["window": "weekly", "remaining_fraction": 0.72, "reset_time": argonReset],
    ]],
]), now: now)
check("gemini nonzero non-Gemini usage: menu bar stays on most-used Gemini group while flagging hot other",
      nonzeroOther.bar?.label == "Gemini 4 Argon" && percentText(nonzeroOther.bar?.used) == "28" &&
      nonzeroOther.otherHot &&
      nonzeroOther.windows.map { "\($0.label):\($0.short):\(percentText($0.used))" } == [
          "Gemini Models:5h:15",
          "Gemini Models:w:1",
          "Claude and GPT models:5h:95",
          "Claude and GPT models:w:80",
          "Gemini 4 Argon:w:28",
      ])

let filteredInvalid = Fetch.geminiParse(geminiJSON([
    ["name": "Gemini Models", "buckets": [
        ["window": "weekly", "remaining_fraction": 0.75, "reset_time": "9999-01-01T00:00:00Z"],
        ["window": "5h", "remaining_fraction": true, "reset_time": fiveReset],
        ["window": "5h", "remaining_fraction": -0.1, "reset_time": fiveReset],
        ["window": "5h", "remaining_fraction": 1.1, "reset_time": fiveReset],
        ["window": "5h", "remaining_fraction": "0.5", "reset_time": fiveReset],
        ["window": "5h", "remaining_fraction": NSNull(), "reset_time": fiveReset],
    ]],
    ["name": "Claude and GPT models", "buckets": [
        ["window": "weekly", "remaining_fraction": 1, "reset_time": otherWeekReset],
        ["window": "5h", "remaining_fraction": -1, "reset_time": fiveReset],
    ]],
]), now: now)
check("gemini invalid buckets skipped and bad reset date omitted",
      filteredInvalid.state == .ok &&
      filteredInvalid.windows.map { "\($0.label):\($0.short):\(percentText($0.used))" } == [
          "Gemini Models:w:25",
          "Claude and GPT models:w:0",
      ] && filteredInvalid.windows[0].resetsAt == nil && filteredInvalid.windows[1].resetsAt != nil)

let noValidGemini = Fetch.geminiParse(geminiJSON([
    ["name": "Gemini Models", "buckets": [["window": "weekly", "remaining_fraction": "bad"]]],
    ["name": "Claude and GPT models", "buckets": [["window": "weekly", "remaining_fraction": 1]]],
]), now: now)
check("gemini fails when no valid Gemini bucket exists", noValidGemini.state == .failed && noValidGemini.windows.isEmpty)

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

let fakeACL = OpaquePointer(bitPattern: 0x1)!
let fakeEntry = OpaquePointer(bitPattern: 0x2)!
let fakePerms = OpaquePointer(bitPattern: 0x3)!
check("Swift ACL NULL + ENOENT is normal no-ACL", !CLI.aclGrantsWrite(
    "/synthetic", getACL: { _ in errno = ENOENT; return nil }, freeACL: { _ in 0 },
    getEntry: { _, _, _ in -1 }, getTag: { _, _ in 0 }, getPermset: { _, _ in 0 }, getPerm: { _, _ in 0 }))
check("Swift ACL NULL + EACCES fails closed", CLI.aclGrantsWrite(
    "/synthetic", getACL: { _ in errno = EACCES; return nil }, freeACL: { _ in 0 },
    getEntry: { _, _, _ in -1 }, getTag: { _, _ in 0 }, getPermset: { _, _ in 0 }, getPerm: { _, _ in 0 }))
var seenEntries = 0
check("Swift ACL read-only entry + normal EINVAL end is allowed", !CLI.aclGrantsWrite(
    "/synthetic", getACL: { _ in fakeACL }, freeACL: { _ in 0 },
    getEntry: { _, which, out in
        if which == ACL_FIRST_ENTRY.rawValue { seenEntries += 1; out.pointee = fakeEntry; return 0 }
        errno = EINVAL; return -1
    },
    getTag: { _, tag in tag.pointee = ACL_EXTENDED_ALLOW; return 0 },
    getPermset: { _, perms in perms.pointee = fakePerms; return 0 },
    getPerm: { _, _ in 0 }) && seenEntries == 1)
check("Swift ACL iteration error (EIO) fails closed", CLI.aclGrantsWrite(
    "/synthetic", getACL: { _ in fakeACL }, freeACL: { _ in 0 },
    getEntry: { _, _, _ in errno = EIO; return -1 },
    getTag: { _, _ in 0 }, getPermset: { _, _ in 0 }, getPerm: { _, _ in 0 }))
check("Swift ACL tag inspection error fails closed", CLI.aclGrantsWrite(
    "/synthetic", getACL: { _ in fakeACL }, freeACL: { _ in 0 },
    getEntry: { _, which, out in
        if which == ACL_FIRST_ENTRY.rawValue { out.pointee = fakeEntry; return 0 }
        errno = EINVAL; return -1
    },
    getTag: { _, _ in errno = EINVAL; return -1 },
    getPermset: { _, _ in 0 }, getPerm: { _, _ in 0 }))
check("Swift ACL perm inspection error (-1) fails closed", CLI.aclGrantsWrite(
    "/synthetic", getACL: { _ in fakeACL }, freeACL: { _ in 0 },
    getEntry: { _, which, out in
        if which == ACL_FIRST_ENTRY.rawValue { out.pointee = fakeEntry; return 0 }
        errno = EINVAL; return -1
    },
    getTag: { _, tag in tag.pointee = ACL_EXTENDED_ALLOW; return 0 },
    getPermset: { _, perms in perms.pointee = fakePerms; return 0 },
    getPerm: { _, _ in errno = EINVAL; return -1 }))
print(failures == 0 ? "PASS: Swift fixes" : "Swift fixes FAILED")
exit(failures == 0 ? 0 : 1)
