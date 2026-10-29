import Foundation
import PersistenceCore
// Blueprint: | `ChatSessionScratch.swift` | `ChatSessionScratch` owns the session scratch JSON path, locked mutation and reads for Mac, Telegram and tools; off-disk backup only, no local backup/export/phone sync, inventoried under chat |

/// Session-local JSON scratch object, shared by Mac, Telegram and tool reads.
/// Local working state: off-disk backup only; no local backup, export or phone sync.
/// Inventoried under PrivacyMap's `chat`; no migration or extra local copy.
public enum ChatSessionScratch {
    private static func path(dataRoot: URL, sessionID: String) -> URL {
        dataRoot.appendingPathComponent("chat/sessions/\(sessionID)/scratch.json")
    }

    public static func read(dataRoot: URL, sessionID: String) async throws -> JSONValue {
        try await SwiftNativePersistenceCore.readJSON(path(dataRoot: dataRoot, sessionID: sessionID), ifMissing: .object([:]))
    }

    public static func write(dataRoot: URL, sessionID: String, key: String, value: String) async throws {
        let path = path(dataRoot: dataRoot, sessionID: sessionID)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let current = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:]))
            guard case .object(var root) = current else {
                throw CocoaError(.fileReadCorruptFile)
            }
            root[key] = .string(value)
            try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
        }
    }
}
