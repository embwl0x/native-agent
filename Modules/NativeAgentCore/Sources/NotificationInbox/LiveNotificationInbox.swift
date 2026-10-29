import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LiveNotificationInbox.swift` | Single physical-line reader and writer for inbox cards; actor mutations and caller-owned row edits share retention and archive-before-rewrite under the inbox flock |

/// Single file owner for the live macOS notification inbox.
///
/// The log stays interoperable JSONL, but reads reuse a parsed snapshot until
/// the file identity changes and every mutation is serialized by the canonical
/// PersistenceCore flock. Retention protects active cards first and uses the
/// remaining budget for recent history; malformed physical lines are carried
/// through byte-for-byte and count against the same hard bound.
///
/// Every write applies age and row bounds:
///   * terminal (`archived`/`dismissed`) rows finished with (`read_at`, else
///     `created_at`) more than `terminalRetentionSeconds` ago are pruned,
///     oldest first;
///   * whatever survives is held to `rowLimit`, newest-active-first.
/// Active/unread cards are never age-pruned — only the hard cap can reach them,
/// and only once the active set alone exceeds it. Each pass evicts at most
/// `maxPrunedRowsPerPass` lines, so a backlog converges over several writes
/// instead of one unbounded scan-rewrite.
///
/// Nothing is destroyed: every evicted physical line is appended verbatim to
/// the uncapped overflow shelf beside the inbox (`inbox_archive.jsonl`, read
/// by delegation reconciliation) BEFORE the trimmed feed is written, mirroring
/// the studio journal. A shelf that cannot be written aborts the whole write.
/// File policy: inbox and overflow shelf are excluded from local backup/export;
/// the phone receives live-card projections. PrivacyMap: Notifications.
public actor LiveNotificationInbox {
    /// Hard bound on physical lines in the live feed.
    public static let rowLimit = 500
    /// How long finished history stays on the live feed, measured from when the
    /// row became terminal (`read_at`), not from when it was raised. Active
    /// cards are exempt at any age.
    public static let terminalRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60
    /// Lines evicted per write. Bounds the work one mutation can do while
    /// holding the file lock; a larger backlog drains over the next writes.
    public static let maxPrunedRowsPerPass = 200
    /// Occurrence ids one rollup card remembers absorbing, newest kept. The
    /// list is retry protection, not history — it only has to outlive a
    /// producer's redelivery window, and it rides inside the card's own row, so
    /// it is bounded rather than allowed to grow with the occurrence count.
    public static let maxAbsorbedOccurrenceIDs = 64

    public static let shared = LiveNotificationInbox(
        path: livePath(dataRoot: PersistenceCore.defaultDataRoot())
    )

    public static func livePath(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    /// Outstanding ways out stay live until the delivery owner settles them.
    public static func hold(dataRoot: URL, title: String, body: String, ways: [String], approvalID: String? = nil,
                            id: String = "held:" + UUID().uuidString.lowercased(), fields: [String: JSONValue] = [:]) async throws {
        var row: [String: JSONValue] = ["id": .string(id), "source": .string("resident_wake"),
            "created_at": .string(NotificationInboxClock.nowISO()), "severity": .string("info"), "status": .string("unread"),
            "title": .string(String(title.prefix(160))), "summary": .string(String(body.prefix(500))),
            "held_delivery": .array(ways.map(JSONValue.string)), "held_title": .string(title), "held_body": .string(body)]
        row.merge(fields) { _, value in value }
        if let approvalID { row["approval_id"] = .string(approvalID) }
        try await live(dataRoot: dataRoot).appendUnique(.object(row), id: id)
    }

    /// The live root's shared inbox keeps its parsed rows between calls; a
    /// fresh instance re-parses the whole feed. Any other root gets its own.
    public static func live(dataRoot: URL) -> LiveNotificationInbox {
        let path = livePath(dataRoot: dataRoot)
        return path == shared.path ? shared : LiveNotificationInbox(path: path)
    }

    /// The uncapped overflow shelf that retention moves rows onto, beside the
    /// feed it belongs to. Never trimmed — it is where "archived" stops meaning
    /// "deleted with a nicer word".
    public static func archivePath(forInbox path: URL) -> URL {
        path.deletingLastPathComponent()
            .appendingPathComponent("inbox_archive.jsonl")
    }

    public struct Line: Sendable {
        public let raw: Data
        public let row: JSONValue?

        public init(raw: Data, row: JSONValue?) {
            self.raw = raw
            self.row = row
        }

        var isActive: Bool {
            guard case .object(let object)? = row else { return false }
            let status: String
            if case .string(let value)? = object["status"] { status = value }
            else { status = "unread" }
            return status != "archived" && status != "dismissed"
        }

        /// A parsed row the user has finished with. Defined as the complement of
        /// `isActive` over parsed rows, so the two can never disagree about a
        /// status string. A malformed physical line is neither: corrupt bytes
        /// are carried through, never aged out.
        var isTerminal: Bool {
            guard case .object? = row else { return false }
            return !isActive
        }

        var hasHeldDelivery: Bool {
            guard case .object(let object)? = row,
                  case .array(let ways)? = object["held_delivery"] else { return false }
            return !ways.isEmpty
        }

        /// When this row's retention clock started. For a terminal row that is
        /// when the user finished with it (`read_at`), NOT when it was created:
        /// a card raised in June and archived today is fresh history, and
        /// pruning it the instant it was archived would make the archive button
        /// look like a delete button.  Falls back to `created_at` for the older
        /// rows written before archive/dismiss stamped a time.
        var retentionStamp: Date? {
            guard case .object(let object)? = row else { return nil }
            if case .string(let readAt)? = object["read_at"], !readAt.isEmpty,
               let finished = LiveNotificationInbox.parseISO8601(readAt) {
                return finished
            }
            guard case .string(let created)? = object["created_at"] else { return nil }
            return LiveNotificationInbox.parseISO8601(created)
        }
    }

    /// What one retention pass decided. `evicted` is in file order and reaches
    /// the overflow shelf before `kept` reaches the feed.
    private struct RetentionPlan {
        let kept: [Line]
        let evicted: [Line]
    }

    public let path: URL
    private var cachedStamp: SnapshotTailOpLog.FileStamp?
    private var cachedRows: [JSONValue]?

    public init(path: URL) {
        self.path = path
    }

    /// The overflow shelf this inbox prunes onto.
    public nonisolated var archivePath: URL { Self.archivePath(forInbox: path) }

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
        guard let stamp = SnapshotTailOpLog.fileStamp(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path.path])
        }
        if stamp == cachedStamp, let cachedRows { return cachedRows }
        let lines = try Self.readLines(path)
        let parsed = lines.compactMap(\.row)
        if case .present(_, _, let size, _, _, _, _) = stamp, size > 0, parsed.isEmpty {
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
        try await appendUnlessDuplicate(row) { rows in
            rows.contains(where: { Self.id(of: $0) == id }) ? id : nil
        } == nil
    }

    /// Append one card unless a producer-supplied check finds an equivalent one
    /// already live. The check and append share this feed's single flock, so
    /// concurrent producers cannot double-card. The check receives freshly read rows.
    ///
    /// Returns the existing card's id when the append was suppressed, nil when
    /// the row was written.
    public func appendUnlessDuplicate(
        _ row: JSONValue,
        duplicateID: @escaping @Sendable ([JSONValue]) -> String?
    ) async throws -> String? {
        let now = Date()
        let existing = try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> String? in
            var lines = try Self.readLines(path)
            if let existing = duplicateID(lines.compactMap(\.row)) { return existing }
            lines.append(Line(raw: Data(try row.serialize(pretty: false).utf8), row: row))
            try Self.write(retaining: lines, to: path, now: now)
            return nil
        }
        if existing == nil { invalidate() }
        return existing
    }

    /// Replace a stable card or append it when absent. Used for notices whose
    /// identity survives content changes without accumulating duplicates.
    @discardableResult
    public func upsert(_ row: JSONValue, id: String) async throws -> Bool {
        try await upsert(id: id) { existing in (row, existing == nil) }
    }

    /// Merge a producer's stable card under the same lock as user disposition.
    /// The newest physical row is the current card; earlier duplicate ids remain history.
    /// The producer returns whether this write represents a new occurrence.
    @discardableResult
    public func upsert(
        id: String,
        update: @escaping @Sendable (JSONValue?) throws -> (row: JSONValue, isNewOccurrence: Bool)
    ) async throws -> Bool {
        let now = Date()
        let isNewOccurrence = try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            let index = lines.lastIndex(where: { Self.id(of: $0.row) == id })
            let result = try update(index.flatMap { lines[$0].row })
            let raw = Data(try result.row.serialize(pretty: false).utf8)
            let line = Line(raw: raw, row: result.row)
            if let index {
                lines[index] = line
            } else {
                lines.append(line)
            }
            try Self.write(retaining: lines, to: path, now: now)
            return result.isNewOccurrence
        }
        invalidate()
        return isNewOccurrence
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
    ///
    /// `occurrenceID` is what makes a retry distinguishable from a new
    /// occurrence. The card id cannot do that job: a producer may reuse ONE
    /// stable card id for every write (the delegation-outcome loop does), in
    /// which case "an id the feed already holds" describes every legitimate
    /// occurrence. The card therefore remembers the occurrence ids it has
    /// absorbed — the newest `maxAbsorbedOccurrenceIDs`, oldest dropped — and a
    /// write whose occurrence is already in that set is the only thing treated
    /// as a retry.
    ///
    /// Passing nil keeps the older card-id retry rule. That is the conservative
    /// default: with no occurrence identity supplied there is no signal that
    /// separates the two cases, and the failure it prevents (an unread card
    /// resurfacing on every redelivery of one notice — the unbounded-attention
    /// pile this API exists to stop) is silent and unbounded, while the failure
    /// it can cause (one occurrence uncounted) leaves the card on the feed with
    /// its prior count and is fixed by the producer passing an `occurrenceID`.
    /// The two rules agree for a producer whose card id IS its occurrence id —
    /// one card id per notice — which is what nil is for.
    public func appendOrRollUpInformational(
        _ row: JSONValue,
        id: String,
        rollupKey: String,
        occurrenceID: String? = nil
    ) async throws -> InformationalRollupResult {
        let key = rollupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let occurrence: String? = {
            guard let trimmed = occurrenceID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }()
        guard case .object(let incoming) = row,
              incoming["severity"]?.stringValue?.lowercased() == "info",
              !key.isEmpty else {
            let inserted = try await appendUnique(row, id: id)
            return InformationalRollupResult(inserted: inserted, cardID: id, occurrenceCount: 1)
        }

        let now = Date()
        let result = try await SwiftNativePersistenceCore.withFileLock(path) {
            () async throws -> (value: InformationalRollupResult, written: Bool) in
            var lines = try Self.readLines(path)

            if let occurrence,
               let duplicate = lines.last(where: { line in
                   guard case .object(let object)? = line.row,
                         object["informational_rollup_key"]?.stringValue == key else { return false }
                   return (object["absorbed_occurrence_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []).contains(occurrence)
               }) {
                return (InformationalRollupResult(
                    inserted: false,
                    cardID: Self.id(of: duplicate.row) ?? id,
                    occurrenceCount: Self.recordedOccurrenceCount(duplicate.row)
                ), false)
            }

            let existingIndex = lines.lastIndex { line in
                guard case .object(let object)? = line.row,
                      object["severity"]?.stringValue?.lowercased() == "info",
                      object["informational_rollup_key"]?.stringValue == key else { return false }
                let status = object["status"]?.stringValue?.lowercased() ?? "unread"
                return status != "archived" && status != "dismissed"
            }

            guard let existingIndex,
                  case .object(let existing)? = lines[existingIndex].row else {
                if occurrence == nil,
                   let duplicate = lines.lastIndex(where: { Self.id(of: $0.row) == id }) {
                    return (InformationalRollupResult(
                        inserted: false,
                        cardID: id,
                        occurrenceCount: Self.recordedOccurrenceCount(lines[duplicate].row)
                    ), false)
                }
                let cardID = lines.contains(where: { Self.id(of: $0.row) == id })
                    ? "\(id)-\(UUID().uuidString)" : id
                var inserted = incoming
                inserted["id"] = .string(cardID)
                inserted["status"] = .string("unread")
                inserted["read_at"] = .null
                inserted["informational_rollup_key"] = .string(key)
                inserted["occurrence_count"] = .int(1)
                if let occurrence {
                    inserted["absorbed_occurrence_ids"] = .array([.string(occurrence)])
                }
                if let createdAt = inserted["created_at"] {
                    inserted["first_created_at"] = createdAt
                    inserted["last_created_at"] = createdAt
                }
                let insertedRow = JSONValue.object(inserted)
                lines.append(Line(
                    raw: Data(try insertedRow.serialize(pretty: false).utf8),
                    row: insertedRow
                ))
                try Self.write(retaining: lines, to: path, now: now)
                return (InformationalRollupResult(inserted: true, cardID: cardID, occurrenceCount: 1), true)
            }

            let existingID = existing["id"]?.stringValue ?? id
            let priorCount = max(1, Self.int(existing["occurrence_count"]) ?? 1)
            var absorbed = (existing["absorbed_occurrence_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])

            // Is this write a NEW occurrence, or the same one arriving twice?
            if let occurrence {
                guard !absorbed.contains(occurrence) else {
                    return (InformationalRollupResult(
                        inserted: false, cardID: existingID, occurrenceCount: priorCount
                    ), false)
                }
                absorbed.append(occurrence)
                if absorbed.count > Self.maxAbsorbedOccurrenceIDs {
                    absorbed.removeFirst(absorbed.count - Self.maxAbsorbedOccurrenceIDs)
                }
            } else if let duplicate = lines.lastIndex(where: { Self.id(of: $0.row) == id }) {
                // No occurrence identity: fall back to the card-id rule.
                return (InformationalRollupResult(
                    inserted: false,
                    cardID: existingID,
                    occurrenceCount: Self.recordedOccurrenceCount(lines[duplicate].row)
                ), false)
            }

            let increment = priorCount.addingReportingOverflow(1)
            guard !increment.overflow, increment.partialValue < Int.max else {
                throw NSError(domain: "NotificationInbox", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Inbox occurrence count exhausted for \(existingID); saved rows preserved."])
            }
            let nextCount = increment.partialValue
            var replacement = incoming
            replacement["id"] = .string(existingID)
            replacement["informational_rollup_key"] = .string(key)
            replacement["occurrence_count"] = .int(Int64(nextCount))
            if !absorbed.isEmpty {
                replacement["absorbed_occurrence_ids"] = .array(absorbed.map { .string($0) })
            }
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
            try Self.write(retaining: lines, to: path, now: now)
            return (InformationalRollupResult(
                inserted: false,
                cardID: existingID,
                occurrenceCount: nextCount
            ), true)
        }
        if result.written { invalidate() }
        return result.value
    }

    /// Set fields on the newest row `id` in one locked read-and-write; a null
    /// value removes its key. With `unlessPresent`, nothing is written when the
    /// row already has that key: the check is the claim. True when written.
    @discardableResult
    public func patch(id: String, unlessPresent: String? = nil, _ fields: [String: JSONValue]) async throws -> Bool {
        let now = Date()
        let changed = try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            guard let index = lines.lastIndex(where: { Self.id(of: $0.row) == id }),
                  case .object(var object)? = lines[index].row else { return false }
            if let unlessPresent, let held = object[unlessPresent], held != .null { return false }
            for (key, value) in fields { object[key] = value == .null ? nil : value }
            let row = JSONValue.object(object)
            lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
            try Self.write(retaining: lines, to: path, now: now)
            return true
        }
        if changed { invalidate() }
        return changed
    }

    /// Accepting one way out must not erase another held transport.
    public func settleHeldDelivery(id: String, way: String) async throws {
        let now = Date()
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var lines = try Self.readLines(self.path)
            guard let index = lines.lastIndex(where: { Self.id(of: $0.row) == id }),
                  case .object(var object)? = lines[index].row,
                  case .array(let ways)? = object["held_delivery"], ways.contains(.string(way)) else { return }
            let remaining = ways.filter { $0 != .string(way) }
            object["held_delivery"] = remaining.isEmpty ? nil : .array(remaining)
            let row = JSONValue.object(object)
            lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
            try Self.write(retaining: lines, to: self.path, now: now)
        }
        invalidate()
    }

    /// `metadata` lands on the row with the status (who settled it and why).
    @discardableResult
    public func updateStatus(
        id: String, status: String, readAt: String?, metadata: [String: JSONValue] = [:]
    ) async throws -> Bool {
        let now = Date()
        let result = try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> (handled: Bool, written: Bool) in
            var lines = try Self.readLines(path)
            // The newest row is the card on screen. A producer that re-files a
            // settled card appends a fresh row under the same id, and settling
            // the oldest one instead left the visible card unread.
            guard let index = lines.lastIndex(where: { Self.id(of: $0.row) == id }),
                  case .object(var object)? = lines[index].row else { return (false, false) }
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
            // Retention ages finished history from `read_at`. Stamp a new
            // terminal transition now, even if the card was read long ago.
            // Repeated requests for the same state preserve its timestamp.
            let stamp: String? = Self.isTerminal(status)
                ? (existingStatus != status || !hasReadTimestamp ? Self.iso8601(now) : nil)
                : readAt
            if existingStatus == status, stamp == nil || hasReadTimestamp, metadata.isEmpty {
                return (true, false)
            }
            object["status"] = .string(status)
            if let stamp { object["read_at"] = .string(stamp) }
            for (key, value) in metadata { object[key] = value }
            let row = JSONValue.object(object)
            lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
            try Self.write(retaining: lines, to: path, now: now)
            return (true, true)
        }
        if result.written { invalidate() }
        return result.handled
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
        return try await archiveActive(readAt: readAt) { lines in
            lines.indices.filter { index in
                guard case .object(let object)? = lines[index].row,
                      let id = Self.id(of: lines[index].row),
                      targets.contains(id),
                      object["severity"]?.stringValue?.lowercased() == "info",
                      (object["status"]?.stringValue?.lowercased() ?? "unread") == "unread"
                else { return false }
                return true
            }
        }
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
        // Unchanged cached rows can prove there are no active targets.
        if let rows = try? rows(), !rows.contains(where: {
            Line(raw: Data(), row: $0).isActive && Self.id(of: $0).map(targets.contains) == true
        }) {
            return 0
        }
        return try await archiveActive(readAt: readAt, metadata: metadata) { lines in
            lines.indices.filter { index in
                guard lines[index].isActive,
                      case .object(let object)? = lines[index].row,
                      let id = Self.id(of: lines[index].row), targets.contains(id) else { return false }
                if let createdNoLaterThan {
                    guard let rawCreated = object["created_at"]?.stringValue,
                          let created = Self.parseISO8601(rawCreated),
                          created <= createdNoLaterThan else { return false }
                }
                return true
            }
        }
    }

    /// Archives selected statuses except the nominated id, or the newest row
    /// per group when no id is nominated, under the inbox's rewrite lock.
    @discardableResult
    public func archiveSupersededRows(
        source: String,
        groupField: String,
        keeping keepItemId: String? = nil,
        readAt: String? = nil,
        statusIsEligible: @escaping @Sendable (String) -> Bool
    ) async throws -> Int {
        guard !source.isEmpty, !groupField.isEmpty else { return 0 }
        return try await archiveActive(readAt: readAt) { lines in
            var latestByGroup: [String: Int] = [:]
            for index in lines.indices {
                guard case .object(let object)? = lines[index].row,
                      object["source"]?.stringValue == source,
                      let group = object[groupField]?.stringValue, !group.isEmpty else { continue }
                latestByGroup[group] = index
            }
            return lines.indices.filter { index in
                guard case .object(let object)? = lines[index].row,
                      object["source"]?.stringValue == source,
                      let group = object[groupField]?.stringValue,
                      statusIsEligible(object["status"]?.stringValue ?? ""),
                      !(keepItemId.map { object["id"]?.stringValue == $0 }
                        ?? (latestByGroup[group] == index)) else { return false }
                return true
            }
        }
    }

    /// Selection and archival share one locked physical snapshot and retention write.
    private func archiveActive(
        readAt: String?, metadata: [String: JSONValue] = [:],
        selecting: @escaping @Sendable ([Line]) -> [Int]
    ) async throws -> Int {
        let now = Date()
        let changed = try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Int in
            var lines = try Self.readLines(path)
            var changed = 0
            for index in selecting(lines) {
                guard case .object(var object)? = lines[index].row else { continue }
                object["status"] = .string("archived")
                if let readAt { object["read_at"] = .string(readAt) }
                for (key, value) in metadata { object[key] = value }
                let row = JSONValue.object(object)
                lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
                changed += 1
            }
            if changed > 0 { try Self.write(retaining: lines, to: path, now: now) }
            return changed
        }
        if changed > 0 { invalidate() }
        return changed
    }

    private func invalidate() {
        cachedStamp = nil
        cachedRows = nil
    }

    /// The two retention bounds, in order: age out finished history, then hold
    /// the survivors to the hard cap. Pure — the caller performs the IO.
    private static func retention(_ lines: [Line], now: Date) -> RetentionPlan {
        var evicted = Set<Int>()
        var budget = maxPrunedRowsPerPass

        // 1. Terminal rows past the age cutoff, oldest first (file order is
        //    append order). Active cards and malformed lines are never eligible,
        //    and neither is a row whose timestamps will not parse — an
        //    unreadable stamp is not evidence of age.
        let cutoff = now.addingTimeInterval(-terminalRetentionSeconds)
        for index in lines.indices {
            guard budget > 0 else { break }
            guard !lines[index].hasHeldDelivery, lines[index].isTerminal,
                  let finished = lines[index].retentionStamp,
                  finished < cutoff else { continue }
            evicted.insert(index)
            budget -= 1
        }

        // 2. The hard cap over what is left. Newest active/actionable cards take
        //    the budget first; the rest goes to newest terminal history and
        //    malformed physical lines, which are never silently "cleaned up" —
        //    they land on the shelf like anything else.
        // Outstanding deliveries must stay live for their release owner.
        let survivors = lines.indices.filter { !evicted.contains($0) && !lines[$0].hasHeldDelivery }
        if survivors.count > rowLimit {
            var kept = Set<Int>()
            for index in survivors.reversed() where lines[index].isActive {
                guard kept.count < rowLimit else { break }
                kept.insert(index)
            }
            if kept.count < rowLimit {
                for index in survivors.reversed() where !kept.contains(index) {
                    guard kept.count < rowLimit else { break }
                    kept.insert(index)
                }
            }
            // Oldest overflow leaves first, still inside this pass's budget.
            for index in survivors where !kept.contains(index) {
                guard budget > 0 else { break }
                evicted.insert(index)
                budget -= 1
            }
        }

        guard !evicted.isEmpty else { return RetentionPlan(kept: lines, evicted: []) }

        // `rows()` fails closed on a file that holds bytes but no parseable row,
        // because that shape means corruption, not an empty inbox. Retention
        // must never manufacture it: on a feed of malformed lines plus aged
        // history, keep the newest parsed row so the reader still has one.
        if lines.contains(where: { $0.row != nil }),
           !lines.indices.contains(where: { !evicted.contains($0) && lines[$0].row != nil }),
           let newestParsed = lines.indices.reversed().first(where: { lines[$0].row != nil }) {
            evicted.remove(newestParsed)
        }

        return RetentionPlan(
            kept: lines.indices.compactMap { evicted.contains($0) ? nil : lines[$0] },
            evicted: lines.indices.compactMap { evicted.contains($0) ? lines[$0] : nil }
        )
    }

    /// Shelf the overflow, then write the retained feed. The shelf append comes
    /// FIRST and is allowed to throw: a shelf that cannot be written is a reason
    /// to abandon the write, never a reason to drop the rows anyway.
    private static func write(retaining lines: [Line], to path: URL, now: Date) throws {
        try validateCounts(lines)
        let plan = retention(lines, now: now)
        if !plan.evicted.isEmpty {
            try appendToArchive(plan.evicted, forInbox: path)
        }
        try writeRaw(plan.kept, to: path)
    }

    /// Append evicted physical lines to the uncapped shelf, byte-for-byte. Runs
    /// under the inbox flock the caller already holds, so concurrent producers
    /// cannot interleave a partial batch.
    private static func appendToArchive(_ lines: [Line], forInbox path: URL) throws {
        var payload = Data()
        payload.reserveCapacity(lines.reduce(0) { $0 + $1.raw.count + 1 })
        for line in lines {
            payload.append(line.raw)
            payload.append(0x0A)
        }
        try SwiftNativePersistenceCore.appendLines(payload, to: archivePath(forInbox: path))
    }

    private static func id(of row: JSONValue?) -> String? {
        guard case .object(let object)? = row,
              case .string(let id)? = object["id"] else { return nil }
        return id
    }

    /// A row's recorded occurrence count, floored at 1 — a plain card that has
    /// never rolled up carries no count and stands for one occurrence.
    private static func recordedOccurrenceCount(_ row: JSONValue?) -> Int {
        guard case .object(let object)? = row else { return 1 }
        return max(1, int(object["occurrence_count"]) ?? 1)
    }

    private static func int(_ value: JSONValue?) -> Int? {
        guard case .int(let value)? = value, let result = Int(exactly: value) else { return nil }
        return result
    }

    /// Match producer timestamps with fractional-second ISO 8601 in UTC.
    private static func iso8601(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }

    private static func isTerminal(_ status: String) -> Bool {
        status == "archived" || status == "dismissed"
    }

    private static func parseISO8601(_ value: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(value)
    }

    public static func readLines(_ path: URL) throws -> [Line] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [] }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { Data($0) }
        if parts.last?.isEmpty == true { parts.removeLast() }
        let lines = parts.map { Line(raw: $0, row: try? JSONValue.parse($0)) }
        try validateCounts(lines)
        return lines
    }

    private static func validateCounts(_ lines: [Line]) throws {
        for (index, line) in lines.enumerated() {
            guard case .object(let fields)? = line.row, let raw = fields["occurrence_count"] else { continue }
            guard case .int(let count) = raw, count > 0, count < Int.max else {
                throw NSError(domain: "NotificationInbox", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Inbox row \(index) has an invalid occurrence_count; saved bytes preserved."])
            }
        }
    }

    /// Whole-file callers hold the inbox flock and preserve untouched physical
    /// lines. They use the same retention/archive boundary as actor mutations.
    public static func write(_ lines: [Data], to path: URL) throws {
        try write(retaining: lines.map { Line(raw: $0, row: try? JSONValue.parse($0)) },
                  to: path, now: Date())
    }

    private static func writeRaw(_ lines: [Line], to path: URL) throws {
        var payload = Data()
        payload.reserveCapacity(lines.reduce(0) { $0 + $1.raw.count + 1 })
        for line in lines {
            payload.append(line.raw)
            payload.append(0x0A)
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(payload, to: path)
    }

}
