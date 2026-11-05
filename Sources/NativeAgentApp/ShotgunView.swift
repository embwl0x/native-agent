import AppKit
import ApprovalTransactions
import ChatSessionWork
import ChatTurnRuntime
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
import SwiftUI

// Blueprint: | `ShotgunView.swift` | `ShotgunView`: driving-session transcript/composer, live step and Stop/Resume/Watch controls through existing owners |

/// Keep transcript, composer and Stop on the same driving session so remote turns stay controllable.
struct ShotgunView: View {
    static let radius: CGFloat = 22

    /// Measure the folded view so the window can hug its pill.
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
        // Remote turns lack a Mac lifecycle; use root flight state and session Stop.
        let remoteRunning = controller.driver.map { driver in
            driver.session == sessionId && turns.inFlightTurns().contains { $0.turnId == driver.turn }
        } ?? false
        let running = turns.isBusy(sessionId) || turn.map { !$0.isTerminal } == true || remoteRunning
        // Shotgun's projection: the last ten user and assistant rows plus every decision (a pending approval, a card waiting on the
        // person, a mirrored card), grouped as their own run so the document shows exactly that.
        let transcript = {
            let all = appModel.engine.transcripts.messages(for: sessionId)
            let approvals = Dictionary(appModel.engine.approvals.records.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
            let cardsAvailable: Bool
            if case .unavailable = appModel.engine.transcripts.transcriptReadStatus(for: sessionId) { cardsAvailable = false }
            else { cardsAvailable = true }
            var said: [String] = [], decisions = Set<String>(), cardsByRow: [String: [TranscriptReadout.Card]] = [:]
            var mirrors = Set<String>(), waiting = false
            for message in all {
                if message.role == "user" || message.role == "assistant" { said.append(message.id) }
                let pending = message.metadata?.isPendingApproval == true
                    && ((message.metadata?.approvalId).flatMap { approvals[$0] }.map { $0 == "pending" } ?? true)
                let cards = cardsAvailable ? message.inlineCards.filter { $0.model.needsAttention } : []
                if let mirror = message.metadata?.interactionMirror { mirrors.insert(mirror.sessionID) }
                if pending || !cards.isEmpty { waiting = true }
                if pending || !cards.isEmpty || message.metadata?.interactionMirror != nil { decisions.insert(message.id) }
                if !cards.isEmpty { cardsByRow[message.id] = cards }
            }
            let shown = decisions.union(said.suffix(10))
            return (groups: MessageGrouper.projection(for: all.filter { shown.contains($0.id) }), cardsByRow: cardsByRow,
                    failed: ChatTurnFailure.read(all) != nil, mirrors: mirrors, waiting: waiting)
        }()
        let waiting = transcript.waiting
        let done = !running && !waiting && turn?.isTerminal == true
        Group {
            if controller.collapsed && !running && !waiting {
                pill
            } else {
                full(sessionId: sessionId, turn: turn, preview: preview, running: running,
                     groups: transcript.groups, cardsByRow: transcript.cardsByRow, failed: transcript.failed)
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
        groups: MessageGrouper.GroupedTranscript, cardsByRow: [String: [TranscriptReadout.Card]], failed: Bool
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
            TranscriptDocumentView(
                sessionID: sessionId,
                groups: groups,
                cardsByRow: cardsByRow,
                showsTrouble: failed,
                streamingMessageID: appModel.engine.turns.streamingBubbleIds[sessionId]
            )
            .environment(\.inlineCardAction) { [inlineCards, appModel] card, action in
                inlineCards.handle(card: card, action: action, appModel: appModel)
            }
            .environment(\.transcriptOpenSettings) { [inlineCards] in inlineCards.openPage(.settings) }
            .frame(maxHeight: .infinity)
            composer(sessionId: sessionId, running: running)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Exclude controls and transcript so dragging cannot steal their interactions.
            Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
        }
        .background {
            // Reduce Transparency asks for more opacity, never less.
            if reduceTransparency { ConcentricRectangle().fill(NativeAgentShell.room) }
            ThinkingGlow(kind: .shimmer, cornerRadius: Self.radius, wholeTurn: true)
        }
        // Fill the window corners so the glass has no inset seam.
        .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: ConcentricRectangle())
        .ignoresSafeArea()
    }

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

    @ViewBuilder
    private func header(turn: TurnPresentationState?, preview: MacChatScreenPreview?, running: Bool) -> some View {
        HStack(spacing: 10) {
            if running, let turn {
                PulsingDot(color: NativeAgentShell.secondary, size: 7, animates: true)
                    .frame(width: 12)
                // Prefer the driving verb's own words so the header agrees with the turn card.
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
            // The refusal can finish its turn before the person hands the Mac back.
            if !ShotgunController.shared.driverAllowed,
               ShotgunController.shared.selectedSessionID != nil {
                word("Resume", emphasis: true) { ShotgunController.shared.resume() }
                    .help("Hand the Mac back and ask me to continue")
            }
            if running {
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
                        Button("Send into reply in progress") { send(sessionId: sessionId) }
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

    /// Every composer sends through the same conversation admission.
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
            case .accepted:
                let unchanged = draft.text == submitted && draft.editedAt == editedAt
                appModel.clearChatDraftAfterSend(submitted, sessionId: sessionId, editedAt: editedAt)
                // Return keyboard ownership after acceptance so the drive can continue.
                if ShotgunController.shared.selectedSessionID == sessionId, unchanged {
                    ShotgunController.shared.giveKeyboardBack()
                }
            case .rejected(let message):
                if ShotgunController.shared.selectedSessionID == sessionId { notice = message }
            }
        }
    }
}
