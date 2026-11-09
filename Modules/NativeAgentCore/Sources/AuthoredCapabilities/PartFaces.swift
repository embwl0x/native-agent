import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `PartFaces.swift` | Actor-owned page admission and demands; LatestRead snapshots, drawn-call checks and settlement |

/// Frozen source packets feed derived faces through the owner's current gates; views read the face feed. A row
/// does what its call says, through the door, for the person and the agent alike; no page answers its own rows.
public actor PartFaces {
    private var registrationFinished = false
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
    public typealias Call = @Sendable (_ id: String, _ input: JSONValue, _ version: String) async -> PartCallResult<PartFace>
    /// How a row's call runs when the person taps it: through the person's door, as `tap` names it, the person's own decision (`decided`)
    /// when the stem composed the call. Its reply retains the owner's words, effects and field settlement.
    public typealias Run = @Sendable (_ call: PartFace.Call, _ tap: Tap) async throws -> FaceActOutcome
    /// A tap on a row: the page and row, the action's id, the person's door (`mac`, `phone`, `telegram`), and who that door verified: the
    /// paired phone, or Telegram's sender (`device`) in its chat (`chat`). `decided` is true when the stem composed the row that ran (a
    /// lever, a key lever, any row of a page that is not the agent's own), so the tap is the person's decision of that call; a row the agent
    /// drew on its own page is the agent's call, and the tap only asks for it.
    public struct Tap: Sendable, Equatable {
        public let page: String
        public let row: String
        public let action: String
        public let door: String
        public let device: String?
        public let chat: String?
        public let decided: Bool
        public let renderer: UUID?
        /// A tap the stem composes outside a page's rows (the phone's own composer) names the page and row it stands for.
        public init(page: String, row: String, action: String, door: String, device: String?, chat: String?, decided: Bool, renderer: UUID? = nil) {
            self.page = page; self.row = row; self.action = action; self.door = door; self.device = device; self.chat = chat
            self.decided = decided
            self.renderer = renderer
        }
    }
    private var run: Run?
    private struct UndoKey: Hashable {
        let page: String; let row: String; let door: String; let device: String?; let renderer: UUID?
    }
    private struct Inverse {
        let operation: UUID
        let call: PartFace.Call
        let tap: Tap
        let part: String
        let version: String?
    }
    private var inverses: [UndoKey: Inverse] = [:]

    public func releaseRenderer(_ renderer: UUID) { inverses = inverses.filter { $0.key.renderer != renderer } }
    /// How the stem's own page (a lever page: Settings, Trust, Providers, Connectors, Inbox, Capabilities, Helpers) reads itself: its face and the
    /// record position it read (or the moment it read, for a page over no record).
    public typealias Read = @Sendable () async throws -> (face: PartFace, epoch: UInt64)
    private var natives: [String: Read] = [:]
    /// What the owner of a page the agent draws reads: the facts the page's part is given (its `keys` bind the face's rows), the record position
    /// they were read at, the person's levers the owner composes (the page's `levers`, and `keyLevers`: rows keyed like the face's, whose
    /// actions ride every face row with that id), and whether something is owed. Neither kind of lever is among the facts.
    public struct Packet: Sendable {
        public let facts: JSONValue
        public let epoch: UInt64
        public let levers: [PartFace.Section]
        public let keyLevers: [PartFace.Section]
        public let owed: Bool
        public init(facts: JSONValue, epoch: UInt64, levers: [PartFace.Section] = [], keyLevers: [PartFace.Section] = [], owed: Bool = false) {
            self.facts = facts; self.epoch = epoch; self.levers = levers; self.keyLevers = keyLevers; self.owed = owed
        }
    }
    public typealias PacketRead = @Sendable () async throws -> Packet
    private var packets: [String: (part: String, read: PacketRead)] = [:]
    /// Each authored page has one part or its own declaration failure.
    private var own: [String: PartFaceCatalog.Claim] { catalog?.claims ?? [:] }
    /// The pages the stem registered (its lever pages and the pages its owners' packets key): their rows' calls are the stem's. A page of the
    /// agent's own is never one, whenever its claim changes.
    private var stemPages: Set<String> = []
    private let ownPagesRead = LatestRead()
    private var ownEpochs: [String: UInt64] = [:]
    /// Only the engine's pages hold the agent's own pages; other projection owners never read them.
    private var holdsOwnPages = false
    public private(set) var snapshots: [String: PartFaceSnapshot] = [:]
    private let dataRoot: URL
    private let call: Call
    private var reads: [String: LatestRead] = [:]
    /// The input each page's ready face was drawn from: a face is a pure reading of its input, so the same selected version over the same
    /// input reuses it whatever epoch carried it, and different input always draws again.
    private var drawnFrom: [String: JSONValue] = [:]
    /// What a page was last projected from: its part (a page may be keyed apart from the part that draws it), that part's input, the levers beside
    /// it and whether its rows are bound to the input's keys.
    private struct Source: Sendable {
        let part: String; let epoch: UInt64; let input: JSONValue; let unavailable: String?; let owed: Bool
        var levers: [PartFace.Section]? = nil; var keyLevers: [PartFace.Section]? = nil; var bound = false; var native = false

        nonisolated func snapshot(_ version: String?, _ status: PartFaceSnapshot.Status, _ face: PartFace?,
                                  _ error: PartCallError?) -> PartFaceSnapshot {
            .init(part: part, version: version, sourceEpoch: epoch, status: status, face: face, error: error, owed: owed, levers: levers,
                  keyLevers: keyLevers)
        }
    }
    private var sources: [String: Source] = [:]
    private var observers: [any NSObjectProtocol] = []
    private var keyringObservation: Task<Void, Never>?
    private var stopped = false
    private var refreshes: [String: Task<Void, Never>] = [:]

    private enum Publication: Sendable {
        case snapshot(String, PartFaceSnapshot)
        case catalog(PartFaceCatalog)
        case flush(CheckedContinuation<Bool, Never>)
    }
    private let publication: AsyncStream<Publication>.Continuation
    private let publishing: Task<Void, Never>

    public init(dataRoot: URL, feed: FaceFeedSource? = nil,
                            key: @escaping @Sendable (String) -> FaceKey = { .page($0) }, call: @escaping Call) {
        self.dataRoot = dataRoot; self.call = call
        let (values, publication) = AsyncStream.makeStream(of: Publication.self)
        self.publication = publication
        publishing = Task.detached {
            for await value in values {
                switch value {
                case .snapshot(let id, let snapshot):
                    if let feed { await feed.post(snapshot, at: key(id)) }
                    NotificationCenter.default.post(name: .pageFacePublished, object: id)
                case .catalog(let catalog):
                    if let feed { await feed.post(catalog, at: PageFaceKey.catalog) }
                    NotificationCenter.default.post(name: .pageCatalogPublished, object: nil)
                case .flush(let continuation): continuation.resume(returning: true)
                }
            }
        }
    }

    /// Register before the first source read; no actor-isolated resources are installed by the nonisolated initializer.
    private func observe() {
        guard !stopped, observers.isEmpty else { return }
        let changes = StoreChangeBus.shared.changes()
        keyringObservation = Task { [weak self] in
            for await change in changes where change.store == .keyring {
                guard !Task.isCancelled else { return }
                await self?.keyringChanged()
            }
        }
        observers = [NotificationCenter.default.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { [weak self] event in
            guard let path = event.object as? String else { return }
            Task { [weak self] in
                await self?.changed(path)
            }
        }, NotificationCenter.default.addObserver(forName: AbilityStore.notebookDidChange, object: nil, queue: nil) { [weak self] event in
            guard let part = event.object as? String else { return }
            Task { [weak self] in await self?.notebookChanged(part) }
        }]
    }

    private func keyringChanged() async {
        guard !stopped else { return }
        let pages = snapshots.filter { _, snapshot in
            snapshot.drawnFace?.sections.contains { $0.block?.receiver?.hasPrefix("keyring:") == true } == true
        }.map(\.key)
        for page in pages { await reproject(page: page) }
    }

    private func notebookChanged(_ part: String) async {
        guard !stopped else { return }
        for (page, claim) in own where claim == .success(part) { await refresh(page: page) }
    }

    isolated deinit {
        publication.finish()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        keyringObservation?.cancel()
        for task in refreshes.values { task.cancel() }
    }

    private func changed(_ path: String) async {
        guard !stopped else { return }
        let root = AbilityStore(dataRoot: dataRoot).root
        let url = URL(fileURLWithPath: path)
        let changedPart: String?
        if url.path == root.path { changedPart = nil }
        else if url.deletingLastPathComponent().path == root.path { changedPart = url.lastPathComponent }
        else { return }
        if holdsOwnPages { await ownPages() }
        for (id, source) in sources where changedPart == nil || source.part == changedPart {
            // The stem's own page reads no part; an ability change never re-projects it.
            guard !source.native else { continue }
            let previous = refreshes[id]
            previous?.cancel()
            gate(id).write { drawnFrom.removeValue(forKey: id) }
            refreshes[id] = Task { [weak self] in
                if let previous { await settle { await previous.value } }
                guard !Task.isCancelled else { return }
                await self?.reproject(page: id)
            }
        }
    }

    /// A part's change re-reads a page drawn from a packet, or re-projects one drawn from its retained source.
    private func reproject(page id: String) async {
        if packets[id] != nil { await refresh(page: id) }
        else if let current = sources[id] {
            _ = await sourceChanged(id: current.part, page: id, epoch: current.epoch, input: current.input,
                unavailable: current.unavailable, owed: current.owed, levers: current.levers, keyLevers: current.keyLevers,
                bound: current.bound)
        }
    }

    private func gate(_ id: String) -> LatestRead {
        if let gate = reads[id] { return gate }
        let gate = LatestRead(); reads[id] = gate; return gate
    }

    /// Frozen packet changes advance the source epoch; missing packets stay explicit. Each read returns its result; LatestRead alone publishes.
    /// Cancelled reads preserve the last snapshot and never enter the version/epoch cache. `id` is the part that draws it; `page` the key it
    /// is published under (the part's id when omitted). A `bound` face keeps only rows its input's keys allow, and the person's levers
    /// (`levers`, `keyLevers`) stand beside it whatever it draws or fails to draw.
    @discardableResult
    public func sourceChanged(id part: String, page: String? = nil, epoch: UInt64, input: JSONValue, unavailable: String? = nil,
        owed: Bool = false, levers: [PartFace.Section]? = nil, keyLevers: [PartFace.Section]? = nil, bound: Bool = false) async -> PartFaceSnapshot {
        observe()
        let id = page ?? part
        let source = Source(part: part, epoch: epoch, input: input, unavailable: unavailable, owed: owed, levers: levers, keyLevers: keyLevers,
                            bound: bound)
        do {
            return try await gate(id).read({ try await projectSource(source, page: id) }, publish: {
                self.publish($0, page: id, source: source)
            })
        } catch {
            return source.snapshot(nil, .failed, nil,
                                   (error as? PartCallError) ?? .init(code: "cancelled", message: "The projection owner was stopped."))
        }
    }

    /// The caller's admission spans the source read and this projection; only its accepted publication may replace the retained source.
    private func projectSource(_ source: Source, page id: String) async throws -> PartFaceSnapshot {
        if Task.isCancelled || stopped { throw PartCallError(code: "cancelled", message: "The projection owner was stopped.") }
        let root = dataRoot, run = call, cached = snapshots[id], previousInput = drawnFrom[id]
        let snapshot = await Task.detached(priority: .userInitiated) {
            let version: String
            do {
                guard let file = try AbilityStore(dataRoot: root).read(id: source.part),
                      file.record["status"] == .string("active"),
                      file.part["face"]?.objectValue?["projection"] == .bool(true),
                      let selected = file.record["codeFingerprint"]?.stringValue else {
                    throw PartCallError(code: "unavailable", message: "The part has no selected projection face.")
                }
                version = selected
            } catch {
                return source.snapshot(nil, .unavailable, nil, .init(code: "unavailable", message: error.localizedDescription))
            }
            if let unavailable = source.unavailable {
                return source.snapshot(version, .unavailable, nil, .init(code: "unavailable", message: unavailable))
            }
            if let cached, cached.version == version, cached.status == .ready, previousInput == source.input {
                do { return source.snapshot(version, .ready, try cached.face?.readingSecretStatus(page: id), cached.error) }
                catch {
                    return source.snapshot(version, .failed, nil, .init(code: "keyring_unavailable", message: error.localizedDescription))
                }
            }
            switch await run(source.part, source.input, version) {
            case .success(let face):
                do {
                    let drawn = source.bound ? try face.bound(to: PartFace.Keys(packet: source.input), levers: source.levers ?? [],
                                                              keyLevers: source.keyLevers ?? []) : face
                    return source.snapshot(version, .ready, try drawn.readingSecretStatus(page: id), nil)
                } catch {
                    return source.snapshot(version, .failed, nil,
                                           (error as? PartCallError) ?? .init(code: "bad_face", message: error.localizedDescription))
                }
            case .failure(let error):
                return source.snapshot(version, .failed, nil, error)
            }
        }.value
        try Task.checkCancellation()
        if let error = snapshot.error, error.code == "cancelled" { throw error }
        if let current = sources[id], source.epoch < current.epoch {
            throw PartCallError(code: "stale_source", message: "A newer source epoch is already present.")
        }
        return snapshot
    }

    /// An unchanged page keeps its snapshot, so every door (the phone's included) sees unchanged bytes and nothing moves. A part's ready face
    /// records the input it was drawn from.
    private func publish(_ snapshot: PartFaceSnapshot, page id: String, source: Source? = nil) {
        guard !stopped, !Task.isCancelled else { return }
        if let source { sources[id] = source }
        if snapshot.status == .ready, let source, !source.native { drawnFrom[id] = source.input } else { drawnFrom.removeValue(forKey: id) }
        let last = snapshots[id]
        guard last?.part != snapshot.part || last?.version != snapshot.version || last?.face != snapshot.face || last?.status != snapshot.status
            || last?.owed != snapshot.owed || last?.levers != snapshot.levers
            || last?.keyLevers != snapshot.keyLevers || last?.error != snapshot.error else { return }
        snapshots[id] = snapshot
        publication.yield(.snapshot(id, snapshot))
    }

    /// The stem's own page publishes the face it read at record position `epoch` through the same gate as a part's projection: an older read
    /// never replaces a newer one, and a failed read keeps its error beside the last face rather than inventing one.
    @discardableResult
    public func publish(page id: String, epoch: UInt64, owed: Bool = false,
                        read: @escaping @Sendable () async throws -> PartFace) async -> PartFaceSnapshot {
        await readNative(page: id, at: epoch, owed: owed) { (try await read(), epoch) }
    }

    /// A lever page (the stem's) registers once how it reads itself; every door then refreshes it through `refresh(page:)`.
    public func register(page id: String, read: @escaping Read) {
        natives[id] = read
        stemPages.insert(id)
    }

    /// A page the agent draws registers once the part that draws it and how its owner reads the packet (facts, epoch, the person's levers);
    /// every door then refreshes it through `refresh(page:)`.
    public func register(page id: String, part: String, read: @escaping PacketRead) {
        packets[id] = (part, read)
        stemPages.insert(id)
    }

    /// A source owner pushes its finished packets; opening this page only reads the last posted snapshot.
    public func register(page id: String) {
        stemPages.insert(id)
    }

    /// The owner's whole page list has been registered; every caller waiting on it goes on.
    public func finishRegistration() {
        registrationFinished = true
        for waiter in registrationWaiters { waiter.resume() }
        registrationWaiters = []
    }

    /// Returns once the owner has registered its pages, so a window opening beside a starting body is not told a page is unknown.
    public func registration() async {
        guard !registrationFinished else { return }
        await withCheckedContinuation { registrationWaiters.append($0) }
    }

    /// Read a registered page again and publish it (a page another owner pushes through `sourceChanged` returns its last snapshot).
    @discardableResult
    public func refresh(page id: String) async -> PartFaceSnapshot? {
        if let demand = itemDemands[id] {
            let owner = currentSnapshot(demand.page) ?? demand.snapshot
            do {
                let face = try await presentation(page: demand.page, item: demand.item, request: demand.request)
                return .init(part: owner.part, version: owner.version, sourceEpoch: owner.sourceEpoch,
                             status: .ready, face: face, error: nil, owed: owner.owed)
            } catch {
                return .init(part: owner.part, version: owner.version, sourceEpoch: owner.sourceEpoch,
                    status: .failed, face: nil, error: (error as? PartCallError) ?? .init(code: "read_failed", message: error.localizedDescription),
                    owed: owner.owed)
            }
        }
        observe()
        let failure: PartCallError?
        if let inventoryFailure = ownPageFailure, own[id] != nil || !stemPages.contains(id) { failure = inventoryFailure }
        else if case .failure(let claimFailure)? = own[id] { failure = claimFailure }
        else { failure = nil }
        if let failure {
            let snapshot = PartFaceSnapshot(part: id, version: nil, sourceEpoch: ownEpochs[id] ?? 0,
                status: .failed, face: nil, error: failure, owed: true)
            gate(id).write { publish(snapshot, page: id) }
            return snapshot
        }
        if let read = natives[id] {
            return await readNative(page: id, at: sources[id]?.epoch ?? 0, owed: sources[id]?.owed ?? false, read: read)
        }
        guard let reader = packets[id] else { return snapshots[id] }
        let floor = sources[id]?.epoch ?? 0, owed = sources[id]?.owed ?? false
        do {
            let result = try await gate(id).read({ () async throws -> (PartFaceSnapshot, Source?) in
                let packet: Packet
                do { packet = try await Self.readOffMain(reader.read) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    // A packet that could not be read publishes its cause in its original admission, never an empty page.
                    let failed = PartFaceSnapshot(part: reader.part, version: nil, sourceEpoch: floor, status: .failed, face: nil,
                        error: (error as? PartCallError) ?? .init(code: "read_failed", message: error.localizedDescription), owed: owed)
                    return (failed, nil)
                }
                let source = Source(part: reader.part, epoch: packet.epoch, input: packet.facts, unavailable: nil, owed: packet.owed,
                    levers: packet.levers.isEmpty ? nil : packet.levers, keyLevers: packet.keyLevers.isEmpty ? nil : packet.keyLevers, bound: true)
                return (try await projectSource(source, page: id), source)
            }, publish: { snapshot, source in
                self.publish(snapshot, page: id, source: source)
            })
            return result.0
        } catch is CancellationError {
            return .init(part: reader.part, version: nil, sourceEpoch: floor, status: .failed, face: nil,
                         error: .init(code: "cancelled", message: "The page read was cancelled."), owed: owed)
        }
        catch {
            return .init(part: reader.part, version: nil, sourceEpoch: floor, status: .failed, face: nil,
                         error: (error as? PartCallError) ?? .init(code: "read_failed", message: error.localizedDescription), owed: owed)
        }
    }

    /// Active parts claim unique pages drawn from their notebooks. Inventory and declaration failures remain visible.
    public private(set) var catalog: PartFaceCatalog?
    private var ownPageFailure: PartCallError? { catalog?.failure }

    @discardableResult public func ownPages() async -> Result<Void, PartCallError> {
        observe()
        holdsOwnPages = true
        let root = dataRoot
        let result: Result<[String: PartFaceCatalog.Claim], PartCallError> = await ownPagesRead.read({
            do {
                let parts = try await Task.detached(priority: .utility) { try AbilityStore(dataRoot: root).pageParts() }.value
                try Task.checkCancellation()
                return .success(self.pageClaims(parts))
            } catch {
                return .failure((error as? PartCallError) ?? .init(
                    code: error is CancellationError ? "cancelled" : "page_inventory_failed", message: error.localizedDescription))
            }
        }, publish: { result in
            switch result {
            case .success(let claims):
                self.publishOwnPages(claims)
            case .failure(let failure):
                self.publishCatalog(.init(claims: self.own, failure: failure))
                for page in self.own.keys {
                    self.gate(page).write {
                        self.publish(.init(part: page, version: nil, sourceEpoch: self.ownEpochs[page] ?? 0,
                            status: .failed, face: nil, error: failure, owed: true), page: page)
                    }
                }
            }
        })
        return result.map { _ in () }
    }

    private func pageClaims(_ parts: [(part: String, page: String)]) -> [String: PartFaceCatalog.Claim] {
        var claimed: [String: PartFaceCatalog.Claim] = [:]
        for (page, group) in Dictionary(grouping: parts, by: \.page) {
            let names = group.map(\.part).sorted().joined(separator: ", ")
            if stemPages.contains(page) {
                claimed[page] = .failure(.init(code: "page_claim_conflict", message: "\(names) claims the stem's page \(page)."))
            } else if group.count > 1 {
                claimed[page] = .failure(.init(code: "page_claim_conflict", message: "\(names) all claim page \(page)."))
            } else if let claim = group.first { claimed[page] = .success(claim.part) }
        }
        return claimed
    }

    private func publishCatalog(_ value: PartFaceCatalog) {
        guard !stopped, !Task.isCancelled, catalog != value else { return }
        catalog = value
        publication.yield(.catalog(value))
    }

    private func publishOwnPages(_ claimed: [String: PartFaceCatalog.Claim]) {
        guard !stopped, !Task.isCancelled else { return }
        let recovering = catalog?.failure != nil
        let changed = Set(own.keys).union(claimed.keys).filter { own[$0] != claimed[$0] || recovering }
        publishCatalog(.init(claims: claimed))
        for page in changed {
            inverses = inverses.filter { $0.key.page != page }
            refreshes.removeValue(forKey: page)?.cancel()
            gate(page).write {
                drawnFrom.removeValue(forKey: page)
                sources.removeValue(forKey: page)
                snapshots.removeValue(forKey: page)
            }
            if !stemPages.contains(page) { packets.removeValue(forKey: page); ownEpochs.removeValue(forKey: page) }
            if case .success(let part)? = claimed[page] {
                let root = dataRoot
                packets[page] = (part, { [weak self] in
                    guard let self else { throw PartCallError(code: "cancelled", message: "The projection owner was stopped.") }
                    let epoch = try await self.nextOwnEpoch(page)
                    return try await Self.notebookPacket(dataRoot: root, part: part, page: page, epoch: epoch)
                })
            }
            if claimed[page] == nil, !stemPages.contains(page) { publishRemoval(page) }
            Task { [weak self] in await self?.refresh(page: page) }
        }
    }

    /// Why `page` cannot be a page of the agent's own (AppDoorNames owns the rule), or nil when it can.
    public nonisolated static func ownPageRefusal(_ page: String) -> String? { AppDoorNames.ownPageRefusal(page) }

    private func nextOwnEpoch(_ page: String) throws -> UInt64 {
        let (epoch, overflow) = (ownEpochs[page] ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw PartCallError(code: "page_epoch_exhausted", message: "Page \(page) exhausted its source epochs.") }
        ownEpochs[page] = epoch
        return epoch
    }

    @concurrent nonisolated private static func notebookPacket(dataRoot: URL, part: String, page: String, epoch: UInt64) async throws -> Packet {
        let facts = try AbilityStore.notebook(dataRoot: dataRoot, id: part, setting: false, value: .null) { code, message in
            PartCallError(code: code, message: message)
        }
        switch facts {
        case .object: return Packet(facts: facts, epoch: epoch)
        case .null: return Packet(facts: .object([:]), epoch: epoch)
        default: throw PartCallError(code: "bad_notebook", message: "Page \(page) draws from \(part)'s notebook, which holds no object.")
        }
    }

    /// Every registered reader (native, packet and notebook) enters on the concurrent executor; readers copy observable values in short main hops.
    /// Cancellation remains in the caller's task.
    @concurrent nonisolated private static func readOffMain<Value: Sendable>(_ read: @Sendable () async throws -> Value) async throws -> Value {
        try await read()
    }

    @concurrent nonisolated private static func project(page id: String, at floor: UInt64, owed: Bool, read: Read) async throws -> PartFaceSnapshot {
        do {
            let (face, epoch) = try await readOffMain(read)
            return .init(part: id, version: "native", sourceEpoch: epoch, status: .ready, face: face, error: nil, owed: owed)
        } catch is CancellationError { throw CancellationError() }
        catch let error as PartCallError where error.code == "stale_source" { throw error }
        catch {
            return .init(part: id, version: "native", sourceEpoch: floor, status: .failed, face: nil,
                error: (error as? PartCallError) ?? .init(code: "read_failed", message: error.localizedDescription), owed: owed)
        }
    }

    private func readNative(page id: String, at floor: UInt64, owed: Bool, read: @escaping Read) async -> PartFaceSnapshot {
        observe()
        do {
            return try await gate(id).read({
                let snapshot = try await Self.project(page: id, at: floor, owed: owed, read: read)
                if snapshot.status == .ready {
                    let epoch = snapshot.sourceEpoch
                    if let source = sources[id], epoch < source.epoch {
                        throw PartCallError(code: "stale_source", message: "A newer source epoch is already present.")
                    }
                }
                try Task.checkCancellation()
                return snapshot
            }, publish: {
                let source: Source? = $0.status == .ready
                    ? Source(part: id, epoch: $0.sourceEpoch, input: .null, unavailable: nil, owed: owed, native: true) : nil
                self.publish($0, page: id, source: source)
            })
        } catch let error as PartCallError {
            return .init(part: id, version: nil, sourceEpoch: floor, status: .failed, face: nil, error: error, owed: owed)
        } catch {
            return .init(part: id, version: nil, sourceEpoch: floor, status: .failed, face: nil,
                error: .init(code: "cancelled", message: "The projection owner was stopped."), owed: owed)
        }
    }

    /// How every tap runs its row's call; set once by the door's owner.
    public func runs(_ run: @escaping Run) { self.run = run }

    public typealias DemandRead = @Sendable (PartFace.Call) async throws -> JSONValue
    private var demandRead: DemandRead?
    private var documentProjection: Call?
    public func reads(_ read: @escaping DemandRead, project: @escaping Call) {
        demandRead = read; documentProjection = project
    }

    /// A document behind a row (a tool's schema, an ability's code, a guidance text) is never in the face: the row opens
    /// `page:<page>/<item>`, and every door reads the document on demand from the page's owner.
    public typealias Body = @MainActor @Sendable (_ item: String) async throws -> String
    private var bodies: [String: Body] = [:]
    private var bodyClaims: [String: @Sendable (String) async throws -> Bool] = [:]

    public func register(page id: String, contains: (@Sendable (String) async throws -> Bool)? = nil, body: @escaping Body) {
        bodies[id] = body
        bodyClaims[id] = contains
    }

    public typealias Item = @Sendable (_ item: String, _ request: FaceReadRequest) async throws -> PartFace
    private var items: [String: Item] = [:]
    private var itemClaims: [String: @Sendable (String) async throws -> Bool] = [:]
    private struct ItemDemand: Sendable {
        let page: String
        let item: String
        let request: FaceReadRequest
        let snapshot: PartFaceSnapshot
    }
    /// Request-scoped answers belong to held demands, outside the top-level pages exported to the phone.
    /// The scope includes the request id: a second door reading the same page/item cannot replace the first answer.
    private var itemDemands: [String: ItemDemand] = [:]

    public func register(page id: String, contains: (@Sendable (String) async throws -> Bool)? = nil, item: @escaping Item) {
        items[id] = item
        itemClaims[id] = contains
    }

    public func hasItem(page id: String, item: String) async throws -> Bool {
        let root = rootPage(id)
        if items[root] != nil {
            if let contains = itemClaims[root] { return try await contains(item) }
            return true
        }
        guard let source = currentSource(id) else {
            if let error = currentSnapshot(id)?.error { throw error }
            if packets[rootPage(id)] != nil {
                throw PartCallError(code: "page_unread", message: "Read the \(id) page before opening an item.")
            }
            return false
        }
        if source.native { return false }
        return try PartFace.Keys(packet: source.input).rows[item]?.read != nil
    }

    public func releaseItem(page id: String, item: String, request: UUID) {
        let namespace = id + "/" + item
        guard itemDemands[namespace]?.request.id == request else { return }
        gate(namespace).write { itemDemands.removeValue(forKey: namespace) }
        inverses = inverses.filter { $0.key.page != namespace }
    }

    public func heldPresentation(page id: String, request: FaceReadRequest) throws -> PartFace {
        guard let demand = itemDemands[id + "/" + request.scope], demand.request == request, let face = demand.snapshot.face else {
            throw PartCallError(code: "page_read_released", message: "This page demand is no longer held. Open it again to read it.")
        }
        return face
    }

    private func currentSnapshot(_ id: String) -> PartFaceSnapshot? { itemDemands[id]?.snapshot ?? snapshots[id] }
    private func rootPage(_ id: String) -> String {
        guard let parent = itemDemands[id]?.page else { return id }
        return rootPage(parent)
    }
    private func currentSource(_ id: String) -> Source? { sources[rootPage(id)] }

    /// The item or collection reader freezes its evidence before the selected pure projection runs.
    public func presentation(page id: String, item: String, request: FaceReadRequest, readUsing: DemandRead? = nil) async throws -> PartFace {
        guard !stopped else { throw CancellationError() }
        guard request.key == item else {
            throw PartCallError(code: "invalid_page_read", message: "The demand's key must name the item its owner is reading.")
        }
        let namespace = id + "/" + request.scope
        let source = currentSource(id)
        let snapshot = currentSnapshot(id)
        let root = rootPage(id)
        let native = items[root]
        let result = try await gate(namespace).read({ () async throws -> PartFace in
            if let native {
                if let contains = itemClaims[root], (try await contains(item)) == false {
                    throw PartCallError(code: "item_unavailable", message: "The page owner does not supply that item.")
                }
                if let expecting = request.expectedCall {
                    let drawn = snapshot?.drawnFace
                    let read = drawn?.allRows.first(where: { $0.id == item })?.read
                        ?? drawn?.sections.first(where: { $0.id == item })?.more?.read
                    guard read == expecting else {
                        throw PartCallError(code: "stale_read", message: "This native read changed. Open its current page before reading it.")
                    }
                }
                let face = try await Self.readOffMain { try await native(item, request) }
                try Task.checkCancellation()
                return face
            }
            guard let snapshot, let source, snapshot.status == .ready, let version = snapshot.version else {
                if let error = snapshot?.error { throw error }
                throw PartCallError(code: "page_unavailable", message: "Read the \(id) page before opening its items.")
            }
            guard let read = try PartFace.Keys(packet: source.input).rows[item]?.read else {
                throw PartCallError(code: "no_read", message: "The \(id) page declares no item or collection read for \(item).")
            }
            if let expecting = request.expectedCall, expecting != read {
                throw PartCallError(code: "stale_read", message: "This read changed. Open its current page before reading it.")
            }
            guard let reader = readUsing ?? demandRead, let projection = documentProjection else {
                throw PartCallError(code: "read_unavailable", message: "The page owner has no demand reader.")
            }
            var args = read.args
            if let cursor = request.cursor { args["cursor"] = .string(cursor) }
            if let anchor = request.anchor { args["anchor"] = .string(anchor) }
            if let query = request.query { args["query"] = .string(query) }
            if let revision = request.revision { args["revision"] = .string(revision) }
            let evidence = try await reader(.init(read.action, args))
            try Task.checkCancellation()
            guard case .object(var input) = source.input else {
                throw PartCallError(code: "bad_packet", message: "An item or collection's frozen packet is an object.")
            }
            input["read"] = evidence
            let projected = await projection(source.part, .object(input), version)
            try Task.checkCancellation()
            switch projected {
            case .failure(let error): throw error
            case .success(let face):
                guard currentSource(id)?.epoch == source.epoch, currentSnapshot(id)?.version == version else {
                    throw PartCallError(code: "stale_read", message: "The page changed while this item was being read. Open its current page.")
                }
                return try face.bound(to: PartFace.Keys(packet: source.input), levers: source.levers ?? [],
                    keyLevers: source.keyLevers ?? []).readingSecretStatus(page: namespace)
            }
        }, publish: { face in
            let held = PartFaceSnapshot(part: snapshot?.part ?? id, version: snapshot?.version, sourceEpoch: snapshot?.sourceEpoch ?? 0,
                                        status: .ready, face: face, error: nil, owed: snapshot?.owed ?? false)
            itemDemands[namespace] = ItemDemand(page: id, item: item, request: request, snapshot: held)
        })
        return result
    }

    public func hasBody(page id: String, item: String) async throws -> Bool {
        let root = rootPage(id)
        if bodies[root] != nil {
            if let contains = bodyClaims[root] { return try await contains(item) }
            return true
        }
        if currentSnapshot(id)?.drawnFace?.sections.compactMap(\.block).contains(where: { $0.key == item && $0.text != nil }) == true { return true }
        if let face = currentSnapshot(id)?.drawnFace,
           face.allRows.contains(where: { $0.id == item && $0.expands == true })
            || face.sections.contains(where: { $0.id == item && $0.more != nil })
            || (face.detail != nil && face.allRows.contains(where: { row in
                guard let open = row.open, case .page(let page, item: let selected?)? = FaceLink(open) else { return false }
                return page == id && selected == item
            })) { return false }
        guard let source = currentSource(id) else {
            if let error = currentSnapshot(id)?.error { throw error }
            if packets[root] != nil {
                throw PartCallError(code: "page_unread", message: "The \(id) page has not supplied its document declarations. Read the page first.")
            }
            return false
        }
        if source.native { return false }
        return try PartFace.Keys(packet: source.input).rows[item]?.read != nil
    }

    public func body(page id: String, item: String, expecting: PartFace.Call? = nil, readUsing: DemandRead? = nil) async throws -> String {
        if let body = bodies[rootPage(id)] { return try await body(item) }
        if let block = currentSnapshot(id)?.drawnFace?.sections.compactMap(\.block).first(where: { $0.key == item }), let text = block.text {
            return text
        }
        guard let snapshot = currentSnapshot(id) else {
            throw PartCallError(code: "page_unread", message: "The \(id) page has not returned its document declarations.")
        }
        if let error = snapshot.error { throw error }
        guard let source = currentSource(id), snapshot.status == .ready else {
            throw PartCallError(code: "page_unavailable", message: "The \(id) page's source is unavailable; its document was not read.")
        }
        guard let version = snapshot.version, let read = try PartFace.Keys(packet: source.input).rows[item]?.read else {
            throw PartCallError(code: "no_body", message: "The \(id) page declares no document read for \(item).")
        }
        if let expecting, expecting != read {
            throw PartCallError(code: "stale_read", message: "This document's read changed. Open its current page before reading it.")
        }
        guard let demandRead = readUsing ?? demandRead, let documentProjection else {
            throw PartCallError(code: "read_unavailable", message: "The page owner has no demand reader.")
        }
        let result = try await demandRead(read)
        try Task.checkCancellation()
        guard case .object(var input) = source.input else {
            throw PartCallError(code: "bad_packet", message: "A document's frozen packet must be an object.")
        }
        input["read"] = result
        let projected = await documentProjection(source.part, .object(input), version)
        try Task.checkCancellation()
        switch projected {
        case .failure(let error): throw error
        case .success(let face):
            let bound = try face.bound(to: PartFace.Keys(packet: source.input), levers: source.levers ?? [], keyLevers: source.keyLevers ?? [])
            guard let block = bound.sections.compactMap(\.block).first(where: { $0.key == item && $0.kind == "document" }),
                  let text = block.text else {
                throw PartCallError(code: "bad_face", message: "The document read completed, but face(input.read) supplied no text for \(item).")
            }
            return text
        }
    }

    /// Secret bytes go directly to the validated Keychain owner, outside an ordinary page call.
    public func saveKeyringForm(page id: String, row: String, action: String, revision: String?,
                                expecting: PartFace.Call, secret: String) async throws -> FaceActOutcome {
        let (name, field) = try await keyringField(page: id, row: row, action: action, revision: revision, expecting: expecting)
        guard !secret.isEmpty else { throw PartCallError(code: "secret_required", message: "Enter a secret.") }
        let existing = try Keyring.entry(name)
        if existing?.value != secret {
            var entry = existing ?? Keyring.Entry(value: secret, hosts: [], programs: [], renewal: nil, at: Date())
            entry.value = secret
            entry.renewal = nil
            entry.account = nil
            entry.at = Date()
            try Keyring.save(name, entry)
        }
        await reproject(page: id)
        return .init(words: "Secret saved in Keychain.", effects: .known, accepted: true, committed: [.init(id: field)])
    }

    public func readKeyringForm(_ request: PageActRequest, secret: String) async throws -> [FaceCommittedField]? {
        guard let call = request.expectedCall else { throw PartCallError(code: "drawn_call_missing", message: "Read the protected form again.") }
        let (name, field) = try await keyringField(page: request.page, row: request.row, action: request.action,
            revision: request.expectedRevision, expecting: call)
        guard try Keyring.entry(name)?.value == secret else { return nil }
        return [.init(id: field)]
    }

    private func keyringField(page id: String, row: String, action: String, revision: String?,
                              expecting: PartFace.Call) async throws -> (String, String) {
        guard let snapshot = await refresh(page: id) else {
            throw PartCallError(code: "page_unavailable", message: "Read this page before entering its secret.")
        }
        if let error = snapshot.error { throw error }
        guard let form = snapshot.drawnFace?.sections.compactMap(\.block).first(where: { $0.key == row }),
              form.kind == "form", form.protected == true, form.doors == ["mac"], form.revision == revision,
              let receiver = form.receiver, receiver.hasPrefix("keyring:"),
              let submit = form.submit?.first(where: { $0.id == action }), submit.unavailable == nil,
              submit.call == expecting, expecting.action == receiver, expecting.args.isEmpty else {
            throw PartCallError(code: "stale_secret_form", message: "This protected form changed. Keep the entry and read its current page.")
        }
        let name = String(receiver.dropFirst("keyring:".count))
        guard Keyring.validName(name), let fields = form.fields, fields.count == 1,
              let field = fields.first, field.kind == "secret", field.value == nil else {
            throw PartCallError(code: "invalid_secret_form", message: "A keyring form names one secret field and a valid keyring name.")
        }
        return (name, field.id)
    }

    /// The person taps a row's action (or changes its control, `action` "set" with the new `value`) at one of the person's doors. The call
    /// is read from the page as it stands now, never from the door: a row or action that is gone refuses, and so does an action that runs
    /// only from other doors. A caller holding the selected call can require it to match before anything runs. The call then runs through
    /// the person's door; the page reads again after it.
    public func act(page id: String, row: String, action: String, value: String? = nil, values: [String: PartFace.Value]? = nil,
                    formRevision: String? = nil, door: String, device: String? = nil,
                    chat: String? = nil, expecting: PartFace.Call? = nil, renderer: UUID? = nil) async throws -> String? {
        let outcome = try await actOutcome(page: id, row: row, action: action, value: value, values: values,
                                          formRevision: formRevision, door: door,
                                          device: device, chat: chat, expecting: expecting, renderer: renderer)
        if let failure = outcome.failure { throw failure }
        if outcome.effects == .unknown {
            throw WireFailure(code: "page_effects_unknown", message: outcome.words ?? "This action's effects are unknown. Read its current state.",
                              cause: nil, effects: .unknown)
        }
        return outcome.words
    }

    public func actOutcome(page id: String, row: String, action: String, value: String? = nil, values: [String: PartFace.Value]? = nil,
                           formRevision: String? = nil, door: String, device: String? = nil,
                           chat: String? = nil, expecting: PartFace.Call? = nil, renderer: UUID? = nil,
                           operation: UUID? = nil, undoOf: UUID? = nil) async throws -> FaceActOutcome {
        guard let run else { throw PartCallError(code: "no_action", message: "Nothing runs a row's call here.") }
        let undoKey = UndoKey(page: id, row: row, door: door, device: device, renderer: renderer)
        if let undoOf {
            guard action == "undo", value == nil, values == nil, let inverse = inverses[undoKey], inverse.operation == undoOf,
                  expecting == inverse.call, currentSnapshot(id)?.part == inverse.part, currentSnapshot(id)?.version == inverse.version else {
                throw PartCallError(code: "undo_unavailable", message: "This owner no longer offers that inverse. Read the page again.")
            }
            inverses.removeValue(forKey: undoKey)
            let tap = Tap(page: id, row: row, action: "undo", door: door, device: device, chat: chat,
                          decided: inverse.tap.decided, renderer: renderer)
            return await perform(inverse.call, tap: tap, operation: operation, undoKey: undoKey, run: run)
        }
        let snapshot: PartFaceSnapshot?
        if itemDemands[id] != nil { snapshot = await refresh(page: id) }
        else { snapshot = snapshots[id] }
        if let error = snapshot?.error { throw error }
        // Where each matching row came from decides who decides its call: the stem's own rows (the page's levers, the key levers, every row
        // of a page the stem registered) are the person's; a row of any other page (the agent's own) is the agent's, so the tap only asks.
        // The stem's rows are read first, so a key lever's action that rides a face row runs as the lever it is; a face never takes a
        // lever's row id or a key lever's action id (`PartFace.bound` refuses both when it draws).
        let stem = ((snapshot?.levers ?? []) + (snapshot?.keyLevers ?? [])).flatMap(\.allRows).filter { $0.id == row }
        let face = snapshot?.drawnFace?.allRows.filter { $0.id == row } ?? []
        let parent = rootPage(id)
        let native = stemPages.contains(parent) || items[parent] != nil
        if let values {
            guard value == nil else { throw PartCallError(code: "invalid_form_values", message: "Submit fields or a control value, never both.") }
            let stemForms = ((snapshot?.levers ?? []) + (snapshot?.keyLevers ?? [])).compactMap(\.block)
            let faceForms = snapshot?.drawnFace?.sections.compactMap(\.block) ?? []
            let forms = stemForms.map { ($0, true) } + faceForms.map { ($0, native) }
            guard let (form, decided) = forms.first(where: { $0.0.key == row && $0.0.kind == "form" }) else {
                throw PartCallError(code: "stale_form", message: "That form is no longer on the \(id) page. Read the page again.")
            }
            guard form.protected != true, form.fields?.contains(where: { $0.kind == "secret" }) != true else {
                throw PartCallError(code: "protected_entry_required", message: "Use this form's protected entry owner. No values were accepted.")
            }
            if let doors = form.doors, !doors.contains(door) {
                throw PartCallError(code: "other_door", message: "This form runs from \(doors.joined(separator: " or ")).")
            }
            guard form.revision == formRevision else {
                throw PartCallError(code: "form_conflict", message: "This form changed while it was being edited. Keep your draft and read its current values.")
            }
            guard let submit = form.submit?.first(where: { $0.id == action }), let call = submit.call else {
                throw PartCallError(code: "stale_form", message: "This form no longer offers that submit action. Read the page again.")
            }
            guard submit.runs(from: door) else {
                throw PartCallError(code: "other_door", message: "This submit action is unavailable from this door.")
            }
            if let reason = submit.unavailable { throw PartCallError(code: "action_unavailable", message: reason) }
            guard let expecting, expecting == call else {
                throw PartCallError(code: "stale_form", message: "This form's submit call changed after it was shown. Read the page again.")
            }
            let issues = form.formIssues(values: values)
            guard issues.isEmpty else {
                return FaceActOutcome(failure: WireFailure(code: "invalid_form_values", message: "Check the marked form fields.",
                    cause: nil, effects: .none, fields: issues), effects: .none)
            }
            let submitted = PartFace.Call(call.action, values.merging(call.args) { _, fixed in fixed })
            let tap = Tap(page: id, row: row, action: action, door: door, device: device, chat: chat, decided: decided, renderer: renderer)
            return await perform(submitted, tap: tap, operation: operation, undoKey: undoKey, run: run)
        }
        guard formRevision == nil else {
            throw PartCallError(code: "invalid_form_values", message: "A form revision accompanies its object values.")
        }
        let origins: [(rows: [PartFace.Row], decided: Bool)] = [(stem, true), (face, native)]
        guard origins.contains(where: { !$0.rows.isEmpty }) else {
            throw PartCallError(code: "stale_row", message: "That row is no longer on the \(id) page; nothing changed.")
        }
        let call: PartFace.Call
        let decided: Bool
        if action == "set" {
            guard let held = origins.lazy.compactMap({ origin in origin.rows.compactMap(\.control).first.map { ($0, origin.decided) } }).first else {
                throw PartCallError(code: "stale_row", message: "That row of the \(id) page holds no control now; nothing changed.")
            }
            guard let value, let made = held.0.settingCall(value) else {
                throw PartCallError(code: "no_control", message: "That row of the \(id) page takes no such value; nothing changed.")
            }
            (call, decided) = (made, held.1)
        } else {
            guard let held = origins.lazy.compactMap({ origin in
                origin.rows.flatMap { $0.actions ?? [] }.first(where: { $0.id == action }).map { ($0, origin.decided) }
            }).first else {
                throw PartCallError(code: "stale_row", message: "That row of the \(id) page no longer offers that; nothing changed.")
            }
            let named = held.0
            if let reason = named.unavailable { throw PartCallError(code: "action_unavailable", message: reason) }
            // An action that runs from some of the person's doors is refused at any other, whatever that door drew.
            if !named.runs(from: door), let doors = named.doorWords {
                throw PartCallError(code: "other_door", message: "\(named.label) runs from the \(doors); nothing changed.")
            }
            guard let made = named.call else {
                throw PartCallError(code: "opens", message: "\(named.label) opens a place; the door goes there and nothing runs.")
            }
            (call, decided) = (made, held.1)
        }
        if let expecting, expecting != call {
            throw PartCallError(code: "stale_row", message: "That row's call changed after it was shown. Read the page again before acting.")
        }
        inverses = inverses.filter {
            $0.key.page != id || $0.key.door != door || $0.key.device != device || $0.key.renderer != renderer
        }
        let tap = Tap(page: id, row: row, action: action, door: door, device: device, chat: chat, decided: decided, renderer: renderer)
        return await perform(call, tap: tap, operation: operation, undoKey: undoKey, run: run)
    }

    private func perform(_ call: PartFace.Call, tap: Tap, operation: UUID?, undoKey: UndoKey, run: Run) async -> FaceActOutcome {
        let id = tap.page, row = tap.row
        let owner = currentSnapshot(id)
        do {
            var outcome = try await run(call, tap)
            let read = await refresh(page: id)
            if let operation, let inverse = outcome.undo, outcome.effects != .unknown {
                if let read, let owner, currentSource(id)?.part == owner.part, read.part == owner.part, read.version == owner.version {
                    inverses = inverses.filter {
                        $0.key.page != id || $0.key.door != tap.door || $0.key.device != tap.device || $0.key.renderer != tap.renderer
                    }
                    inverses[undoKey] = Inverse(operation: operation, call: inverse, tap: tap, part: read.part, version: read.version)
                }
            }
            if outcome.accepted, outcome.effects != .unknown, tap.action == "set", read?.status == .ready {
                let sections = (read?.levers ?? []) + (read?.keyLevers ?? []) + (read?.drawnFace?.sections ?? [])
                if let control = sections.flatMap(\.allRows).first(where: { $0.id == row && $0.control != nil })?.control,
                   let submitted = call.args["value"], case .string(let value) = submitted,
                   control.settingCall(value) == call, let text = control.text {
                    outcome.committed = [FaceCommittedField(id: "value", value: .string(text))]
                }
            }
            return outcome
        } catch {
            await refresh(page: id)
            if let failure = error as? ToolFailureError {
                let effects: FaceEffects = switch failure.effects {
                case .none: .none
                case .occurred, .partial: .known
                case .unknown: .unknown
                }
                return .interrupted(WireFailure(code: failure.code ?? "page_action_failed", message: failure.message,
                    cause: failure.instruction, effects: effects,
                    fields: failure.argumentPath.map { [$0: failure.message] }))
            }
            return .interrupted(error)
        }
    }

    /// A read settles a field only when its current owner proves the exact submitted value under the same call.
    public func reconcile(page: String, row: String, value: String?, values: [String: PartFace.Value]? = nil,
                          expecting: PartFace.Call) async -> FaceActOutcome {
        let read = await refresh(page: page)
        guard let read, read.status == .ready else {
            return FaceActOutcome(words: read?.error?.message ?? "The page has not returned a current reading.", effects: .unknown)
        }
        let sections = (read.levers ?? []) + (read.keyLevers ?? []) + (read.drawnFace?.sections ?? [])
        let rows = sections.flatMap(\.allRows).filter { $0.id == row }
        if values == nil, let value, let control = rows.compactMap(\.control).first, control.settingCall(value) == expecting,
           control.text == value {
            return FaceActOutcome(words: "The field's current value matches this edit.", effects: .known, accepted: true,
                                  committed: [FaceCommittedField(id: "value", value: .string(value))])
        }
        let forms = sections.filter { $0.block?.kind == "form" && $0.block?.key == row }
        let face = PartFace(sections: [.init(id: "current", rows: rows)] + forms)
        return FaceActOutcome(words: "The current page does not establish this action's effect.\n" + face.text(), effects: .unknown)
    }

    public func remove(id: String) async {
        inverses = inverses.filter { $0.key.page != id }
        let task = refreshes.removeValue(forKey: id)
        task?.cancel()
        sources.removeValue(forKey: id)
        items.removeValue(forKey: id)
        itemClaims.removeValue(forKey: id)
        itemDemands = itemDemands.filter { $0.value.page != id }
        drawnFrom.removeValue(forKey: id)
        gate(id).write { snapshots.removeValue(forKey: id) }
        publishRemoval(id)
        if let task { await settle { await task.value } }
    }

    /// Retire publication and cancel synchronously before native quit waits; the owner must await the returned settlement drain.
    public func stop() -> Task<Void, Never> {
        inverses.removeAll()
        itemDemands.removeAll()
        items.removeAll()
        itemClaims.removeAll()
        stopped = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let tasks = Array(refreshes.values)
            + (keyringObservation.map { [$0] } ?? [])
        keyringObservation = nil
        for task in tasks { task.cancel() }
        refreshes.removeAll()
        for id in sources.keys { gate(id).write { snapshots.removeValue(forKey: id) } }
        sources.removeAll()
        drawnFrom.removeAll()
        publication.finish()
        let publishing = publishing
        return Task.detached {
            await settle { for task in tasks { await task.value } }
            await publishing.value
        }
    }

    /// An explicit owner removal clears the drawn value; an unfinished read never means removal.
    private func publishRemoval(_ id: String) {
        inverses = inverses.filter { $0.key.page != id }
        guard !stopped else { return }
        publication.yield(.snapshot(id, .init(part: id, version: nil, sourceEpoch: 0, status: .unavailable, face: nil,
            error: .init(code: "page_removed", message: "The owner removed the \(id) face."), owed: false)))
    }

    public func close() async {
        await stop().value
    }

    /// Finish handing admitted values to the feed before a capture asks it to draw.
    public func flush() async {
        let admitted = await withCheckedContinuation { continuation in
            if case .terminated = publication.yield(.flush(continuation)) { continuation.resume(returning: false) }
        }
        if !admitted { await publishing.value }
    }
}

private extension PartFace {
    func readingSecretStatus(page: String) throws -> Self {
        var result = self
        result.sections = try sections.map { section in
            var section = section
            if var block = section.block, block.protected == true,
               let receiver = block.receiver, receiver.hasPrefix("keyring:") {
                let name = String(receiver.dropFirst("keyring:".count))
                guard Keyring.validName(name) else { throw PartCallError(code: "bad_face", message: "The keyring receiver has an invalid name.") }
                block.secretSet = try Keyring.entry(name) != nil
                block.secretPage = page
                section.block = block
            }
            return section
        }
        return result
    }
}
