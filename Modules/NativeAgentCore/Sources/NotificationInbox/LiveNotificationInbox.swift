import Foundation
import NativeAgentCore
import PersistenceCore

/// Single file owner for the live macOS notification inbox.
///
/// The log stays interoperable JSONL, but reads reuse a parsed snapshot until
/// the file identity changes and every mutation is serialized by the canonical
/// PersistenceCore flock. Retention protects active cards first and uses the
/// remaining budget for recent history; malformed physical lines are carried
/// through byte-for-byte and count against the same hard bound.
public actor LiveNotificationInbox {
    public static let rowLimit = 1_000
    public static let shared = LiveNotificationInbox(
        path: livePath(dataRoot: PersistenceCore.defaultDataRoot())
    )

    public static func livePath(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    private struct Stamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: TimeInterval
    }

    private struct Line {
        let raw: Data
        let row: JSONValue?

        var isActive: Bool {
            guard case .object(let object)? = row else { return false }
            let status: String
            if case .string(let value)? = object["status"] { status = value }
            else { status = "unread" }
            return status != "archived" && status != "dismissed"
        }
    }

    public let path: URL
    private let persistence = SwiftNativePersistenceCore()
    private var cachedStamp: Stamp?
    private var cachedRows: [JSONValue]?

    public init(path: URL) {
        self.path = path
    }

    /// Parsed rows in file order. A non-empty file containing no valid row is
    /// corruption, not an empty inbox, and is surfaced to the caller.
    public func rows() throws -> [JSONValue] {
        let stamp = try Self.stamp(path)
        if stamp == cachedStamp, let cachedRows { return cachedRows }
        let lines = try Self.readLines(path)
        let parsed = lines.compactMap(\.row)
        if stamp?.size ?? 0 > 0, parsed.isEmpty {
            throw NSError(domain: "NotificationInbox", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "The notification inbox contains bytes but no valid JSON rows."
            ])
        }
        cachedStamp = stamp
        cachedRows = parsed
        return parsed
    }

    /// Append once by stable id. The scan and append happen under one flock, so
    /// retries from approval/execution staging cannot create duplicate cards.
    @discardableResult
    public func appendUnique(_ row: JSONValue, id: String) async throws -> Bool {
        let inserted = try await persistence.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            if lines.contains(where: { Self.id(of: $0.row) == id }) { return false }
            lines.append(Line(raw: Data(try row.serialize(pretty: false).utf8), row: row))
            try Self.write(Self.retained(lines), to: path)
            return true
        }
        invalidate()
        return inserted
    }

    /// Replace a stable card or append it when absent. Used for notices whose
    /// identity survives content changes without accumulating duplicates.
    @discardableResult
    public func upsert(_ row: JSONValue, id: String) async throws -> Bool {
        let inserted = try await persistence.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            let raw = Data(try row.serialize(pretty: false).utf8)
            if let index = lines.firstIndex(where: { Self.id(of: $0.row) == id }) {
                lines[index] = Line(raw: raw, row: row)
                try Self.write(Self.retained(lines), to: path)
                return false
            }
            lines.append(Line(raw: raw, row: row))
            try Self.write(Self.retained(lines), to: path)
            return true
        }
        invalidate()
        return inserted
    }

    @discardableResult
    public func updateStatus(id: String, status: String, readAt: String?) async throws -> Bool {
        let changed = try await persistence.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            guard let index = lines.firstIndex(where: { Self.id(of: $0.row) == id }),
                  case .object(var object)? = lines[index].row else { return false }
            object["status"] = .string(status)
            if let readAt { object["read_at"] = .string(readAt) }
            let row = JSONValue.object(object)
            lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
            try Self.write(Self.retained(lines), to: path)
            return true
        }
        invalidate()
        return changed
    }

    private func invalidate() {
        cachedStamp = nil
        cachedRows = nil
    }

    private static func retained(_ lines: [Line]) -> [Line] {
        guard lines.count > rowLimit else { return lines }
        var kept = Set<Int>()
        // Newest active/actionable cards receive the budget first.
        for index in lines.indices.reversed() where lines[index].isActive {
            guard kept.count < rowLimit else { break }
            kept.insert(index)
        }
        // Fill the remaining room with newest terminal history and malformed
        // physical lines. Corrupt bytes are never silently "cleaned up".
        if kept.count < rowLimit {
            for index in lines.indices.reversed() where !kept.contains(index) {
                guard kept.count < rowLimit else { break }
                kept.insert(index)
            }
        }
        return lines.indices.compactMap { kept.contains($0) ? lines[$0] : nil }
    }

    private static func id(of row: JSONValue?) -> String? {
        guard case .object(let object)? = row,
              case .string(let id)? = object["id"] else { return nil }
        return id
    }

    private static func readLines(_ path: URL) throws -> [Line] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [] }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { Data($0) }
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts.map { Line(raw: $0, row: try? JSONValue.parse($0)) }
    }

    private static func write(_ lines: [Line], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var payload = Data()
        payload.reserveCapacity(lines.reduce(0) { $0 + $1.raw.count + 1 })
        for line in lines {
            payload.append(line.raw)
            payload.append(0x0A)
        }
        try payload.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path.path
        )
    }

    private static func stamp(_ path: URL) throws -> Stamp? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        return Stamp(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
    }
}
