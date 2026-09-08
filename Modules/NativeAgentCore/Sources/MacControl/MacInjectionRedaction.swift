import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Typed-secret redaction (W2/W3-FIX 4)

/// `mac_keystroke.text` is the literal characters Agent is about to type. That
/// can be a password, a 2FA code, or a private message. The MacControl RESULT
/// already reduces it to a count — but the approval record and the turn-trace
/// bus were storing the raw string, and the approval record is
/// `remoteResolvable`, so it syncs to the phone and to Telegram.
///
/// This redacts at every persistence/emission boundary: the raw characters are
/// replaced by `{text_character_count, text_sha256}`. The approval card renders
/// "type 7 characters"; the digest lets a reviewer confirm after the fact that
/// what ran is what was approved, without the record ever holding the secret.
public enum MacInjectionArgRedaction {
    /// Argument keys that carry literal user-visible secrets, per tool/action.
    /// `keys` is the only place to add one — every sink calls through here.
    static let secretKeysByTool: [String: [String]] = [
        "mac_keystroke": ["text"],
        "mac.keystroke": ["text"],
        "keystroke": ["text"],
        "mac_ax_act": ["value"],
        "mac.ax_act": ["value"],
        "ax_act": ["value"],
        // native-look item 3 — `mac_act {verb:"type", text:"…"}` carries the
        // literal characters, exactly like mac_keystroke.text. Same class of
        // secret, same redaction at every request boundary.
        "mac_act": ["text"],
        "mac.act": ["text"],
        "act": ["text"],
    ]

    public static func carriesSecretArgs(tool: String) -> Bool {
        secretKeysByTool[normalized(tool)] != nil
    }

    /// Replace every secret-bearing string argument with count + digest.
    /// Non-secret arguments and non-injection tools pass through untouched.
    public static func redacted(tool: String, input: [String: JSONValue]) -> [String: JSONValue] {
        guard let keys = secretKeysByTool[normalized(tool)] else { return input }
        var out = input
        for key in keys {
            guard case .string(let secret)? = input[key] else { continue }
            out.removeValue(forKey: key)
            out["\(key)_character_count"] = .int(Int64(secret.count))
            if let digest = sha256(secret) {
                out["\(key)_sha256"] = .string(digest)
            }
            out["\(key)_redacted"] = .bool(true)
        }
        return out
    }

    /// The secrets stripped by `redacted`, keyed by argument name. The caller
    /// holds these in memory only — never on disk, never over a wire.
    public static func extractSecrets(tool: String, input: [String: JSONValue]) -> [String: String] {
        guard let keys = secretKeysByTool[normalized(tool)] else { return [:] }
        var out: [String: String] = [:]
        for key in keys {
            if case .string(let secret)? = input[key] { out[key] = secret }
        }
        return out
    }

    /// Put previously-extracted secrets back, dropping the redaction markers.
    /// Used only on the approved-replay path, and only after the digest check.
    public static func rehydrated(
        tool: String,
        input: [String: JSONValue],
        secrets: [String: String]
    ) -> [String: JSONValue] {
        guard let keys = secretKeysByTool[normalized(tool)] else { return input }
        var out = input
        for key in keys {
            guard let secret = secrets[key] else { continue }
            out[key] = .string(secret)
            out.removeValue(forKey: "\(key)_character_count")
            out.removeValue(forKey: "\(key)_sha256")
            out.removeValue(forKey: "\(key)_redacted")
        }
        return out
    }

    /// `redacted` for an already-boxed payload. Idempotent, so a sink can call
    /// it without knowing whether an upstream sink already did — which is the
    /// point: every persistence boundary redacts for itself rather than
    /// trusting its caller to have done it.
    public static func redactedPayload(tool: String, payload: JSONValue) -> JSONValue {
        guard case .object(let obj) = payload else { return payload }
        return .object(redacted(tool: tool, input: obj))
    }

    /// True when `input` is the redacted FORM of a secret-bearing call — i.e.
    /// the characters were removed and have to be rehydrated before it can run.
    public static func isRedacted(tool: String, input: [String: JSONValue]) -> Bool {
        guard let keys = secretKeysByTool[normalized(tool)] else { return false }
        for key in keys {
            if case .bool(true)? = input["\(key)_redacted"] { return true }
        }
        return false
    }

    public static func sha256(_ value: String) -> String? {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    static func normalized(_ tool: String) -> String {
        tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Typed-secret redaction, RESULT side (W2/W3-FIX-R2 3)

/// The argument redactor above keeps the typed characters out of everything
/// that stores a REQUEST. This keeps them out of everything that stores a
/// RESULT.
///
/// `ax_act` re-reads the element it just wrote and returns both the element and
/// a `post_state`, so a value the caller set — a password, a 2FA code — came
/// straight back out through the tool result and from there into the turn-trace
/// preview, the operation store, and the approval record's `resultPreview`
/// (which is `remoteResolvable` and syncs to iOS/Telegram). The MacControl
/// handler now redacts at the source; this type is the same redaction applied
/// independently at each downstream preview boundary, so a future result shape
/// that reintroduces the field does not silently reopen the leak.
public enum MacInjectionResultRedaction {
    /// Result keys that can echo an injected secret back. Deliberately the
    /// value-bearing names only: counts, digests, roles, and frames are safe.
    public static let secretResultKeys: Set<String> = ["value", "text"]

    /// The replacement for one secret string: never the characters, always
    /// enough to audit them.
    public static func redactedSecret(_ secret: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "redacted": .bool(true),
            "character_count": .int(Int64(secret.count)),
        ]
        if let digest = MacInjectionArgRedaction.sha256(secret) {
            object["sha256"] = .string(digest)
        }
        return .object(object)
    }

    /// Redact every secret-bearing string in an injection tool's RESULT.
    /// Non-injection tools pass through untouched, and the walk is idempotent
    /// (an already-redacted value is an object, not a string).
    public static func redacted(tool: String, result: JSONValue) -> JSONValue {
        guard MacInjectionToolNames.isInjectionTool(tool)
            || MacInjectionArgRedaction.carriesSecretArgs(tool: tool) else { return result }
        return walk(result)
    }

    private static func walk(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, item) in object {
                if secretResultKeys.contains(key.lowercased()), case .string(let secret) = item {
                    out[key] = redactedSecret(secret)
                } else {
                    out[key] = walk(item)
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(walk))
        default:
            return value
        }
    }
}
