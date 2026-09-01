import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NotificationInbox

// Ledger rows: notifications.live.retention
//
// The live feed (`data/notifications/inbox.jsonl`) reached 671 rows / 1.5 MB in
// 88 days with 86% of rows in a terminal state, because the ONLY bound was a
// 1,000-row cap that had never once bound. These tests pin the two bounds that
// replaced it and the shelf that keeps them from being a delete:
//
//   * SILENT LOSS — retention that hard-deleted user-visible history would look
//     identical to retention that works, until someone went looking for a card.
//     Every eviction is asserted byte-for-byte on `inbox_archive.jsonl`.
//   * SILENT NO-OP — a cap or cutoff that never fires is the original bug. The
//     cap test runs at the live file's real scale.
//   * UNBOUNDED PASS — a backlog must drain over several locked writes, not one
//     scan-rewrite of the whole file.

private let day: TimeInterval = 24 * 60 * 60

/// Fixed "now" for every test here, so a cutoff is never wall-clock dependent.
private let fixedNow = Date(timeIntervalSince1970: 1_788_000_000)

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func retentionFixture(
    _ id: String,
    status: String,
    ageDays: Double,
    detail: String = "fixture"
) -> JSONValue {
    .object([
        "id": .string(id),
        "created_at": .string(iso(fixedNow.addingTimeInterval(-ageDays * day))),
        "source": .string("test"),
        "severity": .string("info"),
        "title": .string(id),
        "summary": .string("fixture"),
        "detail": .string(detail),
        "actions": .array([]),
        "status": .string(status),
        "read_at": .null,
    ])
}

private func retentionInboxPath() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("live-inbox-retention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("inbox.jsonl")
}

/// Seed physical lines directly, returning the exact bytes written per row so a
/// test can prove the shelf preserved them.
@discardableResult
private func seed(_ rows: [JSONValue], at path: URL) throws -> [Data] {
    var payload = Data()
    var lines: [Data] = []
    for row in rows {
        let line = Data(try row.serialize(pretty: false).utf8)
        lines.append(line)
        payload.append(line)
        payload.append(0x0A)
    }
    try payload.write(to: path)
    return lines
}

private func physicalLines(of path: URL) throws -> [Data] {
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    var parts = try Data(contentsOf: path)
        .split(separator: 0x0A, omittingEmptySubsequences: false)
        .map { Data($0) }
    if parts.last?.isEmpty == true { parts.removeLast() }
    return parts
}

private func ids(_ rows: [JSONValue]) -> [String] {
    rows.compactMap {
        guard case .object(let object) = $0,
              case .string(let id)? = object["id"] else { return nil }
        return id
    }
}

private func fixedClockInbox(_ path: URL) -> LiveNotificationInbox {
    LiveNotificationInbox(path: path, clock: { fixedNow })
}

@Test("terminal rows past the cutoff move to the shelf with their bytes intact")
func liveInboxPrunesAgedTerminalRowsOntoTheShelf() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    let aged = (0..<6).map { index in
        retentionFixture(
            "aged-\(index)",
            status: index.isMultiple(of: 2) ? "archived" : "dismissed",
            ageDays: 40 + Double(index),
            detail: String(repeating: "x", count: 512)
        )
    }
    let recentTerminal = [retentionFixture("recent-archived", status: "archived", ageDays: 3)]
    let active = [retentionFixture("live", status: "unread", ageDays: 50)]
    let written = try seed(aged + recentTerminal + active, at: path)

    let inbox = fixedClockInbox(path)
    #expect(try await inbox.appendUnique(
        retentionFixture("fresh", status: "unread", ageDays: 0), id: "fresh"
    ))

    #expect(ids(try await inbox.rows()) == ["recent-archived", "live", "fresh"],
            "a terminal row inside the retention window must not be pruned")

    // The shelf holds the evicted lines verbatim, in file order.
    #expect(try physicalLines(of: inbox.archivePath) == Array(written.prefix(6)))
    #expect(ids(try await inbox.archivedRows()) == (0..<6).map { "aged-\($0)" })

    // A second pass with nothing left to prune must not touch the shelf.
    #expect(try await inbox.appendUnique(
        retentionFixture("fresh-2", status: "unread", ageDays: 0), id: "fresh-2"
    ))
    #expect(try physicalLines(of: inbox.archivePath).count == 6)
}

