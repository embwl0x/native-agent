import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MacControlActionRoutes.swift` | Canonical MacControlResult dispatch receipts plus workbench availability and category policy |

/// Bridge wire translation; the client owns execution gates and the receipt.
public enum MacControlActionRoutes {
    public static func auditPath(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("mac_control_audit.jsonl")
    }

    public static func run(path: String, bodyData: Data, dataRoot: URL, makeClient: (URL) -> any MacControlClient) async throws -> JSONValue {
        let bodyDict: [String: JSONValue]? = {
            if bodyData.isEmpty { return [:] }
            guard let parsed = try? JSONValue.parse(bodyData),
                  case .object(let object) = parsed else { return nil }
            return object
        }()
        if let bodyDict, let action = Self.macControlActionFromPath(path) {
            guard macControlDispatchableActions.contains(action) else {
                return .object(["error": .string("unknown_action"), "action": .string(action)])
            }
            let impl = makeClient(auditPath(dataRoot: dataRoot))
            do {
                return try await impl.dispatch(action: action, body: bodyDict).toJSON()
            } catch let mcErr as MacControlError {
                return .object([
                    "error": .string(mcErr.errorDescription ?? "\(mcErr)"),
                    "dispatched_via": .string("swift"),
                ])
            }
        }
        return .object([
            "error": .string("MacControl Swift dispatch did not serve \(path)"),
            "dispatched_via": .string("swift"),
        ])
    }

    /// Preserve callers' existing /v1/mac_control/* paths.
    fileprivate static func macControlActionFromPath(_ path: String) -> String? {
        let prefix = "/v1/mac_control/"
        guard path.hasPrefix(prefix) else { return nil }
        let action = String(path.dropFirst(prefix.count))
        return action.isEmpty ? nil : action
    }
}

public enum MacControlWorkbenchAvailability: Equatable {
    case ready
    case disabled(String)

    public var isEnabled: Bool {
        if case .ready = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .ready:
            nil
        case .disabled(let message):
            message
        }
    }

}

/// The only action routes the mounted workbench can invoke. Keeping route,
/// native action name, policy gate, and user-facing label together prevents a
/// button from quietly drifting onto an unsupported 501 action.
public enum MacControlWorkbenchAction: String, CaseIterable, Sendable {
    case shell
    case fileRead = "file/read"
    case fileWrite = "file/write"
    case notify

    public var path: String { "/v1/mac_control/\(rawValue)" }

    public func availability(
        policy: MacControlPolicyWireSnapshot,
        policySaved: Bool,
        hasRequiredInput: Bool = true
    ) -> MacControlWorkbenchAvailability {
        guard policySaved else {
            return .disabled("Save your Mac Control permissions before trying an action.")
        }
        guard policy.enabled else {
            return .disabled("Turn on Mac Control before using this action.")
        }
        guard categoryAllowed(by: policy) else {
            return .disabled("Enable \(categoryName) in Mac Control categories first.")
        }
        guard hasRequiredInput else {
            return .disabled("Enter the required input before running this action.")
        }
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
