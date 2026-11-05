import Foundation
import CryptoKit
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace
// Blueprint: | `TurnToolResultPointers.swift` | Replace only overflowing tool-result bodies with pointers to their exact retained bytes. |

enum TurnToolResultPointers {
    static func fit(_ conversation: [LLMMessage], window: Int, dataRoot: URL?, surface: String, sessionID: String?, turn: Turn,
                    measure: @Sendable ([LLMMessage]) async throws -> SessionContextMeasurement) async throws -> [LLMMessage] {
        let before = try await measure(conversation)
        guard before.tokens > max(0, window - before.outputTokens) else { return conversation }
        guard let dataRoot else {
            throw ToolFailureError("The turn's result storage is unavailable; its full results were kept in context.", effects: .none)
        }
        var fitted = conversation
        var after = before
        var replaced = 0
        for index in fitted.indices {
            var blocks = fitted[index].content
            for blockIndex in blocks.indices {
                guard case .toolResult(let id, let body, let isError) = blocks[blockIndex] else { continue }
                let directory = dataRoot.appendingPathComponent("chat/tool_results/\(digest(turn.id))", isDirectory: true)
                let path = directory.appendingPathComponent(digest(id + "\u{0}" + body) + ".txt")
                let pointer = "[Full tool result \(id): \(path.path); read the saved result before repeating its action.]"
                guard pointer.count < body.count else { continue }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(body.utf8).write(to: path, options: .atomic)
                blocks[blockIndex] = .toolResult(toolUseId: id, content: pointer, isError: isError)
                fitted[index] = LLMMessage(role: fitted[index].role, content: blocks)
                replaced += 1
                after = try await measure(fitted)
                if after.tokens <= max(0, window - after.outputTokens) { break }
            }
            if after.tokens <= max(0, window - after.outputTokens) { break }
        }
        if replaced > 0 {
            TurnTraceBus.fireFromContext(kind: "context.tool_result.pointer", sessionId: sessionID, surface: surface, payload: .object([
                "replacedBodies": .int(Int64(replaced)), "inputTokensBefore": .int(Int64(before.tokens)),
                "inputTokensAfter": .int(Int64(after.tokens)), "windowTokens": .int(Int64(window))
            ]), turn: turn)
        }
        return fitted
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
