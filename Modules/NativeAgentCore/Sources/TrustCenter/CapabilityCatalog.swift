import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

// MARK: - Capability catalog persistence
//
// The retired daemon rewrote these stores while serving a read. That behavior
// is deliberately NOT preserved: sources and trust roots are authoritative
// operator state, so a read must be pure and an existing damaged store must be
// unavailable rather than silently becoming the default list. Missing stores
// are the one legitimate bootstrap case; callers receive in-memory defaults
// without a read-side write.
//
//   1. catalog_sources()
//      → <dataRoot>/catalog/sources/sources.json
//   2. capability_trust_roots()
//      → <dataRoot>/catalog/trust/roots.json
//
// Merge semantics remain compatible on valid input:
//   defaults first; for each default record, overlay any saved record
//   with the same id (saved fields win). Then append unmatched saved records.
//
// Timestamps use SwiftNativeManifestSigner.isoTimestamp (TrustCenter.swift:1334)
// for Python-format-compatible UTC ISO strings.

// MARK: - File-private helpers

public enum CapabilityCatalogPersistenceError: Error, LocalizedError {
    case unreadable(path: String, detail: String)
    case malformed(path: String, detail: String)
    case signingKeyUnavailable(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let detail):
            return "capability catalog store unreadable at \(path): \(detail)"
        case .malformed(let path, let detail):
            return "capability catalog store malformed at \(path): \(detail)"
        case .signingKeyUnavailable(let path, let detail):
            return "capability pack signing key unavailable at \(path): \(detail)"
        }
    }
}

private func loadObjectRowsChecked(
    at path: URL,
    recordKind: String
) throws -> [[String: JSONValue]] {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: path.path) else { return [] }

    let data: Data
    do {
        data = try Data(contentsOf: path)
    } catch {
        throw CapabilityCatalogPersistenceError.unreadable(
            path: path.path,
            detail: error.localizedDescription
        )
    }

    let raw: JSONValue
    do {
        raw = try JSONValue.parse(data)
    } catch {
        throw CapabilityCatalogPersistenceError.malformed(
            path: path.path,
            detail: "invalid JSON: \(error.localizedDescription)"
        )
    }
    guard case .array(let items) = raw else {
        throw CapabilityCatalogPersistenceError.malformed(
            path: path.path,
            detail: "expected a JSON array of \(recordKind) records"
        )
    }

    var rows: [[String: JSONValue]] = []
    rows.reserveCapacity(items.count)
    var seenIDs: Set<String> = []
    for (index, item) in items.enumerated() {
        guard case .object(let row) = item else {
            throw CapabilityCatalogPersistenceError.malformed(
                path: path.path,
                detail: "\(recordKind) row \(index) is not a JSON object"
            )
        }
        guard case .string(let id)? = row["id"],
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CapabilityCatalogPersistenceError.malformed(
                path: path.path,
                detail: "\(recordKind) row \(index) has no non-empty string id"
            )
        }
        guard seenIDs.insert(id).inserted else {
            throw CapabilityCatalogPersistenceError.malformed(
                path: path.path,
                detail: "\(recordKind) row \(index) duplicates id \(id)"
            )
        }
        rows.append(row)
    }
    return rows
}

/// Reusable strict boundary for capability authority files. Backup/restore and
/// other ingress paths should call these methods before installing bytes so the
/// same missing-vs-damaged contract governs live reads and restore preflight.
public enum CapabilityCatalogStoreReader {
    public static func loadCatalogSourcesChecked(
        at path: URL
    ) throws -> [[String: JSONValue]] {
        try loadObjectRowsChecked(at: path, recordKind: "catalog source")
    }

    public static func loadCapabilityTrustRootsChecked(
        at path: URL
    ) throws -> [[String: JSONValue]] {
        try loadObjectRowsChecked(at: path, recordKind: "capability trust root")
    }
}

