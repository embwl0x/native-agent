import Foundation
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import WorkflowOrchestration
// Blueprint: | `CapabilityCatalog.swift` | Capability sources, trust roots and pack installation receipts; catalog registry aggregation and mutation share `CapabilityCatalogStoreReader`'s checked object-array schema; workflow mutations delegate to WorkflowOrchestration. Installed items and receipts are authoritative, with no saved pack copy or `packPath`. Retained `catalog/packs` files are untouched orphans, excluded from local backup, export and phone sync; PrivacyMap lists their catalog folder. |

// MARK: - Capability catalog persistence
//
// Sources and trust roots are checked operator authority. Reads never rewrite
// lists; missing lists receive in-memory defaults. Trust-root resolution may
// create the missing signing key after validating the list.
// Local backup includes sources, roots, registry and install receipts; export
// selects sources, roots and registry only. The 64-hex-character, 0600
// .pack_signing_key is deliberately excluded from local backup, export and
// phone sync. No catalog file syncs to the phone. PrivacyMap lists Catalog
// (hidden key bytes are omitted from its directory size tally).
// Saved fields override defaults by ID; unmatched saved records append.

// MARK: - File-private helpers

public enum CapabilityCatalogPersistenceError: Error, LocalizedError {
    case unreadable(path: String, detail: String)
    case malformed(path: String, detail: String)
    case signingKeyUnavailable(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let detail):
            return "capability_catalog_unreadable: Cannot read \(path): \(detail). Repair access to this file; preserve its bytes and saved authority."
        case .malformed(let path, let detail):
            return "capability_catalog_malformed: Invalid records in \(path): \(detail). Repair this file from its retained bytes, preserving every record and authority choice; never reset it to an empty catalog."
        case .signingKeyUnavailable(let path, let detail):
            return "capability_signing_key_unavailable: Cannot use \(path): \(detail). Ask the owner to repair or restore the original 64-hex-character key as a regular 0600 file at this path; never replace an existing signing identity."
        }
    }

    fileprivate var failure: ToolFailureError {
        switch self {
        case .unreadable(let path, let detail):
            let file = URL(fileURLWithPath: path)
            return ToolFailureError("Capability catalog cannot be read at \(path): \(detail)",
                effects: .none, owner: path,
                tap: "Finder > Go > Go to Folder > \(file.deletingLastPathComponent().path) > \(file.lastPathComponent) > Get Info > Sharing & Permissions",
                code: "capability_catalog_unreadable",
                instruction: "Ask the owner to repair access to this file, preserving its original bytes and saved authority.")
        case .malformed(let path, let detail):
            let file = URL(fileURLWithPath: path)
            return ToolFailureError("Capability catalog has invalid records at \(path): \(detail)",
                effects: .none, owner: path,
                code: "capability_catalog_malformed",
                instruction: ToolFailureError.fileRepairInstruction(file,
                    shape: "This catalog authority store must be a JSON array of records with unique nonblank string IDs. Preserve every record, field, trust root, source and authority choice. Recover required fields only from these retained bytes; never invent IDs, packIds, status or authority, or reset the catalog.") + " Repair only the named catalog file from its retained bytes, preserving saved authority.")
        case .signingKeyUnavailable(let path, let detail):
            return ToolFailureError("Capability signing key at \(path) is unavailable: \(detail)",
                effects: .unknown, owner: path,
                tap: "Finder > Go > Go to Folder > \(URL(fileURLWithPath: path).deletingLastPathComponent().path) > .pack_signing_key > Get Info",
                code: "capability_signing_key_unavailable",
                instruction: "Ask the owner to repair or restore the original 64-hex-character key as a regular 0600 file; never replace an existing signing identity.")
        }
    }
}

