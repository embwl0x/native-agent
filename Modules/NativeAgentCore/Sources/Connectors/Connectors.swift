import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Connectors.swift` | Workspace registry read and workspace path spelling |

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

    nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }

    static func workspaceURL(_ value: JSONValue?) -> URL? {
        let path = value?.stringValue ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: NativeAgentWorkspaceRoot.fileSpelling(path))
    }
}