private func mergeRecords(
    defaults: [[String: JSONValue]],
    saved: [[String: JSONValue]]
) -> [[String: JSONValue]] {
    var byID: [String: [String: JSONValue]] = [:]
    for item in saved {
        byID[mergeID(item)] = item
    }

    var merged: [[String: JSONValue]] = []
    var mergedIDs: Set<String> = []
    for defaultItem in defaults {
        var record = defaultItem
        let id = mergeID(defaultItem)
        if let override = byID[id] {
            for (key, value) in override { record[key] = value }
        }
        merged.append(record)
        mergedIDs.insert(id)
    }
    for item in saved {
        let id = mergeID(item)
        if mergedIDs.insert(id).inserted {
            merged.append(item)
        }
    }
    return merged
}

private func defaultCatalogSources(
    dataRoot: URL,
    nowISO: String
) -> [[String: JSONValue]] {
    [[
        "id": .string("local-catalog"),
        "name": .string("Local NativeAgent Catalog"),
        "kind": .string("local"),
        "url": .string(dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("packs", isDirectory: true)
            .path),
        "status": .string("ready"),
        "trustedRootId": .string("local-trusted"),
        "lastCheckedAt": .null,
        "createdAt": .string(nowISO),
    ]]
}

private func mergeID(_ item: [String: JSONValue]) -> String {
    // Python's `str(item.get("id"))` yields the string id, or "None" when
    // missing. In practice every saved/default record has a real id; we
    // match the documented "" → "" fallthrough used across the rest of
    // CapabilityRecords+Dynamic.swift for parity with that file's
    // conventions, which is identical on the happy path.
    if case .string(let s) = item["id"] ?? .null { return s }
    return ""
}

/// Resolve the capability pack signing key from the Swift-native canonical
/// store:
///   1. A present key must be readable and exactly 64 hexadecimal characters.
///   2. A missing key is generated once, atomically persisted with mode 0600,
///      and read back before it can be used.
/// Existing invalid state is never silently rotated and persistence failures
/// never return an ephemeral in-memory secret.
private func resolvePackSigningKey(
    dataRoot: URL,
    persistence: any PersistenceCoreProtocol
) async throws -> String {
    let keyPath = dataRoot
        .appendingPathComponent("catalog", isDirectory: true)
        .appendingPathComponent(".pack_signing_key")
    let work: @Sendable () async throws -> String = {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: keyPath.path) {
            let data: Data
            do {
                data = try Data(contentsOf: keyPath)
            } catch {
                throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
                    path: keyPath.path,
                    detail: "existing key cannot be read: \(error.localizedDescription)"
                )
            }
            guard let existing = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  existing.count == 64,
                  existing.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
                      default: return false
                      }
                  }) else {
                throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
                    path: keyPath.path,
                    detail: "existing key must contain exactly 64 hexadecimal characters"
                )
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: keyPath.path)
            } catch {
                throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
                    path: keyPath.path,
                    detail: "existing key permissions cannot be verified: \(error.localizedDescription)"
                )
            }
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
                    path: keyPath.path,
                    detail: "existing key must be a regular file with mode 0600"
                )
            }
            return existing
        }

        do {
            try fileManager.createDirectory(
                at: keyPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
                path: keyPath.path,
                detail: "cannot create key directory: \(error.localizedDescription)"
            )
        }

        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            try Data(secret.utf8).write(to: keyPath, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyPath.path
            )
            let persisted = try String(contentsOf: keyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard persisted == secret else {
                throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
                    path: keyPath.path,
                    detail: "generated key failed durable read-back verification"
                )
            }
            let attributes = try fileManager.attributesOfItem(atPath: keyPath.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
                    path: keyPath.path,
                    detail: "generated key failed mode 0600 verification"
                )
            }
        } catch {
            // A failed permission/read-back step must not strand valid-looking
            // bytes that a later invocation could adopt. Remove only the exact
            // secret generated by this invocation; never rotate unrelated state.
            if (try? Data(contentsOf: keyPath)) == Data(secret.utf8) {
                try? fileManager.removeItem(at: keyPath)
            }
            if let persistenceError = error as? CapabilityCatalogPersistenceError {
                throw persistenceError
            }
            throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
                path: keyPath.path,
                detail: "cannot persist generated key: \(error.localizedDescription)"
            )
        }
        return secret
    }

    if let nativePersistence = persistence as? SwiftNativePersistenceCore {
        return try await nativePersistence.withFileLock(keyPath, work)
    }
    return try await work()
}

