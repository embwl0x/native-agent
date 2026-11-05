import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
// Blueprint: | `PartFaces.swift` | `PartFaces`, `PartFaceSnapshot`; source-owned face projections (the agent's JS parts and native pages) published through LatestRead, and the one port a row's action returns through |

/// Frozen source packets feed derived faces through the owner's current gates; views read snapshots and no second truth store is kept.
@MainActor @Observable
public final class PartFaces {
    public typealias Call = @Sendable (_ id: String, _ input: JSONValue, _ version: String) async -> PartCallResult<PartFace>
    /// A page owner's answer to what a row does: an action id, or "set" with a control's new value. It returns words for the door when it
    /// has any, and throws an owned no.
    public typealias Act = @Sendable (_ row: String, _ action: String, _ value: String?) async throws -> String?
    /// Who answers a row: the person at one of the person's doors ("mac", "phone"), or the agent, through its own door, in the turn it acts in. A page
    /// whose owner decides by who acts (trust, settings) answers with `ActBy` and keeps its existing authority checks. At the phone's door
    /// `device` is the paired device its router verified (signature and pairing), so an owner that needs signed provenance has it.
    public enum Actor: Sendable {
        case person(door: String, device: String? = nil)
        case agent(Turn)
    }
    public typealias ActBy = @Sendable (_ row: String, _ action: String, _ value: String?, _ by: Actor) async throws -> String?
    @ObservationIgnored private var acts: [String: ActBy] = [:]
    /// How a native page reads itself: its face and the record position it read (or the moment it read, for a page over no record).
    public typealias Read = @MainActor () async throws -> (face: PartFace, epoch: UInt64)
    @ObservationIgnored private var natives: [String: Read] = [:]
    public private(set) var snapshots: [String: PartFaceSnapshot] = [:]
    @ObservationIgnored private let dataRoot: URL
    @ObservationIgnored private let call: Call
    @ObservationIgnored private var reads: [String: LatestRead] = [:]
    /// What a page was last projected from: its part (a page may be keyed apart from the part that draws it) and that part's input.
    private struct Source { let part: String; let epoch: UInt64; let input: JSONValue; let unavailable: String?; let owed: Bool; var native = false }
    @ObservationIgnored private var sources: [String: Source] = [:]
    // Set once at init (before any use), then read and cleared only on the main actor.
    @ObservationIgnored nonisolated(unsafe) private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var refreshes: [String: Task<Void, Never>] = [:]

    public nonisolated init(dataRoot: URL, call: @escaping Call) {
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
        let changedPart: String?
        if url == root { changedPart = nil }
        else if url.deletingLastPathComponent() == root { changedPart = url.lastPathComponent }
        else { return }
        for (id, source) in sources where changedPart == nil || source.part == changedPart {
            // A native page reads no part; an ability change never re-projects it.
            guard !source.native else { continue }
            let previous = refreshes[id]
            previous?.cancel()
            gate(id).write { snapshots.removeValue(forKey: id) }
            refreshes[id] = Task { [weak self] in
                if let previous { await settle { await previous.value } }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                _ = await self.sourceChanged(id: source.part, page: id, epoch: source.epoch, input: source.input,
                    unavailable: source.unavailable, owed: source.owed)
            }
        }
    }

    private func gate(_ id: String) -> LatestRead {
        if let gate = reads[id] { return gate }
        let gate = LatestRead(); reads[id] = gate; return gate
    }

