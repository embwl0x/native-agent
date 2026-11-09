import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import MemoryV2
import TurnTrace
import Transcripts
import ChatTurnContracts

// Blueprint: | `MacChatTurnCommands.swift` | `NativeChatTurnOptions`; `MacChatTurnRuntime`; Shared picker and Mac command ownership |

public struct NativeChatTurnOptions: Sendable, Equatable {
    /// The picker and Core share normalization so the displayed persona matches the compiled one.
    public static func normalizedPickerPersona(_ raw: String?, fallback: String = "canonical") -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

public extension MacChatTurnRuntime {
    // These direct UI commands run outside a model turn and perform no sense reads.
    nonisolated func storeMacChatMemoryFact(_ text: String) async throws {
        _ = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
            .store(content: text, source: "mac.slash-remember", metadata: nil,
                   context: MemoryWriteContext(turn: nil, senseReads: nil, telling: MemoryDataProvenance.toldByPerson(dataRoot: dataRoot)))
    }

    nonisolated func storeMacChatNote(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentNotes", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "text is required"])
        }
        _ = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).store(
            content: trimmed, source: "mac.note",
            metadata: .object([
                "note_kind": .string("user_note"), "tags": .array([]),
                "confidence": .double(0.8), "importance": .double(0.5),
                "surface": .string("chat"), "command": .string("/note"),
            ]),
            context: MemoryWriteContext(turn: nil, senseReads: nil, telling: MemoryDataProvenance.toldByPerson(dataRoot: dataRoot))
        )
    }

    nonisolated func writeMacChatScratch(
        key: String, value: String, sessionId: String?
    ) async throws -> (succeeded: Bool, message: String) {
        guard let sessionId, !sessionId.isEmpty else {
            return (false, "Scratch write failed: scratch requires a session")
        }
        guard let safeSid = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return (false, "Scratch write failed: invalid session id for scratch")
        }
        try await ChatSessionScratch.write(dataRoot: dataRoot, sessionID: safeSid, key: key, value: value)
        return (true, "Scratch \(key) set")
    }

}
