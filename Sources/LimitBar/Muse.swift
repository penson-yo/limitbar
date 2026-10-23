import Foundation
import Security
import LocalAuthentication
import Darwin

/// The only native Muse secret/HTTP boundary. Never logs credentials, decoded objects or system errors.
/// Calling the key endpoint may issue an inference key; returned keys/identity/payment fields are ignored.
enum MuseNative {
    enum Mode { case background, connect }
    enum Stage: String { case authFile, keychain, token, response, transport }
    enum Kind: String { case permissionNeeded, denied, missingLogin, untrustedFile, malformedJSON,
                             unusableToken, keychainUnavailable, invalidResponse, network, timeout, tooLarge, redirect }
    struct Failure: Error {
        let kind: Kind
        let stage: Stage
        let status: OSStatus?
        init(_ kind: Kind, _ stage: Stage, _ status: OSStatus? = nil) {
            self.kind = kind; self.stage = stage; self.status = status
        }
        var snapshot: Snapshot {
            let state: VendorState = kind == .permissionNeeded ? .permissionNeeded : .setup
            let text: String
            switch kind {
            case .permissionNeeded: text = "Allow LimitBar to read your Muse login to show quota."
            case .denied: text = "Muse access was declined. Connect again when you're ready."
            case .missingLogin: text = "No Muse login found. Sign in with Muse, then connect again."
            case .untrustedFile: text = "Muse login file isn't trusted — not read."
            case .malformedJSON: text = "Stored Muse login couldn't be read. Sign in with Muse again."
            case .unusableToken: text = "Muse needs a device login. Sign in with Muse again."
            case .keychainUnavailable: text = "Muse login is temporarily unavailable. Try again later."
            case .invalidResponse: text = "Muse returned an unreadable quota response."
            case .network: text = "Couldn't reach Muse. Try again later."
            case .timeout: text = "Muse quota request timed out."
            case .tooLarge: text = "Muse quota response was too large — not used."
            case .redirect: text = "Muse redirected the quota request — not followed."
            }
            return .status(.muse, state, text)
        }
    }
    struct Reading { let snapshot: Snapshot; let activeLogin: Bool }
    static let maxBytes = 1 << 20
    static let setup = Snapshot.status(.muse, .setup, "Connect Muse to show its quota.")

    struct Client {
        var credential: (Mode) throws -> String = MuseNative.credential
        var network: (String) throws -> (Int, Data) = { try MuseHTTP.request($0) }
        func read(_ mode: Mode) -> Reading {
            do {
                let token = try credential(mode)
                let (status, data) = try network(token) // one request; no refresh, retry or key persistence
                return MuseNative.parse(status: status, data: data, completed: Date())
            } catch let failure as Failure {
                return Reading(snapshot: failure.snapshot, activeLogin: false)
            } catch {
                return Reading(snapshot: Failure(.network, .transport).snapshot, activeLogin: false)
            }
        }
    }

