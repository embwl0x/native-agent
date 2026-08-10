import Foundation
import PersistenceCore

/// Typed, content-bounded observation over the existing TurnTrace bus.
///
/// This owner can subscribe and project only. It has no request, prompt,
/// tool-argument, result, approval, persistence, or dispatch mutation API.
actor NativeDiagnosticObserver {
    static let shared = NativeDiagnosticObserver()

    struct Subscription: Sendable {
        let id: UUID
        let stream: AsyncStream<ExperienceDiagnosticEvent>
    }

    private struct LiveSubscription {
        let sourceID: UUID
        let task: Task<Void, Never>
    }

    private var subscriptions: [UUID: LiveSubscription] = [:]

    func subscribe() async -> Subscription {
        let source = await TurnTraceBus.shared.subscribe()
        let id = UUID()
        let pair = AsyncStream<ExperienceDiagnosticEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let task = Task {
            var ordinal = 0
            for await event in source.stream {
                guard !Task.isCancelled else { break }
                pair.continuation.yield(.project(event, ordinal: ordinal))
                ordinal &+= 1
            }
            pair.continuation.finish()
        }
        subscriptions[id] = LiveSubscription(sourceID: source.id, task: task)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return Subscription(id: id, stream: pair.stream)
    }

    func unsubscribe(_ id: UUID) async {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        subscription.task.cancel()
        await TurnTraceBus.shared.unsubscribe(subscription.sourceID)
    }
}
