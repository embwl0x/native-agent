import Foundation

// Blueprint: | `DerivedStateInvalidation.swift` | `DerivedStateInvalidationCenter`: post-write canonical-source invalidations and coalesced sink delivery; derived owners must reread truth |

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
    private var debounceTask: Task<Void, Never>?
    private var activeDelivery: Task<Void, Never>?
    private var activeGeneration: UInt64?
    private var deliveryGeneration: UInt64 = 0

    public init(coalescingNanoseconds: UInt64 = 150_000_000) {
        self.coalescingNanoseconds = coalescingNanoseconds
    }

    public func install(_ sink: (any DerivedStateInvalidationSink)?) {
        self.sink = sink
        deliveryGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        activeDelivery?.cancel()
        if sink == nil { pending.removeAll(keepingCapacity: true) }
        schedulePendingDelivery()
    }

    deinit { debounceTask?.cancel(); activeDelivery?.cancel() }

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
        schedulePendingDelivery()
    }

    private func schedulePendingDelivery() {
        guard sink != nil, !pending.isEmpty, debounceTask == nil, activeDelivery == nil else { return }
        deliveryGeneration &+= 1
        let expectedGeneration = deliveryGeneration
        let delay = coalescingNanoseconds
        debounceTask = Task { [weak self] in
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

    /// Nobody joins a delivery: writers publish and return, and derived
    /// owners rebuild on their own.
    private func scheduledDeliveryFired(_ expectedGeneration: UInt64) {
        guard expectedGeneration == deliveryGeneration else { return }
        debounceTask = nil
        startPendingDelivery(expectedGeneration)
    }

    private func startPendingDelivery(_ expectedGeneration: UInt64) {
        guard let sink, !pending.isEmpty, activeDelivery == nil else { return }
        let changes = pending.values.sorted {
            if $0.namespace != $1.namespace { return $0.namespace < $1.namespace }
            if $0.stableID != $1.stableID { return $0.stableID < $1.stableID }
            if $0.canonicalLocator != $1.canonicalLocator {
                return ($0.canonicalLocator ?? "") < ($1.canonicalLocator ?? "")
            }
            return $0.occurredAt < $1.occurredAt
        }
        pending.removeAll(keepingCapacity: true)
        // The debounce timer and entered delivery have separate lifetimes.
        // Sink replacement requests cancellation but retains exclusion until
        // the old sink actually returns; writers never join that execution.
        activeGeneration = expectedGeneration
        activeDelivery = Task { [weak self] in
            if !Task.isCancelled { await sink.sourceDidChange(changes) }
            await self?.deliveryFinished(expectedGeneration)
        }
    }

    private func deliveryFinished(_ expectedGeneration: UInt64) {
        guard activeGeneration == expectedGeneration else { return }
        activeDelivery = nil
        activeGeneration = nil
        schedulePendingDelivery()
    }
}