@Test("an active card is never aged out, however old it is")
func liveInboxNeverAgePrunesActiveCards() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    // `unread`, `read`, and a legacy row with no status at all are all active.
    var ancientNoStatus: [String: JSONValue] = [:]
    if case .object(let object) = retentionFixture("legacy", status: "unread", ageDays: 900) {
        ancientNoStatus = object
        ancientNoStatus.removeValue(forKey: "status")
    }
    try seed([
        retentionFixture("ancient-unread", status: "unread", ageDays: 900),
        retentionFixture("ancient-read", status: "read", ageDays: 900),
        .object(ancientNoStatus),
        retentionFixture("ancient-archived", status: "archived", ageDays: 900),
    ], at: path)

    let inbox = fixedClockInbox(path)
    #expect(try await inbox.updateStatus(
        id: "ancient-unread", status: "read", readAt: iso(fixedNow)
    ))

    #expect(ids(try await inbox.rows()) == ["ancient-unread", "ancient-read", "legacy"])
    #expect(ids(try await inbox.archivedRows()) == ["ancient-archived"])
}

@Test("archiving an ancient card keeps it — the clock starts when it is finished")
func liveInboxAgesFromWhenARowBecameTerminal() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    // A card raised months ago and archived just now is FRESH history. Ageing
    // it from `created_at` would prune it in the same write that archived it,
    // making the archive button behave like a delete button.
    try seed([
        retentionFixture("ancient", status: "unread", ageDays: 84),
        retentionFixture("ballast", status: "unread", ageDays: 1),
    ], at: path)

    let inbox = fixedClockInbox(path)
    #expect(try await inbox.archiveActive(ids: ["ancient"], readAt: iso(fixedNow)) == 1)

    let rows = try await inbox.rows()
    #expect(ids(rows) == ["ancient", "ballast"])
    guard case .object(let card)? = rows.first else {
        Issue.record("the just-archived card was pruned by the write that archived it")
        return
    }
    #expect(card["status"] == .string("archived"))
    #expect(try await inbox.archivedRows().isEmpty)
}

@Test("retiring a card with no timestamp stamps one instead of dating it by birth")
func liveInboxStampsATerminalTransitionThatCarriesNoTime() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    // The Mac archive/dismiss actions call `updateStatus` with readAt: nil. If
    // the transition went unstamped, retention would fall back to `created_at`
    // and the archive button would delete an old card outright.
    try seed([
        retentionFixture("ancient", status: "unread", ageDays: 84),
        retentionFixture("ballast", status: "unread", ageDays: 1),
    ], at: path)

    let inbox = fixedClockInbox(path)
    #expect(try await inbox.updateStatus(id: "ancient", status: "archived", readAt: nil))

    let rows = try await inbox.rows()
    #expect(ids(rows) == ["ancient", "ballast"])
    guard case .object(let card)? = rows.first else {
        Issue.record("an unstamped archive pruned the card it archived")
        return
    }
    #expect(card["status"] == .string("archived"))
    guard case .string(let stamped)? = card["read_at"] else {
        Issue.record("the terminal transition left no time to age the row from")
        return
    }
    #expect(stamped == iso(fixedNow))

    // A repeat of the same transition is still a no-op, not timestamp churn.
    #expect(try await inbox.updateStatus(id: "ancient", status: "archived", readAt: nil))
    let after = try await inbox.rows()
    guard case .object(let unchanged)? = after.first else { return }
    #expect(unchanged["read_at"] == .string(stamped))
}

