import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
import Experiences
// Blueprint: | `TurnInspectorFeed.swift` | `LatestRead`: Checked evidence via `LatestRead`; shared Mac/phone grouping |

/// Share persisted evidence across Mac and phone so independent projections cannot disagree on grouping.
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
        observeRecord()
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Clear is a window's display filter; it never changes shared evidence.
    public func cards(after cutoff: Date?) -> [InspectorTurnCard] {
        guard let cutoff else { return cards }
        return TurnInspectorGrouping.group(groups.flatMap(\.events).filter { $0.ts > cutoff })
    }

    private func observeRecord() {
        guard watcher == nil else { return }
        let database = lane.resolvedDataRoot().appendingPathComponent("experiences/experiences.sqlite")
        watcher = FileChangeWatcher(paths: [
            database, URL(fileURLWithPath: database.path + "-wal"), database.deletingLastPathComponent(),
        ]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        scheduleRefresh()
    }

    /// Replay returns an immutable read result; each window keeps its selection.
    public func loadReplay(for date: Date) async throws -> (hasEvidence: Bool, unreadable: Int, cards: [InspectorTurnCard]) {
        let root = lane.resolvedDataRoot()
        let calendar = TurnTracePersistLane.dayCalendar
        let from = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: from) else { throw CocoaError(.fileReadUnknown) }
        let through = Date(timeIntervalSince1970: nextDay.timeIntervalSince1970.nextDown)
        return try await Task.detached(priority: .userInitiated) {
            let read = try await TurnTraceReplayReader.read(.init(from: from, through: through), root: root)
            let events = read.events.filter { $0.ts < nextDay && $0.turnId != "unknown" }
            return (hasEvidence: !events.isEmpty || read.unreadable > 0, unreadable: read.unreadable,
                    cards: TurnInspectorGrouping.group(events))
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

    /// Coalesce record changes for 0.1s before refreshing.
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
