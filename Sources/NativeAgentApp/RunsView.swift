import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

/// Presentation facts per run kind. Shared human-facing vocabulary lives in
/// `RunKindVocabulary`; colour and symbol remain Mac presentation choices.
private enum RunKindStyle {
    static func displayName(_ kind: String) -> String {
        RunKindVocabulary.displayName(kind, on: .mac)
    }

    static func icon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "codex": return "terminal"
        case "claude": return "sparkles"
        case "swarm": return "circle.hexagongrid.fill"
        case "mission": return "target"
        default: return "gearshape.2"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind.lowercased() {
        case "codex": return .teal
        case "claude": return .purple
        case "swarm": return .orange
        case "mission": return .blue
        default: return .secondary
        }
    }
}

struct RunsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedRun: RunRecord?

    var body: some View {
        Group {
            switch RunsPresentation.state(
                runs: appModel.runs,
                staleNotice: appModel.panelStaleNotice(for: .diagnostics)
            ) {
            case .unavailable(let unavailable):
                NativeEmptyState(
                    title: "Runs unavailable",
                    detail: unavailable,
                    systemImage: "exclamationmark.triangle"
                )
            case .empty:
                NativeEmptyState(
                    title: "No Runs Yet",
                    detail: "Codex, swarm, and Desk runs land here as they finish.",
                    systemImage: "list.bullet.clipboard"
                )
            case .rows(let runs):
                List(runs) { run in
                    Button {
                        selectedRun = run
                    } label: {
                        RunRow(run: run)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Runs")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshForSidebarItem(.diagnostics) }
            }
        }
        .sheet(item: $selectedRun) { run in
            RunDetailSheet(run: run)
        }
    }
}

enum RunsPresentation {
    enum State {
        case unavailable(String)
        case empty
        case rows([RunRecord])
    }

    static func state(runs: [RunRecord], staleNotice: String?) -> State {
        if let staleNotice, !staleNotice.isEmpty { return .unavailable(staleNotice) }
        return runs.isEmpty ? .empty : .rows(runs)
    }
}

/// The runs ledger is intentionally forward-compatible: its `status` field is
/// raw writer vocabulary rather than a closed Codable enum.  This boundary is
/// where that vocabulary becomes a human-facing badge, so an old or future
/// writer cannot make a failure-like outcome look like an ordinary neutral
/// pill merely because its raw spelling is new.
enum RunStatusBadgePresentation {
    struct Badge: Equatable, Sendable {
        let label: String
        /// A vocabulary value understood by `NativeAgentTheme.statusColor`.
        let themeStatus: String
        /// Bounded source detail for accessibility/tooltips and diagnostics.
        let sourceStatus: String
    }

    /// Statuses emitted by the current native run writers and retained ledger
    /// history. Aliases stay here rather than relying on generic capitalization
    /// at every Runs surface.
    static let knownRawStatuses: Set<String> = [
        "active", "blocked", "canceled", "cancelled", "completed", "done",
        "disabled", "failed", "failed_pre_dispatch", "interrupted", "pending",
        "queued", "rolled_back", "running", "skipped", "succeeded", "timeout",
        "timed_out", "unknown", "waiting_approval"
    ]

    static func badge(for rawStatus: String) -> Badge {
        let sourceStatus = boundedRawStatus(rawStatus)
        let key = normalizedKey(rawStatus)
        switch key {
        case "succeeded", "completed", "done":
            return Badge(label: "Succeeded", themeStatus: "ok", sourceStatus: sourceStatus)
        case "queued", "pending":
            return Badge(label: "Queued", themeStatus: "info", sourceStatus: sourceStatus)
        case "running", "active":
            return Badge(label: "Running", themeStatus: "running", sourceStatus: sourceStatus)
        case "failed", "failed_pre_dispatch":
            return Badge(label: "Failed", themeStatus: "failed", sourceStatus: sourceStatus)
        case "timeout", "timed_out":
            return Badge(label: "Timed out", themeStatus: "timeout", sourceStatus: sourceStatus)
        case "canceled", "cancelled":
            return Badge(label: "Cancelled", themeStatus: "interrupted", sourceStatus: sourceStatus)
        case "interrupted":
            return Badge(label: "Interrupted", themeStatus: "interrupted", sourceStatus: sourceStatus)
        case "blocked":
            return Badge(label: "Blocked", themeStatus: "blocked", sourceStatus: sourceStatus)
        case "waiting_approval":
            return Badge(label: "Waiting for approval", themeStatus: "blocked", sourceStatus: sourceStatus)
        case "rolled_back":
            return Badge(label: "Rolled back", themeStatus: "warn", sourceStatus: sourceStatus)
        case "skipped":
            return Badge(label: "Skipped", themeStatus: "warn", sourceStatus: sourceStatus)
        case "disabled":
            return Badge(label: "Disabled", themeStatus: "warn", sourceStatus: sourceStatus)
        case "unknown":
            return Badge(label: "Outcome unknown", themeStatus: "warn", sourceStatus: sourceStatus)
        case "":
            return Badge(label: "Status unavailable", themeStatus: "warn", sourceStatus: sourceStatus)
        default:
            return Badge(
                label: "Unrecognized status: \(sourceStatus)",
                themeStatus: "warn",
                sourceStatus: sourceStatus
            )
        }
    }

    private static func normalizedKey(_ rawStatus: String) -> String {
        rawStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func boundedRawStatus(_ rawStatus: String) -> String {
        let trimmed = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(missing)" }
        let compact = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 80 ? String(compact.prefix(80)) + "…" : compact
    }
}

/// The compact row's one-line account of a run. A prompt is an input, never a
/// result; keeping that distinction in the projection prevents an unfinished
/// run from reading as though it answered.
enum RunPreviewPresentation {
    enum Kind: Equatable {
        case error
        case output
        case promptOnly
        case unavailable
    }

    struct Preview: Equatable {
        let kind: Kind
        let text: String
    }

    static func preview(for run: RunRecord) -> Preview {
        if let error = nonEmpty(run.error) {
            return Preview(kind: .error, text: error)
        }
        if let output = nonEmpty(run.output) {
            return Preview(kind: .output, text: "Output: \(output)")
        }
        if let prompt = nonEmpty(run.prompt) {
            return Preview(kind: .promptOnly, text: "Prompt (no result yet): \(prompt)")
        }
        return Preview(kind: .unavailable, text: "No result or prompt recorded.")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One truthful projection of a durable run record for the detail sheet.  The
/// ledger permits optional fields and older writers can emit empty strings, so
/// the sheet must distinguish absent evidence from a fact row that vanished.
enum RunDetailPresentation {
    struct Fact: Identifiable, Equatable {
        let label: String
        let value: String

        var id: String { label }
    }

    static func createdAtText(for run: RunRecord) -> String {
        let raw = run.createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Unknown" }
        let displayed = UserDisplayFormatters.humanizeISOTimestamp(raw)
        return displayed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : displayed
    }

    static func facts(for run: RunRecord) -> [Fact] {
        [
            Fact(label: "Duration", value: durationText(run.durationSeconds)),
            Fact(label: "Model", value: valueText(run.model)),
            Fact(label: "Requested", value: valueText(run.requestedModel)),
            Fact(label: "Reasoning effort", value: valueText(run.reasoningEffort).capitalized),
            Fact(label: "Sandbox", value: valueText(run.codexSandbox)),
            Fact(label: "File access", value: valueText(run.fileAccessMode)),
            Fact(label: "Run ID", value: valueText(run.id)),
        ]
    }

    private static func durationText(_ duration: Double?) -> String {
        guard let duration else { return "Unknown" }
        let displayed = UserDisplayFormatters.humanizeDuration(duration)
        return displayed.isEmpty ? "Unknown" : displayed
    }

    private static func valueText(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown" : trimmed
    }
}

private struct RunRow: View {
    let run: RunRecord

    var body: some View {
        let statusBadge = RunStatusBadgePresentation.badge(for: run.status)
        HStack(alignment: .top, spacing: NativeAgentSpacing.md) {
            Image(systemName: RunKindStyle.icon(run.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RunKindStyle.tint(run.kind))
                .frame(width: 30, height: 30)
                .background(RunKindStyle.tint(run.kind).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                HStack {
                    Text(RunKindStyle.displayName(run.kind))
                        .font(.headline)
                    Spacer()
                    StatusBadge(text: statusBadge.label, status: statusBadge.themeStatus)
                        .help("Ledger status: \(statusBadge.sourceStatus)")
                }
                let preview = RunPreviewPresentation.preview(for: run)
                Text(preview.text)
                    .lineLimit(2)
                    .foregroundStyle(previewColor(preview.kind))
                HStack(spacing: NativeAgentSpacing.sm) {
                    Text(UserDisplayFormatters.humanizeISOTimestamp(run.createdAt))
                    if let duration = run.durationSeconds {
                        Text("·")
                        Text(UserDisplayFormatters.humanizeDuration(duration))
                    }
                    if let model = run.model, !model.isEmpty {
                        Text("·")
                        Text(model).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help("Click for full prompt and output")
    }

    private func previewColor(_ kind: RunPreviewPresentation.Kind) -> Color {
        switch kind {
        case .error: NativeAgentTheme.fail
        case .output, .promptOnly: .secondary
        case .unavailable: Color.secondary.opacity(0.7)
        }
    }
}

private struct RunDetailSheet: View {
    let run: RunRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let statusBadge = RunStatusBadgePresentation.badge(for: run.status)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NativeAgentSpacing.md) {
                Image(systemName: RunKindStyle.icon(run.kind))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RunKindStyle.tint(run.kind))
                    .frame(width: 38, height: 38)
                    .background(RunKindStyle.tint(run.kind).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(RunKindStyle.displayName(run.kind))
                        .font(.title3.weight(.semibold))
                    Text(RunDetailPresentation.createdAtText(for: run))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(text: statusBadge.label, status: statusBadge.themeStatus)
                    .help("Ledger status: \(statusBadge.sourceStatus)")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(NativeAgentSpacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                    Grid(alignment: .leading, horizontalSpacing: NativeAgentSpacing.xl,
                         verticalSpacing: NativeAgentSpacing.sm) {
                        ForEach(RunDetailPresentation.facts(for: run)) { fact in
                            factRow(fact.label, fact.value)
                        }
                    }

                    if let error = run.error, !error.isEmpty {
                        textBlock("Error", systemImage: "exclamationmark.triangle",
                                  text: error, tint: NativeAgentTheme.fail)
                    }
                    if let prompt = run.prompt, !prompt.isEmpty {
                        textBlock("Prompt", systemImage: "text.bubble", text: prompt)
                    }
                    if let output = run.output, !output.isEmpty {
                        textBlock("Output", systemImage: "text.alignleft", text: output)
                    }
                }
                .padding(NativeAgentSpacing.lg)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 560)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(NativeAgentFont.mono)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func textBlock(_ title: String, systemImage: String, text: String,
                           tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(NativeAgentFont.section)
                    .foregroundStyle(tint)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Text(text)
                .font(NativeAgentFont.mono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NativeAgentSpacing.md)
                .background(.quaternary.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
