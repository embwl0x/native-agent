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
///
/// RETENTION (2026-08-31). The feed had a cap and no age dimension: a
/// `rowLimit` of 1,000 never bound a file that had reached 671 rows in 88 days,
/// so 86% terminal rows carrying multi-KB detail blobs were retained forever.
/// Two bounds now run on every write:
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
/// back with `archivedRows()`) BEFORE the trimmed feed is written, mirroring
/// the studio journal. A shelf that cannot be written aborts the whole write.
public actor LiveNotificationInbox {
    /// Hard bound on physical lines in the live feed. Sized like the other hot
    /// feeds in the repo (chat receipts cap at 500) so it actually binds: the
    /// live file sat at 671 rows under the old 1,000.
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

    /// The uncapped overflow shelf that retention moves rows onto, beside the
    /// feed it belongs to. Never trimmed — it is where "archived" stops meaning
    /// "deleted with a nicer word".
    public static func archivePath(forInbox path: URL) -> URL {
        path.deletingLastPathComponent()
            .appendingPathComponent("inbox_archive.jsonl")
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

        /// A parsed row the user has finished with. Defined as the complement of
        /// `isActive` over parsed rows, so the two can never disagree about a
        /// status string. A malformed physical line is neither: corrupt bytes
        /// are carried through, never aged out.
        var isTerminal: Bool {
            guard case .object? = row else { return false }
            return !isActive
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
    private let persistence = SwiftNativePersistenceCore()
    private let clock: @Sendable () -> Date
    private var cachedStamp: Stamp?
    private var cachedRows: [JSONValue]?

    public init(path: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path
        self.clock = clock
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

    /// Rows retention moved off the live feed, oldest first. Uncached and
    /// unbounded — this is history, read on demand, not part of the hot feed a
    /// UI renders. A missing shelf is an empty history, not an error, and a
    /// malformed shelf line is skipped rather than failing the whole read: the
    /// feed's own fail-closed rule exists to stop an apparently-empty INBOX,
    /// and the shelf can never be mistaken for one.
    public func archivedRows() throws -> [JSONValue] {
        try Self.readLines(Self.archivePath(forInbox: path)).compactMap(\.row)
    }

    /// Append once by stable id. The scan and append happen under one flock, so
    /// retries from approval/execution staging cannot create duplicate cards.
    @discardableResult
    public func appendUnique(_ row: JSONValue, id: String) async throws -> Bool {
        let now = clock()
        let inserted = try await persistence.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            if lines.contains(where: { Self.id(of: $0.row) == id }) { return false }
            lines.append(Line(raw: Data(try row.serialize(pretty: false).utf8), row: row))
            try Self.write(retaining: lines, to: path, now: now)
            return true
        }
        invalidate()
        return inserted
    }

    /// Append one card unless a producer-supplied check finds an equivalent one
    /// already live. The check and the append share this feed's single flock —
    /// the same guarantee the caller previously built by hand around a raw
    /// capped append — so two concurrent producers cannot both pass the check
    /// and double-card. The check runs against this feed's file, so it must not
    /// take that lock itself.
    ///
    /// Returns the existing card's id when the append was suppressed, nil when
    /// the row was written.
    public func appendUnlessDuplicate(
        _ row: JSONValue,
        duplicateID: @escaping @Sendable () -> String?
    ) async throws -> String? {
        let now = clock()
        let existing = try await persistence.withFileLock(path) { () async throws -> String? in
            if let existing = duplicateID() { return existing }
            var lines = try Self.readLines(path)
            lines.append(Line(raw: Data(try row.serialize(pretty: false).utf8), row: row))
            try Self.write(retaining: lines, to: path, now: now)
            return nil
        }
        invalidate()
        return existing
    }

    /// Replace a stable card or append it when absent. Used for notices whose
    /// identity survives content changes without accumulating duplicates.
    @discardableResult
    public func upsert(_ row: JSONValue, id: String) async throws -> Bool {
        let now = clock()
        let inserted = try await persistence.withFileLock(path) { () async throws -> Bool in
            var lines = try Self.readLines(path)
            let raw = Data(try row.serialize(pretty: false).utf8)
            if let index = lines.firstIndex(where: { Self.id(of: $0.row) == id }) {
                lines[index] = Line(raw: raw, row: row)
                try Self.write(retaining: lines, to: path, now: now)
                return false
            }
            lines.append(Line(raw: raw, row: row))
            try Self.write(retaining: lines, to: path, now: now)
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
              Self.string(incoming["severity"])?.lowercased() == "info",
              !key.isEmpty else {
            let inserted = try await appendUnique(row, id: id)
            return InformationalRollupResult(inserted: inserted, cardID: id, occurrenceCount: 1)
        }

        let now = clock()
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
                // Creating the card is append-once by card id, as it always was.
                if let duplicate = lines.lastIndex(where: { Self.id(of: $0.row) == id }) {
                    return InformationalRollupResult(
                        inserted: false,
                        cardID: id,
                        occurrenceCount: Self.recordedOccurrenceCount(lines[duplicate].row)
                    )
                }
                var inserted = incoming
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
                return InformationalRollupResult(inserted: true, cardID: id, occurrenceCount: 1)
            }

            let existingID = Self.string(existing["id"]) ?? id
            let priorCount = max(1, Self.int(existing["occurrence_count"]) ?? 1)
            var absorbed = Self.stringArray(existing["absorbed_occurrence_ids"])

            // Is this write a NEW occurrence, or the same one arriving twice?
            if let occurrence {
                guard !absorbed.contains(occurrence) else {
                    return InformationalRollupResult(
                        inserted: false, cardID: existingID, occurrenceCount: priorCount
                    )
                }
                absorbed.append(occurrence)
                if absorbed.count > Self.maxAbsorbedOccurrenceIDs {
                    absorbed.removeFirst(absorbed.count - Self.maxAbsorbedOccurrenceIDs)
                }
            } else if let duplicate = lines.lastIndex(where: { Self.id(of: $0.row) == id }) {
                // No occurrence identity: fall back to the card-id rule.
                return InformationalRollupResult(
                    inserted: false,
                    cardID: existingID,
                    occurrenceCount: Self.recordedOccurrenceCount(lines[duplicate].row)
                )
            }

            let nextCount = priorCount + 1
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
        let now = clock()
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
            // Retention ages finished history from `read_at`. A caller that
            // retires a card without supplying one (the Mac archive/dismiss
            // actions pass nil) would otherwise leave the row dated only by
            // `created_at` — and a months-old card archived today would be
            // pruned by the very write that archived it. Stamp the transition
            // instead, exactly as `archiveActive` already does.
            let stamp: String? = readAt
                ?? (Self.isTerminal(status) && !hasReadTimestamp ? Self.iso8601(now) : nil)
            if existingStatus == status, stamp == nil || hasReadTimestamp {
                return true
            }
            object["status"] = .string(status)
            if let stamp { object["read_at"] = .string(stamp) }
            let row = JSONValue.object(object)
            lines[index] = Line(raw: Data(try row.serialize(pretty: false).utf8), row: row)
            try Self.write(retaining: lines, to: path, now: now)
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
        let now = clock()
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
                try Self.write(retaining: lines, to: path, now: now)
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
        let now = clock()
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
            if changed > 0 { try Self.write(retaining: lines, to: path, now: now) }
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
        let now = clock()
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
            try Self.write(retaining: lines, to: path, now: now)
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
        let now = clock()
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
            guard lines[index].isTerminal,
                  let finished = lines[index].retentionStamp,
                  finished < cutoff else { continue }
            evicted.insert(index)
            budget -= 1
        }

        // 2. The hard cap over what is left. Newest active/actionable cards take
        //    the budget first; the rest goes to newest terminal history and
        //    malformed physical lines, which are never silently "cleaned up" —
        //    they land on the shelf like anything else.
        let survivors = lines.indices.filter { !evicted.contains($0) }
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
        let plan = retention(lines, now: now)
        if !plan.evicted.isEmpty {
            try appendToArchive(plan.evicted, forInbox: path)
        }
        try write(plan.kept, to: path)
    }

    /// Append evicted physical lines to the uncapped shelf, byte-for-byte. Runs
    /// under the inbox flock the caller already holds, so concurrent producers
    /// cannot interleave a partial batch.
    private static func appendToArchive(_ lines: [Line], forInbox path: URL) throws {
        let archive = archivePath(forInbox: path)
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var payload = Data()
        payload.reserveCapacity(lines.reduce(0) { $0 + $1.raw.count + 1 })
        for line in lines {
            payload.append(line.raw)
            payload.append(0x0A)
        }
        guard FileManager.default.fileExists(atPath: archive.path) else {
            try payload.write(to: archive, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: archive.path
            )
            return
        }
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
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

    private static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { element in
            guard case .string(let text) = element else { return nil }
            return text
        }
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

    /// The spelling the newest live rows already use
    /// (`2026-08-31T17:39:23.876Z`), so a stamped `read_at` is indistinguishable
    /// from one a producer wrote.
    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func isTerminal(_ status: String) -> Bool {
        status == "archived" || status == "dismissed"
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
