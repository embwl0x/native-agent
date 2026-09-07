import PersistenceCore

// Deterministic string/key traversal shared by event, node, and workspace metadata.
enum CognitiveMetadataSignals {
    static func stringSignals(from value: JSONValue) -> [String] {
        switch value {
        case .string(let string):
            return [string]
        case .array(let values):
            return values.flatMap(stringSignals(from:))
        case .object(let object):
            return object.keys.sorted().flatMap { key in
                [key] + stringSignals(from: object[key] ?? .null)
            }
        default:
            return []
        }
    }
}