/// SHA-256 hex of `s` (UTF-8 bytes), truncated to the first 32 chars —
/// matches `hashlib.sha256(self.pack_signing_key().encode()).hexdigest()[:32]`
/// at the retired daemon.
private func sha256HexPrefix32(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(32))
}

// MARK: - Actor: catalog sources

public actor SwiftNativeCatalogSources {
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date

    public init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.clock = clock
    }

    /// Pure, strict read of catalog sources. A missing store returns the
    /// bootstrap default in memory. An existing damaged store throws and its
    /// bytes remain untouched.
    public func catalogSources() async throws -> [[String: JSONValue]] {
        let sourcesPath = dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("sources", isDirectory: true)
            .appendingPathComponent("sources.json")
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        let saved = try CapabilityCatalogStoreReader.loadCatalogSourcesChecked(at: sourcesPath)
        return mergeRecords(
            defaults: defaultCatalogSources(dataRoot: dataRoot, nowISO: nowISO),
            saved: saved
        )
    }
}

// MARK: - Actor: capability trust roots

public actor SwiftNativeCapabilityTrustRoots {
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date

    public init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.clock = clock
    }

    /// Pure, strict read of capability trust roots. A missing store returns the
    /// local root in memory. Existing damaged state throws and is never healed
    /// into a different trust set by a read.
    public func capabilityTrustRoots() async throws -> [[String: JSONValue]] {
        let trustPath = dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("roots.json")
        // Validate authoritative root state before the bootstrap key is allowed
        // to mutate. A corrupt roots file must leave the entire catalog trust
        // surface untouched, even when the key is also missing.
        let saved = try CapabilityCatalogStoreReader.loadCapabilityTrustRootsChecked(at: trustPath)
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        let signingKey = try await resolvePackSigningKey(
            dataRoot: dataRoot, persistence: persistence
        )
        let fingerprint = sha256HexPrefix32(signingKey)
        let defaults: [[String: JSONValue]] = [[
            "id": .string("local-trusted"),
            "name": .string("NativeAgent Local Trusted Root"),
            "kind": .string("local"),
            "fingerprint": .string(fingerprint),
            "status": .string("trusted"),
            "createdAt": .string(nowISO),
        ]]
        return mergeRecords(defaults: defaults, saved: saved)
    }
}

// MARK: - Wave 31 W15: catalog write-side ports
//
// Ports the safe write/validate routes of /v1/capability-catalog that touch
// ONLY flock-coordinated state (catalog/sources/sources.json) or are pure
// functions (pack validate). The catalog REGISTRY (catalog/registry.json) and
// INSTALLS (catalog/installs.json) writes are deliberately NOT ported here:
// those files have separate ownership and coordination rules. Keep them out of
// this writer until the Swift registry/install stores own their full mutation
// contract.
//
// Routes ported here:
//   POST /v1/capability-catalog/pack/validate  (pure: HMAC + field + trust-root)
//   POST /v1/capability-catalog/sources         (upsert; flock'd sources.json)
//   POST /v1/capability-catalog/updates/check   (RMW lastCheckedAt; flock'd)
//   GET  /v1/capability-catalog/installs        (read-only installs.json)

// MARK: - Python-parity coercion helpers
//
// The daemon coerces JSON fields with `str(x)` and the `x or default` idiom,
// which (1) stringifies non-string scalars (123 -> "123", true -> "True") and
// (2) treats falsy values (None / "" / 0 / false / [] / {}) as the fallback.
// These helpers reproduce that exactly so the ports stay faithful when a pack
// or body carries a non-string field (gpt-5.5 review wave 31 W15, findings 2-5).

