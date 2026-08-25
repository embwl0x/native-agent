import Foundation
import PersistenceCore

/// Typed, content-bounded observation over the existing TurnTrace bus.
///
/// This owner can subscribe and project only. It has no request, prompt,
/// tool-argument, result, approval, persistence, or dispatch mutation API.
actor NativeDiagnosticObserver {
    static let shared = NativeDiagnosticObserver()

    private let bus: TurnTraceBus
    /// Test-only scheduling seam. Production uses the default no-op: relay
    /// delivery remains an unblocked projection of the bounded bus stream.
    private let beforeProjection: @Sendable () async -> Void

    init(
        bus: TurnTraceBus = .shared,
        beforeProjection: @escaping @Sendable () async -> Void = {}
    ) {
        self.bus = bus
        self.beforeProjection = beforeProjection
    }

    struct Subscription: Sendable {
        let id: UUID
        let stream: AsyncStream<ExperienceDiagnosticEvent>
        /// The bus counter belongs to this exact projection sink.  Consumers
        /// must surface it rather than treating a thinned live stream as a
        /// complete diagnostic timeline.
        let dropCount: @Sendable () async -> Int
    }

    private struct LiveSubscription {
        let sourceID: UUID
        let task: Task<Void, Never>
    }

    private var subscriptions: [UUID: LiveSubscription] = [:]
    /// The observer has a second bounded stream after the bus sink. Count its
    /// drops too: the UI consumes this projection, so a terminal burst can be
    /// lost here even when the bus worker drained its source promptly.
    private var projectionDrops: [UUID: Int] = [:]

    func subscribe(capacity: Int = 256) async -> Subscription {
        let source = await bus.subscribe(capacity: max(1, capacity))
        let id = UUID()
        let pair = AsyncStream<ExperienceDiagnosticEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, capacity))
        )
        let projectionBarrier = beforeProjection
        let task = Task { [weak self] in
            var ordinal = 0
            for await event in source.stream {
                guard !Task.isCancelled else { break }
                await projectionBarrier()
                guard !Task.isCancelled else { break }
                if case .dropped = pair.continuation.yield(.project(event, ordinal: ordinal)) {
                    await self?.recordProjectionDrop(id)
                }
                ordinal &+= 1
            }
            pair.continuation.finish()
        }
        subscriptions[id] = LiveSubscription(sourceID: source.id, task: task)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return Subscription(
            id: id,
            stream: pair.stream,
            dropCount: { [weak self, bus] in
                let busDrops = await bus.dropCount(source.id)
                let projectionDrops = await self?.projectionDropCount(id) ?? 0
                return busDrops + projectionDrops
            }
        )
    }

    private func recordProjectionDrop(_ id: UUID) {
        projectionDrops[id, default: 0] += 1
    }

    private func projectionDropCount(_ id: UUID) -> Int {
        projectionDrops[id, default: 0]
    }

    func unsubscribe(_ id: UUID) async {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        projectionDrops.removeValue(forKey: id)
        subscription.task.cancel()
        await bus.unsubscribe(subscription.sourceID)
    }
}
