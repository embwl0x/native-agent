import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MacControlActionRoutes.swift` | Canonical MacControlResult dispatch receipts and bridge action paths |

/// Bridge wire translation; the client owns execution gates and the receipt.
public enum MacControlActionRoutes {
    public static func run(path: String, bodyData: Data, dataRoot: URL, turn: Turn, context: MacOperationContext, makeClient: (
        URL) -> any MacControlClient) async throws -> JSONValue {
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
            let impl = makeClient(dataRoot)
            do {
                return try await impl.dispatch(action: action, body: bodyDict, turn: turn, context: context).toJSON(readContent: context.readContent)
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

    /// Keep bridge paths aligned with native callers so wire translation cannot redirect an action.
    fileprivate static func macControlActionFromPath(_ path: String) -> String? {
        let prefix = "/v1/mac_control/"
        guard path.hasPrefix(prefix) else { return nil }
        let action = String(path.dropFirst(prefix.count))
        return action.isEmpty ? nil : action
    }
}
