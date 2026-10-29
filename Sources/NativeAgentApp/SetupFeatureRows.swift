import MemoryV2

// Blueprint: | `SetupFeatureRows.swift` | `SetupFeatureRows`: settings-page controls over existing cognition/context/dream/memory/embedding owners; no new settings store |
// Every switch writes through its existing owner; no row owns a setting.
//
// The inner-life master's switch is SetupView's (it carries the runtime's
// status and recovery); this card puts it first, over the lanes it owns.

import Cognition
import SwiftUI
import Context
import TrustCenter

struct SetupFeatureRows<InnerLife: View>: View {
    @Environment(AppModel.self) private var appModel
    /// "An inner life", at the head of its own card, unfolded.
    private let innerLife: InnerLife

    init(@ViewBuilder innerLife: () -> InnerLife) {
        self.innerLife = innerLife()
    }

    // Same keys the Subconscious section and the Observatory bind, so no two
    // surfaces can show different truth.
    @AppStorage("cognitiveSubstrateEnabled") private var subconsciousEnabled = true
    @AppStorage("cognitiveSubstrateReflectionEnabled") private var reflectionEnabled = false
    @AppStorage("organismKernelEnabled") private var organismEnabled = false
    @AppStorage("contextFlowMode") private var contextFlowMode = ContextFlowMode.active.rawValue
    @AppStorage("selfImprovementEnabled") private var selfImprovementEnabled = true

