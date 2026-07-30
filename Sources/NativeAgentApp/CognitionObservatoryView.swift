import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

struct CognitionObservatoryView: View {
    @Environment(AppModel.self) var appModel
    @State private var detail: CognitiveObservatoryDetail?
    @State private var contextFlowHealth: ContextFlowCoordinatorHealth?
    @State private var contextFlowFallback: ContextFlowFallbackState?
    @State private var workshop: WorkshopObservatorySnapshot?
    @State private var enabled = false
    @State private var capsuleEnabled = false
    @State private var backgroundEnabled = false
    @State private var reflectionEnabled = false
    @State private var organismEnabled = false
    @State private var reflectionBudget = 0
    @State private var isRefreshing = false
    @State private var isRunningReflection = false
    @State private var lastRefresh: Date?
    @State private var pinNotice: String?

    private var workspaceAblated: Bool { detail?.summary.ablations["workspace"] == false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                HStack {
                    GradientText(text: "Cognition Observatory", colors: [.teal, .indigo], font: NativeAgentFont.title)
                    Spacer()
                    StatusBadge(text: enabled ? "Enabled" : "Off", status: enabled ? "ok" : "warn")
                    if let lastRefresh {
                        Text("updated \(lastRefresh, style: .time)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                collapsible("controls", title: "Controls", systemImage: "slider.horizontal.3", tint: .teal,
                            hint: enabled ? "substrate on" : "substrate off") {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        Toggle("Cognitive substrate", isOn: enabledBinding)
                        Toggle("Capsule injection", isOn: capsuleEnabledBinding)
                            .disabled(!enabled)
                        Toggle("Background microcycles", isOn: backgroundEnabledBinding)
                            .disabled(!enabled)
                        Toggle("Opus 4.8 reflection", isOn: reflectionEnabledBinding)
                            .disabled(!enabled)
                        Toggle("Organism body kernel", isOn: organismEnabledBinding)
                            .disabled(!enabled)
                        Stepper("Daily reflection budget: \(reflectionBudget)", value: reflectionBudgetBinding, in: 0...8)
                            .disabled(!enabled || !reflectionEnabled)
                        // Same state as Settings ▸ Subconscious. That master
                        // switch sets ALL of these together; these granular
                        // toggles are the research-console overrides.
                        Text("Settings \u{25B8} Subconscious is the master switch — flipping it there resets all of these together.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        HStack(spacing: NativeAgentSpacing.sm) {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await refresh() }
                            }
                            Button("Microcycle", systemImage: "waveform.path.ecg") {
                                Task {
                                    await NativeCognitionRuntime.shared.runMicrocycle(reason: "observatory manual run")
                                    await refresh()
                                }
                            }
                            .disabled(!enabled)
                            Button("Reflect", systemImage: "brain.head.profile") {
                                Task {
                                    isRunningReflection = true
                                    await NativeCognitionRuntime.shared.runManualReflection()
                                    await refresh()
                                    isRunningReflection = false
                                }
                            }
                            .disabled(!enabled || !reflectionEnabled || reflectionBudget <= 0 || isRunningReflection)
                            Button("Clear", systemImage: "trash") {
                                Task {
                                    let outcome = await NativeCognitionRuntime.shared.clearTransientState()
                                    switch outcome {
                                    case .cleared:
                                        appModel.systemToasts.push(success: "Cognitive and organism state cleared.")
                                    case .persistenceFailed(let detail):
                                        appModel.systemToasts.push(error: "Clear failed; state was preserved: \(detail)")
                                    }
                                    await refresh()
                                }
                            }
                            .disabled(!enabled)
                            Button("Settle Body", systemImage: "leaf") {
                                Task {
                                    _ = await NativeCognitionRuntime.shared.settleOrganismContinuity()
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || !organismEnabled)
                            Button("Reset Body", systemImage: "waveform.path.ecg.rectangle") {
                                Task {
                                    _ = await NativeCognitionRuntime.shared.resetOrganismContinuity()
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || !organismEnabled)
                            Button("Run Evals", systemImage: "checklist") {
                                Task {
                                    await NativeCognitionRuntime.shared.runResearchHarness()
                                    await refresh()
                                }
                            }
                            .disabled(!enabled)
                            Button("Export", systemImage: "square.and.arrow.down") {
                                Task {
                                    _ = await NativeCognitionRuntime.shared.exportResearchTrace()
                                    await refresh()
                                }
                            }
                            .disabled(!enabled)
                            Button("Ablate Workspace", systemImage: "eye.slash") {
                                Task {
                                    await NativeCognitionRuntime.shared.setAblation("workspace", enabled: false)
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || workspaceAblated)
                            Button("Restore Workspace", systemImage: "eye") {
                                Task {
                                    await NativeCognitionRuntime.shared.setAblation("workspace", enabled: true)
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || !workspaceAblated)
                            Button("Pin Concern", systemImage: "pin") {
                                Task {
                                    pinNotice = await NativeCognitionRuntime.shared.pinTopConcern()
                                        .map { "Pinned: \($0)" } ?? "Nothing pressing to pin right now."
                                    await refresh()
                                }
                            }
                            .disabled(!enabled)
                        }
                        if workspaceAblated {
                            Label("Workspace ablated — capsule and microcycles ignore workspace nodes until restored.", systemImage: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if let pinNotice {
                            Text(pinNotice)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let detail {
                    metrics(detail)
                    if detail.substrate.persistenceHealth.status == .degraded {
                        Label(
                            cognitionPersistenceFailure(detail.substrate.persistenceHealth),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    collapsible(
                        "contextFlow",
                        title: "Context Flow",
                        systemImage: "arrow.triangle.branch",
                        tint: .cyan,
                        hint: contextFlowHint(contextFlowHealth)
                    ) {
                        ContextFlowObservatoryPanel(
                            health: contextFlowHealth,
                            fallback: contextFlowFallback
                        )
                    }
                    // L11 (Desk→Workshop): User's veto view onto Agent's Workshop.
                    // Sourced from STORE QUERIES (liveState), never the capped
                    // Desk projection — an open pursuit can never fall out of view.
                    collapsible(
                        "workshop",
                        title: "Workshop",
                        systemImage: "hammer",
                        tint: .purple,
                        count: workshop?.model?.openPursuitCount,
                        hint: workshop?.hint
                    ) {
                        WorkshopObservatoryPanel(snapshot: workshop) { handle in
                            Task {
                                await vetoPursuit(handle)
                                await refresh()
                            }
                        }
                    }
                    collapsible("organism", title: "Organism Body", systemImage: "waveform.path.ecg", tint: .green,
                                hint: organismHint(detail.organism)) {
                        organism(detail.organism)
                    }
                    // Every readout group collapses to one clickable header row
                    // (User, 2026-07-03) — the badge/hint says whether there's
                    // anything alive inside without opening it.
                    collapsible("loop", title: "Loop Activity", systemImage: "clock.arrow.circlepath", tint: .teal,
                                count: detail.receipts.count, hint: loopHint(detail.receipts)) {
                        loopActivity(detail.receipts)
                    }
                    collapsible("harness", title: "Research Harness", systemImage: "testtube.2", tint: .orange,
                                hint: detail.welfareBounds.withinBounds ? "bounded" : "attention") {
                        researchHarness(detail)
                    }
                    collapsible("workspace", title: "Workspace", systemImage: "rectangle.3.group", tint: .blue,
                                count: detail.workspace.items.count) {
                        workspace(detail.workspace)
                    }
                    collapsible("associations", title: "Association Graph", systemImage: "point.3.connected.trianglepath.dotted", tint: .blue,
                                count: detail.associations.count) {
                        associationGraph(detail.associations, nodes: detail.substrate.nodes)
                    }
                    collapsible("tensions", title: "Tensions & Pruning", systemImage: "scissors", tint: .red) {
                        tensionsAndPruning(detail)
                    }
                    collapsible("affect", title: "Affect Signals", systemImage: "gauge.with.dots.needle.bottom.50percent", tint: .purple,
                                hint: affectHint(detail.summary.affect)) {
                        affect(detail.summary.affect)
                    }
                    // Predictions/commitments panels were removed with the underlying
                    // task-tracking machinery (fully deleted 2026-07-01) — task-tracking is
                    // out of Agent's cognition (User, 2026-06-30). Her cognition is
                    // feelings/views/continuity, not a to-do.
                    collapsible("seeds", title: "Thought Seeds", systemImage: "sparkles", tint: .yellow,
                                count: detail.thoughtSeeds.count) {
                        thoughtSeeds(detail.thoughtSeeds)
                    }
                    collapsible("interruptions", title: "Suggested Interruptions", systemImage: "lightbulb", tint: .mint,
                                count: detail.thoughtSuggestions.count) {
                        thoughtSuggestions(detail.thoughtSuggestions)
                    }
                    // Standing Views + Schema Proposals are APPROVAL-shaped and
                    // moved to the Activity surface (B2.4); Identity Proposals was
                    // deleted (inert — `proposeIdentity` has no production caller).
                    // This segment is the read-only observational core.
                    collapsible("timeline", title: "Developmental Timeline", systemImage: "timeline.selection", tint: .pink,
                                count: detail.developmentalTimeline.count) {
                        developmentalTimeline(detail.developmentalTimeline)
                    }
                    collapsible("capsule", title: "Capsule Preview", systemImage: "doc.plaintext", tint: .cyan,
                                hint: capsuleHint(detail.capsulePreviewInfo)) {
                        capsule(detail.capsulePreview, info: detail.capsulePreviewInfo,
                                feltMode: detail.feltMode)
                    }
                    collapsible("reflections", title: "Reflection Receipts", systemImage: "brain.head.profile", tint: .teal,
                                count: detail.reflections.count) {
                        reflections(detail.reflections)
                    }
                } else {
                    NativeEmptyState(
                        title: "Cognition Observatory",
                        detail: isRefreshing ? "Loading cognitive state." : "No cognitive state loaded yet.",
                        systemImage: "brain.head.profile"
                    )
                }

                // B2.6 (g): DeskView's debug disclosures (agent projection +
                // raw all-items table) moved here — DeskView keeps zero debug
                // chrome. Self-contained; loads its own desk state.
                DeskDebugPanels()
            }
            .padding(NativeAgentSpacing.xl)
        }
        // Embedded as the Diagnostics ▸ Cognition segment (B2.4): Diagnostics
        // owns the navigation chrome, so no navigationTitle/toolbar here. The
        // Controls panel already carries a Refresh button.
        .task {
            let changes = await NativeCognitionRuntime.shared.changes()
            // Subscribe before the initial read. A cognition event that lands
            // while refresh is in flight is then buffered instead of being
            // lost between the old polling replacement's read and watch arm.
            await refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                // The stream is buffering-newest, so a tool burst collapses
                // while this read is in flight without a timer or idle wake.
                await refresh()
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { value in
            enabled = value
            Task { await NativeCognitionRuntime.shared.setEnabled(value); await refresh() }
        })
    }

    private var capsuleEnabledBinding: Binding<Bool> {
        Binding(get: { capsuleEnabled }, set: { value in
            capsuleEnabled = value
            Task { await NativeCognitionRuntime.shared.setCapsuleEnabled(value); await refresh() }
        })
    }

    private var backgroundEnabledBinding: Binding<Bool> {
        Binding(get: { backgroundEnabled }, set: { value in
            backgroundEnabled = value
            Task { await NativeCognitionRuntime.shared.setBackgroundEnabled(value); await refresh() }
        })
    }

    private var reflectionEnabledBinding: Binding<Bool> {
        Binding(get: { reflectionEnabled }, set: { value in
            reflectionEnabled = value
            Task { await NativeCognitionRuntime.shared.setReflectionEnabled(value); await refresh() }
        })
    }

    private var organismEnabledBinding: Binding<Bool> {
        Binding(get: { organismEnabled }, set: { value in
            organismEnabled = value
            Task { await NativeCognitionRuntime.shared.setOrganismKernelEnabled(value); await refresh() }
        })
    }

    private var reflectionBudgetBinding: Binding<Int> {
        Binding(get: { reflectionBudget }, set: { value in
            reflectionBudget = value
            Task { await NativeCognitionRuntime.shared.setReflectionBudget(value); await refresh() }
        })
    }

    func refresh() async {
        isRefreshing = true
        let next = await NativeCognitionRuntime.shared.observatoryDetail()
        contextFlowHealth = await NativeContextFlowRuntime.shared.health()
        contextFlowFallback = await ContextFlowFallbackReader.load()
        let deskRoot = PersistenceCore.defaultDataRoot()
        workshop = await WorkshopObservatorySnapshot.load(
            store: SwiftNativeDeskStore(dataRoot: deskRoot),
            receiptsPath: deskRoot
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("receipts.jsonl")
        )
        detail = next
        enabled = next.configuration.enabled
        capsuleEnabled = next.configuration.capsuleInjectionEnabled
        backgroundEnabled = next.configuration.backgroundMicrocyclesEnabled
        reflectionEnabled = next.configuration.reflectiveCallsEnabled
        organismEnabled = next.organism.enabled
        reflectionBudget = next.configuration.dailyReflectionCallBudget
        lastRefresh = Date()
        isRefreshing = false
    }

    /// Veto an agent-opened pursuit: close it (canceled) and record a User note.
    /// Wired to the existing store — no new approval machinery (L11 veto action).
    private func vetoPursuit(_ handle: String) async {
        let store = SwiftNativeDeskStore(dataRoot: PersistenceCore.defaultDataRoot())
        do {
            _ = try await store.setStatus(handle, status: .canceled)
            _ = try? await store.appendNote(handle, text: "Vetoed by the user from the Workshop Observatory.")
            appModel.systemToasts.push(success: "Pursuit vetoed — closed as canceled.")
        } catch {
            appModel.systemToasts.push(error: "Veto failed: \(error.localizedDescription)")
        }
    }

    private func contextFlowHint(_ health: ContextFlowCoordinatorHealth?) -> String {
        guard let health else { return "off" }
        if health.lastError != nil { return "attention" }
        return "\(health.mode.rawValue) · generation \(health.activeArenaGenerationID ?? 0)"
    }

    // MARK: - Collapsible panels

    /// Comma-joined ids of the panels the user has opened — persisted so the tab
    /// comes back the way they left it. Default (empty) = everything collapsed
    /// to header rows.
    @AppStorage("cognitionObservatoryExpandedPanels") private var expandedPanelsRaw = ""

    private var expandedPanels: Set<String> {
        Set(expandedPanelsRaw.split(separator: ",").map(String.init))
    }

    private func togglePanel(_ id: String) {
        var set = expandedPanels
        if !set.insert(id).inserted { set.remove(id) }
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedPanelsRaw = set.sorted().joined(separator: ",")
        }
    }

    /// Same card chrome as NativePanel, but the header row is the disclosure
    /// control: count badge + optional pending badge + a one-line hint while
    /// collapsed, chevron flips on expand. Panel ids must not contain commas.
    private func collapsible<Content: View>(
        _ id: String,
        title: String,
        systemImage: String,
        tint: Color,
        count: Int? = nil,
        pending: Int = 0,
        hint: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = expandedPanels.contains(id)
        return NativePanel(title: nil, systemImage: nil, tint: tint) {
            VStack(alignment: .leading, spacing: isExpanded ? NativeAgentSpacing.md : 0) {
                Button {
                    togglePanel(id)
                } label: {
                    HStack(spacing: NativeAgentSpacing.sm) {
                        Image(systemName: systemImage)
                            .foregroundStyle(tint)
                        Text(title)
                            .font(NativeAgentFont.section)
                            .foregroundStyle(.primary)
                        if let count, count > 0 {
                            Text("\(count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tint.opacity(0.15)))
                                .foregroundStyle(tint)
                        }
                        if pending > 0 {
                            Text("\(pending) pending")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                        if !isExpanded, let hint, !hint.isEmpty {
                            Text(hint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isExpanded {
                    content()
                }
            }
        }
    }

    private func loopHint(_ receipts: [CognitiveReceiptRecord]) -> String? {
        guard let latest = receipts.first else { return nil }
        return "\(latest.kind) · \(latest.createdAt.formatted(date: .omitted, time: .shortened))"
    }

    private func affectHint(_ affect: CognitiveAffectState) -> String {
        String(format: "act %.2f · warm %.2f", affect.arousal, affect.socialWarmth)
    }

    private func organismHint(_ snapshot: OrganismSnapshot) -> String {
        guard snapshot.enabled else { return "off" }
        if let line = snapshot.projectedBodyLine, !line.isEmpty {
            return line.replacingOccurrences(of: "- Body: ", with: "")
        }
        return "steady"
    }

    private func capsuleHint(_ info: CapsulePreviewInfo?) -> String? {
        guard let info else { return nil }
        switch info.source {
        case .liveInjected:
            if let at = info.at {
                return "injected \(at.formatted(date: .omitted, time: .shortened))"
            }
            return "live injected"
        case .synthetic:
            return "synthetic preview"
        }
    }


    private func cognitionPersistenceFailure(_ health: CognitivePersistenceHealth) -> String {
        let stage = health.failureStage.map { " at \($0)" } ?? ""
        return "Cognitive persistence degraded\(stage); writes are paused to protect stored continuity."
    }
}
