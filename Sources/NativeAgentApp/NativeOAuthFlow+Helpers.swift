import Foundation
import CryptoKit
import Darwin

// MARK: - PKCE + helpers

struct PKCE {
    let verifier: String
    let challenge: String

    static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        // Fail loud: a zeroed PKCE verifier would silently gut the flow's CSRF/
        // interception protection. RNG failure is catastrophic, not recoverable.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed generating PKCE verifier")
        }
        let verifier = base64URLEncode(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))
        return PKCE(verifier: verifier, challenge: challenge)
    }
}

func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func randomHex(_ byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        fatalError("SecRandomCopyBytes failed generating OAuth state")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

func formEncode(_ params: [String: String]) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    return params.map { k, v in
        let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
        let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
        return "\(ek)=\(ev)"
    }.joined(separator: "&")
}

func loadJSONObject(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

func writeJSONObject(_ obj: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(withJSONObject: obj,
        options: [.prettyPrinted, .sortedKeys])
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

func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var body = String(parts[1])
    while body.count % 4 != 0 { body.append("=") }
    body = body.replacingOccurrences(of: "-", with: "+")
               .replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: body),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

func parseExpiresAt(_ raw: Any?) -> Date? {
    guard let raw = raw else { return nil }
    if let i = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
    if let d = raw as? Double { return Date(timeIntervalSince1970: d) }
    guard let s = raw as? String, !s.isEmpty else { return nil }
    if let unix = TimeInterval(s) { return Date(timeIntervalSince1970: unix) }
    let basic = DateFormatter()
    basic.calendar = Calendar(identifier: .iso8601)
    basic.locale = Locale(identifier: "en_US_POSIX")
    basic.timeZone = TimeZone(secondsFromGMT: 0)
    basic.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    if let d = basic.date(from: s) { return d }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    return nil
}

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date())
}

func isoBasic(_ d: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f.string(from: d)
}

func redact(_ s: String) -> String {
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
