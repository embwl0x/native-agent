import Foundation

/// One completed wizard must enter Chat before it asks the durable welcome
/// writer to send its hidden kickoff. The writer owns idempotency; this route
/// owns navigation order and preserves the writer's outcome for the UI.
struct OnboardingWizardCompletionReceipt: Equatable, Sendable {
    let destination: SidebarItem
    let chatRefresh: AppModel.PanelRefreshStatus
    let greeting: FirstRunGreetingOutcome

    var statusText: String? {
        greeting.routeFailureMessage.map {
            "Onboarding finished, but \($0)."
        }
    }
}

enum OnboardingWizardCompletionRoute {
    @MainActor
    @discardableResult
    static func complete(
        selectChat: () -> Void,
        refreshChat: () async -> AppModel.PanelRefreshStatus,
        sendGreeting: () async -> FirstRunGreetingOutcome,
        record: (OnboardingWizardCompletionReceipt) -> Void
    ) async -> OnboardingWizardCompletionReceipt {
        selectChat()
        let refresh = await refreshChat()
        let receipt = OnboardingWizardCompletionReceipt(
            destination: .chat,
            chatRefresh: refresh,
            greeting: await sendGreeting()
        )
        record(receipt)
        return receipt
    }
}

extension AppModel {
    @MainActor
    func recordOnboardingWizardCompletion(_ receipt: OnboardingWizardCompletionReceipt) {
        onboardingWizardCompletionReceipt = receipt
        if let status = receipt.statusText {
            statusText = status
        }
    }
}