@Test("a malformed physical line is carried through rather than aged out")
func liveInboxNeverAgesOutCorruptBytes() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    var payload = Data("{not-json}\n".utf8)
    payload.append(Data((
        try retentionFixture("aged", status: "archived", ageDays: 90)
            .serialize(pretty: false) + "\n"
    ).utf8))
    try payload.write(to: path)

    let inbox = fixedClockInbox(path)
    #expect(try await inbox.appendUnique(
        retentionFixture("fresh", status: "unread", ageDays: 0), id: "fresh"
    ))

    #expect(try physicalLines(of: path).first == Data("{not-json}".utf8))
    #expect(ids(try await inbox.archivedRows()) == ["aged"])
}

@Test("retention never leaves a feed of bytes with no readable row")
func liveInboxRetentionNeverManufacturesTheFailClosedShape() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    // Corrupt bytes plus history that is entirely past the cutoff. Evicting all
    // of it would leave a non-empty file with zero parseable rows — the exact
    // shape `rows()` refuses as corruption.
    var payload = Data("{not-json}\n".utf8)
    for index in 0..<4 {
        payload.append(Data((
            try retentionFixture("aged-\(index)", status: "archived", ageDays: 60)
                .serialize(pretty: false) + "\n"
        ).utf8))
    }
    try payload.write(to: path)

    let inbox = fixedClockInbox(path)
    #expect(try await inbox.updateStatus(
        id: "aged-0",
        status: "dismissed",
        readAt: iso(fixedNow.addingTimeInterval(-60 * day))
    ))

    #expect(ids(try await inbox.rows()) == ["aged-3"],
            "the newest readable row must survive a full-history prune")
    #expect(ids(try await inbox.archivedRows()) == ["aged-0", "aged-1", "aged-2"])
}

@Test("one pass prunes a bounded slice of a backlog and later passes drain it")
func liveInboxPrunesABoundedSlicePerPass() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    let backlog = LiveNotificationInbox.maxPrunedRowsPerPass * 2 + 50
    try seed(
        (0..<backlog).map {
            retentionFixture("old-\($0)", status: "archived", ageDays: 60 + Double($0) / 100)
        } + [retentionFixture("live", status: "unread", ageDays: 200)],
        at: path
    )

    let inbox = fixedClockInbox(path)
    #expect(try await inbox.appendUnique(
        retentionFixture("fresh", status: "unread", ageDays: 0), id: "fresh"
    ))

    let perPass = LiveNotificationInbox.maxPrunedRowsPerPass
    #expect(try await inbox.rows().count == backlog + 2 - perPass,
            "one locked write must not rewrite the whole backlog")
    #expect(try await inbox.archivedRows().count == perPass)
    // Oldest first: the head of the backlog is what left.
    #expect(ids(try await inbox.archivedRows()) == (0..<perPass).map { "old-\($0)" })

    #expect(try await inbox.appendUnique(
        retentionFixture("fresh-2", status: "unread", ageDays: 0), id: "fresh-2"
    ))
    #expect(try await inbox.rows().count == backlog + 3 - 2 * perPass)
    #expect(try await inbox.archivedRows().count == 2 * perPass,
            "the shelf accumulates across passes instead of being re-trimmed")
}

@Test("the hard cap binds at the live feed's real scale, newest active first")
func liveInboxCapBindsAtLiveScale() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    // The shape the live file actually had: 671 rows, 94 active, all inside the
    // 30-day window so ONLY the cap can act.
    var rows: [JSONValue] = []
    for index in 0..<577 {
        rows.append(retentionFixture("terminal-\(index)", status: "archived", ageDays: 20))
    }
    for index in 0..<94 {
        rows.append(retentionFixture("active-\(index)", status: "unread", ageDays: 20))
    }
    try seed(rows, at: path)

    let inbox = fixedClockInbox(path)
    #expect(try await inbox.appendUnique(
        retentionFixture("fresh", status: "unread", ageDays: 0), id: "fresh"
    ))

    let kept = try await inbox.rows()
    #expect(kept.count == LiveNotificationInbox.rowLimit, "the cap did not bind")
    let keptIDs = Set(ids(kept))
    #expect(keptIDs.contains("fresh"))
    for index in 0..<94 { #expect(keptIDs.contains("active-\(index)")) }
    #expect(!keptIDs.contains("terminal-0"), "oldest terminal history leaves first")
    #expect(keptIDs.contains("terminal-576"), "newest terminal history is kept")

    #expect(try await inbox.archivedRows().count == 672 - LiveNotificationInbox.rowLimit)
    #expect(ids(try await inbox.archivedRows()).allSatisfy { $0.hasPrefix("terminal-") })
}

