import Foundation
import Observation
// Blueprint: | `FaceFeed.swift` | Finished values, replayable connection sinks and applied-frame barriers for local and remote faces |

/// Where a finished value lives on a face. One key, one slot: a change at a key redraws only what reads that key.
public enum FaceKey: Hashable, Sendable, Codable {
    case transcript(session: String)
    case sessions
    case session(String)
    case sessionNavigation
    case sessionPalette
    case sessionSearch(UUID)
    case page(String)
    case turn(session: String)
    case turns
    case counts
    case settings
    // Inspector content survives its readers; remounting selects the same evidence slot.
    case inspector(after: Date?)
    case inspectorReplay(day: Date)
    case layout
    case conversation(session: String)
    case document(UUID)
    case agentScreen(room: String, scope: String?)
    case palette(UUID)
    case deskPalette(UUID)
    case deskDiagnostics
    case workDetail(kind: String, id: String)
    case contacts
    case contactThread(String)
    case helpers
    case helperRuns(String)
    case makeShelf
    case makePreview(reference: String, version: String)
    case senseView
    case memoryDiagnostics
    case knowledgeGraph
    case graphNeighborhood(entity: String)
    case dreamDiary
    case dreamEntry(date: String)
    case cognition
    case contextFlowHealth
    case mood
    case runs
    case run(String)
    case onboarding
    case contextReceipt(session: String)
    case macControl
    case voice(UUID)
}

/// A value a face draws. Codable because the same values cross the process wall when her body runs apart from the window.
public protocol FaceValue: Sendable, Equatable, Codable {}

/// A type-erased value that still knows how to compare itself, so an unchanged value never reaches a view.
public struct AnyFaceValue: Sendable {
    public let base: any FaceValue
    private let equals: @Sendable (any FaceValue) -> Bool

    public init<Value: FaceValue>(_ value: Value) {
        base = value
        equals = { other in (other as? Value) == value }
    }

    public func same(as other: AnyFaceValue) -> Bool { equals(other.base) }
}

/// Everything that arrived since a face last drew: the latest value per key, and text appended to live lines in order.
public struct FaceBatch: Sendable, Codable {
    public var values: [FaceKey: AnyFaceValue] = [:]
    public var appends: [FaceKey: String] = [:]
    public var barriers: [UUID] = []
    public var removals: Set<FaceKey> = []
    public var epoch: UUID?
    public var sequence: UInt64 = 0
    public var replacesAll = false
    public var isEmpty: Bool { values.isEmpty && appends.isEmpty && barriers.isEmpty && removals.isEmpty && !replacesAll }
    public init() {}
}

