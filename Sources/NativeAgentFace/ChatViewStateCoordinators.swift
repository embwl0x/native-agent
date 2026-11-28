import AppKit
import NativeAgentShared
import Foundation
import SwiftUI

// Blueprint: | `ChatViewStateCoordinators.swift` | Card clearance, one-shot clear and occurrence-preserving toasts |

@Observable
@MainActor
final class ChatToastQueue {
    var current: String?

    @ObservationIgnored private var queue: [String] = []
    private let displayDuration: TimeInterval
    init(displayDuration: TimeInterval = 2.0) {
        self.displayDuration = max(0, displayDuration)
    }

    /// Preserve each producer occurrence until it is presented.
    func show(_ message: String) {
        queue.append(message)
        if current == nil { advance() }
    }

    private func advance() {
        guard !queue.isEmpty else { return }
        current = queue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
            self.current = nil
            self.advance()
        }
    }
}

/// Only Latest observes measured heights so card and composer growth cannot invalidate ChatView.body.
@MainActor
@Observable
final class ChatTurnCardClearance {
    var measuredHeight: CGFloat = 0
    /// Keep the idle floor even when no card is visible.
    var showsTurnCard = false
    var showsCard: Bool { showsTurnCard || measuredHeight > 0 }
    /// Use measured composer inset to align the Latest overlay with the frame.
    var measuredComposerHeight: CGFloat = 0
    var clearance: CGFloat {
        ChatViewportPresentation.transcriptBottomClearance(
            showingTurnCard: showsCard,
            measuredCardHeight: measuredHeight,
            measuredComposerHeight: measuredComposerHeight
        )
    }

    /// Keep idle clearance until the composer is measured.
    func idleClearance(floor: CGFloat) -> CGFloat {
        max(floor, ChatViewportPresentation.composerClearance(
            measuredComposerHeight: measuredComposerHeight))
    }
}

/// Confine clearance reads to a modifier body so only the Latest pill re-lays out.
struct ChatTurnCardClearancePadding: ViewModifier {
    let store: ChatTurnCardClearance
    let idle: CGFloat

    func body(content: Content) -> some View {
        content.padding(
            .bottom,
            (store.showsCard ? store.clearance : store.idleClearance(floor: idle))
        )
    }
}

/// Keep these presentation rules value-only; the viewport owns their sole state.
enum ChatViewportPresentation {
    static func turnCardClearance(showingTurnCard: Bool, measuredHeight: CGFloat) -> CGFloat {
        guard showingTurnCard else { return MacChatTurnCardMetrics.floatingClearance }
        return max(MacChatTurnCardMetrics.floatingClearance, measuredHeight)
    }

    /// Latest must clear both stacked bottom insets.
    static func transcriptBottomClearance(
        showingTurnCard: Bool,
        measuredCardHeight: CGFloat,
        measuredComposerHeight: CGFloat
    ) -> CGFloat {
        let card = turnCardClearance(
            showingTurnCard: showingTurnCard,
            measuredHeight: measuredCardHeight
        )
        return card + composerClearance(measuredComposerHeight: measuredComposerHeight)
    }

    /// Before measurement, do not invent a composer height.
    static func composerClearance(measuredComposerHeight: CGFloat) -> CGFloat {
        guard measuredComposerHeight > 0 else { return 0 }
        let sane = min(measuredComposerHeight, NativeAgentShellLayout.composerClearanceMax)
        return sane + NativeAgentShellLayout.composerClearanceMargin
    }
}

/// Consume the captured session exactly once, and only from a presented confirmation.
struct ChatClearConfirmationState: Equatable {
    private(set) var sessionId: String?
    var isPresented: Bool { sessionId != nil }

    mutating func request(sessionId: String) {
        guard !isPresented else { return }
        self.sessionId = sessionId
    }

    mutating func cancel() {
        sessionId = nil
    }

    mutating func consumeConfirmation() -> String? {
        defer { cancel() }
        return sessionId
    }
}

