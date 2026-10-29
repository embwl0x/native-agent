import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
// Blueprint: | `TurnInspectorFeed.swift` | Engine-owned persisted today/yesterday evidence, exact file observation, `LatestRead` publication with checked read failures, grouped Mac cards, bounded phone summaries and immutable selected-date replay reads |

/// The engine's persisted trace projection. Mac details and phone summaries
/// share today's and yesterday's rows, grouped once after source changes.
@MainActor
@Observable
public final class TurnInspectorFeed {
    private var groups: [TurnTraceGroup] = []
    public private(set) var readIssue: String?
    @ObservationIgnored private lazy var latestRead = LatestRead()
    public var cards: [InspectorTurnCard] { TurnInspectorGrouping.cards(groups) }
    public var observationActive: Bool { watcher?.isArmed == true }

    private let lane: TurnTracePersistLane
    @ObservationIgnored private var watcher: FileChangeWatcher?
    @ObservationIgnored private var watchedDay: URL?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false

    public nonisolated init(dataRootOverride: URL? = nil) {
        lane = TurnTracePersistLane(dataRootOverride: dataRootOverride)
    }

    deinit {
        watcher?.cancel()
        refreshTask?.cancel()
    }

    public func start() {
        observeCurrentDays()
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        watchedDay = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Clear is a window's display filter; it never changes shared evidence.
    public func cards(after cutoff: Date?) -> [InspectorTurnCard] {
        guard let cutoff else { return cards }
        return TurnInspectorGrouping.group(groups.flatMap(\.events).filter { $0.ts > cutoff })
    }

    private func observeCurrentDays() {
        let today = lane.path(for: Date())
        guard watchedDay != today else { return }
        watcher?.cancel()
        watchedDay = today
        let yesterday = TurnTracePersistLane.dayCalendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        watcher = FileChangeWatcher(paths: [
            today, lane.path(for: yesterday), today.deletingLastPathComponent(),
        ]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.observeCurrentDays()
                self?.scheduleRefresh()
            }
        }
        scheduleRefresh()
    }

    /// Replay returns an immutable read result; each window keeps its selection.
    public func loadReplay(for date: Date) async throws -> (exists: Bool, report: JSONLReadReport, cards: [InspectorTurnCard]) {
        let url = lane.path(for: date)
        return try await Task.detached(priority: .userInitiated) {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let parsed = try await TurnTraceReplayReader.read(url)
            return (exists: exists, report: parsed.report, cards: TurnInspectorGrouping.group(parsed.events))
        }.value
    }

    public func summaryData() async -> Data? {
        start()
        let result = await readGroups()
        guard case .success(let groups) = result else { return nil }
        return try? TurnSummaryComputer.compute(from: groups)
    }

    private func readGroups() async -> Result<[TurnTraceGroup], Error> {
        await latestRead.read {
            let root = lane.resolvedDataRoot()
            return await Task.detached(priority: .userInitiated) {
                do { return Result<[TurnTraceGroup], Error>.success(TurnTraceGrouping.group(try await TurnSummarySource.loadEvents(root: root))) }
                catch { return .failure(error) }
            }.value
        } publish: { result in
            switch result {
            case .success(let groups): self.groups = groups; readIssue = nil
            case .failure(let error): readIssue = error.localizedDescription
            }
        }
    }

    /// Coalesce persisted-file changes for 0.1s before refreshing.
    private func scheduleRefresh() {
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, !Task.isCancelled else { return }
            while self.refreshRequested {
                self.refreshRequested = false
                _ = await self.readGroups()
                guard !Task.isCancelled else { return }
            }
            self.refreshTask = nil
        }
    }
}
