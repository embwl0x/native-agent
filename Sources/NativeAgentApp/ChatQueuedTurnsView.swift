import SwiftUI

enum ChatQueuePresentation {
    struct MenuItem: Identifiable, Equatable {
        let ordinal: Int
        let turn: QueuedChatTurn

        var id: String { turn.id }
        var sendLabel: String { "Send \(ordinal) now: \(turn.preview)" }
        var removeLabel: String { "Remove \(ordinal): \(turn.preview)" }
    }

    static func visibleTurns(_ turns: [QueuedChatTurn]) -> [QueuedChatTurn] {
        turns.filter(\.shouldDisplayInSendNextQueue)
    }

    static func menuItems(_ turns: [QueuedChatTurn]) -> [MenuItem] {
        visibleTurns(turns).enumerated().map { index, turn in
            MenuItem(ordinal: index + 1, turn: turn)
        }
    }

    static func countLabel(_ turns: [QueuedChatTurn]) -> String {
        "\(visibleTurns(turns).count) queued"
    }
}

/// Compact, session-scoped send-next chrome shared by the main and detached
/// Mac composers. Only the next turn occupies layout space; the complete queue
/// stays in a menu so it never pushes a meaningful portion of chat off-screen.
struct ChatQueuedTurnsView: View {
    @Environment(AppModel.self) private var appModel
    let sessionId: String
    let isBusy: Bool

    private var turns: [QueuedChatTurn] {
        ChatQueuePresentation.visibleTurns(appModel.queuedChatTurns(for: sessionId))
    }

    private var menuItems: [ChatQueuePresentation.MenuItem] {
        ChatQueuePresentation.menuItems(appModel.queuedChatTurns(for: sessionId))
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
            ForEach(menuItems) { item in
                Button {
                    run(item.turn)
                } label: {
                    Label(
                        item.sendLabel,
                        systemImage: item.ordinal == 1 ? "arrow.up.to.line" : "arrow.up"
                    )
                }
                Button(role: .destructive) {
                    appModel.removeQueuedChatTurn(item.turn.id, sessionId: sessionId)
                } label: {
                    Label(item.removeLabel, systemImage: "xmark")
                }
                if item.ordinal < menuItems.count { Divider() }
            }
        } label: {
            Text(ChatQueuePresentation.countLabel(appModel.queuedChatTurns(for: sessionId)))
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
