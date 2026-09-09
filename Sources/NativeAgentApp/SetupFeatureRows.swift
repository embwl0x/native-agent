// THE REST OF THE FOUR THINGS, ON THE SETUP PAGE.
//
// Every switch here writes exactly the storage its old control wrote — the
// substrate lanes (Cognition Observatory), Fluid Context (Settings ▸
// Subconscious), the dream and REM gates (Dreams), the memory policy (Trust ▸
// Living memory), the embeddings backend and memory mode (Settings ▸ Memory)
// and the weekly self-improvement key. Nothing here owns a setting of its own,
// and no row invents a second home for one.
//
// The page's own cards for the inner-life master, Moments and the hour stay in
// SetupView; they are deliberately NOT repeated here.

import SwiftUI
import Context

struct SetupFeatureRows: View {
    @Environment(AppModel.self) private var appModel

    // Same keys the Subconscious section and the Observatory bind, so no two
    // surfaces can show different truth.
    @AppStorage("cognitiveSubstrateEnabled") private var subconsciousEnabled = false
    @AppStorage("cognitiveSubstrateReflectionEnabled") private var reflectionEnabled = false
    @AppStorage("organismKernelEnabled") private var organismEnabled = false
    @AppStorage("contextFlowMode") private var contextFlowMode = ContextFlowMode.shadow.rawValue
    @AppStorage("selfImprovementEnabled") private var selfImprovementEnabled = false

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
    @State private var savingMemoryMode = false
    @State private var savingContextFlow = false

    /// Every sentence on this page is built out of this: the agent's name,
    /// never a gender.
    private var voice: AgentVoice { AgentVoice(name: appModel.agentDisplayName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            reflectionRow
            organismRow
            fluidContextRow
            dreamsRow
            weeklyConsolidationRow
            meaningMemoryRow
            knowledgeGraphRow
            nightlyConsolidationRow
            keepConsolidatedRow
            adaptivePromotionRow
            hygieneRow
            crossSessionRecallRow
            selfImprovementRow
            memoryModeRow
        }
        .task { await load() }
        // The policy is one document: a save anywhere in the app re-publishes
        // it, and these rows follow it rather than keeping their own copy.
        .onChange(of: appModel.trustPolicy) { _, _ in
            syncFromTrustPolicy()
            // The dream gate is a composite the policy only half carries;
            // re-read it the way the Dreams page does.
            guard !savingDream else { return }
            Task { @MainActor in dreamCycleOn = await appModel.client.swiftDreamCompositeEnabled() }
        }
    }

    // MARK: - Reflection (cognitiveSubstrateReflectionEnabled)

    private var reflectionRow: some View {
        SetupFeatureSwitchRow(
            title: "Reflection between conversations",
            detail: subconsciousEnabled
                ? "Between conversations \(voice.subject) \(voice.verb("think")) back over what happened and \(voice.verb("keep")) what matters."
                : "Turn on an inner life first — reflection runs inside it.",
            key: "cognitiveSubstrateReflectionEnabled",
            isOn: Binding(
                get: { reflectionEnabled },
                set: { value in
                    reflectionEnabled = value
                    Task { await NativeCognitionRuntime.shared.setReflectionEnabled(value) }
                }
            ),
            disabled: !subconsciousEnabled
        )
    }

    // MARK: - Organism (organismKernelEnabled)

    private var organismRow: some View {
        SetupFeatureSwitchRow(
            title: "Moods, energy, and a clock of \(voice.possessive) own",
            detail: subconsciousEnabled
                ? "\(voice.Subject) \(voice.verb("get")) moods, tiredness, and a clock that keeps running while you are away."
                : "Turn on an inner life first to enable moods, energy, and a daily rhythm.",
            key: "organismKernelEnabled",
            isOn: Binding(
                get: { organismEnabled },
                set: { value in
                    organismEnabled = value
                    Task { await NativeCognitionRuntime.shared.setOrganismKernelEnabled(value) }
                }
            ),
            disabled: !subconsciousEnabled
        )
    }

    // MARK: - Memory in every reply (contextFlowMode)

