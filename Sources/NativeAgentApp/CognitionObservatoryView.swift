import SwiftUI

enum CognitionObservatoryPanelID: String, CaseIterable, Sendable {
    case controls
    case contextFlow
    case workshop
    case organism
    case loop
    case harness
    case workspace
    case associations
    case tensions
    case affect
    case seeds
    case interruptions
    case timeline
    case capsule
    case reflections
}

/// The Observatory deliberately accepts only these observational panels. Human
/// approval remains an Activity concern, so it cannot be added to this surface
/// by accidentally passing an ad-hoc disclosure identifier.
enum CognitionSurfaceDispositionPresentation {
    enum Destination: Equatable, Sendable {
        case activityCognitionProposals
        case diagnosticsCognition
    }

    enum StandingViewAction: String, CaseIterable, Hashable, Sendable {
        case approve
        case reject

        var title: String {
            switch self {
            case .approve: "Approve"
            case .reject: "Reject"
            }
        }

        var approved: Bool { self == .approve }
    }

    static let approvalsDestination: Destination = .activityCognitionProposals
    static let activityApprovalSection: ActivitySection = .cognitionProposals
    static let deskDebugDestination: Destination = .diagnosticsCognition

    static func standingViewActions(isPending: Bool) -> [StandingViewAction] {
        isPending ? StandingViewAction.allCases : []
    }
}
import Observation
import CognitiveSubstrate
import Context
import PersistenceCore

/// The Observatory's Veto control may only claim a canceled pursuit after the
/// Desk store commits both the terminal status and its rationale. This maps the
/// handler's durable outcome into the mounted toast and refresh decision so a
/// note-write failure remains an explicit adverse state.
enum CognitionObservatoryWorkshopVetoPresentation {
    enum Tone: Equatable {
        case success
        case info
        case failure
    }

    struct Feedback: Equatable {
        let tone: Tone
        let text: String
        let shouldRefresh: Bool
    }

    static func feedback(for outcome: WorkshopObservatoryVetoHandler.Outcome) -> Feedback {
        switch outcome {
        case .completed:
            return Feedback(tone: .success, text: "Pursuit vetoed — closed as canceled.", shouldRefresh: true)
        case .alreadyVetoed:
            return Feedback(tone: .success, text: "Pursuit was already vetoed.", shouldRefresh: true)
        case .inFlight:
            return Feedback(tone: .info, text: "Veto already in progress.", shouldRefresh: false)
        case let .failed(message):
            return Feedback(tone: .failure, text: "Veto not recorded: \(message)", shouldRefresh: false)
        }
    }
}

struct CognitionObservatoryView: View {
    struct Dependencies {
        let dataRoot: URL
        let agentDisplayName: String
        let systemToasts: SystemToastCenter
        let contextFlowHealth: () async -> ContextFlowObservatoryHealthState
        let contextFlowFallback: () async -> ContextFlowFallbackState
        let organismToggleDidRender: @MainActor (Bool) -> Void

        @MainActor
        static func live(appModel: AppModel) -> Self {
            Self(
                dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                agentDisplayName: appModel.agentDisplayName,
                systemToasts: appModel.systemToasts,
                contextFlowHealth: { await NativeContextFlowRuntime.shared.observatoryHealthState() },
                contextFlowFallback: { await ContextFlowFallbackReader.load() },
                organismToggleDidRender: { _ in }
            )
        }
    }

    let runtime: NativeCognitionRuntime
    let dependencies: Dependencies
    private let vetoHandler: WorkshopObservatoryVetoHandler
    @State private var detail: CognitiveObservatoryDetail?
    @State private var detailEvidenceStatus: CognitiveObservatoryDetailRead.EvidenceStatus?
    @State private var contextFlowHealth: ContextFlowObservatoryHealthState = .unavailable
    @State private var contextFlowFallback: ContextFlowFallbackState?
    @State private var workshop: WorkshopObservatorySnapshot?
    @State private var enabled = false
    @State private var capsuleEnabled = false
    @State private var backgroundEnabled = false
    @State private var reflectionEnabled = false
    @State private var organismEnabled = false
    @State private var organismControlReadinessRevision: UInt64 = 0
    @State private var reflectionBudget = 0
    @State private var refreshCoordinator = CognitionObservatoryRefreshCoordinator()
    @State private var isRunningReflection = false
    @State private var isRunningEvaluationSamplers = false
    @State private var evaluationSamplerOutcome: CognitiveEvaluationSamplerOutcome?
    @State var reflexReviewsInFlight: Set<String> = []
    @State private var vetoingPursuitHandles: Set<String> = []
    @State private var lastRefresh: Date?
    @State private var pinNotice: String?

