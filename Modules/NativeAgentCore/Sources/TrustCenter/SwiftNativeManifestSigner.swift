import Foundation
import CryptoKit
import PersistenceCore

// MARK: - SwiftNativeManifestSigner
//
// Swift-native manifest signing and verification. Canonical byte behavior is
// pinned by TrustCenterTests against staged signing keys.

public enum ManifestSigningError: Error, LocalizedError {
    case canonicalizationFailed(String)
    case keyUnavailable(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .canonicalizationFailed(let m): return "manifest signing: canonicalization failed: \(m)"
        case .keyUnavailable(let m): return "manifest signing: key unavailable: \(m)"
        case .ioFailed(let m): return "manifest signing: io failed: \(m)"
        }
    }
}

public actor SwiftNativeManifestSigner {
    private let dataRoot: URL
    private let clock: @Sendable () -> Date

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.clock = clock
    }

    // MARK: - canonical bytes

    /// Canonical compact JSON expected by the signed tool registry.
    /// Non-ASCII characters are emitted as `\uXXXX` escapes and keys sort by UTF-8 byte order.
    public static func canonicalBytes(_ manifest: [String: JSONValue]) throws -> Data {
        var body = manifest
        body.removeValue(forKey: "manifestSignature")
        body.removeValue(forKey: "signedAt")
        body["signatureVersion"] = .int(2)
        var out = String()
        try encode(.object(body), into: &out)
        return Data(out.utf8)
    }

    /// Generic compact canonical-JSON encoder for an arbitrary JSONValue.
    /// Compact sorted JSON encoder for arbitrary payloads. Unlike `canonicalBytes`,
    /// this performs NO manifest-specific field mutation — the caller owns
    /// payload shaping (e.g. the capability-pack signer strips `signature`).
    /// Wave 31 W15: shared by the capability-pack HMAC port so pack signatures
    /// stay identical to `capability_pack_signature()`.
    public static func compactCanonicalJSON(_ value: JSONValue) throws -> Data {
        var out = String()
        try encode(value, into: &out)
        return Data(out.utf8)
    }

    private static func encode(_ value: JSONValue, into out: inout String) throws {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            if !d.isFinite {
                throw ManifestSigningError.canonicalizationFailed("non-finite double")
            }
            if d == d.rounded() && abs(d) < 1e16 {
                out += String(format: "%.1f", d)
            } else {
                out += String(d)
            }
        case .string(let s):
            out += encodeString(s)
        case .array(let arr):
            out += "["
            for (i, el) in arr.enumerated() {
                if i > 0 { out += "," }
                try encode(el, into: &out)
            }
            out += "]"
        case .object(let dict):
            out += "{"
            let sortedKeys = dict.keys.sorted { a, b in
                Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
            }
            for (i, k) in sortedKeys.enumerated() {
                if i > 0 { out += "," }
                out += encodeString(k)
                out += ":"
                try encode(dict[k]!, into: &out)
            }
            out += "}"
        }
    }

    private static func encodeString(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: r += "\\\""
            case 0x5C: r += "\\\\"
            case 0x08: r += "\\b"
            case 0x0C: r += "\\f"
            case 0x0A: r += "\\n"
            case 0x0D: r += "\\r"
            case 0x09: r += "\\t"
            case 0..<0x20:
                r += String(format: "\\u%04x", u.value)
            case 0x20...0x7E:
                r.unicodeScalars.append(u)
            default:
                if u.value > 0xFFFF {
                    let v = u.value - 0x10000
                    let hi = 0xD800 + (v >> 10)
                    let lo = 0xDC00 + (v & 0x3FF)
                    r += String(format: "\\u%04x\\u%04x", hi, lo)
                } else {
                    r += String(format: "\\u%04x", u.value)
                }
            }
        }
        r += "\""
        return r
    }

    // MARK: - key

    /// Load the exact regular 0600 signing key, or durably create it when and
    /// only when the key is missing. Existing invalid authority is unavailable
    /// and remains byte-preserved; it is never silently rotated.
    public func loadOrCreateSigningKey() throws -> Data {
        let keyPath = dataRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent(".manifest_signing_key")
        do {
            return try CheckedFixedSizeSecretFile.loadOrCreate(at: keyPath, byteCount: 32) {
                let key = SymmetricKey(size: .bits256)
                return key.withUnsafeBytes { Data($0) }
            }
        } catch let error as CheckedFixedSizeSecretFile.Unavailable {
            throw ManifestSigningError.keyUnavailable(error.localizedDescription)
        } catch {
            throw ManifestSigningError.keyUnavailable(error.localizedDescription)
        }
    }

    // MARK: - sign / verify

    public func sign(_ manifest: [String: JSONValue]) throws -> [String: JSONValue] {
        var signed = manifest
        signed["signatureVersion"] = .int(2)
        signed["signedAt"] = .string(Self.isoTimestamp(clock()))
        let keyData = try loadOrCreateSigningKey()
        let canonical = try Self.canonicalBytes(signed)
        let mac = HMAC<SHA256>.authenticationCode(
            for: canonical, using: SymmetricKey(data: keyData)
        )
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        signed["manifestSignature"] = .string(hex)
        return signed
    }

    public func verify(_ manifest: [String: JSONValue]) throws -> [String] {
        var sig = ""
        if case .string(let s) = manifest["manifestSignature"] ?? .null {
            sig = s
        }
        if sig.isEmpty {
            return ["Manifest is unsigned; validate/recreate the tool so NativeAgent can sign it."]
        }
        var ver = ""
        switch manifest["signatureVersion"] ?? .null {
        case .int(let i): ver = String(i)
        case .string(let s): ver = s
        default: ver = ""
        }
        if ver != "2" {
            return ["Manifest signatureVersion must be 2."]
        }
        let keyData = try loadOrCreateSigningKey()
        let canonical = try Self.canonicalBytes(manifest)
        let mac = HMAC<SHA256>.authenticationCode(
            for: canonical, using: SymmetricKey(data: keyData)
        )
        let expected = mac.map { String(format: "%02x", $0) }.joined()
        if sig.utf8.count != expected.utf8.count {
            return ["Manifest signature mismatch; tool metadata changed after signing."]
        }
        var diff: UInt8 = 0
        for (a, b) in zip(sig.utf8, expected.utf8) { diff |= a ^ b }
        if diff != 0 {
            return ["Manifest signature mismatch; tool metadata changed after signing."]
        }
        return []
    }

    // MARK: - timestamp

    /// Format `YYYY-MM-DDTHH:MM:SS[.uuuuuu]+00:00` with six microsecond\n    /// digits when needed and no fractional component when subsecond is zero.
    // PUBLIC wave 30 W07 (2026-06-01): exposed so App-target NativeClient
    // capability-catalog ports (getCapabilityCatalog) can produce the SAME
    // `+00:00`/microsecond ISO stamp the SwiftNative ports
    // use internally — avoids the App target inventing a divergent
    // `ISO8601DateFormatter` (`Z`/millisecond) timestamp and breaking parity
    // with `listCapabilityCatalog(dataRoot:nowISO:)`. Pure nonisolated static.
    public nonisolated static func isoTimestamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let ti = date.timeIntervalSince1970
        let frac = ti - floor(ti)
        // Round (not truncate) to microseconds. Date stores time as Double,
        // and at modern epochs (~1.7e9 s) the float resolution is ~4e-7 s,
        // so a Date constructed for ".000001+00:00" lands fractionally
        // below 1e-6 and truncation would emit ".000000". Cap at 999_999
        // so a rounding bump can't silently roll over to the next second.
        var micros = Int((frac * 1_000_000.0).rounded())
        if micros < 0 { micros = 0 }
        if micros > 999_999 { micros = 999_999 }
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
            comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0
        )
        if micros == 0 {
            return base + "+00:00"
        }
        return base + String(format: ".%06d", micros) + "+00:00"
    }
}
