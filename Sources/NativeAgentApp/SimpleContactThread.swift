import SwiftUI
import Foundation
import EngineRuntime
import AgentWorkspace
import NativeAgentShared
import SwarmRuns
import Agents
import ChatSessionWork
import NativeAgentCore
import ChatTurnContracts
import PersistenceCore
import StandingBots
import ProviderRouting
import AppKit
import AppToolRuntime
// Blueprint: | `SimpleContactThread.swift` | Contact replies, Stop and queued resend through canonical session acceptance |

struct SimpleContactThread: View {
    let contact: SimpleContact
    let store: SimpleViewStore
    let openChat: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var note: String?
    /// Allow another send during a reply; session acceptance queues it behind the current turn.
    @State private var sending = 0
    @State private var failure: String?
    @State private var stopAsked = false
    @State private var resending: Set<String> = []
    @State private var transcriptHandle = TranscriptDocumentHandle()

    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }
    private var root: URL { appModel.engine.dataRoot }

    /// Retain delivery state when no reply arrives so silence cannot imply success.
    private var receipt: String? {
        if store.flight(for: contact.id)?.stop?.state == "stopped" { return "Stopped." }
        return switch store.status[contact.id] {
        case .delivered?: "Delivered to \(contact.name)."
        case .read?: "Read by \(contact.name)."
        case .failed?: "No reply came back from \(contact.name)."
        case .notDelivered?: "Didn't reach \(contact.name)."
        case .unanswered?: "No reply from \(contact.name)."
        default: nil
        }
    }

    /// Peer session IDs survive retitling; omit the thread's own conversation from its extra chats.
    private var openedChats: [ChatSession] {
        let owner = String(contact.id.dropFirst(5))
        return appModel.engine.transcripts.sessions.filter { session in
            if session.id == ContactThread.session(owner: owner) { return false }
            return session.id.hasPrefix(ContactThread.prefix(owner: owner))
        }
    }

    /// The thread's lines and, while the contact writes, its partial reply as the last line.
    private var documentLines: [SimpleThreadDocument.Line] {
        var rows = (store.lines[contact.id] ?? []).map { line in
            SimpleThreadDocument.Line(id: line.id, speaker: (line.byPerson ? "You" : line.fromAgent ? agentName : contact.name)
                                          + (line.door.map { " · " + $0 } ?? ""),
                                      text: line.text, at: line.at)
        }
        if store.waiting.contains(contact.id), let partial = store.partial(for: contact.id) {
            rows.append(SimpleThreadDocument.Line(id: "live:" + contact.id, speaker: contact.name, text: partial, at: nil))
        }
        return rows
    }

    var body: some View {
        TranscriptDocumentView(sessionID: "contact:" + contact.id, groups: SimpleThreadDocument.groups(documentLines),
                               handle: transcriptHandle)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    SimpleThreadHeader(title: contact.name, subtitle: contact.via) {
                        SimpleAvatar(contact: contact, size: 36)
                    }
                    threadNotes
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    flightStatus
                        .padding(.bottom, 8)
                    composer
                }
            }
    }

    /// What sits above the thread: a read failure, the chats the contact opened, or why there is nothing yet.
    private var threadNotes: some View {
        let opened = openedChats
        return VStack(alignment: .leading, spacing: 12) {
            if let error = store.refreshError {
                Text(error)
                    .font(ShellType.body)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if !opened.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chats \(contact.name) started with \(agentName)")
                        .font(ShellType.captionSemibold)
                        .foregroundStyle(NativeAgentShell.tertiary)
                    ForEach(opened) { session in
                        Button {
                            Task {
                                await appModel.selectChatSession(session)
                                openChat()
                            }
                        } label: {
                            Text(topic(session))
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens this chat with \(agentName)")
                    }
                }
            }
            if (store.lines[contact.id] ?? []).isEmpty && opened.isEmpty && store.refreshError == nil {
                Text(contact.lastActivityAt == nil
                     ? "Nothing has passed between \(agentName) and \(contact.name) yet."
                     : "Earlier activity is recorded, but no messages are retained here.")
                    .font(ShellType.body)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .simpleRoomColumn()
    }

    /// The send in flight under the thread: who is writing and Stop, the delivery receipt or failure, and anything queued.
    private var flightStatus: some View {
        let flight = store.flight(for: contact.id)
        return VStack(alignment: .leading, spacing: 10) {
            if store.waiting.contains(contact.id) {
                SimpleLiveReply(contact: contact, store: store, stopping: stopAsked, stop: stop)
                if let failure {
                    Text(failure)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if sending > 0 {
                Text("Sending…")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.tertiary)
            } else if let failure {
                Text(failure)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let said = receipt {
                Text(said)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.tertiary)
            }
            if let flight, let words = SimpleLiveReply.stopWords(flight) {
                Text(words)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(flight?.queued ?? []) { item in
                SimplePendingMessage(item: item, speaker: item.byPerson ? "You" : agentName, name: contact.name,
                                     resending: resending.contains(item.id)) {
                    if let flight { sendAgain(item, from: flight) }
                }
            }
        }
        .simpleRoomColumn()
    }

    @ViewBuilder
    private var composer: some View {
        if let restriction = contact.sendRestriction {
            Text(restriction == "Replies only"
                 ? "Replies only · \(agentName) can't start a conversation with \(contact.name)."
                 : restriction)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .simpleRoomColumn()
                .padding(.vertical, 12)
        } else {
            SimpleComposer(thread: contact.id, placeholder: "Message \(contact.name)", recipient: contact.name, note: note) { text in
                await send(text)
            }
        }
    }

    private func topic(_ session: ChatSession) -> String {
        guard let end = session.title.range(of: ", via bridge]") else { return session.title }
        let rest = session.title[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? (session.lastMessagePreview.map(SimpleViewStore.firstLine) ?? "Untitled chat") : rest
    }

    private func send(_ text: String) async -> Bool {
        guard contact.sendRestriction == nil else { return false }
        // Queue behind the current reply to preserve session ordering.
        let session = appModel.activeChatSessionId
        guard !session.isEmpty, appModel.engine.transcripts.sessions.contains(where: { $0.id == session }) else {
            note = "Chat is still starting. Nothing was sent."
            return false
        }
        let root = root
        note = nil
        failure = nil
        sending += 1
        transcriptHandle.goToLatest()
        let agent = contact.id
        defer { sending -= 1 }
        let turn = Turn(session: session).with(\.envelope,
            .personOnMac("mac_ui:contact.send"))
        if let why = await NativeAgentEngine.live.sendContactMessage(agent: agent, text: text, session: session, root: root, turn: turn) {
            failure = why
            return false
        }
        return true
    }

    /// Use the send gates for Stop and retain its outcome in the thread.
    private func stop() {
        guard !stopAsked, let flight = store.flight(for: contact.id) else { return }
        let session = flight.scope
        guard !session.isEmpty else { return }
        let root = root
        stopAsked = true
        failure = nil
        Task { @MainActor in
            if let why = await NativeAgentEngine.live.stopContactMessage(agent: flight.agent, record: flight.recordID,
                                                      session: session, root: root) {
                failure = why
            }
            stopAsked = false
        }
    }

    /// Remove the held copy only after the replacement send is accepted.
    private func sendAgain(_ item: SimpleFlight.Queued, from flight: SimpleFlight) {
        let session = flight.scope
        guard !resending.contains(item.id) else { return }
        guard !session.isEmpty, appModel.engine.transcripts.sessions.contains(where: { $0.id == session }) else {
            note = "The original chat is unavailable. Nothing was sent."
            return
        }
        let root = root
        let agent = flight.agent
        resending.insert(item.id)
        failure = nil
        let turn = Turn(session: session).with(\.envelope,
            .personOnMac("mac_ui:contact.send"))
        Task { @MainActor in
            if let why = await NativeAgentEngine.live.sendContactMessage(agent: agent, text: item.text, session: session, root: root,
                                                      conversation: flight.agent.hasPrefix("bot:") ? nil : flight.recordID, turn: turn) {
                failure = why
            } else {
                do {
                    try await NativeAgentEngine.live.withdrawContactMessage(item.id, record: flight.recordID, root: root)
                } catch {
                    failure = "The replacement was accepted, but the old held copy could not be withdrawn: \(error.localizedDescription) Do not send it again."
                }
            }
            resending.remove(item.id)
        }
    }
}

private struct SimpleLiveReply: View {
    let contact: SimpleContact
    let store: SimpleViewStore
    let stopping: Bool
    let stop: () -> Void
    private var flight: SimpleFlight? { store.flight(for: contact.id) }

    /// Keep a failed Stop visible while it still applies.
    static func stopWords(_ flight: SimpleFlight) -> String? {
        switch flight.stop?.state {
        case "cannot_stop"? where flight.inFlight: flight.stop?.detail
        case "released"?: flight.stop?.detail
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SimpleAvatar(contact: contact, size: 18)
                    .overlay { if flight?.working == true { WorkingRim(cornerRadius: 9) } }
                    .accessibilityHidden(true)
                Text(contact.name)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                if stopping {
                    Text("Stopping…")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                } else if flight != nil, flight?.stop == nil {
                    Button(action: stop) {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                            .font(ShellType.captionMedium)
                            .imageScale(.small)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(NativeAgentShell.softFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Stop \(contact.name)'s reply")
                    .accessibilityLabel("Stop \(contact.name)'s reply")
                    .accessibilityHint("Asks \(contact.name) to stop. Anything queued goes next.")
                }
            }
            if store.partial(for: contact.id) != nil {
                // The partial reply reads as the thread's last line, so this strip says only that it is coming.
                Text("Writing…")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.tertiary)
            } else if let flight, flight.working, let since = flight.live?.startedAt {
                // Tick only while working with no text so idle or populated rows need no timer.
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Working · " + Self.elapsed(from: since, to: context.date))
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .monospacedDigit()
                }
                .accessibilityLabel("\(contact.name) is working")
            } else {
                Text("Waiting for \(contact.name)…")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.tertiary)
            }
            if flight?.working == true, let note = flight?.live?.note {
                Text(note)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let interval = now.timeIntervalSince(start)
        guard interval >= 0, let seconds = Int(exactly: interval.rounded(.towardZero)) else {
            return "Elapsed time unavailable"
        }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm %02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh %02dm", seconds / 3600, seconds / 60 % 60)
    }
}

/// Held messages need a reason and an explicit resend; pending sends retain their queue state.
private struct SimplePendingMessage: View {
    let item: SimpleFlight.Queued
    let speaker: String
    let name: String
    let resending: Bool
    let sendAgain: () -> Void

    private var status: String {
        switch item.state {
        case .queued: "Queued · sends when \(name) answers"
        case .sending: "Sending…"
        case .held(let why): why
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(speaker)
                .font(ShellType.labelSemibold)
                .foregroundStyle(NativeAgentShell.secondary)
            Text(SimpleTranscriptEntry.inline(item.text))
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineSpacing(NativeAgentShellLayout.replyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .houseSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NativeAgentShell.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(status)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .held = item.state {
                    Button(resending ? "Sending…" : "Send again", action: sendAgain)
                        .buttonStyle(.plain)
                        .font(ShellType.captionMedium)
                        .foregroundStyle(resending ? NativeAgentShell.tertiary : NativeAgentShell.text)
                        .disabled(resending)
                        .accessibilityLabel("Send again")
                        .accessibilityHint("Sends this message to \(name) now, as yours")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
