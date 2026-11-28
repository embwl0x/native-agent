import SenseCore
import MacNerves
import DeskCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `HomeFace.swift` | Home packet for `native-home`: named owner facts, thoughts, owed, attention and gaps |

package enum HomeFace {
    struct ExperiencesChanged: BodySignal {}

    @concurrent static func door(dataRoot: URL) async throws -> PartFace {
        guard let snapshot = await NativeAgentEngine.forRoot(dataRoot).pages.refresh(page: "home") else {
            throw PartCallError(code: "home_unattached", message: "Home's page owner has not attached. Open NativeAgent before reading Home.")
        }
        guard snapshot.status == .ready, let face = snapshot.face else {
            throw snapshot.error ?? PartCallError(code: "home_unavailable", message: "Home returned no readable face.")
        }
        return PartFace(title: face.title, line: face.line, sections: (snapshot.levers ?? []) + face.sections, opened: face.opened)
    }

    private static func observe(center: NotificationCenter, changed: @escaping @Sendable () -> Void)
        -> [NotificationCenter.ObservationToken] {
        [
            center.addObserver(for: AgentWorkspaceScreenPreview.DidChange.self) { _ in changed() },
            center.addObserver(for: BrowserConnectionMirror.DidChange.self) { _ in changed() },
            center.addObserver(for: SurfaceLayoutLive.DidChange.self) { _ in changed() },
        ]
    }

    @MainActor package final class Owner {
        private nonisolated let workspace: WorkspaceOperation
        private nonisolated let dataRoot: URL
        private var observers: [NotificationCenter.ObservationToken] = []
        private var sources: Task<Void, Never>?
        private nonisolated let projection = Projection()
        private let changed: @MainActor @Sendable () async -> Void
        private var refresh: Task<Void, Never>?
        private var dirty = false

        package init(workspace: WorkspaceOperation, dataRoot: URL, changed: @escaping @MainActor @Sendable () async -> Void) {
            self.workspace = workspace.preview()
            self.dataRoot = dataRoot
            self.changed = changed
            observers = HomeFace.observe(center: .default) { [weak self] in
                Task { @MainActor [weak self] in self?.signalRefresh() }
            }
            sources = Task.detached { [workspace = self.workspace] in
                guard !Task.isCancelled else { return }
                AgentMemo.shared.holdWorld(dataRoot)
                defer { AgentMemo.shared.releaseWorld(dataRoot) }
                AgentScreen.observeHome(workspace: workspace, dataRoot)
                for await _ in await ExperienceStore.at(dataRoot).changes() {
                    guard !Task.isCancelled else { return }
                    NotificationCenter.default.post(HomeFace.ExperiencesChanged())
                }
            }
        }

        isolated deinit {
            sources?.cancel()
            refresh?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
        }

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

        @concurrent nonisolated package func read(layout: SurfaceLayoutAvailability, attention: JSONValue) async -> PartFaces.Packet {
            await projection.read(workspace: workspace, dataRoot: dataRoot, layout: layout, attention: attention)
        }
    }

    private actor Projection {
        private var components: [String: Component] = [:]
        private var repairRows: [String: RepairRow] = [:]

        func read(workspace: WorkspaceOperation, dataRoot: URL, layout: SurfaceLayoutAvailability, attention: JSONValue) -> PartFaces.Packet {
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

    private static func component(_ id: String, from names: [String], world: AgentWorld, components: inout [String: Component],
                                  keys: inout RowKeys, content: Component.Input? = nil, build: (inout RowKeys) -> JSONValue) -> JSONValue {
        let input = content ?? .readings(names.map { world.readings[$0]?.identity })
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

    private static let sources: [String: [String]] = [
        "mind": ["thoughts", "owed to me"], "notable": ["profile", "mail preview"], "changed": [], "waits": ["desk", "asks", "owed"],
        "queue": ["desk", "queue evidence", "reviews", "people", "contacts", "owed"],
        "working": ["work"], "people": ["contacts", "people", "health", "delegations", "found"],
        "helpers": ["bots", "running helpers"], "senses": ["senses"],
        "elsewhere": ["elsewhere", "contacts"], "places": ["desk"], "mac": ["windows"],
    ]

    private static func packet(_ world: AgentWorld, dataRoot: URL, layout: SurfaceLayoutAvailability, attention: JSONValue,
                               now: Date, components: inout [String: Component], repairRows: inout [String: RepairRow]) -> PartFaces.Packet {
        var keys = RowKeys()
        let repairs = world.repairs.filter(RepairOwed.isOwed)
        let repairIDs = Set(repairs.map(\.id))
        repairRows = repairRows.filter { repairIDs.contains($0.key) }
        let person = world.profile?.userName.trimmedNonEmpty.map { AgentScreen.clip($0, 40) } ?? "the person"
        let order = layout.contentNames("home", profile: SurfaceLayoutStore.profile)
        var mail: JSONValue = .null
        if world.mailPreviewAllowed == true,
           let preview = AgentReadBadges.shared.latest("mail.previews", dataRoot: dataRoot), !preview.words.isEmpty {
            keys.add("mail.previews", open: "page:home/mail")
            mail = fact(["key": .string("mail.previews"), "words": .string(preview.words), "at": .string(clock(preview.at))])
        }
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
                if world.unread.contains(key) { return fact(["source": .string(key)]) }
                // A reading under a minute old that is already being read again is current enough: her own acts in a turn invalidate it constantly.
                guard world.pending.contains(key), let reading = world.readings[key], Date().timeIntervalSince(reading.at) > 60 else { return nil }
                return fact(["source": .string(key), "at": .string(clock(reading.at))])
            })
        }
        var facts: [String: JSONValue] = [
            "person": .string(person), "order": .array(order.map(JSONValue.string)), "attention": attention,
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
        facts["mac"] = .array(mac(world, now: now, keys: &keys))
        facts["keys"] = .object(keys.all)
        return PartFaces.Packet(facts: .object(facts), epoch: UInt64(now.timeIntervalSince1970 * 1000), levers: levers(world, now: now, dataRoot: dataRoot))
    }

    static func clock(_ date: Date) -> String { date.formatted(.iso8601) }

    static func recorded(_ at: String) -> JSONValue? {
        NativeTimestampFormat.parseISO8601FractionalFirst(at).map { .string(clock($0)) }
    }
}
