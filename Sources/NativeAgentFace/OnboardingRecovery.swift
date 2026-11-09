import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `OnboardingRecovery.swift` | Recovery uses the durable disposition returned by an act, never the drawing feed |

extension OnboardingWizard {
    func loadOnboardingState() async {
        guard let appModel = setupModel() else { return }
        do {
            let reading = try await appModel.readOnboarding()
            switch reading.disposition {
            case .resume:
                state.step = .building
                try await appModel.resumePendingOnboarding()
                state.pendingRecoveryNeedsReset = false
                await finishSuccessfulOnboarding()
            case .repairProfile:
                if !state.profileRepairOnly { state.prepareProfileRepair() }
                state.profileRepairOnly = true
                state.pendingRecoveryNeedsReset = false
                state.errorMessage = nil
                state.step = .profileRepair
            case .profileUnreadable:
                state.pendingRecoveryNeedsReset = false
                state.errorMessage = reading.detail
                state.step = .error
            case .reset, .blockedNeedsReset:
                state.pendingRecoveryNeedsReset = true
                state.errorMessage = reading.detail
                state.step = .error
            case .alreadyOnboarded:
                onComplete()
            case .fresh:
                state.profileRepairOnly = false
                state.pendingRecoveryNeedsReset = false
                state.errorMessage = nil
                if state.step == .error { state.step = .identity }
            }
        } catch {
            state.pendingRecoveryNeedsReset = false
            state.errorMessage = FaceActionFeedback.message(error, action: "read where setup left off")
            state.step = .error
        }
    }

    func resetPendingOnboarding() async {
        guard let appModel = setupModel() else { return }
        do {
            try await appModel.resetOnboarding(confirm: true)
            state.pendingRecoveryNeedsReset = false
            state.errorMessage = nil
            state.releaseNames(agent: state.suggestedName, user: "")
            state.step = .identity
        } catch { state.errorMessage = FaceActionFeedback.message(error, action: "reset setup") }
    }
}

struct ErrorStep: View {
    let state: OnboardingWizardState
    let onRetry: () async -> Void
    let onReset: (() async -> Void)?
    var body: some View {
        let actions: [PartFace.Action] = [.init(id: "read", label: "Try again", call: .init("onboarding.recover"))]
            + (onReset == nil ? [] : [.init(id: "reset", label: "Start setup over", role: .destructive, call: .init("onboarding.reset"))])
        FaceView(face: PartFace(title: "Setup didn't finish on this Mac.", sections: [
            .init(id: "onboarding.error", rows: [.init(id: "onboarding.error", title: "Setup needs attention",
                detail: state.errorMessage, tone: .failed, actions: actions)])
        ]), door: ClosureFaceDoor(open: { _ in }) { input in
            if input.action == "reset" { await onReset?() } else { await onRetry() }
            return .init(effects: .none, accepted: true)
        }, session: state.forms)
    }
}
