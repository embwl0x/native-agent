import SwiftUI
import ChatTurnRuntime
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ComposerContextReceipt.swift` | `ComposerContextReceiptBody`, `ComposerContextReceiptCard` views; `LatestRead` on the shell (or standalone card) orders receipt publication |

// MARK: - The receipt body, shared by the composer card and the classic panel

struct ComposerContextReceiptBody: View {
    let state: ComposerContextReceiptState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .loading:
                caption("Reading the last turn…")
            case .noTurn:
                caption("No turn yet. Send a message and the receipt lands here.")
            case .outsideSearch:
                caption("No receipt found in the newest trace rows. Older turns are outside this search.")
            case .unavailable(let reason):
                caption("The turn trace could not be read: \(reason)")
            case .receipt(let receipt):
                rows(receipt)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer.context.card")
        .accessibilityLabel("Context receipt")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private func rows(_ receipt: ComposerContextReceipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(receipt.rows) { row in
                componentRow(row, share: receipt.share(row))
            }
        }

        Rectangle()
            .fill(NativeAgentShell.hairline)
            .frame(height: 1)
            .padding(.vertical, 2)
            .accessibilityHidden(true)

        let total = ComposerContextReceiptPresentation.total(receipt)
        let window = ComposerContextReceiptPresentation.window(receipt)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(total.label)
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.text)
            Spacer(minLength: 8)
            Text(total.value)
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.text)
                .monospacedDigit()
            Text(total.share ?? "—")
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .monospacedDigit()
                .frame(width: Self.shareWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ComposerContextReceiptPresentation.totalAccessibility(receipt)
                + (window.map { ", \($0)" } ?? "")
        )

        if let window {
            Text(window)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }

        let ran = ComposerContextReceiptPresentation.ranAt(receipt.ranAt)
        let provenance = receipt.model.map { "\($0) · \(ran)" } ?? ran
        Text(provenance)
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(
                receipt.model.map { "Last turn ran on \($0), \(ran)" } ?? "Last turn ran \(ran)"
            )
    }

    private static let shareWidth: CGFloat = 40

    private func componentRow(
        _ row: ComposerContextReceiptRow,
        share: Double?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.label)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.text)
                if let detail = row.detail {
                    Text(detail)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let value = ComposerContextReceiptPresentation.value(row) {
                Text(value)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.text)
                    .monospacedDigit()
            }
            // A component with no traced size has no share either; the column
            // stays empty rather than printing a number nobody measured.
            Text(ComposerContextReceiptPresentation.share(share) ?? "—")
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .monospacedDigit()
                .frame(width: Self.shareWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ComposerContextReceiptPresentation.rowAccessibility(row, share: share)
        )
    }
}

/// The composer's context card reads and publishes through its shell owner.
struct ComposerContextReceiptCard: View {
    let sessionId: String
    /// Publishes the receipt to the mounted composer so quiet reads list
    /// the same rows as its native popover.
    let shell: ComposerShellState
    /// A bot conversation's own model; nil is the chat model.
    var model: String? = nil
    @Environment(AppModel.self) private var appModel
    private var windowModel: String { model ?? appModel.chatModel }
    // Settings › Context window: a change re-sizes the window at once.
    @AppStorage("nativeagent.contextWindowMode") private var windowMode = ""
    @AppStorage("nativeagent.compactionThresholdTokens") private var windowSize = 0
    /// A completed turn refreshes the receipt already open in the shell.
    @State private var refreshToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerContextReceiptBody(state: shell.contextReceipt)
            if case .receipt = shell.contextReceipt {
                ComposerContextFedText(sessionId: sessionId, dataRoot: appModel.engine.dataRoot, refresh: refreshToken)
            }
        }
            // Quiet reads await publication; model and window changes refresh the receipt.
            .quietReadTask(id: "\(sessionId):\(refreshToken):\(windowModel):\(windowMode):\(windowSize)") {
                // Clear the previous receipt before reading this conversation.
                shell.contextReceipt = .loading
                _ = await shell.contextReceiptRead.read({ await ContextReceipts.read(
                    sessionId: sessionId, selectedModel: windowModel, dataRoot: appModel.engine.dataRoot
                ) }, publish: { loaded in
                    shell.contextReceipt = loaded
                })
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
                if let completed = note.object as? String, completed != sessionId { return }
                refreshToken += 1
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .nativeAgentSessionProviderUsageDidChange)
            ) { note in
                guard let updated = note.object as? String, updated == sessionId else { return }
                refreshToken += 1
            }
    }
}


/// The text the last turn was fed, whole: what the "Fed this turn" row counts.
/// Read from the record the turn saved, only when opened.
struct ComposerContextFedText: View {
    let sessionId: String
    let dataRoot: URL
    /// A completed turn reloads an open view.
    let refresh: Int
    @State private var open = false
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                Label(open ? "Hide what I was given" : "Show what I was given",
                      systemImage: open ? "chevron.down" : "chevron.right")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.composer.context.fed.toggle")
            if open {
                ScrollView {
                    Text(text ?? "Reading…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NativeAgentShell.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A fixed height: inside a popover a scroll view with only a
                // maximum measures to zero and opens empty.
                .frame(height: 300)
                .task(id: "\(sessionId):\(refresh)") { await load() }
            }
        }
    }

    private func load() async {
        let sessionId = sessionId, dataRoot = dataRoot
        let record = await Task.detached { ContextFedRecord.load(sessionId: sessionId, dataRoot: dataRoot) }.value
        guard let record else {
            text = "Nothing saved yet for this conversation. It is kept from the next turn on."
            return
        }
        let brief = record.brief.isEmpty ? "" : "\n\n— Turn brief —\n" + record.brief
        text = record.fed + brief
    }
}
