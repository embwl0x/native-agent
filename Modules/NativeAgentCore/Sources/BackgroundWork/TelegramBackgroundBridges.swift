import Foundation
import NativeAgentCore
import ChatToolRuntime
import TelegramBot
import ProviderRouting
import MemoryV2
import DeviceSync
import NotificationInbox
import PersistenceCore
// Blueprint: | `TelegramBackgroundBridges.swift` | Telegram memory-write bridge through the canonical memory owner |

public struct TelegramMemoryWriterBridge: TelegramMemoryWriteRef, Sendable {
    let memory: SwiftNativeMemoryV2

    public init(dataRoot: URL) {
        self.memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
    }

    public func remember(text: String, source: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TelegramBotError.invalidRequest }
        let record = try await memory.store(
            content: trimmed,
            source: source,
            metadata: .object([
                "surface": .string("telegram"),
                "command": .string("/remember"),
            ])
        )
        return record.id
    }

    public func note(text: String, kind: String, source: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TelegramBotError.invalidRequest }
        let resolvedKind = kind.isEmpty ? "telegram_note" : kind
        let record = try await memory.store(
            content: trimmed,
            source: source,
            metadata: .object([
                "note_kind": .string(resolvedKind),
                "tags": .array([.string("telegram")]),
                "confidence": .double(0.8),
                "importance": .double(0.5),
                "surface": .string("telegram"),
                "command": .string("/note"),
            ])
        )
        return record.id
    }
}