private func loadObjectRowsChecked(
    at path: URL,
    recordKind: String
) throws -> [[String: JSONValue]] {
    var metadata = stat()
    if lstat(path.path, &metadata) != 0 {
        guard errno == ENOENT else {
            throw CapabilityCatalogPersistenceError.unreadable(
                path: path.path, detail: "store cannot be inspected"
            ).failure
        }
        return []
    }

    let data: Data
    do {
        let fd = Darwin.open(path.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EIO)
        }
        data = try handle.readToEnd() ?? Data()
    } catch {
        throw CapabilityCatalogPersistenceError.unreadable(
            path: path.path,
            detail: error.localizedDescription
        ).failure
    }

    let raw: JSONValue
    do {
        raw = try JSONValue.parse(data)
    } catch {
        throw CapabilityCatalogPersistenceError.malformed(
            path: path.path,
            detail: "invalid JSON: \(error.localizedDescription)"
        ).failure
    }
    guard case .array(let items) = raw else {
        throw CapabilityCatalogPersistenceError.malformed(
            path: path.path,
            detail: "expected a JSON array of \(recordKind) records"
        ).failure
    }

    var rows: [[String: JSONValue]] = []
    rows.reserveCapacity(items.count)
    var seenIDs: Set<String> = []
    for (index, item) in items.enumerated() {
        guard case .object(let row) = item else {
            throw CapabilityCatalogPersistenceError.malformed(
                path: path.path,
                detail: "\(recordKind) row \(index) is not a JSON object"
            ).failure
        }
        guard case .string(let id)? = row["id"],
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CapabilityCatalogPersistenceError.malformed(
                path: path.path,
                detail: "\(recordKind) row \(index) has no non-empty string id"
            ).failure
        }
        guard seenIDs.insert(id).inserted else {
            throw CapabilityCatalogPersistenceError.malformed(
                path: path.path,
                detail: "\(recordKind) row \(index) duplicates id \(id)"
            ).failure
        }
        rows.append(row)
    }
    return rows
}

/// Reusable strict boundary for capability authority files. Backup/restore and
/// other ingress paths should call these methods before installing bytes so the
/// same missing-vs-damaged contract governs live reads and restore preflight.
public enum CapabilityCatalogStoreReader {
    /// The catalog registry's one object-array schema, shared by mutation and
    /// read-only aggregation. Existing damaged rows never become defaults.
    package static func loadRegistryChecked(_ path: URL, persistence: any PersistenceCoreProtocol) async throws -> [[String: JSONValue]] {
        let raw = try await persistence.readJSON(path, ifMissing: .array([]))
        guard case .array(let rows) = raw else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack registry must be an array: \(path.path)"
            ])
        }
        var seenIDs: Set<String> = []
        return try rows.map {
            guard case .object(let obj) = $0, case .string(let id)? = obj["id"],
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenIDs.insert(id).inserted else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack registry contains an invalid entry: \(path.path)"
                ])
            }
            return obj
        }
    }

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

    /// Reads the capability-pack install receipt authority.  A missing receipt
    /// file is the legitimate no-installs bootstrap state; an existing file
    /// must contain complete, uniquely-addressable receipts.  In particular,
    /// do not turn a damaged receipt store into an empty catalog, because that
    /// would make installed capabilities look safely absent and enable a
    /// misleading reinstall/rollback decision.
    public static func loadCapabilityPackInstallsChecked(
        at path: URL
    ) throws -> [[String: JSONValue]] {
        let rows = try loadObjectRowsChecked(at: path, recordKind: "capability pack install")
        for (index, row) in rows.enumerated() {
            guard case .string(let packID)? = row["packId"],
                  !packID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CapabilityCatalogPersistenceError.malformed(
                    path: path.path,
                    detail: "capability pack install row \(index) has no non-empty string packId"
                ).failure
            }
            guard case .string(let status)? = row["status"],
                  !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CapabilityCatalogPersistenceError.malformed(
                    path: path.path,
                    detail: "capability pack install row \(index) has no non-empty string status"
                ).failure
            }
        }
        return rows
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

