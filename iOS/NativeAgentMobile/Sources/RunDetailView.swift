import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `RunDetailView.swift` | One saved run, opened from Diagnostics: its readable prompt summary, the exact captured prompt copyable behind disclosure |

// MARK: - Run detail

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
                Section {
                    Text(RunDetailPromptPresentation.summary(prompt) ?? RunDetailPromptPresentation.unavailableDescription)
                    DisclosureGroup("Raw prompt") {
                        Text(prompt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy raw prompt", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = prompt
                            SystemToastCenter.shared.push(success: RunDetailCopyPresentation.successMessage(for: "Prompt"))
                        }
                    }
                } header: { AliveEyebrow("Request") }
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

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(DeskStatusWords.word(for: status))
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(NativeAgentMobileTheme.Colors.quietFill)
            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
            .clipShape(Capsule())
    }
}
