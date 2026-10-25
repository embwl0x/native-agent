import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// Blueprint: | `SystemOps+Production.swift` | `SwiftNativeProductionExportsClient`: lossless production export registry reads and verification; no external status runtime |

// MARK: - Production read routes
//
// Swift-owned reader for production export registry state.
// Exports read <dataRoot>/production/exports/registry.json losslessly. Health-card and
// whats-running live in their dedicated Swift runtime/status surfaces; do not
// resurrect an external runtime to answer production status.

/// One production-export receipt. Mirrors the dict written by
/// `create_production_export` and surfaced by
/// `list_production_exports`. The full row is held verbatim in `raw` so the
/// Swift port re-serializes the registry rows losslessly (every field
/// preserved, not just the known ProductionExport subset).
public struct ProductionExportReceipt: Sendable, Equatable {
    public let raw: JSONValue
    /// Sort key — byte-accurate mirror of Python's
    /// `str(item.get("createdAt") or "")`. Python's
    /// `or ""` treats None / empty-string / 0 / false as falsy → "", and
    /// stringifies any other truthy value. createdAt is always an ISO string
    /// in practice, but matching the full `str(v or "")` semantics costs
    /// nothing and removes a divergence.
    public let createdAt: String

    public init(raw: JSONValue) {
        self.raw = raw
        var key = ""
        if case .object(let obj) = raw {
            key = Self.pythonStrOrEmpty(obj["createdAt"] ?? .null)
        }
        self.createdAt = key
    }

    /// `str(v or "")` for the JSON value kinds that can appear in a registry
    /// row. Falsy (null / "" / 0 / 0.0 / false) → ""; truthy → its `str()`.
    static func pythonStrOrEmpty(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return ""
        case .string(let s):
            return s  // "" stays "" (falsy → "" via `or ""`, same result)
        case .bool(let b):
            return b ? "True" : ""   // Python str(True)=="True"; False is falsy → ""
        case .int(let i):
            return i == 0 ? "" : String(i)
        case .double(let d):
            // Python: 0.0 is falsy → ""; otherwise str(float). We only need
            // a deterministic stable key, not float-repr parity, but ISO
            // createdAt never lands here.
            return d == 0 ? "" : String(d)
        case .array, .object:
            // A non-empty array/object is truthy in Python; its str() is
            // implementation-detail and never occurs for createdAt. Treat as
            // empty so a malformed row sorts to the bottom deterministically.
            return ""
        }
    }
}

/// One production export as the Capabilities page shows it: the typed
/// projection of a registry row, and the row an export appends.
public struct ProductionExport: Identifiable, Codable, Hashable, Sendable {
    @MainActor
    public func verifyRegistry(dataRoot: URL) async throws -> (records: [ProductionExport], failure: String?) {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let actualBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard actualBytes > 0 else { return ([], "the archive was empty after it was created") }
        guard sizeBytes == actualBytes else { return ([], "the archive size did not match its creation receipt") }
        let records = try await Self.list(dataRoot: dataRoot)
        guard records.contains(where: { $0.id == id && $0.path == path && $0.sizeBytes == actualBytes }) else {
            return ([], "the export registry did not confirm the created archive")
        }
        return (records, nil)
    }

    public var id: String
    public var kind: String?
    public var path: String
    public var scope: [String]
    public var checksum: String?
    public var sizeBytes: Int?
    public var createdAt: String?

    public init(id: String, kind: String?, path: String, scope: [String], checksum: String?,
                sizeBytes: Int?, createdAt: String?) {
        self.id = id; self.kind = kind; self.path = path; self.scope = scope
        self.checksum = checksum; self.sizeBytes = sizeBytes; self.createdAt = createdAt
    }

    /// A present field of the wrong type makes the row malformed.
    public init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), kind: try row.optionalString("kind"), path: try row.string("path"),
            scope: try row.strings("scope"), checksum: try row.optionalString("checksum"),
            sizeBytes: try row.optionalInt("sizeBytes"), createdAt: try row.optionalString("createdAt"))
    }

    public var row: JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "path": .string(path),
            "scope": .array(scope.map { .string($0) }),
        ]
        if let kind { obj["kind"] = .string(kind) }
        if let checksum { obj["checksum"] = .string(checksum) }
        if let sizeBytes { obj["sizeBytes"] = .int(Int64(sizeBytes)) }
        if let createdAt { obj["createdAt"] = .string(createdAt) }
        return .object(obj)
    }

    /// `production/exports/registry.json`, newest first; a malformed row fails the read.
    public static func list(dataRoot: URL) async throws -> [ProductionExport] {
        let registryPath = dataRoot
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("registry.json")
        return try await SwiftNativeProductionExportsClient(registryPath: registryPath).listExports()
            .map { try ProductionExport(row: $0.raw) }
    }
}

// MARK: - SwiftNative — ProductionExports

public struct SwiftNativeProductionExportsClient: Sendable {
    private let registryPath: URL
    private let persistence: any PersistenceCoreProtocol

    /// - Parameters:
    ///   - registryPath: `<dataRoot>/production/exports/registry.json`.
    ///                   Defaults to the PersistenceCore data root path —
    ///                   matches `Daemon.production_exports_path`
    ///.
    ///   - persistence:  Test-injectable PersistenceCore.
    public init(
        registryPath: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.registryPath = registryPath
            ?? PersistenceCore.defaultDataRoot()
                .appendingPathComponent("production", isDirectory: true)
                .appendingPathComponent("exports", isDirectory: true)
                .appendingPathComponent("registry.json")
        self.persistence = persistence
    }

    public func listExports() async throws -> [ProductionExportReceipt] {
        // Only a missing registry means no exports; existing invalid storage fails.
        let value = try await persistence.readJSON(registryPath, ifMissing: .array([]))
        guard case .array(let rows) = value else {
            throw NSError(domain: "NativeAgentBackup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Export registry must contain an array."
            ])
        }
        let receipts = rows.map { ProductionExportReceipt(raw: $0) }
        // Python: sorted(..., key=lambda i: str(i.get("createdAt") or ""), reverse=True).
        // Swift's sort is not stable; CPython's sorted IS stable. Anchor a
        // stable DESC sort with the original index as the tie-breaker so
        // equal-createdAt rows keep their registry order (matches Timsort).
        let indexed = receipts.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            if a.1.createdAt != b.1.createdAt { return a.1.createdAt > b.1.createdAt }
            return a.0 < b.0
        }
        return sorted.map { $0.1 }
    }
}