/// Observe lifecycle and approvals here so updates cannot invalidate ChatView.body.
struct ChatTurnCardInset: View {
    @Environment(AppModel.self) var appModel
    /// Keep the thumbnail in Simple because it has no Work pane.
    @Environment(\.layoutProfile) private var layoutProfile
    let store: ChatTurnCardClearance

    var body: some View {
        ChatTurnStepsFace(sessionID: appModel.activeChatSessionId, showsStatus: showThinkingRow,
                          onOpenScreen: layoutProfile == SimpleViewMode.simple ? nil : { WorkPaneState.shared.userShow(.screen) })
            .id(appModel.activeChatSessionId)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { store.measuredHeight = $0 }
            .onChange(of: showThinkingRow, initial: true) { _, shows in store.showsTurnCard = shows }
    }
}

private struct ChatTurnStepsFace: View {
    private struct TurnReading: Equatable {
        let id: String
        let isLive: Bool
        let ending: TurnPresentationPhase?
        let settledSteps: [TurnFace.Step]
    }

    private struct Reading: Equatable {
        let turnID: String
        var face: PartFace
        var levers: [PartFace.Section]
        var ending: TurnPresentationPhase? = nil
    }

    private enum FooterFocus: Hashable { case pin, dismiss }

    let sessionID: String
    let showsStatus: Bool
    let onOpenScreen: (() -> Void)?
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    @FocusState private var footerFocus: FooterFocus?
    @State private var shown: Reading?
    @State private var session = FacePageSession()

