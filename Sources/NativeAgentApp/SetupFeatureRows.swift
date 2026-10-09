// THE REST OF THE FOUR THINGS, ON THE SETUP PAGE.
//
// Every switch here writes exactly the storage its old control wrote — the
// substrate lanes (Cognition Observatory), Fluid Context (Settings ▸
// Subconscious), the dream and REM gates (Dreams), the memory policy (Trust ▸
// Living memory), the embeddings backend and memory mode (Settings ▸ Memory)
// and the weekly self-improvement key. Nothing here owns a setting of its own,
// and no row invents a second home for one.
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

    // Optimistic local mirrors for the writes that go over the trust policy or
    // the memory runtime, so a switch does not snap back mid-round-trip.
    // Reconciled from the source of truth after every save.
    @State private var dreamCycleOn = false
    @State private var savingDream = false
    @State private var remCycleOn = true
    @State private var savingRem = false
    @State private var memoryDraft = TrustMemoryPolicy()
    @State private var savingMemory = false
    @State private var embeddingsStatus: EmbeddingsStatus?
    @State private var embeddingsOn = false
    @State private var savingEmbeddings = false
    @State private var pendingEmbeddings: Bool?
    @State private var savingContextFlow = false

    var body: some View {
        // Alive glass (2026-09-23): the section's fourteen rows in two group
        // cards, the inner life and then memory, where each was its own card.
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
                knowledgeGraphRow
                nightlyConsolidationRow
                keepConsolidatedRow
                adaptivePromotionRow
                hygieneRow
                crossSessionRecallRow
            }
        }
        .task { await load() }
        // The policy is one document: a save anywhere in the app re-publishes
        // it, and these rows follow it rather than keeping their own copy.
        .onChange(of: appModel.engine.trust.policy) { _, _ in
            syncFromTrustPolicy()
            // The dream gate is a composite the policy only half carries;
            // re-read it the way the Dreams page does.
            guard !savingDream else { return }
            Task { @MainActor in dreamCycleOn = await appModel.engine.cognitionView.dreamEnabled() }
        }
    }

    // MARK: - Reflection (cognitiveSubstrateReflectionEnabled)

    private var reflectionRow: some View {
        SetupFeatureSwitchRow(
            title: "Reflection between conversations",
            detail: subconsciousEnabled
                ? "Between conversations I think back over what happened and keep what matters."
                : "Turn on an inner life first — reflection runs inside it.",
            key: "cognitiveSubstrateReflectionEnabled",
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
        SetupFeatureSwitchRow(
            title: "Moods, energy, and a clock of my own",
            detail: subconsciousEnabled
                ? "I get moods, tiredness, and a clock that keeps running while you are away."
                : "Turn on an inner life first to enable moods, energy, and a daily rhythm.",
            key: "organismKernelEnabled",
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

    /// A menu, as the original control was: a switch cannot round-trip out
    /// of Off (the reviewer's catch, 2026-09-04).
    private var fluidContextRow: some View {
        SetupFeatureCard(
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
        SetupFeatureSwitchRow(
            title: "Dreams at night",
            detail: "At night I go back over the day and write down what I made of it.",
            key: "dream_cycle_enabled",
            isOn: Binding(
                get: { dreamCycleOn },
                set: { value in
                    guard !savingDream else { return }
                    dreamCycleOn = value          // optimistic — no snap-back
                    savingDream = true
                    Task { await setDreams(value) }
                }
            ),
            disabled: savingDream
        )
    }

    @MainActor
    private func setDreams(_ value: Bool) async {
        // ONE call: the two gates move together, and this is the composite
        // write the Dreams page makes.
        let ok = await appModel.setDreamCycleEnabled(value)
        if ok {
            // The gate is a composite of two policy fields; read it back the
            // way the Dreams page does rather than trusting the flip.
            dreamCycleOn = await appModel.engine.cognitionView.dreamEnabled()
        } else {
            dreamCycleOn = !value
            appModel.systemToasts.push(
                error: appModel.dreamError ?? "The dream setting could not be saved."
            )
        }
        savingDream = false
    }

    // MARK: - Weekly consolidation (trainingPolicy.rem_cycle_enabled)

    private var weeklyConsolidationRow: some View {
        SetupFeatureSwitchRow(
            title: "Weekly dream consolidation",
            detail: "Once a week I gather the week's memories into fewer, stronger ones.",
            key: "rem_cycle_enabled",
            isOn: Binding(
                get: { remCycleOn },
                set: { value in
                    guard !savingRem else { return }
                    remCycleOn = value            // optimistic — no snap-back
                    savingRem = true
                    Task {
                        let ok = await appModel.setRemCycleEnabled(value)
                        remCycleOn = ok ? remEnabledInPolicy : !value
                        if !ok {
                            appModel.systemToasts.push(
                                error: appModel.dreamError ?? "The weekly consolidation setting could not be saved."
                            )
                        }
                        savingRem = false
                    }
                }
            ),
            disabled: savingRem
        )
    }

    private var remEnabledInPolicy: Bool {
        appModel.engine.trust.policy?.trainingPolicy?.rem_cycle_enabled == true
    }

    // MARK: - Meaning-based memory (the embeddings backend)

    /// The switch reads what was ASKED for (`requestedEnabled`), which is the
    /// field the write changes; what is actually running is the detail line.
    /// Flipping it re-reads every memory to rebuild how they are found, so it
    /// asks first (the reviewer's catch, 2026-09-04).
    private var meaningMemoryRow: some View {
        SetupFeatureSwitchRow(
            title: "Meaning-based memory",
            detail: meaningMemoryDetail,
            key: "embeddings",
            isOn: Binding(
                get: { pendingEmbeddings ?? embeddingsOn },
                set: { value in
                    guard !savingEmbeddings, value != embeddingsOn else { return }
                    pendingEmbeddings = value
                }
            ),
            disabled: savingEmbeddings || embeddingsStatus == nil
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
        embeddingsOn = value
        do {
            let result = try await appModel.toggleEmbeddingsBackend(enabled: value)
            embeddingsStatus = result.status
            embeddingsOn = result.status.requestedEnabled
            if let error = result.error {
                appModel.systemToasts.push(error: error)
            }
        } catch {
            embeddingsOn = !value
            appModel.systemToasts.push(
                error: UserFacingError.message(error, action: "change how memory is searched")
            )
        }
        savingEmbeddings = false
    }

    /// The detail line says what is TRUE right now, not what was asked for.
    private var meaningMemoryDetail: String {
        guard let status = embeddingsStatus else {
            return "Checking how I look things up right now."
        }
        if savingEmbeddings {
            return "Re-indexing every memory. This can take a while."
        }
        switch status.effectiveBackend {
        case "local":
            return "On — I find memories by what they mean, not by the words in them."
        case "unavailable" where status.requestedEnabled:
            return "Asked for, but the on-device model could not be loaded; I match on words for now."
        default:
            return "Off — I match memories on their words alone."
        }
    }

    // MARK: - Memory policy (memoryPolicy.*)

    private var keepConsolidatedRow: some View {
        SetupFeatureSwitchRow(
            title: "Keep consolidated memories without asking",
            detail: "What the nightly pass gathers stays on its own; off, I ask you first.",
            key: "auto_promote_consolidated",
            isOn: Binding(
                get: { memoryDraft.auto_promote_consolidated },
                set: { value in
                    var next = memoryDraft
                    next.auto_promote_consolidated = value
                    memoryDraft = next
                    Task { await saveMemory(next, expecting: \.auto_promote_consolidated) }
                }
            ),
            disabled: savingMemory || !memoryDraft.consolidation_enabled
        )
    }

    private var hygieneRow: some View {
        SetupFeatureSwitchRow(
            title: "Memory hygiene",
            detail: "I tidy old, noisy, and duplicate memories on a schedule.",
            key: "hygiene_enabled",
            isOn: Binding(
                get: { memoryDraft.hygiene_enabled },
                set: { value in
                    var next = memoryDraft
                    next.hygiene_enabled = value
                    memoryDraft = next
                    Task { await patchMemory(hygiene: value) }
                }
            ),
            disabled: savingMemory
        )
    }

    private var knowledgeGraphRow: some View {
        SetupFeatureSwitchRow(
            title: "Knowledge graph",
            detail: "I join up the people, places, and things your conversations keep mentioning.",
            key: "knowledge_graph_enabled",
            isOn: Binding(
                get: { memoryDraft.knowledge_graph_enabled },
                set: { value in
                    var next = memoryDraft
                    next.knowledge_graph_enabled = value
                    memoryDraft = next
                    Task { await patchMemory(knowledgeGraph: value) }
                }
            ),
            disabled: savingMemory
        )
    }

    private var nightlyConsolidationRow: some View {
        SetupFeatureSwitchRow(
            title: "Memory consolidation",
            detail: "Once a week I gather what keeps coming up into fewer, stronger memories and offer them for review.",
            key: "consolidation_enabled",
            isOn: Binding(
                get: { memoryDraft.consolidation_enabled },
                set: { value in
                    var next = memoryDraft
                    next.consolidation_enabled = value
                    // Same clamp the Trust page makes: auto-promotion cannot
                    // outlive the consolidation pass that feeds it.
                    if !value { next.auto_promote_consolidated = false }
                    memoryDraft = next
                    Task { await saveMemory(next, expecting: \.consolidation_enabled) }
                }
            ),
            disabled: savingMemory
        )
    }

    private var adaptivePromotionRow: some View {
        SetupFeatureSwitchRow(
            title: "Memories that recur become facts",
            detail: "When something keeps coming back, I propose it as a durable fact for you to accept.",
            key: "adaptive_promotion",
            isOn: Binding(
                get: { memoryDraft.adaptive_promotion },
                set: { value in
                    var next = memoryDraft
                    next.adaptive_promotion = value
                    memoryDraft = next
                    Task { await patchMemory(adaptivePromotion: value) }
                }
            ),
            disabled: savingMemory
        )
    }

    private var crossSessionRecallRow: some View {
        SetupFeatureSwitchRow(
            title: "Remember across conversations",
            detail: "I bring in what is relevant from every past conversation, not just this one.",
            key: "cross_session_recall",
            isOn: Binding(
                get: { memoryDraft.cross_session_recall },
                set: { value in
                    var next = memoryDraft
                    next.cross_session_recall = value
                    memoryDraft = next
                    Task { await saveMemory(next, expecting: \.cross_session_recall) }
                }
            ),
            disabled: savingMemory
        )
    }

    // MARK: - Weekly self-improvement (selfImprovementEnabled)

    private var selfImprovementRow: some View {
        SetupFeatureSwitchRow(
            title: "Weekly self-improvement pass",
            detail: "Once a week I review how things actually went and propose safe changes.",
            key: "selfImprovementEnabled",
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
            appModel.engine.trust.policy = try? await appModel.engine.trust.load()
        }
        syncFromTrustPolicy()
        // The dream gate is a COMPOSITE of two policy fields, so it is read
        // through the one function that owns that math.
        dreamCycleOn = await appModel.engine.cognitionView.dreamEnabled()
        await refreshEmbeddings()
    }

    @MainActor
    private func syncFromTrustPolicy() {
        if !savingMemory {
            memoryDraft = appModel.engine.trust.policy?.memoryPolicy ?? TrustMemoryPolicy()
        }
        if !savingRem {
            remCycleOn = remEnabledInPolicy
        }
    }

    @MainActor
    private func refreshEmbeddings() async {
        guard let status = try? await appModel.fetchEmbeddingsStatus() else { return }
        embeddingsStatus = status
        if !savingEmbeddings {
            embeddingsOn = status.requestedEnabled
        }
    }

    /// The three-field memory save. A failure leaves the stored policy alone,
    /// so re-reading it is the revert; the toast says the write did not land.
    @MainActor
    private func saveMemory(
        _ next: TrustMemoryPolicy,
        expecting field: KeyPath<TrustMemoryPolicy, Bool>
    ) async {
        savingMemory = true
        await appModel.saveMemoryPolicy(
            consolidationEnabled: next.consolidation_enabled,
            crossSessionRecall: next.cross_session_recall,
            autoPromoteConsolidated: next.auto_promote_consolidated
        )
        savingMemory = false
        syncFromTrustPolicy()
        if memoryDraft[keyPath: field] != next[keyPath: field] {
            appModel.systemToasts.push(error: "That memory setting could not be saved.")
        }
    }

    @MainActor
    private func patchMemory(
        knowledgeGraph: Bool? = nil,
        adaptivePromotion: Bool? = nil,
        hygiene: Bool? = nil
    ) async {
        savingMemory = true
        let ok = await appModel.patchMemoryPolicy(
            knowledgeGraphEnabled: knowledgeGraph,
            adaptivePromotion: adaptivePromotion,
            hygieneEnabled: hygiene
        )
        savingMemory = false
        syncFromTrustPolicy()
        if !ok {
            appModel.systemToasts.push(error: "That memory setting could not be saved.")
        }
    }
}

// MARK: - The one card shape

/// EXACTLY the page's one row shape (`SetupRow`, SetupView): a title, one
/// secondary sentence in the fixed row box, and one control on the right.
private struct SetupFeatureCard<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        SetupRow(title: title, detail: detail) { trailing }
    }
}

/// One feature, one switch. `key` is the storage the switch actually writes,
/// so the accessibility identifier names the real thing rather than a label.
private struct SetupFeatureSwitchRow: View {
    let title: String
    let detail: String
    let key: String
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        SetupFeatureCard(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .hazeTinted()
                .disabled(disabled)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
                .accessibilityIdentifier("setup.feature.\(key)")
        }
    }
}
