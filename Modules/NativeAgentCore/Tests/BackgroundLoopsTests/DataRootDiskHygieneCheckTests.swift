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
