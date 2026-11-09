import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `OnboardingProfileRepair.swift` | Profile-only repair and completion; preserves persona and skips fresh-install work |

extension OnboardingWizard {
    /// Retain entered names on failure so repair can continue without re-entry.
    func submitProfileRepair(_ input: FaceActSubmission) async -> FaceActOutcome {
        guard let appModel = setupModel() else {
            return .interrupted(WireFailure(code: "setup_unavailable", message: "The app model is missing.", cause: nil, effects: .none))
        }
        state.isLoading = true
        state.errorMessage = nil
        do {
            if input.checking {
                defer { state.isLoading = false }
                guard let profile = try await appModel.readPersonaFormState(documents: false).profile,
                      let agent = input.values?["agent"]?.stringValue, let user = input.values?["user"]?.stringValue,
                      profile.name == agent.trimmingCharacters(in: .whitespacesAndNewlines),
                      profile.userName == user.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return .init(words: "The saved profile does not confirm these names.", effects: .unknown)
                }
                state.releaseNames(agent: profile.name, user: user.trimmingCharacters(in: .whitespacesAndNewlines))
                state.step = .done
                return .init(effects: .known, accepted: true, committed: [
                    .init(id: "agent", value: .string(profile.name)), .init(id: "user", value: profile.userName.map(PartFace.Value.string))])
            }
            let reply = try await appModel.repairOnboardingProfile(
                agentName: state.trimmedAgentName,
                personaType: state.personaType,
                userName: state.trimmedUserName
            )
            let fields = try reply.requiredObject()
            state.isLoading = false
            state.releaseNames(agent: state.trimmedAgentName, user: state.trimmedUserName)
            // Profile repair ends here; never run fresh-install scaffold repair or arm its welcome.
            state.step = .done
            return .init(effects: .known, accepted: true, committed: [
                .init(id: "agent", value: fields["agentName"]), .init(id: "user", value: fields["userName"])])
        } catch {
            state.isLoading = false
            if let refusal = error as? WireFailure,
               ["profile_already_present", "onboarding_in_progress"].contains(refusal.code) {
                await loadOnboardingState()
            }
            state.errorMessage = FaceActionFeedback.message(error, action: "save the names")
            return .interrupted(error)
        }
    }
}

struct DoneStep: View {
    let state: OnboardingWizardState
    let onComplete: () -> Void
    var body: some View {
        FaceView(face: PartFace(title: "The names are saved.", line: "Your existing personality documents are kept.", sections: [
            .init(id: "onboarding.done", rows: [.init(id: "onboarding.done", title: state.agentName,
                actions: [.init(id: "start", label: "Start", role: .primary, call: .init("onboarding.done"))])])
        ]), door: ClosureFaceDoor(open: { _ in }) { _ in onComplete(); return .init(effects: .none, accepted: true) }, session: state.forms)
    }
}

/// Repair writes only the missing profile through its existing owner.
struct ProfileRepairStep: View {
    @Bindable var state: OnboardingWizardState
    let onSave: (FaceActSubmission) async -> FaceActOutcome
    let onRecheck: () async -> Void
    var body: some View {
        ScrollView {
            FaceView(face: PartFace(title: "Enter the names again.", line: "The names file is missing. Your personality documents are kept.", sections: [
                .init(id: "onboarding.repair", footer: state.errorMessage, rows: [], block: .init(kind: "form", key: "onboarding.repair", fields: [
                    .init(id: "user", label: "Your name", value: .string(state.userName), required: true),
                    .init(id: "agent", label: "Agent name", value: .string(state.agentName), required: true)
                ], submit: [.init(id: "save", label: "Save names", role: .primary, call: .init("onboarding.repair"),
                    unavailable: state.isLoading ? "Waiting on the profile owner." : nil)])),
                .init(id: "onboarding.recheck", rows: [.init(id: "onboarding.recheck", title: "Saved setup", actions: [
                    .init(id: "read", label: "Check again", call: .init("onboarding.recheck"),
                        unavailable: state.isLoading ? "Waiting on the profile owner." : nil)])])
            ]), door: ClosureFaceDoor(open: { _ in }) { input in
                if input.action == "read" { await onRecheck(); return .init(effects: .none, accepted: true) }
                guard case .string(let agent)? = input.values?["agent"], case .string(let user)? = input.values?["user"] else {
                    return .interrupted(WireFailure(code: "names_required", message: "Enter both names.", cause: nil, effects: .none))
                }
                if let issue = NativeAgentIdentity.nameValidationMessage(agent.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return .interrupted(WireFailure(code: "name_invalid", message: issue, cause: nil, effects: .none, fields: ["agent": issue]))
                }
                if !input.checking { state.agentName = agent; state.userName = user }
                return await onSave(input)
            }, session: state.forms)
        }
    }
}
