import Foundation
import Testing
import BackgroundLoops
import NativeAgentCore
import NotificationInbox
import PersistenceCore
@testable import NativeAgentApp

// Disk-hygiene card contract (2026-08-11, User: "Make it so I can hit act on it
// and it will clean it up"): the card carries a working Clean Up lever, an
// archived card stays archived while the finding is unchanged, and Act on a
// disk_hygiene item resolves to the cleanup handler — never to a chat draft.

private func hygieneActionTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("disk-hygiene-action-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// The notice path re-validates that offenders still exist on disk before
// writing, so fixture offenders must be real files.
private func writeOffender(_ root: URL, _ rel: String, bytes: Int) throws {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x61, count: bytes).write(to: url)
}

private func diskCardRow(at root: URL) async throws -> [String: JSONValue] {
    let path = root.appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    let rows = try await SwiftNativePersistenceCore().readJSONL(path)
    for row in rows {
        if case .object(let obj) = row, obj["id"] == .string("disk-hygiene") {
            return obj
        }
    }
    Issue.record("disk-hygiene card not found")
    return [:]
}

private func decodeInboxRecord(_ value: JSONValue) throws -> InboxItemRecord {
    let data = try value.serializedData(pretty: false)
    return try JSONDecoder().decode(InboxItemRecord.self, from: data)
}

@Test
func diskHygieneCardCarriesCleanUpActionAndRelatedPaths() async throws {
    let root = try hygieneActionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeOffender(root, "logs/huge.jsonl", bytes: 5000)
    let report = DiskHygieneReport(
        largeFiles: [DiskHygieneOffender(relativePath: "logs/huge.jsonl", sizeBytes: 5000)],
        totalBytes: 5000, totalOverBudget: false)

    #expect(await BackgroundLoopsAssembly.fileDiskHygieneNotice(dataRoot: root, report: report))

    let card = try await diskCardRow(at: root)
    guard case .array(let actions)? = card["actions"] else {
        Issue.record("actions missing"); return
    }
    let ids: [String] = actions.compactMap {
        guard case .object(let a) = $0, case .string(let id)? = a["id"] else { return nil }
        return id
    }
    #expect(ids == ["act", "archive", "dismiss"])
    #expect(card["related_paths"] == .array([
        .string(root.appendingPathComponent("logs/huge.jsonl").path),
    ]))
}

// The sticky-archive tooth: identical finding on the next daily scan must NOT
// resurrect an archived card; a CHANGED finding must.
@Test
func unchangedRescanPreservesArchivedStatusAndChangedRescanResurrects() async throws {
    let root = try hygieneActionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    try writeOffender(root, "logs/huge.jsonl", bytes: 5000)
    let report = DiskHygieneReport(
        largeFiles: [DiskHygieneOffender(relativePath: "logs/huge.jsonl", sizeBytes: 5000)],
        totalBytes: 5000, totalOverBudget: false)
    #expect(await BackgroundLoopsAssembly.fileDiskHygieneNotice(dataRoot: root, report: report))

    // User archives the card.
    let archived = await NativeClient.updateVisibleNotificationInboxStatus(
        id: "disk-hygiene", action: "archive",
        inboxPath: path, persistence: SwiftNativePersistenceCore())
    #expect(archived)

    // Next day, same finding → card stays archived.
    #expect(await BackgroundLoopsAssembly.fileDiskHygieneNotice(dataRoot: root, report: report))
    var card = try await diskCardRow(at: root)
    #expect(card["status"] == .string("archived"))

    // A genuinely different finding → card resurrects unread.
    try writeOffender(root, "exports/dump.bin", bytes: 9000)
    let worse = DiskHygieneReport(
        largeFiles: [
            DiskHygieneOffender(relativePath: "logs/huge.jsonl", sizeBytes: 5000),
            DiskHygieneOffender(relativePath: "exports/dump.bin", sizeBytes: 9000),
        ],
        totalBytes: 14000, totalOverBudget: false)
    #expect(await BackgroundLoopsAssembly.fileDiskHygieneNotice(dataRoot: root, report: worse))
    card = try await diskCardRow(at: root)
    #expect(card["status"] == .string("unread"))
}

@Test
func actOnDiskHygieneItemResolvesToDiskCleanupNotChatDraft() throws {
    let record = try decodeInboxRecord(.object([
        "id": .string("disk-hygiene"),
        "created_at": .string("2026-08-11T00:33:40Z"),
        "source": .string("disk_hygiene"),
        "severity": .string("actionable"),
        "title": .string("Disk usage is piling up"),
        "summary": .string("1 large file(s) in data/"),
        "status": .string("unread"),
        "actions": .array([]),
    ]))
    #expect(NativeClient.resolveInboxPrimaryAction(for: record) == .diskCleanup)
}

// Clean root: cleanup reports "nothing to clean" and rewrites the card as a
// read info receipt instead of throwing or leaving the stale alarm up.
@Test
func cleanupOnCleanRootRewritesCardAsReadReceipt() async throws {
    let root = try hygieneActionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeOffender(root, "logs/huge.jsonl", bytes: 5000)
    let report = DiskHygieneReport(
        largeFiles: [DiskHygieneOffender(relativePath: "logs/huge.jsonl", sizeBytes: 5000)],
        totalBytes: 5000, totalOverBudget: false)
    #expect(await BackgroundLoopsAssembly.fileDiskHygieneNotice(dataRoot: root, report: report))

    let message = try await BackgroundLoopsAssembly.cleanUpDiskHygiene(dataRoot: root)
    #expect(message.contains("Nothing to clean"))
    let card = try await diskCardRow(at: root)
    #expect(card["status"] == .string("read"))
    #expect(card["title"] == .string("Disk cleanup"))
}

// MARK: - W1(c) upgrade campaign: sticky loop-failure card (L4-01)

@Test
func dismissedLoopFailureCardStaysDismissedForSameErrorSignature() async throws {
    let root = try hygieneActionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    let err = "Error Domain=NSURLErrorDomain Code=-1011 \"server said no\""

    await BackgroundLoopsManager.fileLoopFailureNotice(
        dataRoot: root, loopId: "github_tracking", error: err)
    let dismissed = await NativeClient.updateVisibleNotificationInboxStatus(
        id: "loop-failure:github_tracking", action: "dismiss",
        inboxPath: path, persistence: SwiftNativePersistenceCore())
    #expect(dismissed)

    // Same failing condition fires again → card must NOT resurrect.
    await BackgroundLoopsManager.fileLoopFailureNotice(
        dataRoot: root, loopId: "github_tracking", error: err)
    var rows = try await SwiftNativePersistenceCore().readJSONL(path)
    var status: JSONValue? = nil
    for row in rows {
        if case .object(let obj) = row, obj["id"] == .string("loop-failure:github_tracking") {
            status = obj["status"]
        }
    }
    #expect(status == .string("dismissed"))

    // A genuinely different error class → resurrects unread.
    await BackgroundLoopsManager.fileLoopFailureNotice(
        dataRoot: root, loopId: "github_tracking",
        error: "decode failed: schema mismatch in tracking payload")
    rows = try await SwiftNativePersistenceCore().readJSONL(path)
    for row in rows {
        if case .object(let obj) = row, obj["id"] == .string("loop-failure:github_tracking") {
            status = obj["status"]
        }
    }
    #expect(status == .string("unread"))
}
