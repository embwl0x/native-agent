import Foundation
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `CapabilityCatalog.swift` | Capability sources, trust roots, historical pack installation receipts and removal; catalog registry aggregation and mutation share `CapabilityCatalogStoreReader`'s checked object-array schema; workflow mutations delegate to SavedWorkflows. Installed items and receipts are authoritative, with no saved pack copy or `packPath`. Retained `catalog/packs` files are untouched orphans, excluded from local backup, export and phone sync; PrivacyMap lists their catalog folder. |

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
    return try CapabilityCatalogStoreReader.objectRowsChecked(raw, at: path, recordKind: recordKind)
}

/// Reusable strict boundary for capability authority files. Backup/restore and
/// other ingress paths should call these methods before installing bytes so the
/// same missing-vs-damaged contract governs live reads and restore preflight.
public enum CapabilityCatalogStoreReader {
    /// Pure, strict read of catalog sources. A missing store returns the
    /// bootstrap default in memory. An existing damaged store throws and its
    /// bytes remain untouched.
    public static func catalogSources(dataRoot: URL, clock: @Sendable () -> Date = { Date() }) throws -> [[String: JSONValue]] {
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

    /// Strict root-list read; never rewrites it. After validation, resolving
    /// the local root creates its signing key if missing.
    public static func capabilityTrustRoots(dataRoot: URL, clock: @Sendable () -> Date = { Date() }) throws -> [[String: JSONValue]] {
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

    fileprivate static func objectRowsChecked(
        _ raw: JSONValue, at path: URL, recordKind: String
    ) throws -> [[String: JSONValue]] {
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

    /// The catalog registry's one object-array schema, shared by mutation and
    /// read-only aggregation. Existing damaged rows never become defaults.
    package static func loadRegistryChecked(_ path: URL) async throws -> [[String: JSONValue]] {
        let raw = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .array([]))
        return try objectRowsChecked(raw, at: path, recordKind: "capability pack registry")
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

/// SHA-256 hex of the UTF-8 signing key, truncated to 32 characters.
private func sha256HexPrefix32(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(32))
}

// MARK: - Catalog value coercion

/// Null/booleans spell "None"/"True"/"False"; small integral doubles keep ".0"; containers become empty strings.
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

/// Stringify the first truthy value, or return the supplied default.
func pyStrOr(_ values: [JSONValue?], default fallback: String) -> String {
    for v in values where v?.isTruthy == true { return pyStr(v) }
    return fallback
}

/// Lowercase, retain ASCII alphanumerics, collapse separators, trim dashes and cap at 80 characters; empty slugs use a UUID.
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
            pendingDash = true
        }
    }
    let trimmed = String(out.prefix(80))
    return trimmed.isEmpty ? UUID().uuidString.lowercased() : trimmed
}


