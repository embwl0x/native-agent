import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LiveNotificationInbox.swift` | Checked canonical cards and source revisions under the inbox flock; background intent admission binds current content, retention reads outstanding delivery ledger rows, and independent scans preserve named gaps |

/// Single file owner for the live macOS notification inbox.
///
/// The log stays interoperable JSONL, but reads reuse a parsed snapshot until
/// the file identity changes and every mutation is serialized by the canonical
/// PersistenceCore flock. Retention protects active cards first and uses the
/// remaining budget for recent history. Every physical line must read as a
/// current card before a complete snapshot or whole-feed mutation is usable;
/// a damaged line reports its position/cause and leaves the saved bytes alone.
///
/// Every write applies age and row bounds:
///   * terminal (`archived`/`dismissed`) rows finished with (`read_at`, else
///     `created_at`) more than `terminalRetentionSeconds` ago are pruned,
///     oldest first;
///   * rows with outstanding `held_delivery` destinations are exempt from both
///     limits until their delivery owner settles them;
///   * other survivors converge to `rowLimit`, newest-active-first.
/// Active/unread cards are never age-pruned — only the row budget can reach them,
/// and only once the unheld active set alone exceeds it. Each pass evicts at most
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
    /// Target for unheld physical lines, reached over bounded mutation passes.
    /// Held deliveries are additional rows and can exceed this target indefinitely.
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
            "title": .string(String(title.prefix(160))), "summary": .string(String(body.prefix(500))), "actions": .array([]),
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
            guard case .string(let status)? = object["status"] else { return false }
            return status != "archived" && status != "dismissed"
        }

        /// A parsed row the user has finished with. Defined as the complement of
        /// `isActive` over parsed rows, so the two can never disagree about a
        /// status string. Retention only receives checked cards.
        var isTerminal: Bool {
            guard case .object? = row else { return false }
            return !isActive
        }

        /// When this row's retention clock started. For a terminal row that is
        /// when the user finished with it (`read_at`), NOT when it was created:
        /// a card raised in June and archived today is fresh history, and
        /// pruning it the instant it was archived would make the archive button
        /// look like a delete button. A card with no disposition time uses its
        /// creation time; both timestamps are checked at the card boundary.
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

    public nonisolated let path: URL
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

    /// Complete checked rows in file order. One unreadable physical line/card
    /// makes completeness unavailable, never a healthy shorter or empty inbox.
    public func rows() throws -> [JSONValue] {
        guard let stamp = SnapshotTailOpLog.fileStamp(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path.path])
        }
        if stamp == cachedStamp, let cachedRows { return cachedRows }
        let lines = try Self.readLines(path)
        let parsed = lines.compactMap(\.row)
        cachedStamp = stamp
        cachedRows = parsed
        return parsed
    }

    /// Addressed reads do not require a complete feed. Decode the named card
    /// strictly; a sibling's schema damage cannot disable this card.
    public func item(id: String) throws -> InboxItemRecord? {
        guard let row = try row(id: id) else { return nil }
        return try InboxItemRecord(row: row)
    }

    /// Retains owner-only delivery fields alongside the strictly checked card.
    public func row(id: String) throws -> JSONValue? {
        let lines = try Self.physicalLines(path)
        var unreadable: Error?
        for (index, raw) in lines.enumerated().reversed() {
            let row: JSONValue
            do { row = try JSONValue.parse(raw) }
            catch { unreadable = Self.unreadableLine(index, path: path, cause: error); continue }
            guard row.objectValue?["id"] == .string(id) else { continue }
            do { _ = try InboxItemRecord(row: row); return row }
            catch { throw Self.unreadableLine(index, path: path, cause: error) }
        }
        // A line whose identity cannot be read may be the requested card.
        if let unreadable { throw unreadable }
        return nil
    }

    /// A scan whose items are independent, with a named failure for each gap.
    /// Unlike rows(), this never claims a complete healthy snapshot.
    public func cardReads() throws -> [Result<InboxItemRecord, Error>] {
        try Self.physicalLines(path).enumerated().map { index, raw in
            do { return .success(try InboxItemRecord(row: JSONValue.parse(raw))) }
            catch { return .failure(Self.unreadableLine(index, path: path, cause: error)) }
        }
    }

    private static func physicalLines(_ path: URL) throws -> [Data] {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        guard !data.isEmpty else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
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
        _ = try InboxItemRecord(row: row)
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
            _ = try InboxItemRecord(row: result.row)
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
        _ = try InboxItemRecord(row: row)
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
            let previous = object
            for (key, value) in fields { object[key] = value == .null ? nil : value }
            guard object != previous else { return false }
            let row = JSONValue.object(object)
            lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
            try Self.write(retaining: lines, to: path, now: now)
            return true
        }
        if changed { invalidate() }
        return changed
    }

    /// Commit a background knock on the current canonical card BEFORE any
    /// transport admission. Return its committed revision for admission; the
    /// producer's notification words may differ from the card's summary.
    public func retainAttentionIntent(id: String, title: String, body: String, reason: String,
                                      importance: String, userInfo: [String: String], honorsQuietHours: Bool) async throws -> String {
        let result = try await SwiftNativePersistenceCore.withFileLock(path, waitingAtMost: 5) { () async throws -> (written: Bool, revision: String) in
            var lines = try Self.readLines(path)
            guard let index = lines.lastIndex(where: { Self.id(of: $0.row) == id }),
                  var row = lines[index].row?.objectValue,
                  row["status"] != .string("archived"), row["status"] != .string("dismissed") else {
                throw ToolFailureError("Notification source card is settled or unavailable; the knock was not admitted.", effects: .none, owner: path.path)
            }
            let previous = row
            row["held_delivery"] = .array([.string("phone")])
            row["held_event_id"] = .string("inbox:" + id)
            row["held_title"] = .string(title); row["held_body"] = .string(body)
            row["held_reason"] = .string(reason); row["held_importance"] = .string(importance)
            row["held_honors_quiet_hours"] = .bool(honorsQuietHours)
            row["held_user_info"] = .object(userInfo.mapValues(JSONValue.string))
            guard row != previous else {
                return (written: false, revision: try Self.notificationRevision(.object(row)))
            }
            let value = JSONValue.object(row)
            lines[index] = Line(raw: try value.serializedData(pretty: false), row: value)
            try Self.write(retaining: lines, to: path, now: Date())
            // The source writer stamps the revision. Read that exact committed
            // identity while still holding its lock, never infer it from words.
            guard let committed = try Self.readLines(path).last(where: { Self.id(of: $0.row) == id })?.row else {
                throw ToolFailureError("Notification intent was not retained on its source card; nothing was sent.", effects: .none, owner: path.path)
            }
            return (written: true, revision: try Self.notificationRevision(committed))
        }
        if result.written { invalidate() }
        return result.revision
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
    /// the unheld survivors toward the row target. Pure — the caller performs the IO.
    private static func retention(_ lines: [Line], now: Date, held: Set<Int>) -> RetentionPlan {
        var evicted = Set<Int>()
        var budget = maxPrunedRowsPerPass

        // 1. Terminal rows past the age cutoff, oldest first (file order is
        //    append order). Active cards and held deliveries are never eligible.
        let cutoff = now.addingTimeInterval(-terminalRetentionSeconds)
        for index in lines.indices {
            guard budget > 0 else { break }
            guard !held.contains(index), lines[index].isTerminal,
                  let finished = lines[index].retentionStamp,
                  finished < cutoff else { continue }
            evicted.insert(index)
            budget -= 1
        }

        // 2. The row target over unheld survivors. Newest active cards take
        //    the budget first; the rest goes to newest terminal history.
        // Outstanding deliveries must stay live for their release owner.
        let survivors = lines.indices.filter { !evicted.contains($0) && !held.contains($0) }
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

        return RetentionPlan(
            kept: lines.indices.compactMap { evicted.contains($0) ? nil : lines[$0] },
            evicted: lines.indices.compactMap { evicted.contains($0) ? lines[$0] : nil }
        )
    }

    /// Shelf the overflow, then write the retained feed. The shelf append comes
    /// FIRST and is allowed to throw: a shelf that cannot be written is a reason
    /// to abandon the write, never a reason to drop the rows anyway.
    private static func write(retaining lines: [Line], to path: URL, now: Date) throws {
        try validateCards(lines, path: path)
        let ledger = try NotificationDeliveryLedger(dataRoot: path.deletingLastPathComponent().deletingLastPathComponent()).read()
        let byCard = Dictionary(grouping: ledger.entries.values.filter { $0.occurrence.cardID != nil }, by: { $0.occurrence.cardID! })
        var held = Set<Int>()
        for (index, line) in lines.enumerated() {
            guard let row = line.row?.objectValue else { continue }
            if let id = row["notification_occurrence_id"]?.stringValue {
                if let entry = ledger.entries[id] {
                    if entry.supersededBy == nil && entry.rows.values.contains(where: { !$0.outcome.settled }) { held.insert(index) }
                } else { held.insert(index) } // Missing evidence never releases an intent.
            } else if row["held_delivery"]?.arrayValue?.isEmpty == false, let id = row["id"]?.stringValue {
                let revision = try notificationRevision(.object(row))
                let matches = (byCard[id] ?? []).filter { $0.occurrence.sourceRevision == revision }
                if matches.isEmpty || matches.contains(where: { $0.supersededBy == nil && $0.rows.values.contains { !$0.outcome.settled } }) { held.insert(index) }
            }
        }
        let plan = retention(lines, now: now, held: held)
        if !plan.evicted.isEmpty {
            try appendToArchive(plan.evicted, forInbox: path)
        }
        // Revision belongs to the card's source owner, not a delivery snapshot.
        // Disposition-only writes retain it; A → B → A receives a fresh revision.
        let prior = try readLines(path)
        var previous: [String: [String: JSONValue]] = [:]
        for line in prior {
            if let row = line.row?.objectValue, let id = row["id"]?.stringValue { previous[id] = row }
        }
        let stamped = try plan.kept.map { line -> Line in
            guard var row = line.row?.objectValue, let id = row["id"]?.stringValue else { return line }
            let old = previous[id]
            let revision: String
            if let old, notificationContent(old) == notificationContent(row) {
                revision = try notificationRevision(.object(old))
            } else { revision = UUID().uuidString.lowercased() }
            row["notification_revision"] = .string(revision)
            let value = JSONValue.object(row)
            return Line(raw: try value.serializedData(pretty: false), row: value)
        }
        try writeRaw(stamped, to: path)
    }

    /// Retained unstamped cards use their exact content identity until their
    /// next source mutation stamps it. An unrelated write cannot invent a new
    /// occurrence for an already consumed intent.
    public nonisolated static func notificationRevision(_ value: JSONValue) throws -> String {
        guard let row = value.objectValue else { throw CocoaError(.fileReadCorruptFile) }
        if let saved = row["notification_revision"] {
            guard let revision = saved.stringValue, !revision.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return revision
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return NotificationOccurrence.digest(try encoder.encode(notificationContent(row)))
    }

    private static func notificationContent(_ row: [String: JSONValue]) -> [String: JSONValue] {
        row.filter { key, _ in
            key != "notification_revision" && key != "status" && key != "read_at" && key != "actions" && key != "created_at"
                && key != "held_mac_dispatch"
        }
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
        let parts = try physicalLines(path)
        let lines = try parts.enumerated().map { index, raw in
            do { return Line(raw: raw, row: try JSONValue.parse(raw)) }
            catch { throw unreadableLine(index, path: path, cause: error) }
        }
        try validateCards(lines, path: path)
        return lines
    }

    private static func validateCards(_ lines: [Line], path: URL) throws {
        for (index, line) in lines.enumerated() {
            do {
                guard let row = line.row else { throw JSONRow.Malformed.notAnObject }
                _ = try InboxItemRecord(row: row)
            } catch {
                throw unreadableLine(index, path: path, cause: error)
            }
        }
    }

    private static func unreadableLine(_ index: Int, path: URL, cause: Error) -> NSError {
        NSError(domain: "NotificationInbox", code: 1, userInfo: [
            NSFilePathErrorKey: path.path, NSUnderlyingErrorKey: cause,
            NSLocalizedDescriptionKey: "Inbox \(path.lastPathComponent) line \(index + 1) is unreadable: \(cause.localizedDescription). "
                + "The complete inbox is unavailable; saved bytes preserved. Repair this row before using a complete read or rewriting the feed."
        ])
    }

    /// Whole-file callers hold the inbox flock and preserve untouched physical
    /// lines. They use the same retention/archive boundary as actor mutations.
    public static func write(_ lines: [Data], to path: URL) throws {
        try write(retaining: lines.map { Line(raw: $0, row: try JSONValue.parse($0)) },
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
