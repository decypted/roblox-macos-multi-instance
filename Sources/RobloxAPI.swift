import Foundation
import Security

// MARK: - Roblox web API

struct RobloxUser: Codable {
    let id: Int64
    let name: String
    let displayName: String
}

enum RobloxAPIError: LocalizedError {
    case invalidCookie
    case noTicket(Int)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCookie: return "The login cookie is invalid or expired. Log in to this account again."
        case .noTicket(let code): return "Roblox didn't return a launch ticket (HTTP \(code))."
        case .badResponse(let code): return "Unexpected response from Roblox (HTTP \(code))."
        }
    }
}

enum RobloxAPI {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Session with no shared cookie jar, so each request only carries the account we pass in.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    private static func request(_ url: String, cookie: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.setValue(".ROBLOSECURITY=\(cookie)", forHTTPHeaderField: "Cookie")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("https://www.roblox.com/", forHTTPHeaderField: "Referer")
        r.setValue("https://www.roblox.com", forHTTPHeaderField: "Origin")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    static func currentUser(cookie: String) async throws -> RobloxUser {
        let (data, resp) = try await session.data(for: request("https://users.roblox.com/v1/users/authenticated", cookie: cookie))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw RobloxAPIError.invalidCookie }
        guard code == 200 else { throw RobloxAPIError.badResponse(code) }
        return try JSONDecoder().decode(RobloxUser.self, from: data)
    }

    /// One-time ticket the Roblox client exchanges for a session as this account.
    static func authTicket(cookie: String) async throws -> String {
        let (_, http) = try await postJSON("https://auth.roblox.com/v1/authentication-ticket", cookie: cookie, body: Data("{}".utf8))
        let code = http?.statusCode ?? 0
        if code == 401 { throw RobloxAPIError.invalidCookie }
        guard let ticket = http?.value(forHTTPHeaderField: "rbx-authentication-ticket"), !ticket.isEmpty else {
            throw RobloxAPIError.noTicket(code)
        }
        return ticket
    }

    /// POST with Roblox's CSRF dance: the first call returns 403 plus a token to echo back.
    private static func postJSON(_ url: String, cookie: String, body: Data) async throws -> (Data, HTTPURLResponse?) {
        var req = request(url, cookie: cookie, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        var (data, resp) = try await session.data(for: req)
        var http = resp as? HTTPURLResponse
        if http?.statusCode == 403, let csrf = http?.value(forHTTPHeaderField: "x-csrf-token") {
            req.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
            (data, resp) = try await session.data(for: req)
            http = resp as? HTTPURLResponse
        }
        return (data, http)
    }

    /// Where users are right now. Asking about your own account (using its own cookie)
    /// always includes the place and server (gameId).
    static func presence(cookie: String, userIds: [Int64]) async throws -> [UserPresence] {
        let body = try JSONSerialization.data(withJSONObject: ["userIds": userIds])
        let (data, http) = try await postJSON("https://presence.roblox.com/v1/presence/users", cookie: cookie, body: body)
        let code = http?.statusCode ?? 0
        if code == 401 { throw RobloxAPIError.invalidCookie }
        guard code == 200 else { throw RobloxAPIError.badResponse(code) }
        struct Wrapper: Decodable { let userPresences: [UserPresence] }
        return try JSONDecoder().decode(Wrapper.self, from: data).userPresences
    }

    static func headshotURL(userId: Int64) async -> String? {
        let url = "https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=\(userId)&size=150x150&format=Png&isCircular=true"
        guard let (data, _) = try? await session.data(from: URL(string: url)!),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]],
              let img = arr.first?["imageUrl"] as? String else { return nil }
        return img
    }
}

struct UserPresence: Decodable, Equatable {
    let userPresenceType: Int       // 0 offline, 1 website/app, 2 in game, 3 Studio
    let lastLocation: String?
    let placeId: Int64?
    let rootPlaceId: Int64?
    let gameId: String?
    let userId: Int64

    var isInGame: Bool { userPresenceType == 2 }

    var summary: String {
        switch userPresenceType {
        case 2:
            let name = (lastLocation?.isEmpty == false) ? lastLocation! : "a game"
            if let gameId { return "In \(name) · server \(gameId.prefix(8))…" }
            return "In \(name)"
        case 1: return "Online, not in a game"
        case 3: return "In Roblox Studio"
        default: return "Offline"
        }
    }
}

// MARK: - Where to join

struct LaunchTarget {
    var placeId: Int64
    var linkCode: String?
    var jobId: String?
    var followUserId: Int64? = nil

    /// Accepts a plain place ID, a roblox.com/games/<id>/... link, or a private server link.
    static func parse(_ input: String, jobId: String) -> LaunchTarget? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let job = jobId.trimmingCharacters(in: .whitespacesAndNewlines)

        if let id = Int64(s) {
            return LaunchTarget(placeId: id, linkCode: nil, jobId: job.isEmpty ? nil : job)
        }
        guard let placeMatch = s.range(of: #"/games/(\d+)"#, options: .regularExpression) else { return nil }
        let digits = s[placeMatch].drop(while: { !$0.isNumber })
        guard let id = Int64(digits) else { return nil }

        var code: String?
        if let comps = URLComponents(string: s),
           let c = comps.queryItems?.first(where: { $0.name == "privateServerLinkCode" })?.value, !c.isEmpty {
            code = c
        }
        return LaunchTarget(placeId: id, linkCode: code, jobId: job.isEmpty ? nil : job)
    }

    func placeLauncherURL(browserTrackerId: String) -> String {
        let base = "https://www.roblox.com/Game/PlaceLauncher.ashx"
        let attempt = UUID().uuidString.lowercased()
        if let user = followUserId {
            return "\(base)?request=RequestFollowUser&browserTrackerId=\(browserTrackerId)&userId=\(user)&joinAttemptId=\(attempt)&joinAttemptOrigin=JoinUser"
        }
        if let code = linkCode {
            return "\(base)?request=RequestPrivateGame&browserTrackerId=\(browserTrackerId)&placeId=\(placeId)&linkCode=\(code)&joinAttemptId=\(attempt)&joinAttemptOrigin=PlayButton"
        }
        if let job = jobId {
            return "\(base)?request=RequestGameJob&browserTrackerId=\(browserTrackerId)&placeId=\(placeId)&gameId=\(job)&isPlayTogetherGame=false&joinAttemptId=\(attempt)&joinAttemptOrigin=PlayButton"
        }
        return "\(base)?request=RequestGame&browserTrackerId=\(browserTrackerId)&placeId=\(placeId)&isPlayTogetherGame=false&joinAttemptId=\(attempt)&joinAttemptOrigin=PlayButton"
    }

    var summary: String {
        if linkCode != nil { return "private server in place \(placeId)" }
        if let jobId { return "server \(jobId.prefix(8))… in place \(placeId)" }
        return "place \(placeId)"
    }
}

// MARK: - Keychain (login cookies never touch disk in plain text)

enum Keychain {
    private static let service = "com.decypted.rbx-multi.cookies"

    static func set(_ value: String, for account: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
