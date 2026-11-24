import Synchronization
import Foundation
import AppKit
import CryptoKit
import Darwin
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `SensesHub.swift` | Owned installation readiness, watch inventory and exact-version provenance |
/// Wire at launch so Core readers reach senses without depending on the app; nil means not installed.
public final class SensesHub: Sendable {
    public static let shared = SensesHub()
    /// Use installation's own success edge rather than another readiness snapshot.
    public struct DidBecomeReady: NotificationCenter.AsyncMessage {
        public typealias Subject = SensesHub
        public init() {}
    }
    private struct State {
        var registry: FileSenseRegistry?
        var runner: HelperSenseRunner?
        var source: SenseSourceProvider?
        var memoryProvenanceSink: (any SenseMemoryProvenanceSink)?
        var installation: (task: Task<Void, Error>, finished: ScopedWaiter)?
    }
    private let state = Mutex(State())
    // Installation settles on registration success or failure; cancelling a waiter leaves installation and sibling waiters alive.

    public func installReadiness(_ task: Task<Void, Error>, finished: ScopedWaiter) {
        state.withLock { state in
            state.installation = (task, finished)
        }
    }

    private var installation: (task: Task<Void, Error>, finished: ScopedWaiter)? {
        state.withLock { $0.installation }
    }

    public func waitUntilReady() async throws {
        guard let installation else {
            throw SenseFailure(code: "source_unavailable", message: "Senses installation has not started.")
        }
        await installation.finished.park()
        try Task.checkCancellation()
        try await installation.task.value
    }
    public func installMemoryProvenanceSink(_ sink: any SenseMemoryProvenanceSink) {
        state.withLock { state in
            state.memoryProvenanceSink = sink
        }
    }
    /// Record served evidence only after serving a page and before returning it.
    public func didServe(_ provenance: SenseProvenance, reads: SenseTurnReads?) {
        reads?.record(provenance)
    }
    /// Attribute a wrong view to the exact version that served it.
    public func markVersionWrong(senseID: String, version: Int) async throws {
        let sink = memoryProvenanceSink
        guard let sink else {
            throw SenseFailure(code: "memory_unavailable", message: "Cannot flag memories: sense memory provenance is not wired.")
        }
        try await sink.markVersionWrong(senseID: senseID, version: version)
    }
    private var memoryProvenanceSink: (any SenseMemoryProvenanceSink)? {
        state.withLock { $0.memoryProvenanceSink }
    }
    public func install(registry: FileSenseRegistry?, runner: HelperSenseRunner?, source: SenseSourceProvider?) {
        state.withLock {
            $0.registry = registry
            $0.runner = runner
            $0.source = source
        }
        NotificationCenter.default.post(SenseNewsBoard.PresentationDidChange())
    }
    public var registry: FileSenseRegistry? { state.withLock { $0.registry } }
    public var runner: HelperSenseRunner? { state.withLock { $0.runner } }
    public var source: SenseSourceProvider? { state.withLock { $0.source } }
    @concurrent public func liveWatches() async -> [SenseLiveWatch] {
        let runner = self.runner
        let source = self.source as? any SenseWatchReporting
        async let helpers = runner?.liveWatches() ?? []
        async let native = source?.liveWatches() ?? []
        let watches = await helpers + native
        return watches.sorted {
            ($0.address, $0.senseID, $0.version) < ($1.address, $1.senseID, $1.version)
        }
    }
    @MainActor
    public func presentationRecords() async throws -> ([SenseRecord], [SenseCorner: String]) {
        return try await Task.detached(priority: .utility) { [registry] in
            let records = try registry?.presentationRecords() ?? []
            return (records.sorted { $0.corner.key < $1.corner.key },
             Dictionary(uniqueKeysWithValues: Set(records.map(\.corner)).map { ($0, $0.surfaceName) }))
        }.value
    }
    @MainActor
    package func receiveViewEvent(_ event: JSONValue, presentation: SenseInteractiveView, revision: String) async -> String? {
        guard let registry, let source, let receiver = runner else {
            return "This sense cannot receive view events yet."
        }
        do {
            guard let record = try await registry.all().first(where: {
                $0.id == presentation.senseID && $0.version == presentation.version && $0.status == .on
            }), !Task.isCancelled else {
                return "This sense is off or its view has changed."
            }
            if case .failed(let failure) = await receiver.run(record, request: .event(event, revision: revision), source: source,
                operation: .init(turn: nil)) {
                throw failure
            }
            return nil
        } catch {
            return "This sense could not handle the event: \(error.localizedDescription)"
        }
    }
}
