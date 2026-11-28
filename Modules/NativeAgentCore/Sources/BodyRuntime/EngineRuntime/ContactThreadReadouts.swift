import Foundation
import NativeAgentShared
import PersistenceCore
import SenseCore
import Observation
import NativeAgentCore
import Synchronization
import ProviderRouting
import os
// Blueprint: | `ContactThreadReadouts.swift` | Root-scoped contact and independent helper watches; checked in-memory publication feeds the Helpers face |

@MainActor @Observable
final class ContactFlightReadout {
    @ObservationIgnored var flight: AgentContactFlight?
    var structure: AgentContactFlight?
    var partial: String?
    var hasPartial = false

    func update(_ value: AgentContactFlight?) {
        flight = value
        let text = value?.partial
        if partial != text { partial = text }
        if hasPartial != (text != nil) { hasPartial = text != nil }
        var shape = value
        if var live = shape?.live {
            live.partial = nil
            live.partialChars = 0
            live.partialTruncated = false
            live.lastActivityAt = live.startedAt
            live.firstActivityAt = nil
            shape?.live = live
        }
        if structure != shape { structure = shape }
    }
}

@MainActor @Observable
public final class ContactThreadReadouts {
    public nonisolated let dataRoot: URL
    @ObservationIgnored private var contactsWatch: Task<Void, Never>?
    @ObservationIgnored private let contactRead = LatestRead()
    @ObservationIgnored private var helpersWatch: Task<Void, Never>?
    @ObservationIgnored private let helpersRead = LatestRead()
    @ObservationIgnored private weak var helperEngine: NativeAgentEngine?
    struct HelpersDidChange: NotificationCenter.MainActorMessage {
        typealias Subject = NSURL
        let root: URL
    }

    private nonisolated let contactOwner: ContactListFacade

    public nonisolated init(dataRoot: URL, contacts: ContactListFacade) {
        self.dataRoot = dataRoot
        self.contactOwner = contacts
    }

    /// Both shells share this engine’s projection and watches.
    public func start() {
        if contactsWatch == nil { restartContacts() }
    }

    /// An explicit refresh rereads credentials as well as the thread projection that holds send restrictions.
    public func refreshContacts() async throws {
        loaded = false
        contactRefreshError = nil
        restartContacts()
        try await prepareContactsForCapture()
    }

    /// Captures join the contact owner's first read instead of drawing its uninitialized catalog.
    public func prepareContactsForCapture() async throws {
        start()
        let changes = Observations { (self.loaded, self.contactRefreshError) }
        for await (loaded, issue) in changes {
            try Task.checkCancellation()
            if let issue { throw PartCallError(code: "contacts_unavailable", message: issue) }
            if loaded { return }
        }
        throw CancellationError()
    }

    private func restartContacts() {
        contactsWatch?.cancel()
        let root = dataRoot, ids = helpers.map(\.id)
        contactsWatch = Task { [weak self] in
            await Self.watch(root: root, helpers: ids) { [weak self] in self }
        }
    }

    deinit { contactsWatch?.cancel(); helpersWatch?.cancel() }

    public private(set) var contacts: [AgentContactPresentation] = []
    public private(set) var lines: [String: [AgentContactThreadLine]] = [:]
    public private(set) var otherRooms: [OtherRoomExchange] = []
    public private(set) var waiting: Set<String> = []
    public private(set) var status: [String: AgentConversationDelivery] = [:]
    @ObservationIgnored private var flights: [String: AgentContactFlight] = [:]
    @ObservationIgnored private var flightSlots: [String: ContactFlightReadout] = [:]
    public private(set) var helpers: [BotsShelfRecord] = [] {
        didSet {
            if contactsWatch != nil, oldValue.map(\.id) != helpers.map(\.id) { restartContacts() }
        }
    }
    public private(set) var helperRuns: [UUID: Result<AgentContactThreads.HelperResults, WireFailure>] = [:]
    /// False until the first read lands, so an empty list isn't claimed early.
    public private(set) var loaded = false
    /// Each checked source retains its own failure until that source reads successfully.
    public private(set) var contactRefreshError: String?
    public private(set) var running: Set<UUID> = []
    public private(set) var helpersLoaded = false
    public private(set) var helpersRefreshError: String?
    public private(set) var helpersUnattended: Bool?

    static func helperPaths(_ root: URL) -> [URL] {
        ["bots/definitions", "bots/shelf-index.json", "bots/run-queue.json", "clock/times.json", "bots/missed-runs.json", "bots/last-events.json",
         "workflows/approvals/requests.json", "trust/policy.json", "providers", "providers/surfaces.json", "providers/active.json",
         "codex_home/auth.json", "codex_home/models_cache.json"]
            .map { root.appendingPathComponent($0) }
    }

