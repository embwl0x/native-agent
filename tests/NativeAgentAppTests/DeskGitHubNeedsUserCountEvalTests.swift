import Foundation
import Testing

@testable import NativeAgentApp
@testable import PersistenceCore

// EVAL FENCE: app.desk / desk.github.needsUserCount
@Suite("Desk GitHub needs-User count")
struct DeskGitHubNeedsUserCountEvalTests {
    @Test("the Desk count follows the authoritative GitHub command feed through decision and resolution")
    func readsAndClearsOnlyRealNeedsUserRows() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)

        _ = try await store.observe(observation(
            number: 41,
            version: "decision-41",
            decision: GitHubCommandBlocker(detail: "Choose the release direction.", owner: "User")
        ))
        _ = try await store.observe(observation(
            number: 42,
            version: "decision-42",
            decision: GitHubCommandBlocker(detail: "Approve the migration.", owner: "User")
        ))
        _ = try await store.observe(observation(number: 43, version: "waiting-43"))

        #expect(reading(from: try await store.liveState()) == .measured(2))

        _ = try await store.observe(observation(
            number: 41,
            version: "merged-41",
            isOpen: false,
            isMerged: true
        ))
        #expect(reading(from: try await store.liveState()) == .measured(1))

        _ = try await store.observe(observation(
            number: 42,
            version: "merged-42",
            isOpen: false,
            isMerged: true
        ))
        #expect(reading(from: try await store.liveState()) == .measured(0))
    }

    @Test("a malformed GitHub feed is unavailable, never a zero count")
    func malformedFeedRemainsAnHonestUnavailableCount() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await store.observe(observation(
            number: 44,
            version: "decision-44",
            decision: GitHubCommandBlocker(detail: "Confirm owner intent.", owner: "User")
        ))
        try Data("{not-json}\n".utf8).write(to: store.opsPath, options: .atomic)

        let lane: DeskLaneState<GitHubCommandItem>
        do {
            lane = .rows(try await store.liveState().items)
        } catch {
            lane = .failed(error)
        }
        let count = DeskGitHubNeedsUserCount(githubLane: lane)

        guard case .unavailable(let reason) = count else {
            Issue.record("A malformed GitHub feed was presented as a measured count")
            return
        }
        #expect(!reason.isEmpty)
        #expect(count.value == nil)
    }

    private func reading(from state: GitHubCommandState) -> DeskGitHubNeedsUserCount {
        DeskGitHubNeedsUserCount(githubLane: .rows(state.items))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-github-needs-user-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func observation(
        number: Int,
        version: String,
        isOpen: Bool = true,
        isMerged: Bool = false,
        decision: GitHubCommandBlocker? = nil
    ) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "nativeagent/desk-eval",
            number: number,
            kind: .pullRequest,
            title: "Desk count eval \(number)",
            isOpen: isOpen,
            isMerged: isMerged,
            observedVersion: "observed-\(version)",
            humanDecision: decision,
            finalReceipt: isOpen ? nil : "nativeagent/desk-eval #\(number) merged."
        )
    }
}
