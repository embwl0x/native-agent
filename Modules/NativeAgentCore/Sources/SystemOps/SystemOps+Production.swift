import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// Blueprint: | `SystemOps+Production.swift` | `ProductionExport`: Checked newest-first export registry and archives |

// MARK: - Production read routes
// Production status belongs to native runtime owners; registry reads must not start an external runtime.

/// Keep the page projection and export writer on the same typed registry row.
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
        // Only a missing registry means no exports; existing invalid storage fails.
        let value = try await SwiftNativePersistenceCore.readJSON(registryPath, ifMissing: .array([]))
        guard case .array(let rows) = value else {
            throw NSError(domain: "NativeAgentBackup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Export registry must contain an array."
            ])
        }
        let exports = try rows.map { try ProductionExport(row: $0) }
        return exports.enumerated().sorted { a, b in
            let left = a.element.createdAt ?? ""
            let right = b.element.createdAt ?? ""
            return left == right ? a.offset < b.offset : left > right
        }.map(\.element)
    }
}
