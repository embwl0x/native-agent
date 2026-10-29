import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
import NativeAgentShared
// Blueprint: | `SentTurnContext.swift` | Exact user-leading delivery and complete-state metadata; ordered paragraph replacements against the preceding replayed state, with route/window keyframes and optional locked user-row persistence; human content stays unchanged |

/// Delivery metadata, never a memory or a second transcript. Old rows without
/// this metadata keep their existing projection; their missing context is not invented.
package struct SentTurnContext: Sendable {
    package static let metadataKey = "sentTurnContext"
    package let block: String
    package let isKeyframe: Bool
    /// The complete state after this delivery, not another model-facing block.
    /// Absent on legacy rows, which cannot establish a delta baseline.
    let fullBlock: String?
    let model: String
    let provider: String?
    let window: String
    /// Exact model-facing words (including attachment text/riders). Image
    /// pixels keep their existing current-turn-only delivery policy.
    package let userText: String?

    package init(block: String, isKeyframe: Bool, model: String, provider: String?, window: String, userText: String?, fullBlock: String? = nil) {
        self.block = block; self.isKeyframe = isKeyframe
        self.fullBlock = fullBlock
        self.model = model; self.provider = provider; self.window = window; self.userText = userText
    }

    package init?(metadata: [String: JSONValue]?) {
        guard case .object(let value)? = metadata?[Self.metadataKey],
              case .string(let block)? = value["block"],
              case .bool(let keyframe)? = value["keyframe"],
              case .string(let model)? = value["model"],
              case .string(let window)? = value["window"] else { return nil }
        self.block = block; self.isKeyframe = keyframe; self.model = model; self.window = window
        if case .string(let full)? = value["fullBlock"] { self.fullBlock = full } else { self.fullBlock = nil }
        if case .string(let provider)? = value["provider"] { self.provider = provider } else { self.provider = nil }
        if case .string(let text)? = value["userText"] { self.userText = text } else { self.userText = nil }
    }

    private var json: JSONValue {
        .object(["block": .string(block), "keyframe": .bool(isKeyframe), "model": .string(model),
                 "provider": provider.map(JSONValue.string) ?? .null, "window": .string(window),
                 "userText": userText.map(JSONValue.string) ?? .null,
                 "fullBlock": fullBlock.map(JSONValue.string) ?? .null])
    }

    /// One rule for the whole built block: blank-line-separated paragraphs,
    /// compared by UTF-8 bytes (Swift String equality normalizes Unicode).
    /// A changed route/window or a missing retained keyframe starts anew.
    package static func delivery(full: String, replayed: [Self], model: String, provider: String?,
                                 window: String, userText: String?) -> Self {
        let keyframe = replayed.lastIndex(where: { $0.isKeyframe })
        let retained = keyframe.map { Array(replayed[$0...]) } ?? []
        guard let previous = retained.last?.fullBlock,
              retained.allSatisfy({ $0.model == model && $0.provider == provider && $0.window == window }) else {
            return Self(block: full, isKeyframe: true, model: model, provider: provider, window: window, userText: userText, fullBlock: full)
        }
        let old = previous.isEmpty ? [] : previous.components(separatedBy: "\n\n")
        let new = full.isEmpty ? [] : full.components(separatedBy: "\n\n")
        // One ordered splice keeps duplicates and reordering meaningful. A
        // value returning to an earlier value still differs from THIS state.
        var start = 0
        while start < min(old.count, new.count), Data(old[start].utf8) == Data(new[start].utf8) { start += 1 }
        var end = old.count
        var newEnd = new.count
        while end > start, newEnd > start, Data(old[end - 1].utf8) == Data(new[newEnd - 1].utf8) {
            end -= 1; newEnd -= 1
        }
        let delta: String
        if start == end && start == newEnd { delta = "" }
        else {
            let replacement = new[start..<newEnd].joined(separator: "\n\n")
            delta = "[Context update: in the preceding complete context, skip the first \(start) paragraphs, remove the next \(end - start), and insert the following \(newEnd - start) in their place. Keep the remaining paragraphs in order. Paragraphs are separated by blank lines; this update supersedes the removed text.]"
                + (replacement.isEmpty ? "" : "\n\n" + replacement)
        }
        return Self(block: delta, isKeyframe: false, model: model, provider: provider, window: window, userText: userText, fullBlock: full)
    }

    /// Optional replay evidence everywhere: a failed save leaves the next
    /// turn's baseline absent, so it sends the missing context again.
    package func persist(sessionID: String, runID: String, userMessageID: String? = nil, dataRoot: URL?) async {
        do {
            try await persistMetadata(sessionID: sessionID, runID: runID, userMessageID: userMessageID, dataRoot: dataRoot)
        } catch {
            nativeLog("SentTurnContext: the sent context was not kept: %@", error.localizedDescription)
        }
    }

    private func persistMetadata(sessionID: String, runID: String, userMessageID: String?, dataRoot: URL?) async throws {
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            throw NSError(domain: "SentTurnContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid context transcript session."])
        }
        let path = (dataRoot ?? PersistenceCore.defaultDataRoot()).appendingPathComponent("chat/messages/\(safe).jsonl")
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let bytes = try Data(contentsOf: path)
            guard let updated = try ContactThread.editingRow(in: bytes, last: true, matching: { row in
                guard row["role"] == .string("user") else { return false }
                if let userMessageID { return row["id"] == .string(userMessageID) }
                return row["runId"] == .string(runID)
            }, replacement: { original in
                var row = original
                var metadata: [String: JSONValue]
                if case .object(let value)? = row["metadata"] { metadata = value }
                else if row["metadata"] == nil || row["metadata"] == .null { metadata = [:] }
                else {
                    throw NSError(domain: "SentTurnContext", code: 3, userInfo: [NSLocalizedDescriptionKey: "The user row's metadata is unreadable; it was left unchanged."])
                }
                metadata[Self.metadataKey] = self.json
                row["metadata"] = .object(metadata)
                return [.object(row)]
            }) else { return } // A turn without its own user row has no replay baseline.
            try ContactThread.replace(updated, to: path)
        }
    }
}
