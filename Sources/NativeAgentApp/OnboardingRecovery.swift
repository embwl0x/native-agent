import NativeAgentShared
import EngineRuntime
import Onboarding
import SwiftUI
// Blueprint: | `OnboardingRecovery.swift` | OnboardingWizard durable-state recovery and ErrorStep; interrupted transactions resume through the onboarding owner |

extension OnboardingWizard {
    func loadOnboardingState() async {
        guard let appModel = setupModel() else { return }
        // AppModel selects the onboarding owner for its own root.
        let resp: OnboardingStartResult
        // A fresh start verdict clears the previous scaffold failure.
        state.scaffoldRepairFailed = false
        do {
            resp = try await appModel.engine.onboarding.startOnboarding()
        } catch {
            state.pendingRecoveryNeedsReset = true
            state.errorMessage = UserFacingError.message(error, action: "read where setup left off")
            state.step = .error
            return
        }
        let disposition = resp.disposition(buildFailed: state.buildFailed)
        if disposition == .resume {
            state.step = .building
            do {
                let resumed = try await appModel.resumePendingOnboarding()
                if resumed.ok {
                    state.pendingRecoveryNeedsReset = false
                    state.agentName = resumed.agentName ?? resp.currentPersonaName ?? state.agentName
                    state.userName = resumed.userName ?? state.userName
                    state.personaType = resumed.personaType ?? state.personaType
                    await finishSuccessfulOnboarding()
                } else {
                    state.pendingRecoveryNeedsReset = true
                    state.errorMessage = resumed.detail ?? resumed.error ?? "Onboarding recovery failed."
                    state.step = .error
                }
            } catch {
                state.pendingRecoveryNeedsReset = true
                state.errorMessage = UserFacingError.message(error, action: "pick up setup where it left off")
                state.step = .error
            }
            return
        }
        // Missing names require profile-only repair, preserving the existing persona.
        if disposition == .repairProfile {
            // Rechecks preserve the names already entered.
            if !state.profileRepairOnly {
                state.prepareProfileRepair()
            }
            state.profileRepairOnly = true
            state.pendingRecoveryNeedsReset = false
            state.buildFailed = false
            state.errorMessage = nil
            state.step = .profileRepair
            return
        }
        state.profileRepairRecheckOffered = false
        state.profileRepairOnly = false
        // An unreadable profile on a finished install is its own receipt: no reset offered.
        if disposition == .profileUnreadable {
            state.pendingRecoveryNeedsReset = false
            state.errorMessage = resp.profileUnreadable
            state.step = .error
            return
        }
        if disposition == .reset {
            state.pendingRecoveryNeedsReset = true
            state.errorMessage = "Incomplete persona documents were found. Reset will back them up before onboarding starts again."
            state.step = .error
            return
        }
        if disposition == .alreadyOnboarded || disposition == .blockedNeedsReset {
            if disposition == .alreadyOnboarded {
                onComplete()
            } else {
                state.pendingRecoveryNeedsReset = true
                state.errorMessage = state.errorMessage
                    ?? Self.buildFailureMessage(error: "persona_already_exists", detail: nil)
                state.step = .error
            }
            return
        }
        state.pendingRecoveryNeedsReset = false
        state.abilities = resp.abilityOverview.isEmpty ? SwiftNativeOnboardingClient.abilityOverview : resp.abilityOverview
        if state.step == .error {
            state.step = state.trimmedUserName.isEmpty || state.trimmedAgentName.isEmpty
                ? .identity : .provider
        }
    }
}

struct ErrorStep: View {
    let state: OnboardingWizardState
    let onRetry: () -> Void
    let onReset: (() -> Void)?

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Setup didn't finish on this Mac.")
                .font(NativeAgentFont.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(state.scaffoldRepairFailed
                 ? "Your identity documents are saved. Try again to finish setting up the app's local files."
                 : state.pendingRecoveryNeedsReset
                    ? "Try again to check setup, or start over. Any existing identity documents are backed up before starting over."
                    : "Try again to continue setup.")
                .font(NativeAgentFont.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { onRetry() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            DisclosureGroup("Details") {
                Text(state.errorMessage ?? "No detail was reported.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .font(NativeAgentFont.label)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 360)
            if let onReset {
                Button("Start setup over") { onReset() }
                    .buttonStyle(.link)
                    .font(NativeAgentFont.label)
            }
        }
    }
}
