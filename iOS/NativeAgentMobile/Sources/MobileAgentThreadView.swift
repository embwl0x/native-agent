import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `MobileAgentThreadView.swift` | Shared contact conversation rows and retained message form over the signed Mac owner |

enum MobileAgentPresentation {
    static func line(_ agent: MobileAgentRow) -> String {
        let state = agent.stateLine ?? "State not reported"
        guard let at = agent.lastActivityAt, at.isFinite, at > 0 else { return state }
        return state + " · " + Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .shortened)
    }
}

struct MobileAgentThreadView: View {
    let id: String
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairing: PairingStore
    @Environment(ChatStore.self) private var chatStore
    @State private var busy = false
    @State private var error: String?
    private var thread: MobileAgentThread? { sync.agentThreads[id] }
    private var agent: MobileAgentRow? { sync.helpersSnapshot?.agents.first { $0.id == id } ?? thread?.agent }

    private var sendRestriction: String? {
        agent?.sendRestriction
    }
    private var session: FacePageSession { sync.pageSessions.page("contact/" + id) }

    var body: some View {
        AlivePage(title: agent?.name ?? "Agent", line: agent.map(MobileAgentPresentation.line) ?? "Conversation with another agent.") {
            if !pairing.isPaired { AliveUnpairedReason() }
            if let error { AliveSection("Couldn’t complete the request") { Text(error).aliveRow() } }
            FaceView(face: face, door: door, session: session)
            if busy { ProgressView("Waiting for Mac…").aliveRow() }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: agent) { _, _ in
            Task { await refresh() }
        }
    }

    private var face: PartFace {
        var sections: [PartFace.Section] = []
        if let thread {
            sections = thread.lines.map { line in
                .init(id: "exchange-" + line.id, title: line.speaker,
                    footer: Date(timeIntervalSince1970: line.at).formatted(date: .abbreviated, time: .shortened), rows: [],
                    block: .init(kind: "document", key: line.id, text: line.text, format: "plain", copy: true))
            }
            if sections.isEmpty { sections = [.init(id: "conversation", rows: [.init(id: "empty", title: "No exchanges yet.")])] }
            if thread.truncated {
                sections.append(.init(id: "excerpt-note", rows: [
                    .init(id: "excerpt", title: "Recent excerpts; the full conversation remains on the Mac.", tone: .quiet)
                ]))
            }
        } else {
            sections = [.init(id: "conversation", rows: [
                .init(id: "waiting", title: busy ? "Reading conversation from the Mac…" : "This conversation has not reached this iPhone.")
            ])]
        }
        if let agent {
            sections.append(.init(id: "details", title: "Connection details", rows: [
                .init(id: "via", title: agent.via, detail: agent.status),
                .init(id: "exchange", title: "Last exchange", detail: agent.lastExchange)
            ], folded: true))
        }
        sections.append(.init(id: "message", title: "Message", rows: [], block: .init(kind: "form", key: "contact-message",
            fields: [.init(id: "text", label: "Message", kind: "lines", value: .string(""), required: true)],
            submit: [.init(id: "send", label: "Send", call: .init("contact.send", ["contact": .string(id)]),
                           unavailable: sendRestriction ?? (!pairing.isPaired ? "Pair with your Mac before sending." :
                            agent == nil ? "The contact has not arrived from the Mac." : nil))])))
        return PartFace(sections: sections)
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, cancellationLabel: "Cancel waiting", waitingOn: "your Mac") { submission in
            if submission.checking {
                await refresh()
                return .init(words: "The conversation has been refreshed; acceptance of the original message remains unconfirmed.", effects: .unknown)
            }
            guard submission.expectedCall.action == "contact.send", let text = submission.values?["text"]?.stringValue else {
                return .interrupted(WireFailure(code: "contact_message_missing", message: "The message form needs its text.",
                    cause: nil, effects: .none))
            }
            guard pairing.isPaired, let agent, agent.sendRestriction == nil else {
                return FaceActOutcome(failure: .init(code: "contact_unavailable", message: sendRestriction
                    ?? "Read the paired Mac's contact before sending.", cause: nil, effects: .none), effects: .none)
            }
            do {
                _ = try await sync.agentThreadAction(id: id, text: text,
                    sessionID: chatStore.selectedSessionID ?? chatStore.mainSessionID)
                return FaceActOutcome(words: "Message accepted by the Mac.", effects: .known, accepted: true,
                    committed: [.init(id: "text", value: .string(""))])
            } catch { return .phoneFailure(error) }
        }
    }

    private func refresh() async {
        guard !busy else { return }
        guard pairing.isPaired else {
            error = "Pair with your Mac to read or send agent messages."
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await sync.agentThreadAction(id: id, text: nil,
                                                     sessionID: chatStore.selectedSessionID ?? chatStore.mainSessionID)
        } catch { self.error = error.localizedDescription }
    }
}
