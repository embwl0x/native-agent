import Foundation
import PersistenceCore
import NativeAgentShared
import TrustCenter

/// The settings page's observed values and existing UI write actions.
@MainActor
public protocol QuietSettingsHost: AnyObject {
    var dataRootOverride: URL? { get }
    var trustPolicy: TrustPolicy? { get }
    var personality: PersonalityProfile? { get }
    var dreamError: String? { get }
    var chatModel: String { get set }
    var chatReasoningEffort: String { get set }
    var chatFastMode: Bool { get set }
    var chatFileAccess: String { get }

    func saveChatBrainDefaultsFailure() async -> String?
    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async throws -> TrustPolicy
    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String)
    func configureSurfaceSelection(
        surface: String, providerID: String, model: String,
        reasoningEffort: String, serviceTier: String?
    ) async throws
    func clearSurfaceOverride(surface: String) async throws
    func listQuietProviderAccounts() async throws -> [QuietProviderAccount]
    func agentAccessMode(from policy: TrustPolicy) -> String
    func applyTrustPreset(
        _ preset: TrustPolicyPreset,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async -> QuietTrustPresetOutcome
    func saveMultimodalPolicy(_ policy: TrustMultimodalPolicy) async -> Bool
    func dreamEnabled() async -> Bool
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool
    func savePersonalityChecked(_ profile: PersonalityProfile) async throws
    func patchMemoryPolicy(knowledgeGraphEnabled: Bool) async -> Bool
}

public struct QuietProviderAccount: Sendable {
    public let id: String
    public let authState: String

    public init(id: String, authState: String) {
        self.id = id
        self.authState = authState
    }
}

public enum QuietTrustPresetOutcome: Sendable {
    case confirmationRequired
    case applied
    case failed(String)
}
