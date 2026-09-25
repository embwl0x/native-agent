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
    @State private var inFlight = false
    @State private var failure: String?

    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }

    /// Chats this contact opened with the agent over the bridge. The bridge
    /// titles them "[from: <label>, via bridge] …".
    private var openedChats: [ChatSession] {
        appModel.chatSessions.filter { session in
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
                if store.waiting.contains(contact.id) {
                    Text("Waiting for \(contact.name)…")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
                } else if inFlight {
                    Text("Sending…")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
                } else if let failure {
                    Text(failure)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.unanswered.contains(contact.id) {
                    Text("No reply came back from \(contact.name).")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
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
        guard !inFlight, !store.waiting.contains(contact.id) else {
            note = "\(contact.name) is still answering. Send again once the reply is in."
            return false
        }
        // The contact's conversation lives with the agent's current chat, as
        // her own sends to it do, so both continue one thread.
        let session = appModel.activeChatSessionId
        guard !session.isEmpty, appModel.chatSessions.contains(where: { $0.id == session }) else {
            note = "Chat is still starting. Nothing was sent."
            return false
        }
        let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        note = nil
        failure = nil
        inFlight = true
        let agent = contact.id
        Task { @MainActor in
            failure = await ContactThreadSend.send(agent: agent, text: text, session: session, root: root)
            inFlight = false
        }
        return true
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
        let tools = makeNativeAgentAppToolDispatchClient(denyExternalMcp: false, enforceAppAutonomy: false, dataRoot: root)
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
            guard fields["sent"] == .bool(false) || fields["state"] == .string("attention") else { return nil }
            if case .string(let detail)? = fields["detail"], !detail.isEmpty { return detail }
            return "The message didn't go through."
        } catch {
            return error.localizedDescription
        }
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
        guard !session.isEmpty, appModel.chatSessions.contains(where: { $0.id == session }) else {
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
        .glassEffect(reduceTransparency ? .identity : .regular.interactive(), in: shape)
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
