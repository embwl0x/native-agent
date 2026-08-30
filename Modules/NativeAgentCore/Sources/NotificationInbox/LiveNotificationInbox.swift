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

    public struct InformationalRollupResult: Sendable, Equatable {
        public let inserted: Bool
        public let cardID: String
        public let occurrenceCount: Int

        public init(inserted: Bool, cardID: String, occurrenceCount: Int) {
            self.inserted = inserted
            self.cardID = cardID
            self.occurrenceCount = occurrenceCount
        }
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

    /// Consolidates a producer-declared stream of repeated informational
    /// notices into one active card. This is deliberately opt-in: only an
    /// `info` row whose producer supplies a stable non-empty `rollupKey` may
    /// replace an earlier row. Important/actionable cards, archived cards, and
    /// unrelated informational rows retain ordinary append-once semantics.
    ///
    /// The surviving card records its first/last occurrence and count. A new
    /// occurrence resurfaces that one card as unread, but never creates an
    /// unbounded unread pile. Producers must not use this for user-authored
    /// work or events whose individual identity is operationally meaningful.
    public func appendOrRollUpInformational(
        _ row: JSONValue,
        id: String,
        rollupKey: String
    ) async throws -> InformationalRollupResult {
        let key = rollupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .object(let incoming) = row,
              Self.string(incoming["severity"])?.lowercased() == "info",
              !key.isEmpty else {
            let inserted = try await appendUnique(row, id: id)
            return InformationalRollupResult(inserted: inserted, cardID: id, occurrenceCount: 1)
        }

        let result = try await persistence.withFileLock(path) {
            () async throws -> InformationalRollupResult in
            var lines = try Self.readLines(path)
            let existingIndex = lines.lastIndex { line in
                guard case .object(let object)? = line.row,
                      Self.string(object["severity"])?.lowercased() == "info",
                      Self.string(object["informational_rollup_key"]) == key else { return false }
                let status = Self.string(object["status"])?.lowercased() ?? "unread"
                return status != "archived" && status != "dismissed"
            }

            guard let existingIndex,
                  case .object(let existing)? = lines[existingIndex].row else {
                if lines.contains(where: { Self.id(of: $0.row) == id }) {
                    return InformationalRollupResult(
                        inserted: false, cardID: id, occurrenceCount: 1
                    )
                }
                var inserted = incoming
                inserted["informational_rollup_key"] = .string(key)
                inserted["occurrence_count"] = .int(1)
                if let createdAt = inserted["created_at"] {
                    inserted["first_created_at"] = createdAt
                    inserted["last_created_at"] = createdAt
                }
                let insertedRow = JSONValue.object(inserted)
                lines.append(Line(
                    raw: Data(try insertedRow.serialize(pretty: false).utf8),
                    row: insertedRow
                ))
                try Self.write(Self.retained(lines), to: path)
                return InformationalRollupResult(inserted: true, cardID: id, occurrenceCount: 1)
            }

            let existingID = Self.string(existing["id"]) ?? id
            let priorCount = Self.int(existing["occurrence_count"]) ?? 1
            let nextCount = max(1, priorCount) + 1
            var replacement = incoming
            replacement["id"] = .string(existingID)
            replacement["informational_rollup_key"] = .string(key)
            replacement["occurrence_count"] = .int(Int64(nextCount))
            replacement["first_created_at"] = existing["first_created_at"]
                ?? existing["created_at"]
                ?? incoming["created_at"]
                ?? .null
            replacement["last_created_at"] = incoming["created_at"] ?? .null
            replacement["status"] = .string("unread")
            replacement["read_at"] = .null
            let replacementRow = JSONValue.object(replacement)

            // Move the surviving card to the newest position so existing
            // file-order readers present the latest occurrence naturally.
            lines.remove(at: existingIndex)
            lines.append(Line(
                raw: Data(try replacementRow.serialize(pretty: false).utf8),
                row: replacementRow
            ))
            try Self.write(Self.retained(lines), to: path)
            return InformationalRollupResult(
                inserted: false,
                cardID: existingID,
                occurrenceCount: nextCount
            )
        }
        invalidate()
        return result
    }

    @discardableResult
    public func updateStatus(id: String, status: String, readAt: String?) async throws -> Bool {
        let changed = try await persistence.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            guard let index = lines.firstIndex(where: { Self.id(of: $0.row) == id }),
                  case .object(var object)? = lines[index].row else { return false }
            // A detail sheet may appear more than once while the same card is
            // already open.  Its automatic read action is therefore a
            // state-transition request, not a reason to churn `read_at` (and
            // the whole JSONL file) on every appearance.  Preserve a prior
            // read timestamp once the requested state is already complete;
            // an old read row with no timestamp is still repaired below.
            let existingStatus: String? = {
                guard case .string(let value)? = object["status"] else { return nil }
                return value
            }()
            let hasReadTimestamp: Bool = {
                guard case .string(let value)? = object["read_at"] else { return false }
                return !value.isEmpty
            }()
            if existingStatus == status, readAt == nil || hasReadTimestamp {
                return true
            }
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

    /// Archives a producer-selected set of unread informational cards in one
    /// locked rewrite. The status/severity checks are repeated under the lock
    /// so a card that became actionable after the producer's read snapshot is
    /// never hidden by a reconciliation race.
    @discardableResult
    public func archiveUnreadInformational(
        ids: [String],
        readAt: String
    ) async throws -> Int {
        let targets = Set(ids.filter { !$0.isEmpty })
        guard !targets.isEmpty else { return 0 }
        let changed = try await persistence.withFileLock(path) { () async throws -> Int in
            var lines = try Self.readLines(path)
            var changed = 0
            for index in lines.indices {
                guard case .object(var object)? = lines[index].row,
                      let id = Self.id(of: lines[index].row),
                      targets.contains(id),
                      Self.string(object["severity"])?.lowercased() == "info",
                      (Self.string(object["status"])?.lowercased() ?? "unread") == "unread"
                else { continue }
                object["status"] = .string("archived")
                object["read_at"] = .string(readAt)
                let row = JSONValue.object(object)
                lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
                changed += 1
            }
            if changed > 0 {
                try Self.write(Self.retained(lines), to: path)
            }
            return changed
        }
        if changed > 0 { invalidate() }
        return changed
    }

    /// Archives active cards by stable id while preserving user-dismissed or
    /// already-archived history. Optional metadata lets the producer distinguish
    /// an automatic resolution from a user decision on a later recurrence.
    @discardableResult
    public func archiveActive(
        ids: [String],
        readAt: String,
        createdNoLaterThan: Date? = nil,
        metadata: [String: JSONValue] = [:]
    ) async throws -> Int {
        let targets = Set(ids.filter { !$0.isEmpty })
        guard !targets.isEmpty else { return 0 }
        let changed = try await persistence.withFileLock(path) { () async throws -> Int in
            var lines = try Self.readLines(path)
            var changed = 0
            for index in lines.indices {
                guard lines[index].isActive,
                      case .object(var object)? = lines[index].row,
                      let id = Self.id(of: lines[index].row), targets.contains(id) else { continue }
                if let createdNoLaterThan {
                    guard let rawCreated = Self.string(object["created_at"]),
                          let created = Self.parseISO8601(rawCreated),
                          created <= createdNoLaterThan else { continue }
                }
                object["status"] = .string("archived")
                object["read_at"] = .string(readAt)
                for (key, value) in metadata { object[key] = value }
                let row = JSONValue.object(object)
                lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
                changed += 1
            }
            if changed > 0 { try Self.write(Self.retained(lines), to: path) }
            return changed
        }
        if changed > 0 { invalidate() }
        return changed
    }

    /// Appends one state-transition card while retiring every older active card
    /// in the same producer-defined group. The latest-state gate, retirement,
    /// and append share one lock, so concurrent producers cannot leave two
    /// contradictory states active. Retired rows remain as ordinary history.
    @discardableResult
    public func appendReplacingActiveGroup(
        _ row: JSONValue,
        id: String,
        source: String,
        groupField: String,
        groupValue: String,
        stateField: String,
        transitionAt: String,
        ifLatestStateAllows: @escaping @Sendable (String?) -> Bool
    ) async throws -> Bool {
        guard !id.isEmpty, !source.isEmpty, !groupField.isEmpty,
              !groupValue.isEmpty, !stateField.isEmpty else { return false }
        let inserted = try await persistence.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            guard !lines.contains(where: { Self.id(of: $0.row) == id }) else { return false }
            let matching = lines.indices.filter { index in
                guard case .object(let object)? = lines[index].row else { return false }
                return Self.string(object["source"]) == source
                    && Self.string(object[groupField]) == groupValue
            }
            let latestState = matching.reversed().compactMap { index -> String? in
                guard case .object(let object)? = lines[index].row else { return nil }
                return Self.string(object[stateField])
            }.first
            guard ifLatestStateAllows(latestState) else { return false }

            for index in matching where lines[index].isActive {
                guard case .object(var object)? = lines[index].row else { continue }
                object["status"] = .string("archived")
                object["read_at"] = .string(transitionAt)
                let archived = JSONValue.object(object)
                lines[index] = Line(
                    raw: Data(try archived.serialize(pretty: false).utf8),
                    row: archived
                )
            }
            lines.append(Line(raw: Data(try row.serialize(pretty: false).utf8), row: row))
            try Self.write(Self.retained(lines), to: path)
            return true
        }
        if inserted { invalidate() }
        return inserted
    }

    /// One-shot/restart-safe convergence for grouped state streams written by
    /// older builds: only the newest physical row per group remains active.
    /// This never removes history and never changes the newest state.
    @discardableResult
    public func archiveSupersededActiveRows(
        source: String,
        groupField: String,
        readAt: String
    ) async throws -> Int {
        guard !source.isEmpty, !groupField.isEmpty else { return 0 }
        let changed = try await persistence.withFileLock(path) { () async throws -> Int in
            var lines = try Self.readLines(path)
            var latestByGroup: [String: Int] = [:]
            for index in lines.indices {
                guard case .object(let object)? = lines[index].row,
                      Self.string(object["source"]) == source,
                      let group = Self.string(object[groupField]), !group.isEmpty else { continue }
                latestByGroup[group] = index
            }
            var changed = 0
            for index in lines.indices {
                guard lines[index].isActive,
                      case .object(var object)? = lines[index].row,
                      Self.string(object["source"]) == source,
                      let group = Self.string(object[groupField]),
                      latestByGroup[group] != index else { continue }
                object["status"] = .string("archived")
                object["read_at"] = .string(readAt)
                let archived = JSONValue.object(object)
                lines[index] = Line(
                    raw: Data(try archived.serialize(pretty: false).utf8),
                    row: archived
                )
                changed += 1
            }
            if changed > 0 { try Self.write(Self.retained(lines), to: path) }
            return changed
        }
        if changed > 0 { invalidate() }
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

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func int(_ value: JSONValue?) -> Int? {
        guard case .int(let value)? = value, let result = Int(exactly: value) else { return nil }
        return result
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
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
