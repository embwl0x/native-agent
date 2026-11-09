import Foundation
import CognitiveSubstrate
import Context
import ContextFlow
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
import ApprovalInbox
import ChatToolRuntime
import AgentConversations
import Desk
import Experiences
import AuthoredCapabilities
import NativeAgentShared
import Studio
import Transcripts
// Blueprint: | `NativeCognitionRuntime+Preferences.swift` | `NativeCognitionRuntime` preferences, checked configuration refresh and onboarding transitions |

extension NativeCognitionRuntime {
    /// An unreadable existing profile throws rather than inventing an onboarding name.
    public nonisolated static func resolveUserName(dataRoot: URL) throws -> String {
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
        return try SwiftNativeKnowledgeGraphIndexer.profileNames(profileURL: path).user ?? ""
    }

    var backgroundThinkingEnabled: Bool {
        let configuration = Self.loadConfiguration(
            defaults: preferenceDefaults, environment: configurationEnvironment)
        return !isFlushedForTermination && configuration.enabled && configuration.backgroundMicrocyclesEnabled
    }

    public func refreshConfiguration() async {
        sourceWakes.canonDirty = true
        sourceWakes.horizonDirty = true
        if NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot),
           preferenceDefaults.object(forKey: Self.enabledKey) == nil {
            let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
            if let snapshot = try? await routing.checkedRoutingSnapshot(),
               let providerID = snapshot.activeProviders["chat"],
               let provider = try? await routing.getProvider(id: providerID),
               provider.configured == true {
                Self.initializeMissingInnerLifePreferences(
                    dataRoot: dataRoot, providerReady: true, defaults: preferenceDefaults
                )
                if usesLiveAppBody {
                    await contextFlow.reloadConfiguration()
                }
            }
        }
        var configuration = Self.loadConfiguration(
            defaults: preferenceDefaults,
            environment: configurationEnvironment
        )
        do {
            let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
            _ = try await routing.checkedRoutingSnapshot()
            providerRoutingFailure = nil
        } catch {
            // Provider files own reflection routing; corrupt files close that route rather than reviving stale defaults.
            configuration.reflectiveCallsEnabled = false
            providerRoutingFailure = "cognitive provider state unavailable: \(error.localizedDescription)"
        }
        await substrate.configure(configuration)
        // Only the canonical-root runtime may install the process-wide interpretation binding and callbacks.
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            await AdaptiveMemoryPromoter.shared.configureInterpretation(
                isIdle: { [weak self] in
                    guard let self else { return false }
                    return await !self.liveTurnInFlight
                },
                finish: { [weak self] context, interpretation, momentID in
                    await self?.foldTurnMoment(context, interpretation: interpretation, momentID: momentID) ?? false
                },
                door: livedMomentDoor()
            )
        }
        // A verdict refused by the mind never reaches the body, so amend its appraisal receipt at this boundary.
        await substrate.setCaringRefusalRecorder { [weak self] session, turn, why in
            guard let self else { return }
            await self.caringReceiptLog.amendReceiptRefused(
                session: session,
                turn: turn,
                why: why,
                tendernessAfter: await self.organismKernel.snapshot().chemicalState.tenderness
            )
        }
        let organismConfiguration = Self.loadOrganismConfiguration(
            dataRoot: dataRoot,
            defaults: preferenceDefaults
        )
        await organismKernel.configure(organismConfiguration)
        // Invalidate after replacing the clock so a concurrent read cannot consume invalidation before the new state exists.
        sourceWakes.clockDirty = true
        await somaticSignalBus.configure(organismConfiguration)
        await resumeAttentionIfEnabled()
    }

    private func resumeAttentionIfEnabled() async {
        guard backgroundThinkingEnabled, attention.opened, await substrate.hasRestoredAttention() else { return }
        await igniteReady(mode: "awake")
        await weighWaiting(mode: "awake")
    }

    public func setEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.enabledKey)
        await refreshConfiguration()
        if enabled { await bootstrap() }
        await resumeAttentionIfEnabled()
        publishRuntimeChange(reason: "configuration:enabled")
    }

    public func setCapsuleEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.capsuleKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:capsule")
    }

    public func setBackgroundEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.backgroundKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:background")
    }

    public func setReflectionEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.reflectionKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:reflection")
    }



    public func setReflectionBudget(_ budget: Int) async {
        preferenceDefaults.set(max(0, budget), forKey: Self.reflectionBudgetKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:reflection_budget")
    }

    /// Compose the Subconscious preference transaction here so UI callers cannot omit an owner or trigger redundant reloads.
    public func setSubconsciousMasterEnabled(
        _ enabled: Bool,
        reflectionBudget: Int
    ) async -> NativeSubconsciousRuntimeState {
        Self.writeInnerLifePreferences(
            enabled: enabled, reflectionBudget: reflectionBudget,
            defaults: preferenceDefaults, onlyMissing: false
        )

        let alreadyBootstrapped = bootstrapTask != nil
        await refreshConfiguration()
        if enabled {
            if alreadyBootstrapped {
                // Read dormant substrate once on waking; never reload resident substrate or the body already restored during opening.
                await bootstrap()
                await enterDoor()
                defer { leaveDoor() }
                do {
                    if let cognitiveStoreOpeningFailure {
                        throw PersistenceCoreError.ioFailure(cognitiveStoreOpeningFailure)
                    }
                    try await substrate.restorePersistentState()
                    bootstrapFailure = nil
                } catch {
                    bootstrapFailure = "cognitive restore failed: \(error.localizedDescription)"
                    await substrate.recordReceipt(
                        kind: "lifecycle.restore_failed",
                        payload: .object(["error": .string(String(describing: error))])
                    )
                }
                await refreshOrganismBodySchema(reason: "subconscious enabled")
                await persistOrganismContinuity(reason: "subconscious enabled")
                // Refresh Desk on waking because disabled-time edits did not reach its projection.
                await startPursuitRefresh()
            } else {
                await bootstrap()
            }
        }
        await resumeAttentionIfEnabled()
        await rescheduleResidualRepairDeadline()
        await rescheduleCognitionMaintenanceDeadline()
        publishRuntimeChange(reason: "configuration:subconscious_master")
        return await subconsciousRuntimeState()
    }

    public func refreshAfterOnboardingTransition() async -> NativeSubconsciousRuntimeState {
        await bootstrap()
        await refreshConfiguration()
        let organism = await organismKernel.snapshot()
        if organism.enabled {
            await refreshOrganismBodySchema(reason: "onboarding transition")
            await persistOrganismContinuity(reason: "onboarding transition")
        } else {
            cachedBodyRead = nil
        }
        await rescheduleResidualRepairDeadline()
        await rescheduleCognitionMaintenanceDeadline()
        publishRuntimeChange(reason: "configuration:onboarding_transition")
        return await subconsciousRuntimeState()
    }

    /// Automatic setup shares the explicit preference transaction but cannot replace saved choice; the hour preference remains independent.
    nonisolated static func initializeMissingInnerLifePreferences(
        dataRoot: URL, providerReady: Bool, defaults: UserDefaults
    ) {
        guard providerReady,
              NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot),
              defaults.object(forKey: enabledKey) == nil else { return }
        NativeContextFlowConfiguration.initializeMissingInnerLifeMode(defaults: defaults)
        writeInnerLifePreferences(
            enabled: true, reflectionBudget: 2, defaults: defaults, onlyMissing: true
        )
    }

    private nonisolated static func writeInnerLifePreferences(
        enabled: Bool, reflectionBudget: Int, defaults: UserDefaults, onlyMissing: Bool
    ) {
        for key in [capsuleKey, backgroundKey, reflectionKey, organismKernelEnabledKey] {
            if !onlyMissing || defaults.object(forKey: key) == nil {
                defaults.set(enabled, forKey: key)
            }
        }
        if !onlyMissing || defaults.object(forKey: reflectionBudgetKey) == nil {
            defaults.set(enabled ? max(1, reflectionBudget) : 0, forKey: reflectionBudgetKey)
        }
        // Write the master preference last so interrupted initialization can resume.
        if !onlyMissing || defaults.object(forKey: enabledKey) == nil {
            defaults.set(enabled, forKey: enabledKey)
        }
    }

    static func loadConfiguration(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CognitiveConfiguration {
        let env = environment
        let enabled = (defaults.object(forKey: enabledKey) == nil
            || defaults.bool(forKey: enabledKey))
            || env["NATIVE_AGENT_COGNITION_ENABLED"] == "1"
        let capsuleEnabled = enabled && (
            defaults.object(forKey: capsuleKey) as? Bool ?? true
        )
        let backgroundEnabled = enabled && (
            defaults.object(forKey: backgroundKey) as? Bool ?? true
        )
        // Ship inner life and reflection enabled; disabling them is a saved choice.
        let reflectionEnabled = enabled && (
            defaults.object(forKey: reflectionKey) as? Bool ?? true
                || env["NATIVE_AGENT_COGNITION_REFLECTION_ENABLED"] == "1"
        )
        // Dream, replay and requested reflection share the rolling 24-hour cost ceiling.
        let budgetDefault = reflectionEnabled ? 2 : 0
        let storedBudget = defaults.object(forKey: reflectionBudgetKey) as? Int
        let budget = max(0, storedBudget ?? budgetDefault)
        return CognitiveConfiguration(
            enabled: enabled,
            persistenceEnabled: enabled,
            capsuleInjectionEnabled: capsuleEnabled,
            backgroundMicrocyclesEnabled: backgroundEnabled,
            reflectiveCallsEnabled: reflectionEnabled,
            maximumActiveNodes: 256,
            defaultDecayHalfLife: CognitiveConfiguration.turnHalfLife,
            maximumCapsuleCharacters: 4_000,
            maximumWorkspaceItems: 12,
            dailyReflectionCallBudget: budget,
            reflectionSurface: "cognition_reflection"
        )
    }

    nonisolated static func organismConfigurationForLaunch(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedEnabled: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> OrganismConfiguration {
        if NativeAgentPublicSafety.shouldForceNeutralOrganism(dataRoot: dataRoot, environment: environment) {
            return .disabled
        }
        let explicitOrganism = storedEnabled
            ?? (defaults.object(forKey: organismKernelEnabledKey) as? Bool)
        let enabled = (explicitOrganism ?? false)
            || environment["NATIVE_AGENT_ORGANISM_KERNEL_ENABLED"] == "1"
        return OrganismConfiguration(enabled: enabled)
    }

    static func loadOrganismConfiguration(
        dataRoot: URL,
        defaults: UserDefaults = .standard
    ) -> OrganismConfiguration {
        organismConfigurationForLaunch(dataRoot: dataRoot, defaults: defaults)
    }




    private static let enabledKey = "cognitiveSubstrateEnabled"
    private static let capsuleKey = "cognitiveSubstrateCapsuleEnabled"
    private static let backgroundKey = "cognitiveSubstrateBackgroundEnabled"
    private static let reflectionKey = "cognitiveSubstrateReflectionEnabled"
    private static let reflectionBudgetKey = "cognitiveSubstrateDailyReflectionBudget"
    static let organismKernelEnabledKey = "organismKernelEnabled"
}
