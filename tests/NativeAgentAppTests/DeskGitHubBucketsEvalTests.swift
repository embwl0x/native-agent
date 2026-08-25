import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.github.buckets
@Suite("Desk GitHub command buckets")
struct DeskGitHubBucketsEvalTests {
    @Test("every persisted GitHub state maps to a bucket Desk renders")
    func everyStateHasARenderedBucket() {
        let states: [GitHubCommandItemState] = [
            .detected,
            .needsCodex,
            .codexWorking,
            .verifying,
            .needsUser,
            .waitingUpstream(.review),
            .attention(.codexFailed),
            .resolved,
        ]

        let buckets = Set(states.map(DeskGitHubBucket.bucket(for:)))
        #expect(buckets == Set(DeskGitHubBucket.allCases))
        #expect(DeskGitHubBucket.renderedBuckets == Set(DeskGitHubBucket.allCases))
        #expect(states.allSatisfy {
            DeskGitHubBucket.renderedBuckets.contains(DeskGitHubBucket.bucket(for: $0))
        })
    }

    @Test("resolved is the only intentionally capped bucket")
    func resolvedCapDoesNotHideActiveOrWaitingRows() {
        let many = 9
        #expect(DeskGitHubBucket.displayedCount(matchingCount: many, in: .resolved) == 5)
        for bucket in DeskGitHubBucket.allCases where bucket != .resolved {
            #expect(DeskGitHubBucket.displayedCount(matchingCount: many, in: bucket) == many)
        }
        #expect(DeskGitHubBucket.displayedCount(matchingCount: -1, in: .resolved) == 0)
    }

    @Test("persisted waiting rows have a palette reveal path, while stale targets cannot open the rollup")
    func waitingRollupUsesOnlyReachableExpansionKeys() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskGitHubWaitingRollup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = GitHubCommandStore(dataRoot: root)
        let review = try await store.observe(waitingObservation(number: 71, kind: .review))
        let ci = try await store.observe(waitingObservation(number: 72, kind: .ci))
        let persisted = try await GitHubCommandStore(dataRoot: root).liveState().items
        let rows = DeskGitHubWaitingRollup.paletteRows(in: persisted)
        #expect(Set(rows.map(\.handle)) == Set([
            DeskGitHubWaitingRollup.paletteHandle(for: review),
            DeskGitHubWaitingRollup.paletteHandle(for: ci),
        ]))

        for row in rows {
            #expect(!row.isActionable)
            #expect(DeskGitHubWaitingRollup.revealKeys(forPaletteHandle: row.handle, in: persisted)
                == [DeskGitHubWaitingRollup.toggleKey])
        }
        let waitingCommandTarget = DeskPalettePresentation.target(
            rows: rows,
            matches: [],
            selectedHandle: rows.first?.handle,
            parsed: DeskPaletteQuery(verb: .close, query: ""),
            highlighted: 0
        )
        #expect(waitingCommandTarget == nil, "watcher rows may reveal but cannot receive Desk mutations")

        // The same ID after the watcher advances is stale palette state, not
        // authorization to open an unrelated rollup.
        _ = try await store.observe(GitHubCommandObservation(
            repository: "nativeagent/desk-eval", number: 71, kind: .pullRequest,
            title: "Waiting review 71", isOpen: true, isMerged: false,
            observedVersion: "actionable-71", actionableEventVersion: "actionable-71",
            signals: [.changesRequested], waitingKind: .review
        ))
        let advanced = try await store.liveState().items
        #expect(DeskGitHubWaitingRollup.revealKeys(
            forPaletteHandle: DeskGitHubWaitingRollup.paletteHandle(for: review), in: advanced
        ).isEmpty)
        #expect(DeskGitHubWaitingRollup.isPaletteHandle(DeskGitHubWaitingRollup.paletteHandle(for: review)))
        #expect(DeskGitHubWaitingRollup.revealKeys(forPaletteHandle: "ghwait:missing", in: advanced).isEmpty)
    }

    private func waitingObservation(number: Int, kind: GitHubCommandWaitingKind) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "nativeagent/desk-eval", number: number, kind: .pullRequest,
            title: "Waiting \(kind.rawValue) \(number)", isOpen: true, isMerged: false,
            observedVersion: "quiet-\(number)", signals: [], waitingKind: kind
        )
    }
}
