import Testing
import Foundation
@testable import BackgroundLoops

// F1 (upgrade-sweep-2026-08): the disk watchdog could not fire. Its two
// tripwires were a 1 GB single FILE and a 2 GB TOTAL; the live data root
// measured 567 MB with a largest file of 87 MB, and the 2 GB total was the same
// number as the storage limit it was meant to warn ahead of. A backstop that
// can only fire once the problem has arrived is not a backstop.
//
// The fix is a per-DIRECTORY tier (a data root grows by ten thousand small
// files under one branch, not by one giant file) plus a 1 GB tree budget.
@Suite(.serialized)
struct DiskHygieneDirectoryTierTests {

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("disk-tier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test
    func theTreeBudgetIsOneGigabyteNotTwo() {
        #expect(DataRootDiskHygiene.defaultTotalThreshold == 1024 * 1024 * 1024)
        #expect(
            DataRootDiskHygiene.defaultTotalThreshold < 2 * 1024 * 1024 * 1024,
            "the budget must sit BELOW the storage limit it warns about, or it cannot warn"
        )
        #expect(DataRootDiskHygiene.defaultDirectoryThreshold == 128 * 1024 * 1024)
        #expect(
            DataRootDiskHygiene.defaultDirectoryThreshold
                < DataRootDiskHygiene.defaultSingleFileThreshold,
            "the directory tier exists to catch what the file tier cannot see"
        )
    }

    /// The shape the file tier is blind to: many small files, one fat branch.
    @Test
    func manySmallFilesUnderOneBranchTripTheDirectoryTier() throws {
        let root = try makeRoot()
        for index in 0..<40 {
            try write(30_000, to: root.appendingPathComponent("chatter/f\(index).jsonl"))
        }
        try write(1_000, to: root.appendingPathComponent("quiet/one.json"))

        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 1_000_000,
            totalThreshold: 100_000_000,
            directoryThreshold: 1_000_000
        )
        #expect(report.largeFiles.isEmpty, "no single file is over the file tier — that is the point")
        #expect(report.tripped)
        #expect(report.largeDirectories.map(\.relativePath) == ["chatter"])
        let chatterBytes: Int64 = report.largeDirectories.first?.sizeBytes ?? -1
        #expect(chatterBytes == Int64(40 * 30_000))
    }

    /// Only the DEEPEST offender in a branch is reported, so the card names the
    /// culprit rather than every ancestor of it.
    @Test
    func onlyTheDeepestOffendingDirectoryIsReported() throws {
        let root = try makeRoot()
        for index in 0..<20 {
            try write(60_000, to: root.appendingPathComponent("a/b/c/f\(index).bin"))
        }
        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 10_000_000,
            totalThreshold: 100_000_000,
            directoryThreshold: 500_000
        )
        #expect(report.largeDirectories.map(\.relativePath) == ["a/b/c"])
    }

    /// Two independent fat branches are both named, largest first.
    @Test
    func siblingOffendersAreBothReportedLargestFirst() throws {
        let root = try makeRoot()
        for index in 0..<10 { try write(100_000, to: root.appendingPathComponent("small/f\(index)")) }
        for index in 0..<30 { try write(100_000, to: root.appendingPathComponent("big/f\(index)")) }
        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 10_000_000,
            totalThreshold: 100_000_000,
            directoryThreshold: 500_000
        )
        #expect(report.largeDirectories.map(\.relativePath) == ["big", "small"])
    }

    /// Sweep item 21 (2026-09-01), the exact inversion of the old contract: the
    /// MiniLM HuggingFace cache was EXEMPT from this tier on the claim that it
    /// was a wanted permanent store. The CoreML cutover made that false — the
    /// live embedder loads `Bundle.module/minilm.mlpackage` — so the store is
    /// residue and must be reported no matter how small it is.
    @Test
    func residueIsReportedAtAnySizeAndAtItsRoot() throws {
        let root = try makeRoot()
        for index in 0..<4 {
            try write(1_000, to: root.appendingPathComponent("extras/hf_cache/hub/blob\(index)"))
        }
        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 10_000_000,
            totalThreshold: 100_000_000,
            // Two orders of magnitude above the whole residue tree: nothing
            // here is "large", which is precisely the point.
            directoryThreshold: 500_000
        )
        #expect(report.largeDirectories.map(\.relativePath) == ["extras/hf_cache"])
        #expect(report.largeDirectories.first?.sizeBytes == 4_000)
        #expect(report.tripped)
    }

    /// …and a root without the residue store stays quiet. Absence of the
    /// tripwire's subject is the healthy state, not a missing check.
    @Test
    func aRootWithoutResidueDoesNotTripTheResidueTier() throws {
        let root = try makeRoot()
        try write(1_000, to: root.appendingPathComponent("extras/other/blob"))
        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 10_000_000,
            totalThreshold: 100_000_000,
            directoryThreshold: 500_000
        )
        #expect(report.largeDirectories.isEmpty)
        #expect(report.tripped == false)
    }

    /// APFS is typically case-insensitive, so residue matching must be too —
    /// the same reasoning the old protected-prefix compare carried.
    @Test
    func residueMatchIsCaseFolded() throws {
        #expect(DataRootDiskHygiene.isResidue(relativePath: "Extras/HF_Cache"))
        #expect(DataRootDiskHygiene.isResidue(relativePath: "extras/hf_cache"))
        // The root is the finding; descendants are folded into it, not listed.
        #expect(DataRootDiskHygiene.isResidue(relativePath: "extras/hf_cache/hub") == false)
        #expect(DataRootDiskHygiene.isResidueDescendant(relativePath: "Extras/HF_Cache/hub"))
        #expect(DataRootDiskHygiene.isResidue(relativePath: "extras/hf_cache_other") == false)
        #expect(DataRootDiskHygiene.isResidueDescendant(relativePath: "extras/hf_cache_other") == false)
        #expect(DataRootDiskHygiene.isResidue(relativePath: "extras") == false)
    }

    @Test
    func aQuietRootStaysUntripped() throws {
        let root = try makeRoot()
        try write(1_000, to: root.appendingPathComponent("a/one"))
        try write(1_000, to: root.appendingPathComponent("b/two"))
        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 1_000_000,
            totalThreshold: 1_000_000,
            directoryThreshold: 1_000_000
        )
        #expect(report.tripped == false)
        #expect(report.largeDirectories.isEmpty)
    }

    /// Subtree totals must not double-count: the parent's number is the sum of
    /// its children, and the root total is unchanged by the new tier.
    @Test
    func subtreeTotalsAgreeWithTheTreeTotal() throws {
        let root = try makeRoot()
        try write(400_000, to: root.appendingPathComponent("x/y/one"))
        try write(400_000, to: root.appendingPathComponent("x/two"))
        try write(400_000, to: root.appendingPathComponent("three"))
        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 10_000_000,
            totalThreshold: 10_000_000,
            directoryThreshold: 500_000
        )
        #expect(report.totalBytes == 1_200_000)
        // `x` holds 800_000 and its only offending descendant `x/y` holds
        // 400_000 — under the threshold, so `x` itself is the deepest offender.
        #expect(report.largeDirectories.map(\.relativePath) == ["x"])
        #expect(report.largeDirectories.first?.sizeBytes == 800_000)
    }

    /// Symlinks are still not followed, so a loop or an out-of-tree target
    /// cannot inflate a branch's total.
    @Test
    func symlinksDoNotInflateSubtreeTotals() throws {
        let root = try makeRoot()
        try write(200_000, to: root.appendingPathComponent("real/file"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("real")
        )
        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 10_000_000,
            totalThreshold: 10_000_000,
            directoryThreshold: 100_000
        )
        #expect(report.totalBytes == 200_000)
        #expect(report.largeDirectories.map(\.relativePath) == ["real"])
    }

    @Test
    func theTreeBudgetTripsOnItsOwnWithNoOffenders() throws {
        let root = try makeRoot()
        try write(300_000, to: root.appendingPathComponent("a/one"))
        let report = DataRootDiskHygiene.scan(
            dataRoot: root,
            singleFileThreshold: 10_000_000,
            totalThreshold: 100_000,
            directoryThreshold: 10_000_000
        )
        #expect(report.totalOverBudget)
        #expect(report.largeFiles.isEmpty)
        #expect(report.largeDirectories.isEmpty)
        #expect(report.tripped)
    }
}
