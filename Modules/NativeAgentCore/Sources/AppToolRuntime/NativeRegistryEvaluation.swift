import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `NativeRegistryEvaluation.swift` | `NativeRegistryEvaluation` enum; `appendBoundedRun` |

/// Bounded improvements/gauntlet/runs.json joins local backup and support bundles; production export and phone sync exclude it.
public enum NativeRegistryEvaluation {
    public enum LedgerError: LocalizedError {
        case invalidRoot

        public var errorDescription: String? {
            "The gauntlet run ledger must be a JSON array. Its existing bytes were preserved."
        }
    }

    public static func appendBoundedRun(_ row: JSONValue, to path: URL) async throws {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let raw = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .array([]))
            guard case .array(let existing) = raw else { throw LedgerError.invalidRoot }
            var rows = existing
            rows.append(row)
            if rows.count > 200 {
                rows = Array(rows.suffix(200))
            }
            try await SwiftNativePersistenceCore.writeJSON(.array(rows), to: path)
        }
    }

}
