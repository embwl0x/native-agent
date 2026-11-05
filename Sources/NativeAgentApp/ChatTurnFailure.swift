import Foundation
import SwiftUI
import ChatTurnRuntime
import ChatSessionWork

// Blueprint: | `ChatTurnFailure.swift` | `FailedTurnRetryConfirmation`: Shared retry confirmation and session-local continuation |

extension AppModel {
    /// Continue in the failed message's session with prior rows visible so it does not replay the whole turn.
    func continueFailedTurn(_ message: ChatMessage) async {
        let sessionId = message.sessionId ?? activeChatSessionId
        _ = await startChatTurnForSession(ChatTurnFailure.continuePrompt, sessionId: sessionId)
    }
}

/// Every retry after effects or unknown outcomes must share one confirmation.
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