    /// Nonblank inline access_token takes precedence, including an unusable token (no silent fallback).
    /// Invalid/unrelated auth JSON falls back to the CLI's exact Keychain item, as upstream does.
    static func resolve(auth: Data?, keychain: () throws -> Data) throws -> String {
        struct Auth: Decodable {
            var providers: Providers?
            struct Providers: Decodable { var meta: Meta? }
            struct Meta: Decodable { var access_token: String?; var mechanism: String? }
        }
        if let auth, let file = try? JSONDecoder().decode(Auth.self, from: auth),
           let raw = file.providers?.meta?.access_token,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try validate(raw)
        }
        let data = try keychain()
        guard data.count <= maxBytes else { throw Failure(.malformedJSON, .keychain) }
        struct Payload: Decodable { var access_token: String? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw Failure(.malformedJSON, .keychain)
        }
        return try validate(payload.access_token)
    }

    static func validate(_ raw: String?) throws -> String {
        let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard token.utf8.count > 4, token.utf8.count <= 65_536, token.hasPrefix("dca:"),
              token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw Failure(.unusableToken, .token) }
        return token
    }

    static func credential(_ mode: Mode) throws -> String {
        let path = "\(CLI.home)/.config/muse/auth.json" // no environment or command-line secret override
        let auth = try readAuthFile(path)
        return try resolve(auth: auth) { try readKeychain(mode) }
    }

    static func readAuthFile(_ path: String) throws -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure(.untrustedFile, .authFile)
        }
        guard (st.st_mode & (S_IRWXG | S_IRWXO)) == 0, Fetch.trustedData(path) else { throw Failure(.untrustedFile, .authFile) }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(.untrustedFile, .authFile) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var actual = stat()
        guard fstat(fd, &actual) == 0, actual.st_dev == st.st_dev, actual.st_ino == st.st_ino,
              actual.st_uid == getuid(), (actual.st_mode & S_IFMT) == S_IFREG,
              actual.st_size >= 0, actual.st_size <= maxBytes,
              (actual.st_mode & (S_IRWXG | S_IRWXO)) == 0 else { throw Failure(.untrustedFile, .authFile) }
        guard let data = try? file.read(upToCount: maxBytes + 1), data.count <= maxBytes else {
            throw Failure(.malformedJSON, .authFile)
        }
        return data
    }

    static func query(_ mode: Mode, data: Bool = true) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = mode == .background
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "ai.meta.dev.credentials", kSecAttrAccount as String: "meta",
                kSecMatchLimit as String: kSecMatchLimitOne,
                (data ? kSecReturnData : kSecReturnRef) as String: true,
                kSecUseAuthenticationContext as String: context,
                kSecUseAuthenticationUI as String: mode == .connect ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
    }

    static func checkStatus(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed, errSecInteractionRequired: throw Failure(.permissionNeeded, .keychain, status)
        case errSecUserCanceled, errSecAuthFailed: throw Failure(.denied, .keychain, status)
        case errSecItemNotFound: throw Failure(.missingLogin, .keychain, status)
        default: throw Failure(.keychainUnavailable, .keychain, status)
        }
    }

    /// Legacy ACLs can prompt despite no-UI data flags. Inspect decrypt ACLs without asking for data.
    /// Unknown/locked access fails closed. Only an ACL that already permits this exact app may proceed.
    static func backgroundAccess() throws {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(.background, data: false) as CFDictionary, &result)
        try checkStatus(status)
        guard let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else {
            throw Failure(.keychainUnavailable, .keychain)
        }
        let item = unsafeBitCast(result, to: SecKeychainItem.self)
        var access: SecAccess?
        try checkStatus(SecKeychainItemCopyAccess(item, &access))
        guard let access, let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL],
              !acls.isEmpty else { throw Failure(.keychainUnavailable, .keychain) }
        for acl in acls {
            var apps: CFArray?, description: CFString?
            var selector = SecKeychainPromptSelector()
            try checkStatus(SecACLCopyContents(acl, &apps, &description, &selector))
            // Any explicit prompt requirement wins over app membership.
            guard selector.rawValue & 1 == 0 else { continue }
            if apps == nil { return }
            var current: SecTrustedApplication?
            try checkStatus(SecTrustedApplicationCreateFromPath(nil, &current))
            guard let current else { throw Failure(.keychainUnavailable, .keychain) }
            var currentData: CFData?
            try checkStatus(SecTrustedApplicationCopyData(current, &currentData))
            if let currentData, let trusted = apps as? [SecTrustedApplication], trusted.contains(where: {
                var data: CFData?
                return SecTrustedApplicationCopyData($0, &data) == errSecSuccess && data == currentData
            }) { return }
        }
        throw Failure(.permissionNeeded, .keychain, errSecInteractionNotAllowed)
    }

    static func copyData(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    static func readKeychain(_ mode: Mode, preflight: () throws -> Void = backgroundAccess,
                             copy: ([String: Any]) -> (OSStatus, Data?) = copyData) throws -> Data {
        if mode == .background { try preflight() }
        let (status, data) = copy(query(mode))
        try checkStatus(status)
        guard let data else { throw Failure(.malformedJSON, .keychain) }
        return data
    }

    static func plan(_ raw: Any?) -> String {
        guard let name = raw as? String else { return "" }
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "muse code": return "Muse Code"
        case "muse code everyday usage", "everyday usage", "everyday_usage", "everyday": return "Everyday"
        case "muse code high usage", "high usage", "high_usage": return "High Usage"
        case "muse code power usage", "power_usage", "power usage": return "Power Usage"
        case "muse code maximum usage", "maximum usage", "maximum_usage": return "Maximum Usage"
        default: return ""
        }
    }

    static func parse(status: Int, data: Data, completed: Date) -> Reading {
        func fail(_ text: String, state: VendorState = .failed) -> Reading {
            Reading(snapshot: .status(.muse, state, text), activeLogin: false)
        }
        switch status {
        case 200: break
        case 401, 403: return fail("Muse login was rejected. Sign in with Muse again.", state: .setup)
        case 429: return fail("Muse quota requests are rate limited. Try again later.")
        case 300..<400: return Reading(snapshot: Failure(.redirect, .transport).snapshot, activeLogin: false)
        case 500...599: return fail("Muse quota is temporarily unavailable.")
        default: return fail("Muse quota request failed.")
        }
        guard data.count <= maxBytes, let root = Fetch.json(data),
              let payment = root["require_payment"] as? NSNumber, CFGetTypeID(payment) == CFBooleanGetTypeID(),
              let active = root["is_subs_active"] as? NSNumber, CFGetTypeID(active) == CFBooleanGetTypeID() else {
            return Reading(snapshot: Failure(.invalidResponse, .response).snapshot, activeLogin: false)
        }
        if payment.boolValue { return fail("Finish Muse billing to read quota.", state: .setup) }
        guard active.boolValue else { return fail("No active Muse subscription on this login.", state: .setup) }
        var snapshot = Snapshot(vendor: .muse, plan: plan(root["subs_tier_name"]), notes: ["Muse quota API"])
        if root["subs_usage"] == nil || root["subs_usage"] is NSNull {
            snapshot.error = "Muse confirmed an active plan but didn't include quota."
            return Reading(snapshot: snapshot, activeLogin: true)
        }
        guard let usage = root["subs_usage"] as? [String: Any] else {
            snapshot.error = "Muse returned unreadable quota."
            return Reading(snapshot: snapshot, activeLogin: true)
        }
        for (key, label, short) in [("window", "Window", ""), ("weekly", "Week", "w")] {
            guard let row = usage[key] as? [String: Any] else { continue }
            var name = label, abbrev = short
            if key == "window", let mins = number(row["window_duration_mins"]), mins.isFinite,
               mins >= 1.0 / 60, mins <= 10_080 {
                // Reuse r6's duration formatting/guard without giving malformed duration an invented value.
                let formatted = Fetch.museParse(["observedAtMs": completed.timeIntervalSince1970 * 1000,
                    "window": ["usedPercent": 0, "windowDurationMins": mins]], now: completed)
                name = formatted.windows.first?.label ?? label; abbrev = formatted.windows.first?.short ?? short
            }
            let percent = overPercent(row["used_percent"])
            if percent?.over == true { snapshot.notes.append("\(name): over the limit") }
            let reset = number(row["resets_at"]).flatMap { Fetch.supportedDate(seconds: $0) }
            snapshot.windows.append(Window(label: name, short: abbrev, used: percent?.used, resetsAt: reset))
        }
        snapshot.bar = snapshot.windows.first { $0.used != nil }
        if snapshot.bar != nil { snapshot.measuredAt = completed }
        else { snapshot.error = "Muse didn't include usable quota numbers." }
        return Reading(snapshot: snapshot, activeLogin: true)
    }
}

