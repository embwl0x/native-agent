import ApprovalInbox
import AuthoredCapabilities
import ChatSessionWork
import Foundation
import Experiences
import NativeAgentCore
import MemoryV2
import MacControl
import NotificationInbox
import PersistenceCore
import PersonaEngine
import Desk
import StandingBots
import Senses
import NativeAgentShared
import Transcripts
import TurnTrace
// Blueprint: | `AgentWorld.swift` | Retained owner projections; asks read ForPerson's inbox, thoughts and owed happenings the record, no second cache |
// Room acknowledgements preserve stale parts; turn pins apply to Home changes, while part owners are read separately.

/// Home, rooms and the glance draw the same retained owner projections. Owner invalidations refresh each part independently, outside page assembly.
struct AgentWorld: @unchecked Sendable {
    var records: [AgentConversationRecord] = []
    /// Keep handed-off helper entry IDs so delivered results do not announce twice.
    var handed: Set<String> = []
    var chats: [AgentScreen.BridgeChat] = []
    var contacts: [AgentScreen.Contact] = []
    var routes: [AgentScreen.Contact] = []
    var threads: [String: AgentScreen.BridgeChat] = [:]
    var jobs: [DelegationReadout] = []
    var doors: [AgentScreen.DoorLine] = []
    var senses: [String] = []
    var abilityRuns: [String: JSONValue] = [:]
    var senseFailures: [String] = []
    var identity = AgentContactIdentity(peers: [])
    var answered: [String: Date] = [:]
    var health: [String: AgentLocalHealth] = [:]
    var desk: DeskState?
    var deskFailure: String?
    var split = AgentScreen.DeskSplit()
    var bots: [BotDefinition] = []
    var latest: [UUID: ShelfEntry] = [:]
    var running: Set<UUID> = []
    var approvals: [ApprovalRecord] = []
    /// Each part of the agent's with an open trial, or whose latest trial closed: the night's rows on Home.
    var trials: [TrialLevers.Line] = []
    /// Memory proposals need the agent's review, not the owner's.
    var reviews: (count: Int, capped: Bool) = (0, false)
    /// Count an approval's inbox card only once under OwnerAttentionPolicy.
    var asks = 0
    var newestAsk: String?
    var phonePlaces: [PhonePlaceEvent] = []
    /// The agent's latest thoughts, newest first, each with the happenings it attended that the record holds.
    var thoughts: [MindLine] = []
    /// Happenings still owed, newest first: to the agent's mind stream and to the conversations work returns to.
    var owedToMe: [Experience] = []
    /// Unanswered discovery offers remain visible in PEOPLE.
    var found: [String: AgentDiscoveryOffer] = [:]
    /// Distinguish never-read parts from failed source reads.
    var unread: [String] = []
    var pending: [String] = []
    /// A completed source read failed; never described as still pending.
    var failures: [String: String] = [:]
    /// Identity of each retained source result, including a failure. Home reuses only derivations of these exact owner readings.
    var readings: [String: UUID] = [:]
    var oldest: Date?
    var profile: PersonalityProfile?
    var work: [AgentScreen.JobGlance] = []
    var repairs: [Experience] = []
    var queueEvidence: (revision: String, context: MyQueue.Context, conditions: [String: Experience])?
    var asksToOpen: [InboxItemRecord] = []
    var touched: [AgentScreen.Touched] = []
    var mailPreviewAllowed: Bool?

    /// One thought of the agent's and the happenings it attended (the first three its record names).
    struct MindLine: Sendable {
        let thought: Experience
        let attended: [Experience]
    }

