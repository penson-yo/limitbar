import Foundation
import Security
import LocalAuthentication

var checks = 0, failures = 0
func check(_ label: String, _ value: @autoclosure () -> Bool) {
    checks += 1
    let ok = value()
    if !ok { failures += 1 }
    print((ok ? "ok   " : "FAIL ") + label)
}
func failure(_ body: () throws -> Void) -> MuseNative.Failure? {
    do { try body(); return nil } catch let error as MuseNative.Failure { return error } catch { return nil }
}
let token = "dca:NATIVE_FAKE_TOKEN"
func data(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) }
let payload = data(["access_token": token, "ignored": "NATIVE_FAKE_KEY"])
var reads = 0
func kc() -> Data { reads += 1; return payload }
func auth(_ value: Any) -> Data { data(["providers": ["meta": ["access_token": value, "mechanism": "oauth"]]]) }
check("inline login precedence", (try? MuseNative.resolve(auth: auth(token), keychain: kc)) == token && reads == 0)
check("blank inline falls back", (try? MuseNative.resolve(auth: auth("  "), keychain: kc)) == token && reads == 1)
check("invalid auth JSON follows upstream fallback", (try? MuseNative.resolve(auth: Data("{".utf8), keychain: kc)) == token && reads == 2)
check("absent auth follows exact Keychain path", (try? MuseNative.resolve(auth: nil, keychain: kc)) == token && reads == 3)
let before = reads
check("bad nonblank inline never falls through", failure { _ = try MuseNative.resolve(auth: auth("LLM|NATIVE_FAKE_KEY"), keychain: kc) }?.kind == .unusableToken && reads == before)
check("malformed stored JSON is specific", failure { _ = try MuseNative.resolve(auth: nil) { Data("{".utf8) } }?.kind == .malformedJSON)
check("invalid stored type is specific", failure { _ = try MuseNative.resolve(auth: nil) { data(["access_token": true]) } }?.kind == .malformedJSON)
for raw in ["", "dca:", "LLM|NATIVE_FAKE_KEY", "dca:a\nb", "dca:é", String(repeating: "a", count: 70000)] {
    check("reject unusable token", failure { _ = try MuseNative.validate(raw) }?.kind == .unusableToken)
}
check("trim surrounding whitespace", (try? MuseNative.validate(" \n" + token + "\n ")) == token)
for (status, kind) in [(errSecInteractionNotAllowed, MuseNative.Kind.permissionNeeded), (errSecInteractionRequired, .permissionNeeded),
                       (errSecUserCanceled, .denied), (errSecAuthFailed, .denied), (errSecItemNotFound, .missingLogin),
                       (errSecNotAvailable, .keychainUnavailable), (OSStatus(-99999), .keychainUnavailable)] {
    let error = failure { try MuseNative.checkStatus(status) }
    check("OSStatus mapped to safe kind and stage", error?.kind == kind && error?.stage == .keychain && error?.status == status)
}
check("success OSStatus accepted", failure { try MuseNative.checkStatus(errSecSuccess) } == nil)
var preflights = 0, copies = 0
for mode in [MuseNative.Mode.background, .connect] {
    let result = try? MuseNative.readKeychain(mode, preflight: { preflights += 1 }, copy: { q in
        copies += 1
        check("exact Keychain service and account", q[kSecAttrService as String] as? String == "ai.meta.dev.credentials" && q[kSecAttrAccount as String] as? String == "meta")
        check("data-only single item query", q[kSecReturnData as String] as? Bool == true && q[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        check("interaction follows explicit mode", (q[kSecUseAuthenticationUI as String] as? String) == (mode == .background ? kSecUseAuthenticationUIFail as String : kSecUseAuthenticationUIAllow as String))
        check("per-query auth context, no global toggle", (q[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == (mode == .background))
        return (errSecSuccess, payload)
    })
    check("injected secret returned only in memory", result == payload)
}
check("only background does silent ACL preflight", preflights == 1 && copies == 2)
check("ACL interaction refusal prevents secret read", failure {
    _ = try MuseNative.readKeychain(.background, preflight: { throw MuseNative.Failure(.permissionNeeded, .keychain) }, copy: { _ in copies += 1; return (0,payload) })
}?.kind == .permissionNeeded && copies == 2)
let tmp = CommandLine.arguments[1]
let authPath = tmp + "/auth.json"
let authBytes = auth(token)
try! authBytes.write(to: URL(fileURLWithPath: authPath))
try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
check("trusted bounded auth file accepted", (try? MuseNative.readAuthFile(authPath)) == authBytes)
try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authPath)
check("auth file readable by other accounts refused", failure { _ = try MuseNative.readAuthFile(authPath) }?.kind == .untrustedFile)
try! FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: authPath)
check("shared writable auth file refused", failure { _ = try MuseNative.readAuthFile(authPath) }?.kind == .untrustedFile)
let link = tmp + "/auth-link.json"
try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: authPath)
check("symlink auth file refused", failure { _ = try MuseNative.readAuthFile(link) }?.kind == .untrustedFile)
check("missing auth file is not grant failure", (try? MuseNative.readAuthFile(tmp + "/absent")) == nil)
let large = tmp + "/large.json"
try! Data(repeating: 32, count: MuseNative.maxBytes+1).write(to: URL(fileURLWithPath: large))
check("oversized auth file refused", failure { _ = try MuseNative.readAuthFile(large) }?.kind == .untrustedFile)

let now = Date(timeIntervalSince1970: 1_792_665_000)
var root: [String: Any] = ["require_payment":false,"is_subs_active":true,"subs_tier_name":"Muse Code Everyday Usage",
                         "key":"NATIVE_FAKE_KEY","user_email":"NATIVE_FAKE_EMAIL","payment_method":"NATIVE_FAKE_KEY"]
func parsed(_ root: [String:Any]) -> MuseNative.Reading { MuseNative.parse(status:200,data:data(root),completed:now) }
for missing in [true, false] {
    var object = root; if !missing { object["subs_usage"] = NSNull() }
    let result = parsed(object)
    check("absent/null quota keeps active plan", result.activeLogin && result.snapshot.plan == "Everyday" && result.snapshot.state == .ok)
    check("absent/null quota stays unknown and unmeasured", result.snapshot.bar == nil && result.snapshot.windows.isEmpty && result.snapshot.measuredAt == nil && result.snapshot.error != nil)
}
let window: [String:Any] = ["used_percent":0,"window_duration_mins":300,"resets_at":now.timeIntervalSince1970+3600]
let weekly: [String:Any] = ["used_percent":111,"resets_at":now.timeIntervalSince1970+86400]
root["subs_usage"] = ["window":window,"weekly":weekly]
let good = parsed(root)
check("zero is valid received quota", good.snapshot.bar?.used == 0 && good.snapshot.measuredAt == now)
check("response seconds and r6 duration label", good.snapshot.bar?.resetsAt == now.addingTimeInterval(3600) && good.snapshot.bar?.label == "5-hour")
check("bounded over-limit is flagged", good.snapshot.windows.last?.used == 100 && good.snapshot.notes.contains("Week: over the limit"))
let encoded = String(decoding:try! JSONEncoder().encode(good.snapshot),as:UTF8.self)
check("snapshot excludes identity/key/payment", !encoded.contains("NATIVE_FAKE") && encoded.contains("Muse quota API"))
for (field, bad) in [("require_payment", 0 as Any), ("is_subs_active", "true" as Any), ("require_payment", NSNull()), ("is_subs_active", NSNull())] {
    var object = root; object[field] = bad
    let result = parsed(object)
    check("boolean fields require real JSON booleans", !result.activeLogin && result.snapshot.measuredAt == nil)
}
for field in ["require_payment", "is_subs_active"] {
    var object = root; object.removeValue(forKey:field)
    check("missing boolean fails validation", !parsed(object).activeLogin)
}
var payment = root; payment["require_payment"] = true
check("payment gate has fixed message", !parsed(payment).activeLogin && parsed(payment).snapshot.error == "Finish Muse billing to read quota.")
var inactive = root; inactive["is_subs_active"] = false
check("inactive subscription does not opt in", !parsed(inactive).activeLogin)
for raw: Any in [true, "15", -1, 1001, 1e308, NSNull()] {
    var w = window; w["used_percent"] = raw
    var object = root; object["subs_usage"] = ["window":w]
    let result = parsed(object)
    check("invalid quota unknown and never measured", result.snapshot.bar == nil && result.snapshot.windows.first?.used == nil && result.snapshot.measuredAt == nil)
}
for raw: Any in [true, "30", -1, 0, 1e308, 10081] {
    var w = window; w["window_duration_mins"] = raw
    var object = root; object["subs_usage"] = ["window":w]
    check("invalid duration uses guarded generic label", parsed(object).snapshot.windows.first?.label == "Window")
}
for raw: Any in [true, "30", -1, 1e308, 4_102_444_800.0] {
    var w = window; w["resets_at"] = raw
    var object = root; object["subs_usage"] = ["window":w]
    check("invalid reset never reaches UI as date", parsed(object).snapshot.windows.first?.resetsAt == nil)
}
for raw: Any in [NSNull(), "NATIVE_FAKE_EMAIL", 13, "arbitrary backend text"] {
    check("unknown plan never passes backend text", MuseNative.plan(raw).isEmpty)
}
for (raw, expected) in [("Muse Code Everyday Usage","Everyday"),("Muse Code High Usage","High Usage"),("Muse Code Power Usage","Power Usage"),("Muse Code Maximum Usage","Maximum Usage")] {
    check("canonical documented plan", MuseNative.plan(raw) == expected)
}
for code in [301,302,307,401,403,429,500,503,418] {
    let result = MuseNative.parse(status:code,data:data(root),completed:now)
    check("HTTP errors do not opt in or measure", !result.activeLogin && result.snapshot.measuredAt == nil && result.snapshot.windows.isEmpty)
}
check("response limit enforced at parser", !MuseNative.parse(status:200,data:Data(repeating:32,count:MuseNative.maxBytes+1),completed:now).activeLogin)
for invalid in ["NaN", "Infinity", "-Infinity"] {
    let bytes = Data(("{\"require_payment\":false,\"is_subs_active\":true,\"subs_usage\":{\"window\":{\"used_percent\":" + invalid + "}}}").utf8)
    let result = MuseNative.parse(status:200,data:bytes,completed:now)
    check("nonfinite JSON never measures quota", result.snapshot.measuredAt == nil && result.snapshot.bar == nil)
}
check("malformed response is fixed safe failure", !MuseNative.parse(status:200,data:Data("{".utf8),completed:now).activeLogin)
var requests = 0
let client = MuseNative.Client(credential: { _ in token }, network: { value in
    requests += 1; check("network receives only validated fixture", value == token); return (200,data(root))
})
check("single call per native read", client.read(.background).activeLogin && requests == 1)
let noCredential = MuseNative.Client(credential: { _ in throw MuseNative.Failure(.missingLogin,.keychain,errSecItemNotFound) },network:{ _ in requests += 1; return (200,data(root)) })
check("credential failure prevents HTTP", !noCredential.read(.connect).activeLogin && requests == 1)

final class FakeURL: URLProtocol {
    static var calls = 0
    static var mode = "ok"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        FakeURL.calls += 1
        check("hardcoded HTTPS endpoint and POST", request.url?.absoluteString == "https://api.meta.ai/muse-code/key" && request.httpMethod == "POST")
        check("authorization header only and API version", request.value(forHTTPHeaderField:"Authorization") == "Bearer " + token && request.value(forHTTPHeaderField:"x-api-version") == "1.0.0")
        check("bounded timeout request", request.timeoutInterval == 15)
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating:0,count:16)
            let count = stream.read(&bytes,maxLength:bytes.count)
            if count >= 0 { body = Data(bytes.prefix(count)) }
        }
        check("POST body is empty JSON object", body == Data("{}".utf8))
        if FakeURL.mode == "error" { client?.urlProtocol(self,didFailWithError:URLError(.timedOut)); return }
        let length = FakeURL.mode == "length" ? MuseNative.maxBytes+1 : 2
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Length":String(length)])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:FakeURL.mode == "chunk" ? Data(repeating:32,count:MuseNative.maxBytes+1) : Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
check("real URLSession with offline protocol succeeds", (try? MuseHTTP.request(token,protocols:[FakeURL.self]))?.0 == 200 && FakeURL.calls == 1)
for mode in ["length","chunk","error"] {
    FakeURL.mode = mode
    let count = FakeURL.calls
    let error = failure { _ = try MuseHTTP.request(token,protocols:[FakeURL.self]) }
    check("transport enforces limit/timeout without retries", error?.kind == (mode == "error" ? .timeout : .tooLarge) && FakeURL.calls == count+1)
}
let receiver = MuseHTTP()
let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FakeURL.self]
let session = URLSession(configuration:config)
let task = session.dataTask(with:URL(string:"https://api.meta.ai/muse-code/key")!)
var followed = true
receiver.urlSession(session,task:task,willPerformHTTPRedirection:HTTPURLResponse(url:task.originalRequest!.url!,statusCode:302,httpVersion:nil,headerFields:nil)!,newRequest:URLRequest(url:URL(string:"https://example.invalid")!)) { followed = $0 != nil }
check("redirect delegate denies forwarding", !followed)
session.invalidateAndCancel()

