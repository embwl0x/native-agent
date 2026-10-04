import Foundation
import NativeAgentCore
import PersistenceCore

public enum NativeRegistryEvaluation {
    public static func appendBoundedRun(_ row: JSONValue, to path: URL) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let raw = try await persistence.readJSON(path, ifMissing: .array([]))
            var rows: [JSONValue]
            if case .array(let existing) = raw {
                rows = existing
            } else {
                rows = []
            }
            rows.append(row)
            if rows.count > 200 {
                rows = Array(rows.suffix(200))
            }
            try await persistence.writeJSON(.array(rows), to: path)
        }
    }

}
