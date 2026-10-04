import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

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

    public func toJSON() -> JSONValue { raw }
}

public protocol ProductionExportsClient: Sendable {
    func listExports() async throws -> [ProductionExportReceipt]
}

// MARK: - SwiftNative — ProductionExports

public struct SwiftNativeProductionExportsClient: ProductionExportsClient {
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
        // Python: read_json(path, []) — missing/garbage file yields the
        // default []. PersistenceCore.readJSON returns the defaultValue on
        // any read/parse failure, so `.array([])` is the byte-accurate
        // mirror of `read_json(..., [])`.
        let value = try await persistence.readJSON(registryPath, ifMissing: .array([]))
        guard case .array(let rows) = value else {
            // Python: `if not isinstance(exports, list): return []`
            return []
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
