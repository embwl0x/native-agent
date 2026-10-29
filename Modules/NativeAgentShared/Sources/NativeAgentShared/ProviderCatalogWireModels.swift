import Foundation

// Blueprint: | `ProviderCatalogWireModels.swift` | Shared provider connections with compatible decoding, model capabilities, typed check results, reasoning-choice values/table/filter and surface-group vocabulary; callers own their default reasoning policies |

public struct ReasoningEffortOption: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public var defaultReasoningEffortOptions: [ReasoningEffortOption] {
    [
        ReasoningEffortOption(id: "none", label: "None", description: nil),
        ReasoningEffortOption(id: "low", label: "Low", description: nil),
        ReasoningEffortOption(id: "medium", label: "Medium", description: nil),
        ReasoningEffortOption(id: "high", label: "High", description: nil),
        ReasoningEffortOption(id: "xhigh", label: "XHigh", description: nil),
        ReasoningEffortOption(id: "max", label: "Max", description: nil),
        ReasoningEffortOption(id: "ultra", label: "Ultra", description: nil)
    ]
}

public func reasoningOptions<Option>(available: [Option], supported: [String]?, id: (Option) -> String) -> [Option] {
    guard let supported, !supported.isEmpty else { return available }
    return available.filter { supported.contains(id($0)) }
}

public struct ProviderModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Tokens, or 0 when the provider catalog states no window.
    public var context_length: Int
    public var supports_streaming: Bool
    public var supports_vision: Bool
    public var supports_tools: Bool
    public var supports_json_mode: Bool
    public var cost_per_1k_in: Double?
    public var cost_per_1k_out: Double?
    public var default_reasoning_effort: String? = nil
    public var supported_reasoning_efforts: [String]? = nil
    public var supports_fast: Bool? = nil

    public init(
        id: String,
        name: String,
        context_length: Int,
        supports_streaming: Bool,
        supports_vision: Bool,
        supports_tools: Bool,
        supports_json_mode: Bool,
        cost_per_1k_in: Double? = nil,
        cost_per_1k_out: Double? = nil,
        default_reasoning_effort: String? = nil,
        supported_reasoning_efforts: [String]? = nil,
        supports_fast: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.context_length = context_length
        self.supports_streaming = supports_streaming
        self.supports_vision = supports_vision
        self.supports_tools = supports_tools
        self.supports_json_mode = supports_json_mode
        self.cost_per_1k_in = cost_per_1k_in
        self.cost_per_1k_out = cost_per_1k_out
        self.default_reasoning_effort = default_reasoning_effort
        self.supported_reasoning_efforts = supported_reasoning_efforts
        self.supports_fast = supports_fast
    }
}

public struct ProviderInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { provider_id }
    public var provider_id: String
    public var display_name: String
    public var auth_modes: [String]
    public var auth_status: ProviderAuthStatus
    public var models: [ProviderModelInfo]
    public var auth_mode: String?
    public var default_model: String?
    /// Explains an unavailable or last-known fetched catalog.
    public var models_note: String? = nil
    public init(
        provider_id: String,
        display_name: String,
        auth_modes: [String],
        auth_status: ProviderAuthStatus,
        models: [ProviderModelInfo],
        auth_mode: String? = nil,
        default_model: String? = nil,
        models_note: String? = nil
    ) {
        self.provider_id = provider_id
        self.display_name = display_name
        self.auth_modes = auth_modes
        self.auth_status = auth_status
        self.models = models
        self.auth_mode = auth_mode
        self.default_model = default_model
        self.models_note = models_note
    }

}

extension ProviderInfo {
    private enum CodingKeys: String, CodingKey { case provider_id, display_name, auth_modes, auth_status, models, auth_mode, default_model, models_note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider_id = try c.decode(String.self, forKey: .provider_id)
        display_name = try c.decode(String.self, forKey: .display_name)
        auth_modes = try c.decode([String].self, forKey: .auth_modes)
        auth_status = try c.decode(ProviderAuthStatus.self, forKey: .auth_status)
        models = try c.decode([ProviderModelInfo].self, forKey: .models)
        auth_mode = try? c.decode(String.self, forKey: .auth_mode)
        default_model = try? c.decode(String.self, forKey: .default_model)
        models_note = try? c.decode(String.self, forKey: .models_note)
    }
}

