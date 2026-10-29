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
    /// Read the configured user name from `<dataRoot>/memory/profile.json`
    /// (`userName`, written at onboarding). Tolerant of a missing/malformed file.
    public nonisolated static func resolveUserName(dataRoot: URL) -> String {
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
        return SwiftNativeKnowledgeGraphIndexer.profileNames(profileURL: path).user ?? ""
    }

    var reachEnabled: Bool {
        let configuration = Self.loadConfiguration(
            defaults: preferenceDefaults, environment: configurationEnvironment)
        return !isFlushedForTermination && configuration.enabled && configuration.backgroundMicrocyclesEnabled
    }

    public func refreshConfiguration() async {
        sourceWakes.canonDirty = true
        sourceWakes.horizonDirty = true
        sourceWakes.reachDirty = true
        withdrawReachIfDisabled()
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
            // Provider files are authoritative for reflection. Corruption closes
            // only the provider-using lane instead of silently reviving a stale
            // UserDefaults route.
            configuration.reflectiveCallsEnabled = false
            providerRoutingFailure = "cognitive provider state unavailable: \(error.localizedDescription)"
        }
        await substrate.configure(configuration)
        // The promoter is process-wide: only the canonical-root runtime may
        // install its entire interpretation binding, including the callbacks.
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            await AdaptiveMemoryPromoter.shared.configureInterpretation(
                isIdle: { [weak self] in
                    guard let self else { return false }
                    return await self.liveTurnLatchCount() == 0
                },
                finish: { [weak self] context, interpretation, momentID in
                    // True when the mind's and body's shares both landed.
                    await self?.foldTurnMoment(context, interpretation: interpretation, momentID: momentID) ?? false
                },
                door: livedMomentDoor()
            )
        }
        // A verdict the
        // mind turns away never reaches the body, so it amends its own
        // appraisal row from here, with the same fields a body outcome writes.
        await substrate.setCaringRefusalRecorder { [weak self] session, turn, why in
            guard let self else { return }
            await CaringReceiptLog.shared.amendReceiptRefused(
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
        // Configuration replaces the pushed clock. Invalidate after that await
        // so a concurrent body read cannot consume the invalidation too early.
        sourceWakes.clockDirty = true
        await somaticSignalBus.configure(organismConfiguration)
    }

    public func setEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.enabledKey)
        await refreshConfiguration()
        if enabled { await bootstrap() }
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

    /// The user-facing Subconscious switch is one transaction over the
    /// existing cognition and organism owners. Keeping this composition here
    /// prevents UI call sites from omitting a lane or triggering a cascade of
    /// redundant configuration reloads and invalidations.
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
                // A launch with the inner life off read none of her substrate;
                // waking reads it once (seeding and migrating her cares) and
                // reads her recent life if that is still owed. A substrate
                // already read keeps its resident state (restore runs once),
                // and the body, restored dormant at the opening, is never
                // reloaded over.
                await bootstrap()
                await enterDoor()
                defer { leaveDoor() }
                do {
                    try await substrate.restorePersistentState()
                    bootstrapFailure = nil
                } catch {
                    bootstrapFailure = "cognitive restore failed: \(error.localizedDescription)"
                    await substrate.recordReceipt(
                        kind: "lifecycle.restore_failed",
                        payload: .object(["error": .string(String(describing: error))])
                    )
                }
                if !isFlushedForTermination, recentLifeTask == nil {
                    recentLifeTask = Task {
                        await self.readRecentLifeIntoCaresIfOwed()
                        self.recentLifeTask = nil
                    }
                }
                await refreshOrganismBodySchema(reason: "subconscious enabled")
                await persistOrganismContinuity(reason: "subconscious enabled")
                // Desk changes while she was off did not reach the work projection;
                // waking reads the Desk once.
                await startPursuitRefresh()
            } else {
                await bootstrap()
            }
        }
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

    /// Setup completion and launch share the explicit switch's preference
    /// transaction, but automatic initialization never replaces a saved choice.
    /// The independent hour preference is deliberately not part of this master.
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
        // Write the master last so an interrupted initialization can resume.
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
        // The personality ships on, reflection included; off is a choice.
        let reflectionEnabled = enabled && (
            defaults.object(forKey: reflectionKey) as? Bool ?? true
                || env["NATIVE_AGENT_COGNITION_REFLECTION_ENABLED"] == "1"
        )
        // Rolling 24h cost ceiling; admission is load.
        let budgetDefault = reflectionEnabled ? 2 : 0
        let storedBudget = defaults.object(forKey: reflectionBudgetKey) as? Int
        let budget = max(0, storedBudget ?? budgetDefault)
        let storedLoadThreshold = defaults.object(forKey: reflectionLoadThresholdKey) as? Double
        return CognitiveConfiguration(
            enabled: enabled,
            persistenceEnabled: enabled,
            capsuleInjectionEnabled: capsuleEnabled,
            backgroundMicrocyclesEnabled: backgroundEnabled,
            reflectiveCallsEnabled: reflectionEnabled,
            maximumActiveNodes: 256,
            defaultDecayHalfLife: 60 * 60,
            maximumCapsuleCharacters: 4_000,
            maximumWorkspaceItems: 12,
            dailyReflectionCallBudget: budget,
            reflectionLoadThreshold: storedLoadThreshold ?? CognitiveConfiguration().reflectionLoadThreshold,
            reflectionSurface: "cognition_reflection"
        )
    }

    nonisolated static func organismConfigurationForLaunch(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedEnabled: Bool? = nil,
        storedSubconsciousEnabled: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> OrganismConfiguration {
        if NativeAgentPublicSafety.shouldForceNeutralOrganism(dataRoot: dataRoot, environment: environment) {
            return .disabled
        }
        let explicitOrganism = storedEnabled
            ?? (defaults.object(forKey: organismKernelEnabledKey) as? Bool)
        let subconsciousMaster = storedSubconsciousEnabled
            ?? (defaults.object(forKey: enabledKey) as? Bool)
        let enabled = (explicitOrganism ?? subconsciousMaster ?? false)
            || environment["NATIVE_AGENT_ORGANISM_KERNEL_ENABLED"] == "1"
        return OrganismConfiguration(enabled: enabled)
    }

    static func loadOrganismConfiguration(
        dataRoot: URL,
        defaults: UserDefaults = .standard
    ) -> OrganismConfiguration {
        reconcileOrganismPreferenceForLaunch(dataRoot: dataRoot, defaults: defaults)
    }

    /// Existing installs can predate the organism preference while already
    /// having the Subconscious master enabled. Inherit that master exactly
    /// once. An explicit organism choice always wins, and public clean-room
    /// safety remains authoritative before onboarding.
    nonisolated static func reconcileOrganismPreferenceForLaunch(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> OrganismConfiguration {
        let storedOrganism = defaults.object(forKey: organismKernelEnabledKey) as? Bool
        let storedMaster = defaults.object(forKey: enabledKey) as? Bool
        let configuration = organismConfigurationForLaunch(
            dataRoot: dataRoot,
            environment: environment,
            storedEnabled: storedOrganism,
            storedSubconsciousEnabled: storedMaster,
            defaults: defaults
        )
        if storedOrganism == nil,
           storedMaster == true,
           configuration.enabled,
           !NativeAgentPublicSafety.shouldForceNeutralOrganism(
               dataRoot: dataRoot,
               environment: environment
           ) {
            defaults.set(true, forKey: organismKernelEnabledKey)
        }
        return configuration
    }


    static func configurationWithoutPersistence(_ configuration: CognitiveConfiguration) -> CognitiveConfiguration {
        var copy = configuration
        copy.persistenceEnabled = false
        return copy
    }



    private static let enabledKey = "cognitiveSubstrateEnabled"
    private static let capsuleKey = "cognitiveSubstrateCapsuleEnabled"
    private static let backgroundKey = "cognitiveSubstrateBackgroundEnabled"
    private static let reflectionKey = "cognitiveSubstrateReflectionEnabled"
    private static let reflectionBudgetKey = "cognitiveSubstrateDailyReflectionBudget"
    /// Unresolved-load admission threshold for spontaneous reflection. No UI
    /// knob: the ceiling is what User steers; this is the shape's tuning seam.
    private static let reflectionLoadThresholdKey = "cognitiveSubstrateReflectionLoadThreshold"
    static let organismKernelEnabledKey = "organismKernelEnabled"
}
