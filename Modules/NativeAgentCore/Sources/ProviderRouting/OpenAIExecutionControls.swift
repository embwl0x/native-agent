import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `OpenAIExecutionControls.swift` | `OpenAIExecutionControls`: route-owned controls |

/// Capability-aware controls for public OpenAI requests and ChatGPT/Codex account-backed requests. A signed account catalog can expose reasoning levels
/// that are not valid public API values, so those contracts stay transport-specific.
public enum OpenAIExecutionControls {
    public enum Transport {
        case publicAPI
        case chatGPTOAuth
        case codexCLI

        /// The selected route owns the accepted controls.
        var route: String {
            switch self {
            case .publicAPI: "openai"
            case .chatGPTOAuth: "openai_oauth_direct"
            case .codexCLI: "codex"
            }
        }
    }


    /// The selected account's checked row for account transports; public API controls belong to the route's effective row (listed by OpenAI for this
    /// key, else shipped). No row means unknown.
    public static func supportedReasoningEfforts(
        model: String,
        transport: Transport = .publicAPI,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        oauthAuthURL: URL? = nil, preview: Bool = false
    ) -> Set<String> {
        switch transport {
        case .publicAPI:
            return FirstPartyModelCatalog.routeSupportedEfforts(model, providerID: transport.route, dataRoot: dataRoot).map(Set.init) ?? []
        case .chatGPTOAuth, .codexCLI:
            return accountModel(model: model, transport: transport, dataRoot: dataRoot, oauthAuthURL: oauthAuthURL, preview: preview)
                .map { Set($0.supportedReasoningEfforts) } ?? []
        }
    }

    private static func accountModel(model: String, transport: Transport, dataRoot: URL, oauthAuthURL: URL?, preview: Bool = false) -> CodexAccountModelCatalog
        .Model? {
        CodexAccountModelCatalog.matchingModels(
            providerID: transport.route,
            oauthAuthURL: oauthAuthURL ?? ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot),
            dataRoot: dataRoot, preview: preview
        ).first { $0.id == model }
    }

    static func usesResponses(model: String, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> Bool {
        FirstPartyModelCatalog.descriptor(for: model, providerID: Transport.publicAPI.route, dataRoot: dataRoot)?.usesResponses == true
    }

    public static func reasoningEffort(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        oauthAuthURL: URL? = nil, preview: Bool = false
    ) throws -> String? {
        guard let requested else { return nil }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supported = supportedEfforts.map { Set($0) }
            ?? supportedReasoningEfforts(model: model, transport: transport, dataRoot: dataRoot, oauthAuthURL: oauthAuthURL, preview: preview)
        guard supported.contains(normalized) else {
            throw LLMError.providerError(
                message: """
                    Think level '\(requested)' is unsupported or unknown for \(model) on \(transport.route). Refresh Providers and choose a supported \
                    level.
                    """)
        }
        // "default" is the provider's own default: no effort field at all.
        return normalized == "default" ? nil : normalized
    }

    /// Account presets max/ultra map to xhigh on direct Responses, which rejects those literal presets. The CLI retains them for its own preset behavior.
    public static func wireReasoningEffort(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil, preview: Bool = false
    ) throws -> String? {
        guard let selected = try reasoningEffort(
            model: model,
            requested: requested,
            transport: transport,
            supportedEfforts: supportedEfforts, preview: preview
        ) else { return nil }
        if transport == .chatGPTOAuth,
           selected == "max" || selected == "ultra" {
            return "xhigh"
        }
        return selected
    }

    /// Priority only where the model's row declares Fast: the account's own row when the caller has it, else the transport's shipped row.
    public static func serviceTier(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportsFast: Bool? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        oauthAuthURL: URL? = nil, preview: Bool = false
    ) throws -> String? {
        guard let requested else { return nil }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "default" { return nil }
        let declaredFast: Bool?
        if let supportsFast { declaredFast = supportsFast }
        else {
            switch transport {
            case .publicAPI: declaredFast = FirstPartyModelCatalog.descriptor(for: model, providerID: transport.route, dataRoot: dataRoot)?.supportsFast
            case .chatGPTOAuth, .codexCLI:
                declaredFast = accountModel(model: model, transport: transport, dataRoot: dataRoot, oauthAuthURL: oauthAuthURL, preview: preview)?.supportsFast
            }
        }
        guard normalized == "priority", declaredFast == true else {
            throw LLMError.providerError(
                message: "Service tier '\(requested)' is unsupported or unknown for \(model) on \(transport.route). Choose a supported tier in Providers.")
        }
        return "priority"
    }

    static func applyResponsesControls(
        to body: inout [String: Any],
        model: String,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil,
        supportsFast: Bool? = nil, call: LLMCall
    ) throws {
        if let effort = try wireReasoningEffort(
            model: model,
            requested: call.admission?.reasoningEffort,
            transport: transport,
            supportedEfforts: supportedEfforts, preview: call.preview
        ) {
            body["reasoning"] = ["effort": effort]
        }
        if let tier = try serviceTier(
            model: model,
            requested: call.admission?.serviceTier,
            transport: transport,
            supportsFast: supportsFast, preview: call.preview
        ) {
            body["service_tier"] = tier
        }
    }

    static func applyChatCompletionsControls(
        to body: inout [String: Any], model: String, call: LLMCall, dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws {
        let row = FirstPartyModelCatalog.descriptor(for: model, providerID: Transport.publicAPI.route, dataRoot: dataRoot)
        if let effort = try wireReasoningEffort(
            model: model,
            requested: call.admission?.reasoningEffort,
            supportedEfforts: row?.supportedReasoningEfforts ?? [], preview: call.preview
        ) {
            body["reasoning_effort"] = effort
        }
        if let tier = try serviceTier(model: model, requested: call.admission?.serviceTier, supportsFast: row?.supportsFast ?? false,
                                      preview: call.preview) {
            body["service_tier"] = tier
        }
    }
}
