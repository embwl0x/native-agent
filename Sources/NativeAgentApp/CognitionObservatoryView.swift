import Foundation
import NativeAgentShared
import EngineRuntime
import Cognition
import BackgroundLoops
import TurnTrace
import SwiftUI

// Blueprint: | `CognitionObservatoryView.swift` | `CognitionObservatoryView`: live panel assembly, live dependency reads, override controls and persistence/feedback presentation |

enum CognitionObservatoryPanelID: String, CaseIterable, Sendable {
    case controls
    case contextFlow
    case workshop
    case organism
    case loop
    case workspace
    case associations
    case tensions
    case affect
    case timeline
    case capsule
    case reflections
}

import Observation
import CognitiveSubstrate
import Context
import ContextFlow
import PersistenceCore
import Desk

struct CognitionObservatoryView: View {
    struct Dependencies {
        let dataRoot: URL
        let agentDisplayName: String
        let systemToasts: SystemToastCenter
        let contextFlowHealth: () async -> ContextFlowObservatoryHealthState

        @MainActor
        static func live(appModel: AppModel) -> Self {
            Self(
                dataRoot: appModel.engine.dataRoot,
                agentDisplayName: appModel.agentDisplayName,
                systemToasts: appModel.systemToasts,
                contextFlowHealth: { await appModel.engine.contextFlow.observatoryHealthState() }
            )
        }
    }

    let cognition: CognitionViewFacade
    let runtime: NativeCognitionRuntime
    let dependencies: Dependencies
    @State private var isRunningReflection = false

    init(
        cognition: CognitionViewFacade,
        runtime: NativeCognitionRuntime,
        dependencies: Dependencies
    ) {
        self.cognition = cognition
        self.runtime = runtime
        self.dependencies = dependencies
    }

    private var workspaceAblated: Bool { cognition.detail?.summary.ablations["workspace"] == false }
    private var affectPresentation: CognitionObservatoryAffectPresentation {
        CognitionObservatoryAffectPresentation(
            configuration: cognition.detail?.configuration,
            affect: cognition.detail?.summary.affect,
            capsulePreviewInfo: cognition.detail?.capsulePreviewInfo
        )
    }