public struct ProviderTestResult: Codable, Hashable, Sendable {
    public var provider_id: String
    public var status: String
    public var tested: Bool
    public var response: String?
    public var model_used: String?
    public var detail: String?
    public var error: String?
    /// The failed check's typed cause, encoded by the provider router; nil from older peers.
    public var cause: String? = nil
    /// Short hash of the exact key the check sent, taken before it was sent.
    public var credential: String? = nil

    public init(
        provider_id: String,
        status: String,
        tested: Bool,
        response: String? = nil,
        model_used: String? = nil,
        detail: String? = nil,
        error: String? = nil,
        cause: String? = nil,
        credential: String? = nil
    ) {
        self.provider_id = provider_id
        self.status = status
        self.tested = tested
        self.response = response
        self.model_used = model_used
        self.detail = detail
        self.error = error
        self.cause = cause
        self.credential = credential
    }
}

/// The three model choices share this membership and presentation vocabulary.
public struct ProviderSurfaceMember: Sendable, Equatable {
    /// The routing surface id, as written in `providers/surfaces.json`.
    public let surface: String
    /// What the Providers page calls it, in a person's words.
    public let label: String

    public init(_ surface: String, _ label: String) {
        self.surface = surface
        self.label = label
    }
}

public struct ProviderSurfaceGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let members: [ProviderSurfaceMember]

    public init(id: String, title: String, members: [ProviderSurfaceMember]) {
        self.id = id
        self.title = title
        self.members = members
    }

    public var surfaces: [String] { members.map(\.surface) }

    /// The caption under a group's row: what this choice actually governs.
    public var caption: String {
        let names = members.map(\.label)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

public enum ProviderSurfaceGroups {
    public static let chat = ProviderSurfaceGroup(
        id: "chat", title: "Chat",
        members: [
            .init("chat", "Chat"),
            .init("ios", "iPhone"),
            .init("telegram", "Telegram"),
            .init("slack", "Slack"),
        ]
    )
    public static let work = ProviderSurfaceGroup(
        id: "work", title: "Work",
        members: [
            .init("desk", "Desk"),
            .init("workshop", "Task execution"),
            .init("autonomy", "Independent tasks"),
            .init("swarms", "Coordinated tasks"),
            .init("training", "Skill practice"),
            .init("heartbeat", "Background check-ins"),
            .init("diagnostics", "Diagnostics"),
        ]
    )
    public static let mind = ProviderSurfaceGroup(
        id: "memory_and_mind", title: "Memory and mind",
        members: [
            .init("memory", "Memory"),
            .init("dream", "Dreams"),
            .init("rem", "REM"),
            .init("cognition_reflection", "Reflection"),
            .init("compaction", "Conversation summaries"),
            .init("self_improvement", "Learning"),
            .init("studio_wander", "Creative exploration"),
        ]
    )
    public static let all: [ProviderSurfaceGroup] = [chat, work, mind]

    /// Every label, keyed by surface — the page reads its row names from here so
    /// a name can never drift from the group that owns it.
    public static func rows(visible: [String]) -> [ProviderSurfaceGroup] {
        all.compactMap { group in
            let members = group.members.filter { visible.contains($0.surface) }
            guard !members.isEmpty else { return nil }
            return ProviderSurfaceGroup(id: group.id, title: group.title, members: members)
        }
    }

    public static let labels: [String: String] = Dictionary(
        uniqueKeysWithValues: all.flatMap(\.members).map { ($0.surface, $0.label) }
    )

}

public enum ProviderSurfaceLabel: Equatable, Sendable {
    case named(String)
    case unrecognized(String)
    case malformed

    public static func presentation(for rawSurface: String) -> Self {
        let trimmed = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == rawSurface, rawSurface == rawSurface.lowercased() else {
            return .malformed
        }
        guard let label = ProviderSurfaceGroups.labels[rawSurface == "missions" ? "workshop" : rawSurface] else {
            return .unrecognized(rawSurface)
        }
        return .named(label)
    }
}
