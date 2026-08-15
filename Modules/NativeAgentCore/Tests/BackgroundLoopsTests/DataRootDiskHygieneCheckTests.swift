import Testing
import Foundation
@testable import BackgroundLoops

// Tightness round 2 item 6: daily disk-hygiene watchdog (User: "make sure we dont
// pile up logs like that again"). Pins the pure scan's threshold detection and
// that the daily reservation prevents a same-day double-run.

private final class NoticeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [DiskHygieneReport] = []
    var reports: [DiskHygieneReport] { lock.lock(); defer { lock.unlock() }; return _reports }
    func record(_ r: DiskHygieneReport) { lock.lock(); _reports.append(r); lock.unlock() }
}

private func hygieneTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("disk-hygiene-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x61, count: bytes).write(to: url)
}

// MARK: - Pure scan

@Test func scanFlagsOversizedSingleFile() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("logs/big.jsonl"), bytes: 2000)
    try writeFile(root.appendingPathComponent("logs/small.jsonl"), bytes: 50)

    let report = DataRootDiskHygiene.scan(
        dataRoot: root, singleFileThreshold: 1000, totalThreshold: 1_000_000)
    #expect(report.tripped)
    #expect(report.largeFiles.count == 1)
    #expect(report.largeFiles.first?.relativePath == "logs/big.jsonl")
    #expect(report.largeFiles.first?.sizeBytes == 2000)
    #expect(!report.totalOverBudget)
}

@Test func scanFlagsTotalOverBudget() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("a.bin"), bytes: 600)
    try writeFile(root.appendingPathComponent("b.bin"), bytes: 600)

    let report = DataRootDiskHygiene.scan(
        dataRoot: root, singleFileThreshold: 10_000, totalThreshold: 1000)
    #expect(report.tripped)
    #expect(report.largeFiles.isEmpty)     // no single file over threshold
    #expect(report.totalOverBudget)
    #expect(report.totalBytes == 1200)
}

@Test func scanCleanTreeDoesNotTrip() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("logs/small.jsonl"), bytes: 50)
    let report = DataRootDiskHygiene.scan(dataRoot: root)
    #expect(!report.tripped)
}

@Test func scanRespectsDepthBound() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // Depth 0 = root; a file at depth 3 is visited with maxDepth 4, a file
    // deeper than maxDepth is not.
    try writeFile(root.appendingPathComponent("a/b/deep.bin"), bytes: 2000)
    try writeFile(root.appendingPathComponent("a/b/c/d/e/tooDeep.bin"), bytes: 2000)
    let report = DataRootDiskHygiene.scan(
        dataRoot: root, maxDepth: 4, singleFileThreshold: 1000, totalThreshold: 1_000_000)
    #expect(report.largeFiles.map(\.relativePath) == ["a/b/deep.bin"])
}

// A5.1 (W5#P1-1): a store past the depth bound must surface as
// `depthTruncated` so a clean-looking scan can never hide an unscanned tree.
@Test func scanFlagsDepthTruncationWhenADirectorySitsPastMaxDepth() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // `e/` sits past maxDepth 4, so its file is unscanned — that must flag.
    try writeFile(root.appendingPathComponent("a/b/c/d/e/tooDeep.bin"), bytes: 2000)
    let report = DataRootDiskHygiene.scan(
        dataRoot: root, maxDepth: 4, singleFileThreshold: 1000, totalThreshold: 1_000_000)
    #expect(report.depthTruncated)
    #expect(!report.truncated)   // NOT the file-budget flag — a distinct signal
    #expect(report.largeFiles.isEmpty)
}

@Test func scanDoesNotFlagDepthTruncationWhenEverythingFitsWithinBound() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("a/b/deep.bin"), bytes: 50)
    let report = DataRootDiskHygiene.scan(
        dataRoot: root, maxDepth: 4, singleFileThreshold: 1000, totalThreshold: 1_000_000)
    #expect(!report.depthTruncated)
}

// The raised default (7) must actually reach the MiniLM HuggingFace cache blob,
// which lives at path-depth 6: extras/hf_cache/hub/models--…/blobs/<hash>.
@Test func defaultDepthReachesTheDepth6MiniLMCacheBlob() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let blob = root
        .appendingPathComponent("extras/hf_cache/hub/models--sentence-transformers--all-MiniLM-L6-v2/blobs/deadbeef")
    try writeFile(blob, bytes: 2000)
    let report = DataRootDiskHygiene.scan(
        dataRoot: root, singleFileThreshold: 1000, totalThreshold: 1_000_000)
    #expect(report.largeFiles.map(\.relativePath)
        == ["extras/hf_cache/hub/models--sentence-transformers--all-MiniLM-L6-v2/blobs/deadbeef"])
    #expect(!report.depthTruncated)   // fully scanned at the raised default
    #expect(DataRootDiskHygiene.defaultMaxDepth == 7)
}

