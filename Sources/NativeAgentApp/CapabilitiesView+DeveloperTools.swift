import EngineRuntime
import MemoryV2
import Foundation
import Research
import SwiftUI
import TrustCenter
import SystemOps
import ToolRegistry
import ApprovalInbox
// Blueprint: | `CapabilitiesView+DeveloperTools.swift` | `CapabilitiesView`: research receipts, memory graph and autonomy guardrail controls |

extension CapabilitiesView {
    var developerTools: some View {
        DisclosureGroup(isExpanded: $showDeveloperTools.animation(
            NativeAgentMotion.respecting(NativeAgentMotion.arrive, reduceMotion: reduceMotion)
        )) {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                AdvancedSection(title: "Recent activity") {
                    let traceState = appModel.engine.turns.capabilityTraceTimeline
                    if case .sourceAbsent = traceState {
                        AdvancedEmptyState(
                            title: "No activity yet",
                            detail: "The activity log has not been created yet."
                        )
                    } else if case .empty = traceState {
                        AdvancedEmptyState(
                            title: "Nothing has happened yet",
                            detail: "Saving a workflow or installing an item writes the first entry."
                        )
                    } else if case .unavailable(let detail) = traceState {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recent activity is unavailable")
                                .font(ShellType.bodySemibold)
                                .foregroundStyle(NativeAgentShell.trouble)
                            Text(detail)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        if case .partial(_, let rejectedRows) = traceState {
                            Text("\(rejectedRows) unreadable \(rejectedRows == 1 ? "entry was" : "entries were") left out of this list.")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.trouble)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(traceState.traces.prefix(14)) { trace in
                            CapabilityDetailRow(title: trace.title, detail: trace.kind, status: trace.status ?? "ok")
                        }
                    }
                }

                SkillMemoryGraphPanel()

                researchLab
                hardening
            }
            .padding(.top, 12)
            .transition(NativeAgentMotion.arrivalFade)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer")
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text("Checks, logs and tools for people working on the app.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("capabilities.for-developers")
    }

    private var researchLab: some View {
        AdvancedSection(title: "Research lab") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Research objective", text: appModel.editBinding("capability-research/new", seed: "Find current best practices for lightweight autonomous agent capability systems."), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(ShellType.label)
                    .lineLimit(2...4)
                Button("Run the research lab") {
                    let submitted = researchObjective
                    Task { await runResearchLab(objective: submitted) }
                }
                .disabled(isRunningResearchLab)
            }

            if let researchLabMessage {
                researchLabMessageRow(researchLabMessage)
            }

            if !appModel.engine.desk.researchRunsLoaded {
                AdvancedWaitingLine("Reading the research lab's receipts…")
            } else if let detail = appModel.engine.desk.researchRunsError {
                Text("Research lab receipts are unavailable: \(detail)")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !appModel.engine.desk.researchRuns.isEmpty {
                    AliveEyebrow("Last known receipts")
                    researchLabRunRows(appModel.engine.desk.researchRuns)
                }
            } else if appModel.engine.desk.researchRuns.isEmpty {
                AdvancedEmptyState(
                    title: "No research runs",
                    detail: "A run started here leaves its receipt in this list."
                )
            } else {
                researchLabRunRows(appModel.engine.desk.researchRuns)
            }
        }
    }

    @MainActor
    private func runResearchLab(objective: String) async {
        isRunningResearchLab = true
        defer { isRunningResearchLab = false }
        let outcome = await appModel.runResearchLab(objective: objective)
        researchLabMessage = CapabilitiesResearchLabPresentation.message(for: outcome)
        if case .recorded = outcome {
            if researchObjective == objective { appModel.clearEditDraft("capability-research/new") }
            await appModel.engine.desk.refreshResearchRuns()
        }
    }

    private func researchLabMessageRow(_ message: CapabilitiesResearchLabPresentation.Message) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.text)
                .font(ShellType.labelSemibold)
                .foregroundStyle(researchLabColor(message.tone))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = message.detail {
                Text(detail)
                    .font(ShellType.caption)
                    .foregroundStyle(researchLabColor(message.tone))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func researchLabRunRows(_ runs: [ResearchLabRun]) -> some View {
        ForEach(runs.prefix(4)) { run in
            let message = CapabilitiesResearchLabPresentation.message(for: run)
            CapabilityDetailRow(
                title: run.objective,
                detail: message.detail ?? message.text,
                status: run.status
            )
        }
    }

    private func researchLabColor(_ tone: CapabilitiesResearchLabPresentation.Tone) -> Color {
        switch tone {
        case .success:
            NativeAgentShell.calm
        case .warning, .failure:
            NativeAgentShell.trouble
        }
    }

    private var hardening: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            AdvancedSection(title: "Autonomy guardrails") {
                if let kernel = appModel.engine.trust.autonomyKernel {
                    HStack(spacing: 12) {
                        AdvancedStatusWord(status: kernel.status)
                        if let mode = kernel.mode {
                            AdvancedMeta(AdvancedStatusWords.label(mode))
                        }
                        Spacer()
                    }
                    ForEach(kernel.guardrails) { guardrail in
                        CapabilityDetailRow(title: guardrail.title, detail: guardrail.id, status: guardrail.status)
                    }
                } else {
                    Text("The autonomy guardrails have not loaded yet.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }

            nativeMacPower
            CapabilityProductionHardeningPanel()
        }
    }
}

struct SkillMemoryGraphPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var graphQuery = "memory workflow capability"
    private var memory: MemoryFacade { appModel.engine.memory }

    var body: some View {
        AdvancedSection(title: "Skill memory graph") {
            if let snapshot = memory.graphSnapshot {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    AdvancedStat(title: "Items", value: "\(snapshot.entities.count)", detail: "memories, runs, Desk tasks, capabilities")
                    AdvancedStat(title: "Links", value: "\(snapshot.edges.count)", detail: "what produced and used what")
                    AdvancedStat(title: "Capabilities", value: "0", detail: "listed in the graph")
                }

                if let error = memory.graphLoadError {
                    Text("\(error) What is shown may be out of date.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    AdvancedStatusWord(status: AgentGraphReads.graphIndexStatus(from: snapshot).status)
                    AdvancedMeta("\(snapshot.entities.count) entities")
                    TextField("Search the graph", text: $graphQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                    Button("Search") {
                        Task { await appModel.searchGraph(graphQuery) }
                    }
                    .controlSize(.small)
                    Button("Refresh") {
                        Task { await appModel.refreshGraph() }
                    }
                    .controlSize(.small)
                }

                if snapshot.entities.isEmpty {
                    Text("The graph is empty. New memories and linked capability activity show up here once they are added.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !appModel.graphSearchResults.isEmpty {
                        ForEach(appModel.graphSearchResults.prefix(8)) { result in
                            CapabilityDetailRow(
                                title: result.node.label ?? AdvancedStatusWords.label(result.id),
                                detail: result.explanation ?? "Score \(String(format: "%.2f", result.score))",
                                status: result.node.status ?? "ok"
                            )
                        }
                }

                if !snapshot.entities.isEmpty {
                        ForEach(snapshot.entities.prefix(5)) { entity in
                            CapabilityDetailRow(
                                title: entity.name,
                                detail: "\(entity.mentions ?? 0) mentions · confidence \(String(format: "%.2f", entity.confidence ?? 0))",
                                status: entity.kind ?? "ok"
                            )
                        }
                }
            } else if let error = memory.graphLoadError {
                AdvancedEmptyState(
                    title: "Skill memory graph unavailable",
                    detail: error,
                    actionTitle: "Refresh the graph",
                    action: { Task { await appModel.refreshGraph() } }
                )
            } else {
                AdvancedEmptyState(
                    title: "Skill memory graph not loaded",
                    detail: "Refresh to read the current graph. This does not mean the graph is empty.",
                    actionTitle: "Refresh the graph",
                    action: { Task { await appModel.refreshGraph() } }
                )
            }
        }
    }
}

/// Result of sending a Research Lab request through the native research owner.
/// A returned run can still describe an unavailable connector, so callers must
/// inspect the receipt rather than treating a non-throwing call as success.
enum ResearchLabActionOutcome: Equatable {
    case rejected(String)
    case recorded(ResearchLabRun)
    case failed(String)
}

enum CapabilitiesResearchLabPresentation {
    enum Tone: Equatable {
        case success
        case warning
        case failure
    }

    struct Message: Equatable {
        let text: String
        let detail: String?
        let tone: Tone
    }

    static func message(for outcome: ResearchLabActionOutcome) -> Message {
        switch outcome {
        case .rejected(let detail):
            Message(text: "Research objective required", detail: detail, tone: .warning)
        case .failed(let detail):
            Message(text: "Research lab failed", detail: detail, tone: .failure)
        case .recorded(let run):
            message(for: run)
        }
    }

    static func message(for run: ResearchLabRun) -> Message {
        let status = run.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = meaningfulDetail(for: run)
        switch status {
        case "completed":
            if let error = nonempty(run.error) {
                return Message(text: "Research lab reported an error", detail: error, tone: .failure)
            }
            return Message(
                text: "Research run completed",
                detail: "\(run.sources.count) source\(run.sources.count == 1 ? "" : "s") recorded.",
                tone: .success
            )
        case "needs_connector":
            return Message(
                text: "Research needs a connector",
                detail: detail ?? "Connect a research service before this can return sources.",
                tone: .warning
            )
        case "failed", "error":
            return Message(
                text: "Research lab failed",
                detail: detail ?? "The research run came back failed, with no detail.",
                tone: .failure
            )
        default:
            return Message(
                text: "Research result needs review",
                detail: detail ?? "The research run came back with a status this page does not recognise: \(run.status).",
                tone: .warning
            )
        }
    }

    private static func meaningfulDetail(for run: ResearchLabRun) -> String? {
        nonempty(run.error) ?? nonempty(run.brief)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : bounded(trimmed)
    }

    private static func bounded(_ text: String) -> String {
        let limit = 240
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
