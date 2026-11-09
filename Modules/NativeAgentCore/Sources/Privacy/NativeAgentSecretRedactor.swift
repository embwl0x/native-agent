import PersistenceCore
import NativeAgentShared
import CryptoKit
import Foundation
// Blueprint: | `NativeAgentSecretRedactor.swift` | Canonical credential recognition and redaction. |

/// Canonical redaction contract for durable local receipts and activity feeds. Shared credential recognition retains digest-bearing receipt replacements.
public enum NativeAgentSecretRedactor {
    public static func redactText(_ value: String) -> String {
        guard TurnSecretRedactor.mayContainCredential(value) else { return value }
        return TurnSecretRedactor.redactText(value, patterns: TurnSecretRedactor.credentialPatterns, replacement: digestReplacement)
    }

    /// Boundaries may retain their replacement text while sharing recognition.
    public static func redactText(_ value: String, replacement: (String, String) -> String) -> String {
        guard TurnSecretRedactor.mayContainCredential(value) else { return value }
        return TurnSecretRedactor.redactText(value, patterns: TurnSecretRedactor.credentialPatterns, replacement: replacement)
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

    public static func secretPath(_ value: JSONValue, at path: String = "input") -> String? {
        switch value {
        case .string(let text): return containsAuditSecret(text) ? path : nil
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
        guard TurnSecretRedactor.mayContainCredential(value) else { return false }
        let range = NSRange(location: 0, length: (value as NSString).length)
        if TurnSecretRedactor.credentialPatterns.contains(where: { $0.1.firstMatch(in: value, range: range) != nil }) { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-----BEGIN") && trimmed.contains("PRIVATE KEY") { return true }
        // These rules only distinguish lengths through 25. ASCII uses its byte count; Unicode segmentation is bounded to that prefix.
        let length = trimmed.utf8.allSatisfy { $0 < 128 } ? trimmed.utf8.count : trimmed.prefix(25).count
        if trimmed.prefix(7).lowercased() == "bearer " && length > 24 { return true }
        if trimmed.hasPrefix("sk-") && length > 20 { return true }
        if trimmed.hasPrefix("ghp_") && length > 20 { return true }
        if trimmed.hasPrefix("xoxb-") && length > 20 { return true }
        // A token starts a word: "desk-park-future-proof" holds no "sk-" key.
        let trimmedRange = NSRange(location: 0, length: (trimmed as NSString).length)
        if auditTokens.firstMatch(in: trimmed, range: trimmedRange) != nil { return true }
        if containsValidJWT(in: trimmed) { return true }
        return false
    }

    /// Audit JWT candidates are bounded base64url triplets with JSON objects for header and payload, so ordinary dotted paths cannot qualify.
    private static func containsValidJWT(in value: String) -> Bool {
        guard value.utf8.contains(46) else { return false }
        let fullRange = NSRange(location: 0, length: (value as NSString).length)
        for match in auditJWT.matches(in: value, range: fullRange) {
            let candidate = (value as NSString).substring(with: match.range)
            let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
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

    private static let auditTokens = expression(#"\b(?:sk-[A-Za-z0-9_\-]{10,}|ghp_[A-Za-z0-9_]{10,}|xoxb-[A-Za-z0-9_\-]{10,})"#)
    private static let auditJWT = expression(
        #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"#)

    private static func expression(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) }
        catch { preconditionFailure("Invalid credential recognition pattern: \(error)") }
    }

    /// Only the masking producer can construct this value. Projection admission consumes its already checked size without re-encoding or
    /// treating a masked secret-named field as a new secret. Ordinary part calls still run secretPath over their raw input.
    public struct FaceInput: Sendable {
        public let value: JSONValue
        fileprivate init(_ value: JSONValue) { self.value = value }
    }

    /// The part face producer. Reuse requires exact raw content equality, including at each subtree; there is no expiry or event-based
    /// invalidation that could reuse a mask after a secret changed. Retain only the latest input per part, for at most 64 parts.
    public actor FaceInputs {
        private var kept: [String: (raw: JSONValue, safe: FaceInput)] = [:]
        private var order: [String] = []
        public init() {}

        public func prepare(id: String, input: JSONValue) throws -> FaceInput {
            try Task.checkCancellation()
            let previous = kept[id]
            if let previous, previous.raw == input { return previous.safe }
            let safe = mask(input, previous: previous?.raw, safe: previous?.safe.value)
            guard case .object = safe, try safe.serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
                throw PartFaceInputError()
            }
            try Task.checkCancellation()
            let result = FaceInput(safe)
            if previous == nil {
                if order.count == 64 { kept.removeValue(forKey: order.removeFirst()) }
                order.append(id)
            }
            kept[id] = (input, result)
            return result
        }

        private func mask(_ value: JSONValue, previous: JSONValue?, safe: JSONValue?) -> JSONValue {
            if previous == value, let safe { return safe }
            switch value {
            case .string(let text):
                let redacted = NativeAgentSecretRedactor.redactText(text)
                return .string(NativeAgentSecretRedactor.containsAuditSecret(redacted) ? "[REDACTED]" : redacted)
            case .array(let list):
                let old = previous?.arrayValue, masked = safe?.arrayValue
                return .array(list.enumerated().map { index, item in
                    mask(item, previous: old.flatMap { index < $0.count ? $0[index] : nil },
                         safe: masked.flatMap { index < $0.count ? $0[index] : nil })
                })
            case .object(let fields):
                return .object(Dictionary(uniqueKeysWithValues: fields.map { key, field in
                    (key, NativeAgentSecretRedactor.isSecretName(key, use: .scriptInput) && field != .null ? JSONValue.string("[REDACTED]")
                        : mask(field, previous: previous?.objectValue?[key], safe: safe?.objectValue?[key]))
                }))
            default: return value
            }
        }
    }

    private struct PartFaceInputError: LocalizedError {
        var errorDescription: String? { "part.call input is a JSON object of at most 4 MiB." }
    }

    private static func decodeBase64URLJSON(_ segment: Substring) -> [String: Any]? {
        var encoded = String(segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.utf8.count % 4
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
