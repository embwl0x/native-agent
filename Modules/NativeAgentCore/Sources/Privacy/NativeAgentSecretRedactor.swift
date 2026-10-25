import PersistenceCore
import CryptoKit
import Foundation
// Blueprint: | `NativeAgentSecretRedactor.swift` | Canonical credential text redaction and shared secret detection: exact script-input names, broader audit/card names, audit token/JWT scanning and recursive script-input paths |

/// Canonical redaction contract for durable local receipts and activity feeds.
///
/// The pattern order and replacement format mirror the retired runtime's
/// `redact_secret_text` / `redact_secret_value` behavior. Subsystems that need
/// this exact eight-pattern, digest-bearing contract must reuse this owner
/// instead of carrying private copies. More aggressive privacy boundaries
/// (for example chat traces or public/app projections) may layer additional
/// patterns without weakening this baseline.
public enum NativeAgentSecretRedactor {
    private static let patterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            (
                "PRIVATE_KEY",
                "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
                [.dotMatchesLineSeparators]
            ),
            (
                "GITHUB_TOKEN",
                "\\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})\\b",
                []
            ),
            ("OPENAI_KEY", "\\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\\b", []),
            ("ANTHROPIC_KEY", "\\bsk-ant-[A-Za-z0-9_-]{20,}\\b", []),
            ("STRIPE_KEY", "\\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\\b", []),
            ("SLACK_TOKEN", "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b", []),
            ("GOOGLE_API_KEY", "\\bAIza[0-9A-Za-z_-]{25,}\\b", []),
            (
                "BEARER_TOKEN",
                "\\bBearer\\s+[A-Za-z0-9._~+/=-]{24,}\\b",
                [.caseInsensitive]
            ),
        ]
        return specs.map { kind, pattern, options in
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: options
            ) else {
                preconditionFailure("NativeAgentSecretRedactor pattern failed: \(kind)")
            }
            return (kind, expression)
        }
    }()

    public static func redactText(_ value: String) -> String {
        redactText(value, patterns: patterns)
    }

    /// Boundaries may retain their replacement text while sharing recognition.
    public static func redactText(_ value: String, replacement: (String, String) -> String) -> String {
        redactText(value, patterns: patterns, replacement: replacement)
    }

    static func redactText(_ value: String, patterns: [(String, NSRegularExpression)],
                           replacement: (String, String) -> String = digestReplacement) -> String {
        var text = value
        for (kind, expression) in patterns {
            let current = text as NSString
            let matches = expression.matches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: current.length)
            )
            for match in matches.reversed() {
                let matched = current.substring(with: match.range)
                text = (text as NSString).replacingCharacters(
                    in: match.range,
                    with: replacement(kind, matched)
                )
            }
        }
        return text
    }

    static func digestReplacement(_ kind: String, _ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12)
        return "[REDACTED_\(kind):\(digest)]"
    }

    public static func redactValue(_ value: JSONValue) -> JSONValue {
        value.mapStrings(redactText)
    }
    /// Exact input names and the deliberately broader audit/card name matches.
    public enum NameUse { case scriptInput, audit, approval }
    public static func isSecretName(_ name: String, use: NameUse) -> Bool {
        let key = name.lowercased()
        let common = ["api_key", "apikey", "token", "password", "secret", "private_key", "authorization", "cookie", "credential"]
        let extra: [String] = switch use {
        case .scriptInput: ["access_token", "refresh_token", "passphrase", "client_secret", "credentials", "bearer"]
        case .audit: ["passphrase", "auth", "jwt", "bearer"]
        case .approval: ["passwd", "auth"]
        }
        return (common + extra).contains { use == .scriptInput ? key == $0 : key.contains($0) }
    }

    /// The first place a script's input carries a key or token: a field
    /// named as one, or a value shaped like one.
    public static func secretPath(_ value: JSONValue, at path: String = "input") -> String? {
        switch value {
        case .string(let text): return redactText(text) == text && !containsAuditSecret(text) ? nil : path
        case .array(let list): return list.indices.lazy.compactMap { secretPath(list[$0], at: "\(path)[\($0)]") }.first
        case .object(let fields):
            return fields.keys.sorted().lazy.compactMap { key -> String? in
                if isSecretName(key, use: .scriptInput), fields[key] != .null { return "\(path).\(key)" }
                return secretPath(fields[key] ?? .null, at: "\(path).\(key)")
            }.first
        default: return nil
        }
    }

    public static func containsAuditSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-----BEGIN") && trimmed.contains("PRIVATE KEY") { return true }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("bearer ") && trimmed.count > 24 { return true }
        if trimmed.hasPrefix("sk-") && trimmed.count > 20 { return true }
        if trimmed.hasPrefix("ghp_") && trimmed.count > 20 { return true }
        if trimmed.hasPrefix("xoxb-") && trimmed.count > 20 { return true }
        if trimmed.range(of: #"sk-[A-Za-z0-9_\-]{10,}"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"ghp_[A-Za-z0-9_]{10,}"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"xoxb-[A-Za-z0-9_\-]{10,}"#, options: .regularExpression) != nil { return true }
        if containsValidJWT(in: trimmed) { return true }
        return false
    }

    /// Detect a real JWT token inside arbitrary text. The former implementation
    /// split the *entire input string* on "." and treated three long chunks as
    /// a JWT. A shell command that mentioned `Package.swift` twice therefore
    /// became three chunks and was blocked as secret egress. Candidate tokens
    /// must now be bounded base64url triplets whose header and payload decode
    /// as JSON objects; ordinary dotted paths and filenames cannot qualify.
    private static func containsValidJWT(in value: String) -> Bool {
        let pattern = #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: fullRange) {
            guard let range = Range(match.range, in: value) else { continue }
            let parts = value[range].split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let header = decodeBase64URLJSON(parts[0]),
                  decodeBase64URLJSON(parts[1]) != nil else {
                continue
            }
            if header["alg"] != nil || header["typ"] != nil {
                return true
            }
        }
        return false
    }

    private static func decodeBase64URLJSON(_ segment: Substring) -> [String: Any]? {
        var encoded = String(segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }
}
