import Foundation

func decodeTolerantDisplayString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
        return value
    }
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
        return String(value)
    }
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
        return String(value)
    }
    if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
        return value ? "true" : "false"
    }
    if let value = try? container.decodeIfPresent(NextGenJSONValue.self, forKey: key) {
        return value.displayString
    }
    return nil
}
