import AuthoredCapabilities
import ChromeControl
import Desk
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
import Transcripts
// Blueprint: | `HomeFace.swift` | Home's packet for `native-home`: world parts as keyed facts, thoughts, owed, attention; lifetime and gaps |

package enum HomeFace {
    static let experiencesChanged = Notification.Name("NativeAgent.homeExperiencesChanged")
    package static let jobsChanged = Notification.Name("NativeAgent.homeJobsChanged")
    @MainActor private static var readers: [String: @MainActor () async -> PartFaceSnapshot?] = [:]

    /// Read the page owner, rather than keeping a second face for the workspace door.
    @MainActor package static func bind(dataRoot: URL, read: @escaping @MainActor () async -> PartFaceSnapshot?) {
        readers[dataRoot.standardizedFileURL.path] = read
    }

    /// The agent's door reads Home as every door draws it: the person's levers first, then the face the agent's part drew.
    @concurrent static func door(dataRoot: URL) async throws -> PartFace {
        let read = await MainActor.run { readers[dataRoot.standardizedFileURL.path] }
        guard let read, let snapshot = await read() else {
            throw PartCallError(code: "home_unattached", message: "Home's page owner has not attached. Open NativeAgent before reading Home.")
        }
        guard snapshot.status == .ready, let face = snapshot.face else {
            throw snapshot.error ?? PartCallError(code: "home_unavailable", message: "Home returned no readable face.")
        }
        return PartFace(title: face.title, line: face.line, sections: (snapshot.levers ?? []) + face.sections)
    }

    private static func observe(center: NotificationCenter, names: [Notification.Name], changed: @escaping @Sendable () -> Void)
        -> [any NSObjectProtocol] {
        names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in changed() }
        }
    }

    @MainActor package final class Owner {
        private nonisolated let workspace: WorkspaceOperation
        private nonisolated let dataRoot: URL
        private var observers: [(any NSObjectProtocol)] = []
        private var sources: Task<Void, Never>?
        private nonisolated let projection = Projection()
        private let changed: @MainActor @Sendable () async -> Void
        private var refresh: Task<Void, Never>?
        private var dirty = false

        package init(workspace: WorkspaceOperation, dataRoot: URL, changed: @escaping @MainActor @Sendable () async -> Void) {
            self.workspace = workspace.preview()
            self.dataRoot = dataRoot
            self.changed = changed
            observers = HomeFace.observe(center: .default,
                names: [AgentWorkspaceScreenPreview.didChange, BrowserConnectionMirror.didChange, SurfaceLayoutLive.didChange]) { [weak self] in
                Task { @MainActor [weak self] in self?.signalRefresh() }
            }
            sources = Task.detached { [workspace = self.workspace] in
                guard !Task.isCancelled else { return }
                AgentMemo.shared.holdWorld(dataRoot)
                defer { AgentMemo.shared.releaseWorld(dataRoot) }
                AgentScreen.observeHome(workspace: workspace, dataRoot)
                for await _ in await ExperienceStore.at(dataRoot).changes() {
                    guard !Task.isCancelled else { return }
                    NotificationCenter.default.post(name: HomeFace.experiencesChanged, object: nil)
                }
            }
        }

        isolated deinit {
            sources?.cancel()
            refresh?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Source changes during a refresh owe one follow-up read when it completes.
        private func signalRefresh() {
            dirty = true
            guard refresh == nil else { return }
            refresh = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.dirty = false
                await self.changed()
                self.refresh = nil
                if self.dirty, !Task.isCancelled { self.signalRefresh() }
            }
        }

        /// What `native-home` draws Home from, read from the retained parts at this moment (the epoch). `attention` is the cognition runtime's
        /// reading: `asleep`, `awake`, or `unavailable` when no runtime runs.
        @concurrent nonisolated package func read(layout: SurfaceLayoutAvailability, attention: String) async -> PartFaces.Packet {
            await projection.read(workspace: workspace, dataRoot: dataRoot, layout: layout, attention: attention)
        }
    }

    private actor Projection {
        private var components: [String: Component] = [:]
        private var repairRows: [String: RepairRow] = [:]

        func read(workspace: WorkspaceOperation, dataRoot: URL, layout: SurfaceLayoutAvailability, attention: String) -> PartFaces.Packet {
            let now = Date()
            let world = AgentScreen.retainedWorld(workspace: workspace, dataRoot, now: now)
            return HomeFace.packet(world, dataRoot: dataRoot, layout: layout, attention: attention, now: now,
                                   components: &components, repairRows: &repairRows)
        }
    }

    private struct Component {
        enum Input: Equatable {
            case readings([UUID?])
            case experiences([[Experience]])
        }
        let input: Input
        let facts: JSONValue
        let keys: RowKeys

    }

    struct RepairRow {
        let source: Experience
        let facts: JSONValue
    }

    /// Each component retains only its last derivation of exact retained owner results. Missing readings are nil, never a success verdict.
    /// Source failures get new identities too. Clock-dependent queue verdicts and trial levers are read at `now` rather than cached.
    private static func component(_ id: String, from names: [String], world: AgentWorld, components: inout [String: Component],
                                  keys: inout RowKeys, content: Component.Input? = nil, build: (inout RowKeys) -> JSONValue) -> JSONValue {
        let input = content ?? .readings(names.map { world.readings[$0] })
        let result: Component
        if let kept = components[id], kept.input == input { result = kept }
        else {
            var ownKeys = RowKeys()
            result = Component(input: input, facts: build(&ownKeys), keys: ownKeys)
            components[id] = result
        }
        keys.merge(result.keys)
        return result.facts
    }

    /// The keys a Home packet declares: where each row id may lead, what it may do, and the door call each action makes (`PartFace.Keys`
    /// reads them). An action's id is the verb it calls.
    struct RowKeys {
        private(set) var all: [String: JSONValue] = [:]

        mutating func merge(_ other: RowKeys) { all.merge(other.all) { _, new in new } }

        mutating func add(_ id: String, open: String? = nil, actions: [(call: PartFace.Call, destructive: Bool)] = []) {
            var key: [String: JSONValue] = [:]
            if let open { key["open"] = .string(open) }
            if !actions.isEmpty {
                key["actions"] = .array(actions.map { action in
                    var fields: [String: JSONValue] = ["id": .string(action.call.action), "call": .object(action.call.input)]
                    if action.destructive { fields["role"] = .string("destructive") }
                    return .object(fields)
                })
            }
            all[id] = .object(key)
        }
    }

    static func fact(_ fields: [String: JSONValue?]) -> JSONValue { .object(fields.compactMapValues { $0 }) }
    static func text(_ value: String?) -> JSONValue? { value.map(JSONValue.string) }

    /// Which retained parts feed each section: a part never read is a gap there, and a part that failed names its failure there.
    private static let sources: [String: [String]] = [
        "mind": ["thoughts", "owed to me"], "notable": ["profile", "mail preview"], "changed": [], "waits": ["desk", "asks", "owed"],
        "queue": ["desk", "queue evidence", "reviews", "people", "contacts", "owed"],
        "working": ["work"], "open": [], "people": ["contacts", "people", "health", "delegations", "found"],
        "helpers": ["bots", "running helpers"], "senses": ["senses"],
        "elsewhere": ["elsewhere", "contacts"], "places": ["desk"], "mac": ["touched"],
    ]

    private static func packet(_ world: AgentWorld, dataRoot: URL, layout: SurfaceLayoutAvailability, attention: String,
                               now: Date, components: inout [String: Component], repairRows: inout [String: RepairRow]) -> PartFaces.Packet {
        var keys = RowKeys()
        let repairs = world.repairs.filter(RepairOwed.isOwed)
        let repairIDs = Set(repairs.map(\.id))
        repairRows = repairRows.filter { repairIDs.contains($0.key) }
        let person = world.profile?.userName.flatMap(AgentScreen.nonEmpty).map { AgentScreen.clip($0, 40) } ?? "the person"
        let order = layout.contentNames("home", profile: SurfaceLayoutStore.profile)
        var mail: JSONValue = .null
        if world.mailPreviewAllowed == true,
           let preview = AgentReadBadges.shared.latest("mail.previews", dataRoot: dataRoot), !preview.words.isEmpty {
            keys.add("mail.previews", open: "page:home/mail")
            mail = fact(["key": .string("mail.previews"), "words": .string(preview.words), "at": .string(clock(preview.at))])
        }
        keys.add("windows", open: "page:home/windows")
        let working = component("working", from: ["work"], world: world, components: &components, keys: &keys) { keys in
            .array(world.work.filter(\.working).prefix(10).map { job in
                keys.add("job:" + job.id, actions: [(PartFace.Call("agent.read", ["job": .string(job.id)]), false)])
                return fact(["key": .string("job:" + job.id), "title": .string(AgentScreen.clip(AgentScreen.firstLine(job.brief), 100)),
                    "name": .string(AgentScreen.clip(job.name, 60)), "state": .string(job.state), "at": .string(clock(job.at))])
            })
        }
        var gaps: [String: JSONValue] = [:]
        for name in ["mind"] + order {
            gaps[name] = .array((sources[name] ?? []).compactMap { key -> JSONValue? in
                if let failure = world.failures[key] { return fact(["source": .string(key), "failure": .string(failure)]) }
                // A part re-reading keeps its last value; only a part never read yet is a gap on the page.
                return world.unread.contains(key) ? fact(["source": .string(key)]) : nil
            })
        }
        var facts: [String: JSONValue] = [
            "person": .string(person), "order": .array(order.map(JSONValue.string)), "attention": .object(["state": .string(attention)]),
            "mail": mail, "working": working, "gaps": .object(gaps),
        ]
        facts["thoughts"] = component("thoughts", from: ["thoughts"], world: world, components: &components, keys: &keys,
            content: .experiences(world.thoughts.map { [$0.thought] + $0.attended })) { _ in
            .array(thoughts(world))
        }
        facts["owed"] = component("owed", from: ["owed to me"], world: world, components: &components, keys: &keys,
            content: .experiences([world.owedToMe])) { _ in owed(world) }
        facts["agent"] = world.profile.map { JSONValue.string(AgentScreen.clip($0.name, 40)) } ?? .null
        facts["layoutFailure"] = text(layout.failure?.localizedDescription) ?? .null
        let personRepairs = Self.repairs(repairs, person: true, keys: &keys, cache: &repairRows)
        facts["waits"] = .array(waits(world, keys: &keys) + personRepairs)
        let steps = queue(world, now: now, keys: &keys)
        let agentRepairs = Self.repairs(repairs, person: false, keys: &keys, cache: &repairRows)
        facts["queue"] = .array(steps + agentRepairs)
        facts["people"] = component("people", from: ["contacts", "people", "health", "delegations", "found"], world: world,
            components: &components, keys: &keys) { keys in .array(people(world, keys: &keys)) }
        facts["helpers"] = component("helpers", from: ["bots", "running helpers"], world: world, components: &components, keys: &keys) { keys in
            .array(helpers(world, keys: &keys))
        }
        facts["senses"] = component("senses", from: ["senses"], world: world, components: &components, keys: &keys) { keys in
            .array(senses(world, keys: &keys))
        }
        facts["elsewhere"] = component("elsewhere", from: ["elsewhere", "contacts", "profile"], world: world,
            components: &components, keys: &keys) { keys in
            .array(elsewhere(world, person: person, keys: &keys))
        }
        facts["places"] = .array(places(world, dataRoot: dataRoot, layout: layout, keys: &keys))
        facts["mac"] = component("mac", from: ["touched"], world: world, components: &components, keys: &keys) { keys in
            .array(mac(world, keys: &keys))
        }
        facts["keys"] = .object(keys.all)
        return PartFaces.Packet(facts: .object(facts), epoch: UInt64(now.timeIntervalSince1970 * 1000), levers: levers(world, now: now))
    }

    static func clock(_ date: Date) -> String { date.formatted(.iso8601) }

    /// A record time in the faces' clock; a time the record cannot read is absent from the fact, never invented.
    static func recorded(_ at: String) -> JSONValue? {
        NativeTimestampFormat.parseISO8601FractionalFirst(at).map { .string(clock($0)) }
    }
}
