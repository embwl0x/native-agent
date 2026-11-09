import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `ChatTurnFailure.swift` | Message-scoped continue/restart acts and body-authored failure confirmation |

extension AppModel {
    func continueFailedTurn(message: String, session: String) async {
        await regenerateAssistantMessage(message: message, session: session, choice: .continueFromResults)
    }
}

struct FailedTurnRetryConfirmation: ViewModifier {
    @Binding var failure: WireFailure?
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
        } message: { failure in Text(failure.localizedDescription) }
    }
}
