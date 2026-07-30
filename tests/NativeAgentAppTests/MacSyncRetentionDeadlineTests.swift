import Foundation
import Testing
@testable import NativeAgentApp

@Test func archiveRetentionUsesEarliestExactCreationCrossing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacSyncRetention-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let old = root.appendingPathComponent("old.json")
    let newer = root.appendingPathComponent("new.json")
    try Data("{}".utf8).write(to: old)
    try Data("{}".utf8).write(to: newer)
    let anchor = Date(timeIntervalSince1970: 1_800_000_000)
    try FileManager.default.setAttributes([.creationDate: anchor], ofItemAtPath: old.path)
    try FileManager.default.setAttributes(
        [.creationDate: anchor.addingTimeInterval(3_600)],
        ofItemAtPath: newer.path
    )

    let now = anchor.addingTimeInterval(60)
    let due = try #require(MacSyncEngine.nextArchiveRetentionDeadline(in: [root], after: now))
    #expect(abs(due.timeIntervalSince(anchor.addingTimeInterval(7 * 24 * 60 * 60))) < 0.01)
}

@Test func archiveRetentionReturnsNilForEmptyDirectories() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacSyncRetentionEmpty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(MacSyncEngine.nextArchiveRetentionDeadline(in: [root], after: Date()) == nil)
}
