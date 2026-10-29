import SwiftUI
import ChatTurnRuntime

// Blueprint: | `ChatQueuedTurnsView.swift` | `ChatQueuedTurnsView`: bounded session-scoped send-next chips, overflow and steer/send-now controls |

enum ChatQueuePresentation {
    /// Chips that take layout space; the rest wait behind "+N more".
    static let visibleChipCount = 3

    struct MenuItem: Identifiable, Equatable {
        let ordinal: Int
        let turn: QueuedChatTurn

        var id: String { turn.id }
        var sendLabel: String { "Send \(ordinal) now: \(turn.preview)" }
        var steerLabel: String { "Steer \(ordinal) into the reply in progress: \(turn.preview)" }
        var removeLabel: String { "Remove \(ordinal): \(turn.preview)" }

        func actionLabel(isBusy: Bool) -> String {
            isBusy ? "Stop current response and send \(ordinal): \(turn.preview)" : sendLabel
        }
    }

    static func visibleTurns(_ turns: [QueuedChatTurn]) -> [QueuedChatTurn] {
        turns.filter(\.shouldDisplayInSendNextQueue)
    }

    static func menuItems(_ turns: [QueuedChatTurn]) -> [MenuItem] {
        visibleTurns(turns).enumerated().map { index, turn in
            MenuItem(ordinal: index + 1, turn: turn)
        }
    }
}

/// Both Mac composers show queued sends in order, with actions to steer or send now.
struct ChatQueuedTurnsView: View {
    @Environment(AppModel.self) private var appModel
    let sessionId: String
    let isBusy: Bool

    var body: some View {
        let items = ChatQueuePresentation.menuItems(appModel.engine.turns.queued(for: sessionId))
        if !items.isEmpty {
            let shown = Array(items.prefix(ChatQueuePresentation.visibleChipCount))
            let overflow = items.count - shown.count
            VStack(spacing: 3) {
                ForEach(shown) { item in
                    chip(item.turn, ordinal: item.ordinal,
                         overflow: item.ordinal == shown.count ? overflow : 0, items: items)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Send-next queue, \(items.count) queued")
        }
    }

    private func chip(_ turn: QueuedChatTurn, ordinal: Int, overflow: Int, items: [ChatQueuePresentation.MenuItem]) -> some View {
        let paused = appModel.engine.turns.isQueuePaused(sessionId)
        return HStack(spacing: 7) {
            if ordinal == 1 {
                Image(systemName: paused ? "pause.fill" : "text.line.last.and.arrowtriangle.forward")
                    .foregroundStyle(NativeAgentShell.secondary)
            }

            Text(ordinal == 1 ? (paused ? "Paused" : "Next") : "\(ordinal)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            // Show the queue's own rejection reason on its first pending turn.
            if ordinal == 1, let reason = appModel.engine.turns.queuePauseReason(sessionId) {
                Text(reason)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(NativeAgentTheme.fail)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .help(reason)
                    .accessibilityLabel("Queue paused: \(reason)")
            }

            Text(turn.preview)
                .font(NativeAgentFont.tag)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !turn.attachments.isEmpty {
                Label("\(turn.attachments.count)", systemImage: "paperclip")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if overflow > 0 { queueMenu(items: items, overflow: overflow) }

            action(for: turn)

            Button {
                appModel.removeQueuedChatTurn(turn.id, sessionId: sessionId)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this queued message")
            .accessibilityLabel("Remove queued message \(ordinal)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func action(for turn: QueuedChatTurn) -> some View {
        if !isBusy {
            Button("Send next") {
                appModel.resumeQueuedChatTurns(sessionId: sessionId, startingWith: turn.id)
            }
            .buttonStyle(.borderless)
            .help("Run this queued message now")
        } else if appModel.engine.turns.isSteering(turn.id) {
            Text("Steering")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .help("The reply in progress takes it at its next step")
        } else if turn.canSteerRunningTurn {
            Menu {
                Button("Stop current response and send now") {
                    appModel.sendQueuedChatTurnNow(turn.id, sessionId: sessionId)
                }
            } label: {
                Text("Steer")
            } primaryAction: {
                appModel.steerQueuedChatTurn(turn.id, sessionId: sessionId)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Hand this to the reply in progress at its next step")
        } else {
            Button("Send now") {
                appModel.sendQueuedChatTurnNow(turn.id, sessionId: sessionId)
            }
            .buttonStyle(.borderless)
            .help("Stop the current response and run this message next")
        }
    }

    private func queueMenu(items: [ChatQueuePresentation.MenuItem], overflow: Int) -> some View {
        Menu {
            ForEach(items) { item in
                if isBusy, item.turn.canSteerRunningTurn,
                   !appModel.engine.turns.isSteering(item.turn.id) {
                    Button {
                        appModel.steerQueuedChatTurn(item.turn.id, sessionId: sessionId)
                    } label: {
                        Label(item.steerLabel, systemImage: "arrow.turn.down.right")
                    }
                }
                Button {
                    if isBusy {
                        appModel.sendQueuedChatTurnNow(item.turn.id, sessionId: sessionId)
                    } else {
                        appModel.resumeQueuedChatTurns(sessionId: sessionId, startingWith: item.turn.id)
                    }
                } label: {
                    Label(
                        item.actionLabel(isBusy: isBusy),
                        systemImage: item.ordinal == 1 ? "arrow.up.to.line" : "arrow.up"
                    )
                }
                Button(role: .destructive) {
                    appModel.removeQueuedChatTurn(item.turn.id, sessionId: sessionId)
                } label: {
                    Label(item.removeLabel, systemImage: "xmark")
                }
                if item.ordinal < items.count { Divider() }
            }
        } label: {
            Text("+\(overflow) more")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show all queued messages")
        .accessibilityLabel("Show all \(items.count) queued messages")
    }
}
