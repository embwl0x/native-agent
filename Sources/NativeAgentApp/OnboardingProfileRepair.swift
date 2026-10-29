import NativeAgentShared
import EngineRuntime
import Onboarding
import SwiftUI
// Blueprint: | `OnboardingProfileRepair.swift` | OnboardingWizard profile-only repair, failure copy, ProfileRepairStep and DoneStep; completion bypasses fresh-install scaffolding and welcome |

extension OnboardingWizard {
    /// Writes only memory/profile.json; failures retain the entered names on this step.
    func submitProfileRepair() async {
        guard let appModel = setupModel() else { return }
        state.isLoading = true
        state.errorMessage = nil
        do {
            let resp = try await appModel.repairOnboardingProfile(
                agentName: state.trimmedAgentName,
                personaType: state.personaType,
                userName: state.trimmedUserName
            )
            state.isLoading = false
            guard resp.ok else {
                let message = Self.profileRepairFailureMessage(error: resp.error, detail: resp.detail)
                // A changed profile or pending transaction requires a fresh durable verdict.
                if resp.requiresProfileRepairRecheck {
                    await loadOnboardingState()
                    if state.step == .profileRepair {
                        state.profileRepairRecheckOffered = true
                        state.errorMessage = message
                    }
                    return
                }
                state.errorMessage = message
                return
            }
            state.profileRepairRecheckOffered = false
            state.releaseNames(agent: state.trimmedAgentName, user: state.trimmedUserName)
            // Profile repair ends here; never run fresh-install scaffold repair or arm its welcome.
            state.step = .done
        } catch {
            state.isLoading = false
            state.errorMessage = UserFacingError.message(error, action: "save the names")
        }
    }

    /// Backend codes are not user-facing copy. Copy names the agent by the
    /// entered name or "the agent" — never a pronoun.
    static func profileRepairFailureMessage(error: String?, detail: String?) -> String {
        switch error {
        case "missing_agent_name":
            return "Enter a name for the agent before saving."
        case "missing_user_name":
            return "Enter your name before saving."
        case "profile_already_present":
            return "A profile file is already there, so nothing was overwritten. Check again to pick up the current state."
        case "profile_repair_not_required":
            return "No completed onboarding was found on this Mac, so there is no profile to repair."
        case "onboarding_in_progress":
            return "An interrupted onboarding is still pending. Check again to finish it first."
        case .some(let code) where detail == nil || detail?.isEmpty == true:
            return "Saving the names failed (\(code))."
        default:
            return detail ?? error ?? "Saving the names failed."
        }
    }
}

struct DoneStep: View {
    let state: OnboardingWizardState
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(NativeAgentShell.secondary)
            Text("\(state.agentName) is back.")
                .font(ShellType.display)
            // A repair changed one file. It says nothing about providers,
            // so it must not nag about connecting one.
            Text("The names are saved again. Nothing else on this Mac was changed.")
                .font(NativeAgentFont.title)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // A name repair leaves the saved Simple/Advanced choice alone.
            Button("Start") { onComplete() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
    }
}

/// Asks for missing names on a completed install, preserving the existing persona documents.
struct ProfileRepairStep: View {
    @Bindable var state: OnboardingWizardState
    let onSave: () -> Void
    let onRecheck: () -> Void

    private var canSave: Bool {
        !state.trimmedAgentName.isEmpty && !state.trimmedUserName.isEmpty && !state.isLoading
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Label("Names missing", systemImage: "person.text.rectangle")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.orange)
                    Text("Enter the names again to finish setting this Mac back up.")
                        .font(NativeAgentFont.display)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Setup finished on this Mac, but the file holding your name and the agent's name is gone, so a default is being used instead. Nothing here can guess them. The existing personality documents are kept exactly as they are — only the names file is rewritten.")
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NativePanel {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your name")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.secondary)
                            TextField("Your name", text: $state.userName)
                                .font(NativeAgentFont.body)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Agent name")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.secondary)
                            TextField("Agent name", text: $state.agentName)
                                .accessibilityLabel("Agent name")
                                .font(NativeAgentFont.body)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                if let message = state.missingNamesMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = state.errorMessage {
                    Text(message)
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    if state.profileRepairRecheckOffered {
                        Button("Check again") { onRecheck() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(state.isLoading)
                    }
                    Button(state.isLoading ? "Saving\u{2026}" : "Save names") { onSave() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSave)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
