import Foundation
// Blueprint: | `MacControlWorkbenchAction.swift` | Workbench action routes and category-policy availability shared by body and renderer |

public enum MacControlWorkbenchAvailability: Equatable, Sendable {
    case ready
    case disabled(String)
    public var isEnabled: Bool { if case .ready = self { true } else { false } }
    public var message: String? { if case .disabled(let reason) = self { reason } else { nil } }
}

public enum MacControlWorkbenchAction: String, CaseIterable, Sendable {
    case shell
    case fileRead = "file/read"
    case fileWrite = "file/write"
    case notify

    public var path: String { "/v1/mac_control/\(rawValue)" }

    /// The execution receipt owns effect evidence; a transport's committed envelope does not.
    public func settlement(_ value: PartFace.Value, fields: [String: PartFace.Value],
                           publicationFailure: WireFailure? = nil) -> FaceActOutcome {
        guard case .object(let receipt) = value else {
            return .interrupted(WireFailure(code: "workbench_receipt_unreadable", message: "The Mac control reply has no readable receipt.",
                cause: nil, effects: self == .fileRead ? .none : .unknown))
        }
        let output: [String: PartFace.Value]
        if case .object(let values)? = receipt["output"] { output = values } else { output = [:] }
        let state = receipt["operationState"]?.stringValue ?? output["operation_state"]?.stringValue
        let effect = output["effects"]?.stringValue ?? receipt["effects"]?.stringValue
        let pending = receipt["httpStatus"] == .int(202) || output["status"] == .string("pending_approval")
        let succeeded = receipt["ok"] == .bool(true) && receipt["verification"] != .string("failed")
            && (state == nil || state == "completed") && ["completed", "partial"].contains(receipt["status"]?.stringValue ?? "")
        let effects: FaceEffects
        if self == .fileRead, !pending { effects = .none }
        else if pending || effect == "unknown" || receipt["effects"] == .string("unknown")
            || ["accepted", "started", "cancel_requested", "outcome_unknown", "timed_out"].contains(state ?? "") {
            effects = .unknown
        } else if effect == "none" || ["blocked", "refused"].contains(state ?? "") || receipt["httpStatus"] == .int(403) {
            effects = .none
        }
        else if ["known", "occurred", "partial"].contains(effect ?? "") || succeeded { effects = .known }
        else { effects = .unknown }
        if pending { return .init(words: "Waiting on your approval. Read Approvals before running this action again.", effects: .unknown) }
        if succeeded {
            return .init(words: "Mac control action completed.", failure: publicationFailure, effects: effects, accepted: true,
                committed: self == .fileRead || effects == .unknown ? nil : fields.map { .init(id: $0.key, value: $0.value) })
        }
        return .interrupted(WireFailure(code: "workbench_failed", message: "The Mac control action has not confirmed success.",
            cause: receipt["error"]?.stringValue ?? output["detail"]?.stringValue ?? state, effects: effects))
    }

    public func availability(policy: MacControlPolicyWireSnapshot, policySaved: Bool,
                             hasRequiredInput: Bool = true) -> MacControlWorkbenchAvailability {
        guard policySaved else { return .disabled("Save your Mac Control permissions before trying an action.") }
        guard policy.enabled else { return .disabled("Turn on Mac Control before using this action.") }
        guard categoryAllowed(by: policy) else { return .disabled("Enable \(categoryName) in Mac Control categories first.") }
        guard hasRequiredInput else { return .disabled("Enter the required input before running this action.") }
        return .ready
    }

    private var categoryName: String {
        switch self {
        case .shell: "Terminal commands"
        case .fileRead, .fileWrite: "File Operations"
        case .notify: "Notifications"
        }
    }

    private func categoryAllowed(by policy: MacControlPolicyWireSnapshot) -> Bool {
        switch self {
        case .shell: policy.shellAllowed
        case .fileRead, .fileWrite: policy.fileOpsAllowed
        case .notify: policy.notificationsAllowed
        }
    }
}
