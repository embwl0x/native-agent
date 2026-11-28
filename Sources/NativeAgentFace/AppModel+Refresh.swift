import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `AppModel+Refresh.swift` | Checked refresh replies and person-request feedback |

enum FaceActionFeedback {
    static func message(_ error: any Error, action: String) -> String {
        "Couldn't \(action). \(error.localizedDescription)"
    }

    static func unexpected(_ expected: String) -> WireFailure {
        WireFailure(code: "unexpected_face_reply", message: "Not sure that went through. Check before trying again.",
                    cause: "The body did not return \(expected). The operation's outcome is unknown.", effects: .unknown)
    }
}

extension FaceActReply {
    func checkedCommit() throws -> CommittedResult {
        let result: CommittedResult
        switch self {
        case .committed(let value): result = value
        case .failed(let failure), .refused(let failure): throw failure
        default: throw FaceActionFeedback.unexpected("a committed result")
        }
        if let failure = result.publicationFailure { throw failure }
        return result
    }

    func checkedAcknowledgement() throws {
        switch self {
        case .acknowledged: return
        case .failed(let failure), .refused(let failure): throw failure
        default: throw FaceActionFeedback.unexpected("an acknowledgement")
        }
    }

    func checkedPersona(documents: Bool = false) throws -> PersonaSettingsFace {
        switch self {
        case .persona(let value):
            if let issue = documents ? value.documentsIssue : value.profileIssue {
                throw WireFailure(code: "persona_readback_unavailable", message: issue, cause: nil, effects: .unknown)
            }
            return value
        case .failed(let failure), .refused(let failure): throw failure
        default: throw FaceActionFeedback.unexpected("the saved persona")
        }
    }

    func checkedValue() throws -> PartFace.Value {
        switch self {
        case .result(let value): return value
        case .failed(let failure), .refused(let failure): throw failure
        default: throw FaceActionFeedback.unexpected("the requested readback")
        }
    }
}
extension PartFace.Value {
    func requiredObject() throws -> [String: PartFace.Value] {
        guard case .object(let fields) = self else { throw FaceActionFeedback.unexpected("an object readback") }
        return fields
    }

}

@MainActor
extension AppModel {

    @discardableResult
    func requestFaceRefresh(_ scope: FaceRefreshScope, userInitiated: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !userInitiated { faceRefreshIssue = nil }
        do {
            try await client.act(.refresh(scope)).checkedAcknowledgement()
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            setFailureStatus(error, action: "refresh the requested view")
            if userInitiated { systemToasts.push(error: statusText) }
            else { faceRefreshIssue = statusText }
            return false
        }
    }
}
