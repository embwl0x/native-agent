import SwiftUI
import AppKit
import EngineRuntime
import NativeAgentShared
import PersistenceCore

// Blueprint: | `RunDetailSheet.swift` | Full prompt, output and saved run facts remain an instrument reached from Diagnostics run rows |

/// Share run-kind words through RunKindVocabulary while keeping colour and symbols Mac-specific.
private enum RunKindStyle {
    static func displayName(_ kind: String) -> String {
        RunKindVocabulary.displayName(kind, on: .mac)
    }

    static func icon(_ kind: String) -> String {
        RunKindVocabulary.symbol(kind) ?? "gearshape.2"
    }

    static func tint(_ kind: String) -> Color {
        switch kind.lowercased() {
        case "codex": return .teal
        case "claude": return .purple
        default: return .secondary
        }
    }
}

/// Optional or empty ledger fields are absent evidence, not permission to hide a fact row.
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
        let displayed = CompactDurationFormatter.string(duration)
        return displayed.isEmpty ? "Unknown" : displayed
    }

    private static func valueText(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown" : trimmed
    }
}

struct RunDetailSheet: View {
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
                    .help("Saved status: \(statusBadge.sourceStatus)")
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
                .houseInset(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
