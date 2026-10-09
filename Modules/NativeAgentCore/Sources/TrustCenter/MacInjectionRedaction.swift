import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Typed-secret redaction (W2/W3-FIX 4)

/// Text passed to a Mac action can be a password, a 2FA code, or a private
/// message. The MacControl RESULT
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
        "keystroke": ["text"],
        "clipboard_write": ["text"],
        "ax_act": ["value"],
        // The closed-loop act action can carry literal typed characters.
        "act": ["text"],
        "browser.chrome_type": ["text", "value", "fields"],
        "browser.chrome_fill": ["text", "value", "fields"],
        "browser.chrome_navigate": ["text", "value", "fields"],
        // Retired card names a model may still call from memory: whatever
        // token it wrote must never reach a receipt or trace in the clear.
        "interaction_act": ["value"], "card_act": ["value"], "answer_card": ["value"],
    ]

    public static func carriesSecretArgs(tool: String) -> Bool {
        secretKeysByTool[normalized(tool)] != nil
    }

    /// The secret args an `app` call carries, by its action.
    public static func appDoorSecretKeys(_ input: [String: JSONValue]) -> [String] {
        let keys = AppActionPolicy.action(input: input)?.secretArgs ?? []
        let foldedTool = ToolNameAliases.ranTool("app", input: input)
        return Array(Set(keys + (secretKeysByTool[normalized(foldedTool)] ?? []))).sorted()
    }

    /// Script source that names an action taking a key or token, by its id or
    /// by its two words apart (`app.card["answer"]`), each a whole word
    /// ("contacts" does not name act). The runner refuses such a call, but the
    /// source itself is never kept.
    public static func namesAppDoorSecretAction(_ source: String) -> Bool {
        let text = source.lowercased()
        let words = Set(text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
        let actions = AppActionPolicy.secretActionIDs
            + secretKeysByTool.keys.compactMap { ToolNameAliases.appAction($0) }
        return actions.contains { id in
            text.contains(id) || id.split(separator: ".").allSatisfy { words.contains(String($0)) }
        }
    }

    public static let appDoorScriptPlaceholder =
        "[redacted: this script names an action that takes a key or token]"

    /// An `app` call whose args or script could carry a key or token.
    public static func appDoorCarriesSecret(_ input: [String: JSONValue]) -> Bool {
        if !appDoorSecretKeys(input).isEmpty { return true }
        if case .string(let script)? = input["script"] { return namesAppDoorSecretAction(script) }
        return false
    }

    /// Replace literal text and form fields with count + digest.
    /// Non-secret arguments and non-injection tools pass through untouched.
    public static func redacted(tool: String, input: [String: JSONValue]) -> [String: JSONValue] {
        // An action id called as a tool name (mac.act) is an app call; redact it as one.
        let action = JSONValue.string(tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if tool.contains("."), AppActionPolicy.action(input: ["action": action]) != nil,
           case .object(let args)? = redacted(tool: "app", input: ["action": action, "args": .object(input)])["args"] {
            return args
        }
        if normalized(tool) == "app" {
            var out = input
            if case .string(let script)? = input["script"], namesAppDoorSecretAction(script) {
                out["script"] = .string(appDoorScriptPlaceholder)
            }
            let keys = appDoorSecretKeys(input)
            if !keys.isEmpty, case .object(let args)? = input["args"] {
                let safeArgs = redacting(keys, in: args)
                let foldedTool = ToolNameAliases.ranTool("app", input: input)
                out["args"] = .object(foldedTool == "app" ? safeArgs : redacted(tool: foldedTool, input: safeArgs))
            }
            return out
        }
        guard let keys = secretKeysByTool[normalized(tool)] else { return input }
        var out = redacting(keys, in: input)
        if normalized(tool) == "act", case .array(let steps)? = input["steps"] {
            out["steps"] = .array(steps.map { step in
                guard case .object(let args) = step else { return step }
                return .object(redacting(keys, in: args))
            })
        }
        return out
    }

    // Keep a form's labels and typed values together in memory for exact replay.
    // Serializing the whole fields value also covers numeric and boolean inputs.
    private static func secret(_ key: String, in input: [String: JSONValue]) -> String? {
        if key == "fields", let fields = input[key], fields != .null {
            return try? fields.serialize(pretty: false)
        }
        guard case .string(let value)? = input[key] else { return nil }
        return value
    }

    private static func redacting(_ keys: [String], in input: [String: JSONValue]) -> [String: JSONValue] {
        var out = input
        for key in keys {
            let secret = secret(key, in: input)
            guard secret != nil || (key == "fields" && input[key] != nil && input[key] != .null) else { continue }
            out.removeValue(forKey: key)
            if let secret {
                out["\(key)_character_count"] = .int(Int64(secret.count))
                if let digest = sha256(secret) {
                    out["\(key)_sha256"] = .string(digest)
                }
            }
            out["\(key)_redacted"] = .bool(true)
        }
        return out
    }

    /// The secrets stripped by `redacted`, keyed by argument name. The caller
    /// holds these in memory only — never on disk, never over a wire.
    public static func extractSecrets(tool: String, input: [String: JSONValue]) -> [String: String] {
        if normalized(tool) == "app" {
            guard case .object(let args)? = input["args"] else { return [:] }
            return extractSecrets(
                tool: ToolNameAliases.ranTool("app", input: input),
                input: args,
                keys: appDoorSecretKeys(input)
            )
        }
        return extractSecrets(tool: tool, input: input, keys: secretKeysByTool[normalized(tool)] ?? [])
    }

    private static func extractSecrets(tool: String, input: [String: JSONValue], keys: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in keys {
            if let secret = secret(key, in: input) { out[key] = secret }
        }
        if normalized(tool) == "act", case .array(let steps)? = input["steps"] {
            for (index, step) in steps.enumerated() {
                guard case .object(let args) = step else { continue }
                for (key, secret) in extractSecrets(tool: "keystroke", input: args) {
                    out["steps.\(index).\(key)"] = secret
                }
            }
        }
        return out
    }

    /// Put previously-extracted secrets back, dropping the redaction markers.
    /// The approved-replay caller verifies the reconstructed count and digest.
    public static func rehydrated(
        tool: String,
        input: [String: JSONValue],
        secrets: [String: String]
    ) -> [String: JSONValue] {
        if normalized(tool) == "app" {
            guard case .object(let args)? = input["args"] else { return input }
            var out = input
            out["args"] = .object(rehydrated(
                tool: ToolNameAliases.ranTool("app", input: input),
                input: args,
                secrets: secrets,
                keys: appDoorSecretKeys(input)
            ))
            return out
        }
        return rehydrated(tool: tool, input: input, secrets: secrets, keys: secretKeysByTool[normalized(tool)] ?? [])
    }

    private static func rehydrated(
        tool: String,
        input: [String: JSONValue],
        secrets: [String: String],
        keys: [String]
    ) -> [String: JSONValue] {
        var out = input
        for key in keys {
            guard let secret = secrets[key] else { continue }
            if key == "fields" {
                guard let fields = try? JSONValue.parse(Data(secret.utf8)) else { continue }
                out[key] = fields
            } else {
                out[key] = .string(secret)
            }
            out.removeValue(forKey: "\(key)_character_count")
            out.removeValue(forKey: "\(key)_sha256")
            out.removeValue(forKey: "\(key)_redacted")
        }
        if normalized(tool) == "act", case .array(let steps)? = input["steps"] {
            out["steps"] = .array(steps.enumerated().map { index, step in
                guard case .object(let args) = step else { return step }
                var stepSecrets: [String: String] = [:]
                for key in keys {
                    stepSecrets[key] = secrets["steps.\(index).\(key)"]
                }
                return .object(rehydrated(tool: "keystroke", input: args, secrets: stepSecrets))
            })
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
        if normalized(tool) == "app" {
            if input["script"] == .string(appDoorScriptPlaceholder) { return true }
            guard case .object(let args)? = input["args"] else { return false }
            return isRedacted(
                tool: ToolNameAliases.ranTool("app", input: input),
                input: args,
                keys: appDoorSecretKeys(input)
            )
        }
        return isRedacted(tool: tool, input: input, keys: secretKeysByTool[normalized(tool)] ?? [])
    }

    private static func isRedacted(tool: String, input: [String: JSONValue], keys: [String]) -> Bool {
        for key in keys {
            if case .bool(true)? = input["\(key)_redacted"] { return true }
        }
        if normalized(tool) == "act", case .array(let steps)? = input["steps"] {
            return steps.contains { step in
                guard case .object(let args) = step else { return false }
                return isRedacted(tool: "keystroke", input: args)
            }
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

    public static func normalized(_ tool: String) -> String {
        ToolNameAliases.canonical(tool).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

// MARK: - Injection TOOL vocabulary (the model-facing names)

/// `macControlAccessibilityInjectionActions` names the MacControl ACTIONS.
/// This names the model-facing TOOLS that map onto them, in every spelling the
/// catalog has ever used. Single source of truth for the autonomy floor, the
/// YOLO exclusion, and the redaction sinks — three places that were previously
/// keeping their own copies of the same four strings, which is how one of them
/// (the autonomy override path) ended up out of step.
public enum MacInjectionToolNames {
    public static let canonical: [String: String] = [
        // W6 — mac_wake posts a HID nudge, so it belongs to the SAME
        // vocabulary: one entry here gives it replay verification, redaction,
        // and the body-bound capability path, with no wake-shaped special case
        // anywhere in the gate.
        "mac_wake": "wake",
        "mac.wake": "wake",
    ]

    public static var all: Set<String> { Set(canonical.keys) }

    public static func isInjectionTool(_ toolName: String) -> Bool {
        canonical[toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil
    }

    /// The MacControl action a tool name maps to, or nil if it is not an
    /// injection tool.
    public static func action(forTool toolName: String) -> String? {
        canonical[toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// Legacy floor value; the compatibility clamp below is disabled.
    public static let minimumAutonomyLevel = "send_approval"

    /// Legacy unattended-level vocabulary retained for existing consumers.
    public static let unattendedAutonomyLevels: Set<String> = [
        "auto", "app_data_autonomous", "workspace_autonomous",
    ]

    /// Compatibility entry point: returns the resolved autonomy unchanged.
    ///
    /// USER 2026-08-12 — YOLO: "Nothing should be approval gated for her.
    /// Nothing." The floor is DISABLED at his explicit direction. His machine,
    /// his agent: the Full-Mac grant + accessibility category + the macOS TCC
    /// grant are the gates, and per-call approval made every motor tool dead on
    /// non-interactive surfaces (the bridge, while he is away) — precisely when
    /// he needs her to act.
    public static func clampedAutonomyLevel(toolName: String, resolved: String) -> String {
        return resolved
    }
}
