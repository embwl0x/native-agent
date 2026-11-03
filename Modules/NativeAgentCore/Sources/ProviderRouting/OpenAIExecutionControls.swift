import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `OpenAIExecutionControls.swift` | `OpenAIExecutionControls`: transport-specific catalog capability admission and reasoning/service-tier wire serialization |

/// Capability-aware controls for public OpenAI requests and ChatGPT/Codex
/// account-backed requests. A signed account catalog can expose reasoning
/// levels that are not valid public API values, so those contracts stay
/// transport-specific.
public enum OpenAIExecutionControls {
    public enum Transport {
        case publicAPI
        case chatGPTOAuth
        case codexCLI

        /// The route whose catalog rows declare what this transport accepts.
        var route: String {
            switch self {
            case .publicAPI: "openai"
            case .chatGPTOAuth: "openai_oauth_direct"
            case .codexCLI: "codex"
            }
        }
    }


    /// Builder tools use the command CLI's selected account, like admission.
    public static var codexBridgeModelIDs: [String] {
        CodexAccountModelCatalog.matchingModels(providerID: "codex",
            oauthAuthURL: ChatGPTTransport.preferredAuthPath(source: .commandCLI)).map(\.id)
    }

    /// The selected account's checked row for account transports; public API
    /// controls belong only to its shipped descriptor. No row means unknown.
    public static func supportedReasoningEfforts(
        model: String,
        transport: Transport = .publicAPI,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        oauthAuthURL: URL? = nil
    ) -> Set<String> {
        switch transport {
        case .publicAPI:
            return FirstPartyModelCatalog.routeSupportedEfforts(model, providerID: transport.route).map(Set.init) ?? []
        case .chatGPTOAuth, .codexCLI:
            return accountModel(model: model, transport: transport, dataRoot: dataRoot, oauthAuthURL: oauthAuthURL)
                .map { Set($0.supportedReasoningEfforts) } ?? []
        }
    }

    private static func accountModel(model: String, transport: Transport, dataRoot: URL, oauthAuthURL: URL?) -> CodexAccountModelCatalog.Model? {
        CodexAccountModelCatalog.matchingModels(
            providerID: transport.route,
            oauthAuthURL: oauthAuthURL ?? ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot),
            dataRoot: dataRoot
        ).first { $0.id == model }
    }

    static func usesResponses(model: String) -> Bool {
        FirstPartyModelCatalog.descriptor(for: model, providerID: Transport.publicAPI.route)?.usesResponses == true
    }

    public static func reasoningEffort(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        oauthAuthURL: URL? = nil
    ) throws -> String? {
        guard let requested else { return nil }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supported = supportedEfforts.map { Set($0) }
            ?? supportedReasoningEfforts(model: model, transport: transport, dataRoot: dataRoot, oauthAuthURL: oauthAuthURL)
        guard supported.contains(normalized) else {
            throw LLMError.providerError(message: "Think level '\(requested)' is unsupported or unknown for \(model) on \(transport.route). Refresh Providers and choose a supported level.")
        }
        return normalized
    }

    /// Convert a selectable account tier into the exact value accepted by the
    /// target request transport. `max` and `ultra` are Codex client presets;
    /// the direct ChatGPT Responses backend exposes the same deepest wire
    /// effort as `xhigh` and rejects either preset when sent literally. Codex
    /// CLI keeps the original value so it can apply its client-side preset
    /// behavior, including Ultra's orchestration policy.
    public static func wireReasoningEffort(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil
    ) throws -> String? {
        guard let selected = try reasoningEffort(
            model: model,
            requested: requested,
            transport: transport,
            supportedEfforts: supportedEfforts
        ) else { return nil }
        if transport == .chatGPTOAuth,
           selected == "max" || selected == "ultra" {
            return "xhigh"
        }
        return selected
    }

    /// Priority only where the model's row declares Fast: the account's own
    /// row when the caller has it, else the transport's shipped row.
    public static func serviceTier(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportsFast: Bool? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        oauthAuthURL: URL? = nil
    ) throws -> String? {
        guard let requested else { return nil }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "default" { return nil }
        let declaredFast: Bool?
        if let supportsFast { declaredFast = supportsFast }
        else {
            switch transport {
            case .publicAPI: declaredFast = FirstPartyModelCatalog.descriptor(for: model, providerID: transport.route)?.supportsFast
            case .chatGPTOAuth, .codexCLI:
                declaredFast = accountModel(model: model, transport: transport, dataRoot: dataRoot, oauthAuthURL: oauthAuthURL)?.supportsFast
            }
        }
        guard normalized == "priority", declaredFast == true else {
            throw LLMError.providerError(message: "Service tier '\(requested)' is unsupported or unknown for \(model) on \(transport.route). Choose a supported tier in Providers.")
        }
        return "priority"
    }

    static func applyResponsesControls(
        to body: inout [String: Any],
        model: String,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil,
        supportsFast: Bool? = nil
    ) throws {
        if let effort = try wireReasoningEffort(
            model: model,
            requested: LLMCallContext.reasoningEffort,
            transport: transport,
            supportedEfforts: supportedEfforts
        ) {
            body["reasoning"] = ["effort": effort]
        }
        // Opt in even when the provider chooses its default reasoning effort.
        // Summary frames renew the guard but never become answer/code content.
        if ProviderStreamContext.stallOnly {
            var reasoning = body["reasoning"] as? [String: String] ?? [:]
            reasoning["summary"] = "auto"
            body["reasoning"] = reasoning
        }
        if let tier = try serviceTier(
            model: model,
            requested: LLMCallContext.serviceTier,
            transport: transport,
            supportsFast: supportsFast
        ) {
            body["service_tier"] = tier
        }
    }

    static func applyChatCompletionsControls(to body: inout [String: Any], model: String) throws {
        if let effort = try wireReasoningEffort(
            model: model,
            requested: LLMCallContext.reasoningEffort
        ) {
            body["reasoning_effort"] = effort
        }
        if let tier = try serviceTier(model: model, requested: LLMCallContext.serviceTier) {
            body["service_tier"] = tier
        }
    }
}
