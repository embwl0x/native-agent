import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
// Blueprint: | `PartFaces.swift` | `PartFaces`: native source-change projection owner; frozen packets and source epochs, version/epoch cache, canonical ability-change invalidation, per-part LatestRead publication; cancelled reads publish and cache nothing, preserving the last snapshot and allowing another ask at the same version/epoch; observable and Codable typed rows for Mac/phone consumers; `PartFaceSnapshot` keeps native unavailable/failed/owed beside authored content; synchronous stop retires publication/observation and cancels refreshes before returning their settlement drain (close awaits it); source callers retain and cancel their own reads; no view executes JS, no domain truth store |

/// One source owner's derived faces. Feed it frozen sources from that owner's
/// change handler; views only read snapshots. The injected call enters the
/// owner's current gate chain on every execution, including a part replacement.
/// Nothing here commits domain truth or keeps another durable store.
@MainActor @Observable
public final class PartFaces {
    public typealias Call = @Sendable (_ id: String, _ input: JSONValue, _ version: String) async -> PartCallResult<PartFace>
    public private(set) var snapshots: [String: PartFaceSnapshot] = [:]
    @ObservationIgnored private let dataRoot: URL
    @ObservationIgnored private let call: Call
    @ObservationIgnored private var reads: [String: LatestRead] = [:]
    private struct Source { let epoch: UInt64; let input: JSONValue; let unavailable: String?; let owed: Bool }
    @ObservationIgnored private var sources: [String: Source] = [:]
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var refreshes: [String: Task<Void, Never>] = [:]

    public init(dataRoot: URL, call: @escaping Call) {
        self.dataRoot = dataRoot; self.call = call
        observer = NotificationCenter.default.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { [weak self] event in
            guard let path = event.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.changed(path)
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        for task in refreshes.values { task.cancel() }
    }

    private func changed(_ path: String) {
        guard observer != nil else { return }
        let root = AbilityStore(dataRoot: dataRoot).root
        let url = URL(fileURLWithPath: path)
        let ids: [String]
        if url == root { ids = Array(sources.keys) }
        else if url.deletingLastPathComponent() == root { ids = [url.lastPathComponent] }
        else { return }
        for id in ids {
            guard let source = sources[id] else { continue }
            let previous = refreshes[id]
            previous?.cancel()
            gate(id).write { snapshots.removeValue(forKey: id) }
            refreshes[id] = Task { [weak self] in
                if let previous { await settle { await previous.value } }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                _ = await self.sourceChanged(id: id, epoch: source.epoch, input: source.input,
                    unavailable: source.unavailable, owed: source.owed)
            }
        }
    }

    private func gate(_ id: String) -> LatestRead {
        if let gate = reads[id] { return gate }
        let gate = LatestRead(); reads[id] = gate; return gate
    }

    /// The native source epoch increases when the frozen packet changes. A
    /// missing source is explicit, never replaced by an empty packet. Callers
    /// receive their own result; only LatestRead decides which result publishes.
    /// A cancelled read leaves the last snapshot standing and is never cached.
    @discardableResult
    public func sourceChanged(id: String, epoch: UInt64, input: JSONValue,
        unavailable: String? = nil, owed: Bool = false) async -> PartFaceSnapshot {
        if Task.isCancelled || observer == nil {
            return .init(part: id, version: nil, sourceEpoch: epoch, status: .failed, face: nil,
                error: .init(code: "cancelled", message: "The projection owner was stopped."), owed: owed)
        }
        if let source = sources[id], epoch < source.epoch {
            return .init(part: id, version: nil, sourceEpoch: epoch, status: .failed, face: nil,
                error: .init(code: "stale_source", message: "A newer source epoch is already present."), owed: owed)
        }
        sources[id] = Source(epoch: epoch, input: input, unavailable: unavailable, owed: owed)
        func project() async -> PartFaceSnapshot {
            let version: String
            do {
                guard let file = try AbilityStore(dataRoot: dataRoot).read(id: id),
                      file.record["status"] == .string("active"),
                      file.part["face"]?.objectValue?["projection"] == .bool(true),
                      let selected = file.record["codeFingerprint"]?.stringValue else {
                    throw PartCallError(code: "unavailable", message: "The part has no selected projection face.")
                }
                version = selected
            } catch {
                return PartFaceSnapshot(part: id, version: nil, sourceEpoch: epoch, status: .unavailable, face: nil,
                    error: .init(code: "unavailable", message: error.localizedDescription), owed: owed)
            }
            if let unavailable {
                return .init(part: id, version: version, sourceEpoch: epoch, status: .unavailable, face: nil,
                    error: .init(code: "unavailable", message: unavailable), owed: owed)
            }
            if let cached = snapshots[id], cached.version == version, cached.sourceEpoch == epoch,
               cached.status == .ready {
                return .init(part: id, version: version, sourceEpoch: epoch, status: cached.status,
                    face: cached.face, error: cached.error, owed: owed)
            }
            switch await call(id, input, version) {
            case .success(let face):
                return .init(part: id, version: version, sourceEpoch: epoch, status: .ready, face: face, error: nil, owed: owed)
            case .failure(let error):
                return .init(part: id, version: version, sourceEpoch: epoch, status: .failed, face: nil, error: error, owed: owed)
            }
        }
        do {
            return try await gate(id).read({
                let snapshot = await project()
                try Task.checkCancellation()
                if let error = snapshot.error, error.code == "cancelled" { throw error }
                return snapshot
            }, publish: {
                guard observer != nil, !Task.isCancelled else { return }
                snapshots[id] = $0
            })
        } catch {
            // Throwing from the load also keeps cancellation from advancing
            // LatestRead's publication boundary ahead of another reader.
            return .init(part: id, version: nil, sourceEpoch: epoch, status: .failed, face: nil,
                error: (error as? PartCallError) ?? .init(code: "cancelled", message: "The projection owner was stopped."), owed: owed)
        }
    }

    public func remove(id: String) async {
        let task = refreshes.removeValue(forKey: id)
        task?.cancel()
        sources.removeValue(forKey: id)
        gate(id).write { snapshots.removeValue(forKey: id) }
        if let task { await settle { await task.value } }
    }

    /// Retire publication and cancel now, before a synchronous native quit
    /// wait. The owner awaits the returned settlement; close is its async form.
    public func stop() -> Task<Void, Never> {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        let tasks = Array(refreshes.values)
        for task in tasks { task.cancel() }
        refreshes.removeAll()
        for id in sources.keys { gate(id).write { snapshots.removeValue(forKey: id) } }
        sources.removeAll()
        return Task.detached {
            await settle { for task in tasks { await task.value } }
        }
    }

    public func close() async {
        await stop().value
    }
}
