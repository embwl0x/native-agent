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
// Blueprint: | `HomeFace.swift` | Home's shared native face from retained world parts; source-fed lifetime, cached reads and section gaps |

package enum HomeFace {
    static let experiencesChanged = Notification.Name("NativeAgent.homeExperiencesChanged")
    package static let jobsChanged = Notification.Name("NativeAgent.homeJobsChanged")
    @MainActor private static var readers: [String: @MainActor () async -> PartFaceSnapshot?] = [:]

    /// Read the page owner, rather than keeping a second face for the workspace door.
    @MainActor package static func bind(dataRoot: URL, read: @escaping @MainActor () async -> PartFaceSnapshot?) {
        readers[dataRoot.standardizedFileURL.path] = read
    }

    @MainActor static func door(dataRoot: URL) async throws -> PartFace {
        guard let read = readers[dataRoot.standardizedFileURL.path], let snapshot = await read() else {
            throw PartCallError(code: "home_unattached", message: "Home's page owner has not attached. Open NativeAgent before reading Home.")
        }
        guard snapshot.status == .ready, let face = snapshot.face else {
            throw snapshot.error ?? PartCallError(code: "home_unavailable", message: "Home returned no readable face.")
        }
        return face
    }

    private static func observe(center: NotificationCenter, names: [Notification.Name], changed: @escaping @Sendable () -> Void)
        -> [any NSObjectProtocol] {
        names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in changed() }
        }
    }

    @MainActor package final class Owner {
        private let workspace: WorkspaceOperation
        private let dataRoot: URL
        private var observers: [(any NSObjectProtocol)] = []
        private var sources: Task<Void, Never>?

        package init(workspace: WorkspaceOperation, dataRoot: URL, changed: @escaping @MainActor @Sendable () async -> Void) {
            self.workspace = workspace.preview()
            self.dataRoot = dataRoot
            AgentMemo.shared.holdWorld(dataRoot)
            observers = HomeFace.observe(center: .default,
                names: [AgentWorkspaceScreenPreview.didChange, BrowserConnectionMirror.didChange, SurfaceLayoutLive.didChange]) {
                Task { @MainActor in await changed() }
            }
            AgentScreen.observeHome(workspace: workspace.preview(), dataRoot)
            sources = Task {
                for await _ in await ExperienceStore.at(dataRoot).changes() {
                    guard !Task.isCancelled else { return }
                    NotificationCenter.default.post(name: HomeFace.experiencesChanged, object: nil)
                }
            }
        }

        isolated deinit {
            sources?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
            AgentMemo.shared.releaseWorld(dataRoot)
        }

        package func read(layout: SurfaceLayoutAvailability) async -> (face: PartFace, epoch: UInt64) {
            let now = Date()
            let world = AgentScreen.retainedWorld(workspace: workspace, dataRoot, now: now)
            return (HomeFace.face(world, dataRoot: dataRoot, layout: layout, now: now),
                    UInt64(now.timeIntervalSince1970 * 1000))
        }

    }

    private static func face(_ world: AgentWorld, dataRoot: URL, layout: SurfaceLayoutAvailability, now: Date) -> PartFace {
        let person = world.profile?.userName.flatMap(AgentScreen.nonEmpty).map { AgentScreen.clip($0, 40) } ?? "the person"
        var rows: [String: [PartFace.Row]] = [:]
        let sources: [String: [String]] = [
            "notable": ["profile", "mail preview"], "changed": [], "waits": ["desk", "approvals", "asks", "owed"],
            "queue": ["desk", "queue evidence", "arrivals", "reviews", "people", "contacts", "owed"],
            "working": ["work"], "open": [], "people": ["contacts", "people", "health", "delegations", "found"],
            "helpers": ["bots", "running helpers"], "senses": ["senses"],
            "elsewhere": ["elsewhere", "contacts"], "places": ["desk"], "mac": ["touched"],
        ]
        if world.mailPreviewAllowed == true,
           let preview = AgentReadBadges.shared.latest("mail.previews", dataRoot: dataRoot), !preview.words.isEmpty {
            rows["notable"] = [.init(id: "mail.previews", title: "Last Mail read", detail: preview.words,
                at: clock(preview.at), open: "page:home/mail")]
        }
        rows["changed"] = [.init(id: "changed.scope", title: "Changes since the last look are read on each door", tone: .quiet)]
        rows["waits"] = waits(world, person: person)
        rows["queue"] = queue(world, person: person, now: now)
        rows["working"] = world.work.filter(\.working).prefix(10).map { job in
            .init(id: "job:" + job.id, title: AgentScreen.clip(AgentScreen.firstLine(job.brief), 100), detail: AgentScreen.clip(job.name, 60),
                value: job.state, at: clock(job.at), tone: .live,
                actions: [.init(id: "agent.read", label: "Read job")])
        }
        rows["open"] = [.init(id: "windows", title: "This conversation's open places",
            detail: "Windows and browser tabs stay with the conversation that owns them.", open: "page:home/windows")]
        rows["people"] = people(world, now: now)
        rows["helpers"] = world.bots.sorted {
            (world.running.contains($0.id) ? 1 : 0, world.latest[$0.id]?.runAt ?? .distantPast)
                > (world.running.contains($1.id) ? 1 : 0, world.latest[$1.id]?.runAt ?? .distantPast)
        }.map { bot in
            let entry = world.latest[bot.id], running = world.running.contains(bot.id)
            let status: String
            let tone: PartFace.Tone
            if world.unread.contains("running helpers") { status = "Run queue not read"; tone = .attention }
            else if running { status = "Running or queued"; tone = .attention }
            else if let entry {
                status = entry.runtimeStatus.rawValue
                tone = entry.runtimeStatus == .failed || entry.runtimeStatus == .interrupted ? .failed : .plain
            } else { status = "Never run"; tone = .quiet }
            return .init(id: "bot:" + bot.id.uuidString, title: AgentScreen.clip(bot.name, 60),
                detail: entry.map { AgentScreen.clip($0.headline, 120) } ?? StandingBotSchedule.words(bot.cadence),
                value: status + (bot.paused ? " · paused" : ""), at: running ? nil : entry.map { clock($0.runAt) }, tone: tone,
                open: "page:home/agent/bot:" + bot.id.uuidString)
        }
        rows["senses"] = world.senses.enumerated().map { index, words in
            .init(id: "sense:" + String(index), title: words, open: "page:home/senses")
        }
        rows["senses", default: []] += world.senseFailures.enumerated().map { index, failure in
            .init(id: "sense:failed:" + String(index), title: "Sense source unavailable", detail: failure, tone: .failed, open: "page:home/senses")
        }
        var doors: Set<String> = []
        let peers = Dictionary(world.routes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        rows["elsewhere"] = world.doors.filter { doors.insert($0.door == "bridge" ? $0.session : $0.door).inserted }.prefix(5).map { line in
            .init(id: "elsewhere:" + line.session, title: line.door, detail: AgentScreen.who(line, person: person, peers: peers),
                at: clock(line.at), open: "chat:" + line.session)
        }
        rows["places"] = layout.contentNames("places", profile: SurfaceLayoutStore.profile).map(AppDoorNames.resolve).map { place in
            let badge = AgentReadBadges.shared.latest(place, dataRoot: dataRoot)
            let detail: String?
            if place == "browser" {
                detail = BrowserConnectionMirror.connected.map { $0 ? "Chrome connected" : "Chrome not connected" } ?? "Chrome connection unobserved"
            } else if place == "desk", let state = world.desk {
                detail = "\(world.split.active.count) active · \(world.split.parked.count) parked · \(world.split.waiting.count) waiting · "
                    + state.boardCountSummary
            } else { detail = badge?.words }
            return .init(id: place, title: place.capitalized, detail: detail, at: badge.map { clock($0.at) }, open: "page:home/" + place)
        }
        rows["mac"] = world.touched.map { item in
            .init(id: "mac:" + item.app + ":" + (item.kind ?? ""), title: item.app, detail: item.kind, value: item.readout,
                at: clock(Date(timeIntervalSince1970: item.at)), open: "page:home/mac")
        }
        let titles = ["notable": "Notable", "changed": "Changed", "waits": person.capitalized + " waits", "queue": "My queue",
            "working": "Working", "open": "Open", "people": "People", "helpers": "Helpers", "senses": "My senses",
            "elsewhere": "Elsewhere", "places": "Places", "mac": "Mac"]
        let coverage = ["notable": "Prior Mail previews, not a current inbox scan.", "changed": "The agent's door compares tracked records per look.",
            "waits": "Desk, approvals, inbox asks and repairs; no fresh calendar, reminders or Mail read.",
            "queue": "Queued Desk steps, reviews, arrivals, handoffs and repairs; not all autonomous activity.",
            "working": "Jobs and lines at work; agent.jobs lists them all.", "open": "Retained places by conversation; not Mac windows.",
            "people": "Contacts, exchanges, discovery offers and local health; no full Doctor check.",
            "helpers": "Definitions, latest shelf results and run queue; not full run history.", "senses": "Retained abilities, senses and watches.",
            "elsewhere": "Latest speakers across recent transcripts; not a complete activity log.",
            "places": "Navigation, Chrome connection and prior read badges; browser tabs stay with their conversation.",
            "mac": "Recorded reads/actions retained at their last write; no fresh window content."]
        let sections = layout.contentNames("home", profile: SurfaceLayoutStore.profile).map { name -> PartFace.Section in
            var body = rows[name] ?? []
            for key in sources[name] ?? [] {
                if let failure = world.failures[key] {
                    body.append(.init(id: name + ":failed:" + key, title: key + " unavailable", detail: failure, tone: .failed))
                } else if world.unread.contains(key) {
                    // A part re-reading keeps its last value; only a part never read yet is a gap on the page.
                    body.append(.init(id: name + ":unread:" + key, title: key + " not read yet",
                        detail: "This section is incomplete until its first reading lands.", tone: .attention))
                }
            }
            if name == "notable", let failure = layout.failure {
                body.append(.init(id: "layout.failed", title: "Layout unavailable", detail: failure.localizedDescription, tone: .failed))
            }
            if body.isEmpty { body = [.init(id: name + ":empty", title: "No retained rows", tone: .quiet)] }
            return .init(id: name, title: titles[name], style: .list, footer: coverage[name], rows: body)
        }
        return .init(title: world.profile.map { AgentScreen.clip($0.name, 40) }, line: "Where I am, what waits and what is within reach.", sections: sections)
    }

    static func clock(_ date: Date) -> String { date.formatted(.iso8601) }
}