    init(
        runtime: NativeCognitionRuntime = .shared,
        dependencies: Dependencies
    ) {
        self.runtime = runtime
        self.dependencies = dependencies
        self.vetoHandler = WorkshopObservatoryVetoHandler(dataRoot: dependencies.dataRoot)
    }

    private var isRefreshing: Bool { refreshCoordinator.isRefreshing }

    private var workspaceAblated: Bool { detail?.summary.ablations["workspace"] == false }
    private var affectPresentation: CognitionObservatoryAffectPresentation {
        CognitionObservatoryAffectPresentation(
            configuration: detail?.configuration,
            affect: detail?.summary.affect,
            capsulePreviewInfo: detail?.capsulePreviewInfo
        )
    }

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

                if case .receiptEvidenceUnavailable(let reason) = detailEvidenceStatus {
                    Label(
                        CognitionObservatoryPresentation.receiptEvidenceUnavailableText(reason),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.orange)
                }

                collapsible(.controls, title: "Controls", systemImage: "slider.horizontal.3", tint: .teal,
                            hint: enabled ? "substrate on" : "substrate off") {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        Toggle("Cognitive substrate", isOn: enabledBinding)
                        Toggle("Capsule injection", isOn: capsuleEnabledBinding)
                            .disabled(!enabled)
                        Toggle("Background microcycles", isOn: backgroundEnabledBinding)
                            .disabled(!enabled)
                        Toggle("Opus 4.8 reflection", isOn: reflectionEnabledBinding)
                            .disabled(!enabled)
                        Toggle(CognitionObservatoryOrganismControlPresentation.label, isOn: organismEnabledBinding)
                            .disabled(!organismControl.isEnabled)
                            .accessibilityLabel(CognitionObservatoryOrganismControlPresentation.label)
                            .onAppear { reportOrganismToggleStateIfReady() }
                            .onChange(of: organismEnabled) { _, _ in
                                reportOrganismToggleStateIfReady()
                            }
                            .onChange(of: organismControlReadinessRevision) { _, _ in
                                reportOrganismToggleStateIfReady()
                            }
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
                            .disabled(refreshCoordinator.isRefreshing)
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
                                    let outcome = await CognitionObservatoryActions.reflectWithOutcome(
                                        runtime: .shared
                                    )
                                    CognitionObservatoryControlFeedback.publish(outcome.status, to: dependencies.systemToasts)
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
                                        dependencies.systemToasts.push(success: "Cognitive and organism state cleared.")
                                    case .persistenceFailed(let detail):
                                        dependencies.systemToasts.push(error: "Clear failed; state was preserved: \(detail)")
                                    }
                                    await refresh()
                                }
                            }
                            .disabled(!enabled)
                            Button("Settle Body", systemImage: "leaf") {
                                Task {
                                    let result = await CognitionObservatoryActions.settleBodyChecked()
                                    CognitionObservatoryControlFeedback.publish(result.outcome, action: "settle", to: dependencies.systemToasts)
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || !organismEnabled)
                            Button("Reset Body", systemImage: "waveform.path.ecg.rectangle") {
                                Task {
                                    let result = await CognitionObservatoryActions.resetBodyChecked()
                                    CognitionObservatoryControlFeedback.publish(result.outcome, action: "reset", to: dependencies.systemToasts)
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || !organismEnabled)
                            Button("Run Evals", systemImage: "checklist") {
                                Task {
                                    isRunningEvaluationSamplers = true
                                    let outcome = await runtime.runResearchHarness()
                                    evaluationSamplerOutcome = outcome
                                    if outcome.isComplete {
                                        dependencies.systemToasts.push(success: outcome.presentationText)
                                    } else if outcome.isFailed {
                                        dependencies.systemToasts.push(error: outcome.presentationText)
                                    } else {
                                        dependencies.systemToasts.push(info: outcome.presentationText)
                                    }
                                    await refresh()
                                    isRunningEvaluationSamplers = false
                                }
                            }
                            .disabled(!enabled || isRunningEvaluationSamplers)
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
                        if let evaluationSamplerOutcome {
                            Label(
                                evaluationSamplerOutcome.presentationText,
                                systemImage: evaluationSamplerOutcome.isComplete
                                    ? "checkmark.circle"
                                    : "exclamationmark.triangle"
                            )
                            .font(.caption2)
                            .foregroundStyle(evaluationSamplerOutcome.isComplete ? .green : .orange)
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
                        .contextFlow,
                        title: "Context Flow",
                        systemImage: "arrow.triangle.branch",
                        tint: .cyan,
                        hint: contextFlowHint(contextFlowHealth)
                    ) {
                        ContextFlowObservatoryPanel(
                            healthState: contextFlowHealth,
                            fallback: contextFlowFallback
                        )
                    }
                    // L11 (Desk→Workshop): User's veto view onto Agent's Workshop.
                    // Sourced from STORE QUERIES (liveState), never the capped
                    // Desk projection — an open pursuit can never fall out of view.
                    collapsible(
                        .workshop,
                        title: "Desk",
                        systemImage: "hammer",
                        tint: .purple,
                        count: workshop?.model?.openPursuitCount,
                        hint: workshop?.hint
                    ) {
                        WorkshopObservatoryPanel(
                            snapshot: workshop,
                            pendingVetoHandles: vetoingPursuitHandles
                        ) { handle in
                            beginVetoPursuit(handle)
                        }
                    }
                    collapsible(.organism, title: "Organism Body", systemImage: "waveform.path.ecg", tint: .green,
                                hint: Self.organismHint(detail.organism)) {
                        organism(detail.organism)
                    }
                    // Every readout group collapses to one clickable header row
                    // (User, 2026-07-03) — the badge/hint says whether there's
                    // anything alive inside without opening it.
                    collapsible(.loop, title: "Loop Activity", systemImage: "clock.arrow.circlepath", tint: .teal,
                                count: CognitionLoopActivityPresentation.receiptCount(for: detail.receiptRead),
                                hint: CognitionLoopActivityPresentation.collapsedHint(for: detail.receiptRead)) {
                        loopActivity(detail.receiptRead)
                    }
                    collapsible(.harness, title: "Research Harness", systemImage: "testtube.2", tint: .orange,
                                hint: detail.welfareBounds.withinBounds ? "bounded" : "attention") {
                        researchHarness(detail)
                    }
                    collapsible(.workspace, title: "Workspace", systemImage: "rectangle.3.group", tint: .blue,
                                count: detail.workspace.items.count) {
                        workspace(detail.workspace)
                    }
                    collapsible(.associations, title: "Association Graph", systemImage: "point.3.connected.trianglepath.dotted", tint: .blue,
                                count: detail.associations.count) {
                        associationGraph(detail.associations, nodes: detail.substrate.nodes)
                    }
                    collapsible(.tensions, title: "Tensions & Pruning", systemImage: "scissors", tint: .red) {
                        tensionsAndPruning(detail)
                    }
                    collapsible(.affect, title: "Affect Signals", systemImage: "gauge.with.dots.needle.bottom.50percent", tint: .purple,
                                hint: affectPresentation.collapsedHint) {
                        affect(affectPresentation)
                    }
                    // Predictions/commitments panels were removed with the underlying
                    // task-tracking machinery (fully deleted 2026-07-01) — task-tracking is
                    // out of Agent's cognition (User, 2026-06-30). Her cognition is
                    // feelings/views/continuity, not a to-do.
                    collapsible(.seeds, title: "Thought Seeds", systemImage: "sparkles", tint: .yellow,
                                count: detail.thoughtSeeds.count) {
                        thoughtSeeds(detail.thoughtSeeds)
                    }
                    collapsible(.interruptions, title: "Suggested Interruptions", systemImage: "lightbulb", tint: .mint,
                                count: detail.thoughtSuggestions.count) {
                        thoughtSuggestions(detail.thoughtSuggestions)
                    }
                    // Standing Views + Schema Proposals are APPROVAL-shaped and
                    // moved to the Activity surface (B2.4); Identity Proposals was
                    // retired after its experimental producer proved inert.
                    // This segment is the read-only observational core.
                    collapsible(.timeline, title: "Developmental Timeline", systemImage: "timeline.selection", tint: .pink,
                                count: detail.developmentalTimeline.count) {
                        developmentalTimeline(detail.developmentalTimeline)
                    }
                    collapsible(.capsule, title: "Capsule Preview", systemImage: "doc.plaintext", tint: .cyan,
                                hint: capsuleHint(detail.capsulePreviewInfo)) {
                        capsule(detail.capsulePreview, info: detail.capsulePreviewInfo,
                                feltMode: detail.feltMode)
                    }
                    collapsible(.reflections, title: "Reflection Receipts", systemImage: "brain.head.profile", tint: .teal,
                                count: detail.reflections.count) {
                        reflections(detail.reflections)
                    }
                } else {
                    collapsible(.affect, title: "Affect Signals", systemImage: "gauge.with.dots.needle.bottom.50percent", tint: .purple,
                                hint: affectPresentation.collapsedHint) {
                        affect(affectPresentation)
                    }
                    NativeEmptyState(
                        title: "Cognition Observatory",
                        detail: isRefreshing ? "Loading cognitive state." : "No cognitive state loaded yet.",
                        systemImage: "brain.head.profile"
                    )
                }

                // B2.6 (g): DeskView's debug disclosures (agent projection +
                // raw all-items table) moved here — DeskView keeps zero debug
                // chrome. Self-contained; loads its own desk state.
                DeskDebugPanels(
                    dataRoot: dependencies.dataRoot,
                    agentDisplayName: dependencies.agentDisplayName
                )
            }
            .padding(NativeAgentSpacing.xl)
        }
        // Embedded as the Diagnostics ▸ Cognition segment (B2.4): Diagnostics
        // owns the navigation chrome, so no navigationTitle/toolbar here. The
        // Controls panel already carries a Refresh button.
        .task {
            let changes = await runtime.changes()
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
            Task { await runtime.setEnabled(value); await refresh() }
        })
    }

    private var capsuleEnabledBinding: Binding<Bool> {
        Binding(get: { capsuleEnabled }, set: { value in
            capsuleEnabled = value
            Task { await runtime.setCapsuleEnabled(value); await refresh() }
        })
    }

    private var backgroundEnabledBinding: Binding<Bool> {
        Binding(get: { backgroundEnabled }, set: { value in
            backgroundEnabled = value
            Task { await runtime.setBackgroundEnabled(value); await refresh() }
        })
    }

    private var reflectionEnabledBinding: Binding<Bool> {
        Binding(get: { reflectionEnabled }, set: { value in
            reflectionEnabled = value
            Task { await runtime.setReflectionEnabled(value); await refresh() }
        })
    }

    private var organismControl: CognitionObservatoryOrganismControlPresentation {
        CognitionObservatoryOrganismControlPresentation(
            cognitiveSubstrateEnabled: enabled,
            organismKernelEnabled: organismEnabled
        )
    }

    private var organismEnabledBinding: Binding<Bool> {
        Binding(get: { organismEnabled }, set: { value in
            organismEnabled = value
            Task { await runtime.setOrganismKernelEnabled(value); await refresh() }
        })
    }

    @MainActor
    private func reportOrganismToggleStateIfReady() {
        guard enabled else { return }
        dependencies.organismToggleDidRender(organismEnabled)
    }

    private var reflectionBudgetBinding: Binding<Int> {
        Binding(get: { reflectionBudget }, set: { value in
            reflectionBudget = value
            Task { await runtime.setReflectionBudget(value); await refresh() }
        })
    }

    func refresh() async {
        let refreshGeneration = refreshCoordinator.begin()
        let nextRead = await CognitionObservatoryActions.refreshRead(runtime: runtime)
        let next = nextRead.detail
        let nextContextFlowHealth = await dependencies.contextFlowHealth()
        let nextContextFlowFallback = await dependencies.contextFlowFallback()
        let deskRoot = dependencies.dataRoot
        let nextWorkshop = await WorkshopObservatorySnapshot.load(
            store: SwiftNativeDeskStore(dataRoot: deskRoot),
            receiptsPath: deskRoot
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("receipts.jsonl")
        )
        guard refreshCoordinator.settle(refreshGeneration) == .accepted else { return }
        detail = next
        detailEvidenceStatus = nextRead.evidenceStatus
        contextFlowHealth = nextContextFlowHealth
        contextFlowFallback = nextContextFlowFallback
        workshop = nextWorkshop
        enabled = next.configuration.enabled
        capsuleEnabled = next.configuration.capsuleInjectionEnabled
        backgroundEnabled = next.configuration.backgroundMicrocyclesEnabled
        reflectionEnabled = next.configuration.reflectiveCallsEnabled
        organismEnabled = next.organism.enabled
        reflectionBudget = next.configuration.dailyReflectionCallBudget
        if enabled {
            // Commit a render-observed readiness edge only after refresh has
            // installed both the control's enabled state and its kernel state.
            // This guarantees an initial OFF lifecycle event even when the
            // disabled Toggle appeared before the asynchronous refresh ended.
            organismControlReadinessRevision &+= 1
        }
        lastRefresh = Date()
    }

    /// Starts one mounted-button veto and holds that row disabled until its
    /// durable result (and any needed refresh) has settled. The actor remains
    /// the cross-surface guard; this local state prevents a second click from
    /// racing a stale refresh into the visible Observatory snapshot.
    private func beginVetoPursuit(_ handle: String) {
        guard vetoingPursuitHandles.insert(handle).inserted else {
            dependencies.systemToasts.push(info: "Veto already in progress.")
            return
        }
        Task {
            let shouldRefresh = await vetoPursuit(handle)
            if shouldRefresh { await refresh() }
            vetoingPursuitHandles.remove(handle)
        }
    }

    /// Veto through the same resolved Desk root the panel refresh reads. The
    /// store commits status plus rationale together and the handler guards
    /// duplicate in-flight button events. Only a settled durable outcome may
    /// refresh the visible pursuit list.
    private func vetoPursuit(_ handle: String) async -> Bool {
        let feedback = CognitionObservatoryWorkshopVetoPresentation.feedback(
            for: await vetoHandler.veto(handle)
        )
        switch feedback.tone {
        case .success:
            dependencies.systemToasts.push(success: feedback.text)
        case .info:
            dependencies.systemToasts.push(info: feedback.text)
        case .failure:
            dependencies.systemToasts.push(error: feedback.text)
        }
        return feedback.shouldRefresh
    }

    private func contextFlowHint(_ state: ContextFlowObservatoryHealthState) -> String {
        switch state {
        case .unavailable:
            return "unavailable"
        case .off:
            return "off"
        case .health(let health):
            if health.lastError != nil { return "attention" }
            return "\(health.mode.rawValue) · generation \(health.activeArenaGenerationID ?? 0)"
        }
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
        _ id: CognitionObservatoryPanelID,
        title: String,
        systemImage: String,
        tint: Color,
        count: Int? = nil,
        pending: Int = 0,
        hint: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = expandedPanels.contains(id.rawValue)
        let collapsedHint = CognitionObservatoryCollapsedRowPresentation.hint(
            raw: hint,
            isExpanded: isExpanded
        )
        return NativePanel(title: nil, systemImage: nil, tint: tint) {
            VStack(alignment: .leading, spacing: isExpanded ? NativeAgentSpacing.md : 0) {
                Button {
                    togglePanel(id.rawValue)
                } label: {
                    HStack(spacing: NativeAgentSpacing.sm) {
                        Image(systemName: systemImage)
                            .foregroundStyle(tint)
                        Text(title)
                            .font(NativeAgentFont.section)
                            .foregroundStyle(.primary)
                        CognitionObservatoryCountBadge(count: count, tint: tint)
                        if pending > 0 {
                            Text("\(pending) pending")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                        if let collapsedHint {
                            Text(collapsedHint.text)
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
                .accessibilityLabel(CognitionObservatoryCollapsedRowPresentation.accessibilityLabel(
                    title: title,
                    count: count,
                    pending: pending,
                    hint: collapsedHint
                ))
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Collapse \(title)." : "Expand \(title).")
                if isExpanded {
                    content()
                }
            }
        }
    }

    nonisolated static func organismHint(_ snapshot: OrganismSnapshot) -> String {
        // Keep the compact disclosure hint source-compatible for saved/static
        // snapshots; the opened body panel performs the real freshness check
        // and withholds stale rows rather than pretending they are current.
        CognitionObservatoryOrganismPresentation(
            snapshot: snapshot,
            now: snapshot.generatedAt
        ).collapsedHint
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
