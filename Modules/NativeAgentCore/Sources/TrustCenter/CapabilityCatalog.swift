import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `CapabilityCatalog.swift` | Read-only typed saved capability sources and trust roots; source writes validate stable name-derived identity and commit under the source lock. No pack source, root, key creation or availability projection; retained pack bytes remain untouched. |

// MARK: - Capability catalog persistence
//
// Sources and trust roots are checked operator authority. Reads never rewrite
// lists; missing lists have no saved records. Reads create no signing identity
// or synthetic local pack source/root. Retained pack files are inert.
// Local backup includes sources, roots and registry; export
// selects sources, roots and registry only. The 64-hex-character, 0600
// retained .pack_signing_key is deliberately excluded from local backup, export and
// phone sync. No catalog file syncs to the phone. PrivacyMap lists Catalog
// including regular hidden files in its directory size tally. Storage/export
// exclusions do not exclude bytes from this privacy inventory.

// MARK: - File-private helpers

public enum CapabilityCatalogPersistenceError: Error, LocalizedError {
    case unreadable(path: String, detail: String)
    case malformed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let detail):
            return "capability_catalog_unreadable: Cannot read \(path): \(detail). Repair access to this file; preserve its bytes and saved authority."
        case .malformed(let path, let detail):
            return "capability_catalog_malformed: Invalid records in \(path): \(detail). Repair this file from its retained bytes, preserving every record and authority choice; never reset it to an empty catalog."
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
                    shape: "This catalog authority store must be a JSON array of records with unique nonblank string IDs, string names and typed optional string fields. Preserve every record, field, trust root, source and authority choice. Recover required fields only from these retained bytes; never invent IDs, status or authority, or reset the catalog.") + " Repair only the named catalog file from its retained bytes, preserving saved authority.")
        }
    }
}

private func loadObjectRowsChecked(
    at path: URL,
    recordKind: String,
    validate: ([String: JSONValue]) throws -> Void
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
    return try CapabilityCatalogStoreReader.objectRowsChecked(raw, at: path, recordKind: recordKind, validate: validate)
}

/// Reusable strict boundary for capability authority files. Backup/restore and
/// other ingress paths should call these methods before installing bytes so the
/// same missing-vs-damaged contract governs live reads and restore preflight.
public enum CapabilityCatalogStoreReader {
    /// Pure, strict read of saved catalog sources. A missing store has no
    /// records. An existing damaged store throws; its bytes remain untouched.
    public static func catalogSources(dataRoot: URL) throws -> [[String: JSONValue]] {
        let sourcesPath = dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("sources", isDirectory: true)
            .appendingPathComponent("sources.json")
        return try loadCatalogSourcesChecked(at: sourcesPath)
    }

    /// Strict saved-root read; never rewrites the list or creates a key.
    public static func capabilityTrustRoots(dataRoot: URL) throws -> [[String: JSONValue]] {
        let trustPath = dataRoot
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("roots.json")
        return try loadCapabilityTrustRootsChecked(at: trustPath)
    }

    fileprivate static func objectRowsChecked(
        _ raw: JSONValue, at path: URL, recordKind: String,
        validate: ([String: JSONValue]) throws -> Void
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
            do { try validate(row) }
            catch {
                throw CapabilityCatalogPersistenceError.malformed(
                    path: path.path, detail: "\(recordKind) row \(index): \(error.localizedDescription)"
                ).failure
            }
            rows.append(row)
        }
        return rows
    }

    public static func loadCatalogSourcesChecked(
        at path: URL
    ) throws -> [[String: JSONValue]] {
        try loadObjectRowsChecked(at: path, recordKind: "catalog source") {
            _ = try CapabilityCatalogSource(row: .object($0))
        }
    }

    public static func loadCapabilityTrustRootsChecked(
        at path: URL
    ) throws -> [[String: JSONValue]] {
        try loadObjectRowsChecked(at: path, recordKind: "capability trust root") {
            _ = try CapabilityTrustRoot(row: .object($0))
        }
    }
}

/// Stable name-derived identity. An unusable name is refused before any write.
private func swiftCatalogSlugify(_ value: String) throws -> String {
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
    guard !trimmed.isEmpty else {
        throw ToolFailureError("The catalog source name cannot form a stable identity.",
            argumentPath: "name", accepted: "A source name containing at least one ASCII letter or digit.",
            effects: .none, code: "catalog_source_name_invalid", status: .refused,
            instruction: "Include an ASCII letter or digit in the source name, then save it again.", recovery: .correctArguments)
    }
    return trimmed
}


/// Source writes validate under the `catalog/sources/sources.json` flock, then commit once; reads are lock-free.
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

    /// Shared diagnostic ledger; appends belong to TurnTracePersistLane.
    private var tracesPath: URL {
        dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// Replace the source with the same slugified ID and append its replacement.
    public func upsertCatalogSource(name: String, url: String, kind: String) async throws -> [String: JSONValue] {
        let name = String(name.prefix(120))
        let sourceID = try swiftCatalogSlugify(name)
        let now = SwiftNativeManifestSigner.isoTimestamp(clock())
        let status = url.isEmpty ? "needs_setup" : "ready"

        let replacement: [String: JSONValue] = [
            "id": .string(sourceID),
            "name": .string(name),
            "kind": .string(kind),
            "url": .string(url),
            "status": .string(status),
            "lastCheckedAt": .null,
            "updatedAt": .string(now),
        ]

        let sourcesPathLocal = sourcesPath
        let dataRootLocal = dataRoot
        let record = try await SwiftNativePersistenceCore.withFileLock(sourcesPathLocal) {
            var sources = try CapabilityCatalogStoreReader.catalogSources(dataRoot: dataRootLocal)
            let index = sources.firstIndex { $0["id"] == .string(sourceID) }
            var record: [String: JSONValue]
            if let index {
                record = sources[index]
                sources.remove(at: index)
            } else {
                record = ["createdAt": .string(now)]
            }
            record.merge(replacement) { _, new in new }
            sources.append(record)
            try await SwiftNativePersistenceCore.writeJSON(.array(sources.map { .object($0) }), to: sourcesPathLocal)
            return record
        }
        // Receipt failures propagate even after the source write succeeded.
        try await TurnTracePersistLane(standalonePath: tracesPath).appendChecked(
            TurnTraceEvent(kind: "catalog.source.save", title: name, status: status,
            payload: .object([
                "sourceId": .string(sourceID),
                "status": .string(status),
            ]), createdAt: SwiftNativeManifestSigner.isoTimestamp(clock())))
        return record
    }

}