    /// Frozen packet changes advance the source epoch; missing packets stay explicit. Each read returns its result; LatestRead alone publishes.
    /// Cancelled reads preserve the last snapshot and never enter the version/epoch cache. `id` is the part that draws it; `page` the key it
    /// is published under (the part's id when omitted).
    @discardableResult
    public func sourceChanged(id part: String, page: String? = nil, epoch: UInt64, input: JSONValue,
        unavailable: String? = nil, owed: Bool = false) async -> PartFaceSnapshot {
        let id = page ?? part
        if Task.isCancelled || observer == nil {
            return .init(part: part, version: nil, sourceEpoch: epoch, status: .failed, face: nil,
                error: .init(code: "cancelled", message: "The projection owner was stopped."), owed: owed)
        }
        if let source = sources[id], epoch < source.epoch {
            return .init(part: part, version: nil, sourceEpoch: epoch, status: .failed, face: nil,
                error: .init(code: "stale_source", message: "A newer source epoch is already present."), owed: owed)
        }
        sources[id] = Source(part: part, epoch: epoch, input: input, unavailable: unavailable, owed: owed)
        func project() async -> PartFaceSnapshot {
            let version: String
            do {
                guard let file = try AbilityStore(dataRoot: dataRoot).read(id: part),
                      file.record["status"] == .string("active"),
                      file.part["face"]?.objectValue?["projection"] == .bool(true),
                      let selected = file.record["codeFingerprint"]?.stringValue else {
                    throw PartCallError(code: "unavailable", message: "The part has no selected projection face.")
                }
                version = selected
            } catch {
                return PartFaceSnapshot(part: part, version: nil, sourceEpoch: epoch, status: .unavailable, face: nil,
                    error: .init(code: "unavailable", message: error.localizedDescription), owed: owed)
            }
            if let unavailable {
                return .init(part: part, version: version, sourceEpoch: epoch, status: .unavailable, face: nil,
                    error: .init(code: "unavailable", message: unavailable), owed: owed)
            }
            if let cached = snapshots[id], cached.version == version, cached.sourceEpoch == epoch,
               cached.status == .ready {
                return .init(part: part, version: version, sourceEpoch: epoch, status: cached.status,
                    face: cached.face, error: cached.error, owed: owed)
            }
            switch await call(part, input, version) {
            case .success(let face):
                return .init(part: part, version: version, sourceEpoch: epoch, status: .ready, face: face, error: nil, owed: owed)
            case .failure(let error):
                return .init(part: part, version: version, sourceEpoch: epoch, status: .failed, face: nil, error: error, owed: owed)
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
                // An unchanged face keeps its snapshot, so every door (the phone's included) sees unchanged bytes and nothing moves.
                guard snapshots[id]?.face != $0.face || snapshots[id]?.status != $0.status || snapshots[id]?.owed != $0.owed else { return }
                snapshots[id] = $0
                NotificationCenter.default.post(name: .pageFacePublished, object: id)
            })
        } catch {
            // Throwing from the load also keeps cancellation from advancing LatestRead's publication boundary ahead of another reader.
            return .init(part: part, version: nil, sourceEpoch: epoch, status: .failed, face: nil,
                error: (error as? PartCallError) ?? .init(code: "cancelled", message: "The projection owner was stopped."), owed: owed)
        }
    }

    /// A native page publishes the face it read at record position `epoch` through the same gate as a part's projection: an older read
    /// never replaces a newer one, and a failed read keeps its error beside the last face rather than inventing one.
    @discardableResult
    public func publish(page id: String, epoch: UInt64, owed: Bool = false,
                        read: @escaping @MainActor () async throws -> PartFace) async -> PartFaceSnapshot {
        await project(page: id, at: epoch, owed: owed) { (try await read(), epoch) }
    }

    /// A native page registers once how it reads itself and what its rows do; every door then refreshes it through `refresh(page:)`.
    public func register(page id: String, read: @escaping Read, act: Act? = nil) {
        var actBy: ActBy?
        if let act { actBy = { row, action, value, _ in try await act(row, action, value) } }
        register(page: id, read: read, actBy: actBy)
    }

    public func register(page id: String, read: @escaping Read, actBy: ActBy?) {
        natives[id] = read
        if let actBy { acts[id] = actBy }
    }

    /// Read a registered page again and publish it (a page drawn by the agent's part refreshes through its own source and returns its snapshot).
    @discardableResult
    public func refresh(page id: String) async -> PartFaceSnapshot? {
        guard let read = natives[id] else { return snapshots[id] }
        return await project(page: id, at: sources[id]?.epoch ?? 0, owed: sources[id]?.owed ?? false, read: read)
    }

    private func project(page id: String, at floor: UInt64, owed: Bool, read: @escaping Read) async -> PartFaceSnapshot {
        do {
            return try await gate(id).read({
                let snapshot: PartFaceSnapshot
                do {
                    let (face, epoch) = try await read()
                    if let source = sources[id], epoch < source.epoch {
                        throw PartCallError(code: "stale_source", message: "A newer source epoch is already present.")
                    }
                    sources[id] = Source(part: id, epoch: epoch, input: .null, unavailable: nil, owed: owed, native: true)
                    snapshot = .init(part: id, version: "native", sourceEpoch: epoch, status: .ready, face: face, error: nil, owed: owed)
                } catch let error as CancellationError {
                    throw error
                } catch let error as PartCallError where error.code == "stale_source" {
                    throw error
                } catch {
                    snapshot = .init(part: id, version: "native", sourceEpoch: floor, status: .failed, face: nil,
                        error: (error as? PartCallError) ?? .init(code: "read_failed", message: error.localizedDescription), owed: owed)
                }
                try Task.checkCancellation()
                return snapshot
            }, publish: {
                guard observer != nil, !Task.isCancelled else { return }
                // An unchanged face keeps its snapshot, so every door (the phone's included) sees unchanged bytes and nothing moves.
                guard snapshots[id]?.face != $0.face || snapshots[id]?.status != $0.status || snapshots[id]?.owed != $0.owed else { return }
                snapshots[id] = $0
                NotificationCenter.default.post(name: .pageFacePublished, object: id)
            })
        } catch let error as PartCallError {
            return .init(part: id, version: nil, sourceEpoch: floor, status: .failed, face: nil, error: error, owed: owed)
        } catch {
            return .init(part: id, version: nil, sourceEpoch: floor, status: .failed, face: nil,
                error: .init(code: "cancelled", message: "The projection owner was stopped."), owed: owed)
        }
    }

    /// The page's owner answers what its rows do; one owner per page.
    public func answer(page id: String, with act: @escaping Act) { acts[id] = { row, action, value, _ in try await act(row, action, value) } }

    /// What a row does goes back to its page's owner, from every door alike. A page with no owner answer refuses with its reason.
    public func act(page id: String, row: String, action: String, value: String? = nil, by: Actor) async throws -> String? {
        guard let act = acts[id] else {
            throw PartCallError(code: "no_action", message: "The \(id) page has nothing a row can do.")
        }
        guard snapshots[id]?.face?.sections.contains(where: { $0.rows.contains { $0.id == row } }) == true else {
            throw PartCallError(code: "stale_row", message: "That row is no longer on the \(id) page; nothing changed.")
        }
        let words = try await act(row, action, value, by)
        await refresh(page: id)
        return words
    }

    public func remove(id: String) async {
        let task = refreshes.removeValue(forKey: id)
        task?.cancel()
        sources.removeValue(forKey: id)
        gate(id).write { snapshots.removeValue(forKey: id) }
        if let task { await settle { await task.value } }
    }

    /// Retire publication and cancel synchronously before native quit waits; the owner must await the returned settlement drain.
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