/// Source writes validate and merge under the `catalog/sources/sources.json` flock, then commit once; install reads are lock-free.
public actor SwiftNativeCatalogWrites {
    private let dataRoot: URL
    private let clock: @Sendable () -> Date

    public init(
        dataRoot: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
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

    /// Shared diagnostic ledger; appends belong to TurnTracePersistLane.
    private var tracesPath: URL {
        dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// Replace the source with the same slugified ID and append its replacement.
    public func upsertCatalogSource(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        let name = String(
            pyStrOr([body["name"], body["id"]], default: "Capability Source").prefix(120)
        )
        let idSeed = body["id"]?.isTruthy == true ? pyStr(body["id"]) : name
        let sourceID = swiftCatalogSlugify(idSeed)
        let url = pyStrOr([body["url"]], default: "")
        let kind = pyStrOr([body["kind"]], default: "local")
        let trustedRootId = pyStrOr([body["trustedRootId"]], default: "local-trusted")
        let createdAt = body["createdAt"]?.isTruthy == true
            ? pyStr(body["createdAt"])
            : SwiftNativeManifestSigner.isoTimestamp(clock())
        let now = SwiftNativeManifestSigner.isoTimestamp(clock())

        let record: [String: JSONValue] = [
            "id": .string(sourceID),
            "name": .string(name),
            "kind": .string(kind),
            "url": .string(url),
            // Status uses the original URL's truthiness, before string coercion.
            "status": .string(body["url"]?.isTruthy == true ? "ready" : "needs_setup"),
            "trustedRootId": .string(trustedRootId),
            "lastCheckedAt": .null,
            "createdAt": .string(createdAt),
            "updatedAt": .string(now),
        ]

        let sourcesPathLocal = sourcesPath
        let dataRootLocal = dataRoot
        let readTime = clock()
        try await SwiftNativePersistenceCore.withFileLock(sourcesPathLocal) {
            let merged = try CapabilityCatalogStoreReader.catalogSources(
                dataRoot: dataRootLocal, clock: { readTime }
            )
            var sources = merged.filter { row in
                if case .string(let id)? = row["id"] { return id != sourceID }
                return true
            }
            sources.append(record)
            try await SwiftNativePersistenceCore.writeJSON(.array(sources.map { .object($0) }), to: sourcesPathLocal)
        }
        // Receipt failures propagate even after the source write succeeded.
        let status = record["status"]?.stringValue ?? ""
        try await TurnTracePersistLane(standalonePath: tracesPath).appendChecked(
            TurnTraceEvent(kind: "catalog.source.save", title: name, status: status.isEmpty ? "ok" : status,
            payload: .object([
                "sourceId": .string(sourceID),
                "status": record["status"] ?? .string(""),
            ]), createdAt: SwiftNativeManifestSigner.isoTimestamp(clock())))
        return record
    }

    /// Checked receipt read, sorted by installedAt or createdAt descending.
    public func listCapabilityPackInstalls() async throws -> [[String: JSONValue]] {
        let rows = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(
            at: installsPath
        )
        func sortKey(_ row: [String: JSONValue]) -> String {
            pyStrOr([row["installedAt"], row["createdAt"]], default: "")
        }
        // Equal keys retain receipt order.
        let indexed = rows.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let lk = sortKey(lhs.1), rk = sortKey(rhs.1)
            if lk != rk { return lk > rk }
            return lhs.0 < rhs.0
        }
        return sorted.map { $0.1 }
    }

}
extension CapabilityPackInstall {

    public static func rollback(id: String, dataRoot root: URL) async throws -> CapabilityPackInstall {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "rollbackCapabilityPack: empty install id"
            ])
        }
        let rolledBack = try await rollbackCapabilityPackInstall(id: trimmed, root: root)
        let data = try JSONValue.object(rolledBack).serializedData(pretty: false)
        return try JSONDecoder().decode(CapabilityPackInstall.self, from: data)
    }


    private static func rollbackCapabilityPackInstall(
        id: String,
        root: URL
    ) async throws -> [String: JSONValue] {
        let installsPath = capabilityPackInstallsPath(root: root)
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let target = try await SwiftNativePersistenceCore.withFileLock(installsPath) {
            var rows = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(at: installsPath)
            guard let idx = rows.firstIndex(where: { jsonString($0, "id") == id }) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack install '\(id)' not found."
                ])
            }
            var row = rows[idx]
            let packID = jsonString(row, "packId")
            let itemIDs = try installedItemIDs(from: row)
            try await removePackCatalogItems(itemIDs.catalog, installID: id, packID: packID, root: root)
            try await SavedWorkflows(root: root)
                .removePackItems(itemIDs.workflows, installID: id, packID: packID)
            try CapabilityPackParts.remove(itemIDs.skills, installID: id, dataRoot: root)
            row["status"] = .string("rolled_back")
            row["rolledBackAt"] = .string(nowISO)
            rows[idx] = row
            try await SwiftNativePersistenceCore.writeJSON(.array(rows.map { .object($0) }), to: installsPath)
            return row
        }
        let packID = jsonString(target, "packId")
        try await TurnTracePersistLane(dataRootOverride: root).appendChecked(TurnTraceEvent(
            kind: "capability.pack.rollback",
            title: jsonString(target, "name").isEmpty ? packID : jsonString(target, "name"),
            status: "rolled_back", payload: .object([
                "installId": .string(id),
                "packId": .string(packID),
                "status": .string("rolled_back"),
            ]), createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())))
        return target
    }


    private static func installedItemIDs(from receipt: [String: JSONValue]) throws -> (catalog: [String], workflows: [String], skills: [String]) {
        guard case .string(let packID)? = receipt["packId"], !packID.isEmpty,
              case .object(let itemIds)? = receipt["itemIds"] else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack install receipt is invalid."
            ])
        }
        let fields = try JSONRow(.object(itemIds))
        func strings(_ key: String) throws -> [String] {
            guard let ids = try? fields.strings(key), ids.allSatisfy({ !$0.isEmpty }) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack install receipt has invalid \(key) IDs."
                ])
            }
            return ids
        }
        return try (strings("catalog"), strings("workflows"), strings("skills"))
    }


    private static func removePackCatalogItems(
        _ ids: [String],
        installID: String,
        packID: String,
        root: URL
    ) async throws {
        try await removeMarkedRows(path: root.appendingPathComponent("catalog/registry.json"), ids: ids, installID: installID, packID: packID)
    }

    private static func removeMarkedRows(
        path: URL,
        ids: [String],
        installID: String,
        packID: String
    ) async throws {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var rows = try await CapabilityCatalogStoreReader.loadRegistryChecked(path)
            rows.removeAll { row in
                let marked = jsonString(row, "capabilityPackInstallId") == installID || jsonString(row, "installedByPack") == packID
                let matches = ids.isEmpty || ids.contains(jsonString(row, "id"))
                return marked && matches
            }
            try await SwiftNativePersistenceCore.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
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