var persisted: [Bool] = [], modes: [MuseNative.Mode] = []
let store = Store(preview:[.muse:MuseNative.setup])
check("disabled source does not background poll", !store.fixtureShouldPoll(true,90))
check("disabled fetch does no credential/network work", store.fixtureBackground().state == .setup)
let testClient = MuseNative.Client(credential: { mode in modes.append(mode); return token },network:{ _ in (200,data(root)) })
store.fixtureNative(testClient,persist:{ persisted.append($0) })
store.connectMuse(); store.connectMuse()
check("connect is busy immediately and duplicate ignored", store.busy.contains(.muse))
let deadline = Date().addingTimeInterval(3)
while store.busy.contains(.muse), Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
check("connect completion applies on main", !store.busy.contains(.muse) && store.snaps[.muse]?.bar?.used == 0)
check("only successful active login opts into auto poll", store.fixtureSource() && persisted == [true] && modes == [.connect])
check("connect completion starts 30 minute floor", !store.fixtureShouldPoll(true,90))
store.fixtureFloor(1799)
check("force hover wake cannot bypass floor", !store.fixtureShouldPoll(true,nil) && !store.fixtureShouldPoll(false,90))
store.fixtureFloor(1801)
check("after floor background eligible", store.fixtureShouldPoll(true,nil))
_ = store.fixtureBackground()
check("future polling uses background mode", modes == [.connect,.background])
store.fixtureApply(.status(.muse,.permissionNeeded,"Allow LimitBar to read your Muse login to show quota."))
store.fixtureFloor(1); store.connectMuse()
check("reconnect cannot bypass floor", !store.busy.contains(.muse) && persisted == [true])
let deniedStore = Store(preview:[.muse:MuseNative.setup])
var deniedPersists: [Bool] = []
deniedStore.fixtureNative(MuseNative.Client(credential:{ _ in throw MuseNative.Failure(.denied,.keychain,errSecUserCanceled) },network:{ _ in failures += 1; return (200,Data()) }),persist:{ deniedPersists.append($0) })
deniedStore.connectMuse()
while deniedStore.busy.contains(.muse), Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
check("denied connect stops with inline feedback and no opt-in", deniedPersists == [false] && !deniedStore.fixtureSource() && deniedStore.snaps[.muse]?.state == .setup && deniedStore.snaps[.muse]?.error?.contains("declined") == true)
check("denied source never retries in background", !deniedStore.fixtureShouldPoll(true,nil))
deniedStore.connectMuse()
check("manual denial cannot cause repeated prompt within floor", !deniedStore.busy.contains(.muse) && deniedPersists == [false])
var nullRoot = root; nullRoot["subs_usage"] = NSNull()
let nullStore = Store(preview:[.muse:MuseNative.setup])
var nullOptIn: [Bool] = []
nullStore.fixtureNative(MuseNative.Client(credential:{ _ in token },network:{ _ in (200,data(nullRoot)) }),persist:{ nullOptIn.append($0) })
nullStore.connectMuse()
let nullDeadline = Date().addingTimeInterval(3)
while nullStore.busy.contains(.muse), Date() < nullDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
check("active login with null quota opts in without measurement", nullOptIn == [true] && nullStore.fixtureSource() && nullStore.snaps[.muse]?.measuredAt == nil && nullStore.snaps[.muse]?.plan == "Everyday")
store.fixtureApply(good.snapshot)
store.fixtureApply(parsed(nullRoot).snapshot)
check("unknown answer replaces old quota without fresh timestamp", store.snaps[.muse]?.windows.isEmpty == true && store.snaps[.muse]?.measuredAt == nil)
let failingNetwork = MuseNative.Client(credential:{ _ in token },network:{ _ in throw NSError(domain:"NATIVE_FAKE_TOKEN",code:1,userInfo:[NSLocalizedDescriptionKey:"NATIVE_FAKE_KEY"]) })
let safeFailure = String(decoding:try! JSONEncoder().encode(failingNetwork.read(.connect).snapshot),as:UTF8.self)
check("transport error payload never reaches output", !safeFailure.contains("NATIVE_FAKE"))
let preview = Store(preview:[.muse:MuseNative.setup]); preview.connectMuse()
check("preview cannot trigger Connect", !preview.busy.contains(.muse))
check("default Fetch muse inert", Fetch.muse() == MuseNative.setup)
print("PASS: \(checks) native checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
