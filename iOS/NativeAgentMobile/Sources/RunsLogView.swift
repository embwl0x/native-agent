import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `RunsLogView.swift` | Run history, rows and complete run detail |

// MARK: - Runs log

struct RunsLogView: View {
    @ObservedObject var store: AdvancedStore
    private let sync = iCloudSyncEngine.shared

    var body: some View {
        List {
            AlivePageHeader(title: "Runs Log", line: "What I've run on the Mac lately.", style: .pushed)
                .padding(.horizontal, 4)
                .aliveListRow(top: 4, bottom: 6)
            switch RunsLogPresentation.state(runs: sync.runs, error: store.runsLoadError) {
            case .unavailable(let error):
                AliveCalmState(title: "Runs are not available", line: error)
                    .aliveListRow()
            case .empty:
                AliveCalmState(title: "No runs yet", line: "The latest Mac run snapshot contains no runs.")
                    .aliveListRow()
            case .content:
                ForEach(sync.runs) { run in
                    NavigationLink {
                        RunDetailView(run: run)
                    } label: {
                        RunRowView(run: run)
                    }
                }
                .listRowBackground(AlivePalette.fill)
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .alivePageChrome(title: "Runs Log", root: false)
        .task { await store.refreshRuns() }
        .refreshable { await store.refreshRuns() }
        .onChange(of: sync.runs) { _, runs in
            store.runsDidChange(runs)
        }
    }
}

private struct RunRowView: View {
    let run: RunRecord

    var body: some View {
        MobileAdaptiveRow(alignment: .top, spacing: 12) {
            Image(systemName: RunKindPresentation.icon(run.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(NativeAgentMobileTheme.Colors.quietFill,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                MobileAdaptiveRow {
                    Text(RunKindPresentation.displayName(run.kind))
                        .font(.headline)
                    Spacer()
                    StatusBadge(status: run.status)
                }
                if let prompt = run.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MobileAdaptiveRow(spacing: 6) {
                    Text(UserDisplayFormatters.humanizeISOTimestamp(run.createdAt))
                    if let duration = run.durationSeconds {
                        Text("·")
                        Text(UserDisplayFormatters.humanizeDuration(duration))
                    }
                    if let model = run.model, !model.isEmpty {
                        Text("·")
                        Text(model).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
                .foregroundStyle(AlivePalette.secondary)
                .accessibilityLabel("Recorded \(run.createdAt)")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Run detail

/// Full record for one run: what ran, with which model/settings, the whole
/// prompt, and the whole output/error. Content stays on plain list rows —
/// no glass on the content layer.
struct RunDetailView: View {
    let run: RunRecord

    var body: some View {
        List {
            AlivePageHeader(title: "Run detail", style: .pushed)
                .padding(.horizontal, 4)
                .aliveListRow(top: 4, bottom: 6)
            Group {
            Section {
                MobileAdaptiveRow(spacing: 12) {
                    Image(systemName: RunKindPresentation.icon(run.kind))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(NativeAgentMobileTheme.Colors.quietFill,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RunKindPresentation.displayName(run.kind))
                            .font(.title2.weight(.semibold))
                        Text(UserDisplayFormatters.humanizeISOTimestamp(run.createdAt))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(status: run.status)
                }
                .padding(.vertical, 2)
                if let duration = run.durationSeconds {
                    LabeledContent("Duration", value: UserDisplayFormatters.humanizeDuration(duration))
                }
                if let date = UserDisplayFormatters.parseISOTimestamp(run.createdAt) {
                    LabeledContent("Started") {
                        Text(date, format: .dateTime.month().day().hour().minute().second())
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Run ID") {
                    Text(run.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            let modelFacts = RunDetailPresentation.modelFacts(for: run)
            if !modelFacts.isEmpty {
                Section {
                    ForEach(modelFacts) { fact in
                        LabeledContent(fact.label, value: fact.value)
                    }
                } header: { AliveEyebrow("Model") }
            }

            if let prompt = RunDetailPromptPresentation.copyablePrompt(run.prompt) {
                runTextSection("Prompt", systemImage: "text.bubble", text: prompt)
            } else {
                Section {
                    Text(RunDetailPromptPresentation.unavailableDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { AliveEyebrow("Prompt") }
            }
            if let error = run.error, !error.isEmpty {
                Section {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: { AliveEyebrow("Error") }
            }
            if let output = run.output, !output.isEmpty {
                runTextSection("Output", systemImage: "text.alignleft", text: output)
            }
            }
            .listRowBackground(AlivePalette.fill)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .alivePageChrome(title: "Run Detail", root: false)
    }

    private func runTextSection(_ title: String, systemImage: String, text: String) -> some View {
        Section {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy \(title)", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                        SystemToastCenter.shared.push(
                            success: RunDetailCopyPresentation.successMessage(for: title)
                        )
                    }
                }
        } header: { AliveEyebrow(title) }
    }
}