    var body: some View {
        let enabled = cognition.detail?.configuration.enabled ?? false
        let reflectionEnabled = cognition.detail?.configuration.reflectiveCallsEnabled ?? false
        let reflectionBudget = cognition.detail?.configuration.dailyReflectionCallBudget ?? 0
        let organismEnabled = cognition.detail?.organism.enabled ?? false
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                HStack {
                    Text("Cognition").font(NativeAgentFont.title).foregroundStyle(NativeAgentShell.text)
                    Spacer()
                    StatusBadge(text: cognition.detail == nil ? "Loading…" : (enabled ? "Enabled" : "Off"),
                                status: cognition.detail == nil ? "pending" : (enabled ? "ok" : "warn"))
                    if let lastRefresh = cognition.lastRefresh {
                        Text("updated \(lastRefresh, style: .time)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .unavailable(let reason) = cognition.detail?.receiptRead {
                    Label(
                        CognitionObservatoryPresentation.receiptEvidenceUnavailableText(reason),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.orange)
                }

                collapsible(.controls, title: "Controls", systemImage: "slider.horizontal.3", tint: .teal,
                            hint: cognition.detail == nil ? "Loading…" : (enabled ? "on" : "off")) {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        Toggle("Give me a thought summary", isOn: capsuleEnabledBinding)
                            .disabled(!enabled)
                        Toggle("Keep thinking in the background", isOn: backgroundEnabledBinding)
                            .disabled(!enabled)
                        Stepper("Reflections in 24 hours: \(reflectionBudget)", value: reflectionBudgetBinding, in: 0...8)
                            .disabled(!enabled || !reflectionEnabled)
                        // One home per switch: the inner life, reflection and
                        // moods are switched on Settings, and the master sets
                        // ALL of these together; these are the Observatory
                        // overrides that live only here.
                        Text("An inner life, reflection and moods are switched in Settings \u{25B8} Inner life. Turning the inner life on or off there resets these too.")
                            .font(.caption2)
                            .foregroundStyle(NativeAgentShell.secondary)
                        HStack(spacing: NativeAgentSpacing.sm) {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await refresh() }
                            }
                            .disabled(cognition.isRefreshing)
                            Button("Think now", systemImage: "waveform.path.ecg") {
                                Task {
                                    await runtime.runMicrocycle(reason: "observatory manual run")
                                    await refresh()
                                }
                            }
                            .disabled(!enabled)
                            Button("Reflect", systemImage: "brain.head.profile") {
                                Task {
                                    isRunningReflection = true
                                    let outcome = await runtime.runManualReflection()
                                    CognitionObservatoryControlFeedback.publish(outcome, to: dependencies.systemToasts)
                                    await refresh()
                                    isRunningReflection = false
                                }
                            }
                            .disabled(!enabled || !reflectionEnabled || reflectionBudget <= 0 || isRunningReflection)
                            Button("Clear", systemImage: "trash") {
                                Task {
                                    let outcome = await runtime.clearTransientState()
                                    switch outcome {
                                    case .cleared:
                                        dependencies.systemToasts.push(success: "Thinking and body state cleared.")
                                    case .persistenceFailed(let detail):
                                        dependencies.systemToasts.push(error: "Nothing was cleared; the state was kept: \(detail)")
                                    case .bodyPersistenceFailed:
                                        dependencies.systemToasts.push(error: "Thinking state cleared. Body state cleared in memory, but was not saved; its previous state may return after a restart.")
                                    }
                                    await refresh()
                                }
                            }
                            .disabled(!enabled)
                            Button("Settle body", systemImage: "leaf") {
                                Task {
                                    let outcome = await runtime.settleOrganismContinuityChecked()
                                    CognitionObservatoryControlFeedback.publish(outcome, action: "settle", to: dependencies.systemToasts)
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || !organismEnabled)
                            Button("Reset body", systemImage: "waveform.path.ecg.rectangle") {
                                Task {
                                    let outcome = await runtime.resetOrganismContinuityChecked()
                                    CognitionObservatoryControlFeedback.publish(outcome, action: "reset", to: dependencies.systemToasts)
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || !organismEnabled)
                            Button("Leave workspace out", systemImage: "eye.slash") {
                                Task {
                                    await runtime.setAblation("workspace", enabled: false)
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || workspaceAblated)
                            Button("Include workspace", systemImage: "eye") {
                                Task {
                                    await runtime.setAblation("workspace", enabled: true)
                                    await refresh()
                                }
                            }
                            .disabled(!enabled || !workspaceAblated)
                        }
                        if workspaceAblated {
                            Label("The workspace is being left out — the thought summary and background thinking ignore it until it is included again.", systemImage: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let detail = cognition.detail {
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
                        title: "Context flow",
                        systemImage: "arrow.triangle.branch",
                        tint: .cyan,
                        hint: contextFlowHint(cognition.contextFlowHealth)
                    ) {
                        ContextFlowObservatoryPanel(healthState: cognition.contextFlowHealth)
                    }
                    // Workshop diagnostics use live store queries; owner controls live on Desk item rows.
                    collapsible(
                        .workshop,
                        title: "Desk",
                        systemImage: "hammer",
                        tint: .purple,
                        count: cognition.workshop?.model?.openPursuitCount,
                        hint: cognition.workshop?.hint
                    ) {
                        WorkshopObservatoryPanel(snapshot: cognition.workshop)
                    }
                    collapsible(.organism, title: "Body signals", systemImage: "waveform.path.ecg", tint: .green,
                                hint: Self.organismHint(detail.organism)) {
                        organism(detail.organism)
                    }
                    // Collapsed readout headers show whether their group has activity.
                    collapsible(.loop, title: "Loop activity", systemImage: "clock.arrow.circlepath", tint: .teal,
                                count: CognitionLoopActivityPresentation.receiptCount(for: detail.receiptRead),
                                hint: CognitionLoopActivityPresentation.collapsedHint(for: detail.receiptRead)) {
                        loopActivity(detail.receiptRead)
                    }
                    collapsible(.workspace, title: "Workspace", systemImage: "rectangle.3.group", tint: .blue,
                                count: detail.workspace.items.count) {
                        workspace(detail.workspace)
                    }
                    collapsible(.associations, title: "Association graph", systemImage: "point.3.connected.trianglepath.dotted", tint: .blue,
                                count: detail.associations.count) {
                        associationGraph(detail.associations, nodes: detail.substrate.nodes)
                    }
                    collapsible(.tensions, title: "Tensions and pruning", systemImage: "scissors", tint: .red) {
                        tensionsAndPruning(detail)
                    }
                    collapsible(.affect, title: "Mood signals", systemImage: "gauge.with.dots.needle.bottom.50percent", tint: .purple,
                                hint: affectPresentation.collapsedHint) {
                        affect(affectPresentation)
                    }
                    collapsible(.timeline, title: "How I have grown", systemImage: "timeline.selection", tint: .pink,
                                count: detail.developmentalTimeline.count) {
                        developmentalTimeline(detail.developmentalTimeline, week: detail.growthWeek)
                    }
                    collapsible(.capsule, title: "Thought summary preview", systemImage: "doc.plaintext", tint: .cyan,
                                hint: capsuleHint(detail.capsulePreviewInfo)) {
                        capsule(detail.capsulePreview, info: detail.capsulePreviewInfo,
                                feltMode: detail.feltMode)
                    }
                    collapsible(.reflections, title: "Reflection records", systemImage: "brain.head.profile", tint: .teal,
                                count: detail.reflections.count) {
                        reflections(detail.reflections)
                    }
                } else {
                    collapsible(.affect, title: "Mood signals", systemImage: "gauge.with.dots.needle.bottom.50percent", tint: .purple,
                                hint: affectPresentation.collapsedHint) {
                        affect(affectPresentation)
                    }
                    NativeEmptyState(
                        title: "Cognition",
                        detail: cognition.isRefreshing ? "Loading." : "Nothing has loaded yet."
                    )
                }

                // The agent projection and raw all-items table belong here;
                // the primary Desk keeps zero debug
                // chrome. Both render the engine’s retained Desk revision.
                DeskDebugPanels(
                    agentDisplayName: dependencies.agentDisplayName
                )
            }
            .padding(NativeAgentSpacing.xl)
        }
        // Diagnostics owns navigation; Controls carries Refresh.
        .task(id: expandedPanels.contains(CognitionObservatoryPanelID.workshop.rawValue)) {
            let changes = await cognition.changes()
            // Subscribe before reading so changes during refresh are buffered.
            await refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                // The stream is buffering-newest, so a tool burst collapses
                // while this read is in flight without a timer or idle wake.
                await refresh()
            }
        }
    }

    private var capsuleEnabledBinding: Binding<Bool> {
        Binding(get: { cognition.detail?.configuration.capsuleInjectionEnabled ?? false }, set: { value in
            cognition.detail?.configuration.capsuleInjectionEnabled = value
            Task { await runtime.setCapsuleEnabled(value); await refresh() }
        })
    }

    private var backgroundEnabledBinding: Binding<Bool> {
        Binding(get: { cognition.detail?.configuration.backgroundMicrocyclesEnabled ?? false }, set: { value in
            cognition.detail?.configuration.backgroundMicrocyclesEnabled = value
            Task { await runtime.setBackgroundEnabled(value); await refresh() }
        })
    }

    private var reflectionBudgetBinding: Binding<Int> {
        Binding(get: { cognition.detail?.configuration.dailyReflectionCallBudget ?? 0 }, set: { value in
            cognition.detail?.configuration.dailyReflectionCallBudget = value
            Task { await runtime.setReflectionBudget(value); await refresh() }
        })
    }

    func refresh() async {
        await cognition.refreshObservatory(
            includeWorkshopReceipts: { expandedPanels.contains(CognitionObservatoryPanelID.workshop.rawValue) },
            contextFlowHealthRead: dependencies.contextFlowHealth
        )
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
        withAnimation(NativeAgentMotion.quick) {
            expandedPanelsRaw = set.sorted().joined(separator: ",")
        }
    }

    /// Same card chrome as NativePanel, but the header row is the disclosure
    /// control: count badge + a one-line hint while
    /// collapsed, chevron flips on expand. Panel ids must not contain commas.
    private func collapsible<Content: View>(
        _ id: CognitionObservatoryPanelID,
        title: String,
        systemImage: String,
        tint: Color,
        count: Int? = nil,
        hint: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = expandedPanels.contains(id.rawValue)
        let collapsedHint = CognitionObservatoryCollapsedRowPresentation.hint(
            raw: hint,
            isExpanded: isExpanded
        )
        return NativePanel(title: nil) {
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
                        if let collapsedHint {
                            Text(collapsedHint)
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

/// Presentation policy for a collapsed Observatory disclosure row. The compact
/// text is a status summary, not an unbounded diagnostic channel: preserve a
/// real state, normalize malformed whitespace, and expose the same bounded
/// summary to VoiceOver and the visible row.
enum CognitionObservatoryCollapsedRowPresentation {
    static let maximumVisibleHintCharacters = 96

    static func hint(raw: String?, isExpanded: Bool) -> String? {
        guard !isExpanded,
              let raw else { return nil }
        let normalized = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maximumVisibleHintCharacters else {
            return normalized
        }
        return String(normalized.prefix(maximumVisibleHintCharacters)) + "…"
    }

    static func accessibilityLabel(
        title: String,
        count: Int?,
        hint: String?
    ) -> String {
        var parts = [title]
        if let badge = CognitionObservatoryCountBadgePresentation.badge(for: count) {
            let count = badge.count
            parts.append("\(count) item\(count == 1 ? "" : "s")")
        }
        if let hint {
            parts.append(hint)
        }
        return parts.joined(separator: ", ")
    }
}

enum CognitionObservatoryPresentation {
    static func receiptEvidenceUnavailableText(_ reason: CognitiveReceiptReadUnavailability) -> String {
        switch reason {
        case .cognitionDisabled:
            return "The records behind this page are unavailable while cognition is off."
        case .persistenceDisabled:
            return "The records behind this page are unavailable because cognition is not saving anything."
        case .storeUnavailable:
            return "The records behind this page are unavailable because their store could not be opened."
        case .readFailed:
            return "The records behind this page could not be read."
        }
    }

}

@MainActor
enum CognitionObservatoryControlFeedback {
    static func publish(_ outcome: LoopTickOutcome, to toasts: SystemToastCenter) {
        switch outcome {
        case .completed:
            toasts.push(success: "Reflection recorded.")
        case .skipped(let reason, _):
            toasts.push(info: "Reflection skipped: \(reason)")
        case .failed(let reason):
            toasts.push(error: "Reflection failed: \(reason)")
        }
    }

    static func publish(_ outcome: OrganismContinuityApplyOutcome, action: String, to toasts: SystemToastCenter) {
        switch outcome.status {
        case .applied:
            toasts.push(success: action == "reset" ? "Body state reset and saved." : "Body state settled and saved.")
        case .organismDisabled:
            toasts.push(info: outcome.error ?? "Body signals are off.")
        case .persistenceFailed:
            toasts.push(error: outcome.error ?? "Body state was not saved.")
        }
    }
}
