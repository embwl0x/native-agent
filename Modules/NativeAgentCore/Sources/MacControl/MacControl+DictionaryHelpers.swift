import PersistenceCore

// Blueprint: | `MacControl+DictionaryHelpers.swift` | `Dictionary.stringValue`: MacControl's shared typed string lookup for JSON argument dictionaries |

// MARK: - Dictionary helpers

extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(_ key: String) -> String? {
        if case .string(let s) = self[key] ?? .null { return s }
        return nil
    }
}
