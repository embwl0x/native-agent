import Foundation

/// Dependency-neutral source invalidation emitted only after a canonical write
/// succeeds. Derived systems use this as a wake-up signal and must reread the
/// canonical owner rather than treating the event as source data.
public struct DerivedSourceChange: Codable, Equatable, Hashable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case changed
        case removed
        case reconcile
    }

    public let namespace: String
    public let stableID: String
    public let operation: Operation
    public let canonicalLocator: String?
    public let reason: String
    public let semantic: Bool
    public let occurredAt: Date

    public init(
        namespace: String,
        stableID: String,
        operation: Operation,
        canonicalLocator: String? = nil,
        reason: String,
        semantic: Bool = true,
        occurredAt: Date = Date()
    ) {
        self.namespace = Self.normalized(namespace, fallback: "unknown")
        self.stableID = Self.normalized(stableID, fallback: "unknown")
        self.operation = operation
        self.canonicalLocator = canonicalLocator
        self.reason = Self.normalized(reason, fallback: "source_change")
        self.semantic = semantic
        self.occurredAt = occurredAt
    }

    private static func normalized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// Implemented by a process-owned derived-state coordinator. Canonical owners
/// depend only on this base protocol, so persona/memory/skills do not acquire a
/// dependency on ContextFlow or any other derived index.
public protocol DerivedStateInvalidationSink: Sendable {
    func sourceDidChange(_ changes: [DerivedSourceChange]) async
}

public extension DerivedStateInvalidationSink {
    func sourceDidChange(_ change: DerivedSourceChange) async {
        await sourceDidChange([change])
    }
}

/// Useful default for isolated tools/tests. Production composition should pass
/// the process-owned coordinator adapter explicitly.
public struct NoopDerivedStateInvalidationSink: DerivedStateInvalidationSink {
    public init() {}

    public func sourceDidChange(_ changes: [DerivedSourceChange]) async {}
}

/// Process-wide event bridge from canonical owners to rebuildable derived
/// systems. Writes remain complete when no sink is installed; events are
/// advisory wake-ups and never become a second source of truth.
public actor DerivedStateInvalidationCenter {
    public static let shared = DerivedStateInvalidationCenter()

    private struct ChangeKey: Hashable {
        let namespace: String
        let stableID: String
    }

    private let coalescingNanoseconds: UInt64
    private var sink: (any DerivedStateInvalidationSink)?
    private var pending: [ChangeKey: DerivedSourceChange] = [:]
    private var deliveryTask: Task<Void, Never>?
    private var deliveryGeneration: UInt64 = 0

    public init(coalescingNanoseconds: UInt64 = 150_000_000) {
        self.coalescingNanoseconds = coalescingNanoseconds
    }

    public func install(_ sink: (any DerivedStateInvalidationSink)?) {
        self.sink = sink
        guard sink == nil else { return }
        deliveryGeneration &+= 1
        deliveryTask?.cancel()
        deliveryTask = nil
        pending.removeAll(keepingCapacity: true)
    }

    public func publish(_ change: DerivedSourceChange) async {
        await publish([change])
    }

    public func publish(_ changes: [DerivedSourceChange]) async {
        guard sink != nil, !changes.isEmpty else { return }
        for change in changes {
            pending[ChangeKey(namespace: change.namespace, stableID: change.stableID)] = change
        }
        guard deliveryTask == nil else { return }
        deliveryGeneration &+= 1
        let expectedGeneration = deliveryGeneration
        let delay = coalescingNanoseconds
        deliveryTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.scheduledDeliveryFired(expectedGeneration)
        }
    }

    public func flush() async {
        deliveryGeneration &+= 1
        let scheduledDelivery = deliveryTask
        deliveryTask = nil
        scheduledDelivery?.cancel()
        await deliverPending()
    }

    /// The coalescing task must not route through `flush()`: doing so cancels
    /// the task that is currently delivering and leaks cancellation into the
    /// derived-state sink. Explicit flushes still cancel the outstanding delay.
    private func scheduledDeliveryFired(_ expectedGeneration: UInt64) async {
        guard expectedGeneration == deliveryGeneration else { return }
        deliveryTask = nil
        await deliverPending()
    }

    private func deliverPending() async {
        guard let sink, !pending.isEmpty else { return }
        let changes = pending.values.sorted {
            if $0.namespace != $1.namespace { return $0.namespace < $1.namespace }
            if $0.stableID != $1.stableID { return $0.stableID < $1.stableID }
            return $0.occurredAt < $1.occurredAt
        }
        pending.removeAll(keepingCapacity: true)
        await sink.sourceDidChange(changes)
    }
}
