import Darwin

// Blueprint: | `NetworkAddress.swift` | Shared loopback and private-network address classification |

public enum NetworkAddress {
    /// Only exact localhost/loopback IP literals are local; lookalike names grant no local authority.
    public static func loopback(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return bytes == Array(repeating: 0, count: 15) + [1]
            || bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] && bytes.dropFirst(12).first == 127
    }

    public static func privateNetwork(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        let value: UInt32
        if inet_pton(AF_INET, host, &v4) == 1 { value = UInt32(bigEndian: v4.s_addr) }
        else {
            guard inet_pton(AF_INET6, String(host.prefix { $0 != "%" }), &v6) == 1 else { return false }
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            guard bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] else {
                let prefix = bytes.prefix(2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
                return bytes.allSatisfy { $0 == 0 } || prefix & 0xffc0 == 0xfe80 || prefix & 0xfe00 == 0xfc00
            }
            value = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        let first = value >> 24, second = value >> 16 & 0xff
        return first == 0 || first == 10 || first == 172 && (16...31).contains(second)
            || first == 192 && second == 168 || first == 169 && second == 254 || first == 100 && (64...127).contains(second)
    }
}
