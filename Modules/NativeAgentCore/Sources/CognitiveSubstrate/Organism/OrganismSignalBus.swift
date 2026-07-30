import Foundation

public protocol SomaticSignalObserving: Sendable {
    func observe(_ signal: SomaticSignal) async
}

extension OrganismKernel: SomaticSignalObserving {
    public func observe(_ signal: SomaticSignal) async {
        await ingest(signal)
    }
}

public struct SomaticSignalBusDependencies: Sendable {
    public var makeUUID: @Sendable () -> UUID

    public init(makeUUID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.makeUUID = makeUUID
    }

    public static let live = SomaticSignalBusDependencies()
}

public actor SomaticSignalBus {
    private var configuration: OrganismConfiguration
    private let observer: any SomaticSignalObserving
    private let dependencies: SomaticSignalBusDependencies
    private var deliveredEventKeys: Set<String> = []
    private var deliveredEventKeyOrder: [String] = []

    /// Matches the continuity field's bounded replay horizon. Oldest keys are
    /// evicted in batches, keeping insertion amortized O(1) on the hot path.
    private static let maximumDeliveredEventKeys = 4_096
    private static let deliveredEventKeyEvictionBatch = 512

    public init(
        configuration: OrganismConfiguration = .disabled,
        observer: any SomaticSignalObserving,
        dependencies: SomaticSignalBusDependencies = .live
    ) {
        self.configuration = configuration
        self.observer = observer
        self.dependencies = dependencies
    }

    public func configure(_ configuration: OrganismConfiguration) async {
        self.configuration = configuration
    }

    @discardableResult
    public func observe(_ event: CognitiveEvent) async -> SomaticSignal? {
        guard configuration.enabled else { return nil }
        let eventKey = event.deduplicationKey
        guard !deliveredEventKeys.contains(eventKey) else { return nil }
        guard let signal = CognitiveSomaticSignalAdapter.signal(
            from: event,
            id: dependencies.makeUUID(),
            bounds: configuration.metadataBounds
        ) else {
            return nil
        }
        // Mark before the observer await so a reentrant replay cannot be
        // delivered while the first observation is still being integrated.
        deliveredEventKeys.insert(eventKey)
        rememberDeliveredEventKey(eventKey)
        await observer.observe(signal)
        return signal
    }

    private func rememberDeliveredEventKey(_ key: String) {
        deliveredEventKeyOrder.append(key)
        guard deliveredEventKeyOrder.count > Self.maximumDeliveredEventKeys else { return }
        let overflow = deliveredEventKeyOrder.count - Self.maximumDeliveredEventKeys
        let dropCount = min(
            deliveredEventKeyOrder.count,
            overflow + Self.deliveredEventKeyEvictionBatch
        )
        for stale in deliveredEventKeyOrder.prefix(dropCount) {
            deliveredEventKeys.remove(stale)
        }
        deliveredEventKeyOrder.removeFirst(dropCount)
    }
}
