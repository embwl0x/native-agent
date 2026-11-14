import Context
import Foundation
import PersistenceCore
import NativeAgentShared
import ProviderRouting
import TrustCenter
// Blueprint: | `QuietSettingsHost.swift` | Settings owner ports, mounted platform control declarations and asynchronous phone-owned control resolution |

/// Settings values and mutations share the page's observed state and UI actions.
@MainActor
public protocol QuietSettingsHost: AnyObject {
    var dataRootOverride: URL? { get }
    var trustPolicy: TrustPolicy? { get }
    var personality: PersonalityProfile? { get }
    var personalityError: String? { get }
    var dreamError: String? { get }
    var chatModel: String { get set }
    var chatReasoningEffort: String { get set }
    var chatFastMode: Bool { get set }
    var chatFileAccess: String { get }
    var chatProvider: String { get }
    var searchServiceURL: String { get }
    /// Controls owned by the mounted app (for example its shortcut manager). Declared beside those owners, then used by every settings reader/writer.
    var platformSettings: [QuietSetting] { get }
    /// A phone owns its local controls. Resolve them through its signed request channel; no Mac defaults or cached phone state stand in for its answer.
    func phoneSetting(id: String) async throws -> QuietSetting?

    func saveChatBrainDefaultsFailure() async -> String?
    func saveMacControlPolicy(
        _ policy: MacControlPolicyWireSnapshot,
        comparedTo baseline: MacControlPolicyWireSnapshot,
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
        _ preset: MobileTrustAction.Preset,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async -> QuietTrustPresetOutcome
    func saveMultimodalPolicy(
        field: String, enabled: Bool,
        guardedByLockedPolicy: @escaping @Sendable ([String: JSONValue]) throws -> Void
    ) async throws -> TrustPolicy
    func dreamEnabled() async throws -> Bool
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool
    func savePersonalityChecked(_ profile: PersonalityProfile) async throws
    func patchMemoryPolicy(knowledgeGraphEnabled: Bool?, adaptivePromotion: Bool?) async -> Bool
    func saveMemoryPolicy(crossSessionRecall: Bool) async

    // Live switches must both persist the key and notify the running app through their page-owned setters.
    /// Report the effective inner life with a reason when the requested state did not take effect.
    func setInnerLifeEnabled(_ enabled: Bool) async -> (enabled: Bool, problem: String?)
    func setCognitionLane(_ lane: QuietCognitionLane, enabled: Bool) async
    func setReflectionBudget(_ budget: Int) async
    /// The mode in effect after the write, which setup or safety can hold off.
    func setContextFlowMode(_ mode: ContextFlowMode) async throws -> ContextFlowMode
    func setGlobalHotkeyEnabled(_ enabled: Bool)
    func savePersonalityName(_ name: String) async -> String?
    func saveSearchServiceURL(_ url: String) async throws
    func findSearchService(context: QuietSettingWrite) async throws -> String
    func inboxTriggers() async throws -> [QuietInboxTrigger]
    func setInboxTrigger(_ name: String, enabled: Bool) async throws
    /// Platform-owned lower-only rows retain Core's lowerOnly/narrowOnly direction rules.
    func lowerOnlyRows(forPage page: String?) throws -> [QuietSetting]
}

/// Each inner-life lane uses its own runtime setter, shared by Settings and Cognition.
public enum QuietCognitionLane: Sendable {
    case capsule, background, reflection, organism
}

public struct QuietInboxTrigger: Sendable {
    public let name: String
    public let enabled: Bool
    public init(name: String, enabled: Bool) {
        self.name = name
        self.enabled = enabled
    }
}

/// Providers and composer share each account's offered models and declared thinking levels.
public struct QuietProviderModel: Sendable {
    public let id: String
    public let defaultEffort: String
    public let efforts: [String]
    public let supportsFast: Bool
    public let reasoningCapabilitiesKnown: Bool
    /// False for a build row standing where the provider's list is missing: its controls read here, but it is not a choice.
    public let offered: Bool
    /// What a choice of it is refused with: the account's own sentence.
    public let refusal: String?

    public init(id: String, defaultEffort: String, efforts: [String], supportsFast: Bool, reasoningCapabilitiesKnown: Bool = true,
                offered: Bool = true, refusal: String? = nil) {
        self.id = id
        self.defaultEffort = defaultEffort
        self.efforts = efforts
        self.supportsFast = supportsFast
        self.reasoningCapabilitiesKnown = reasoningCapabilitiesKnown
        self.offered = offered
        self.refusal = refusal
    }
}

public struct QuietProviderAccount: Sendable {
    public let id: String
    public let authState: String
    /// ProviderRouting's published eligibility; `authState` is never read for it.
    public let eligible: Bool
    public let models: [QuietProviderModel]

    public init(id: String, authState: String, eligible: Bool, models: [QuietProviderModel]) {
        self.id = id
        self.authState = authState
        self.eligible = eligible
        self.models = models
    }
}

public enum QuietTrustPresetOutcome: Sendable {
    case confirmationRequired
    case applied
    case failed(String)
}
