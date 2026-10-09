import AppKit
import ChatOrchestration
import NativeAgentCore
import NativeAgentShared
import SwiftUI

/// What Shotgun shows (Shotgun.swift owns the window): her live step as one
/// line on top, the last ten messages of the chat on screen with her reply
/// streaming in, a composer that sends into that same chat (and queues while
/// she works), Stop while a turn runs, Resume while the person holds the Mac,
/// Watch for the masked screen glimpse, Expand/Open for the full window. A
/// finished turn reads "Done · Open" and later folds into a small name pill.
/// One glass surface; nothing inside it is glass.
struct ShotgunView: View {
    static let radius: CGFloat = 22

    /// Reports the folded pill's measured size so the window can hug it.
    let onSize: (CGSize) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("nativeagent.darkMode") private var preferDark = true
    @State private var watching = false
    @State private var draft = ""
    @State private var notice: String?
    @State private var sending = false
    @State private var inlineCards = InlineInteractionChatBinding()
    @State private var mirrorCards: [String: InlineInteractionChatBinding] = [:]
    @FocusState private var composerFocused: Bool

    var body: some View {
        let controller = ShotgunController.shared
        let sessionId = appModel.activeChatSessionId
        let turns = appModel.engine.turns
        let turn = turns.lifecycle(for: sessionId)?.presentation
        let preview = turns.screenPreview(for: sessionId)
        let running = turns.isBusy(sessionId) || turn.map { !$0.isTerminal } == true
        let all = appModel.engine.transcripts.messages(for: sessionId)
        let mirrorRows = all.filter { $0.metadata?.interactionMirror != nil }
        let mirrorSessions = Set(mirrorRows.compactMap { $0.metadata?.interactionMirror?.sessionID }).sorted()
        let waiting = all.contains(where: hasPendingApproval)
            || inlineCards.cardsByRow.values.contains { $0.contains { $0.needsAttention } }
            || mirrorRows.contains { message in
                guard let mirror = message.metadata?.interactionMirror else { return false }
                guard let binding = mirrorCards[mirror.sessionID] else { return true }
                return binding.cardsByRow.values.flatMap { $0 }
                    .first { $0.id == mirror.interactionID }?.needsAttention == true
            }
        let done = !running && !waiting && turn?.isTerminal == true
        Group {
            if controller.collapsed && !running && !waiting {
                pill
            } else {
                full(sessionId: sessionId, turn: turn, preview: preview, running: running)
            }
        }
        .preferredColorScheme(preferDark ? .dark : nil)
        .onChange(of: done && controller.isShown, initial: true) { _, now in controller.setDone(now) }
        .onChange(of: draft) { _, _ in notice = nil }
        .inlineCardSetup(inlineCards)
        .task(id: sessionId) { await inlineCards.refresh(sessionID: sessionId) }
        // Keep origin bindings alive even while the decision rows are folded away.
        .task(id: [sessionId] + mirrorRows.map(\.id)) {
            mirrorCards = Dictionary(uniqueKeysWithValues: mirrorSessions.map { origin in
                (origin, mirrorCards[origin] ?? InlineInteractionChatBinding())
            })
            for origin in mirrorSessions {
                guard !Task.isCancelled, let binding = mirrorCards[origin] else { return }
                await binding.refresh(sessionID: origin)
            }
        }
        .onChange(of: appModel.engine.transcripts.structureVersion) { _, _ in
            inlineCards.refreshSoon(sessionID: sessionId)
        }
        .onReceive(NotificationCenter.default.publisher(for: InlineInteractionWire.changedNotification)) { note in
            guard let origin = note.object as? String else { return }
            if origin == sessionId { Task { await inlineCards.refresh(sessionID: sessionId) } }
            if let binding = mirrorCards[origin] { Task { await binding.refresh(sessionID: origin) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
            guard note.object as? String == sessionId else { return }
            Task { await inlineCards.refresh(sessionID: sessionId) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard note.object is ShotgunPanel else { return }
            Task { await inlineCards.verifyOnReturn() }
            for binding in mirrorCards.values { Task { await binding.verifyOnReturn() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shotgun")
        .accessibilityIdentifier("shotgun")
    }

    private func full(
        sessionId: String, turn: TurnPresentationState?, preview: MacChatScreenPreview?, running: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(turn: turn, preview: preview, running: running)
            if watching, let preview, preview.isShowable, let image = preview.image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5)
                    )
                    .accessibilityLabel("What I am looking at: \(preview.caption)")
            }
            messages(sessionId: sessionId, running: running)
                .frame(maxHeight: .infinity, alignment: .bottom)
            ChatQueuedTurnsView(sessionId: sessionId, isBusy: appModel.engine.turns.isBusy(sessionId))
            composer(sessionId: sessionId, running: running)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Drag it from anywhere that is not a control or the transcript.
            Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
        }
        .background {
            // Reduce Transparency asks for more opacity, never less.
            if reduceTransparency { ConcentricRectangle().fill(NativeAgentShell.room) }
            // The same working shimmer the composer carries, lit for the turn.
            ThinkingGlow(kind: .shimmer, cornerRadius: Self.radius, wholeTurn: true)
        }
        // The window's own corners: the glass fills the panel edge to edge.
        .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: ConcentricRectangle())
        .ignoresSafeArea()
    }

    /// Done, folded: the agent's name, which opens NativeAgent, and ×.
    private var pill: some View {
        HStack(spacing: 10) {
            word(appModel.agentDisplayName, emphasis: true) { ShotgunController.shared.unfold() }
                .help("Open Shotgun")
            closeButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize()
        .background {
            if reduceTransparency { Capsule().fill(NativeAgentShell.room) }
        }
        .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: Capsule())
        .gesture(WindowDragGesture())
        // The window hugs the pill.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button { ShotgunController.shared.close() } label: {
            Image(systemName: "xmark")
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .buttonStyle(.plain)
        .help("Close Shotgun")
        .accessibilityLabel("Close Shotgun")
    }

    // MARK: - Header

    /// One line, replaced in place: what is happening now, or how it ended.
    @ViewBuilder
    private func header(turn: TurnPresentationState?, preview: MacChatScreenPreview?, running: Bool) -> some View {
        HStack(spacing: 10) {
            if running, let turn {
                PulsingDot(color: NativeAgentShell.secondary, size: 7, animates: true)
                    .frame(width: 12)
                // While she drives, the verb's own words win, as on the turn card.
                let line = preview?.isShowable == true ? preview?.caption ?? "" : WorkPaneSteps.liveLine(turn)
                Text(line)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line)
            } else if let turn {
                Text(Self.endWord(turn.phase))
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text("·")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .accessibilityHidden(true)
                word("Open") { ShotgunController.shared.expand() }
                    .help("Open NativeAgent")
            } else {
                Text(appModel.agentDisplayName)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            Spacer(minLength: 4)
            if running {
                // The person holds the Mac (they used it while she drove).
                if preview?.isShowable == true, !ShotgunController.shared.driverAllowed {
                    word("Resume", emphasis: true) { ShotgunController.shared.resume() }
                        .help("Hand the Mac back to me")
                }
                if preview?.isShowable == true {
                    word(watching ? "Hide" : "Watch") { watching.toggle() }
                        .help(watching ? "Hide what I am looking at" : "Watch what I am looking at")
                }
                word("Expand") { ShotgunController.shared.expand() }
                    .help("Open NativeAgent")
            } else if turn == nil {
                word("Open") { ShotgunController.shared.expand() }
                    .help("Open NativeAgent")
                closeButton
            } else {
                closeButton
            }
        }
        .contentShape(Rectangle())
        // The header is the handle the window is dragged by.
        .gesture(WindowDragGesture())
    }

    static func endWord(_ phase: TurnPresentationPhase) -> String {
        switch phase {
        case .canceled: "Stopped"
        case .failed: "Couldn't finish"
        default: "Done"
        }
    }

    private func word(_ title: String, emphasis: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(emphasis ? ShellType.labelSemibold : ShellType.label)
            .foregroundStyle(emphasis ? NativeAgentShell.text : NativeAgentShell.secondary)
    }

    // MARK: - Messages

    /// The last ten things said in the chat, newest at the bottom, her reply
    /// streaming into the last one as it does in the main window.
    @ViewBuilder
    private func messages(sessionId: String, running: Bool) -> some View {
        let all = appModel.engine.transcripts.messages(for: sessionId)
        let lastAssistantId = all.last(where: { $0.role == "assistant" })?.id
        let tailId = all.last.flatMap { $0.role == "assistant" ? $0.id : nil }
        let shown = Array(all.filter { $0.role == "user" || $0.role == "assistant" }.suffix(10))
        let decisionRows = all.filter { message in
            hasPendingApproval(message) || message.metadata?.interactionMirror != nil
                || inlineCards.cards(forRow: message.id).contains { $0.needsAttention }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(shown) { message in
                    if message.id == tailId {
                        StreamingTailBubble(
                            message: message,
                            isLastAssistant: message.id == lastAssistantId,
                            isLive: running
                        )
                    } else {
                        MessageBubble(message: message, isLastAssistant: message.id == lastAssistantId)
                            .equatable()
                    }
                }
                // Decisions belong to this session, regardless of the prose cap.
                ForEach(decisionRows) { message in
                    if hasPendingApproval(message) {
                        InlineApprovalCard(message: message)
                    }
                    if let mirror = message.metadata?.interactionMirror,
                       let binding = mirrorCards[mirror.sessionID] {
                        InteractionInboxCard(mirrorOf: .init(sessionID: mirror.sessionID,
                                                            interactionID: mirror.interactionID),
                                             hidesAnswered: true, binding: binding)
                    }
                    ChatInlineCardHost(cards: inlineCards.cards(forRow: message.id).filter { $0.needsAttention }) { card, action in
                        inlineCards.handle(card: card, action: action, appModel: appModel)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        // Opens at the newest and stays there while the reply grows.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }

    private func hasPendingApproval(_ message: ChatMessage) -> Bool {
        guard message.metadata?.isPendingApproval == true else { return false }
        return appModel.engine.approvals.records.first(where: { $0.id == message.metadata?.approvalId })
            .map { $0.status == "pending" } ?? true
    }

    // MARK: - Composer

    private func composer(sessionId: String, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(appModel.agentDisplayName)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ShellType.body)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit { send(sessionId: sessionId) }
                let canSend = ChatTranscriptPresentation.hasVisibleText(draft) && !sending
                let lit = running || canSend
                Button {
                    if running { appModel.stopChatStream(sessionId: sessionId) }
                    else { send(sessionId: sessionId) }
                } label: {
                    ZStack {
                        if running {
                            Image(systemName: "stop.fill")
                                .font(ShellType.label)
                                .transition(glyphSwap)
                        } else {
                            Image(systemName: "arrow.right")
                                .font(ShellType.body)
                                .transition(glyphSwap)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(lit ? Color.primary.opacity(0.12) : NativeAgentShell.quietFill, in: Circle())
                    .foregroundStyle(lit ? NativeAgentShell.text : NativeAgentShell.tertiary)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!lit)
                .help(running ? "Stop what I am doing" : "Send")
                .accessibilityLabel(running ? "Stop" : "Send")
                .contextMenu {
                    if running {
                        Button("Send next") { send(sessionId: sessionId) }
                            .disabled(!canSend)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                NativeAgentShell.softFill,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            if let notice {
                Text(notice)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var glyphSwap: AnyTransition {
        reduceMotion ? .identity
            : .scale(scale: 0.5).combined(with: .opacity).animation(NativeAgentMotion.arrivalCurve)
    }

    /// Into the same chat; while she is busy it waits in the send-next queue,
    /// exactly as from the main composer.
    private func send(sessionId: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            switch await appModel.startChatTurnForSession(text, sessionId: sessionId) {
            case .accepted, .queued:
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                // Sent: the keyboard goes back to the app she is driving, and
                // any keystrokes of hers that waited on this message go on.
                ShotgunController.shared.giveKeyboardBack()
            case .rejected(let message):
                notice = message
            }
        }
    }
}
