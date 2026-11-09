import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+Onboarding.swift` | Onboarding commands and durable disposition readback through the body |

enum OnboardingDisposition: String {
    case resume, repairProfile, profileUnreadable, reset, alreadyOnboarded, blockedNeedsReset, fresh
}

struct OnboardingReadback {
    let disposition: OnboardingDisposition
    let detail: String?

    init(_ value: PartFace.Value) throws {
        let fields = try value.requiredObject()
        guard case .string(let raw)? = fields["disposition"], let disposition = OnboardingDisposition(rawValue: raw) else {
            throw FaceActionFeedback.unexpected("the durable onboarding disposition")
        }
        self.disposition = disposition
        switch fields["detail"] {
        case .string(let detail): self.detail = detail
        case .null, nil: self.detail = nil
        default: throw FaceActionFeedback.unexpected("onboarding detail text")
        }
    }
}

@MainActor
extension AppModel {
    func readOnboarding() async throws -> OnboardingReadback {
        let value = try await client.act(.onboarding(.start)).checkedValue()
        return try OnboardingReadback(value)
    }

    @discardableResult
    func completeOnboarding(agentName: String, personaType: String, userName: String) async throws -> PartFace.Value {
        try await performOnboarding(.complete(agentName: agentName, personaType: personaType, userName: userName))
    }

    @discardableResult
    func resumePendingOnboarding() async throws -> PartFace.Value {
        try await performOnboarding(.resume)
    }

    @discardableResult
    func repairOnboardingProfile(agentName: String, personaType: String, userName: String) async throws -> PartFace.Value {
        try await performOnboarding(.repairProfile(agentName: agentName, personaType: personaType, userName: userName))
    }

    @discardableResult
    func resetOnboarding(confirm: Bool = true) async throws -> PartFace.Value {
        try await performOnboarding(.reset(confirmed: confirm))
    }

    private func performOnboarding(_ act: OnboardingAct) async throws -> PartFace.Value {
        let value = try await protectedFormAct(.onboarding(act)).checkedValue()
        let fields = try value.requiredObject()
        guard case .bool(let ok)? = fields["ok"] else { throw FaceActionFeedback.unexpected("the setup operation's outcome") }
        guard ok else {
            guard case .string(let code)? = fields["error"] else { throw FaceActionFeedback.unexpected("the setup failure's cause") }
            let detail: String?
            switch fields["detail"] {
            case .string(let text): detail = text
            case .null, nil: detail = nil
            default: throw FaceActionFeedback.unexpected("the setup failure's detail")
            }
            throw WireFailure(code: code, message: "Setup did not finish: " + code, cause: detail, effects: .unknown)
        }
        return value
    }
}