@Test("every producer append shelves what it evicts, including the deduped path")
func liveInboxProducerAppendsAllShelveTheirOverflow() async throws {
    // The three app-side card writers (scheduler receipts, trigger mirror,
    // self-evolution) used to append raw through `appendJSONLCapped`, whose
    // trim keeps a suffix and HARD-DELETES the overflow. They now go through
    // `appendUnique` and `appendUnlessDuplicate`; both must carry the shelf, or
    // routing them here would only have moved the data loss.
    for usesDuplicateCheck in [false, true] {
        let path = try retentionInboxPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let aged = (0..<4).map {
            retentionFixture("aged-\($0)", status: "archived", ageDays: 60)
        }
        try seed(aged + [retentionFixture("live", status: "unread", ageDays: 1)], at: path)
        let inbox = fixedClockInbox(path)
        let fresh = retentionFixture("fresh", status: "unread", ageDays: 0)

        if usesDuplicateCheck {
            #expect(try await inbox.appendUnlessDuplicate(fresh, duplicateID: { nil }) == nil)
        } else {
            #expect(try await inbox.appendUnique(fresh, id: "fresh"))
        }

        #expect(ids(try await inbox.rows()) == ["live", "fresh"])
        #expect(ids(try await inbox.archivedRows()) == (0..<4).map { "aged-\($0)" },
                "a producer append destroyed history instead of shelving it")
    }
}

@Test("a producer's duplicate check runs under the feed lock and suppresses the append")
func liveInboxAppendUnlessDuplicateHonoursTheProducerCheck() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = fixedClockInbox(path)

    #expect(try await inbox.appendUnlessDuplicate(
        retentionFixture("first", status: "unread", ageDays: 0), duplicateID: { nil }
    ) == nil)
    // The check sees the feed as of this call, inside the lock the append takes.
    #expect(try await inbox.appendUnlessDuplicate(
        retentionFixture("second", status: "unread", ageDays: 0),
        duplicateID: { "first" }
    ) == "first")
    #expect(ids(try await inbox.rows()) == ["first"])
}

@Test("a stable-card-id producer still counts each occurrence, and still ignores retries")
func liveInboxRollupCountsByOccurrenceNotByCardID() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = fixedClockInbox(path)

    // The delegation-outcome shape: ONE stable card id for every write, so the
    // card id says nothing about whether this is a new job or a redelivery.
    let cardID = "delegation-outcome:codex:successful-rollup"
    func write(job: String) async throws -> LiveNotificationInbox.InformationalRollupResult {
        try await inbox.appendOrRollUpInformational(
            retentionFixture(cardID, status: "unread", ageDays: 0),
            id: cardID,
            rollupKey: "delegation_outcome.successful.codex",
            occurrenceID: job
        )
    }

    #expect(try await write(job: "cx-1")
        == .init(inserted: true, cardID: cardID, occurrenceCount: 1))
    #expect(try await write(job: "cx-2")
        == .init(inserted: false, cardID: cardID, occurrenceCount: 2),
            "a second distinct job must roll into the card, not be read as a retry")
    #expect(try await write(job: "cx-3")
        == .init(inserted: false, cardID: cardID, occurrenceCount: 3))

    // …and the retry protection survives: an already-absorbed job is a no-op,
    // including after the card was read.
    #expect(try await inbox.updateStatus(id: cardID, status: "read", readAt: iso(fixedNow)))
    #expect(try await write(job: "cx-2")
        == .init(inserted: false, cardID: cardID, occurrenceCount: 3))

    let rows = try await inbox.rows()
    #expect(rows.count == 1)
    guard case .object(let card)? = rows.first else {
        Issue.record("the rolled-up card vanished")
        return
    }
    #expect(card["status"] == .string("read"), "a retry resurfaced the card unread")
    #expect(card["occurrence_count"] == .int(3))
    #expect(card["absorbed_occurrence_ids"]
        == .array([.string("cx-1"), .string("cx-2"), .string("cx-3")]))
}