    func sourceFailure(_ keys: String...) -> String? {
        let lines = keys.compactMap { failures[$0] }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func healthID(for contact: AgentScreen.Contact, record: AgentConversationRecord?) -> String {
        let id = record?.agent ?? contact.id
        return health[id] == nil ? contact.id : id
    }
}

extension AgentScreen {
    /// Cache identity: absence and failed metadata are distinct stamps. This stamp is never a source-value or liveness verdict.
    static func stamp(_ url: URL) -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return url.lastPathComponent + (errno == ENOENT ? " absent" : " unavailable errno=\(errno)")
        }
        return "\(info.st_ino).\(info.st_size).\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    /// A folder and each entry in it (or `file` inside each entry).
    static func stamps(_ dir: URL, file: String? = nil) throws -> [String] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { names = [] }
        return [stamp(dir)] + names.map { name in
            stamp(file.map { dir.appendingPathComponent(name).appendingPathComponent($0) } ?? dir.appendingPathComponent(name))
        }
    }

    static func readWorld(workspace: WorkspaceOperation, _ dataRoot: URL, now: Date = Date()) async -> AgentWorld {
        world(workspace: workspace, dataRoot, now: now, observing: true, home: false)
    }

    static func observeHome(workspace: WorkspaceOperation, _ dataRoot: URL) {
        _ = world(workspace: workspace, dataRoot, now: Date(), observing: true, home: true)
    }

    /// The face only reads retained parts. Watch registration and all source I/O belong to the owner, outside this read.
    static func retainedWorld(workspace: WorkspaceOperation, _ dataRoot: URL, now: Date) -> AgentWorld {
        world(workspace: workspace, dataRoot, now: now, observing: false, home: true)
    }

    private static func world(workspace: WorkspaceOperation, _ dataRoot: URL, now: Date, observing: Bool, home: Bool) -> AgentWorld {
        let root = dataRoot.standardizedFileURL.path + "\u{0}"
        @Sendable func at(_ path: String) -> URL { dataRoot.appendingPathComponent(path) }
        @Sendable func files(_ dir: URL, file: String? = nil) -> [URL] {
            // Passive watch reach only. Keep the parent even if enumeration fails, so restoration invalidates the checked owner reading.
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return [dir] + names.compactMap { name in
                let child = dir.appendingPathComponent(name)
                guard let file else { return child }
                // Only a folder holds a file of its own; a path under a plain file can never be watched.
                return (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? child.appendingPathComponent(file) : nil
            }
        }
        let memo = AgentMemo.shared
        var world = AgentWorld()
        func part<T>(_ key: String, _ paths: @autoclosure @escaping @Sendable () -> [URL], notifications: [Notification.Name] = [],
                     _ compute: @escaping @Sendable () async throws -> T) -> T? {
            if observing { memo.observe(root + key, paths: paths, notifications: notifications, compute: compute) }
            let kept: (value: Result<T, Error>, current: Bool, at: Date, identity: UUID)? = memo.peek(root + key)
            world.readings[key] = kept?.identity
            if let at = kept?.at { world.oldest = min(world.oldest ?? at, at) }
            if kept?.current != true { world.pending.append(key) }
            if kept == nil { world.unread.append(key) }
            switch kept?.value {
            case .success(let value): return value
            case .failure(let error):
                world.pending.removeAll { $0 == key }
                world.unread.append(key)
                world.failures[key] = key + " unavailable: " + error.localizedDescription + ". Repair this source; its previous value is not this reading."
                return nil
            case nil: return nil
            }
        }

        if let events: [PhonePlaceEvent] = part("phone places", [PhonePlaceHistory.url(dataRoot)], {
            try PhonePlaceHistory.read(dataRoot)
        }) { world.phonePlaces = events }
        if let found: [String: AgentDiscoveryOffer] = part("found", [AgentDiscoveryOffer.url(dataRoot)], {
            try AgentDiscoveryOffer.checkedRead(dataRoot).filter(\.value.open)
        }) { world.found = found }

        typealias People = (records: [AgentConversationRecord], chats: [BridgeChat], answered: [String: Date],
                            handed: Set<String>)
        if let people: People = part("people", [at("agents/conversations.json"), at("chat/sessions.json")]
                + files(at("agents/grok-requests")), notifications: [.nativeAgentChatTranscriptDidChange], {
            let all = try workspace.ports.conversations.records(dataRoot: dataRoot, locked: false)
            let handed = Set(all.compactMap { row -> String? in
                guard row.agent.hasPrefix("bot-run:"), row.shownInline == row.operationID + ":" + row.phase,
                      case .string(let entry)? = row.readInput?["message_id"] else { return nil }
                return entry.uppercased()
            })
            let chats = try bridgeChats(dataRoot: dataRoot)
            let answered = try workspace.ports.conversations.answeredRequests(dataRoot: dataRoot).reduce(into: [String: Date]()) {
                if let message = $1.message { $0[message] = $1.modified }
            }
            return (all, chats, answered, handed)
        }) {
            world.records = people.records; world.chats = people.chats; world.answered = people.answered
            world.handed = people.handed
        }
        @Sendable func bridges() -> URL { InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot) }
        if let people: (AgentContactIdentity, [Contact], [Contact], [String: BridgeChat]) = part("contacts", [at("agents/peers.json"), bridges(),
                bridges().appendingPathComponent("claude-bridge"), bridges().appendingPathComponent("claude-bridge/bridge.json"),
                bridges().appendingPathComponent("claude-bridge/token"), at("chat/messages"), ContactReplyReads.url(dataRoot)],
                notifications: [.nativeAgentChatTranscriptDidChange], {
            let identity = try workspace.ports.conversations.identity(dataRoot: dataRoot)
            let people = contacts(identity: identity)
            let transcripts = try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, archived: [:])
            let threads = try Dictionary(uniqueKeysWithValues: people.compactMap { contact in
                try thread(contact, dataRoot: dataRoot, identity: identity, transcripts: transcripts).map { (contact.id, $0) }
            })
            return (identity, people, contacts(identity: identity, mergeIdentities: false), threads)
        }) {
            (world.identity, world.contacts, world.routes, world.threads) = people
        }
        if let jobs: (jobs: [DelegationReadout], allStoresReadable: Bool) = part("delegations",
                DelegationStatusProjector(configRoot: bridges(), dataRoot: dataRoot).watchedPaths, {
            DelegationStatusProjector(configRoot: bridges(), dataRoot: dataRoot).allJobsWithAvailability(now: Date())
        }) {
            world.jobs = jobs.jobs
            if !jobs.allStoresReadable {
                world.unread.append("delegations")
                world.failures["delegations"] = """
                    Delegation evidence unavailable: inspect the sources from app agent.jobs and repair the unreadable bridge records; retained jobs are only \
                    partial.
                    """
            }
        }
        world.health = part("health", [AgentLocalHealth.url(dataRoot), at("agents/peers.json")],
                notifications: workspace.ports.conversations.healthNotifications, {
            try workspace.ports.conversations.liveHealth(dataRoot: dataRoot)
        }) ?? [:]

        // Parking is drawn from the owner's retained work and the jobs that carry its items.
        if let desk: (state: DeskState?, live: Set<String>, failure: String?) = part("desk", [at("desk/desk_ops.jsonl"),
                at("desk/desk_ops_base.json"), at("agents/jobs.json")], notifications: [HomeFace.jobsChanged], {
            let store = SwiftNativeDeskStore(dataRoot: dataRoot)
            let state: DeskState
            do { state = try await store.liveStateUnlocked() }
            catch {
                return (nil, [], readFailure(error, reason: "desk_unavailable", remedy: Repair.remedy(owner: at("desk").path,
                    nextCall: nil, tap: nil, instruction: ToolFailureError.fileRepairInstruction(at("desk"),
                        shape: """
                            Desk storage failed: \(error.localizedDescription). Inspect desk_ops.jsonl and desk_ops_base.json; recover only retained work \
                            records.
                            """))))
            }
            guard let read = AgentScreen.jobGlances.withLock({ $0 }) else {
                return (nil, [], "Your jobs are not readable in this app yet, so what carries each Desk item is unknown.")
            }
            let live: Set<String>
            do { live = Set(try read(dataRoot).filter(\.working).compactMap(\.desk)) }
            catch {
                return (nil, [], readFailure(error, reason: "jobs_unavailable", remedy: Repair.remedy(owner: at("agents/jobs.json").path,
                    nextCall: nil, tap: nil, instruction: ToolFailureError.fileRepairInstruction(at("agents/jobs.json"),
                        shape: "Your jobs could not be read: \(error.localizedDescription). Repair agents/jobs.json."))))
            }
            return (state, live, nil)
        }) {
            world.desk = desk.state; world.deskFailure = desk.failure
            if let failure = desk.failure { world.failures["desk"] = failure; world.unread.append("desk") }
            if let state = desk.state { world.split = deskSplit(state, live: desk.live, now: now) }
        }

        if let bots: ([BotDefinition], [UUID: ShelfEntry]) = part("bots",
                files(at("bots/definitions")) + [at("bots/shelf-index.json")], {
            let definitions = BotDefinitionStore(dataRoot: dataRoot), shelf = ShelfStore(dataRoot: dataRoot)
            let bots = try definitions.listUnlocked()
            let entries = try (bots.isEmpty ? [] : shelf.latestEntriesUnlocked(botIDs: Set(bots.map(\.id))))
            return (bots, Dictionary(entries.map { ($0.botId, $0) }, uniquingKeysWith: { a, _ in a }))
        }) { (world.bots, world.latest) = bots }

        world.approvals = part("approvals", [at("workflows/approvals/requests.json")]) {
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            let rows = try inbox.pendingUnlocked()
            return rows.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }
                .sorted { ($0.lastRequestedAt ?? $0.createdAt) > ($1.lastRequestedAt ?? $1.createdAt) }
        } ?? []
        // The stem's trial record: one row per part with an open trial or a closed one; when a closed one still shows is the page's to judge.
        world.trials = part("trials", [at("abilities/state.json")]) { try TrialLevers.read(dataRoot: dataRoot) } ?? []
        world.abilityRuns = part("ability runs", [at("abilities/state.json")]) { try AbilityStore(dataRoot: dataRoot).states() } ?? [:]
        // Memory proposals for the owner's review, the Today page's rule, from the shared store only; kept until the memory database changes.
        if let reviews: (count: Int, capped: Bool) = part("reviews",
                [at("memory/memory.sqlite"), at("memory/memory.sqlite-wal")], {
            guard SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot) else { return (0, false) }
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let pending = try await storage.listProposals(status: "pending", limit: 100)
            return (pending.filter { SwiftNativeMemoryV2.awaitsReview(content: $0.content, source: $0.source, metadata: $0.metadata) }.count,
                    pending.count == 100)
        }) { world.reviews = reviews }
        // Asks read the inbox: its change rereads what it took; the record's change retries an inbox that could not load.
        if let asks: [InboxItemRecord] = part("asks", [], notifications: [HomeFace.experiencesChanged, ForPerson.didChange], {
            try await ForPerson.at(dataRoot).inbox().filter { $0.id != $0.related_approval_id && $0.requiresOwnerInput }
        }) { world.asksToOpen = asks; world.asks = asks.count; world.newestAsk = asks.first?.title }
        world.running = part("running helpers", [at("bots/run-queue.json")], notifications: [BotRunQueue.didChange]) {
            try BotRunQueue(dataRoot: dataRoot).activeOrQueuedIDs(locked: false)
        } ?? []
        world.doors = part("elsewhere", [at("chat/messages"), at("trust/policy.json")],
                notifications: [.nativeAgentChatTranscriptDidChange], {
            try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) ? doorLines(dataRoot: dataRoot, now: Date()) : []
        }) ?? []
        // An ability's definition change posts AbilityStore.didChange; its run accounting (abilities/state.json) is not this reading.
        if let senses: SenseReading = part("senses", [at("senses/news/unread.json")]
                + files(at("senses"), file: "state.json") + files(at("tools"), file: "state.json")
                + files(at("skills"), file: "state.json"),
                notifications: [AbilityStore.didChange, SenseNewsBoard.presentationDidChange, SensesHub.didBecomeReady], {
            await sensesReading(workspace: workspace, dataRoot: dataRoot, now: Date())
        }) { world.senses = senses.rows; world.senseFailures = senses.failures }
        guard home else { return world }
        world.profile = part("profile", [at("memory/profile.json")]) {
            try await SwiftNativePersonaEngine.readPersonality(dataRoot: dataRoot)
        }
        world.work = part("work", [at("agents/jobs.json")], notifications: [HomeFace.jobsChanged]) {
            guard let read = jobGlances.withLock({ $0 }) else {
                throw NameFailure("Your jobs are not readable in this app yet; job ownership needs repair.")
            }
            return try read(dataRoot)
        } ?? []
        world.touched = part("touched", [AgentTouched.path(dataRoot)]) { try touched(dataRoot: dataRoot, now: Date()) } ?? []
        world.repairs = part("owed", [], notifications: [HomeFace.experiencesChanged]) {
            try await ExperienceStore.at(dataRoot).projection()
        } ?? []
        // The mind stream and what is owed are readings of the record, so they refresh with it like the owed rows.
        world.thoughts = part("thoughts", [], notifications: [HomeFace.experiencesChanged]) {
            let store = ExperienceStore.at(dataRoot)
            var lines: [AgentWorld.MindLine] = []
            for thought in try await Attention.thoughts(dataRoot: dataRoot).suffix(6).reversed() {
                var attended: [Experience] = []
                for id in thought.thought?.happenings.prefix(3) ?? [] {
                    if let happening = try await store.experience(id) { attended.append(happening) }
                }
                lines.append(.init(thought: thought, attended: attended))
            }
            return lines
        } ?? []
        world.owedToMe = part("owed to me", [], notifications: [HomeFace.experiencesChanged]) {
            try await Attention.owed(dataRoot: dataRoot).sorted { $0.at > $1.at }
        } ?? []
        world.queueEvidence = part("queue evidence", [at("desk/desk_ops.jsonl"), at("desk/desk_ops_base.json"),
            at("workflows/approvals/requests.json"), at("chat/sessions.json"), at("chat/messages"),
            PhonePlaceHistory.url(dataRoot), PhoneSenseHistory.url(dataRoot)],
            notifications: [HomeFace.experiencesChanged, .nativeAgentChatTranscriptDidChange, MacPersonInput.presenceChanged]) {
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveStateUnlocked()
            return (state.generatedTs, try queueContext(dataRoot: dataRoot, now: Date(), ownTurn: false),
                    try await MyQueueReady.conditions(items: state.items, dataRoot: dataRoot))
        }
        world.mailPreviewAllowed = part("mail preview", [at("security/mac_integration_permissions.json")],
            notifications: [MacIntegrationPermissionStore.didChange]) {
            !(try await MacIntegrationPermissionStore(dataRoot: dataRoot).readinessChecked()).operatorReadOff.contains("mail")
        }
        return world
    }

    /// What the app can vouch for, and no more: each part is read again when a source it watches signals a change, and a part that is
    /// not being read has had no such signal since. How long ago it was read is not staleness; said as an age, it made the agent read
    /// everything again to be sure. A source that changes without a signal (a clock passing, a file the part does not watch) is not
    /// covered by this line.
    static func freshness(_ world: AgentWorld) -> String {
        (world.oldest == nil ? "Nothing read yet"
            : "Each part is read again when a source it watches signals a change; none has since these were read"
                + (world.pending.isEmpty ? "" : ", except " + world.pending.joined(separator: ", ") + " (being read now)"))
            + (world.failures.isEmpty ? "" : "\n" + world.failures.keys.sorted().compactMap { world.failures[$0] }.joined(separator: "\n"))
    }

    // MARK: - Since you looked

    /// Compare each stable name's fingerprint to distinguish changes from first appearance or removal.
    /// `waits` and `what` are read from the world on every look, so the saved record keeps only what a comparison needs.
    struct Mark: Codable, Equatable {
        var fp: String
        var line: String
        var new: String = ""
        var gone: String = ""
        var at: Double
        /// Its change needs me: it is told on its own line and never folded into a count.
        var waits = false
        /// What happened, in the line's own word; a change that does not wait is counted by it under its room.
        var what = ""
        private enum CodingKeys: String, CodingKey { case fp, line, new, gone, at }
    }

    struct Seen: Codable {
        var at: Double
        var marks: [String: Mark]
        /// Read failure evidence is never persisted as an observation.
        var problem: String? = nil
        private enum CodingKeys: String, CodingKey { case at, marks }
    }

    /// Full precision, so two updates in one second still differ.
    private static func fp(_ date: Date?) -> String { date.map { String($0.timeIntervalSince1970) } ?? "-" }

    /// Build observations independently of the viewer; exclude the active chat only when reading changes.
    static func worldMarks(workspace: WorkspaceOperation, _ world: AgentWorld, dataRoot: URL, person: String, now: Date,
        currentOnly: Bool = false) throws -> [String: Mark] {
        var marks: [String: Mark] = [:]
        func current(_ parts: String...) -> Bool { !currentOnly || parts.allSatisfy { !world.pending.contains($0) && !world.unread.contains($0) } }
        try withNames(workspace: workspace, dataRoot) { book in
            for contact in world.contacts where current("contacts", "people") {
                let slug = book.slug(id: contact.id, name: contact.name)
                let record = latest(contact, records: world.records)
                let message: String? = if case .string(let id)? = record?.readInput?["message_id"] { id } else { nil }
                let answered = message.flatMap { world.answered[$0] }
                let bare = Contact(id: contact.id, name: contact.name, kind: nil)
                let change = state(bare, record: record, chat: nil, answered: world.answered, now: now).change
                // Already-shown replies are silent.
                let shown = record.map { $0.shownInline == $0.operationID + ":" + $0.phase } ?? false
                let line = shown || change.isEmpty ? "" : slug + " " + change
                // My sending is no change; what a contact says back, or what became of my send, needs me.
                marks[slug] = Mark(fp: [fp(record?.updatedAt), fp(answered), record?.phase ?? "-"].joined(separator: "|"),
                    line: line, at: ([record?.updatedAt, answered].compactMap { $0 }.max() ?? .distantPast).timeIntervalSince1970,
                    waits: true, what: change)
                for id in Set([contact.id] + contact.agents) {
                    if let health = world.health[id], health.current, current("health") {
                        marks["health:" + id] = Mark(fp: health.status + ":" + health.detail,
                            line: health.problem.map { slug + ": " + $0 } ?? "", at: health.checkedAt.timeIntervalSince1970,
                            waits: true, what: health.status)
                    }
                }
                // A chat the agent already answered is not news: the agent was there.
                for chat in world.chats where !chat.answered && (chat.who == contact.id || chat.who == contact.name.lowercased()) {
                    guard let heard = chat.heard else { continue }
                    marks["chat:" + chat.id] = Mark(fp: fp(heard), line: slug + " wrote", at: heard.timeIntervalSince1970, waits: true, what: "wrote")
                }
            }
            for bot in world.bots where current("bots", "running helpers", "people") {
                let slug = book.slug(id: "bot:" + bot.id.uuidString, name: bot.name)
                let entry = world.latest[bot.id], running = world.running.contains(bot.id)
                // A helper that answered my ask, failed, or waits on the person needs me; a run or a stop is counted.
                var what = "ran", detail = "", waits = false
                if running { what = "running" }
                else if let entry, world.handed.contains(entry.id.uuidString) { what = "" }
                else if let entry {
                    switch entry.runtimeStatus {
                    case .completed:
                        (what, waits, detail) = (entry.asked == true ? "answered" : "ran", entry.asked == true, ": " + clip(entry.headline, 36))
                    case .failed, .interrupted: (what, waits) = ("failed", true)
                    case .stopped: what = "stopped"
                    case .waitingForApproval, .waitingOnPerson: (what, waits) = ("waiting on " + person, true)
                    }
                }
                let line = what.isEmpty ? "" : slug + " " + what + detail
                marks[slug] = Mark(fp: [entry?.id.uuidString ?? "-", entry?.runtimeStatus.rawValue ?? "-",
                                      entry?.statusDetail ?? "-", entry?.approvalID ?? "-", running ? "running" : "idle"].joined(separator: "|"), line: line,
                                   at: (running ? now : entry?.runAt ?? .distantPast).timeIntervalSince1970, waits: waits, what: what)
            }
        }
        if let desk = world.desk, current("desk") {
            for item in desk.items where item.parent == nil || OwnerAttentionPolicy.waitsOnOwner(item) {
                let name = "desk." + item.alias
                let waits = OwnerAttentionPolicy.waitsOnOwner(item)
                let label = waits ? "waiting on " + person : item.spokenStatus
                let at = (date(item.updatedAt) ?? now).timeIntervalSince1970
                // What I do by my own hand I already know, so it is seen as it is made: my queue steps are filed by me and closed by my own
                // work. A step the person closed from the Desk is theirs, and a wait on the person is always told.
                if !waits, item.origin == .agent, item.project == MyQueue.project, item.summary != DeskQuickAction.deskCloseOutcome {
                    marks[name] = Mark(fp: label, line: "", at: at)
                    continue
                }
                marks[name] = Mark(fp: label, line: name + " → " + label, new: name + " new: " + clip(item.title, 36),
                                   gone: name + " closed", at: at, waits: waits, what: label)
            }
        }
        for approval in world.approvals where current("approvals") {
            marks["approval:" + approval.id] = Mark(fp: "pending", line: "",
                new: "approval: " + clip(approval.title, 40),
                at: (date(approval.lastRequestedAt ?? approval.createdAt) ?? now).timeIntervalSince1970, waits: true)
        }
        let placeClock = DateFormatter()
        placeClock.locale = Locale(identifier: "en_US_POSIX")
        placeClock.dateFormat = "HH:mm"
        for event in world.phonePlaces where current("phone places") {
            let prefix = "Phone " + event.transition.rawValue + " "
            let when = " (" + placeClock.string(from: event.timestamp) + ", " + age(now.timeIntervalSince(event.timestamp)) + " ago)"
            // Keep the observation time inside the glance's 44-character line budget.
            let place = clip(String(reflecting: event.name), max(1, 44 - prefix.count - when.count))
            marks["phone-place:" + event.id] = Mark(fp: event.id, line: prefix + place + when, at: event.timestamp.timeIntervalSince1970,
                what: event.transition.rawValue)
        }
        return marks
    }

    /// The room a mark's change is counted under and read in, from its name. A plain name is a contact's or a helper's; the name book
    /// knows which.
    static func room(_ name: String, book: NameBook) -> String {
        if name.hasPrefix("desk.") { return "desk" }
        if name.hasPrefix("approval:") { return "approvals" }
        if name.hasPrefix("phone-place:") { return "phone" }
        if name.hasPrefix("home:tab:") { return "browser tabs" }
        if name.hasPrefix("home:") { return String(name.dropFirst(5)) }
        if name.hasPrefix("chat:") || name.hasPrefix("health:") { return "people" }
        return book.slugs[name]?.id.hasPrefix("bot:") == true ? "helpers" : "people"
    }

    /// What changed since the saved look: what waits on me first, newest first within each. The chat the agent is in (`excluding`) is never news.
    struct Change {
        var names: Set<String>
        var at: Double
        var line: String
        var waits: Bool
        var what: String
    }

    static func changes(since seen: Seen?, now marks: [String: Mark], excluding scope: String?) -> [Change] {
        guard let seen, seen.problem == nil else { return [] }
        var found: [String: Change] = [:]
        func add(_ name: String, _ line: String, _ at: Double, waits: Bool, what: String) {
            guard !line.isEmpty else { return }
            found[line, default: Change(names: [], at: at, line: line, waits: waits, what: what)].names.insert(name)
        }
        let live = scope.map { "chat:" + $0 }
        for (name, mark) in marks where name != live {
            guard let old = seen.marks[name] else {
                add(name, mark.new.isEmpty ? mark.line : mark.new, mark.at, waits: mark.waits, what: mark.new.isEmpty ? mark.what : "new")
                continue
            }
            if old.fp != mark.fp { add(name, mark.line, mark.at, waits: mark.waits, what: mark.what) }
        }
        for (name, old) in seen.marks where marks[name] == nil { add(name, old.gone, seen.at, waits: false, what: "closed") }
        return found.values.sorted { ($0.waits ? 1 : 0, $0.at, $0.line) > ($1.waits ? 1 : 0, $1.at, $1.line) }
    }

    /// One telling of what changed, for Home and the glance alike. Each change that waits on me is its own line, up to `limit`; more than
    /// that are one line saying how many and, when they fit, the rooms (each an item) to read them in, and stay news until a look shows them.
    /// Everything else is one line per room, counted by what happened, or by its total when those counts do not fit, or the change's own line
    /// when the room has one. `names` are the names of every change these lines tell.
    static func tell(_ changed: [Change], limit: Int, width: Int, book: NameBook) -> (lines: [String], names: Set<String>) {
        func roomOf(_ change: Change) -> String? { change.names.min().map { room($0, book: book) } }
        let waiting = changed.filter(\.waits), shown = waiting.prefix(limit)
        var lines = shown.map { clip($0.line, width) }
        var told = Set(shown.flatMap(\.names))
        let more = waiting.dropFirst(limit)
        if !more.isEmpty {
            var places: [String] = []
            for name in more.compactMap(roomOf) where !places.contains(name) { places.append(name) }
            let count = "+\(more.count) more need me", read = count + ": read " + places.joined(separator: ", ")
            lines.append(read.count <= width ? read : count)
        }
        var rooms: [(name: String, changes: [Change])] = []
        for change in changed where !change.waits {
            guard let name = roomOf(change) else { continue }
            if let index = rooms.firstIndex(where: { $0.name == name }) { rooms[index].changes.append(change) }
            else { rooms.append((name, [change])) }
            told.formUnion(change.names)
        }
        for room in rooms {
            if room.changes.count == 1, let only = room.changes.first { lines.append(clip(only.line, width)); continue }
            var counts: [(what: String, count: Int)] = []
            for change in room.changes {
                if let index = counts.firstIndex(where: { $0.what == change.what }) { counts[index].count += 1 }
                else { counts.append((change.what, 1)) }
            }
            // A count is never cut: a room whose counts do not fit is told by its total, and she reads the rest in the room.
            let counted = room.name + ": " + counts.map { "\($0.count) \($0.what)" }.joined(separator: ", ")
            var line = counted.count <= width ? counted : room.name + ": \(room.changes.count) changes"
            // A count says how many; where there is room, the newest one says what kind of thing arrived. Only this example is ever cut.
            if let newest = room.changes.first, width - line.count > 24 { line += " · newest: " + clip(newest.line, width - line.count - 11) }
            lines.append(line)
        }
        return (lines, told)
    }

    /// Missing source evidence cannot close Desk work or announce a helper's run as ended.
    static func preserveUnreadMarks(_ marks: inout [String: Mark], seen: Seen?, world: AgentWorld,
                                    workspace: WorkspaceOperation, dataRoot: URL) throws {
        guard !world.unread.isEmpty, let seen else { return }
        let helpers = world.unread.contains("running helpers")
            ? try withNames(workspace: workspace, dataRoot) { book in
                Set(world.bots.map { book.slug(id: "bot:" + $0.id.uuidString, name: $0.name) })
            } : []
        for (name, mark) in seen.marks where helpers.contains(name)
            || marks[name] == nil && world.unread.contains("desk") && name.hasPrefix("desk.") { marks[name] = mark }
    }

    private static func seenURL(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("her_screen/last_seen.json") }

    private static func readSeen(_ url: URL) -> Seen? {
        do {
            let seen = try JSONDecoder().decode(Seen.self, from: Data(contentsOf: url))
            let range = Date.distantPast.timeIntervalSince1970...Date.distantFuture.timeIntervalSince1970
            guard range.contains(seen.at), seen.marks.values.allSatisfy({ range.contains($0.at) }) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            return seen
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch {
            return Seen(at: 0, marks: [:], problem: "Last look unavailable: " + error.localizedDescription
                + ". Saved last_seen.json is preserved; repair it before acknowledging observations.")
        }
    }

    static func lastSeen(_ dataRoot: URL) async -> Seen? {
        let url = seenURL(dataRoot)
        return await AgentMemo.shared.value(dataRoot.standardizedFileURL.path + "\u{0}seen", stamp: [stamp(url)]) { readSeen(url) }
    }

    /// What the agent changes on its Desk by its own hand it already knows: the item is recorded as seen in the state it now has, and the
    /// time of the last look stays where it was, so Home does not tell the change back as news. A wait on the person is still told, and
    /// a step under another item was never told by itself.
    package static func sawOwnDeskChange(_ handle: String, dataRoot: URL) async {
        guard let seen = readSeen(seenURL(dataRoot)), seen.problem == nil,
              let item = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items.first(where: { $0.handle == handle }),
              item.parent == nil, !OwnerAttentionPolicy.waitsOnOwner(item) else { return }
        let name = "desk." + item.alias
        markSeen(dataRoot, marks: [name: Mark(fp: item.spokenStatus, line: "", at: seen.at)], only: [name],
                 now: Date(timeIntervalSince1970: seen.at))
    }

    /// A look merges only identities represented in its output, retaining hidden and capped records at their previous observation. One writer at a time: read,
    /// merge and write happen under one lock.
    static func markSeen(_ dataRoot: URL, marks: [String: Mark], only names: Set<String>? = nil, now: Date = Date()) {
        let url = seenURL(dataRoot)
        AgentMemo.shared.seenLock.withLock {
            let previous = readSeen(url)
            guard previous?.problem == nil else { return }
            var seen: Seen
            if let names {
                var saved = previous ?? Seen(at: now.timeIntervalSince1970, marks: [:])
                for name in names { saved.marks[name] = marks[name] }
                // The time of the last look never moves back: a write that carries an older reading leaves a newer look standing.
                saved.at = max(saved.at, now.timeIntervalSince1970)
                seen = saved
            } else { seen = Seen(at: now.timeIntervalSince1970, marks: marks) }
            do { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(seen), to: url) }
            catch {
                RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run, operation: "home.seen", owner: url.path,
                    words: "Home was shown, but its seen record could not be saved: \(error.localizedDescription). The previous record is preserved.",
                    tap: ToolFailureError.fileRepairInstruction(url,
                        shape: "Preserve the last_seen object and restore write access. Read home after repair; do not repeat any work."))
            }
        }
    }

    /// A room's look: the names that room shows (a person's room includes their bridge chats).
    static func markRoomSeen(workspace: WorkspaceOperation, _ location: AgentWorkspaceLocation, dataRoot: URL, scope: String,
                             observation: (world: AgentWorld, at: Date, health: Set<String>)? = nil) async {
        do {
            if observation == nil, case .record("agent_read", let input, _) = location,
               case .string(let agent)? = input["agent"] {
                guard agent.lowercased().hasPrefix("bot:"),
                      UUID(uuidString: String(agent.dropFirst(4))) != nil else { return }
            }
            let now = observation?.at ?? Date()
            let world: AgentWorld
            if let observation { world = observation.world }
            else { world = await readWorld(workspace: workspace, dataRoot, now: now) }
            guard world.failures.isEmpty else { return }
            let marks = try worldMarks(workspace: workspace, world, dataRoot: dataRoot, person: names(dataRoot).person, now: now, currentOnly: true)
            var names: Set<String> = []
            switch location {
            case .record("agent_read", let input, _):
                guard case .string(let agent)? = input["agent"] else { return }
                let id = agent.lowercased().hasPrefix("bot:") ? "bot:" + String(agent.dropFirst(4)).uppercased() : agent
                if let slug = try withNames(workspace: workspace, dataRoot, { book in book.slugs.first { $0.value.id.caseInsensitiveCompare(
                    id) == .orderedSame }?.key }) {
                    names.insert(slug)
                }
                if let contact = world.contacts.first(where: { $0.id.caseInsensitiveCompare(agent) == .orderedSame }) {
                    names.formUnion(world.chats.filter { $0.who == contact.id || $0.who == contact.name.lowercased() }.map { "chat:" + $0.id })
                }
            case .record("desk_read", let input, _):
                guard case .string(let handle)? = input["handle"],
                      let alias = world.desk?.items.first(where: { $0.handle == handle })?.alias else { return }
                names.insert("desk." + alias)
            case .record("chat_conversations", let input, _):
                guard case .string(let id)? = input["conversation_session_id"] else { return }
                names.insert("chat:" + id)
            case .area("ongoing"): names = Set(marks.keys.filter { $0.hasPrefix("desk.") })
            case .area("helpers"):
                names = try withNames(workspace: workspace, dataRoot) { book in Set(world.bots.map { book.slug(id: "bot:" + $0.id.uuidString,
                    name: $0.name) }) }
            case .people:
                names = try withNames(workspace: workspace, dataRoot) { book in Set(world.contacts.map { book.slug(id: $0.id, name: $0.name) }) }
            default: return
            }
            names.formUnion((observation?.health ?? []).map { "health:" + $0 })
            markSeen(dataRoot, marks: marks, only: names.intersection(marks.keys), now: now)
        } catch { nativeLog("Workspace observation was not acknowledged: %@", nameFailure(error)) }
    }

    // MARK: - The glance line

    /// Pin Home changes to the turn, but read part owners at assembly; never mark seen or include the user's screen/activity data.
    package static func glance(workspace: WorkspaceOperation, dataRoot: URL, scope: String?, turn: Date?, message: String) async -> PreparedWorkspaceGlance {
        async let parts: PreparedWorkspaceGlance = {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = await AgentWorkspacePorts.parts(for: message, dataRoot: dataRoot, turn: workspace.turn)
            TurnTraceBus.fireFromContext(kind: "context.glance.read", payload: .object([
                "read": .string("parts"), "elapsedMs": .int(Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))]), turn: workspace.turn)
            return value
        }()
        let homeStart = DispatchTime.now().uptimeNanoseconds
        let home = await homeGlance(workspace: workspace, dataRoot: dataRoot, scope: scope, turn: turn)
        TurnTraceBus.fireFromContext(kind: "context.glance.read", payload: .object([
            "read": .string("home"), "elapsedMs": .int(Int64((DispatchTime.now().uptimeNanoseconds - homeStart) / 1_000_000))]), turn: workspace.turn)
        let prepared = await parts
        return PreparedWorkspaceGlance([home, prepared.text].compactMap { $0 }.joined(separator: "\n"), delivered: prepared.delivered)
    }

    private static func homeGlance(workspace: WorkspaceOperation, dataRoot: URL, scope: String?, turn: Date?) async -> String? {
        let key = "home\u{0}" + dataRoot.standardizedFileURL.path + "\u{0}" + (scope ?? "-") + "\u{0}" + (turn.map { String($0.timeIntervalSince1970) } ?? "-")
        if turn != nil, let kept = AgentMemo.shared.glance(key) { return kept }
        let now = turn ?? Date()
        let text = await renderGlance(workspace: workspace, dataRoot: dataRoot, scope: scope, now: now)
        if turn != nil { AgentMemo.shared.keepGlance(key, text) }
        return text
    }

    static func renderGlance(workspace: WorkspaceOperation, dataRoot: URL, scope: String?, now: Date) async -> String? {
        do {
            let world = await readWorld(workspace: workspace, dataRoot, now: now)
            if !world.failures.isEmpty { return "Home glance unavailable. " + freshness(world) }
            let person = names(dataRoot).person
            let seen = await lastSeen(dataRoot)
            if let problem = seen?.problem { return "Home glance — " + problem }
            // Home's own names (presence, Chrome, badges, tabs) are not the glance's to speak.
            var marks = try worldMarks(workspace: workspace, world, dataRoot: dataRoot, person: person, now: now)
            for (name, mark) in seen?.marks ?? [:] where name.hasPrefix("home:") { marks[name] = mark }
            // Unread parts are named and keep their last-seen state; only desk says "gone", while a helper's running state belongs to its live part.
            try preserveUnreadMarks(&marks, seen: seen, world: world, workspace: workspace, dataRoot: dataRoot)
            let changed = changes(since: seen, now: marks, excluding: scope)
            // The person's to decide first, then the agent's: the same split as home.
            var waits: [String] = [], mine: [String] = []
            if let first = world.approvals.first {
                waits.append("approval \"" + clip(first.title, 28) + "\""
                    + (world.approvals.count > 1 ? " +\(world.approvals.count - 1)" : ""))
            }
            if let desk = world.desk {
                let waiting = desk.items.filter(OwnerAttentionPolicy.waitsOnOwner).sorted { $0.updatedAt > $1.updatedAt }
                waits += waiting.prefix(2).map { "desk." + $0.alias + " — " + clip($0.title, 28) }
                    + (waiting.count > 2 ? ["+\(waiting.count - 2) desk"] : [])
            }
            if world.asks > 0 { waits.append("inbox \(world.asks)" + (world.newestAsk.map { " — " + clip($0, 44) } ?? "")) }
            if world.reviews.count > 0 { mine.append("memories \(world.reviews.count)\(world.reviews.capped ? "+" : "")") }
            try withNames(workspace: workspace, dataRoot) { book in
                for contact in world.contacts where state(contact, record: latest(contact, records: world.records),
                                                          chat: nil, answered: world.answered, now: now).asks {
                    mine.append(book.slug(id: contact.id, name: contact.name) + " asks")
                }
            }
            let words = ["people": "people", "desk": "desk", "bots": "helpers", "approvals": "approvals",
                         "reviews": "memories to review"]
            let unread = world.unread.map { words[$0] ?? $0 }
            guard !changed.isEmpty || !waits.isEmpty || !mine.isEmpty || !unread.isEmpty else { return nil }
            var parts = ["""
                Home glance — snapshot as of \(now.formatted(.iso8601)). \(freshness(world)). Desk, inbox, approvals, exchanges, helper \
                status, phone-place records and reviews; no live calendar, reminders, mail, front app, full Doctor check or complete activity log.
                """]
            if let seen, !changed.isEmpty {
                let book = try withNames(workspace: workspace, dataRoot) { $0 }
                let shown = tell(changed, limit: 3, width: 44, book: book).lines
                parts.append("Since you looked (\(age(now.timeIntervalSince1970 - seen.at))): " + shown.joined(separator: " · ")
                    + (shown.last?.hasSuffix("…") == true ? "" : "."))
            }
            if !waits.isEmpty { parts.append(person + " waits on: " + waits.joined(separator: ", ") + ".") }
            if !mine.isEmpty { parts.append("Mine: " + mine.joined(separator: ", ") + ".") }
            if !unread.isEmpty { parts.append("Not read yet: " + unread.joined(separator: ", ") + ", so there may be news there.") }
            return parts.joined(separator: " ") + " (app {} for home)"
        } catch { return nameFailure(error) }
    }
}
