import Foundation
import Security
import CryptoKit
import Darwin
import PersistenceCore

// MARK: - PKCE + helpers

public struct PKCE {
    public let verifier: String
    public let challenge: String

    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A zeroed PKCE verifier would silently gut the flow's CSRF /
        // interception protection, so this must never fall back to weak
        // bytes — but it must not take the app down from Sign in either.
        // arc4random_buf is the platform CSPRNG and has no failure mode.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, bytes.count)
        }
        let verifier = NativeOAuthSupport.base64URLEncode(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = NativeOAuthSupport.base64URLEncode(Data(digest))
        return PKCE(verifier: verifier, challenge: challenge)
    }
}

public enum NativeOAuthSupport {
    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        // Same rule as the PKCE verifier: never weak bytes, never a crash from
        // Sign in. arc4random_buf is the platform CSPRNG and cannot fail.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, bytes.count)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }

    public static func loadJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    static func updateProviderCredential(
        at path: URL,
        replacingXAIGrant: Bool = false,
        update: (inout [String: Any]) throws -> Void
    ) throws {
        try CredentialFileLock.withLock(path) {
            var object: [String: Any]
            if replacingXAIGrant {
                object = try ProviderStateValidation.credentialMetadata(at: path)
            } else {
                object = try ProviderStateValidation.credential(at: path)
            }
            try update(&object)
            try ProviderStateValidation.credential(object)
            try writeJSONObject(object, to: path)
        }
    }

    /// Every credential write the app makes — sign-in, token replacement, the
    /// connector stores. User, 2026-09-06: this ran with no lock at all, so a
    /// sign-in replacing the file raced an adapter's in-flight token refresh,
    /// which compared the bytes and then wrote. Both sides now take the SAME
    /// per-path lock, so the refresh's compare-and-write cannot straddle this one.
    /// Callers that already hold that path's lock through `withFileLock` (the
    /// connector, Slack and X credential writes all do) pass straight through:
    /// `flock` is not recursive, so re-acquiring it here only waited out the
    /// acquire timeout and failed the write it was protecting.
    public static func writeJSONObject(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if url.lastPathComponent == "xai_oauth_direct.json",
           ["access_token", "refresh_token", "id_token", "tokens"].contains(where: { obj[$0] != nil }) {
            try XAIOAuthCredentialStore.write(obj, to: url)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        try CredentialFileLock.withLock(url) {
            let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        }
    }

    public static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    public static func isoBasic(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: d)
    }

    public static func redact(_ s: String) -> String {
        var out = s
        let patterns: [(String, String)] = [
            ("sk-[A-Za-z0-9_-]{20,}",                                "***REDACTED***"),
            ("Bearer [A-Za-z0-9._-]+",                               "Bearer ***REDACTED***"),
            ("xox[baprs]-[A-Za-z0-9-]{20,}",                         "xox***REDACTED***"),
            ("gh[opsru]_[A-Za-z0-9_]{20,}",                           "gh***REDACTED***"),
            ("github_pat_[A-Za-z0-9_]{20,}",                          "github_pat_***REDACTED***"),
            ("eyJ[A-Za-z0-9._-]+\\.[A-Za-z0-9._-]+\\.[A-Za-z0-9._-]+", "***REDACTED***"),
            ("rt_[A-Za-z0-9._-]{16,}",                               "rt_***REDACTED***"),
        ]
        for (pat, repl) in patterns {
            if let re = try? NSRegularExpression(pattern: pat) {
                out = re.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: repl)
            }
        }
        return out
    }
}
