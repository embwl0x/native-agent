import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CapabilityCatalog.swift` | Read-only checked sources/roots. |

// MARK: - Capability catalog persistence
// Saved sources and roots are checked authority: reads neither rewrite them nor create signing identity. Storage exclusions do not remove hidden retained files
// from privacy inventory.

// MARK: - File-private helpers

public enum CapabilityCatalogPersistenceError: Error, LocalizedError {
    case unreadable(path: String, detail: String)
    case malformed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let detail):
            return "capability_catalog_unreadable: Cannot read \(path): \(detail). Repair access to this file; preserve its bytes and saved authority."
        case .malformed(let path, let detail):
            return """
                capability_catalog_malformed: Invalid records in \(path): \(detail). Repair this file from its retained bytes, preserving every \
                record and authority choice; never reset it to an empty catalog.
                """
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
                    shape: """
                        This catalog authority store must be a JSON array of records with unique nonblank string IDs, string names and typed optional \
                        string fields. Preserve every record, field, trust root, source and authority choice. Recover required fields only from these \
                        retained bytes; never invent IDs, status or authority, or reset the catalog.
                        """) + " Repair only the named catalog file from its retained bytes, preserving saved authority.")
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

/// Use the same strict boundary for live reads and restore preflight so missing and damaged authority never collapse.
public enum CapabilityCatalogStoreReader {
    /// Pure, strict read of saved catalog sources. A missing store has no records. An existing damaged store throws; its bytes remain untouched.
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
