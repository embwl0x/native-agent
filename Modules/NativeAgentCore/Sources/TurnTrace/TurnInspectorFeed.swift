import Foundation
import Observation

public enum TurnInspectorLiveDropState: Equatable, Sendable {
    case measured(Int)
    case unavailable
}

/// Owns a bounded Inspector subscription and generation-bound replay reads.
@MainActor
@Observable
public final class TurnInspectorFeed {
    public private(set) var liveEvents: [TurnTraceEvent] = []
    public private(set) var replayEvents: [TurnTraceEvent] = []
    public private(set) var liveDropCountState: TurnInspectorLiveDropState = .measured(0)
    public private(set) var liveSinkActive = false
    public var onEventsChanged: (() -> Void)?

    private let lane: TurnTracePersistLane
    private let bus: TurnTraceBus
    private var consumeTask: Task<Void, Never>?
    private var liveGeneration = 0
    private var replayGeneration = 0

    public init(dataRootOverride: URL? = nil, bus: TurnTraceBus = .shared) {
        lane = TurnTracePersistLane(dataRootOverride: dataRootOverride)
        self.bus = bus
    }

    @discardableResult
    public func start() -> Bool {
        guard consumeTask == nil else { return false }
        liveGeneration += 1
        liveDropCountState = .measured(0)
        let generation = liveGeneration
        consumeTask = Task { [weak self, bus] in
            let sub = await bus.subscribe(capacity: TurnTraceBus.defaultBufferCapacity)
            defer { Task { await bus.unsubscribe(sub.id) } }
            // Cancellation cannot abort the actor call above; a stale start
            // must still release the subscription it just received.
            guard !Task.isCancelled, self?.liveGeneration == generation else { return }
            self?.liveSinkActive = true
            let dropMonitor = Task { [weak self] in
                for await count in sub.dropCounts {
                    guard !Task.isCancelled, self?.liveGeneration == generation else { break }
                    self?.liveDropCountState = .measured(max(0, count))
                }
            }
            defer { dropMonitor.cancel() }
            for await event in sub.stream {
                guard !Task.isCancelled, let self, self.liveGeneration == generation else { break }
                self.liveEvents.append(event)
                if self.liveEvents.count > 4000 {
                    self.liveEvents.removeFirst(self.liveEvents.count - 4000)
                }
                self.onEventsChanged?()
            }
            if !Task.isCancelled, self?.liveGeneration == generation {
                self?.liveSinkActive = false
                self?.liveDropCountState = .unavailable
            }
        }
        return true
    }

    public func stop() {
        liveSinkActive = false
        liveGeneration += 1
        consumeTask?.cancel()
        consumeTask = nil
    }

    public func clearLive() {
        liveEvents.removeAll()
    }

    /// A superseded read cannot relabel the displayed evidence as another day.
    public func loadReplay(for date: Date) async -> (exists: Bool, skipped: Int)? {
        replayGeneration += 1
        let generation = replayGeneration
        let url = lane.path(for: date)
        let result = await Task.detached(priority: .userInitiated) {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let parsed = TurnTraceReplayReader.read(url)
            return (exists: exists, events: parsed.events, skipped: parsed.skipped)
        }.value
        guard generation == replayGeneration else { return nil }
        replayEvents = result.events
        return (result.exists, result.skipped)
    }
}