/// Python `str(value)` for a JSONValue scalar (the shapes that reach these
/// routes). Mirrors CPython: bool -> "True"/"False", int -> decimal,
/// float -> repr (1.0 -> "1.0"), string -> itself, null -> "None".
/// Containers are not expected here; they fall back to "" which matches the
/// daemon's `str(... or "")` outcome for the empty container case it cares about.
func pyStr(_ value: JSONValue?) -> String {
    switch value ?? .null {
    case .null: return "None"
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    case .double(let d):
        if d == d.rounded() && abs(d) < 1e16 { return String(format: "%.1f", d) }
        return String(d)
    case .string(let s): return s
    case .array, .object: return ""
    }
}

/// Retired truthiness of a JSONValue: none/""/0/0.0/false/[]/{} are falsy.
func pyTruthy(_ value: JSONValue?) -> Bool {
    switch value ?? .null {
    case .null: return false
    case .bool(let b): return b
    case .int(let i): return i != 0
    case .double(let d): return d != 0
    case .string(let s): return !s.isEmpty
    case .array(let a): return !a.isEmpty
    case .object(let o): return !o.isEmpty
    }
}

/// Python `str(a or b or ... or default)` chain: pick the first truthy value,
/// stringify it; if none truthy, stringify `default`.
func pyStrOr(_ values: [JSONValue?], default fallback: String) -> String {
    for v in values where pyTruthy(v) { return pyStr(v) }
    return fallback
}

/// Faithful port of `slugify()` at the retired daemon:
///   slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
///   return slug[:80] or str(uuid.uuid4())
/// Note: Python's regex operates on the LOWERCASED string, so any char that is
/// not ASCII [a-z0-9] (including ASCII uppercase already lowered, and ALL
/// non-ASCII) collapses to a single "-". We mirror byte-for-byte on the ASCII
/// happy path used by catalog ids; the uuid4 fallback for an all-separator
/// input is preserved.
public func swiftCatalogSlugify(_ value: String) -> String {
    let lowered = value.lowercased()
    var out = ""
    var pendingDash = false
    for scalar in lowered.unicodeScalars {
        let v = scalar.value
        let isLowerAlnum = (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) // a-z 0-9
        if isLowerAlnum {
            if pendingDash && !out.isEmpty { out += "-" }
            pendingDash = false
            out.unicodeScalars.append(scalar)
        } else {
            // any run of non-[a-z0-9] => single "-" (re.sub r"[^a-z0-9]+")
            pendingDash = true
        }
    }
    // .strip("-") removes leading/trailing dashes (we never emit a leading dash
    // because pendingDash is only flushed when out is non-empty; a trailing
    // pendingDash is simply never written). Then [:80].
    let trimmed = String(out.prefix(80))
    return trimmed.isEmpty ? UUID().uuidString.lowercased() : trimmed
}

/// Pure-function port of the capability-pack signature + validate logic from
/// the retired daemon (capability_pack_signature) and :6455
/// (validate_capability_pack). Signature is
/// HMAC-SHA256(packSigningKey.utf8, compactCanonicalJSON(pack without
/// "signature")). The validate path additionally consults the trusted-roots
/// set (the flock'd `SwiftNativeCapabilityTrustRoots` actor) for the
/// signing-identity check.
public struct SwiftNativeCapabilityPackSigner: Sendable {
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date

