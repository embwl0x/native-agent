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

/// Process-wide event bridge from canonical owners to rebuildable derived
/// systems. Writes remain complete when no sink is installed; events are
/// advisory wake-ups and never become a second source of truth.
public actor DerivedStateInvalidationCenter {
    public static let shared = DerivedStateInvalidationCenter()

    private struct ChangeKey: Hashable {
        let namespace: String
        let stableID: String
        let canonicalLocator: String?
    }

    private let coalescingNanoseconds: UInt64
    private var sink: (any DerivedStateInvalidationSink)?
    private var pending: [ChangeKey: DerivedSourceChange] = [:]
    private var deliveryTask: Task<Void, Never>?
    private var deliveryGeneration: UInt64 = 0
    private var sinkEpoch: UInt64 = 0
    private var nextDeliveryID: UInt64 = 0
    private struct Delivery {
        let sinkEpoch: UInt64
        let task: Task<Void, Never>
    }
    private var inFlightDeliveries: [UInt64: Delivery] = [:]

    public init(coalescingNanoseconds: UInt64 = 150_000_000) {
        self.coalescingNanoseconds = coalescingNanoseconds
    }

    public func install(_ sink: (any DerivedStateInvalidationSink)?) {
        sinkEpoch &+= 1
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
            // Candidate databases retain the live row IDs. Their changes must
            // not replace a live-root change while this batch is coalescing.
            pending[ChangeKey(
                namespace: change.namespace,
                stableID: change.stableID,
                canonicalLocator: change.canonicalLocator
            )] = change
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
        await flush(onAdmission: nil)
    }

    /// Internal admission receipt keeps concurrency fixtures deterministic
    /// without exposing payloads or adding a production observer API.
    func flush(onAdmission: (@Sendable (Int) -> Void)?) async {
        deliveryGeneration &+= 1
        let scheduledDelivery = deliveryTask
        deliveryTask = nil
        scheduledDelivery?.cancel()
        startPendingDelivery()
        // Snapshot one boundary before suspending. New publishes belong to a
        // later flush; detached deliveries for an old installation cannot
        // hold a new owner hostage. Earlier flushes retain their own tasks.
        let admitted = inFlightDeliveries.sorted { $0.key < $1.key }
            .map(\.value).filter { $0.sinkEpoch == sinkEpoch }.map(\.task)
        onAdmission?(admitted.count)
        for delivery in admitted { await delivery.value }
    }

    /// The coalescing task must not route through `flush()`: doing so cancels
    /// the task that is currently delivering and leaks cancellation into the
    /// derived-state sink. Explicit flushes still cancel the outstanding delay.
    private func scheduledDeliveryFired(_ expectedGeneration: UInt64) async {
        guard expectedGeneration == deliveryGeneration else { return }
        deliveryTask = nil
        startPendingDelivery()
    }

    private func startPendingDelivery() {
        guard let sink, !pending.isEmpty else { return }
        let changes = pending.values.sorted {
            if $0.namespace != $1.namespace { return $0.namespace < $1.namespace }
            if $0.stableID != $1.stableID { return $0.stableID < $1.stableID }
            if $0.canonicalLocator != $1.canonicalLocator {
                return ($0.canonicalLocator ?? "") < ($1.canonicalLocator ?? "")
            }
            return $0.occurredAt < $1.occurredAt
        }
        pending.removeAll(keepingCapacity: true)
        nextDeliveryID &+= 1
        let id = nextDeliveryID
        // This center owns delivery, not the flushing caller or delay timer.
        // Canceling either must not cancel the canonical refresh in the sink.
        let task = Task<Void, Never> { [weak self] in
            await sink.sourceDidChange(changes)
            await self?.deliveryFinished(id)
        }
        inFlightDeliveries[id] = Delivery(sinkEpoch: sinkEpoch, task: task)
    }

    private func deliveryFinished(_ id: UInt64) {
        inFlightDeliveries[id] = nil
    }
}
