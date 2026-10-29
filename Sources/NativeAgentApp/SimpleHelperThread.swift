import SwiftUI
import EngineRuntime
import NativeAgentShared
import StandingBots
import Foundation
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import AppKit
import AppToolRuntime
// Blueprint: | `SimpleHelperThread.swift` | SimpleHelperRuns shows helper history and messages; accepted drafts send to the helper or the resident's chat |

struct SimpleHelperRuns: View {
    let record: BotsShelfRecord
    let store: SimpleViewStore
    let openChat: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var note: String?
    @State private var inFlight = false
    @State private var failure: String?

    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }
    private var name: String { record.definition.name }
    private var key: String { SimpleViewStore.key(record.id) }

    var body: some View {
        let lines = store.lines[key] ?? []
        let runs = store.helperRuns[record.id]?.history ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if runs.isEmpty, lines.isEmpty {
                    Text("No runs yet.")
                        .font(ShellType.body)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                ForEach(runs) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(BotsShelfRecord.shortDate(entry.entry.runAt))
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.tertiary)
                            .frame(width: 124, alignment: .leading)
                        Text(SimpleViewStore.firstLine(entry.line))
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.text)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(lines) { line in
                    SimpleTranscriptEntry(speaker: line.byPerson ? "You" : line.fromAgent ? agentName : name,
                                          text: line.text, at: line.at)
                        .equatable()
                        .padding(.top, 12)
                }
                if store.waiting.contains(key) || inFlight {
                    Text("\(name) is working on it…")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
                } else if let failure {
                    Text(failure)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .simpleRoomColumn()
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .roomTopChrome {
            SimpleThreadHeader(title: name, subtitle: record.definition.paused ? "Paused" : record.cadence) {
                SimpleClockTile(size: 36)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SimpleComposer(thread: key, placeholder: "Message \(name)", recipient: name, note: note,
                           alternate: ("Ask \(agentName)", askAgent)) { text in
                await send(text)
            }
        }
    }

    /// Message the helper in its own session without changing its standing brief.
    private func send(_ text: String) async -> Bool {
        guard !inFlight, !store.waiting.contains(key) else {
            note = "\(name) is still answering. Send again once the reply is in."
            return false
        }
        // The helper's conversation lives with the agent's current chat, as
        // a contact's does, so her own asks and yours continue one thread.
        let session = appModel.activeChatSessionId
        guard !session.isEmpty, appModel.engine.transcripts.sessions.contains(where: { $0.id == session }) else {
            note = "Chat is still starting. Nothing was sent."
            return false
        }
        let root = appModel.engine.dataRoot
        note = nil
        failure = nil
        inFlight = true
        let agent = key
        defer { inFlight = false }
        failure = await NativeAgentEngine.live.sendContactMessage(agent: agent, text: text, session: session, root: root)
        return failure == nil
    }

    /// Ask the resident agent in her chat.
    private func askAgent(_ text: String) async -> Bool {
        let acceptance = await appModel.startActiveChatTurn("About \(name): \(text)",
                                                            expectedSessionId: appModel.activeChatSessionId)
        if case .rejected(let message) = acceptance {
            note = message
            return false
        }
        openChat()
        return true
    }

}