// MARK: - Cleanup (user-initiated)

// The default single-file tripwire sits at 1GB (raised 2026-08-11 from 64MB,
// which permanently false-alarmed on the 86.7MB MiniLM embedder blob).
@Test func defaultSingleFileThresholdIsOneGB() {
    #expect(DataRootDiskHygiene.defaultSingleFileThreshold == 1024 * 1024 * 1024)
}

@Test func cleanupTrashesARegularFileAndReportsFreedBytes() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("logs/huge.jsonl"), bytes: 2000)
    var trashedURLs: [URL] = []
    let result = DataRootDiskHygiene.cleanup(
        dataRoot: root,
        relativePaths: ["logs/huge.jsonl"],
        trash: { trashedURLs.append($0) }
    )
    #expect(trashedURLs.map(\.lastPathComponent) == ["huge.jsonl"])
    #expect(result.trashed.count == 1)
    #expect(result.skipped.isEmpty)
    #expect(result.freedBytes == 2000)
}

@Test func cleanupRefusesPathTraversalOutsideDataRoot() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // A sibling file the traversal would reach if containment failed.
    let sibling = root.deletingLastPathComponent()
        .appendingPathComponent("hygiene-victim-\(UUID().uuidString).txt")
    try Data("do not touch".utf8).write(to: sibling)
    defer { try? FileManager.default.removeItem(at: sibling) }
    var trashedURLs: [URL] = []
    let result = DataRootDiskHygiene.cleanup(
        dataRoot: root,
        relativePaths: ["../\(sibling.lastPathComponent)", "/etc/hosts"],
        trash: { trashedURLs.append($0) }
    )
    #expect(trashedURLs.isEmpty)
    #expect(result.trashed.isEmpty)
    #expect(result.skipped.count == 2)
    #expect(result.skipped.allSatisfy { $0.skippedReason == "outside the data directory" })
}

@Test func cleanupRefusesProtectedModelCache() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let rel = "extras/hf_cache/hub/models--x/blobs/deadbeef"
    try writeFile(root.appendingPathComponent(rel), bytes: 2000)
    var trashedURLs: [URL] = []
    let result = DataRootDiskHygiene.cleanup(
        dataRoot: root, relativePaths: [rel], trash: { trashedURLs.append($0) })
    #expect(trashedURLs.isEmpty)
    #expect(result.trashed.isEmpty)
    #expect(result.skipped.first?.skippedReason?.contains("protected store") == true)
}

@Test func cleanupSkipsMissingFilesDirectoriesAndSymlinks() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("a-directory"), withIntermediateDirectories: true)
    try writeFile(root.appendingPathComponent("real.bin"), bytes: 100)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("a-link"),
        withDestinationURL: root.appendingPathComponent("real.bin"))
    var trashedURLs: [URL] = []
    let result = DataRootDiskHygiene.cleanup(
        dataRoot: root,
        relativePaths: ["gone.bin", "a-directory", "a-link"],
        trash: { trashedURLs.append($0) })
    #expect(trashedURLs.isEmpty)
    #expect(result.trashed.isEmpty)
    #expect(result.skipped.count == 3)
    // The real file was never touched through the symlink.
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("real.bin").path))
}

// gpt-5.5 review BLOCKING regression: a symlinked PARENT directory under the
// data root must not smuggle the real target outside it.
@Test func cleanupRefusesFileReachedThroughSymlinkedParentEscapingRoot() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: outside) }
    try writeFile(outside.appendingPathComponent("victim.bin"), bytes: 700)
    // root/logs -> outside; "logs/victim.bin" is lexically inside the root
    // but resolves outside it.
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("logs"), withDestinationURL: outside)
    var trashedURLs: [URL] = []
    let result = DataRootDiskHygiene.cleanup(
        dataRoot: root, relativePaths: ["logs/victim.bin"], trash: { trashedURLs.append($0) })
    #expect(trashedURLs.isEmpty)
    #expect(result.trashed.isEmpty)
    #expect(result.skipped.first?.skippedReason == "outside the data directory")
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("victim.bin").path))
}

