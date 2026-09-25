import Foundation

/// GitHub sign-in by OAuth device flow (RFC 8628). The app is public: device
/// flow and its refresh need only the client ID, never a client secret.
public enum GitHubOAuthDeviceFlow {
    /// NativeAgent's registered GitHub OAuth App. Public by design.
    public static let clientID = "Ov23li0P1eSSTsro8QEw"
    public static let scopes = "repo read:org notifications read:user"

    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    public struct DeviceCode: Sendable, Equatable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURI: URL
        public let expiresAt: Date
        public let interval: TimeInterval
    }

    /// Stored as one JSON value in the Keychain.
    public struct Token: Codable, Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        public var refreshTokenExpiresAt: Date?

        /// Due for refresh inside five minutes of expiry.
        public func needsRefresh(now: Date = Date()) -> Bool {
            guard let expiresAt, refreshToken != nil else { return false }
            return expiresAt.timeIntervalSince(now) < 300
        }
    }

    public enum FlowError: Error, Sendable, Equatable, LocalizedError {
        case expired
        case denied
        /// GitHub rejected the refresh token; the person has to sign in again.
        case refreshRejected(String)
        case github(String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .expired: return "The GitHub code expired before it was approved. Start again."
            case .denied: return "GitHub sign-in was cancelled."
            case .refreshRejected(let code): return "GitHub sign-in has lapsed (\(code)). Connect GitHub again."
            case .github(let message): return "GitHub sign-in failed: \(message)"
            case .transport(let message): return "Couldn't reach GitHub: \(message)"
            }
        }
    }

    public static func requestDeviceCode() async throws -> DeviceCode {
        let object = try await post(deviceCodeURL, ["client_id": clientID, "scope": scopes])
        if let error = object["error"] as? String {
            throw FlowError.github((object["error_description"] as? String) ?? error)
        }
        guard let deviceCode = object["device_code"] as? String,
              let userCode = object["user_code"] as? String,
              let uri = (object["verification_uri"] as? String).flatMap(URL.init(string:))
        else { throw FlowError.github("device code response was incomplete") }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            expiresAt: Date().addingTimeInterval(number(object["expires_in"]) ?? 900),
            interval: number(object["interval"]) ?? 5
        )
    }

    /// Polls until the person approves, declines, or the code expires.
    /// Cancelling the task stops it.
    public static func pollForToken(_ code: DeviceCode) async throws -> Token {
        var interval = max(code.interval, 1)
        while Date() < code.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            // A dropped connection or a 5xx while the person is still approving
            // is retried at the next interval, not the end of the sign-in; the
            // code's expiry still bounds the loop, and cancelling still stops it.
            let object: [String: Any]
            do {
                object = try await post(tokenURL, [
                    "client_id": clientID,
                    "device_code": code.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            } catch FlowError.transport {
                try Task.checkCancellation()
                continue
            }
            switch object["error"] as? String {
            case nil:
                return try token(from: object)
            case "authorization_pending":
                continue
            case "slow_down":
                interval = number(object["interval"]) ?? (interval + 5)
            case "expired_token":
                throw FlowError.expired
            case "access_denied":
                throw FlowError.denied
            case let other?:
                throw FlowError.github((object["error_description"] as? String) ?? other)
            }
        }
        throw FlowError.expired
    }

    /// Device-flow tokens refresh without a client secret (GitHub docs:
    /// client_secret is required "unless the user access token was generated
    /// using the device flow").
    public static func refresh(_ refreshToken: String) async throws -> Token {
        let object = try await post(tokenURL, [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        if let error = object["error"] as? String {
            // Only a dead grant ends the sign-in; anything else is retried later.
            if ["invalid_grant", "bad_refresh_token", "unauthorized_client"].contains(error) {
                throw FlowError.refreshRejected(error)
            }
            throw FlowError.github((object["error_description"] as? String) ?? error)
        }
        return try token(from: object)
    }

    private static func token(from object: [String: Any]) throws -> Token {
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw FlowError.github("token response had no access token")
        }
        let now = Date()
        return Token(
            accessToken: access,
            refreshToken: (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: number(object["expires_in"]).map { now.addingTimeInterval($0) },
            refreshTokenExpiresAt: number(object["refresh_token_expires_in"]).map { now.addingTimeInterval($0) }
        )
    }

    private static func number(_ raw: Any?) -> TimeInterval? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return TimeInterval(s) }
        return nil
    }

    private static func post(_ url: URL, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("NativeAgent", forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+:/ ")
        request.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FlowError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FlowError.transport("HTTP \(status), non-JSON response")
        }
        // GitHub answers OAuth errors with 200 + `error`; a 5xx is transient.
        if status >= 500 { throw FlowError.transport("HTTP \(status)") }
        return object
    }
}