    /// Three modes, so a menu, as the original control was: a switch cannot
    /// round-trip out of Off (the reviewer's catch, 2026-09-04).
    private var fluidContextRow: some View {
        SetupFeatureCard(
            title: "Memory in every reply",
            detail: "What \(voice.subject) \(voice.verb("remember")) shapes each reply. Observe only measures what would have helped and changes nothing."
        ) {
            Picker("Memory in every reply", selection: Binding(
                get: { ContextFlowMode(rawValue: contextFlowMode) ?? .shadow },
                set: { mode in
                    contextFlowMode = mode.rawValue
                    Task { await setFluidContext(mode) }
                }
            )) {
                ForEach([ContextFlowMode.off, .shadow, .active], id: \.rawValue) { mode in
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
        let status = await NativeContextFlowRuntime.shared.setMode(requested)
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
            detail: "At night \(voice.subject) \(voice.verb("go")) back over the day and \(voice.verb("write")) down what \(voice.subject) made of it.",
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
            dreamCycleOn = await appModel.client.swiftDreamCompositeEnabled()
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
            detail: "Once a week \(voice.subject) \(voice.verb("gather")) the week's memories into fewer, stronger ones.",
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
        appModel.trustPolicy?.trainingPolicy?.rem_cycle_enabled == true
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
            Text("\(voice.Subject) \(voice.verb("re-read")) every memory to rebuild how \(voice.subject) \(voice.verb("find")) them. That can take a while, and memory stays available meanwhile.")
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
                error: "The memory backend could not be changed: \(error.localizedDescription)"
            )
        }
        savingEmbeddings = false
    }

    /// The detail line says what is TRUE right now, not what was asked for.
    private var meaningMemoryDetail: String {
        guard let status = embeddingsStatus else {
            return "Checking how \(voice.subject) \(voice.verb("look")) things up right now."
        }
        if savingEmbeddings {
            return "Re-indexing every memory. This can take a while."
        }
        switch status.effectiveBackend {
        case "local":
            return "On — \(voice.subject) \(voice.verb("find")) memories by what they mean, not by the words in them."
        case "unavailable" where status.requestedEnabled:
            return "Asked for, but the on-device model could not be loaded; \(voice.subject) \(voice.verb("match")) on words for now."
        default:
            return "Off — \(voice.subject) \(voice.verb("match")) memories on their words alone."
        }
    }

    // MARK: - Memory policy (memoryPolicy.*)

    private var keepConsolidatedRow: some View {
        SetupFeatureSwitchRow(
            title: "Keep consolidated memories without asking",
            detail: "What the nightly pass gathers stays on its own; off, \(voice.subject) \(voice.verb("ask")) you first.",
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
            detail: "\(voice.Subject) \(voice.verb("tidy")) old, noisy, and duplicate memories on a schedule.",
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
            detail: "\(voice.Subject) \(voice.verb("join")) up the people, places, and things your conversations keep mentioning.",
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
            detail: "Once a week \(voice.subject) \(voice.verb("gather")) what keeps coming up into fewer, stronger memories and \(voice.verb("offer")) them for review.",
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
            detail: "When something keeps coming back, \(voice.subject) \(voice.verb("propose")) it as a durable fact for you to accept.",
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
            detail: "\(voice.Subject) \(voice.verb("bring")) in what is relevant from every past conversation, not just this one.",
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
            detail: "Once a week \(voice.subject) \(voice.verb("review")) how things actually went and \(voice.verb("propose")) safe changes.",
            key: "selfImprovementEnabled",
            isOn: $selfImprovementEnabled
        )
    }

    // MARK: - Memory mode (the embeddings runtime's idle retention)

    private var memoryModeRow: some View {
        SetupFeatureCard(
            title: "Memory mode",
            detail: memoryModeDetail
        ) {
            Picker("Memory mode", selection: Binding(
                get: { memoryMode },
                set: { mode in Task { await setMemoryMode(mode) } }
            )) {
                Text("Fast").tag("performance")
                Text("Balanced").tag("balanced")
                Text("Low").tag("low_memory")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Nothing on this page truncates mid-word.
            .fixedSize()
            .disabled(embeddingsStatus == nil || savingMemoryMode)
            .accessibilityIdentifier("setup.feature.memoryMode")
        }
    }

    private var memoryMode: String {
        guard let status = embeddingsStatus else { return "balanced" }
        return EmbeddingsSettingsStatusPresentation(status: status).memoryMode
    }

    private var memoryModeDetail: String {
        guard let status = embeddingsStatus else {
            return "Checking how much \(voice.subject) \(voice.verb("keep")) loaded for recall."
        }
        return EmbeddingsSettingsStatusPresentation(status: status).memoryModeDescription
    }

    @MainActor
    private func setMemoryMode(_ mode: String) async {
        savingMemoryMode = true
        defer { savingMemoryMode = false }
        do {
            let result = try await appModel.setEmbeddingsMemoryMode(mode: mode)
            embeddingsStatus = result.status
            if let error = result.error {
                appModel.systemToasts.push(error: result.detail.map { "\(error): \($0)" } ?? error)
            }
        } catch {
            appModel.systemToasts.push(
                error: "Memory mode update failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Loading and reconciliation

    @MainActor
    private func load() async {
        // The policy carries the REM gate and the whole memory policy. Setup
        // loads it too; this only fills the gap when these rows are mounted
        // before that read lands.
        if appModel.trustPolicy == nil {
            appModel.trustPolicy = try? await appModel.getTrustPolicy()
        }
        syncFromTrustPolicy()
        // The dream gate is a COMPOSITE of two policy fields, so it is read
        // through the one function that owns that math.
        dreamCycleOn = await appModel.client.swiftDreamCompositeEnabled()
        await refreshEmbeddings()
    }

    @MainActor
    private func syncFromTrustPolicy() {
        if !savingMemory {
            memoryDraft = appModel.trustPolicy?.memoryPolicy ?? TrustMemoryPolicy()
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

/// EXACTLY the shape of the page's rest-cards (`appearanceRow`, SetupView):
/// a 13 semibold title, one secondary sentence in a fixed 50pt box, and one
/// control on the right. Fixed, not minimum — a minimum drifts the moment a
/// name or a sentence changes length.
private struct SetupFeatureCard<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        SetupCardShell {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold).lineLimit(1)
                    Text(detail)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .frame(height: SetupMetrics.restCardContentHeight, alignment: .topLeading)
                Spacer(minLength: 12)
                trailing
            }
        }
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
                .tint(NativeAgentBrand.accent)
                .disabled(disabled)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
                .accessibilityIdentifier("setup.feature.\(key)")
        }
    }
}
