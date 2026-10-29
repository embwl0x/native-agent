import SwiftUI
import Foundation
import EngineRuntime
import AgentWorkspace
import NativeAgentShared
import SwarmRuns
import Agents
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting
import AppKit
import AppToolRuntime
// Blueprint: | `SimpleContactThread.swift` | Contact conversation, live reply, stop and queued resend retain canonical session acceptance and delivery evidence |

struct SimpleContactThread: View {
    let contact: SimpleContact
    let store: SimpleViewStore
    let openChat: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var note: String?
    /// The person's sends still being handed over (a second can go while
    /// the first's reply is coming; it queues behind it).
    @State private var sending = 0
    @State private var failure: String?
    /// Stop tapped; cleared once the stop call returns.
    @State private var stopAsked = false
    /// Held messages being sent again.
    @State private var resending: Set<String> = []
    @State private var reading = ChatScrollFollow()

    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }
    private var root: URL { appModel.engine.dataRoot }

    /// Where the last send stands when no reply is owed or none came.
    private var receipt: String? {
        if store.flight(for: contact.id)?.stop?.state == "stopped" { return "Stopped." }
        return switch store.status[contact.id] {
        case .delivered?: "Delivered to \(contact.name)."
        case .read?: "Read by \(contact.name)."
        case .failed?: "No reply came back from \(contact.name)."
        case .notDelivered?: "Didn't reach \(contact.name)."
        default: nil
        }
    }

    /// Chats this contact opened with the agent over the bridge. Peer-owned
    /// session IDs survive retitling; legacy bridge chats carry their label.
    /// The contact's own conversation is this thread, so it is not listed.
    private var openedChats: [ChatSession] {
        let owner = String(contact.id.dropFirst(5))
        return appModel.engine.transcripts.sessions.filter { session in
            if session.id == ContactThread.session(owner: owner) { return false }
            if session.id.hasPrefix(ContactThread.prefix(owner: owner)) { return true }
            guard session.title.hasPrefix("[from: "),
                  let end = session.title.range(of: ", via bridge]") else { return false }
            let label = session.title[session.title.index(session.title.startIndex, offsetBy: 7)..<end.lowerBound]
                .lowercased()
            return label == contact.name.lowercased()
        }
    }

    var body: some View {
        let lines = store.lines[contact.id] ?? []
        let opened = openedChats
        TranscriptScrollView(coordinator: reading) {
            LazyVStack(alignment: .leading, spacing: 26) {
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
                if lines.isEmpty && opened.isEmpty && store.refreshError == nil {
                    Text(contact.lastActivityAt == nil
                         ? "Nothing has passed between \(agentName) and \(contact.name) yet."
                         : "Earlier activity is recorded, but no messages are retained here.")
                        .font(ShellType.body)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                ForEach(lines) { line in
                    SimpleTranscriptEntry(speaker: (line.byPerson ? "You" : line.fromAgent ? agentName : contact.name)
                                          + (line.door.map { " · " + $0 } ?? ""),
                                          text: line.text, at: line.at)
                        .equatable()
                        .readingBlock("\(line.id)")
                }
                let flight = store.flight(for: contact.id)
                if store.waiting.contains(contact.id) {
                    VStack(alignment: .leading, spacing: 10) {
                        SimpleLiveReply(contact: contact, store: store, stopping: stopAsked, stop: stop)
                        // A stop or a queued send that didn't take, said while the reply still comes.
                        if let failure {
                            Text(failure)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .readingBlock("live")
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
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        // From the top when it fits; opened at the newest, and kept there
        // while the reader is (TranscriptScrollView).
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Lines dissolve before the header, as in the chat.
        .roomTopChrome {
            SimpleThreadHeader(title: contact.name, subtitle: contact.via) {
                SimpleAvatar(contact: contact, size: 36)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
    }

    private func topic(_ session: ChatSession) -> String {
        guard let end = session.title.range(of: ", via bridge]") else { return session.title }
        let rest = session.title[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? (session.lastMessagePreview.map(SimpleViewStore.firstLine) ?? "Untitled chat") : rest
    }

    private func send(_ text: String) async -> Bool {
        guard contact.sendRestriction == nil else { return false }
        // Sends queue behind a live reply in the agent's current conversation.
        let session = appModel.activeChatSessionId
        guard !session.isEmpty, appModel.engine.transcripts.sessions.contains(where: { $0.id == session }) else {
            note = "Chat is still starting. Nothing was sent."
            return false
        }
        let root = root
        note = nil
        failure = nil
        sending += 1
        reading.followFromLiveEdge()
        let agent = contact.id
        defer { sending -= 1 }
        if let why = await NativeAgentEngine.live.sendContactMessage(agent: agent, text: text, session: session, root: root) {
            failure = why
            return false
        }
        return true
    }

    /// Stop the reply in flight, through the same gated chain as a send. What
    /// happened is written on the thread and shows from there.
    private func stop() {
        guard !stopAsked, let flight = store.flight(for: contact.id) else { return }
        let session = appModel.engine.transcripts.sessions.contains(where: { $0.id == flight.scope }) ? flight.scope : appModel.activeChatSessionId
        guard !session.isEmpty else { return }
        let root = root
        stopAsked = true
        failure = nil
        Task { @MainActor in
            if let why = await NativeAgentEngine.live.stopContactMessage(agent: flight.agent, conversation: flight.label,
                                                      session: session, root: root) {
                failure = why
            }
            stopAsked = false
        }
    }

    /// A held message, sent again by the person's tap; the held copy leaves
    /// the thread once the new send is accepted (sent or queued).
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
        Task { @MainActor in
            if let why = await NativeAgentEngine.live.sendContactMessage(agent: agent, text: item.text, session: session, root: root,
                                                      conversation: flight.agent.hasPrefix("bot:") ? nil : flight.recordID) {
                failure = why
            } else {
                await NativeAgentEngine.live.withdrawContactMessage(item.id, record: flight.recordID, root: root)
            }
            resending.remove(item.id)
        }
    }
}

/// Show streamed words, elapsed work or handoff waiting, with the contact's Stop action.
private struct SimpleLiveReply: View {
    let contact: SimpleContact
    let store: SimpleViewStore
    let stopping: Bool
    let stop: () -> Void
    private var flight: SimpleFlight? { store.flight(for: contact.id) }

    /// A stop that could not stop, in plain words, for as long as it applies.
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
            if let partial = store.partial(for: contact.id) {
                SimpleLiveText(text: partial)
                    .font(ShellType.body)
                    .foregroundStyle(NativeAgentShell.text.opacity(0.82))
                    .lineSpacing(NativeAgentShellLayout.replyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
                    .accessibilityLabel("\(contact.name) is writing: \(partial)")
            } else if let flight, flight.working, let since = flight.live?.startedAt {
                // Once a second, only while it works and has nothing to show.
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

    /// "12s", "3m 04s", "1h 02m".
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

/// Pending sends show their queue state; held messages explain why and offer Send again.
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
