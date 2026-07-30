import SwiftUI

/// Compact, session-scoped send-next chrome shared by the main and detached
/// Mac composers. Only the next turn occupies layout space; the complete queue
/// stays in a menu so it never pushes a meaningful portion of chat off-screen.
struct ChatQueuedTurnsView: View {
    @Environment(AppModel.self) private var appModel
    let sessionId: String
    let isBusy: Bool

    private var turns: [QueuedChatTurn] {
        appModel.queuedChatTurns(for: sessionId).filter(\.shouldDisplayInSendNextQueue)
    }

    var body: some View {
        if let next = turns.first {
            HStack(spacing: 7) {
                Image(systemName: appModel.isChatQueuePaused(sessionId)
                      ? "pause.fill"
                      : "text.line.last.and.arrowtriangle.forward")
                    .foregroundStyle(NativeAgentBrand.accentDeep)

                Text(appModel.isChatQueuePaused(sessionId) ? "Paused" : "Next")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(next.preview)
                    .font(NativeAgentFont.tag)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !next.attachments.isEmpty {
                    Label("\(next.attachments.count)", systemImage: "paperclip")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                queueMenu

                Button(isBusy ? "Steer" : "Send next") {
                    run(next)
                }
                .buttonStyle(.borderless)
                .help(isBusy
                      ? "Stop the current response and run this message next"
                      : "Run this queued message now")

                Button {
                    appModel.removeQueuedChatTurn(next.id, sessionId: sessionId)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove next queued message")
                .accessibilityLabel("Remove next queued message")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                NativeAgentBrand.accent.opacity(0.07),
                in: RoundedRectangle(cornerRadius: NativeAgentRadius.control)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Send-next queue, \(turns.count) queued")
        }
    }

    private var queueMenu: some View {
        Menu {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                Button {
                    run(turn)
                } label: {
                    Label(
                        "Send \(index + 1) now: \(turn.preview)",
                        systemImage: index == 0 ? "arrow.up.to.line" : "arrow.up"
                    )
                }
                Button(role: .destructive) {
                    appModel.removeQueuedChatTurn(turn.id, sessionId: sessionId)
                } label: {
                    Label("Remove \(index + 1): \(turn.preview)", systemImage: "xmark")
                }
                if index < turns.count - 1 { Divider() }
            }
        } label: {
            Text("\(turns.count) queued")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show all queued messages")
        .accessibilityLabel("Show all \(turns.count) queued messages")
    }

    private func run(_ turn: QueuedChatTurn) {
        if isBusy {
            appModel.steerQueuedChatTurn(turn.id, sessionId: sessionId)
        } else {
            appModel.resumeQueuedChatTurns(sessionId: sessionId, startingWith: turn.id)
        }
    }
}
