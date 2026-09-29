import SwiftUI
import ChatOrchestration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots

// Simple view's right-hand panes besides the chat: what the agent and one
// contact have said to each other, what one helper has done and said, and what
// a crew is doing. A contact's composer sends straight to the contact as the
// person's own message (ContactThreadSend), and the reply lands in the thread.
// The built-in Codex / Claude / OMP lanes answer through the agent's chat, so
// theirs still goes through the agent as "Tell <contact>: …". A helper's
// composer talks to the helper itself, the same way (`bot_ask` in its own
// session, brief unchanged); "Ask <agent>" sends it to the agent instead. A
// crew's thread is read-only.
//
// Every pane sits in the agent's own chat column (width, gutter, anchor, type),
// so moving between the chat and a thread never moves the words.

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

    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }
    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    /// Where the last send stands when no reply is owed or none came.
    private var receipt: String? {
        if store.flights[contact.id]?.stop?.state == "stopped" { return "Stopped." }
        return switch store.status[contact.id] {
        case .delivered?: "Delivered to \(contact.name)."
        case .read?: "Read by \(contact.name)."
        case .failed?: "No reply came back from \(contact.name)."
        case .notDelivered?: "Didn't reach \(contact.name)."
        default: nil
        }
    }

    /// Chats this contact opened with the agent over the bridge. The bridge
    /// titles them "[from: <label>, via bridge] …".
    private var openedChats: [ChatSession] {
        appModel.engine.transcripts.sessions.filter { session in
            guard session.title.hasPrefix("[from: "),
                  let end = session.title.range(of: ", via bridge]") else { return false }
            let label = session.title[session.title.index(session.title.startIndex, offsetBy: 7)..<end.lowerBound]
                .lowercased()
            return label == contact.name.lowercased() || (contact.builtIn && label == contact.id)
        }
    }

    var body: some View {
        let lines = store.lines[contact.id] ?? []
        let opened = openedChats
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
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
                if lines.isEmpty {
                    Text("Nothing has passed between \(agentName) and \(contact.name) yet.")
                        .font(ShellType.body)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                ForEach(lines) { line in
                    SimpleTranscriptEntry(speaker: line.byPerson ? "You" : line.fromAgent ? agentName : contact.name,
                                          text: line.text, at: line.at)
                }
                let flight = store.flights[contact.id]
                if store.waiting.contains(contact.id) {
                    VStack(alignment: .leading, spacing: 10) {
                        SimpleLiveReply(contact: contact, flight: flight, stopping: stopAsked, stop: stop)
                        // A stop or a queued send that didn't take, said while the reply still comes.
                        if let failure {
                            Text(failure)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                if let flight, let words = SimpleLiveReply.stopWords(flight, name: contact.name) {
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
        // From the top when it fits; opened at, and kept on, the newest.
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // Lines dissolve before the header, as in the chat.
        .roomTopChrome(masked: true) {
            SimpleThreadHeader(title: contact.name, subtitle: contact.via) {
                SimpleAvatar(contact: contact, size: 36)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SimpleComposer(placeholder: "Message \(contact.name)", recipient: contact.name, note: note) { text in
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
        guard !contact.builtIn else {
            let acceptance = await appModel.startActiveChatTurn("Tell \(contact.name): \(text)",
                                                                expectedSessionId: appModel.activeChatSessionId)
            if case .rejected(let message) = acceptance {
                note = message
                return false
            }
            note = "Sent through \(agentName)."
            return true
        }
        // While a reply is still coming, this queues behind it (the send says so).
        // The contact's conversation lives with the agent's current chat, as
        // her own sends to it do, so both continue one thread.
        let session = appModel.activeChatSessionId
        guard !session.isEmpty, appModel.engine.transcripts.sessions.contains(where: { $0.id == session }) else {
            note = "Chat is still starting. Nothing was sent."
            return false
        }
        let root = root
        note = nil
        failure = nil
        sending += 1
        let agent = contact.id
        Task { @MainActor in
            if let why = await ContactThreadSend.send(agent: agent, text: text, session: session, root: root) {
                failure = why
            }
            sending -= 1
        }
        return true
    }

    /// Stop the reply in flight, through the same gated chain as a send. What
    /// happened is written on the thread and shows from there.
    private func stop() {
        guard !stopAsked, let flight = store.flights[contact.id] else { return }
        let session = appModel.engine.transcripts.sessions.contains(where: { $0.id == flight.scope }) ? flight.scope : appModel.activeChatSessionId
        guard !session.isEmpty else { return }
        let root = root
        stopAsked = true
        failure = nil
        Task { @MainActor in
            if let why = await ContactThreadSend.stop(agent: flight.agent, conversation: flight.label,
                                                      session: session, root: root) {
                failure = why
            }
            stopAsked = false
        }
    }

    /// A held message, sent again by the person's tap; the held copy leaves
    /// the thread once the new send is accepted (sent or queued).
    private func sendAgain(_ item: SimpleFlight.Queued, from flight: SimpleFlight) {
        let session = appModel.activeChatSessionId
        guard !resending.contains(item.id) else { return }
        guard !session.isEmpty, appModel.engine.transcripts.sessions.contains(where: { $0.id == session }) else {
            note = "Chat is still starting. Nothing was sent."
            return
        }
        let root = root
        let agent = contact.id
        resending.insert(item.id)
        failure = nil
        Task { @MainActor in
            if let why = await ContactThreadSend.send(agent: agent, text: item.text, session: session, root: root) {
                failure = why
            } else {
                await ContactThreadSend.withdraw(item.id, record: flight.recordID, root: root)
            }
            resending.remove(item.id)
        }
    }
}

/// The person's own message to a contact, from its thread: the same
/// agent_message machinery the agent uses (peer resolution, transports,
/// receipts, AgentConversationStore), through the same gated chain, marked as
/// the person's by `PersonInitiatedSend`. This is the only place that mark is
/// made, and only a composer click or Return reaches it.
enum ContactThreadSend {
    /// Nil when the message went; otherwise why not, in plain words.
    static func send(agent: String, text: String, session: String, root: URL) async -> String? {
        let tools = NativeAgentEngine.live.toolDispatchClient(denyExternalMcp: false, enforceAppAutonomy: false)
        // No approval filer: nothing here can raise a card the thread can't show.
        let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: "auto", dataRoot: root, verifiedSessionId: session)
        do {
            let result = try await PersonInitiatedSend.$current.withValue(PersonInitiatedSend(agent: agent, text: text)) {
                try await ChatToolSessionContext.$verifiedSessionId.withValue(session) {
                    try await chain.dispatch(tool: "agent_message",
                        input: ["agent": .string(agent), "text": .string(text)], surface: "chat")
                }
            }
            guard case .object(let fields) = result else { return "Nothing came back from the send." }
            // Queued behind the reply in progress: accepted, it goes by itself.
            if fields["queued"] == .bool(true) { return nil }
            guard fields["sent"] == .bool(false) || fields["state"] == .string("attention") else { return nil }
            if case .string(let detail)? = fields["detail"], !detail.isEmpty { return detail }
            return "The message didn't go through."
        } catch {
            return error.localizedDescription
        }
    }

    /// The person's Stop on the reply in flight: `agent_cancel` through the
    /// same chain. Nil when the thread recorded the stop (stopping, stopped,
    /// released, cannot_stop or finished; shown from the record); otherwise why not.
    static func stop(agent: String, conversation: String, session: String, root: URL) async -> String? {
        let tools = NativeAgentEngine.live.toolDispatchClient(denyExternalMcp: false, enforceAppAutonomy: false)
        let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: "auto", dataRoot: root, verifiedSessionId: session)
        do {
            let result = try await ChatToolSessionContext.$verifiedSessionId.withValue(session) {
                try await chain.dispatch(tool: "agent_cancel",
                    input: ["agent": .string(agent), "conversation": .string(conversation)], surface: "chat")
            }
            guard case .object(let fields) = result else { return "Nothing came back from the stop." }
            if fields["stop_state"] != nil { return nil }
            if case .string(let detail)? = fields["detail"], !detail.isEmpty { return detail }
            return "The stop didn't go through."
        } catch {
            return error.localizedDescription
        }
    }

    /// Takes a held message off its thread once it has been sent again.
    static func withdraw(_ item: String, record: String, root: URL) async {
        await Task.detached(priority: .userInitiated) {
            let store = AgentConversationStore(dataRoot: root)
            guard let row = try? store.records().first(where: { $0.id == record }) else { return }
            _ = try? store.update(id: record, operationID: row.operationID, touch: false) {
                $0.queued?.removeAll { $0.id == item && $0.held != nil }
                if $0.queued?.isEmpty == true { $0.queued = nil }
            }
        }.value
    }
}

/// The other agent's reply while it is being written, in the thread's reply
/// type: its name beside its mark wearing the working rim, the words so far,
/// and a quiet line for what it is doing. A lane that cannot stream shows how
/// long it has been working instead of made-up text. Handed off with no live
/// channel, it is simply waiting. A small Stop sits beside the name.
private struct SimpleLiveReply: View {
    let contact: SimpleContact
    let flight: SimpleFlight?
    let stopping: Bool
    let stop: () -> Void

    /// A stop that could not stop, in plain words, for as long as it applies.
    static func stopWords(_ flight: SimpleFlight, name: String) -> String? {
        switch flight.stop?.state {
        case "cannot_stop"? where flight.inFlight: "\(name) can't be stopped — its reply will still arrive."
        case "released"?: "\(name) can't be stopped from here, so this thread stopped waiting. Its reply will still arrive."
        default: nil
        }
    }

    private var stopState: String? { flight?.stop?.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SimpleAvatar(contact: contact, size: 18)
                    .overlay { if flight?.working == true { WorkingRim(cornerRadius: 9) } }
                    .accessibilityHidden(true)
                Text(contact.name)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                if stopping || stopState == "stopping" {
                    Text("Stopping…")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                } else if stopState == nil {
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
            if let partial = flight?.partial {
                Text(SimpleTranscriptEntry.inline(partial))
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
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm %02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh %02dm", seconds / 3600, seconds / 60 % 60)
    }
}

/// A follow-up waiting its turn behind the reply in flight: the words on a
/// quiet sheet, not yet a line of the thread, and where it stands under them.
/// Held (it did not go) says why, with one tap to send it again.
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
                .background(NativeAgentShell.quietFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        // A reply said in the thread is also one of its runs; show it once.
        let said = Set(lines.filter { !$0.fromAgent }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        let runs = Array(record.sortedEntries.filter {
            !said.contains($0.actualReply.trimmingCharacters(in: .whitespacesAndNewlines))
        }.prefix(40))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if runs.isEmpty, lines.isEmpty {
                    Text("No runs yet.")
                        .font(ShellType.body)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                ForEach(runs) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(BotsShelfRecord.shortDate(entry.runAt))
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.tertiary)
                            .frame(width: 124, alignment: .leading)
                        Text(Self.line(entry))
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
        .roomTopChrome(masked: true) {
            SimpleThreadHeader(title: name, subtitle: record.definition.paused ? "Paused" : record.cadence) {
                SimpleClockTile(size: 36)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SimpleComposer(placeholder: "Message \(name)", recipient: name, note: note,
                           alternate: ("Ask \(agentName)", askAgent)) { text in
                await send(text)
            }
        }
    }

    /// The person's message to the helper itself: a turn in its own session,
    /// its standing brief unchanged (`agent_message` to `bot:<id>` → `bot_ask`).
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
        let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        note = nil
        failure = nil
        inFlight = true
        let agent = key
        Task { @MainActor in
            failure = await ContactThreadSend.send(agent: agent, text: text, session: session, root: root)
            inFlight = false
        }
        return true
    }

    /// The old path, kept to one side: the agent answers, in her chat.
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

    /// What one run came to, in a line: its first line of reply, or its state.
    static func line(_ entry: ShelfEntry) -> String {
        let said = SimpleViewStore.firstLine(entry.actualReply)
        switch entry.runtimeStatus {
        case .completed: return said.isEmpty ? BotsShelfRecord.health(entry.runHealth) : said
        case .waitingForApproval: return "Waiting for approval"
        case .waitingOnPerson: return entry.statusDetail.map { "Waiting on you — \($0)" } ?? "Waiting on you"
        case .failed: return "Failed: " + (entry.statusDetail ?? "cause not recorded")
        case .interrupted: return "Interrupted" + (entry.statusDetail.map { ": " + $0 } ?? (said.isEmpty ? "" : ": " + said))
        }
    }
}

extension View {
    /// The agent's chat column: the same width, gutter and anchor as its
    /// transcript, so a thread's words start where the chat's do.
    func simpleRoomColumn(gutter: CGFloat = NativeAgentShellLayout.roomGutter) -> some View {
        padding(.horizontal, gutter)
            .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .topLeading)
            .padding(.leading, NativeAgentShellLayout.roomLeadingInset)
            .padding(.trailing, NativeAgentShellLayout.roomTrailingInset)
            .frame(maxWidth: .infinity, alignment: NativeAgentShellLayout.roomAlignment)
    }
}

/// A pane's pinned header, like the chat's: a mark, the name at the room
/// header's size, one line under it. No sheet of its own (it read as a band
/// with a seam over the haze); the scroll edge dissolves words beneath it.
private struct SimpleThreadHeader<Mark: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        HStack(spacing: 12) {
            mark()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ShellType.title)
                    .foregroundStyle(NativeAgentShell.text)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .simpleRoomColumn()
        .padding(.top, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A helper's mark: a clock on a quiet tile (a crew's: three people). The
/// travelling rim while it works.
struct SimpleClockTile: View {
    var size: CGFloat = 30
    var symbol = "clock"
    var working = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(NativeAgentShell.softFill)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .frame(width: size, height: size)
            .overlay { if working { WorkingRim(cornerRadius: size * 0.27) } }
            .accessibilityHidden(true)
    }
}

/// A crew's run, read-only: each worker and what it has come back with so far,
/// then the findings pulled together.
struct SimpleCrewThread: View {
    let crew: SimpleCrew

    /// How a finished crew went, in words.
    static func outcome(_ crew: SimpleCrew) -> String {
        switch crew.status {
        case "completed": return "Done"
        case "partial": return "Done, some workers fell short"
        case "cancelled": return "Stopped"
        case "failed": return "Didn't finish"
        default: return crew.live ? "Working now" : "Finished"
        }
    }

    var body: some View {
        let count = crew.workers.count == 1 ? "1 worker" : "\(crew.workers.count) workers"
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(crew.live ? "I sent \(count) on this. What each finds comes in here as they finish."
                               : "I sent \(count) on this.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                ForEach(crew.workers) { worker in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(worker.name)
                            .font(ShellType.labelSemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        Text(SimpleTranscriptEntry.inline(Self.said(worker)))
                            .font(worker.status == "completed" ? ShellType.body : ShellType.label)
                            .foregroundStyle(worker.status == "completed" ? NativeAgentShell.text : NativeAgentShell.secondary)
                            .lineSpacing(NativeAgentShellLayout.replyLineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let synthesis = crew.synthesis {
                    SimpleTranscriptEntry(speaker: "Together", text: synthesis, at: crew.at)
                } else if crew.live, crew.settled {
                    Text("Pulling it together…")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
            }
            .simpleRoomColumn()
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .roomTopChrome(masked: true) {
            SimpleThreadHeader(title: crew.task, subtitle: "\(Self.outcome(crew)) · \(count)") {
                SimpleClockTile(size: 36, symbol: "person.3", working: crew.live)
            }
        }
    }

    private static func said(_ worker: SimpleCrew.Worker) -> String {
        switch worker.status {
        case "working": return "Working…"
        case "completed": return worker.text
        case "cancelled": return "Stopped" + (worker.text.isEmpty ? "." : ": " + worker.text)
        default: return "Didn't finish" + (worker.text.isEmpty ? "." : ": " + worker.text)
        }
    }
}

/// One read-only transcript entry: who, when, and the words in the chat's
/// reply type.
private struct SimpleTranscriptEntry: View {
    let speaker: String
    let text: String
    let at: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(speaker)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(BotsShelfRecord.shortDate(at))
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
            }
            Text(Self.inline(text))
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.text)
                .lineSpacing(NativeAgentShellLayout.replyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Bold, italics and code as the chat shows them; line breaks kept.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The chat's message box, for a thread: the same rounded glass (radius 22,
/// native glass, the haze's faint bottom glow), the same column and gutter,
/// the draft on top and a row under it with the send arrow on the right.
/// Return sends; the box clears only once the message is accepted.
private struct SimpleComposer: View {
    let placeholder: String
    var prefill = ""
    /// Who a send goes straight to. Shown the whole time, because the
    /// placeholder that named them is gone at the first keystroke.
    var recipient: String?
    var note: String?
    /// A second way to send the draft, beside the arrow: a title and its send.
    var alternate: (title: String, send: (String) async -> Bool)?
    let send: (String) async -> Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var sending = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sendable: Bool { !sending && !trimmed.isEmpty && trimmed != prefill.trimmingCharacters(in: .whitespaces) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NativeAgentShellLayout.composerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let recipient {
                    Text("To: \(recipient)")
                        .font(ShellType.captionMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(NativeAgentShell.softFill, in: Capsule())
                        .fixedSize()
                }
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ShellType.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { submit() }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(note ?? "")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let alternate {
                    Button(alternate.title) { submit(alternate.send) }
                        .buttonStyle(.plain)
                        .font(ShellType.captionMedium)
                        .foregroundStyle(sendable ? NativeAgentShell.secondary : NativeAgentShell.tertiary)
                        .disabled(!sendable)
                }
                Button(action: { submit() }) {
                    Image(systemName: "arrow.right")
                        .font(ShellType.body)
                        .frame(width: 36, height: 36)
                        .background(
                            sendable ? Color.primary.opacity(0.12) : NativeAgentShell.quietFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .foregroundStyle(sendable ? NativeAgentShell.text : NativeAgentShell.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!sendable)
                .help("Send")
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .background {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .overlay { shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1) }
            }
            HazeBottomGlow(cornerRadius: NativeAgentShellLayout.composerRadius)
        }
        .glassEffect(reduceTransparency ? .identity : ShellSidebarRail.plateGlass, in: shape)
        .overlay {
            if focused, !reduceTransparency {
                shape.fill(Color.primary.opacity(0.04)).allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : NativeAgentMotion.quick, value: focused)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .simpleRoomColumn(gutter: 0)
        .padding(.bottom, 24)
        .onAppear { if text.isEmpty { text = prefill } }
        // A draft belongs to one thread: never carried to another contact.
        .onChange(of: recipient) { text = prefill }
    }

    private func submit(_ route: ((String) async -> Bool)? = nil) {
        guard sendable else { return }
        let message = trimmed
        let deliver = route ?? send
        sending = true
        Task { @MainActor in
            defer { sending = false }
            if await deliver(message) { text = prefill }
        }
    }
}
