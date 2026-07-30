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

/// Presentation facts per run kind — mirrors the iOS RunKindStyle so the
/// same run reads the same on both platforms.
private enum RunKindStyle {
    static func displayName(_ kind: String) -> String {
        switch kind.lowercased() {
        case "codex": return "Codex"
        // Keep the legacy wire identifier for compatibility, but never expose
        // a maintainer's private nickname in the public product.
        case "claude": return "Claude Code"
        case "swarm": return "Swarm"
        case "mission": return "Workshop"
        default: return kind.capitalized
        }
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
            if appModel.runs.isEmpty {
                NativeEmptyState(
                    title: "No Runs Yet",
                    detail: "Codex, swarm, and Workshop runs land here as they finish.",
                    systemImage: "list.bullet.clipboard"
                )
            } else {
                List(appModel.runs) { run in
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

private struct RunRow: View {
    let run: RunRecord

    var body: some View {
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
                    StatusBadge(text: run.status.capitalized, status: run.status)
                }
                // Failures lead with the error, in failure color — a gray
                // "failed" row was the old ux_lie here.
                if let error = run.error, !error.isEmpty {
                    Text(error)
                        .lineLimit(2)
                        .foregroundStyle(NativeAgentTheme.fail)
                } else if let preview = [run.output, run.prompt]
                    .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty }) {
                    Text(preview)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
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
}

private struct RunDetailSheet: View {
    let run: RunRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
                    Text(UserDisplayFormatters.humanizeISOTimestamp(run.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(text: run.status.capitalized, status: run.status)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(NativeAgentSpacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                    Grid(alignment: .leading, horizontalSpacing: NativeAgentSpacing.xl,
                         verticalSpacing: NativeAgentSpacing.sm) {
                        if let duration = run.durationSeconds {
                            factRow("Duration", UserDisplayFormatters.humanizeDuration(duration))
                        }
                        if let model = run.model, !model.isEmpty {
                            factRow("Model", model)
                        }
                        if let requested = run.requestedModel, !requested.isEmpty, requested != run.model {
                            factRow("Requested", requested)
                        }
                        if let effort = run.reasoningEffort, !effort.isEmpty {
                            factRow("Reasoning effort", effort.capitalized)
                        }
                        if let sandbox = run.codexSandbox, !sandbox.isEmpty {
                            factRow("Sandbox", sandbox)
                        }
                        if let fileAccess = run.fileAccessMode, !fileAccess.isEmpty {
                            factRow("File access", fileAccess)
                        }
                        factRow("Run ID", run.id)
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