    public init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.clock = clock
    }

    /// Route-boundary unwrap shared by sign/validate/install. Mirrors the daemon
    /// idiom `pack = body.get("pack") if isinstance(body.get("pack"), dict) else body`
    ///. A future POST /pack/{sign,validate}
    /// port must call this before handing the pack to `sign`/`validate` so a
    /// `{"pack": {...}}` envelope and a bare pack both work. NOT baked into the
    /// pure functions to avoid double-unwrapping a real pack that legitimately
    /// carries a nested "pack" field.
    public static func unwrapPackBody(_ body: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let inner)? = body["pack"] { return inner }
        return body
    }

    /// HMAC-SHA256 hex of the canonical pack payload (with "signature" removed),
    /// keyed by the UTF-8 bytes of the pack signing key.
    /// Mirrors `capability_pack_signature()`.
    public func signature(for pack: [String: JSONValue]) async throws -> String {
        var payload = pack
        payload.removeValue(forKey: "signature")
        let canonical = try SwiftNativeManifestSigner.compactCanonicalJSON(.object(payload))
        let key = try await resolvePackSigningKey(dataRoot: dataRoot, persistence: persistence)
        let mac = HMAC<SHA256>.authenticationCode(
            for: canonical, using: SymmetricKey(data: Data(key.utf8))
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Port of `sign_capability_pack()`: set defaults
    /// for signedAt / signingIdentity, then attach signature.
    public func sign(_ pack: [String: JSONValue]) async throws -> [String: JSONValue] {
        var out = pack
        if out["signedAt"] == nil {
            out["signedAt"] = .string(SwiftNativeManifestSigner.isoTimestamp(clock()))
        }
        if out["signingIdentity"] == nil {
            out["signingIdentity"] = .string("local-trusted")
        }
        out["signature"] = .string(try await signature(for: out))
        return out
    }

    /// Port of `validate_capability_pack()`. Returns the
    /// validation report object byte-shape-identical to the Python route.
    public func validate(_ pack: [String: JSONValue]) async throws -> [String: JSONValue] {
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        var errors: [String] = []

        // required = ["id","name","version","items","signature"]
        let required = ["id", "name", "version", "items", "signature"]
        let missing = required.filter { pack[$0] == nil }
        if !missing.isEmpty {
            errors.append("Missing required field(s): \(missing.joined(separator: ", "))")
        }

        let expected = try await signature(for: pack)
        let actualSig: String? = {
            if case .string(let s)? = pack["signature"] { return s }
            return nil
        }()
        // Python compares pack.get("signature") != expected. A missing key is
        // None in Python, which != the hex string, so it's a mismatch.
        if actualSig != expected {
            errors.append("Signature mismatch.")
        }

        // items must be an object; items.{skills,workflows,catalog} must be lists.
        if case .object(let items)? = pack["items"] {
            for key in ["skills", "workflows", "catalog"] {
                if let v = items[key] {
                    if case .array = v {} else {
                        errors.append("items.\(key) must be a list.")
                    }
                }
            }
        } else {
            errors.append("items must be an object.")
        }

        var status = errors.isEmpty ? "valid" : "invalid"

        // trusted roots id set
        let rootsActor = SwiftNativeCapabilityTrustRoots(
            dataRoot: dataRoot, persistence: persistence, clock: clock
        )
        let roots = try await rootsActor.capabilityTrustRoots()
        // Python: root_ids = {str(item.get("id")) for item in roots} (:6475) —
        // stringifies non-string ids. Use pyStr for byte-faithful membership.
        var rootIDs: Set<String> = []
        for r in roots {
            rootIDs.insert(pyStr(r["id"]))
        }

        // signing_identity = str(pack.get("signingIdentity") or "") — non-string
        // scalars stringify, falsy -> "".
        let signingIdentity = pyStrOr([pack["signingIdentity"]], default: "")
        var trustTier = "local"
        if !signingIdentity.isEmpty
            && !rootIDs.contains(signingIdentity)
            && signingIdentity != "local-trusted" {
            trustTier = "unknown"
            errors.append("Signing identity is not in trusted roots.")
            status = "invalid"
        }

        // provenance = pack.get("provenance") or {"source": "local"} — falsy
        // (None / {} / []) falls back.
        let provenance: JSONValue = pyTruthy(pack["provenance"])
            ? (pack["provenance"] ?? .object(["source": .string("local")]))
            : .object(["source": .string("local")])

        return [
            // Python uses str(pack.get(k) or "") for id/name/version (:6483-6485).
            "id": .string(pyStrOr([pack["id"]], default: "")),
            "name": .string(pyStrOr([pack["name"]], default: "")),
            "version": .string(pyStrOr([pack["version"]], default: "")),
            "status": .string(status),
            "valid": .bool(errors.isEmpty),
            "errors": .array(errors.map { .string($0) }),
            "expectedSignature": .string(expected),
            // str(pack.get("signingIdentity") or "") or "local-trusted" (:6490).
            "signingIdentity": .string(signingIdentity.isEmpty ? "local-trusted" : signingIdentity),
            "trustTier": .string(trustTier),
            "provenance": provenance,
            "createdAt": .string(nowISO),
        ]
    }
}

/// Catalog-source UPSERT + updates-check + installs-read ports. Source
/// mutations use the canonical `catalog/sources/sources.json` flock, strictly
/// validate existing state, merge in memory, and commit exactly once. The
/// installs read remains lock-free.
public actor SwiftNativeCatalogWrites {
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date

    public init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.clock = clock
    }

    private var sourcesPath: URL {
        dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("sources", isDirectory: true)
            .appendingPathComponent("sources.json")
    }

    private var installsPath: URL {
        dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("installs.json")
    }

    private var packsPath: String {
        dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("packs", isDirectory: true)
            .path
    }

    /// Daemon's trace/activity ledger — `<dataRoot>/traces/events.jsonl`
    ///. Both the activity feed (/v1/activity) and the
    /// trace ledger (/v1/traces) read this file, so emitting the same envelope
    /// here keeps the audit feeds intact when the write flows through Swift.
    private var tracesPath: URL {
        dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func withSourcesLock<T: Sendable>(
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        if let p = persistence as? SwiftNativePersistenceCore {
            return try await p.withFileLock(sourcesPath, work)
        }
        return try await work()
    }

    /// Port of `upsert_catalog_source()`. Builds the
    /// record, then read-modify-writes the sources file under flock (replace any
    /// row with the same slugified id, append the new one).
    public func upsertCatalogSource(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        // All fields use the daemon's str(... or ...) idiom:
        // non-string scalars stringify, falsy values fall through to the next term.
        // name = str(body.get("name") or body.get("id") or "Capability Source")[:120]
        let name = String(
            pyStrOr([body["name"], body["id"]], default: "Capability Source").prefix(120)
        )
        // source_id = slugify(str(body.get("id") or name))
        let idSeed = pyTruthy(body["id"]) ? pyStr(body["id"]) : name
        let sourceID = swiftCatalogSlugify(idSeed)
        // url = str(body.get("url") or "")
        let url = pyStrOr([body["url"]], default: "")
        // kind = str(body.get("kind") or "local")
        let kind = pyStrOr([body["kind"]], default: "local")
        // trustedRootId = str(body.get("trustedRootId") or "local-trusted")
        let trustedRootId = pyStrOr([body["trustedRootId"]], default: "local-trusted")
        // createdAt = str(body.get("createdAt") or now_iso())
        let createdAt = pyTruthy(body["createdAt"])
            ? pyStr(body["createdAt"])
            : SwiftNativeManifestSigner.isoTimestamp(clock())
        let now = SwiftNativeManifestSigner.isoTimestamp(clock())

        let record: [String: JSONValue] = [
            "id": .string(sourceID),
            "name": .string(name),
            "kind": .string(kind),
            "url": .string(url),
            // "ready" if body.get("url") else "needs_setup" — raw truthiness of
            // the ORIGINAL body url, not the coerced string.
            "status": .string(pyTruthy(body["url"]) ? "ready" : "needs_setup"),
            "trustedRootId": .string(trustedRootId),
            "lastCheckedAt": .null,
            "createdAt": .string(createdAt),
            "updatedAt": .string(now),
        ]

        let sourcesPathLocal = sourcesPath
        let packsPathLocal = packsPath
        let persistenceLocal = persistence
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        try await withSourcesLock {
            // Strictly load + merge in memory, then commit the complete mutation
            // once. Existing damaged state throws before any write.
            let merged = try Self.mergedSourcesChecked(
                sourcesPath: sourcesPathLocal,
                packsPath: packsPathLocal,
                nowISO: nowISO
            )
            var sources = merged.filter { row in
                if case .string(let id)? = row["id"] { return id != sourceID }
                return true
            }
            sources.append(record)
            try await persistenceLocal.writeJSON(.array(sources.map { .object($0) }), to: sourcesPathLocal)
        }
        // Audit-trace parity: the daemon emits
        // record_trace("catalog.source.save", name, {"sourceId", "status"})
        // AFTER the write. Wave 31 W15 was reverted
        // because this side-effect was omitted; port it so the activity feed
        // (/v1/activity) and trace ledger (/v1/traces) stay identical whether
        // the upsert flows through Python or Swift.
        //
        // Wave 33 W01 (closes §6.95 #1): the trace append MUST propagate its
        // error, not swallow it. Python's `record_trace` calls the UNWRAPPED
        // `append_jsonl`, so a mkdir/open/write
        // failure raises straight out of `upsert_catalog_source` and the HTTP
        // route returns a 500 — even though the source record is already on
        // disk. Wave 32 W02 swallowed it Swift-side, a strict parity gap. Match
        // the daemon (and DispatchLedger.append / Research.appendResearchTrace,
        // which both already propagate) by letting the `try` surface here.
        try await emitCatalogTrace(
            kind: "catalog.source.save",
            title: name,
            payload: [
                "sourceId": .string(sourceID),
                "status": record["status"] ?? .string(""),
            ]
        )
        return record
    }

    /// Port of `check_capability_updates()`. Reads the
    /// installs list (lock-free), builds a "current" update row per install,
    /// then stamps lastCheckedAt on every source under the sources flock.
    public func checkCapabilityUpdates() async throws -> [String: JSONValue] {
        let installs = try await listCapabilityPackInstalls()
        var updates: [JSONValue] = []
        for install in installs {
            let packId = install["packId"] ?? .null
            let version = install["version"] ?? .null
            // f"update:{install.get('packId')}" — missing -> "update:None",
            // numeric -> "update:123", string -> raw.
            updates.append(.object([
                "id": .string("update:\(pyStr(install["packId"]))"),
                "packId": packId,
                "installedVersion": version,
                "availableVersion": version,
                "status": .string("current"),
                "sourceId": .string("local-catalog"),
            ]))
        }

        let sourcesPathLocal = sourcesPath
        let packsPathLocal = packsPath
        let persistenceLocal = persistence
        let now = SwiftNativeManifestSigner.isoTimestamp(clock())
        let sourceCount: Int = try await withSourcesLock {
            var merged = try Self.mergedSourcesChecked(
                sourcesPath: sourcesPathLocal,
                packsPath: packsPathLocal,
                nowISO: now
            )
            for i in merged.indices {
                merged[i]["lastCheckedAt"] = .string(now)
            }
            try await persistenceLocal.writeJSON(.array(merged.map { .object($0) }), to: sourcesPathLocal)
            return merged.count
        }

        return [
            "status": .string("checked"),
            "updates": .array(updates),
            "sourceCount": .int(Int64(sourceCount)),
            "createdAt": .string(now),
        ]
    }

    /// Port of `list_capability_pack_installs()`.
    /// Lock-free read; sorts by installedAt||createdAt descending (string sort,
    /// matching Python's `str(...)` key with reverse=True).
    public func listCapabilityPackInstalls() async throws -> [[String: JSONValue]] {
        let raw = await persistence.readJSON(installsPath, defaultValue: .array([]))
        guard case .array(let items) = raw else { return [] }
        let rows: [[String: JSONValue]] = items.compactMap {
            if case .object(let o) = $0 { return o }
            return nil
        }
        // str(item.get("installedAt") or item.get("createdAt") or "") —
        // non-string scalars stringify; falsy falls through.
        func sortKey(_ row: [String: JSONValue]) -> String {
            pyStrOr([row["installedAt"], row["createdAt"]], default: "")
        }
        // Python's sorted(..., reverse=True) is a STABLE sort. Swift's sort is
        // NOT guaranteed stable, so emulate Python's stable-reverse by sorting
        // on (key descending, original-index ascending) to keep equal-key order.
        let indexed = rows.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let lk = sortKey(lhs.1), rk = sortKey(rhs.1)
            if lk != rk { return lk > rk }
            return lhs.0 < rhs.0
        }
        return sorted.map { $0.1 }
    }

    /// Strict, pure source merge usable from inside the @Sendable flock closure.
    /// Missing state receives the in-memory bootstrap default; existing damaged
    /// state throws before the caller's single commit.
    private static func mergedSourcesChecked(
        sourcesPath: URL,
        packsPath: String,
        nowISO: String
    ) throws -> [[String: JSONValue]] {
        let saved = try CapabilityCatalogStoreReader.loadCatalogSourcesChecked(at: sourcesPath)

        let defaults: [[String: JSONValue]] = [[
            "id": .string("local-catalog"),
            "name": .string("Local NativeAgent Catalog"),
            "kind": .string("local"),
            "url": .string(packsPath),
            "status": .string("ready"),
            "trustedRootId": .string("local-trusted"),
            "lastCheckedAt": .null,
            "createdAt": .string(nowISO),
        ]]

        return mergeRecords(defaults: defaults, saved: saved)
    }

    /// Append a trace event to `<dataRoot>/traces/events.jsonl` in the daemon's
    /// `record_trace` envelope shape (`{id, kind, title, status, payload,
    /// createdAt}`, the retired daemon). The envelope-level `status` mirrors
    /// the daemon, which pulls `status` out of the payload defaulting to "ok"
    /// (`str(_payload.get("status") or "ok")`, the retired daemon); for
    /// catalog.source.save that resolves to the record's "ready"|"needs_setup".
    /// `_normalize_trace_error` only mutates the payload when an `error` key is
    /// present, which catalog.source.save never carries, so the payload passes
    /// through verbatim.
    ///
    /// Wave 33 W01 (closes §6.95 #1+#2):
    /// - ERROR PROPAGATION: this `async throws` and lets the append error
    ///   surface. The daemon's `record_trace` calls the UNWRAPPED `append_jsonl`
    ///, so a trace-write failure raises out of
    ///   `upsert_catalog_source`; matching that means the Swift port must NOT
    ///   swallow. Same convention as DispatchLedger.append /
    ///   Research.appendResearchTrace, which already propagate.
    /// - CROSS-PROCESS FLOCK: the `withFileLock` around the append is now
    ///   SYMMETRIC with the daemon. Wave 33 W01 made Python's `record_trace`
    ///   and the periodic/startup traces prune acquire `file_lock(traces_path)`
    ///, which rendezvous on the same `<path>.lock` advisory
    ///   lock (Python `str(path)+".lock"` == Swift `targetPath.path+".lock"`).
    ///   The lock is required, not a cosmetic precaution: `traces/events.jsonl`
    ///   is co-written by Python (`record_trace` + the read-modify-replace
    ///   prune) and >=4 Swift emitters during the cutover, and trace payloads
    ///   can exceed PIPE_BUF so O_APPEND atomicity alone does not prevent torn
    ///   lines, nor does it protect the non-atomic prune `os.replace` against
    ///   in-flight appenders. See docs/CUTOVER_PLAN.md §6.96.
    private func emitCatalogTrace(
        kind: String,
        title: String,
        payload: [String: JSONValue]
    ) async throws {
        var statusStr = "ok"
        if case .string(let s)? = payload["status"], !s.isEmpty { statusStr = s }
        let event: JSONValue = .object([
            // Lowercased to match Python's str(uuid.uuid4()) (the retired daemon
            // record_trace) — Darwin's UUID().uuidString is UPPERCASE, which
            // would drift the trace-envelope `id` case from the daemon's. This
            // is the repo convention for Python-parity ids (see slugify fallback
            // at line 390, etc.).
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string(kind),
            "title": .string(title),
            "status": .string(statusStr),
            "payload": .object(payload),
            "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(clock())),
        ])
        let tracesURL = tracesPath
        let persistenceLocal = persistence
        let work: @Sendable () async throws -> Void = {
            try await persistenceLocal.appendJSONL(event, to: tracesURL)
        }
        if let p = persistence as? SwiftNativePersistenceCore {
            try await p.withFileLock(tracesURL, work)
        } else {
            try await work()
        }
    }
}
