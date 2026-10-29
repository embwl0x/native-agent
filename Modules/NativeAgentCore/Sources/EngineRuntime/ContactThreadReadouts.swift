import AgentConversations
import AgentWorkspace
import ChatToolRuntime
import Foundation
import NativeAgentShared
import PersistenceCore
import StandingBots
import Experiences
import Observation
import SwarmRuns
import os
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import BackgroundWork
import Synchronization
// Blueprint: | `ContactThreadReadouts.swift` | ContactThreadReadouts and ContactFlightReadout own mounted contact/helper/crew observation and LatestRead publication; live-only ticks update isolated flight slots |

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
    @ObservationIgnored private var crewsWatch: Task<Void, Never>?
    @ObservationIgnored private let contactRead = LatestRead()
    @ObservationIgnored private let crewRead = LatestRead()

    private nonisolated let contactOwner: ContactListFacade

    public nonisolated init(dataRoot: URL, contacts: ContactListFacade) {
        self.dataRoot = dataRoot
        self.contactOwner = contacts
    }

    /// Both shells observe this engine's existing projection and watches.
    public func start() {
        if contactsWatch == nil { restartContacts() }
        if crewsWatch == nil {
            let root = dataRoot
            crewsWatch = Task { [weak self] in
                await Self.watchCrews(root: root) { [weak self] in self }
            }
        }
    }

    private func restartContacts() {
        contactsWatch?.cancel()
        let root = dataRoot, ids = helpers.map(\.id)
        contactsWatch = Task { [weak self] in
            await Self.watch(root: root, helpers: ids) { [weak self] in self }
        }
    }

    deinit { contactsWatch?.cancel(); crewsWatch?.cancel() }

    /// Most recent exchange first, then unspoken contacts in their original order.
    public private(set) var contacts: [AgentContactPresentation] = []
    /// Per contact id, oldest first.
    public private(set) var lines: [String: [AgentContactThreadLine]] = [:]
    public private(set) var otherRooms: [OtherRoomExchange] = []
    /// Contacts with a message still on its way or awaiting a reply.
    public private(set) var waiting: Set<String> = []
    /// Where each contact's latest send stands when no reply is owed or
    /// none came: delivered, read, failed, not delivered.
    public private(set) var status: [String: AgentConversationDelivery] = [:]
    /// Per contact id: its live reply, queue and stop, while there are any.
    @ObservationIgnored private var flights: [String: AgentContactFlight] = [:]
    @ObservationIgnored private var flightSlots: [String: ContactFlightReadout] = [:]
    public private(set) var helpers: [BotsShelfRecord] = [] {
        didSet {
            if oldValue.map(\.id) != helpers.map(\.id) { restartContacts() }
        }
    }
    public private(set) var helperRuns: [UUID: AgentContactThreads.HelperResults] = [:]
    /// False until the first read lands, so an empty list isn't claimed early.
    public private(set) var loaded = false
    /// A failed refresh keeps the last proven conversation snapshot visible.
    public private(set) var refreshError: String?
    /// Helpers with a run queued or under way now.
    public private(set) var running: Set<UUID> = []
    /// Crews at work now, then the few most recently finished.
    public private(set) var crews: [SwarmCrew] = []

    private typealias Snapshot = AgentContactThreads.Snapshot
    private typealias ContactRead = (Snapshot, AgentContactThreads.Delta?, [UUID: AgentContactThreads.HelperResults]?)

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

    /// Contact, chat, shelf, claim, queue and inbox changes refresh conversations;
    /// live-hub partials re-read only flights.
    private static func watch(root: URL, helpers ids: [UUID], projection: @MainActor () -> ContactThreadReadouts?) async {
        let paths = ["agents/peers.json", "agents/conversations.json", "chat/sessions.json", "bots/definitions",
                     "bots/shelf-index.json", "bots/run-queue.json", "agents/conversation-live.json",
                     "agents/local-health.json", "agents/reply-reads.json"]
            + ids.map { "bots/\($0.uuidString)/run.lock" }
        let liveFile = root.appendingPathComponent("agents/conversation-live.json").standardizedFileURL
        let bridges = InstallPaths.current.bridgeConfigRoot(dataRoot: root)
        let inboxes = ["claude", "codex", "omp"].compactMap { AgentConversationDelivery.inbox(agent: $0, bridgeConfigRoot: bridges) }
        let events = FileChangeEvents(paths: paths.map { root.appendingPathComponent($0) } + inboxes
            + [bridges.appendingPathComponent("claude-bridge/claude-live")], emitInitial: true)
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // Clear pending changes before each read; only the live file sets `live` instead of `full`.
        let pending = OSAllocatedUnfairLock(initialState: (full: false, live: false))
        let files = Task {
            for await url in events.stream {
                pending.withLock { if url == liveFile { $0.live = true } else { $0.full = true } }
                tick.yield()
            }
        }
        let experienceChanges = Task {
            for await _ in await ExperienceStore.at(root).changes() {
                pending.withLock { $0.full = true }
                tick.yield()
            }
        }
        let ended = NotificationCenter.default.addObserver(forName: BotRunQueue.didChange, object: nil, queue: nil) { _ in
            pending.withLock { $0.full = true }
            tick.yield()
        }
        let dotChanged = NotificationCenter.default.addObserver(forName: ChatGPTDotIPCTransport.didChange, object: nil, queue: nil) { _ in
            pending.withLock { $0.full = true }
            tick.yield()
        }
        var last: Snapshot
        do {
            guard let owner = projection() else { return }
            last = Snapshot(contacts: owner.contacts, lines: owner.lines, waiting: owner.waiting, status: owner.status,
                            flights: owner.flights, helpers: owner.helpers, running: owner.running, otherRooms: owner.otherRooms)
        }
        await withTaskCancellationHandler {
            for await _ in ticks {
                guard let owner = projection() else { break }
                guard !Task.isCancelled else { break }
                guard pending.withLock({ $0.full || $0.live }) else { continue }
                // One message writes several files; let the burst land first.
                if owner.loaded { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { break }
                let first = !owner.loaded
                let retry = owner.refreshError != nil
                let full = pending.withLock { state in
                    defer { state = (false, false) }
                    return state.full || first || retry
                }
                let result = await owner.contactRead.read {
                    do { return Result<ContactRead, Error>.success(try await Task.detached(priority: .userInitiated) { [last, contactOwner = owner.contactOwner] in
                        // A records change that rode in on the live file's tick still gets its full read.
                        if !full, let flights = AgentContactThreads.readFlights(root: root, last: last) {
                            var next = last
                            next.flights = flights
                            return (next, AgentContactThreads.changes(from: last, to: next), Optional<[UUID: AgentContactThreads.HelperResults]>.none)
                        }
                        if try AgentPeerStore(dataRoot: root).list().contains(where: ChatGPTDotIPCTransport.owns) {
                            _ = await SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false).chatGPTDotReadiness()
                        }
                        let snapshot = try await AgentContactThreads.read(root: root, contacts: contactOwner)
                        let next = snapshot
                        let delta = AgentContactThreads.changes(from: last, to: next)
                        var runs: [UUID: AgentContactThreads.HelperResults] = [:]
                        for helper in next.helpers {
                            runs[helper.id] = try await AgentContactThreads.helperResults(helper, root: root,
                                representedResults: Set((next.lines[Self.key(helper.id)] ?? []).compactMap(\.resultID)))
                        }
                        return (next, delta, runs)
                    }.value) }
                    catch { return .failure(error) }
                } publish: { result in
                    switch result {
                    case .success(let (next, delta, runs)):
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
                        if let value = delta.helpers { owner.helpers = value }
                        if let value = delta.running { owner.running = value }
                    }
                    if let runs, owner.helperRuns != runs { owner.helperRuns = runs }
                    if !owner.loaded { owner.loaded = true }
                    owner.refreshError = nil
                    case .failure(let error):
                        owner.refreshError = UserFacingError.message(error, action: "refresh conversations")
                    }
                }
                if case .success(let (next, _, _)) = result {
                    last = next
                }
            }
        } onCancel: { events.cancel(); tick.finish() }
        files.cancel()
        experienceChanges.cancel()
        NotificationCenter.default.removeObserver(ended)
        NotificationCenter.default.removeObserver(dotChanged)
    }

    /// Crews on their own watch: runs.json keeps every finished run whole, so
    /// it is read only when a crew changes, never on a contact's message.
    private static func watchCrews(root: URL, projection: @MainActor () -> ContactThreadReadouts?) async {
        let paths = ["swarms/live.json", "swarms/runs.json"].map { root.appendingPathComponent($0) }
        // Arm on the folder so the first crew is seen; create only that empty folder.
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: paths[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        }.value
        let events = FileChangeEvents(paths: paths, emitInitial: true)
        await withTaskCancellationHandler {
            for await _ in events.stream {
                guard let owner = projection() else { break }
                guard !Task.isCancelled else { break }
                _ = await owner.crewRead.read { () async -> Result<[SwarmCrew], Error> in
                    do { return .success(try await Task.detached(priority: .utility) { try SwarmCrew.read(root: root) }.value) }
                    catch { return Result<[SwarmCrew], Error>.failure(error) }
                } publish: { result in
                    switch result {
                    case .success(let next): if owner.crews != next { owner.crews = next }
                    case .failure(let error): owner.refreshError = UserFacingError.message(error, action: "refresh crews")
                    }
                }
            }
        } onCancel: { events.cancel() }
    }

    /// Strip bridge notes and bare contact metadata from a bridged turn.
    public nonisolated static func bridgedText(_ content: String) -> String { ContactThread.bridgedText(content) }

    /// The first line of some text with its markdown marks gone, for a row.
    public nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>-* "))
    }
}
