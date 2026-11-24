import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ChatSessionScratch.swift` | Locked conversation scratch and one private working-memory slot; off-disk backup only |

/// Share session scratch state across Mac, Telegram and tools; off-disk backup and PrivacyMap/chat include it, local backup/export/phone sync do not.
public enum ChatSessionScratch {
    private static let workingMemoryKey = "__private_working_memory"
    public static let workingMemoryLimit = 1_200

    private static func path(dataRoot: URL, sessionID: String) -> URL {
        dataRoot.appendingPathComponent("chat/sessions/\(sessionID)/scratch.json")
    }

    @concurrent public static func read(dataRoot: URL, sessionID: String) async throws -> JSONValue {
        var scratch = try contents(dataRoot: dataRoot, sessionID: sessionID)
        scratch.removeValue(forKey: workingMemoryKey)
        return .object(scratch)
    }

    private static func contents(dataRoot: URL, sessionID: String) throws -> [String: JSONValue] {
        guard NativeAgentChatSessionID.isSafePathComponent(sessionID) else { throw CocoaError(.fileReadInvalidFileName) }
        let bytes: Data
        do { bytes = try Data(contentsOf: path(dataRoot: dataRoot, sessionID: sessionID)) }
        catch CocoaError.fileReadNoSuchFile { return [:] }
        let raw = try JSONValue.parse(bytes)
        guard case .object(let scratch) = raw else { throw CocoaError(.fileReadCorruptFile) }
        return scratch
    }

    /// Only the serving conversation reads this slot into its private provider input.
    @concurrent public static func workingMemory(dataRoot: URL, sessionID: String) async throws -> String? {
        let scratch = try contents(dataRoot: dataRoot, sessionID: sessionID)
        guard let value = scratch[workingMemoryKey] else { return nil }
        guard case .string(let text) = value, text.count <= workingMemoryLimit else { throw CocoaError(.fileReadCorruptFile) }
        return text
    }

    /// Empty explicitly releases the choice; neither elapsed time nor a read clears it.
    @concurrent public static func holdWorkingMemory(dataRoot: URL, sessionID: String, text: String) async throws {
        guard text.count <= workingMemoryLimit else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        guard try SessionConversation.checkedRow(sessionID, dataRoot: dataRoot) != nil else {
            throw ToolFailureError("This request has no saved conversation to hold a private choice; nothing was changed.", effects: .none)
        }
        try await set(dataRoot: dataRoot, sessionID: sessionID, key: workingMemoryKey, value: text.isEmpty ? nil : .string(text))
    }

    @concurrent public static func write(dataRoot: URL, sessionID: String, key: String, value: String) async throws {
        guard key != workingMemoryKey else { throw CocoaError(.fileWriteInvalidFileName) }
        try await set(dataRoot: dataRoot, sessionID: sessionID, key: key, value: .string(value))
    }

    @concurrent private static func set(dataRoot: URL, sessionID: String, key: String, value: JSONValue?) async throws {
        guard NativeAgentChatSessionID.isSafePathComponent(sessionID) else { throw CocoaError(.fileWriteInvalidFileName) }
        let path = path(dataRoot: dataRoot, sessionID: sessionID)
        let changed = try CredentialFileLock.tryWithLock(path) {
            var root = try contents(dataRoot: dataRoot, sessionID: sessionID)
            guard root[key] != value else { return false }
            root[key] = value
            try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONValue.object(root).serializedData(pretty: true), to: path)
            return true
        }
        guard changed != nil else {
            throw ToolFailureError("Conversation scratch is locked by another writer at \(path.path); nothing was changed.", effects: .none,
                owner: path.path, code: "conversation_scratch_busy",
                instruction: "Let the writer holding this scratch file finish before submitting the choice again.")
        }
    }
}
