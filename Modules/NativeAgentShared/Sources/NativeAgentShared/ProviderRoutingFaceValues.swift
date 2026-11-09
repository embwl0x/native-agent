import Foundation
// Blueprint: | `ProviderRoutingFaceValues.swift` | Checked routing and preference values shared by execution and faces |

/// Group members share a unanimous override or inherit Chat's route with independent effort and tier.
public struct SurfacePreference: Sendable, Codable, Equatable {
    public var surface: String
    public var model: String
    public var reasoningEffort: String
    public var serviceTier: String

    public init(
        surface: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String = "default"
    ) {
        self.surface = surface
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }
}

/// Execution and faces consume the same reconciled picker tuple.
public struct ProviderRoutingSnapshot: Sendable, Codable, Equatable {
    /// The checked picker files' committed source revision, read under their lock.
    public let revision: Double
    public let preferences: [String: SurfacePreference]
    public let activeProviders: [String: String]
    public let pinnedModels: [String: String]
    /// Model/account inheritance is independent of effort and Fast.
    public var modelOverrideSurfaces: Set<String> {
        Set(pinnedModels.keys).union(preferences.keys.filter { surface in
            surface != "chat" && (preferences[surface]?.model != preferences["chat"]?.model
                || (activeProviders[surface] ?? activeProviders["chat"]) != activeProviders["chat"])
        })
    }
    /// Unusable saved picks leave the surface unset with a reason; no replacement is selected.
    public let unusablePicks: [String: String]

    public init(
        preferences: [String: SurfacePreference],
        activeProviders: [String: String],
        pinnedModels: [String: String],
        unusablePicks: [String: String] = [:],
        revision: Double = 0
    ) {
        self.revision = revision
        self.preferences = preferences
        self.activeProviders = activeProviders
        self.pinnedModels = pinnedModels
        self.unusablePicks = unusablePicks
    }
}

/// Unsupported saved keys remain visible as adverse state.
public struct ProviderSurfaceRowSet: Sendable, Codable, Equatable {
    public let visibleSurfaces: [String]
    public let unsupportedStoredKeys: [String]
    public init(visibleSurfaces: [String], unsupportedStoredKeys: [String]) {
        self.visibleSurfaces = visibleSurfaces
        self.unsupportedStoredKeys = unsupportedStoredKeys
    }
}