/// A single ephemeral URLSession task; no cookies, cached credentials, proxy overrides, redirects or retries.
final class MuseHTTP: NSObject, URLSessionDataDelegate {
    private var body = Data()
    private var status = 0
    private var failure: MuseNative.Failure?
    private let done = DispatchSemaphore(value: 0)

    static func request(_ token: String, protocols: [AnyClass]? = nil) throws -> (Int, Data) {
        let receiver = MuseHTTP()
        let config = URLSessionConfiguration.ephemeral
        if let protocols { config.protocolClasses = protocols }
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:] // no environment proxy injection
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.meta.ai/muse-code/key")!, timeoutInterval: 15)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        task.resume()
        guard receiver.done.wait(timeout: .now() + 15) == .success else {
            task.cancel(); throw MuseNative.Failure(.timeout, .transport)
        }
        if let failure = receiver.failure { throw failure }
        return (receiver.status, receiver.body)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        failure = MuseNative.Failure(.redirect, .transport); completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > MuseNative.maxBytes {
            failure = MuseNative.Failure(.tooLarge, .transport); completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= MuseNative.maxBytes - body.count else {
            failure = MuseNative.Failure(.tooLarge, .transport); dataTask.cancel(); return
        }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil, let error = error as? URLError {
            failure = MuseNative.Failure(error.code == .timedOut ? .timeout : .network, .transport)
        } else if failure == nil, error != nil { failure = MuseNative.Failure(.network, .transport) }
        done.signal()
    }
}