private func validatedPackSigningKey(_ data: Data, at keyPath: URL) throws -> String {
    guard let secret = String(data: data, encoding: .utf8),
          secret.unicodeScalars.allSatisfy({ scalar in
              switch scalar.value {
              case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
              default: return false
              }
          }) else {
        throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
            path: keyPath.path,
            detail: "existing key must contain exactly 64 hexadecimal characters"
        ).failure
    }
    return secret
}

private func checkedExistingPackSigningKey(at keyPath: URL) throws -> String? {
    guard let data = try CheckedFixedSizeSecretFile.peekExisting(at: keyPath, byteCount: 64) else { return nil }
    return try validatedPackSigningKey(data, at: keyPath)
}

/// Only genuine absence may create a signing identity. Existing damaged keys
/// remain untouched and unavailable.
private func resolvePackSigningKey(dataRoot: URL) throws -> String {
    let keyPath = dataRoot.appendingPathComponent("catalog/.pack_signing_key")
    let data: Data
    do {
        data = try CheckedFixedSizeSecretFile.loadOrCreate(at: keyPath, byteCount: 64) {
            let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return Data(secret.utf8)
        }
    } catch {
        throw CapabilityCatalogPersistenceError.signingKeyUnavailable(
            path: keyPath.path, detail: error.localizedDescription
        ).failure
    }
    return try validatedPackSigningKey(data, at: keyPath)
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

    /// Strict root-list read; never rewrites it. After validation, resolving
    /// the local root creates its signing key if missing.
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
        let signingKey = try resolvePackSigningKey(dataRoot: dataRoot)
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

    /// HMAC-SHA256 hex of the canonical pack payload (with "signature" removed),
    /// keyed by the UTF-8 bytes of the pack signing key.
    /// Mirrors `capability_pack_signature()`.
    public func signature(for pack: [String: JSONValue]) async throws -> String {
        let key = try resolvePackSigningKey(dataRoot: dataRoot)
        return try Self.signature(for: pack, signingKey: key)
    }

    private static func signature(
        for pack: [String: JSONValue],
        signingKey: String
    ) throws -> String {
        var payload = pack
        payload.removeValue(forKey: "signature")
        let canonical = try SwiftNativeManifestSigner.compactCanonicalJSON(.object(payload))
        let mac = HMAC<SHA256>.authenticationCode(
            for: canonical, using: SymmetricKey(data: Data(signingKey.utf8))
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

    /// Read-only install preflight. It preserves the validation report shape,
    /// but never bootstraps a signing key or trust root merely to inspect an
    /// untrusted pack.
    public func validate(_ pack: [String: JSONValue]) async throws -> [String: JSONValue] {
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        var errors: [String] = []

        // required = ["id","name","version","items","signature"]
        let required = ["id", "name", "version", "items", "signature"]
        let missing = required.filter { pack[$0] == nil }
        if !missing.isEmpty {
            errors.append("Missing required field(s): \(missing.joined(separator: ", "))")
        }

        let keyPath = dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent(".pack_signing_key")
        let expected: String
        do {
            if let signingKey = try checkedExistingPackSigningKey(at: keyPath) {
                expected = try Self.signature(for: pack, signingKey: signingKey)
            } else {
                errors.append("Capability pack signing key is unavailable; an invalid pack cannot initialize signing state.")
                expected = ""
            }
        } catch {
            errors.append(error.localizedDescription)
            expected = ""
        }
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

        // Trust-root validation is read-only for the same reason as key
        // validation above. Missing roots do not need a persisted bootstrap
        // record for the built-in local identity, while damaged roots still
        // fail closed and leave their bytes untouched.
        let trustPath = dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("roots.json")
        let roots = try CapabilityCatalogStoreReader.loadCapabilityTrustRootsChecked(at: trustPath)
        let signingIdentity = pyStrOr([pack["signingIdentity"]], default: "local-trusted")
        // The bootstrap root is deliberately machine-local: it is keyed by
        // the same local signing secret used to create demo packs.  It proves
        // integrity against that local key, not third-party attestation.
        var trustTier = signingIdentity == "local-trusted" ? "self_issued" : "local"
        let savedRoot = roots.first { $0["id"] == .string(signingIdentity) }
        let rootTrusted = savedRoot.map { $0["status"] == .string("trusted") }
            ?? (signingIdentity == "local-trusted")
        if !rootTrusted {
            trustTier = "unknown"
            errors.append("Signing identity is not trusted.")
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
            "signingIdentity": .string(signingIdentity),
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

    /// Shared diagnostic ledger; appends belong to appendPathOwnedJSONL.
    private var tracesPath: URL {
        dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func withSourcesLock<T: Sendable>(
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        return try await persistence.withFileLock(sourcesPath, work)
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
        let dataRootLocal = dataRoot
        let persistenceLocal = persistence
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        try await withSourcesLock {
            // Strictly load + merge in memory, then commit the complete mutation
            // once. Existing damaged state throws before any write.
            let merged = try Self.mergedSourcesChecked(
                sourcesPath: sourcesPathLocal,
                dataRoot: dataRootLocal,
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

    /// No source-version comparison is implemented, so no source was checked.
    public func checkCapabilityUpdates() async throws -> [String: JSONValue] {
        return [
            "status": .string("unavailable"),
            "reason": .string("Update checking is unavailable because source versions are not compared."),
            "updates": .array([]),
            "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(clock())),
        ]
    }

    /// Port of `list_capability_pack_installs()`.
    /// Lock-free read; sorts by installedAt||createdAt descending (string sort,
    /// matching Python's `str(...)` key with reverse=True).
    public func listCapabilityPackInstalls() async throws -> [[String: JSONValue]] {
        let rows = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(
            at: installsPath
        )
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
        dataRoot: URL,
        nowISO: String
    ) throws -> [[String: JSONValue]] {
        let saved = try CapabilityCatalogStoreReader.loadCatalogSourcesChecked(at: sourcesPath)

        return mergeRecords(defaults: defaultCatalogSources(dataRoot: dataRoot, nowISO: nowISO), saved: saved)
    }

    /// Append the shared {id, kind, title, status, payload, createdAt} envelope.
    /// The path-owned persistence writer holds its lock through append/retention;
    /// no retired daemon writes this feed. Catalog payloads pass through verbatim
    /// and their nonempty status becomes the envelope status (otherwise "ok").
    /// Append failures propagate to the catalog mutation's caller.
    private func emitCatalogTrace(
        kind: String,
        title: String,
        payload: [String: JSONValue]
    ) async throws {
        var statusStr = "ok"
        if case .string(let s)? = payload["status"], !s.isEmpty { statusStr = s }
        let event: JSONValue = .object([
            // Preserve the stored envelope's lowercase UUID convention.
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string(kind),
            "title": .string(title),
            "status": .string(statusStr),
            "payload": .object(payload),
            "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(clock())),
        ])
        let tracesURL = tracesPath
        try await appendPathOwnedJSONL(
            event,
            to: tracesURL,
            using: persistence,
            logLabel: "CapabilityCatalog.trace"
        )
    }
}
extension CapabilityPackInstall {
    /// The local signed demo pack: signed by the canonical signer, then
    /// installed through the same validated boundary as an acquired pack.
    public static func installDemo(dataRoot root: URL) async throws -> CapabilityPackInstall {
        let persistence = SwiftNativePersistenceCore()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let signer = SwiftNativeCapabilityPackSigner(dataRoot: root, persistence: persistence)
        let signed = try await signer.sign(demoCapabilityPack(nowISO: nowISO))
        let receipt = try await installCapabilityPack(signed, root: root, persistence: persistence, nowISO: nowISO)
        let data = try JSONValue.object(receipt).serializedData(pretty: false)
        let installed = try JSONDecoder().decode(CapabilityPackInstall.self, from: data)
        let signature = installed.signature?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard installed.status == "installed", !signature.isEmpty else {
            throw NSError(domain: "NativeAgent.CapabilityPack", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack did not return a verified installed receipt."
            ])
        }
        return installed
    }

    public static func rollback(id: String, dataRoot root: URL) async throws -> CapabilityPackInstall {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "rollbackCapabilityPack: empty install id"
            ])
        }
        let persistence = SwiftNativePersistenceCore()
        let rolledBack = try await rollbackCapabilityPackInstall(id: trimmed, root: root, persistence: persistence)
        let data = try JSONValue.object(rolledBack).serializedData(pretty: false)
        return try JSONDecoder().decode(CapabilityPackInstall.self, from: data)
    }

    private static func demoCapabilityPack(nowISO: String) -> [String: JSONValue] {
        let packID = "nativeagent-demo-operator-pack"
        let workflowID = "demo-pack-memory-capture"
        let skillID = "demo-capability-pack"
        let catalogID = "catalog:\(packID)"
        return [
            "id": .string(packID),
            "name": .string("NativeAgent Demo Operator Pack"),
            "version": .string("1.0.0"),
            "description": .string("Local signed demo pack proving Swift-native capability install and rollback."),
            "provenance": .object([
                "source": .string("nativeagent-local-demo"),
                "createdAt": .string(nowISO),
            ]),
            "items": .object([
                "catalog": .array([
                    .object([
                        "id": .string(catalogID),
                        "name": .string("NativeAgent Demo Operator Pack"),
                        "kind": .string("capability_pack"),
                        "status": .string("installed"),
                        "description": .string("Signed local demo pack installed by the Swift capability-pack path."),
                        "riskClass": .string("low"),
                        "autoload": .bool(false),
                    ]),
                ]),
                "workflows": .array([
                    .object([
                        "id": .string(workflowID),
                        "name": .string("Demo Pack Memory Capture"),
                        "description": .string("Route an objective, write a memory-shaped note, and record a trace receipt."),
                        "status": .string("active"),
                        "trigger": .string("demo pack memory"),
                        "steps": .array([
                            .object([
                                "id": .string("route"),
                                "title": .string("Route objective"),
                                "kind": .string("router"),
                                "requiresApproval": .bool(false),
                            ]),
                            .object([
                                "id": .string("trace"),
                                "title": .string("Record trace receipt"),
                                "kind": .string("trace"),
                                "requiresApproval": .bool(false),
                            ]),
                        ]),
                    ]),
                ]),
                "skills": .array([
                    .object([
                        "id": .string(skillID),
                        "name": .string("Demo Capability Pack"),
                        "description": .string("Procedure installed by the Swift signed capability-pack demo."),
                        "triggers": .array([.string("demo capability pack"), .string("signed pack")]),
                        "script": .object([
                            "entry": .string("run"),
                            "source": .string("function run(input) { return \"# Demo Capability Pack\\n\\nUse this to confirm signed capability packs install and roll back through Swift-owned registries.\\n\"; }"),
                            "actions": .array([]),
                        ]),
                    ]),
                ]),
            ]),
        ]
    }

    private static func installCapabilityPack(
        _ pack: [String: JSONValue],
        root: URL,
        persistence: SwiftNativePersistenceCore,
        nowISO: String
    ) async throws -> [String: JSONValue] {
        // Keep admission and replacement in the same registry lock epoch.
        try await persistence.withFileLock(capabilityPackInstallsPath(root: root)) {
            try await persistence.withFileLock(root.appendingPathComponent("catalog/registry.json")) {
                try await persistence.withFileLock(root.appendingPathComponent("workflows/registry.json")) {
                    try await installCapabilityPackLocked(pack, root: root, persistence: persistence, nowISO: nowISO)
                }
            }
        }
    }

    private static func installCapabilityPackLocked(
        _ pack: [String: JSONValue],
        root: URL,
        persistence: SwiftNativePersistenceCore,
        nowISO: String
    ) async throws -> [String: JSONValue] {
        let signer = SwiftNativeCapabilityPackSigner(dataRoot: root, persistence: persistence)
        let validation = try await signer.validate(pack)
        guard case .bool(true)? = validation["valid"] else {
            let errors: String = {
                if case .array(let rows)? = validation["errors"] {
                    let messages = rows.compactMap { value -> String? in
                        if case .string(let message) = value { return message }
                        return nil
                    }
                    if !messages.isEmpty { return messages.joined(separator: "; ") }
                }
                return "unknown validation failure"
            }()
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack validation failed: \(errors)"
            ])
        }

        let packID = jsonString(pack, "id")
        guard !packID.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack missing id."
            ])
        }
        let installID = "install:\(packID)"
        let packName = jsonString(pack, "name")
        let version = jsonString(pack, "version")
        let signature = jsonString(pack, "signature")
        let itemIDs = capabilityPackItemIDs(pack)
        let skillItems = capabilityPackObjects(pack, category: "skills")
        let installs = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(at: capabilityPackInstallsPath(root: root))
        let previousItemIDs = try installs.first(where: { jsonString($0, "id") == installID })
            .map { try installedItemIDs(from: $0) }
        try await preflightPackItems(capabilityPackObjects(pack, category: "catalog"),
            path: root.appendingPathComponent("catalog/registry.json"), installID: installID, persistence: persistence)
        try SwiftNativeWorkflowOrchestrationClient(root: root, persistence: persistence)
            .preflightPackItems(capabilityPackObjects(pack, category: "workflows"), installID: installID)
        try CapabilityPackParts.preflight(skillItems, installID: installID, dataRoot: root)
        try await installCatalogItems(
            capabilityPackObjects(pack, category: "catalog"),
            root: root,
            persistence: persistence,
            installID: installID,
            packID: packID,
            nowISO: nowISO
        )
        try await SwiftNativeWorkflowOrchestrationClient(root: root, persistence: persistence).installPackItems(
            capabilityPackObjects(pack, category: "workflows"),
            installID: installID,
            packID: packID,
            nowISO: nowISO
        )
        try await CapabilityPackParts.install(skillItems, installID: installID, pack: packID, dataRoot: root)
        if let previousItemIDs {
            let omittedCatalog = previousItemIDs.catalog.filter { !itemIDs.catalog.contains($0) }
            let omittedWorkflows = previousItemIDs.workflows.filter { !itemIDs.workflows.contains($0) }
            let skillIDs = Set(itemIDs.skills.map { $0.lowercased() })
            let omittedSkills = previousItemIDs.skills.filter { !skillIDs.contains($0.lowercased()) }
            // Empty removal lists mean all owned items, so only pass omissions.
            if !omittedCatalog.isEmpty {
                try await removePackCatalogItems(omittedCatalog, installID: installID, packID: packID, root: root, persistence: persistence)
            }
            if !omittedWorkflows.isEmpty {
                try await SwiftNativeWorkflowOrchestrationClient(root: root, persistence: persistence)
                    .removePackItems(omittedWorkflows, installID: installID, packID: packID)
            }
            if !omittedSkills.isEmpty {
                try CapabilityPackParts.remove(omittedSkills, installID: installID, dataRoot: root)
            }
        }
        // Receipts and installed items own the installation. No saved pack copy:
        // retained catalog/packs files stay untouched, outside local backup,
        // export and phone sync; PrivacyMap's catalog category lists the folder.
        let receipt: [String: JSONValue] = [
            "id": .string(installID),
            "packId": .string(packID),
            "name": .string(packName.isEmpty ? packID : packName),
            "version": .string(version),
            "status": .string("installed"),
            "signature": signature.isEmpty ? .null : .string(signature),
            "installedAt": .string(nowISO),
            "rolledBackAt": .null,
            "itemIds": .object([
                "catalog": .array(itemIDs.catalog.map { .string($0) }),
                "workflows": .array(itemIDs.workflows.map { .string($0) }),
                "skills": .array(itemIDs.skills.map { .string($0) }),
            ]),
        ]
        try await upsertCapabilityPackInstallReceipt(receipt, root: root, persistence: persistence)
        try await appendCapabilityPackTrace(
            kind: "capability.pack.install",
            title: packName.isEmpty ? packID : packName,
            payload: [
                "installId": .string(installID),
                "packId": .string(packID),
                "status": .string("installed"),
            ],
            root: root,
            persistence: persistence
        )
        return receipt
    }

    private static func rollbackCapabilityPackInstall(
        id: String,
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws -> [String: JSONValue] {
        let installsPath = capabilityPackInstallsPath(root: root)
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let target = try await persistence.withFileLock(installsPath) {
            var rows = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(at: installsPath)
            guard let idx = rows.firstIndex(where: { jsonString($0, "id") == id }) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack install '\(id)' not found."
                ])
            }
            var row = rows[idx]
            let packID = jsonString(row, "packId")
            let itemIDs = try installedItemIDs(from: row)
            try await removePackCatalogItems(itemIDs.catalog, installID: id, packID: packID, root: root, persistence: persistence)
            try await SwiftNativeWorkflowOrchestrationClient(root: root, persistence: persistence)
                .removePackItems(itemIDs.workflows, installID: id, packID: packID)
            try CapabilityPackParts.remove(itemIDs.skills, installID: id, dataRoot: root)
            row["status"] = .string("rolled_back")
            row["rolledBackAt"] = .string(nowISO)
            rows[idx] = row
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: installsPath)
            return row
        }
        let packID = jsonString(target, "packId")
        try await appendCapabilityPackTrace(
            kind: "capability.pack.rollback",
            title: jsonString(target, "name").isEmpty ? packID : jsonString(target, "name"),
            payload: [
                "installId": .string(id),
                "packId": .string(packID),
                "status": .string("rolled_back"),
            ],
            root: root,
            persistence: persistence
        )
        return target
    }

    private static func capabilityPackObjects(_ pack: [String: JSONValue], category: String) -> [[String: JSONValue]] {
        guard case .object(let items)? = pack["items"],
              case .array(let values)? = items[category] else { return [] }
        return values.compactMap {
            if case .object(let obj) = $0 { return obj }
            return nil
        }
    }

    private static func capabilityPackItemIDs(_ pack: [String: JSONValue]) -> (catalog: [String], workflows: [String], skills: [String]) {
        (
            catalog: capabilityPackObjects(pack, category: "catalog").map { jsonString($0, "id") }.filter { !$0.isEmpty },
            workflows: capabilityPackObjects(pack, category: "workflows").map { jsonString($0, "id") }.filter { !$0.isEmpty },
            skills: capabilityPackObjects(pack, category: "skills").map(CapabilityPackParts.id).filter { !$0.isEmpty }
        )
    }

    private static func installedItemIDs(from receipt: [String: JSONValue]) throws -> (catalog: [String], workflows: [String], skills: [String]) {
        guard case .string(let packID)? = receipt["packId"], !packID.isEmpty,
              case .object(let itemIds)? = receipt["itemIds"] else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack install receipt is invalid."
            ])
        }
        func strings(_ key: String) throws -> [String] {
            guard case .array(let values)? = itemIds[key] else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack install receipt has invalid \(key) IDs."
                ])
            }
            return try values.map {
                guard case .string(let s) = $0, !s.isEmpty else {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                        NSLocalizedDescriptionKey: "Capability pack install receipt has invalid \(key) IDs."
                    ])
                }
                return s
            }
        }
        return try (strings("catalog"), strings("workflows"), strings("skills"))
    }

    private static func preflightPackItems(
        _ items: [[String: JSONValue]], path: URL, installID: String, persistence: SwiftNativePersistenceCore
    ) async throws {
        let rows = try await CapabilityCatalogStoreReader.loadRegistryChecked(path, persistence: persistence)
        let ids = Set(items.map { jsonString($0, "id") })
        guard items.allSatisfy({
                  if case .string(let id)? = $0["id"] {
                      return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }
                  return false
              }), ids.count == items.count,
              !rows.contains(where: {
                  ids.contains(jsonString($0, "id")) && jsonString($0, "capabilityPackInstallId") != installID
              }) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack items collide with existing entries or have invalid IDs in \(path.lastPathComponent)."
            ])
        }
    }

    private static func installCatalogItems(
        _ items: [[String: JSONValue]],
        root: URL,
        persistence: SwiftNativePersistenceCore,
        installID: String,
        packID: String,
        nowISO: String
    ) async throws {
        guard !items.isEmpty else { return }
        let path = root.appendingPathComponent("catalog/registry.json")
        try await persistence.withFileLock(path) {
            var rows = try await CapabilityCatalogStoreReader.loadRegistryChecked(path, persistence: persistence)
            let ids = Set(items.map { jsonString($0, "id") }.filter { !$0.isEmpty })
            rows.removeAll { ids.contains(jsonString($0, "id")) }
            for item in items {
                var row = item
                row["status"] = .string(jsonString(row, "status").isEmpty ? "installed" : jsonString(row, "status"))
                row["installed"] = .bool(true)
                row["installedAt"] = .string(nowISO)
                row["updatedAt"] = .string(nowISO)
                if row["createdAt"] == nil { row["createdAt"] = .string(nowISO) }
                row["installedByPack"] = .string(packID)
                row["capabilityPackInstallId"] = .string(installID)
                rows.append(row)
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
    }

    private static func removePackCatalogItems(
        _ ids: [String],
        installID: String,
        packID: String,
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        try await removeMarkedRows(path: root.appendingPathComponent("catalog/registry.json"), ids: ids, installID: installID, packID: packID, persistence: persistence)
    }

    private static func removeMarkedRows(
        path: URL,
        ids: [String],
        installID: String,
        packID: String,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        try await persistence.withFileLock(path) {
            var rows = try await CapabilityCatalogStoreReader.loadRegistryChecked(path, persistence: persistence)
            rows.removeAll { row in
                let marked = jsonString(row, "capabilityPackInstallId") == installID || jsonString(row, "installedByPack") == packID
                let matches = ids.isEmpty || ids.contains(jsonString(row, "id"))
                return marked && matches
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
    }

    private static func upsertCapabilityPackInstallReceipt(
        _ receipt: [String: JSONValue],
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        let path = capabilityPackInstallsPath(root: root)
        let id = jsonString(receipt, "id")
        try await persistence.withFileLock(path) {
            var rows = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(at: path)
            rows.removeAll { jsonString($0, "id") == id }
            rows.append(receipt)
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
    }

    private static func appendCapabilityPackTrace(
        kind: String,
        title: String,
        payload: [String: JSONValue],
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        let path = root.appendingPathComponent("traces/events.jsonl")
        var eventPayload = payload
        if eventPayload["status"] == nil { eventPayload["status"] = .string("ok") }
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string(kind),
            "title": .string(title),
            "status": eventPayload["status"] ?? .string("ok"),
            "payload": .object(eventPayload),
            "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(Date())),
        ])
        try await appendPathOwnedJSONL(
            event,
            to: path,
            using: persistence,
            logLabel: "NativeClient.capabilityPackTrace"
        )
    }

    private static func capabilityPackInstallsPath(root: URL) -> URL {
        root.appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("installs.json")
    }

    private static func jsonString(_ obj: [String: JSONValue], _ key: String) -> String {
        switch obj[key] {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return ""
        }
    }

}
