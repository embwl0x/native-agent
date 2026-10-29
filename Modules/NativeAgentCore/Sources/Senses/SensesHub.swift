import AuthoredCapabilities
import Foundation
import AppKit
import CryptoKit
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SensesHub.swift` | Lock-protected sense installation, live-watch aggregation, exact-version view events and served/wrong-version provenance |
/// Process-wide wiring, set once at launch by the app, so Core call sites
/// (the door and the readers) reach the senses without
/// depending on the app. Every member is optional: nil = senses not wired.
public final class SensesHub: @unchecked Sendable {
    public static let shared = SensesHub()
    private let lock = NSLock()
    private var _registry: FileSenseRegistry?
    private var _runner: HelperSenseRunner?
    private var _source: SenseSourceProvider?
    private var _memoryProvenanceSink: (any SenseMemoryProvenanceSink)?
    private var _crossing: (any SenseCrossing)?
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
    /// Call for viewWrong and for the version being withdrawn on rollback.
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
