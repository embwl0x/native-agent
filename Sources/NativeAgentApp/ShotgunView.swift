import AppKit
import ApprovalTransactions
import ChatSessionWork
import ChatTurnRuntime
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
import SwiftUI

// Blueprint: | `ShotgunView.swift` | `ShotgunView`: driving-session transcript/composer, live step and Stop/Resume/Watch controls through existing owners |

/// What Shotgun shows (Shotgun.swift owns the window): her live step as one
/// line on top, the last ten messages of the selected conversation with her reply
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
    @State private var watching = false
    @State private var notice: String?
    @State private var sending = false
    @State private var inlineCards = InlineInteractionChatBinding()
    @FocusState private var composerFocused: Bool

    var body: some View {
        let controller = ShotgunController.shared
        let sessionId = controller.selectedSessionID ?? appModel.activeChatSessionId
        let turns = appModel.engine.turns
        let turn = turns.lifecycle(for: sessionId)?.presentation
        let preview = turns.screenPreview(for: sessionId)
        // A turn from another door (Telegram) has no Mac lifecycle: it runs while it
        // is in flight on this root, and Stop reaches it by its session.
        let remoteRunning = controller.driver.map { driver in
            driver.session == sessionId && turns.inFlightTurns().contains { $0.turnId == driver.turn }
        } ?? false
        let running = turns.isBusy(sessionId) || turn.map { !$0.isTerminal } == true || remoteRunning
        let transcript = {
            let all = appModel.engine.transcripts.messages(for: sessionId)
            let approvals = Dictionary(appModel.engine.approvals.records.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
            let cardsAvailable: Bool
            if case .unavailable = appModel.engine.transcripts.transcriptReadStatus(for: sessionId) { cardsAvailable = false }
            else { cardsAvailable = true }
            var shown: [ChatMessage] = [], decisions: [(message: ChatMessage, pending: Bool, cards: [InlineCardModel])] = []
            var mirrors = Set<String>(), lastAssistantId: String?, waiting = false
            for message in all {
                if message.role == "user" || message.role == "assistant" { shown.append(message) }
                if message.role == "assistant" { lastAssistantId = message.id }
                let pending = message.metadata?.isPendingApproval == true
                    && ((message.metadata?.approvalId).flatMap { approvals[$0] }.map { $0 == "pending" } ?? true)
                let cards = cardsAvailable ? message.inlineCards.compactMap { $0.model.needsAttention ? $0.model : nil } : []
                if let mirror = message.metadata?.interactionMirror { mirrors.insert(mirror.sessionID) }
                if pending || !cards.isEmpty { waiting = true }
                if pending || !cards.isEmpty || message.metadata?.interactionMirror != nil { decisions.append((message, pending, cards)) }
            }
            return (shown: Array(shown.suffix(10)), decisions: decisions, mirrors: mirrors, waiting: waiting,
                    lastAssistantId: lastAssistantId, tailId: all.last.flatMap { $0.role == "assistant" ? $0.id : nil })
        }()
        let waiting = transcript.waiting
        let done = !running && !waiting && turn?.isTerminal == true
        Group {
            if controller.collapsed && !running && !waiting {
                pill
            } else {
                full(sessionId: sessionId, turn: turn, preview: preview, running: running,
                     shown: transcript.shown, decisions: transcript.decisions,
                     lastAssistantId: transcript.lastAssistantId, tailId: transcript.tailId)
            }
        }
        .preferredColorScheme(AppearanceController.shared.colorScheme)
        .onChange(of: done && controller.isShown, initial: true) { _, now in controller.setDone(now) }
        .onChange(of: appModel.chatDraft(for: sessionId)) { _, _ in notice = nil }
        .onChange(of: sessionId) { _, _ in notice = nil }
        .inlineCardSetup(inlineCards)
        .task(id: sessionId) { await appModel.engine.transcripts.refreshCards(in: sessionId) }
        .onReceive(NotificationCenter.default.publisher(for: InlineInteractionWire.changedNotification)) { note in
            guard let origin = note.object as? String else { return }
            if origin == sessionId || transcript.mirrors.contains(origin) {
                Task { await appModel.engine.transcripts.refreshCards(in: sessionId) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
            guard note.object as? String == sessionId else { return }
            Task { await appModel.engine.transcripts.refreshCards(in: sessionId) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard note.object is ShotgunPanel else { return }
            Task { await inlineCards.verifyOnReturn() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shotgun")
        .accessibilityIdentifier("shotgun")
    }

    private func full(
        sessionId: String, turn: TurnPresentationState?, preview: MacChatScreenPreview?, running: Bool,
        shown: [ChatMessage], decisions: [(message: ChatMessage, pending: Bool, cards: [InlineCardModel])],
        lastAssistantId: String?, tailId: String?
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
                    ForEach(decisions, id: \.message.id) { decision in
                        if decision.pending {
                            InlineApprovalCard(message: decision.message)
                        }
                        ChatInlineCardHost(cards: decision.cards) { card, action in
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
        case .outcomeUnknown: "Outcome unknown"
        default: "Done"
        }
    }

    private func word(_ title: String, emphasis: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(emphasis ? ShellType.labelSemibold : ShellType.label)
            .foregroundStyle(emphasis ? NativeAgentShell.text : NativeAgentShell.secondary)
    }

    // MARK: - Composer

    private func composer(sessionId: String, running: Bool) -> some View {
        let draft = appModel.composerDraft(for: sessionId)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(appModel.agentDisplayName)…", text: draft.textBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ShellType.body)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit { send(sessionId: sessionId) }
                let canSend = ChatTranscriptPresentation.hasVisibleText(draft.text) && !sending
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
        let draft = appModel.composerDraft(for: sessionId)
        let submitted = draft.text
        let editedAt = draft.editedAt
        let text = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            switch await appModel.startChatTurnForSession(text, sessionId: sessionId) {
            case .accepted, .queued:
                let unchanged = draft.text == submitted && draft.editedAt == editedAt
                appModel.clearChatDraftAfterSend(submitted, sessionId: sessionId, editedAt: editedAt)
                // Sent: the keyboard goes back to the app she is driving, and
                // any keystrokes of hers that waited on this message go on.
                if ShotgunController.shared.selectedSessionID == sessionId, unchanged {
                    ShotgunController.shared.giveKeyboardBack()
                }
            case .rejected(let message):
                if ShotgunController.shared.selectedSessionID == sessionId { notice = message }
            }
        }
    }
}
