import AppKit
import NativeAgentShared
import Foundation
import SwiftUI
/// Distinguish transcript layout motion from reader input so unintended jumps remain observable.
let scrollMoveLog = ModuleLog(category: "TranscriptScroll")

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
    var showsCard = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Keep the thumbnail in Simple because it has no Work pane.
    @Environment(\.layoutProfile) private var layoutProfile
    let store: ChatTurnCardClearance

    /// Keep the tray inside the glass merge distance so it fuses with the composer's container.
    private var card: some View {
        // Use the composer-owned Stop in this window while sharing detached chat's card.
        MacChatTurnCardHost(
            sessionId: appModel.activeChatSessionId,
            onOpenScreen: layoutProfile == SimpleViewMode.simple ? nil : { WorkPaneState.shared.userShow(.screen) }
        )
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .padding(.bottom, ChatComposerTray.gap)
    }

    var body: some View {
        // The card's measured height feeds the transcript's bottom inset (`clearance`); the card itself fades in and out.
        ZStack(alignment: .bottom) {
            if showThinkingRow {
                card
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(NativeAgentMotion.fade)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            store.measuredHeight = height
        }
        .onChange(of: showThinkingRow, initial: true) { _, shows in
            store.showsCard = shows
        }
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: showThinkingRow)
    }
}
