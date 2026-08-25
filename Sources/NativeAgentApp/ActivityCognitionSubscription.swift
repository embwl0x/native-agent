import CognitiveSubstrate
import Observation

/// Owns Activity's live proposal projection while the Activity root is mounted.
/// The runtime stream is armed before the first read, so a cognition change
/// cannot land between a stale snapshot and the subscription. Revisions are
/// monotonic and duplicate/late notifications are ignored; each reload is
/// awaited before another begins, keeping burst work bounded.
@MainActor
@Observable
final class ActivityCognitionSubscription {
    enum State: Equatable {
        case idle
        case active
        case unavailable(String)
        case stopped
    }

    private let runtime: NativeCognitionRuntime
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activeRefreshes = 0

    private(set) var pending = CognitionProposalsFeed.Pending()
    private(set) var state: State = .idle
    private(set) var lastRevision: UInt64?
    private(set) var refreshCount = 0
    private(set) var peakConcurrentRefreshes = 0

    init(runtime: NativeCognitionRuntime = .shared) {
        self.runtime = runtime
    }

    func start() {
        guard consumeTask == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        state = .idle
        consumeTask = Task { [weak self, runtime] in
            let changes = await runtime.changes()
            guard let self, !Task.isCancelled, self.isCurrent(currentGeneration) else { return }
            await self.refresh(currentGeneration)

            for await change in changes {
                guard !Task.isCancelled, self.isCurrent(currentGeneration) else { break }
                guard Self.shouldRefresh(for: change, after: self.lastRevision) else { continue }
                self.lastRevision = change.revision
                await self.refresh(currentGeneration)
            }

            self.finish(currentGeneration, cancelled: Task.isCancelled)
        }
    }

    func stop() {
        generation &+= 1
        consumeTask?.cancel()
        consumeTask = nil
        state = .stopped
    }

    func refreshNow() async {
        let currentGeneration = generation
        await refresh(currentGeneration, allowStopped: true)
    }

    static func shouldRefresh(
        for change: NativeCognitionRuntimeChange,
        after lastRevision: UInt64?
    ) -> Bool {
        guard let lastRevision else { return true }
        return change.revision > lastRevision
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    private func refresh(_ currentGeneration: UInt64, allowStopped: Bool = false) async {
        guard allowStopped || isCurrent(currentGeneration) else { return }
        activeRefreshes += 1
        peakConcurrentRefreshes = max(peakConcurrentRefreshes, activeRefreshes)
        defer { activeRefreshes -= 1 }

        let read = await CognitionProposalsFeed.read(runtime: runtime)
        guard allowStopped || isCurrent(currentGeneration) else { return }
        refreshCount += 1
        switch read {
        case .available(let next):
            pending = next
            state = .active
        case .unavailable(let detail):
            pending = .init()
            state = .unavailable(detail)
        }
    }

    private func finish(_ currentGeneration: UInt64, cancelled: Bool) {
        guard isCurrent(currentGeneration) else { return }
        consumeTask = nil
        state = cancelled
            ? .stopped
            : .unavailable("Cognition update subscription ended. Refresh Activity to retry.")
    }
}
