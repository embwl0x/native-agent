import Foundation
import Testing
@testable import NativeAgentApp

// Coverage ledger: app.bridges / macsync.archiveRetentionWatcher
//
// The watcher is an event-driven retention trigger. A file in place of one of
// its directories cannot produce the required directory vnode events, so the
// engine must surface an unavailable state instead of installing a dead watch.

private func archiveRetentionWatcherRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacSyncArchiveRetentionWatcher-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("app.bridges · MacSync archive retention watcher", .serialized)
struct MacSyncArchiveRetentionWatcherEvalTests {
    @MainActor
    @Test("every canonical archive directory exists before the watcher is armed")
    func watcherCreatesMissingArchiveDirectoriesBeforeArming() throws {
        let root = try archiveRetentionWatcherRoot("creates")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        let engine = MacSyncEngine(stateDataRootOverride: root)
        engine.inboxDir = inbox
        engine.responsesDir = responses

        engine.startArchiveRetentionWatcher()
        defer { engine.archiveRetentionWatcher?.cancel() }

        let expected = [inbox, responses, inbox.appendingPathComponent("_rejected", isDirectory: true)]
        for path in expected {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
        #expect(engine.archiveRetentionWatcher != nil)
        #expect(engine.syncError == nil)
    }

    @MainActor
    @Test("an unarmable archive path reports unavailable instead of installing a dead watcher")
    func watcherRefusesARegularFileWhereRejectedArchiveDirectoryBelongs() throws {
        let root = try archiveRetentionWatcherRoot("unavailable")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        let rejected = inbox.appendingPathComponent("_rejected", isDirectory: true)
        try Data("not a directory".utf8).write(to: rejected)

        let engine = MacSyncEngine(stateDataRootOverride: root)
        engine.inboxDir = inbox
        engine.responsesDir = responses
        engine.startArchiveRetentionWatcher()

        #expect(engine.archiveRetentionWatcher == nil)
        #expect(engine.syncError?.contains("Archive retention watcher unavailable") == true)
        #expect(MacSyncArchiveRetentionWatchPaths.resolve(
            inboxDirectory: inbox,
            responsesDirectory: responses
        ).isEmpty)
    }
}
