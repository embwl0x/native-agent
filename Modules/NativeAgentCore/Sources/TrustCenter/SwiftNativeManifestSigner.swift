import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SwiftNativeManifestSigner.swift` | `SwiftNativeManifestSigner` actor; 32-byte regular 0600 signing authority with explicit backup/export/sync/privacy decisions; `canonicalBytes`, read-only `existingSigningKey` for proof checks |

// MARK: - SwiftNativeManifestSigner
//
// Owns tools/.manifest_signing_key: exactly 32 binary bytes, regular 0600 file.
// Local backup includes it; export and phone sync exclude it. PrivacyMap counts it under Tools, including hidden files.

public enum ManifestSigningError: Error, LocalizedError {
    case canonicalizationFailed(String)
    case keyUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .canonicalizationFailed(let m): return "manifest_canonicalization_failed: \(m). Replace the named value in the signing input with a finite JSON number before signing."
        case .keyUnavailable(let m): return "manifest_signing_key_unavailable: \(m). Ask the owner to repair or restore the original 32-byte signing key as a regular 0600 file at tools/.manifest_signing_key; never replace an existing signing identity."
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
        try encode(.object(body), into: &out, path: "$")
        return Data(out.utf8)
    }

    private static func encode(_ value: JSONValue, into out: inout String, path: String) throws {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            if !d.isFinite {
                throw ToolFailureError("Signing input has a non-finite number at \(path). Replace it with a finite JSON number; keep any existing signing key.",
                    argumentPath: path, accepted: "A finite JSON number.", effects: .unknown,
                    code: "manifest_canonicalization_failed",
                    instruction: "Replace the named value with a finite JSON number before signing; preserve any existing signing key.", recovery: .correctArguments)
            }
            if d == d.rounded() && abs(d) < 1e16 {
                out += String(format: "%.1f", d)
            } else {
                out += String(d)
            }
        case .string(let s):
            JSONValue.encodeString(s, into: &out)
        case .array(let arr):
            out += "["
            for (i, el) in arr.enumerated() {
                if i > 0 { out += "," }
                try encode(el, into: &out, path: "\(path)[\(i)]")
            }
            out += "]"
        case .object(let dict):
            out += "{"
            let sortedEntries = dict.sorted { a, b in
                Array(a.key.utf8).lexicographicallyPrecedes(Array(b.key.utf8))
            }
            for (i, entry) in sortedEntries.enumerated() {
                let (k, value) = entry
                if i > 0 { out += "," }
                JSONValue.encodeString(k, into: &out)
                out += ":"
                var key = String()
                JSONValue.encodeString(k, into: &key)
                try encode(value, into: &out, path: "\(path)[\(key)]")
            }
            out += "}"
        }
    }

    // MARK: - key

    /// Exactly 32 regular 0600 bytes; create only if missing. Invalid authority stays
    /// byte-preserved and unavailable, never rotated. Local backup carries tools;
    /// off-disk backup, export and phone sync exclude the key. PrivacyMap lists tools.
    public func loadOrCreateSigningKey() throws -> Data {
        do {
            return try CheckedFixedSizeSecretFile.loadOrCreate(at: keyPath, byteCount: 32) {
                let key = SymmetricKey(size: .bits256)
                return key.withUnsafeBytes { Data($0) }
            }
        } catch {
            throw signingKeyFailure(error, effects: .unknown)
        }
    }

    private nonisolated func signingKeyFailure(_ error: any Error, effects: ToolFailureError.Effects) -> ToolFailureError {
        ToolFailureError("Manifest signing key is unavailable: \(error.localizedDescription)",
            effects: effects, owner: keyPath.path,
            tap: "Finder > Go > Go to Folder > \(keyPath.deletingLastPathComponent().path) > .manifest_signing_key > Get Info",
            code: "manifest_signing_key_unavailable",
            instruction: "Ask the owner to repair or restore the original 32-byte signing key as a regular 0600 file; never replace an existing signing identity.")
    }

    /// Local backup only; excluded from production export and phone sync.
    /// PrivacyMap lists tools as nonexportable. Metadata watches use this path.
    public nonisolated var keyPath: URL { dataRoot.appendingPathComponent("tools/.manifest_signing_key") }

    /// Read-only proof checks never create signing authority.
    public nonisolated func existingSigningKey() throws -> Data? {
        do { return try CheckedFixedSizeSecretFile.peekExisting(at: keyPath, byteCount: 32) }
        catch { throw signingKeyFailure(error, effects: .none) }
    }

    // MARK: - sign / verify

    public func sign(_ manifest: [String: JSONValue]) throws -> [String: JSONValue] {
        var signed = manifest
        signed["signatureVersion"] = .int(2)
        signed["signedAt"] = .string(Self.isoTimestamp(clock()))
        let canonical = try Self.canonicalBytes(signed)
        let keyData = try loadOrCreateSigningKey()
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
        guard let keyData = try existingSigningKey() else {
            throw ToolFailureError("Manifest signing authority is missing; verification never creates it.",
                effects: .none, owner: keyPath.path,
                tap: "Finder > Go > Go to Folder > \(keyPath.deletingLastPathComponent().path) > .manifest_signing_key",
                code: "manifest_signing_key_missing",
                instruction: "Ask the owner to restore the original 32-byte signing key as a regular 0600 file; verification cannot establish a new identity.")
        }
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

    /// Emits `YYYY-MM-DDTHH:MM:SS[.uuuuuu]+00:00` with six fractional digits only when nonzero.
    public nonisolated static func isoTimestamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
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
