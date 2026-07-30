import Foundation
import PersistenceCore

extension SwiftNativeSecurityCenter {
    static func promptInjectionKeys(in value: JSONValue) -> [String] {
        let needles = [
            "ignore previous",
            "ignore all previous",
            "system prompt",
            "developer message",
            "reveal secrets",
            "show secrets",
            "api key",
            "access token",
            "disable safety",
            "bypass policy",
            "run shell",
            "sudo ",
        ]
        var hits: [String] = []
        func walk(_ v: JSONValue, keyPath: String) {
            switch v {
            case .string(let s):
                let lower = s.lowercased()
                if needles.contains(where: { lower.contains($0) }) {
                    hits.append(keyPath.isEmpty ? "input" : keyPath)
                }
            case .array(let arr):
                for (idx, item) in arr.enumerated() { walk(item, keyPath: "\(keyPath)[\(idx)]") }
            case .object(let obj):
                for (k, item) in obj { walk(item, keyPath: keyPath.isEmpty ? k : "\(keyPath).\(k)") }
            default:
                break
            }
        }
        walk(value, keyPath: "")
        return hits
    }

    static func secretKeys(in value: JSONValue) -> [String] {
        var hits: [String] = []
        func walk(_ v: JSONValue, keyPath: String) {
            let key = keyPath.lowercased()
            switch v {
            case .string(let s):
                if isSecretKey(key) || looksLikeSecret(s) {
                    hits.append(keyPath.isEmpty ? "input" : keyPath)
                }
            case .array(let arr):
                for (idx, item) in arr.enumerated() { walk(item, keyPath: "\(keyPath)[\(idx)]") }
            case .object(let obj):
                for (k, item) in obj { walk(item, keyPath: keyPath.isEmpty ? k : "\(keyPath).\(k)") }
            default:
                if isSecretKey(key) {
                    hits.append(keyPath)
                }
            }
        }
        walk(value, keyPath: "")
        return Array(Set(hits)).sorted()
    }

    static func redactValue(_ value: JSONValue, keyPath: String = "") -> JSONValue {
        let key = keyPath.lowercased()
        if isSecretKey(key) {
            return .string("[REDACTED]")
        }
        switch value {
        case .string(let s):
            if looksLikeSecret(s) {
                return .string("[REDACTED]")
            }
            if s.count > 500 {
                return .string(String(s.prefix(500)) + "...")
            }
            return .string(s)
        case .array(let arr):
            return .array(arr.enumerated().map { idx, item in
                redactValue(item, keyPath: "\(keyPath)[\(idx)]")
            })
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (k, item) in obj {
                out[k] = redactValue(item, keyPath: keyPath.isEmpty ? k : "\(keyPath).\(k)")
            }
            return .object(out)
        default:
            return value
        }
    }

    static func isSecretKey(_ key: String) -> Bool {
        let needles = [
            "password", "passphrase", "api_key", "apikey", "secret", "token",
            "credential", "authorization", "auth", "cookie", "jwt", "bearer",
            "private_key", "access_token", "refresh_token", "client_secret",
        ]
        return needles.contains(where: { key.contains($0) })
    }

    static func looksLikeSecret(_ value: String) -> Bool {
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
