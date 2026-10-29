import NativeAgentShared
import EngineRuntime
import Onboarding
import SwiftUI
// Blueprint: | `ResetPersonaView.swift` | ResetPersonaView and OnboardingWizard pending-setup reset; both use the backup-preserving onboarding reset owner |

extension OnboardingWizard {
    func resetPendingOnboarding() async {
        guard let appModel = setupModel() else { return }
        do {
            let reset = try await appModel.resetOnboarding(confirm: true)
            guard reset.ok else {
                state.errorMessage = reset.error ?? "Onboarding reset failed."
                return
            }
            state.pendingRecoveryNeedsReset = false
            state.buildFailed = false
            state.errorMessage = nil
            state.releaseNames(agent: state.suggestedName, user: "")
            state.step = .identity
        } catch {
            state.errorMessage = UserFacingError.message(error, action: "reset setup")
        }
    }
}

struct ResetPersonaView: View {
    @Environment(AppModel.self) private var appModel
    var onReset: (@MainActor () async -> Void)?
    @State private var showConfirmAlert = false
    @State private var isResetting = false
    @State private var resetResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Reset identity")
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                Text("Reset the agent's identity documents.")
                    .font(NativeAgentFont.body)
                Text("Existing documents are backed up before reset. This lets you run the onboarding wizard again.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
                if let result = resetResult {
                    Text(result)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
                Button(isResetting ? "Resetting…" : "Reset identity") {
                    showConfirmAlert = true
                }
                .buttonStyle(.bordered)
                .disabled(isResetting)
            }
            .padding(.horizontal, AliveMetrics.rowInsetH)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aliveCard()
        }
        .accessibilityElement(children: .contain)
        .alert("Reset identity?", isPresented: $showConfirmAlert) {
            Button("Reset", role: .destructive) {
                Task { await performReset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent's identity documents will be backed up and cleared. The onboarding wizard will appear next launch.")
        }
    }

    private func performReset() async {
        isResetting = true
        resetResult = nil
        do {
            let resp = try await appModel.resetOnboarding(confirm: true)
            if resp.ok {
                resetResult = "Reset complete. \(resp.backedUp.count) doc(s) backed up."
                await onReset?()
            } else {
                resetResult = UserFacingError.message(detail: resp.error ?? "no reason given", action: "reset the identity documents")
            }
        } catch {
            resetResult = UserFacingError.message(error, action: "reset the identity documents")
        }
        isResetting = false
    }
}
