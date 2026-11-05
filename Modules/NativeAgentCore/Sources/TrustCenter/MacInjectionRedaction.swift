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
    /// Argument keys that carry literal user-visible secrets, per tool/action. `keys` is the only place to add one — every sink calls through here.
    static let secretKeysByTool: [String: [String]] = [
        "keystroke": ["text"],
        "clipboard_write": ["text"],
        "ax_act": ["value"],
        "act": ["text"],
        "browser.chrome_type": ["text", "value", "fields"],
        "browser.chrome_fill": ["text", "value", "fields"],
        "browser.chrome_navigate": ["text", "value", "fields"],
        "interaction_act": ["value"],
    ]

    public static func carriesSecretArgs(tool: String, turn: Turn?, catalog: [String: AppActionBinding]? = nil) -> Bool {
        secretKeysByTool[normalized(tool)] != nil || argumentProtectionReason(tool, turn: turn, catalog: catalog) != nil
    }

    /// Unknown ingress has no trusted argument contract, so withhold input; checked owners recognize dynamic faces and senses (a sense door is
    /// scoped to the turn's verified session, so the turn being served is the one whose contracts count).
    private static func argumentProtectionReason(_ tool: String, turn: Turn?, catalog: [String: AppActionBinding]?) -> String? {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if AuthoredToolEffects.isPrimitiveEffect(name) { return nil }
        if name == "app" || AppActionBinding.declaredSchema(name) != nil || AppActionBinding.declaredBinding(name) != nil
            || AppActionBinding.bindsTool(name) { return nil }
        do {
            if try AppActionBinding.binding(name, turn: turn, catalog: catalog) != nil { return nil }
            return unknownActionPrefix + "No action is called \(name); nothing ran. Find the one you mean with app {find:\"\(name)\"}."
        } catch {
            return """
                The call's argument contract could not be read: \(error.localizedDescription). Its arguments were withheld; repair the catalog before \
                submitting the original call again.
                """
        }
    }

    /// Withheld calls require original arguments again; missing bytes cannot become executable defaults or approval payloads.
    private static let argumentContractUnavailableKey = "_nativeagent_argument_contract_unavailable"

    /// Unknown arguments stay withheld from evidence; the door answers the missing action before consent.
    private static let unknownActionPrefix = "unknown_action: "

    /// The plain line for a call naming an action that does not exist, or nil.
    public static func unknownActionReason(in value: JSONValue) -> String? {
        guard let reason = withheldArgumentReason(in: value), reason.hasPrefix(unknownActionPrefix) else { return nil }
        return String(reason.dropFirst(unknownActionPrefix.count))
    }

    public static func withheldArgumentReason(in value: JSONValue, includingUnknownActions: Bool = true) -> String? {
        switch value {
        case .object(let object):
            if let reason = object[argumentContractUnavailableKey]?.stringValue,
               includingUnknownActions || !reason.hasPrefix(unknownActionPrefix) { return reason }
            for value in object.values {
                if let reason = withheldArgumentReason(in: value, includingUnknownActions: includingUnknownActions) { return reason }
            }
        case .array(let values):
            for value in values {
                if let reason = withheldArgumentReason(in: value, includingUnknownActions: includingUnknownActions) { return reason }
            }
        default: break
        }
        return nil
    }

    private static func withheld(_ reason: String) -> [String: JSONValue] {
        [argumentContractUnavailableKey: .string(reason)]
    }

    public static func appDoorSecretKeys(_ input: [String: JSONValue]) -> [String] {
        // Credential declarations belong to the fixed door vocabulary. An authored action has no :secret argument declarations.
        let keys = input["action"]?.stringValue.flatMap { AppActionBinding.declaredBinding($0)?.secretArgs } ?? []
        let foldedTool = ToolNameAliases.ranTool("app", input: input)
        return Array(Set(keys + (secretKeysByTool[normalized(foldedTool)] ?? []))).sorted()
    }

    /// Recognize whole action ids or separated words so traces withhold credential-bearing source without matching unrelated names.
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

    public static func appDoorCarriesSecret(_ input: [String: JSONValue], turn: Turn?, catalog: [String: AppActionBinding]? = nil) -> Bool {
        if !appDoorSecretKeys(input).isEmpty { return true }
        if let action = input["action"]?.stringValue, argumentProtectionReason(action, turn: turn, catalog: catalog) != nil,
            input["args"] != nil { return true }
        if case .string(let script)? = input["script"], namesAppDoorSecretAction(script) { return true }
        if case .array(let entries)? = input["actions"] {
            return entries.contains { if case .object(let call) = $0 { appDoorCarriesSecret(call, turn: turn, catalog: catalog) } else { false } }
        }
        return false
    }

    /// Replace secret text and form values with count/digest while preserving non-secret arguments.
    public static func redacted(tool: String, input: [String: JSONValue], turn: Turn?, catalog: [String: AppActionBinding]? = nil) -> [String: JSONValue] {
        if withheldArgumentReason(in: .object(input)) != nil {
            return withheld("This call contains withheld arguments. Submit the original call after its current argument contract is available.")
        }
        // An action id called as a tool name (mac.act) is an app call; redact it as one.
        let action = JSONValue.string(tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if tool.contains("."), AppActionBinding.declaredBinding(tool) != nil,
           case .object(let args)? = redacted(tool: "app", input: ["action": action, "args": .object(input)], turn: turn, catalog: catalog)["args"] {
            return args
        }
        if normalized(tool) == "app" {
            var out = input
            if let action = input["action"]?.stringValue, let reason = argumentProtectionReason(action, turn: turn, catalog: catalog), input["args"] != nil {
                out["args"] = .object(withheld(reason))
                return out
            }
            if case .string(let script)? = input["script"], namesAppDoorSecretAction(script) {
                out["script"] = .string(appDoorScriptPlaceholder)
            }
            if case .array(let entries)? = input["actions"] {
                out["actions"] = .array(entries.map { if case .object(let call) = $0 { .object(redacted(tool: "app", input: call, turn: turn,
                    catalog: catalog)) } else { $0 } })
            }
            let keys = appDoorSecretKeys(input)
            if !keys.isEmpty, case .object(let args)? = input["args"] {
                let safeArgs = redacting(keys, in: args)
                let foldedTool = ToolNameAliases.ranTool("app", input: input)
                out["args"] = .object(foldedTool == "app" ? safeArgs : redacted(tool: foldedTool, input: safeArgs, turn: turn, catalog: catalog))
            }
            return out
        }
        guard let keys = secretKeysByTool[normalized(tool)] else {
            return argumentProtectionReason(tool, turn: turn, catalog: catalog).map(withheld) ?? input
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

    // Keep a form's labels and typed values together in memory for exact replay. Serializing the whole fields value also covers numeric and boolean inputs.
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

    /// Extracted secrets stay in caller memory only, never on disk or over a wire.
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

    /// Reconstruction requires the approved replay owner to verify restored count and digest.
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

    /// Redaction is idempotent so every persistence boundary can enforce it without trusting upstream callers.
    public static func redactedPayload(tool: String, payload: JSONValue, turn: Turn?, catalog: [String: AppActionBinding]? = nil) -> JSONValue {
        guard case .object(let obj) = payload else { return payload }
        return .object(redacted(tool: tool, input: obj, turn: turn, catalog: catalog))
    }

    /// Redacted secret calls cannot execute until their missing characters are rehydrated.
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
    /// Result keys that can echo an injected secret back. Deliberately the value-bearing names only: counts, digests, roles, and frames are safe.
    public static let secretResultKeys: Set<String> = ["value", "text"]

    /// Replace characters with auditable count and digest.
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

    /// Idempotently walk injection results so already-redacted objects survive downstream boundaries.
    public static func redacted(tool: String, result: JSONValue, turn: Turn?, catalog: [String: AppActionBinding]? = nil) -> JSONValue {
        guard MacInjectionToolNames.isInjectionTool(tool)
            || MacInjectionArgRedaction.carriesSecretArgs(tool: tool, turn: turn, catalog: catalog) else { return result }
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

/// Current wake-tool classification for injection handling and approval replay. PermissionLaw owns authority; this vocabulary only maps tool names to wake.
public enum MacInjectionToolNames {
    public static let canonical: [String: String] = [
        "mac_wake": "wake",
        "mac.wake": "wake",
    ]

    public static func isInjectionTool(_ toolName: String) -> Bool {
        canonical[toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil
    }

    public static func action(forTool toolName: String) -> String? {
        canonical[toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
