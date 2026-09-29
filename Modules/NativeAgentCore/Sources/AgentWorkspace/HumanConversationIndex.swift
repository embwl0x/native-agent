import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts

package enum HumanConversationIndex {
    package static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }; return nil
    }
    package static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let row)? = value { return row }; return [:]
    }
    package static func rows(dataRoot: URL) throws -> [[String: JSONValue]] {
        try ChatSessionIndexFile.loadObjectRowsForMutation(at: dataRoot.appendingPathComponent("chat/sessions.json"))
            .filter { row in
                let source = string(row["source"]) ?? "app"
                return ["app", "chat", "mac", "telegram", "slack", "ios", "iphone", "mobile", "icloud"].contains(source)
                    && row["archived"] != .bool(true)
                    && string(row["id"]).flatMap(NativeAgentChatSessionID.normalizedPathComponent) != nil
            }
            .sorted { (string($0["updatedAt"]) ?? "") > (string($1["updatedAt"]) ?? "") }
    }
}
