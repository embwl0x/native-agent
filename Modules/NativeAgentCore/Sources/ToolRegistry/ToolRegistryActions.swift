import Foundation
import NativeAgentCore
import PersistenceCore

public enum ToolRegistryActions {
    public static func updateTool(id: String, autoRun: Bool, dataRoot root: URL, validate: @escaping @Sendable (ToolRecord) throws -> Void) async throws -> ToolRecord {
        let regPath = root.appendingPathComponent("tools/registry.json")
        let core = SwiftNativePersistenceCore()
        return try await core.withFileLock(regPath) {
            let fm = FileManager.default
            try fm.createDirectory(at: regPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            var rows: [[String: Any]] = []
            if fm.fileExists(atPath: regPath.path) {
                let data = try Data(contentsOf: regPath)
                let raw: Any
                do {
                    raw = try JSONSerialization.jsonObject(with: data, options: [])
                } catch {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                        NSLocalizedDescriptionKey: "updateTool: tools registry is malformed"
                    ])
                }
                if let arr = raw as? [[String: Any]] {
                    rows = arr
                } else if let dict = raw as? [String: Any], let arr = dict["tools"] as? [[String: Any]] {
                    rows = arr
                } else {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                        NSLocalizedDescriptionKey: "updateTool: tools registry must contain an array of records"
                    ])
                }
            }
            guard let idx = rows.firstIndex(where: { ($0["id"] as? String) == id }) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "updateTool: tool id \(id) not found in \(regPath.path)"
                ])
            }
            rows[idx]["autoRun"] = autoRun
            let out = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            try out.write(to: regPath, options: .atomic)
            let recordData = try JSONSerialization.data(withJSONObject: rows[idx], options: [])
            let row = try JSONValue.parse(recordData)
            if let field = ToolRecord.stringFieldProblem(in: row) {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "updateTool: tool id \(id) has no valid \(field)"
                ])
            }
            guard let record = ToolRecord(json: row) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "updateTool: tool id \(id) is not a complete registry record"
                ])
            }
            try validate(record)
            return record
        }
    }

}

