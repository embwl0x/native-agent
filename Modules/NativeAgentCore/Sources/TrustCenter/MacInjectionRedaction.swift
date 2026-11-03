import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
#if canImport(CryptoKit)
import CryptoKit
// Blueprint: | `MacInjectionRedaction.swift` | `MacInjectionArgRedaction` enum; `carriesSecretArgs`, `appDoorSecretKeys` |
#endif

// MARK: - Typed-secret redaction

/// Persisted and emitted secret text is replaced by `{text_character_count, text_sha256}`.
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
        // The current folded card.answer executor carries the answer value.
        "interaction_act": ["value"],
    ]

    public static func carriesSecretArgs(tool: String) -> Bool {
        secretKeysByTool[normalized(tool)] != nil || argumentProtectionReason(tool) != nil
    }

    /// Unknown ingress has no trusted argument contract. Withhold its input
    /// generically instead of maintaining a list of retired spellings. Dynamic
    /// faces and sense actions are recognized by their checked current owner.
    private static func argumentProtectionReason(_ tool: String) -> String? {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if AuthoredToolEffects.isPrimitiveEffect(name) { return nil }
        if name == "app" || AppActionBinding.declaredSchema(name) != nil || AppActionBinding.declaredBinding(name) != nil
            || AppActionBinding.bindsTool(name) { return nil }
        do {
            if try AppActionBinding.binding(name) != nil { return nil }
            return "The call is unrecognized; its arguments were withheld because no current contract declares them."
        } catch {
            return "The call's argument contract could not be read: \(error.localizedDescription). Its arguments were withheld; repair the catalog before submitting the original call again."
        }
    }

    /// A withheld call is never executable, even if its catalog is repaired
    /// between redaction and admission. The original arguments must be supplied
    /// again; missing bytes cannot become defaults or an approval payload.
    private static let argumentContractUnavailableKey = "_nativeagent_argument_contract_unavailable"

    public static func withheldArgumentReason(in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            if let reason = object[argumentContractUnavailableKey]?.stringValue { return reason }
            for value in object.values {
                if let reason = withheldArgumentReason(in: value) { return reason }
            }
        case .array(let values):
            for value in values {
                if let reason = withheldArgumentReason(in: value) { return reason }
            }
        default: break
        }
        return nil
    }

    private static func withheld(_ reason: String) -> [String: JSONValue] {
        [argumentContractUnavailableKey: .string(reason)]
    }

    /// The secret args an `app` call carries, by its action.
    public static func appDoorSecretKeys(_ input: [String: JSONValue]) -> [String] {
        // Credential declarations belong to the fixed door vocabulary. An
        // authored action has no :secret argument declarations.
        let keys = input["action"]?.stringValue.flatMap { AppActionBinding.declaredBinding($0)?.secretArgs } ?? []
        let foldedTool = ToolNameAliases.ranTool("app", input: input)
        return Array(Set(keys + (secretKeysByTool[normalized(foldedTool)] ?? []))).sorted()
    }

    /// Script source that names an action taking a key or token, by its id or
    /// by its two words apart (`app.card["answer"]`), each a whole word
    /// ("contacts" does not name act). Traces withhold its source even when
    /// the script's credential detector admits ordinary typed text.
    public static func namesAppDoorSecretAction(_ source: String) -> Bool {
        let text = source.lowercased()
        let words = Set(text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
        let actions = AppActionBinding.secretActionIDs
            + secretKeysByTool.keys.compactMap { ToolNameAliases.appAction($0) }
        return actions.contains { id in
            text.contains(id) || id.split(separator: ".").allSatisfy { words.contains(String($0)) }
        }
    }

    public static let appDoorScriptPlaceholder =
        "[redacted: this script names an action that takes a key or token]"

    /// An `app` call whose args, script or listed actions could carry a key or token.
    public static func appDoorCarriesSecret(_ input: [String: JSONValue]) -> Bool {
        if !appDoorSecretKeys(input).isEmpty { return true }
        if let action = input["action"]?.stringValue, argumentProtectionReason(action) != nil, input["args"] != nil { return true }
        if case .string(let script)? = input["script"], namesAppDoorSecretAction(script) { return true }
        if case .array(let entries)? = input["actions"] {
            return entries.contains { if case .object(let call) = $0 { appDoorCarriesSecret(call) } else { false } }
        }
        return false
    }

    /// Replace literal text and form fields with count + digest.
    /// Non-secret arguments and non-injection tools pass through untouched.
    public static func redacted(tool: String, input: [String: JSONValue]) -> [String: JSONValue] {
        if withheldArgumentReason(in: .object(input)) != nil {
            return withheld("This call contains withheld arguments. Submit the original call after its current argument contract is available.")
        }
        // An action id called as a tool name (mac.act) is an app call; redact it as one.
        let action = JSONValue.string(tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if tool.contains("."), AppActionBinding.declaredBinding(tool) != nil,
           case .object(let args)? = redacted(tool: "app", input: ["action": action, "args": .object(input)])["args"] {
            return args
        }
        if normalized(tool) == "app" {
            var out = input
            if let action = input["action"]?.stringValue, let reason = argumentProtectionReason(action), input["args"] != nil {
                out["args"] = .object(withheld(reason))
                return out
            }
            if case .string(let script)? = input["script"], namesAppDoorSecretAction(script) {
                out["script"] = .string(appDoorScriptPlaceholder)
            }
            if case .array(let entries)? = input["actions"] {
                out["actions"] = .array(entries.map { if case .object(let call) = $0 { .object(redacted(tool: "app", input: call)) } else { $0 } })
            }
            let keys = appDoorSecretKeys(input)
            if !keys.isEmpty, case .object(let args)? = input["args"] {
                let safeArgs = redacting(keys, in: args)
                let foldedTool = ToolNameAliases.ranTool("app", input: input)
                out["args"] = .object(foldedTool == "app" ? safeArgs : redacted(tool: foldedTool, input: safeArgs))
            }
            return out
        }
        guard let keys = secretKeysByTool[normalized(tool)] else {
            return argumentProtectionReason(tool).map(withheld) ?? input
        }
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

// MARK: - Typed-secret result redaction

/// Echoed secrets are redacted at the source and every downstream result-preview boundary.
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

/// Current wake-tool classification for injection handling and approval replay.
/// PermissionLaw owns authority; this vocabulary only maps tool names to wake.
public enum MacInjectionToolNames {
    public static let canonical: [String: String] = [
        "mac_wake": "wake",
        "mac.wake": "wake",
    ]

    public static func isInjectionTool(_ toolName: String) -> Bool {
        canonical[toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil
    }

    /// The MacControl action a tool name maps to, or nil if it is not an
    /// injection tool.
    public static func action(forTool toolName: String) -> String? {
        canonical[toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
