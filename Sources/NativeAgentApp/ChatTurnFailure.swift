import Foundation
import SwiftUI
import ChatOrchestration

extension AppModel {
    /// Continue from here: a new turn in the failed message's session that
    /// sees the rows above it, instead of replaying the whole turn.
    func continueFailedTurn(_ message: ChatMessage) async {
        let sessionId = message.sessionId ?? activeChatSessionId
        _ = await startChatTurnForSession(ChatTurnFailure.continuePrompt, sessionId: sessionId)
    }
}

/// The one confirmation every retry path shows before re-running a turn that
/// acted or whose outcome is unknown.
struct FailedTurnRetryConfirmation: ViewModifier {
    @Binding var failure: ChatTurnFailure?
    var onRetry: () -> Void
    var onContinue: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Start this over?",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            titleVisibility: .visible,
            presenting: failure
        ) { _ in
            Button("Continue from here", action: onContinue)
            Button("Start over anyway", role: .destructive, action: onRetry)
            Button("Cancel", role: .cancel) {}
        } message: { failure in
            Text(failure.confirmationMessage)
        }
    }
}

extension EnvironmentValues {
    /// True in the main room, where the trouble card carries Retry, so the
    /// failed bubble does not draw a second one. Detached panels have no card
    /// and keep the bubble's own button.
    @Entry var troubleCardOwnsRetry = false
}