@Test("the absorbed-occurrence list stays bounded, dropping its oldest ids")
func liveInboxRollupBoundsItsAbsorbedOccurrenceList() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = fixedClockInbox(path)
    let cardID = "bounded-rollup"
    let bound = LiveNotificationInbox.maxAbsorbedOccurrenceIDs
    let total = bound + 5

    for index in 0..<total {
        _ = try await inbox.appendOrRollUpInformational(
            retentionFixture(cardID, status: "unread", ageDays: 0),
            id: cardID,
            rollupKey: "bounded",
            occurrenceID: "job-\(index)"
        )
    }

    guard case .object(let card)? = try await inbox.rows().first,
          case .array(let absorbed)? = card["absorbed_occurrence_ids"] else {
        Issue.record("the rolled-up card lost its absorbed-occurrence list")
        return
    }
    #expect(card["occurrence_count"] == .int(Int64(total)),
            "the count is the running total, not the size of the bounded list")
    #expect(absorbed.count == bound, "the absorbed list grew without bound")
    #expect(absorbed.first == .string("job-5"), "the oldest absorbed ids should drop first")
    #expect(absorbed.last == .string("job-\(total - 1)"))

    // An id that has aged out of the list is no longer recognised as a retry.
    // That is the accepted cost of bounding it: the window only has to outlive
    // a producer's redelivery, and re-counting beats an unbounded row.
    #expect(try await inbox.appendOrRollUpInformational(
        retentionFixture(cardID, status: "unread", ageDays: 0),
        id: cardID, rollupKey: "bounded", occurrenceID: "job-0"
    ) == .init(inserted: false, cardID: cardID, occurrenceCount: total + 1))
}

@Test("re-delivering a rolled-up card's own id is a retry, not a new occurrence")
func liveInboxRollupRefusesADuplicateID() async throws {
    let path = try retentionInboxPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = fixedClockInbox(path)

    func notice(_ id: String) -> JSONValue {
        retentionFixture(id, status: "unread", ageDays: 0)
    }

    #expect(try await inbox.appendOrRollUpInformational(
        notice("first"), id: "first", rollupKey: "health:a"
    ) == .init(inserted: true, cardID: "first", occurrenceCount: 1))

    // A genuinely new occurrence still rolls up onto the same card.
    #expect(try await inbox.appendOrRollUpInformational(
        notice("second"), id: "second", rollupKey: "health:a"
    ) == .init(inserted: false, cardID: "first", occurrenceCount: 2))
    #expect(try await inbox.updateStatus(id: "first", status: "read", readAt: iso(fixedNow)))

    // The surviving card carries `first`; re-delivering THAT id is the same
    // occurrence arriving twice. It must not bump the count or resurface it.
    #expect(try await inbox.appendOrRollUpInformational(
        notice("first"), id: "first", rollupKey: "health:a"
    ) == .init(inserted: false, cardID: "first", occurrenceCount: 2))

    let rows = try await inbox.rows()
    #expect(rows.count == 1)
    guard case .object(let card)? = rows.first else {
        Issue.record("the rolled-up card vanished")
        return
    }
    #expect(card["status"] == .string("read"), "a retry resurfaced the card unread")
    #expect(card["occurrence_count"] == .int(2))
}
