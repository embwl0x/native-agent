import SwiftUI
import EngineRuntime
import NativeAgentCore
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
                caption("No receipt found in today's or yesterday's trace. Older turns are outside this search.")
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

/// The card the composer's context ring opens. It owns only its own read.
struct ComposerContextReceiptCard: View {
    let sessionId: String
    /// The shell this card is a pane of, when it is one. The card publishes
    /// what it loaded here so a page read of the open pane lists the same
    /// rows; nil for the classic panel, which nothing reads that way.
    var shell: ComposerShellState? = nil
    /// A bot conversation's own model; nil is the chat model.
    var model: String? = nil
    @Environment(AppModel.self) private var appModel
    @State private var state: ComposerContextReceiptState = .loading
    @State private var receiptRead = LatestRead()
    private var windowModel: String { model ?? appModel.chatModel }
    // Settings › Context window: a change re-sizes the window at once.
    @AppStorage("nativeagent.contextWindowMode") private var windowMode = ""
    @AppStorage("nativeagent.compactionThresholdTokens") private var windowSize = 0
    /// Bumped by a completed turn, so a receipt that is already open moves on
    /// to the turn that just finished instead of standing still (Sol).
    @State private var refreshToken = 0

    var body: some View {
        ComposerContextReceiptBody(state: shell?.contextReceipt ?? state)
            // `quietReadTask`, not `.task`: this only fetches and assigns, and
            // the offscreen copy a quiet page read mounts must WAIT for it —
            // otherwise the screenshot of an open context pane is a picture of
            // the word "Reading the last turn…". The selected model is in the
            // id so a model pick re-scales every percent at once.
            .quietReadTask(id: "\(sessionId):\(refreshToken):\(windowModel):\(windowMode):\(windowSize)") {
                // Sol, 2026-09-17: switching conversations used to leave the
                // previous one's receipt on screen for the length of two
                // reads, and a fresh conversation showed the old turn. The
                // card empties FIRST; what replaces it belongs to this id.
                state = .loading
                shell?.contextReceipt = .loading
                _ = await (shell?.contextReceiptRead ?? receiptRead).read({ await ContextReceiptProjection.read(
                    sessionId: sessionId, selectedModel: windowModel, dataRoot: appModel.engine.dataRoot
                ) }, publish: { loaded in
                state = loaded
                shell?.contextReceipt = loaded
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
