import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Connectors.swift` | Workspace registry read |

public final class SwiftNativeConnectorsClient: Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var workspacesPath: URL {
        root.appendingPathComponent("connectors/workspaces.json")
    }

    public func listWorkspaces() async throws -> [JSONValue] {
        let raw = try await SwiftNativePersistenceCore.readJSON(workspacesPath, ifMissing: .array([]))
        guard case .array(let arr) = raw else {
            throw PersistenceCoreError.ioFailure("\(workspacesPath.path) is not a list of workspaces; repair it before using workspaces")
        }
        return arr
    }
}