    /// The helper owner reads its sources at launch and their changes; a face only reads this published memory.
    func startHelpers(engine: NativeAgentEngine) {
        guard helpersWatch == nil else { return }
        helperEngine = engine
        let root = dataRoot
        helpersWatch = Task { [weak self] in
            await EventDeadlinePhysiology.refreshOnChanges(paths: Self.helperPaths(root),
                notifications: [BotRunQueue.DidChange.name, ShelfStore.DidChange.name, ChatGPTAccountModelRefresh.DidRefresh.name,
                    .NSSystemTimeZoneDidChange, .NSSystemClockDidChange], directoryFiles: engine.pageDirectoryFiles) { [weak self] in
                _ = await self?.refreshHelpers()
            }
        }
    }

    @discardableResult public func refreshHelpers() async -> Bool {
        let root = dataRoot
        let result = await helpersRead.read {
            do {
                guard let engine = helperEngine else {
                    throw PartCallError(code: "helpers_owner_unavailable", message: "The helper owner has not started. Reopen Helpers after launch.")
                }
                var unattended: Bool?
                var records = try await engine.botsShelfRead { unattended = $0 }
                for index in records.indices {
                    do {
                        let choice = try await BotChatContract.choice(for: records[index].definition, dataRoot: root)
                        records[index].followingModel = choice.model
                    } catch { records[index].modelChoiceIssue = String(describing: error) }
                }
                return Result<([BotsShelfRecord], Bool?), Error>.success((records, unattended))
            } catch { return .failure(error) }
        } publish: { result in
            let changed: Bool
            switch result {
            case .success(let (records, unattended)):
                changed = helpers != records || helpersUnattended != unattended || !helpersLoaded || helpersRefreshError != nil
                if helpers != records { helpers = records }
                running = Set(records.filter { $0.running || $0.queued }.map(\.id))
                helpersUnattended = unattended
                helpersLoaded = true
                helpersRefreshError = nil
            case .failure(let error):
                let problem = UserFacingError.message(error, action: "read helpers")
                changed = helpersRefreshError != problem
                helpersRefreshError = problem
            }
            if changed { NotificationCenter.default.post(HelpersDidChange(root: root), subject: root as NSURL) }
        }
        if case .success = result { return true }
        return false
    }

    private typealias Snapshot = AgentContactThreads.Snapshot
    private typealias ContactRead = (Snapshot, AgentContactThreads.Delta?, [UUID: Result<AgentContactThreads.HelperResults, WireFailure>]?)

    public nonisolated static func key(_ helper: UUID) -> String { AgentContactThreads.key(helper) }

    private func slot(_ id: String) -> ContactFlightReadout {
        if let slot = flightSlots[id] { return slot }
        let slot = ContactFlightReadout()
        flightSlots[id] = slot
        return slot
    }

    public func flight(for id: String) -> AgentContactFlight? {
        let slot = slot(id)
        _ = slot.structure
        _ = slot.hasPartial
        return slot.flight
    }

    public func partial(for id: String) -> String? { slot(id).partial }

    func mobileThreads() throws -> [MobileAgentThread] {
        if let issue = contactRefreshError { throw PartCallError(code: "contacts_unavailable", message: issue) }
        guard loaded else { throw PartCallError(code: "contacts_unread", message: "Agent conversations are still being read.") }
        return try AgentContactThreads.mobileThreads(snapshot: Snapshot(contacts: contacts, lines: lines, waiting: waiting,
            status: status, flights: flights, helpers: helpers, running: running, otherRooms: otherRooms))
    }

