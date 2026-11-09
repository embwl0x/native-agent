import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
import NativeAgentShared
// Blueprint: | `SentTurnContext.swift` | SentTurnContext owner. |

/// Public moment context as sent, kept on its user row as evidence; private held choices remain with scratch and history replays neither.
package struct SentTurnContext: Sendable {
    package static let metadataKey = "sentTurnContext"
    package let block: String
    let model: String
    let provider: String?
    /// Retain exact sent words and attachment text; image pixels remain current-turn-only.
    package let userText: String?

    package init(block: String, model: String, provider: String?, userText: String?) {
        self.block = block; self.model = model; self.provider = provider; self.userText = userText
    }

    package init?(metadata: [String: JSONValue]?) {
        guard case .object(let value)? = metadata?[Self.metadataKey],
              case .string(let block)? = value["block"],
              case .string(let model)? = value["model"] else { return nil }
        self.block = block; self.model = model
        if case .string(let provider)? = value["provider"] { self.provider = provider } else { self.provider = nil }
        if case .string(let text)? = value["userText"] { self.userText = text } else { self.userText = nil }
    }

    private var json: JSONValue {
        .object(["block": .string(block), "model": .string(model),
                 "provider": provider.map(JSONValue.string) ?? .null,
                 "userText": userText.map(JSONValue.string) ?? .null])
    }

    /// A failed save leaves the row without its evidence; the turn itself already carried the whole block.
    package func persist(sessionID: String, runID: String, userMessageID: String? = nil, dataRoot: URL?) async {
        do {
            try await persistMetadata(sessionID: sessionID, runID: runID, userMessageID: userMessageID, dataRoot: dataRoot)
        } catch {
            nativeLog("SentTurnContext: the sent context was not kept: %@", error.localizedDescription)
        }
    }

    package static func matches(_ row: [String: JSONValue], runID: String, userMessageID: String?) -> Bool {
        guard row["role"] == .string("user") else { return false }
        if let userMessageID { return row["id"] == .string(userMessageID) }
        return row["runId"] == .string(runID)
    }

    private func persistMetadata(sessionID: String, runID: String, userMessageID: String?, dataRoot: URL?) async throws {
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            throw NSError(domain: "SentTurnContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid context transcript session."])
        }
        let path = (dataRoot ?? PersistenceCore.defaultDataRoot()).appendingPathComponent("chat/messages/\(safe).jsonl")
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let bytes = try Data(contentsOf: path)
            guard let updated = try ContactThread.editingRow(in: bytes, last: true, matching: { row in
                Self.matches(row, runID: runID, userMessageID: userMessageID)
            }, replacement: { original in
                var row = original
                var metadata: [String: JSONValue]
                if case .object(let value)? = row["metadata"] { metadata = value }
                else if row["metadata"] == nil || row["metadata"] == .null { metadata = [:] }
                else {
                    throw NSError(domain: "SentTurnContext", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "The user row's metadata is unreadable; it was left unchanged."])
                }
                metadata[Self.metadataKey] = self.json
                row["metadata"] = .object(metadata)
                return [.object(row)]
            }) else { return } // A turn without its own user row has no row to keep its block on.
            try ContactThread.replace(updated, to: path)
        }
    }
}
