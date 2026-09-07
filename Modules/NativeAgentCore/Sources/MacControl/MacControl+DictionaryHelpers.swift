import PersistenceCore

// MARK: - Dictionary helpers

extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(_ key: String) -> String? {
        if case .string(let s) = self[key] ?? .null { return s }
        return nil
    }
}
