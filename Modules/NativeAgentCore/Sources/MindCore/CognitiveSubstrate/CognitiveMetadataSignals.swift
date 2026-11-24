import PersistenceCore
// Blueprint: | `CognitiveMetadataSignals.swift` | `CognitiveMetadataSignals` enum; `stringSignals` |

// Share deterministic traversal so event, node and workspace metadata expose the same signals.
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