/// The agent's side. Her owners post finished values from wherever they run; nothing here touches a face's thread. A value replaces
/// the pending one at its key; appended text joins what is pending for its key. The first post into an empty batch signals the face once.
public actor FaceFeedSource {
    private var pending = FaceBatch()
    private var retained = FaceBatch()
    private var sinks: [UUID: FaceFeedSinkState] = [:]
    private var remoteBarriers: [UUID: FaceRemoteBarrier] = [:]
    private var barriers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private let signal: AsyncStream<Void>.Continuation
    public nonisolated let arrivals: AsyncStream<Void>

    public init() {
        (arrivals, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func post<Value: FaceValue>(_ value: Value, at key: FaceKey) {
        let erased = AnyFaceValue(value)
        if let previous = retained.values[key], previous.same(as: erased) { return }
        let wasEmpty = pending.isEmpty
        pending.values[key] = erased
        pending.removals.remove(key)
        retained.values[key] = erased
        var change = FaceBatch()
        change.values[key] = erased
        forward(change)
        if wasEmpty { signal.yield() }
    }

    /// A live line grows by appends; the face extends what it holds and never rebuilds it.
    public func append(_ text: String, at key: FaceKey) {
        guard !text.isEmpty else { return }
        let wasEmpty = pending.isEmpty
        pending.appends[key, default: ""] += text
        retained.appends[key, default: ""] += text
        var change = FaceBatch()
        change.appends[key] = text
        forward(change)
        if wasEmpty { signal.yield() }
    }

    public func take() -> FaceBatch {
        defer { pending = FaceBatch() }
        return pending
    }

    public func remove(_ key: FaceKey) {
        guard retained.values.removeValue(forKey: key) != nil || retained.appends[key] != nil else { return }
        retained.appends.removeValue(forKey: key)
        let wasEmpty = pending.isEmpty
        pending.values.removeValue(forKey: key)
        pending.appends.removeValue(forKey: key)
        pending.removals.insert(key)
        var change = FaceBatch()
        change.removals.insert(key)
        forward(change)
        if wasEmpty { signal.yield() }
    }

    /// Each connection receives a complete base before its ordered changes.
    public func attachSink() -> FaceFeedSink {
        let id = UUID()
        let (batches, continuation) = AsyncThrowingStream<FaceBatch, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.detachSink(id, cause: FaceWireError.disconnected) }
        }
        sinks[id] = FaceFeedSinkState(continuation: continuation)
        var base = retained
        base.replacesAll = true
        deliver(base, to: id)
        return FaceFeedSink(epoch: id, batches: batches)
    }

    public func detachSink(_ epoch: UUID, cause: any Error = FaceWireError.disconnected) {
        sinks.removeValue(forKey: epoch)?.continuation.finish(throwing: cause)
        let waiting = remoteBarriers.filter { $0.value.epoch == epoch }
        for (id, barrier) in waiting {
            remoteBarriers.removeValue(forKey: id)
            barrier.continuation?.resume(throwing: cause)
        }
    }

    /// Only an actual applied-frame receipt releases this connection's barrier.
    @discardableResult public func flush(sink epoch: UUID) async throws -> UUID {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let sink = sinks[epoch] else { throw FaceWireError.disconnected }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                remoteBarriers[id] = FaceRemoteBarrier(epoch: epoch, sequence: sink.sequence, continuation: continuation)
                var batch = FaceBatch()
                batch.barriers = [id]
                deliver(batch, to: epoch)
            }
        } onCancel: {
            Task { await self.cancelRemoteBarrier(id) }
        }
        return id
    }

    public func applied(epoch: UUID, sequence: UInt64, barriers ids: [UUID]) throws {
        guard var sink = sinks[epoch] else {
            throw WireFailure(code: "frame_receipt_epoch", message: "The applied frame's connection is not attached.",
                              cause: "Epoch \(epoch); sequence \(sequence)", effects: .none)
        }
        guard sequence > sink.appliedSequence, sequence < sink.sequence else {
            throw WireFailure(code: "frame_receipt_sequence", message: "The applied frame is not a new delivered sequence.",
                cause: "Epoch \(epoch); received \(sequence), applied \(sink.appliedSequence), next \(sink.sequence)", effects: .none)
        }
        guard Set(ids).count == ids.count, ids.allSatisfy({ id in
            guard let barrier = remoteBarriers[id] else { return false }
            return barrier.epoch == epoch && barrier.sequence <= sequence
        }) else {
            throw WireFailure(code: "frame_receipt_barriers", message: "The applied frame contains duplicate or unheld barriers.",
                cause: "Epoch \(epoch); sequence \(sequence); barriers " + ids.map(\.uuidString).joined(separator: ","), effects: .none)
        }
        sink.appliedSequence = sequence
        sinks[epoch] = sink
        for id in ids { remoteBarriers.removeValue(forKey: id)?.continuation?.resume() }
    }

    private func cancelRemoteBarrier(_ id: UUID) {
        guard var barrier = remoteBarriers[id] else { return }
        let continuation = barrier.continuation
        barrier.continuation = nil
        // The barrier is already in the sink stream; only its waiter is cancelled.
        remoteBarriers[id] = barrier
        continuation?.resume(throwing: CancellationError())
    }

    private func forward(_ batch: FaceBatch) {
        for id in Array(sinks.keys) { deliver(batch, to: id) }
    }

    private func deliver(_ batch: FaceBatch, to epoch: UUID) {
        guard var sink = sinks[epoch] else { return }
        let (next, overflow) = sink.sequence.addingReportingOverflow(1)
        guard !overflow else { detachSink(epoch, cause: FaceWireError.invalidFeedOrder); return }
        var frame = batch
        frame.epoch = epoch
        frame.sequence = sink.sequence
        sink.sequence = next
        sinks[epoch] = sink
        sink.continuation.yield(frame)
    }

    /// A capture waits for its queued values to reach the face's frame; cancellation ends the wait without drawing early.
    fileprivate func flush() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let wasEmpty = pending.isEmpty
                barriers[id] = continuation
                pending.barriers.append(id)
                if wasEmpty { signal.yield() }
            }
        } onCancel: {
            Task { await self.cancelBarrier(id) }
        }
    }

    fileprivate func applied(_ batch: FaceBatch) {
        for id in batch.barriers { barriers.removeValue(forKey: id)?.resume() }
    }

    private func cancelBarrier(_ id: UUID) {
        pending.barriers.removeAll { $0 == id }
        barriers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

/// One key's current value on a face. Views observe a slot, so only the views reading this key redraw when it changes.
@MainActor @Observable
public final class FaceSlot {
    public private(set) var value: AnyFaceValue?
    /// Text appended to this key's live line since the face last took it.
    public private(set) var appended = ""
    @ObservationIgnored fileprivate var generation = 0
    /// The value as selections read it, outside observation, so a selection never ties its reader to the whole value.
    @ObservationIgnored private var current: AnyFaceValue?
    @ObservationIgnored private var selections: [String: any FaceSelectionBox] = [:]

    fileprivate init() {}

    @discardableResult fileprivate func apply(_ next: AnyFaceValue) -> Bool {
        if let value, value.same(as: next) { return false }
        current = next
        value = next
        for selection in selections.values { selection.refresh(next) }
        return true
    }

    fileprivate func clear() {
        current = nil
        value = nil
        appended = ""
        for selection in selections.values { selection.refresh(nil) }
    }

    /// The one part of this key's value a view draws. The view redraws when that part changes, never for the rest of the value.
    /// A name is one projection: the same name always selects the same part.
    public func select<Value: FaceValue, Part: Equatable>(_ name: String, as type: Value.Type,
                                                          _ part: @escaping (Value?) -> Part) -> Part {
        if let selection = selections[name] as? FaceSelection<Value, Part> { return selection.part }
        let selection = FaceSelection(part, from: current)
        selections[name] = selection
        return selection.part
    }

    fileprivate func extend(_ text: String) { appended += text }

    /// The live line's reader consumes what it has drawn.
    public func takeAppended() -> String {
        defer { appended = "" }
        return appended
    }

    public func value<Value: FaceValue>(as type: Value.Type) -> Value? { value?.base as? Value }
}

@MainActor
private protocol FaceSelectionBox: AnyObject {
    func refresh(_ value: AnyFaceValue?)
}

/// A selection observes only its part; the slot refreshes it with each new value and it changes only when the part does.
@MainActor @Observable
private final class FaceSelection<Value: FaceValue, Part: Equatable>: FaceSelectionBox {
    private(set) var part: Part
    @ObservationIgnored private let project: (Value?) -> Part

    init(_ project: @escaping (Value?) -> Part, from value: AnyFaceValue?) {
        self.project = project
        part = project(value?.base as? Value)
    }

    func refresh(_ value: AnyFaceValue?) {
        let next = project(value?.base as? Value)
        if next != part { part = next }
    }
}

/// The face's side: the only agent state its views read. It waits for the source's arrival signal, then for the face's next frame,
/// and applies everything that arrived in one pass. A burst of updates is one redraw.
@MainActor
public final class FaceFeed {
    private var slots: [FaceKey: FaceSlot] = [:]
    private let source: FaceFeedSource?
    private var remoteEpoch: UUID?
    private var remoteSequence: UInt64 = 0
    /// The window records accepted page application separately from layout and drawing.
    public var onPageApplied: (@MainActor (String, PartFaceSnapshot, TimeInterval) -> Void)?

    public init() { source = nil }

    /// `nextFrame` is the face's own display rhythm (a display link on the Mac, CADisplayLink on the phone).
    public init(source: FaceFeedSource, nextFrame: @escaping @MainActor () async -> Void) {
        self.source = source
        // The drain ends with the feed: it holds the feed weakly and returns at the next arrival after the feed is gone.
        Task { @MainActor [weak self, source] in
            for await _ in source.arrivals {
                await nextFrame()
                let batch = await source.take()
                guard let self else { return }
                self.apply(batch)
                await source.applied(batch)
            }
        }
    }

    public func slot(_ key: FaceKey) -> FaceSlot {
        if let slot = slots[key] { return slot }
        let slot = FaceSlot()
        slots[key] = slot
        return slot
    }

    public func flush() async throws {
        guard let source else { throw FaceWireError.disconnected }
        try await source.flush()
        try Task.checkCancellation()
    }

    private func apply(_ batch: FaceBatch) {
        if batch.replacesAll { for slot in slots.values { slot.clear() } }
        for key in batch.removals { slots[key]?.clear() }
        for (key, value) in batch.values {
            if case .page(let page) = key, let snapshot = value.base as? PartFaceSnapshot, let onPageApplied {
                let started = ProcessInfo.processInfo.systemUptime
                let changed = slot(key).apply(value)
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if changed { onPageApplied(page, snapshot, elapsed) }
            } else { slot(key).apply(value) }
        }
        for (key, text) in batch.appends { slot(key).extend(text) }
    }

    /// The connection schedules this once per display frame and acknowledges the returned batch's barriers afterward.
    public func applyRemote(_ batch: FaceBatch) throws {
        guard let epoch = batch.epoch else { throw FaceWireError.invalidFeedOrder }
        let (expected, overflow) = remoteSequence.addingReportingOverflow(1)
        guard !overflow, batch.sequence == expected,
              remoteEpoch == epoch || (remoteEpoch == nil && batch.replacesAll) else { throw FaceWireError.invalidFeedOrder }
        remoteEpoch = epoch
        remoteSequence = batch.sequence
        apply(batch)
    }

    public func disconnect() {
        for slot in slots.values { slot.clear() }
        remoteEpoch = nil
        remoteSequence = 0
    }
}

public struct FaceFeedSink: Sendable {
    public let epoch: UUID
    public let batches: AsyncThrowingStream<FaceBatch, Error>
}

private struct FaceFeedSinkState {
    let continuation: AsyncThrowingStream<FaceBatch, Error>.Continuation
    var sequence: UInt64 = 1
    var appliedSequence: UInt64 = 0
}

private struct FaceRemoteBarrier {
    let epoch: UUID
    let sequence: UInt64
    var continuation: CheckedContinuation<Void, Error>?
}
