import Testing
import Foundation
@testable import PersistenceCore

// M7 (honesty sweep, 2026-07-09): turn_traces/ grew one day-file plus one
// orphaned .lock per day, forever. This is the date-keyed sweep, mirroring
// ChatSessionRetention's role for chat/sessions.json.

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TurnTraceRetentionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func seedDay(_ root: URL, daysAgo: Int, now: Date, withLock: Bool = true) throws -> URL {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
    let name = TurnTraceRetention.dayFormatter.string(from: day)
    let dir = root.appendingPathComponent("turn_traces", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("\(name).jsonl")
    try Data("{\"row\":1}\n".utf8).write(to: file)
    if withLock {
        try Data().write(to: file.appendingPathExtension("lock"))
    }
    return file
}

@Test func turnTraceRetention_removes_expired_days_and_their_locks() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()

    let today = try seedDay(root, daysAgo: 0, now: now)
    let edge = try seedDay(root, daysAgo: 13, now: now)   // newest kept day
    let expired = try seedDay(root, daysAgo: 14, now: now) // first dropped day
    let ancient = try seedDay(root, daysAgo: 400, now: now)

    let report = try TurnTraceRetention.enforce(dataRoot: root, now: now, keepDays: 14)

    #expect(report.keptDays == 2)
    #expect(report.removedDays == 2)
    #expect(report.removedLocks == 2)

    let fm = FileManager.default
    #expect(fm.fileExists(atPath: today.path))
    #expect(fm.fileExists(atPath: edge.path))
    #expect(!fm.fileExists(atPath: expired.path))
    #expect(!fm.fileExists(atPath: ancient.path))
    // The lock sidecar goes with its day — that is what left the orphans.
    #expect(!fm.fileExists(atPath: expired.appendingPathExtension("lock").path))
    #expect(fm.fileExists(atPath: today.appendingPathExtension("lock").path))
}

@Test func turnTraceRetention_sweeps_orphan_locks_for_expired_days() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()

    // A lock whose .jsonl is already gone (partial historical sweep).
    let expired = try seedDay(root, daysAgo: 30, now: now)
    try FileManager.default.removeItem(at: expired)
    let orphan = expired.appendingPathExtension("lock")
    #expect(FileManager.default.fileExists(atPath: orphan.path))

    let report = try TurnTraceRetention.enforce(dataRoot: root, now: now, keepDays: 14)
    #expect(report.removedLocks == 1)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
}

@Test func turnTraceRetention_never_touches_unparseable_names() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("turn_traces", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stray = dir.appendingPathComponent("notes.jsonl")
    try Data("{}\n".utf8).write(to: stray)

    let report = try TurnTraceRetention.enforce(dataRoot: root, now: Date(), keepDays: 14)
    #expect(report.removedDays == 0)
    // Never guess at a filename the writer didn't produce.
    #expect(FileManager.default.fileExists(atPath: stray.path))
}

@Test func turnTraceRetention_on_missing_directory_is_a_no_op() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try TurnTraceRetention.enforce(dataRoot: root, now: Date(), keepDays: 14)
    #expect(report == TurnTraceRetentionReport())
}