    /// Owner changes refresh conversations; live-hub partials re-read only flights.
    private static func watch(root: URL, helpers ids: [UUID], projection: @MainActor () -> ContactThreadReadouts?) async {
        var last: Snapshot
        do {
            guard let owner = projection() else { return }
            last = Snapshot(contacts: owner.contacts, lines: owner.lines, waiting: owner.waiting, status: owner.status,
                            flights: owner.flights, helpers: owner.helpers, running: owner.running, otherRooms: owner.otherRooms)
        }
        let paths = ["agents/peers.json", "agents/conversations.json", "agents/discovery.json", "agents/recipes/", "chat/sessions.json", "bots/definitions",
                     "bots/shelf-index.json", "bots/run-queue.json", "agents/conversation-live.json",
                     "agents/local-health.json", "agents/reply-reads.json"]
            + ids.map { "bots/\($0.uuidString)/run.lock" }
        let liveFile = root.appendingPathComponent("agents/conversation-live.json").standardizedFileURL
        let events = await EventDeadlinePhysiology.readEvents(paths: paths.map { root.appendingPathComponent($0) }.filter { $0 != liveFile },
            directoryFiles: { directory in
                if directory.standardizedFileURL == root.appendingPathComponent("bots/definitions", isDirectory: true).standardizedFileURL {
                    return try BotDefinitionStore(dataRoot: root).definitionFiles()
                }
                return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            })
        let liveEvents = await EventDeadlinePhysiology.readEvents(paths: [liveFile])
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let pending = Mutex((full: true, live: false, doors: true))
        let files = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in events.stream {
                        pending.withLock { $0.full = true; $0.doors = true }
                        tick.yield()
                    }
                }
                for await _ in liveEvents.stream {
                    pending.withLock { $0.live = true }
                    tick.yield()
                }
                group.cancelAll()
            }
        }
        let experienceChanges = Task {
            for await _ in await ExperienceStore.at(root).changes() {
                pending.withLock { $0.full = true }
                tick.yield()
            }
        }
        let ended = NotificationCenter.default.observeSynchronously(for: BotRunQueue.DidChange.self) {
            pending.withLock { $0.full = true; $0.doors = true }
            tick.yield()
        }
        let helpersChanged = NotificationCenter.default.addObserver(for: HelpersDidChange.self) { _ in
            pending.withLock { $0.full = true; $0.doors = true }
            tick.yield()
        }
        let dotChanged = NotificationCenter.default.observeSynchronously(for: ChatGPTDotIPCTransport.DidChange.self) {
            pending.withLock { $0.full = true; $0.doors = true }
            tick.yield()
        }
        tick.yield()
        await withTaskCancellationHandler {
            for await _ in ticks {
                guard let owner = projection() else { break }
                guard !Task.isCancelled else { break }
                guard pending.withLock({ $0.full || $0.live }) else { continue }
                let first = !owner.loaded
                let retry = owner.contactRefreshError != nil
                let (full, doors) = pending.withLock { state in
                    defer { state = (false, false, false) }
                    return (state.full || first || retry, state.doors || first || retry)
                }
                let result = await owner.contactRead.read {
                    do { return Result<ContactRead, Error>.success(try await Task.detached(priority: .userInitiated) { [last, contactOwner = owner
                        .contactOwner, helpers = owner.helpers] in
                        // A records change detected during a live tick still requires a full read.
                        if !full, let flights = try AgentContactThreads.readFlights(root: root, last: last) {
                            var next = last
                            next.flights = flights
                            let unread: [UUID: Result<AgentContactThreads.HelperResults, WireFailure>]? = nil
                            return (next, AgentContactThreads.changes(from: last, to: next), unread)
                        }
                        let snapshot = try await AgentContactThreads.read(root: root, contacts: contactOwner,
                            refreshDoors: doors || !full)
                        let next = snapshot
                        let delta = AgentContactThreads.changes(from: last, to: next)
                        var runs: [UUID: Result<AgentContactThreads.HelperResults, WireFailure>] = [:]
                        for helper in helpers {
                            do {
                                runs[helper.id] = .success(try await AgentContactThreads.helperResults(helper, root: root,
                                    representedResults: Set((next.lines[Self.key(helper.id)] ?? []).compactMap(\.resultID))))
                            } catch {
                                runs[helper.id] = .failure(WireFailure(code: "helper_history_unavailable",
                                    message: "Could not read results for helper \(helper.definition.name) (\(helper.id.uuidString)).",
                                    cause: error.localizedDescription, effects: .none))
                            }
                        }
                        return (next, delta, runs)
                    }.value) }
                    catch { return .failure(error) }
                } publish: { result in
                    switch result {
                    case .success(let (next, delta, runs)):
                    let changed = delta != nil || runs.map { owner.helperRuns != $0 } == true || !owner.loaded || owner.contactRefreshError != nil
                    if let delta {
                        if let value = delta.otherRooms { owner.otherRooms = value }
                        if let value = delta.contacts { owner.contacts = value }
                        if let value = delta.lines { owner.lines = value }
                        if let value = delta.waiting { owner.waiting = value }
                        if let value = delta.status { owner.status = value }
                        if let value = delta.flights {
                            for id in Set(owner.flights.keys).union(value.keys) where owner.flights[id] != value[id] {
                                owner.slot(id).update(value[id])
                            }
                            owner.flights = value
                        }
                    }
                    if let runs, owner.helperRuns != runs { owner.helperRuns = runs }
                    if !owner.loaded { owner.loaded = true }
                    owner.contactRefreshError = nil
                    if changed { ContactsDidChange(root: root).post() }
                    case .failure(let error):
                        let problem = UserFacingError.message(error, action: "refresh conversations")
                        guard owner.contactRefreshError != problem else { return }
                        owner.contactRefreshError = problem
                        ContactsDidChange(root: root).post()
                    }
                }
                if case .success(let (next, _, _)) = result {
                    last = next
                }
            }
        } onCancel: { tick.finish() }
        files.cancel()
        await events.cancel()
        await liveEvents.cancel()
        experienceChanges.cancel()
        NotificationCenter.default.removeObserver(ended)
        NotificationCenter.default.removeObserver(helpersChanged)
        NotificationCenter.default.removeObserver(dotChanged)
    }

    public nonisolated static func bridgedText(_ content: String) -> String { ContactThread.bridgedText(content) }

    public nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>-* "))
    }
}