    var body: some View {
        let turn = appModel.turnPart("turnStepsReading", for: sessionID) { face -> TurnReading? in
            guard let face, let id = face.turnID else { return nil }
            let ending = face.phase.flatMap { $0.isTerminal ? $0 : nil }
            return TurnReading(id: id, isLive: face.activeTurnID == id && face.phase?.isTerminal == false,
                               ending: ending, settledSteps: ending == nil ? [] : face.steps)
        }
        let snapshot = chatPageIsVisible && !sessionID.isEmpty
            ? appModel.face.slot(.page(PageFaceKey.turnSteps(sessionID))).value(as: PartFaceSnapshot.self) : nil
        let live = snapshot.flatMap { $0.part == turn?.id && turn?.isLive == true ? $0 : nil }
        let reading = chatPageIsVisible ? shown : nil
        let covered = Set(reading?.face.allRows.filter { $0.tone != .live }.map(\.id) ?? [])
        VStack(spacing: ChatComposerTray.gap) {
            if let shown = reading {
                card(shown, live: live, turn: turn, held: session)
                    .id(shown.turnID)
                    .transition(NativeAgentMotion.reveal(reduceMotion: reduceMotion, anchor: .bottom))
                    .padding(.horizontal, NativeAgentShellLayout.roomGutter)
            }
            if showsStatus {
                MacChatTurnCardHost(sessionId: sessionID, onOpenScreen: onOpenScreen,
                                   coveredTurnID: reading?.turnID, coveredStepIDs: covered)
                    .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                    .padding(.bottom, ChatComposerTray.gap)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(NativeAgentMotion.fade)
            }
        }
        .animation(Animation.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion), value: showsStatus)
        .animation(reduceMotion ? NativeAgentMotion.crossfade : NativeAgentMotion.spring, value: reading?.turnID)
        .onChange(of: chatPageIsVisible) { _, visible in if !visible { replace(with: nil) } }
        .onChange(of: live, initial: true) { _, next in update(next, turn: turn) }
        .onChange(of: turn) { _, next in update(live, turn: next) }
        .onChange(of: session.interactsWithText) { _, _ in update(live, turn: turn) }
        .onChange(of: holdsDissolution) { _, held in
            FaceFollows.shared.holdChatSteps(session, held: held && reading != nil)
            update(live, turn: turn)
        }
        .onDisappear { FaceFollows.shared.holdChatSteps(session, held: false) }
    }

    private var holdsDissolution: Bool { footerFocus != nil || session.holdsDissolution }

    private func card(_ reading: Reading, live: PartFaceSnapshot?, turn: TurnReading?, held: FacePageSession) -> some View {
        let active = reading.turnID == live?.part
        let shape = RoundedRectangle(cornerRadius: NativeAgentRadius.card)
        let operation = held.operation(for: reading.turnID)
        var face = reading.face
        if active || operation != nil {
            face.sections += reading.levers.map { section in
                var section = section
                section.rows = section.rows.map { row in
                    var row = row
                    if !active { row.actions = nil }
                    if let outcome = operation?.outcome, outcome.accepted, !outcome.unresolved { row.detail = outcome.words }
                    return row
                }
                return section
            }
        }
        let door: any FaceDoor = if active || operation != nil {
            appModel.pageDoor(page: PageFaceKey.turnSteps(sessionID), open: { _ in })
        } else { ReadOnlyFaceDoor() }
        let contents = FaceView(face: face, door: door, session: held, inline: true)
        let pinLabel = held.isPinned ? (active ? "Follow live" : "Release") : "Keep open"
        return VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
            contents
            HStack {
                Text(active ? "Turn steps" : Self.endLabel(reading.ending, pinned: held.isPinned))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(pinLabel) {
                    held.isPinned.toggle()
                    update(live, turn: turn)
                }
                .focused($footerFocus, equals: .pin)
                if !active {
                    Button("Dismiss") { replace(with: live) }
                        .focused($footerFocus, equals: .dismiss)
                        .disabled(operation.map { $0.outcome == nil || $0.checking } == true)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(NativeAgentSpacing.md)
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay { shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1).allowsHitTesting(false) }
        .contentShape(shape)
        .onHover { held.isHovering = $0 }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("chat.turn.steps")
    }

    private func update(_ live: PartFaceSnapshot?, turn: TurnReading?) {
        guard var reading = shown else { replace(with: live); return }
        if reading.turnID == live?.part {
            if !session.isPinned, !session.interactsWithText, let live, let face = live.drawnFace {
                reading.face = face
                reading.levers = live.drawnLevers
                if shown != reading { shown = reading }
            }
            return
        }
        guard holdsDissolution else { replace(with: live); return }
        if let turn, turn.id == reading.turnID, let ending = turn.ending {
            reading.ending = ending
            if !session.isPinned {
                let rows = PartFace.turnSteps(turn.settledSteps).allRows
                let final = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                let shownRows = reading.face.allRows
                let shownIDs = Set(shownRows.map(\.id))
                reading.face.sections[0].rows = shownRows.map { final[$0.id] ?? $0 } + rows.filter { !shownIDs.contains($0.id) }
            }
        }
        if !session.isPinned {
            reading.face.sections[0].rows = reading.face.allRows.map { row in
                guard row.tone == .live else { return row }
                return .init(id: row.id, title: row.title, value: "Outcome unconfirmed", tone: .attention)
            }
        }
        if shown != reading { shown = reading }
    }

    private func replace(with live: PartFaceSnapshot?) {
        guard shown != nil || live != nil else { return }
        FaceFollows.shared.holdChatSteps(session, held: false)
        footerFocus = nil
        session = FacePageSession()
        shown = live.flatMap { snapshot in
            snapshot.drawnFace.map { Reading(turnID: snapshot.part, face: $0, levers: snapshot.drawnLevers) }
        }
    }

    private static func endLabel(_ phase: TurnPresentationPhase?, pinned: Bool) -> String {
        let label: String = switch phase {
        case .completed?: "Finished"
        case .canceled?: "Stopped"
        case .failed?: "Turn failed"
        case .outcomeUnknown?: "Outcome unconfirmed"
        case .waitingOnPerson?: "Waiting on you"
        default: "Live updates ended"
        }
        return pinned ? label + " · Last live reading" : label
    }
}
