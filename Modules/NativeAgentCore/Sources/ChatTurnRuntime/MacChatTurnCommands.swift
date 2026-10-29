import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import MemoryV2
import TurnTrace
import Transcripts
import ChatTurnContracts

// Blueprint: | `MacChatTurnCommands.swift` | `NativeChatTurnOptions` and `MacChatTurnRuntime`: shared Mac turn options, memory facts, notes and scratch commands; transcript commands live on NativeAgentEngine |

/// The two Mac chat entry points share their provider-facing tier setting.
/// Core resolves the installation's persona for every door.
public struct NativeChatTurnOptions: Sendable, Equatable {
    public let serviceTier: String?

    public static func resolve(
        fastModeEnabled: Bool,
        surface: String
    ) -> NativeChatTurnOptions {
        return NativeChatTurnOptions(
            serviceTier: surface == "chat" && fastModeEnabled ? "priority" : nil
        )
    }

    /// The picker displays the same normalized value Core compiles.
    public static func normalizedPickerPersona(_ raw: String?, fallback: String = "AI") -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    public static func current(surface: String, defaults: UserDefaults = .standard) -> NativeChatTurnOptions {
        resolve(
            fastModeEnabled: defaults.bool(forKey: "chatFastMode"),
            surface: surface
        )
    }
}

public extension MacChatTurnRuntime {
    nonisolated func storeMacChatMemoryFact(_ text: String) async throws {
        _ = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
            .store(content: text, source: "mac.slash-remember", metadata: nil)
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
                "surface": .string("mac"), "command": .string("/note"),
            ])
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