    // Pending edits reconcile from their owners after every save.
    @State private var pendingDream: Bool?
    @State private var savingDream = false
    @State private var pendingRem: Bool?
    private var embeddingSnapshot: EmbeddingRuntimeSnapshot? { appModel.engine.memory.embeddingSnapshot }
    @State private var savingEmbeddings = false
    @State private var pendingEmbeddings: Bool?
    @State private var savingContextFlow = false

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            AdvancedSection(title: "Inner life") {
                innerLife
                reflectionRow
                organismRow
                fluidContextRow
                dreamsRow
                weeklyConsolidationRow
                selfImprovementRow
            }
            AdvancedSection(title: "Memory") {
                meaningMemoryRow
                LivingMemoryPermissionsView()
            }
        }
        .task { await load() }
    }

    // MARK: - Reflection (cognitiveSubstrateReflectionEnabled)

    private var reflectionRow: some View {
        SetupSwitchCard(
            title: "Reflection between conversations",
            sentence: subconsciousEnabled
                ? "Between conversations I think back over what happened and keep what matters."
                : "Turn on an inner life first — reflection runs inside it.",
            identifier: "setup.feature.cognitiveSubstrateReflectionEnabled",
            isOn: Binding(
                get: { reflectionEnabled },
                set: { value in
                    reflectionEnabled = value
                    Task { await NativeAgentEngine.liveCognition.setReflectionEnabled(value) }
                }
            ),
            disabled: !subconsciousEnabled
        )
    }

    // MARK: - Organism (organismKernelEnabled)

    private var organismRow: some View {
        SetupSwitchCard(
            title: "Moods, energy, and a clock of my own",
            sentence: subconsciousEnabled
                ? "I get moods, tiredness, and a clock that keeps running while you are away."
                : "Turn on an inner life first to enable moods, energy, and a daily rhythm.",
            identifier: "setup.feature.organismKernelEnabled",
            isOn: Binding(
                get: { organismEnabled },
                set: { value in
                    organismEnabled = value
                    Task { await NativeAgentEngine.liveCognition.setOrganismKernelEnabled(value) }
                }
            ),
            disabled: !subconsciousEnabled
        )
    }

    // MARK: - Memory in every reply (contextFlowMode)

    /// Context flow uses a menu so Off remains reversible.
    private var fluidContextRow: some View {
        SetupRow(
            title: "Memory in every reply",
            detail: "What I remember shapes each reply."
        ) {
            Picker("Memory in every reply", selection: Binding(
                get: { ContextFlowMode(rawValue: contextFlowMode) ?? .active },
                set: { mode in
                    contextFlowMode = mode.rawValue
                    Task { await setFluidContext(mode) }
                }
            )) {
                ForEach([ContextFlowMode.off, .active], id: \.rawValue) { mode in
                    Text(OperationalSettingsControlPresentation.fluidContextLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(savingContextFlow)
            .accessibilityIdentifier("setup.feature.contextFlowMode")
        }
    }

    @MainActor
    private func setFluidContext(_ requested: ContextFlowMode) async {
        savingContextFlow = true
        defer { savingContextFlow = false }
        let status = await NativeAgentEngine.live.contextFlow.setMode(requested)
        if status.effectiveMode != requested {
            appModel.systemToasts.push(
                warn: "Fluid context is effectively \(OperationalSettingsControlPresentation.fluidContextLabel(status.effectiveMode)) right now."
            )
        }
    }

    // MARK: - Dreams (personalityPolicy.dream_cycle_enabled + trainingPolicy.dream_scheduler)

    private var dreamsRow: some View {
        SetupSwitchCard(
            title: "Dreams at night",
            sentence: "At night I go back over the day and write down what I made of it.",
            identifier: "setup.feature.dream_cycle_enabled",
            isOn: Binding(
                get: { pendingDream ?? (appModel.engine.cognitionView.diaryGate?.dreamEnabled == true) },
                set: { value in
                    guard !savingDream else { return }
                    pendingDream = value
                    savingDream = true
                    Task { await setDreams(value) }
                }
            ),
            disabled: savingDream || appModel.engine.cognitionView.diaryGate == nil
        )
    }

    @MainActor
    private func setDreams(_ value: Bool) async {
        // ONE call: the two gates move together, and this is the composite
        // write the Dreams page makes.
        let ok = await appModel.setDreamCycleEnabled(value)
        await appModel.engine.cognitionView.refreshDiary()
        pendingDream = nil
        if !ok {
            appModel.systemToasts.push(
                error: appModel.dreamError ?? "The dream setting could not be saved."
            )
        }
        savingDream = false
    }

    // MARK: - Weekly consolidation (trainingPolicy.rem_cycle_enabled)

    private var weeklyConsolidationRow: some View {
        SetupSwitchCard(
            title: "Weekly dream consolidation",
            sentence: "Once a week I gather the week's memories into fewer, stronger ones.",
            identifier: "setup.feature.rem_cycle_enabled",
            isOn: Binding(
                get: { pendingRem ?? remEnabledInPolicy },
                set: { value in
                    guard pendingRem == nil else { return }
                    pendingRem = value
                    Task {
                        let ok = await appModel.setRemCycleEnabled(value)
                        pendingRem = nil
                        if !ok {
                            appModel.systemToasts.push(
                                error: appModel.dreamError ?? "The weekly consolidation setting could not be saved."
                            )
                        }
                    }
                }
            ),
            disabled: pendingRem != nil
        )
    }

    private var remEnabledInPolicy: Bool {
        appModel.engine.trust.policy?.trainingPolicy?.rem_cycle_enabled == true
    }

    // MARK: - Meaning-based memory (the embeddings backend)

    /// The switch binds the requested backend and confirms before rebuilding memory lookup.
    private var meaningMemoryRow: some View {
        SetupSwitchCard(
            title: "Meaning-based memory",
            sentence: meaningMemoryDetail,
            identifier: "setup.feature.embeddings",
            isOn: Binding(
                get: { pendingEmbeddings ?? embeddingSnapshot.map { $0.requestedBackend != ManagedEmbeddingProvider.mockBackend } ?? false },
                set: { value in
                    guard !savingEmbeddings, value != embeddingSnapshot.map({ $0.requestedBackend != ManagedEmbeddingProvider.mockBackend }) else { return }
                    pendingEmbeddings = value
                }
            ),
            disabled: savingEmbeddings || embeddingSnapshot == nil
        )
        .confirmationDialog(
            pendingEmbeddings == true ? "Turn on meaning-based memory?" : "Turn off meaning-based memory?",
            isPresented: Binding(
                get: { pendingEmbeddings != nil },
                set: { if !$0 { pendingEmbeddings = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingEmbeddings == true ? "Turn on and re-index" : "Turn off and re-index") {
                if let value = pendingEmbeddings {
                    pendingEmbeddings = nil
                    Task { await setEmbeddings(value) }
                }
            }
            Button("Cancel", role: .cancel) { pendingEmbeddings = nil }
        } message: {
            Text("I re-read every memory to rebuild how I find them. That can take a while, and memory stays available meanwhile.")
        }
    }

    @MainActor
    private func setEmbeddings(_ value: Bool) async {
        savingEmbeddings = true
        do {
            try await appModel.engine.memory.toggleEmbeddings(value)
        } catch {
            appModel.systemToasts.push(
                error: UserFacingError.message(error, action: "change how memory is searched")
            )
        }
        savingEmbeddings = false
    }

    /// The detail line says what is TRUE right now, not what was asked for.
    private var meaningMemoryDetail: String {
        guard let status = embeddingSnapshot else {
            return appModel.engine.memory.embeddingsError ?? "Checking how I look things up right now."
        }
        if savingEmbeddings {
            return "Re-indexing every memory. This can take a while."
        }
        switch status.effectiveBackend {
        case ManagedEmbeddingProvider.coreMLBackend:
            return "On — I find memories by what they mean, not by the words in them."
        case ManagedEmbeddingProvider.failClosedBackend where status.requestedBackend != ManagedEmbeddingProvider.mockBackend:
            return "Asked for, but the on-device model could not be loaded; I match on words for now."
        default:
            return "Off — I match memories on their words alone."
        }
    }

    // MARK: - Weekly self-improvement (selfImprovementEnabled)

    private var selfImprovementRow: some View {
        SetupSwitchCard(
            title: "Weekly self-improvement pass",
            sentence: "Once a week I review how things actually went and propose safe changes.",
            identifier: "setup.feature.selfImprovementEnabled",
            isOn: $selfImprovementEnabled
        )
    }


    // MARK: - Loading and reconciliation

    @MainActor
    private func load() async {
        // The policy carries the REM gate and the whole memory policy. Setup
        // loads it too; this only fills the gap when these rows are mounted
        // before that read lands.
        if appModel.engine.trust.policy == nil {
            _ = try? await appModel.engine.trust.load()
        }
        await appModel.engine.cognitionView.refreshDiary()
        await appModel.engine.memory.loadEmbeddings()
    }

}
