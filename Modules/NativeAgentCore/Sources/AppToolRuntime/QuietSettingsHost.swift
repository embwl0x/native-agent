import Context
import Foundation
import PersistenceCore
import NativeAgentShared
import ProviderRouting
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
    var chatProvider: String { get }
    var searchServiceURL: String { get }

    func saveChatBrainDefaultsFailure() async -> String?
    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async throws -> TrustPolicy
    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String)
    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String?, model: String?,
        reasoningEffort: String?, serviceTier: String?, clearOverride: Bool
    ) async throws -> ProviderGroupWriteResult
    func listQuietProviderAccounts() async throws -> [QuietProviderAccount]
    func agentAccessMode(from policy: TrustPolicy) -> String
    func applyTrustPreset(
        _ preset: TrustPolicyPreset,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async -> QuietTrustPresetOutcome
    func saveMultimodalPolicy(
        field: String, enabled: Bool,
        guardedByLockedPolicy: @escaping @Sendable ([String: JSONValue]) throws -> Void
    ) async throws -> TrustPolicy
    func dreamEnabled() async -> Bool
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool
    func savePersonalityChecked(_ profile: PersonalityProfile) async throws
    func patchMemoryPolicy(knowledgeGraphEnabled: Bool?, adaptivePromotion: Bool?, hygieneEnabled: Bool?) async -> Bool
    func saveMemoryPolicy(consolidationEnabled: Bool, crossSessionRecall: Bool, autoPromoteConsolidated: Bool) async

    // The Settings page's live switches. Each stores its key AND tells the
    // running app, which is what the page's own control does; a bare write to
    // the key changed what the page showed and nothing else until relaunch.
    /// The inner life as it ended up, and why when it is not running as asked.
    func setInnerLifeEnabled(_ enabled: Bool) async -> (enabled: Bool, problem: String?)
    func setCognitionLane(_ lane: QuietCognitionLane, enabled: Bool) async
    func setReflectionBudget(_ budget: Int) async
    /// The mode in effect after the write, which setup or safety can hold off.
    func setContextFlowMode(_ mode: ContextFlowMode) async -> ContextFlowMode
    func setGlobalHotkeyEnabled(_ enabled: Bool)
    func memoryMode() async throws -> String
    func setMemoryMode(_ mode: String) async throws
    /// Nil when saved; otherwise what was wrong with it.
    func savePersonalityName(_ name: String) async -> String?
    func saveSearchServiceURL(_ url: String) async throws
    /// The URL found and saved, or a throw saying why none was.
    func findSearchService() async throws -> String
    func inboxTriggers() async throws -> [QuietInboxTrigger]
    func setInboxTrigger(_ name: String, enabled: Bool) async throws
    func saveWatchedFolders(_ paths: [String]) async throws
    /// The lower-only switches whose state lives where only the app reaches
    /// (Chrome, Pause everything, activity capture, Mac integration, Telegram,
    /// Slack, connected agents), built with `QuietSettings.lowerOnly` and
    /// `narrowOnly` so the direction rule stays here.
    var lowerOnlyRows: [QuietSetting] { get }
}

/// The inner-life lanes the Settings page and the Cognition page switch one
/// at a time, each through its own runtime setter.
public enum QuietCognitionLane: Sendable {
    case capsule, background, reflection, organism
    /// Phase 5 D: opinions and interests (`personality.views_experiment`).
    case viewsExperiment
}

/// One proactive-inbox trigger as the Notifications page lists it.
public struct QuietInboxTrigger: Sendable {
    public let name: String
    public let enabled: Bool
    /// The folders `file_watch` watches; empty for every other trigger.
    public let paths: [String]

    public init(name: String, enabled: Bool, paths: [String]) {
        self.name = name
        self.enabled = enabled
        self.paths = paths
    }
}

/// One model an account offers, with the thinking levels it takes — the
/// list the Providers page and the composer pick from.
public struct QuietProviderModel: Sendable {
    public let id: String
    public let defaultEffort: String
    public let efforts: [String]
    public let supportsFast: Bool

    public init(id: String, defaultEffort: String, efforts: [String], supportsFast: Bool) {
        self.id = id
        self.defaultEffort = defaultEffort
        self.efforts = efforts
        self.supportsFast = supportsFast
    }
}

public struct QuietProviderAccount: Sendable {
    public let id: String
    public let authState: String
    public let models: [QuietProviderModel]

    public init(id: String, authState: String, models: [QuietProviderModel]) {
        self.id = id
        self.authState = authState
        self.models = models
    }
}

public enum QuietTrustPresetOutcome: Sendable {
    case confirmationRequired
    case applied
    case failed(String)
}
