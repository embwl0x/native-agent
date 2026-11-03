import AuthoredCapabilities
import Foundation
import AppKit
import CryptoKit
import Darwin
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `SensesHub.swift` | Lock-protected sense installation; readiness reads the installation owner's exact task through a cancellation-aware ScopedWaiter bounded to four seconds or the earlier caller deadline, with unavailable reads leaving installation alive; installation success names one repair notification, live-watch aggregation, exact-version view events and served/wrong-version provenance |
/// Process-wide wiring, set once at launch by the app, so Core call sites
/// (the door and the readers) reach the senses without
/// depending on the app. Every member is optional: nil = senses not wired.
public final class SensesHub: @unchecked Sendable {
    public static let shared = SensesHub()
    /// Installation's successful repair edge, not a second readiness snapshot.
    public static let didBecomeReady = Notification.Name("NativeAgent.sensesReady")
    private let lock = NSLock()
    private var _registry: FileSenseRegistry?
    private var _runner: HelperSenseRunner?
    private var _source: SenseSourceProvider?
    private var _memoryProvenanceSink: (any SenseMemoryProvenanceSink)?
    private var _crossing: (any SenseCrossing)?
    // The installation owner's exact task and completion, never a copied
    // ready flag. A cancelled waiter leaves installation and siblings alone.
    private var _installation: (task: Task<Void, Error>, finished: ScopedWaiter)?

    public func installReadiness(_ task: Task<Void, Error>, finished: ScopedWaiter) {
        lock.lock(); defer { lock.unlock() }
        _installation = (task, finished)
    }

    private var installation: (task: Task<Void, Error>, finished: ScopedWaiter)? {
        lock.lock(); defer { lock.unlock() }; return _installation
    }

    public func waitUntilReady() async throws {
        guard let installation else {
            throw SenseFailure(code: "source_unavailable", message: "Senses installation has not started.")
        }
        // Bound only this read's wait. Installation keeps its repair observation
        // and every sibling retains its own parker. Never infer ready from expiry.
        let ceiling = ContinuousClock.now.advanced(by: .seconds(4))
        let deadline = TaskWaitDeadline.current.map { min($0, ceiling) } ?? ceiling
        try await TaskWaitDeadline.$current.withValue(deadline) {
            await installation.finished.park()
            try Task.checkCancellation()
            guard !TaskWaitDeadline.expired else {
                throw SenseFailure(code: "source_unavailable", message: "Senses registration did not finish within this read's readiness wait. Inspect Doctor's Senses installation reading (launch.senses); if it names a failure, preserve and repair that source. A canonical repair change rechecks registration. This sense read did not run; other resident work continues.")
            }
        }
        try Task.checkCancellation()
        if TaskWaitDeadline.expired { throw TaskWaitDeadline.Exceeded() }
        try await installation.task.value
    }
    public func installCrossing(_ crossing: any SenseCrossing) {
        lock.lock(); defer { lock.unlock() }
        _crossing = crossing
    }
    public var crossing: (any SenseCrossing)? { lock.lock(); defer { lock.unlock() }; return _crossing }
    public func installMemoryProvenanceSink(_ sink: any SenseMemoryProvenanceSink) {
        lock.lock(); defer { lock.unlock() }
        _memoryProvenanceSink = sink
    }
    /// Call after a page is actually served in her turn, before returning it.
    public func didServe(_ provenance: SenseProvenance) {
        SenseTurnReads.current?.record(provenance)
    }
    /// Call for viewWrong on the version whose served view was wrong.
    public func markVersionWrong(senseID: String, version: Int) async throws {
        let sink = memoryProvenanceSink
        guard let sink else {
            throw SenseFailure(code: "memory_unavailable", message: "Cannot flag memories: sense memory provenance is not wired.")
        }
        try await sink.markVersionWrong(senseID: senseID, version: version)
    }
    private var memoryProvenanceSink: (any SenseMemoryProvenanceSink)? {
        lock.lock(); defer { lock.unlock() }; return _memoryProvenanceSink
    }
    public func install(registry: FileSenseRegistry?, runner: HelperSenseRunner?, source: SenseSourceProvider?) {
        lock.lock()
        _registry = registry; _runner = runner; _source = source
        lock.unlock()
        NotificationCenter.default.post(name: SenseNewsBoard.presentationDidChange, object: nil)
    }
    public var registry: FileSenseRegistry? { lock.lock(); defer { lock.unlock() }; return _registry }
    public var runner: HelperSenseRunner? { lock.lock(); defer { lock.unlock() }; return _runner }
    public var source: SenseSourceProvider? { lock.lock(); defer { lock.unlock() }; return _source }
    public func liveWatches() async -> [SenseLiveWatch] {
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
    public func receiveViewEvent(_ event: JSONValue, presentation: SenseInteractiveView) async -> String? {
        guard let registry, let source, let receiver = runner else {
            return "This sense cannot receive view events yet."
        }
        do {
            guard let record = try await registry.all().first(where: {
                $0.id == presentation.senseID && $0.version == presentation.version && $0.status == .on
            }), !Task.isCancelled else {
                return "This sense is off or its view has changed."
            }
            try await Self.$passiveObservation.withValue(false) {
                if case .failed(let failure) = await receiver.run(record, request: .event(event), source: source) {
                    throw failure
                }
            }
            return nil
        } catch {
            return "This sense could not handle the event: \(error.localizedDescription)"
        }
    }
    /// Watch entries, source callbacks, restarts and unattended part wakes are
    /// observations, independently of the turn that started the live sense.
    /// On-call admission retains this origin so retirement stops unattended
    /// work while an accepted human interaction settles with its caller.
    @TaskLocal public static var passiveObservation = false
}
