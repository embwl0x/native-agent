import Foundation
// Blueprint: | `LeftOutWhenUnreadable.swift` | The one law for reading what a newer build wrote: a value this build cannot read is left out of what carries it |

/// A build reads what it knows. A value of a type marked this way that names a kind, a phase or a shape this build does not know is left out
/// whole, never half-read, and never fails what carries it: an older phone keeps reading a newer Mac. Every keyed field of such a type, or a
/// list of them, takes this path (these overloads are more specific than the generic ones the compiler would otherwise pick).
public protocol LeftOutWhenUnreadable: Decodable {}

extension KeyedDecodingContainer {
    public func decodeIfPresent<T: LeftOutWhenUnreadable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try? decode(type, forKey: key)
    }

    public func decodeIfPresent<T: LeftOutWhenUnreadable>(_ type: [T].Type, forKey key: Key) throws -> [T]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decode(type, forKey: key)
    }

    public func decode<T: LeftOutWhenUnreadable>(_ type: [T].Type, forKey key: Key) throws -> [T] {
        var list = try nestedUnkeyedContainer(forKey: key)
        var read: [T] = []
        while !list.isAtEnd {
            if let value = try? list.decode(T.self) { read.append(value) } else { _ = try list.decode(Unread.self) }
        }
        return read
    }
}

/// Steps past one element without reading it.
private struct Unread: Decodable {
    init(from decoder: Decoder) {}
}