// gpt-5.5 review: APFS is typically case-insensitive, so a case-varied spelling
// of the protected prefix addresses the same store and must also be refused.
@Test func cleanupRefusesProtectedModelCacheCaseInsensitively() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("extras/hf_cache/hub/blob"), bytes: 2000)
    var trashedURLs: [URL] = []
    let result = DataRootDiskHygiene.cleanup(
        dataRoot: root,
        relativePaths: ["Extras/HF_Cache/hub/blob"],
        trash: { trashedURLs.append($0) })
    #expect(trashedURLs.isEmpty)
    #expect(result.trashed.isEmpty)
    // On a case-sensitive volume the varied spelling simply doesn't exist;
    // either way nothing under the protected store may move.
    #expect(result.skipped.count == 1)
}

@Test func cleanupReportsATrashFailureAsSkippedNotTrashed() throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("stubborn.bin"), bytes: 500)
    struct Boom: Error {}
    let result = DataRootDiskHygiene.cleanup(
        dataRoot: root, relativePaths: ["stubborn.bin"], trash: { _ in throw Boom() })
    #expect(result.trashed.isEmpty)
    #expect(result.freedBytes == 0)
    #expect(result.skipped.first?.skippedReason?.contains("could not move to Trash") == true)
}

// MARK: - Loop

@Test func diskHygiene_tickFilesNoticeWhenTripped() async throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("logs/huge.jsonl"), bytes: 4000)
    let recorder = NoticeRecorder()
    let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
    let loop = DataRootDiskHygieneCheck(
        dataRoot: root,
        clock: { fixedNow },
        singleFileThreshold: 1000,
        totalThreshold: 1_000_000,
        fileNotice: { recorder.record($0); return true }
    )
    let outcome = await loop.tickOutcome()
    if case .completed = outcome {} else { Issue.record("expected .completed, got \(outcome)") }
    #expect(recorder.reports.count == 1)
    #expect(recorder.reports.first?.largeFiles.first?.relativePath == "logs/huge.jsonl")
}

@Test func diskHygiene_reservationPreventsDoubleRunSameDay() async throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("logs/huge.jsonl"), bytes: 4000)
    let recorder = NoticeRecorder()
    let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
    func makeLoop() -> DataRootDiskHygieneCheck {
        DataRootDiskHygieneCheck(
            dataRoot: root,
            clock: { fixedNow },
            singleFileThreshold: 1000,
            totalThreshold: 1_000_000,
            fileNotice: { recorder.record($0); return true }
        )
    }
    let first = await makeLoop().tickOutcome()
    let second = await makeLoop().tickOutcome()
    if case .completed = first {} else { Issue.record("first should complete, got \(first)") }
    if case .skipped = second {} else { Issue.record("second should skip, got \(second)") }
    // The notice fired exactly once despite two ticks the same day.
    #expect(recorder.reports.count == 1)
}

@Test func diskHygiene_cleanTreeCompletesWithoutNotice() async throws {
    let root = hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root.appendingPathComponent("logs/small.jsonl"), bytes: 50)
    let recorder = NoticeRecorder()
    let loop = DataRootDiskHygieneCheck(
        dataRoot: root,
        clock: { Date(timeIntervalSince1970: 1_760_000_000) },
        fileNotice: { recorder.record($0); return true }
    )
    let outcome = await loop.tickOutcome()
    if case .completed = outcome {} else { Issue.record("expected .completed, got \(outcome)") }
    #expect(recorder.reports.isEmpty)
}

// MARK: - W1(b) upgrade campaign: offline blips are not failures (L4-02)

@Test func offlineErrorsClassifyAsOffline() {
    #expect(SwiftNativeLoopScheduler.isOfflineError(
        "Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\""))
    #expect(SwiftNativeLoopScheduler.isOfflineError(
        "Error Domain=NSURLErrorDomain Code=-1005 \"The network connection was lost.\""))
    #expect(SwiftNativeLoopScheduler.isOfflineError(
        "Error Domain=NSPOSIXErrorDomain Code=57 \"Socket is not connected\""))
    #expect(SwiftNativeLoopScheduler.isOfflineError("Telegram long poll: unavailable"))
}

@Test func realFailuresDoNotClassifyAsOffline() {
    // Timeouts stay REAL: the github_tracking 120s defect must not be buried.
    #expect(!SwiftNativeLoopScheduler.isOfflineError("timeout after 120s"))
    #expect(!SwiftNativeLoopScheduler.isOfflineError(
        "Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\""))
    #expect(!SwiftNativeLoopScheduler.isOfflineError(
        "GitHub API rejected the request: No server is currently available"))
    #expect(!SwiftNativeLoopScheduler.isOfflineError("decode failed: missing field 'id'"))
}
