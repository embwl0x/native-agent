import AuthoredCapabilities
import ChatTurnRuntime
import CognitiveSubstrate
import Experiences
import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `NativeCognitionRuntime+Attention.swift` | Serial committed intake, checked weighing, retained claims and sleep |

/// Where a thought opens: the agent's mind stream, installed at launch above cognition.
public protocol AttentionStream: Sendable {
    /// Open one thought attending these, returning when it settles. A thought that cannot open leaves what it carried owed.
    func think(_ attended: Attended) async
    /// Return owed happenings to the conversation they belong to.
    func returnTo(_ session: String, _ happenings: [Experience]) async
    func rest(_ attended: Attended) async
}

/// What one thought attends: the node whose drive ignited it, the happenings, and what the agent felt as it weighed them.
public struct Attended: Sendable {
    public let node: AttentionNode?
    public let drive: Double?
    public let happenings: [Experience]
    /// Persisted drive whose full happening provenance is no longer in the retained record.
    public let earlierDrive: Attention.EarlierDrive?
    public let readings: JSONValue?
    /// `awake`, `waking` for what waited through sleep, or `night` for the sleep thought's continuation.
    public let mode: String
    /// A reading that failed while the thought was gathered, said in the thought rather than hidden.
    public let unread: String?
    /// The night's reading of the agent's parts when the thought is the sleep thought's continuation.
    public let night: JSONValue?

    public init(node: AttentionNode?, drive: Double?, happenings: [Experience], readings: JSONValue?, mode: String, unread: String? = nil,
                night: JSONValue? = nil, earlierDrive: Attention.EarlierDrive? = nil) {
        self.node = node; self.drive = drive; self.happenings = happenings; self.readings = readings; self.mode = mode; self.unread = unread
        self.night = night; self.earlierDrive = earlierDrive
    }

    /// The record retains earlier ids even when their happening bodies are no longer available.
    public var happeningIDs: [String] {
        var ids = happenings.map(\.id)
        for id in earlierDrive?.happenings ?? [] where !ids.contains(id) { ids.append(id) }
        return ids
    }
}

struct AttentionState {
    var stream: (any AttentionStream)?
    /// Admission opened: owed happenings have been attended and what waited has been weighed once.
    var opened = false
    var opening = false
    var openingHappenings: [String: Experience] = [:]
    /// From the sleep moment until the night settles, or something owed or the person arrives. The world waits unweighed.
    var asleep = false
    /// The runtime owns admission across suspensions, not just the actor's synchronous slices.
    var admitted = false
    var released = ScopedWaiter()
    /// An unfinished landing/record/claim stays this batch's work; a later admission finishes it before landing anything else.
    var batch: AttentionBatch?
    /// Failed thoughts return their original payload as well as their drive. These are unsettled returns, not a second field snapshot.
    var returns: [AttentionReturn] = []
}

struct AttentionBatch {
    let at: Date
    let mode: String
    let stream: any AttentionStream
    var crossings: [AttentionCrossing]
}

struct AttentionCrossing {
    let node: AttentionNode
    /// The final drive at the batch's clock reading, before any record await.
    let drive: Double
    let readings: JSONValue?
    let once = "attention.ignite:" + UUID().uuidString
    var claimed: Attended?
}

struct AttentionReturn {
    let attended: Attended
    let at: Date
    let once = "attention.restore:" + UUID().uuidString
    var restored = false
}

extension NativeCognitionRuntime: AttentionIntake {
    /// The mind stream opens admission: what is owed is attended, nodes already at one ignite, and what waited is weighed, once.
    public func installStream(_ stream: any AttentionStream) async {
        attention.stream = stream
        guard !attention.opened, !attention.opening else { return }
        attention.opening = true
        defer { attention.opening = false }
        var owed: [Experience]
        do { owed = try await Attention.owed(dataRoot: dataRoot) }
        catch { attentionFailed("opening", subject: "owed", error: error); return }
        attentionSucceeded("opening", subject: "owed")
        let read = Set(owed.map(\.id))
        owed += attention.openingHappenings.values.filter { !read.contains($0.id) }
        attention.openingHappenings.removeAll()
        attention.opened = true
        open(owed)
        await igniteReady(mode: "awake")
        await weighWaiting(mode: "awake")
    }

    public func took(_ experience: Experience) async {
        guard let happening = experience.happening else { return }
        if happening.signal == "person.away", happening.door == "presence" { await senseHour(experience) }
        // A world line releases the agent's `on_news` steps it touches: those are moments the agent set, owed even through sleep or before opening.
        if happening.kind == .world { await releaseNewsIntentions(touchedBy: happening.words, watch: happening.door) }
        if !attention.opened {
            if happening.owed { attention.openingHappenings[experience.id] = experience }
            if !attention.opening, let stream = attention.stream { await installStream(stream) }
            return
        }
        if happening.owed {
            if attention.asleep { await woke("something owed arrived") }
            open([experience])
            return
        }
        if attention.asleep {
            // The person's arrival wakes the agent; everything else nobody asked about waits unweighed.
            if happening.signal == "person.here" { await woke("the person arrived") }
            return
        }
        await weigh([experience], mode: "awake")
    }

    public func arrived() async {
        if attention.asleep { await woke("a message arrived") }
    }

    /// Owed happenings open their thought at once: returns in the conversation they belong to, the rest in the agent's mind stream.
    func open(_ owed: [Experience]) {
        guard let stream = attention.stream else { return }
        var routes: [String: [Experience]] = [:]
        var mine: [Experience] = []
        for experience in owed {
            if experience.happening?.subject == "night", experience.happening?.door == "sense:night" {
                let attended = Attended(node: nil, drive: nil, happenings: [experience], readings: nil, mode: "night")
                Task.detached { await stream.rest(attended) }
                continue
            }
            // Work returning to the agent's own stream is a thought there.
            if let route = experience.happening?.route, route != Attention.stream { routes[route, default: []].append(experience) }
            else { mine.append(experience) }
        }
        for (session, happenings) in routes { Task.detached { await stream.returnTo(session, happenings) } }
        guard !mine.isEmpty else { return }
        let attended = Attended(node: nil, drive: nil, happenings: mine, readings: nil, mode: attention.asleep ? "waking" : "awake")
        Task.detached { await stream.think(attended) }
    }

    /// A Desk change re-offers its still-owed moments, including returns to conversations; the stream reads their current Desk evidence.
    func reofferQueueMoments() async {
        guard attention.opened, !isFlushedForTermination else { return }
        do {
            let owed = try await Attention.owed(dataRoot: dataRoot).filter {
                $0.happening?.kind == .moment && $0.happening?.subject.hasPrefix("queue:") == true
            }
            guard !isFlushedForTermination else { return }
            attentionSucceeded("queue", subject: "owed")
            open(owed)
        } catch { attentionFailed("queue", subject: "owed", error: error) }
    }

    // MARK: - Weighing

    /// Each happening nobody asked about is weighed by the agent's turn program with what it feels and its worth lands where it means. Once the batch
    /// has landed, each node at one ignites once: a backlog gathers before it is thought about. A program without `weigh`, or one whose `weigh` fails,
    /// leaves the rest waiting unweighed and tells the agent once.
    func weigh(_ experiences: [Experience], mode: String) async {
        guard await enterAttention() else { return }
        defer { leaveAttention() }
        guard await finishAttention(), backgroundThinkingEnabled, !attention.asleep, let stream = attention.stream else { return }
        let feltAt = now()
        var weighed: [(experience: Experience, happening: Happening, care: UUID?, worth: Double, felt: JSONValue, said: JSONValue?)] = []
        weighing: for experience in experiences {
            guard let happening = experience.happening, !happening.owed else { continue }
            // Two passes may read the same waiting list: a happening already weighed is never weighed twice.
            do {
                let alreadyWeighed = try await Attention.weighed(experience.id, dataRoot: dataRoot)
                attentionSucceeded("weighed", subject: experience.id)
                if alreadyWeighed { continue }
            }
            catch { attentionFailed("weighed", subject: experience.id, error: error); continue }
            var care: UUID?
            let touch: CareTouchReading
            if happening.subject == "night", happening.door == "sense:night" {
                touch = .none
            } else if happening.kind == .self {
                if let selected = happening.care {
                    guard let id = UUID(uuidString: selected) else {
                        attentionFailed("care", subject: experience.id,
                            error: PersistenceCoreError.ioFailure("Invalid selected care identity: " + selected))
                        continue
                    }
                    care = id
                }
                touch = .none
            } else {
                touch = await substrate.careTouch(by: happening.words)
                if case .touches(let touched, _, _, _) = touch { care = touched.id }
            }
            let felt: JSONValue
            let given: JSONValue
            do {
                let node = try await substrate.attentionNode(care: care, subject: happening.subject, words: happening.words)
                let feeling = try await feltReading(touch: touch, node: node.key, door: happening.door, mode: mode, at: feltAt)
                guard var reading = feeling.objectValue else { throw CocoaError(.coderReadCorrupt) }
                if happening.subject == "night", happening.door == "sense:night" {
                    guard let shows = happening.shows else { throw PersistenceCoreError.ioFailure("The night line has no rest facts.") }
                    reading["rest"] = try JSONValue.parse(Data(shows.utf8))
                }
                if happening.subject == "hour", happening.door == "sense:hour" {
                    guard let shows = happening.shows,
                          case .object(let hour) = try JSONValue.parse(Data(shows.utf8)),
                          let rest = hour["rest"], let curiosity = hour["curiosity"] else {
                        throw PersistenceCoreError.ioFailure("The hour line has no rest or curiosity facts.")
                    }
                    reading["rest"] = rest
                    reading["curiosity"] = curiosity
                }
                felt = .object(reading)
                given = try JSONValue.parse(JSONEncoder().encode(happening))
                attentionSucceeded("reading", subject: experience.id)
                attentionSucceeded("care", subject: experience.id)
            } catch { attentionFailed("reading", subject: experience.id, error: error); continue }
            switch await TurnWeigh.weigh(given, felt: felt, dataRoot: dataRoot) {
            case .ungrown(let program):
                tellOrgan(program)
                break weighing
            case .failed(let program, let why):
                tellWeighFailed(program, why: why)
                break weighing
            case .unavailable(let why):
                attentionFailed("weigh", subject: experience.id, error: PersistenceCoreError.ioFailure(why))
                break weighing
            case .worth(let worth, let said):
                attentionSucceeded("weigh", subject: experience.id)
                weighed.append((experience, happening, care, worth, felt, said))
            }
        }
        guard !weighed.isEmpty else { return }
        // Preferences may change while the turn program weighs. Leave these inputs unweighed for re-enablement.
        guard backgroundThinkingEnabled else { return }
        // No await between these landings: other field work cannot decay the first landing before the last one lands.
        let landing: (at: Date, landed: [(node: AttentionNode, drive: Double)])
        do {
            guard let admitted = try await substrate.land(weighed.map { weight in
                var row: [String: JSONValue] = ["worth": .double(weight.worth), "mode": .string(mode),
                    "door": .string(weight.happening.door), "felt": weight.felt]
                if let said = weight.said { row["said"] = said }
                return (weight.worth, weight.care, weight.happening.subject, weight.happening.words, weight.experience.id, row)
            }) else { return }
            landing = admitted
        } catch { attentionFailed("landing", subject: "batch", error: error); return }
        let (at, landings) = (landing.at, landing.landed)
        guard landings.count == weighed.count else {
            attentionFailed("landing", subject: "batch", error: PersistenceCoreError.ioFailure("Attention landing count does not match its input"))
            return
        }
        scheduleDirtyMicrocycle(reason: "attention.land")
        attentionSucceeded("landing", subject: "batch")
        var ready: [String: AttentionCrossing] = [:]
        for (weight, landed) in zip(weighed, landings) {
            if landed.drive >= 1 {
                ready[landed.node.key] = AttentionCrossing(node: landed.node, drive: landed.drive, readings: weight.felt)
            }
        }
        attention.batch = AttentionBatch(at: at, mode: mode, stream: stream,
            crossings: ready.values.sorted { $0.node.key < $1.node.key })
        _ = await finishAttention()
    }

    /// What waited (through sleep, or until the agent's turn program could weigh) is weighed once.
    func weighWaiting(mode: String) async {
        do {
            let waiting = try await Attention.waiting(dataRoot: dataRoot)
            attentionSucceeded("waiting", subject: "record")
            await weigh(waiting, mode: mode)
        }
        catch { attentionFailed("waiting", subject: "record", error: error) }
    }

    /// A thought settled: if the agent's turn program changed, what waited may now be weighed.
    public func thoughtSettled() async {
        guard attention.opened, !attention.asleep else { return }
        await weighWaiting(mode: "awake")
    }

    // MARK: - Ignition

    /// Admission release or caller cancellation ends this wait; the admitted batch retains its own work.
    private func enterAttention() async -> Bool {
        while attention.admitted {
            let released = attention.released
            await released.park()
            if Task.isCancelled { return false }
        }
        guard !Task.isCancelled else { return false }
        attention.admitted = true
        return true
    }

    private func leaveAttention() {
        attention.admitted = false
        attention.released.resume()
        attention.released = ScopedWaiter()
    }

    /// Finish the admitted batch before another landing, even across record awaits. Retained phases are unsettled work, not a cache:
    /// unfinished rows live with the substrate's application marker and a claimed handoff stays here until settlement.
    private func finishAttention() async -> Bool {
        do {
            if let landing = try await substrate.checkpointAttentionLanding() {
                let rows = try landing.rows.map { try attentionDetail(Attention.weighKind, subject: $0.subject, row: $0.fields,
                    at: landing.at, once: "attention.weigh:" + $0.subject) }
                try await ExperienceStore.at(dataRoot).note(rows, durable: true)
                await substrate.settleAttentionLanding(landing.id)
                attentionSucceeded("checkpoint", subject: "batch")
            }
        } catch {
            attentionFailed("checkpoint", subject: "batch", error: error)
            return false
        }
        if var batch = attention.batch {
            do {
                while var crossing = batch.crossings.first {
                    if crossing.claimed == nil {
                        guard backgroundThinkingEnabled else { attention.batch = batch; return false }
                        // Membership must be complete before drive leaves its node.
                        let landed: Attention.Landed
                        do {
                            landed = try await Attention.landed(on: crossing.node.key, dataRoot: dataRoot)
                            guard await substrate.attend(crossing.node.key, at: batch.at) != nil else {
                                throw Attention.RecordError.missingNode(crossing.node.key)
                            }
                            attentionSucceeded("claim", subject: crossing.node.key)
                        } catch let error as Attention.RecordError {
                            if case .malformedDetail = error { throw error }
                            attentionFailed("claim", subject: crossing.node.key, error: error)
                            // The node keeps its drive and repair debt; another landing or opening can claim it again.
                            batch.crossings.removeFirst()
                            continue
                        }
                        crossing.claimed = Attended(node: crossing.node, drive: crossing.drive, happenings: landed.happenings,
                            readings: crossing.readings, mode: batch.mode, earlierDrive: landed.earlierDrive)
                        batch.crossings[0] = crossing
                        scheduleDirtyMicrocycle(reason: "attention.ignite")
                    }
                    guard let attended = crossing.claimed else { throw Attention.RecordError.missingNode(crossing.node.key) }
                    var row: [String: JSONValue] = ["drive": .double(crossing.drive), "about": .string(crossing.node.about),
                        "happenings": .array(attended.happeningIDs.map { .string($0) }), "mode": .string(batch.mode), "accounted": .bool(true)]
                    if let earlier = attended.earlierDrive { row["earlierDrive"] = try JSONValue.fromEncodable(earlier) }
                    try await ExperienceStore.at(dataRoot).note([try attentionDetail(Attention.igniteKind, subject: crossing.node.key,
                        row: row, at: batch.at, once: crossing.once)])
                    attentionSucceeded("claim.record", subject: "batch")
                    let stream = batch.stream
                    if attended.happenings.contains(where: { $0.happening?.subject == "night" && $0.happening?.door == "sense:night" }) {
                        Task.detached { await stream.rest(attended) }
                    } else {
                        Task.detached { await stream.think(attended) }
                    }
                    batch.crossings.removeFirst()
                }
                attention.batch = nil
            } catch {
                attention.batch = batch
                attentionFailed("claim.record", subject: "batch", error: error)
                return false
            }
        }
        var remaining = attention.returns.count
        while remaining > 0, var returned = attention.returns.first {
            remaining -= 1
            guard let node = returned.attended.node, let drive = returned.attended.drive else {
                attentionFailed("return", subject: returned.once,
                    error: PersistenceCoreError.ioFailure("A failed thought's return has no node or drive"))
                return false
            }
            if !returned.restored {
                do {
                    if try await substrate.restoreDrive(node.key, drive) {
                        returned.restored = true
                        attentionSucceeded("return", subject: node.key)
                        attention.returns[0] = returned
                        scheduleDirtyMicrocycle(reason: "attention.restore")
                    } else {
                        // A missing node owes repair; its payload must reach the record before admission lets it go.
                        attentionFailed("return", subject: node.key, error: Attention.RecordError.missingNode(node.key))
                    }
                } catch {
                    attentionFailed("return", subject: node.key, error: error)
                    attention.returns.removeFirst()
                    attention.returns.append(returned)
                    continue
                }
            }
            do {
                var row: [String: JSONValue] = ["drive": .double(drive),
                    "happenings": .array(returned.attended.happenings.map { .string($0.id) })]
                if let earlier = returned.attended.earlierDrive { row["earlierDrive"] = try JSONValue.fromEncodable(earlier) }
                try await ExperienceStore.at(dataRoot).note([try attentionDetail(Attention.restoreKind, subject: node.key,
                    row: row, at: returned.at, once: returned.once)], durable: true)
                attentionSucceeded("return.record", subject: node.key)
                attention.returns.removeFirst()
            } catch {
                attentionFailed("return.record", subject: node.key, error: error)
                return false
            }
        }
        return attention.returns.isEmpty
    }

    private func attentionDetail(_ kind: String, subject: String, row: [String: JSONValue], at: Date, once: String) throws -> ExperienceStore.Detail {
        .init(source: Attention.detailSource, at: at, subject: subject, kind: kind,
              row: Data(try JSONValue.object(row).serialize(pretty: false).utf8), once: once)
    }

    /// A failed thought returns exactly what it drained, after the current batch finishes.
    public func restoreDrive(_ attended: Attended) async {
        guard attended.node != nil, attended.drive != nil else { return }
        attention.returns.append(AttentionReturn(attended: attended, at: now()))
        guard await enterAttention() else { return }
        defer { leaveAttention() }
        _ = await finishAttention()
    }

    func igniteReady(mode: String) async {
        guard await enterAttention() else { return }
        defer { leaveAttention() }
        guard await finishAttention(), backgroundThinkingEnabled, !attention.asleep, let stream = attention.stream else { return }
        let ready = await substrate.igniting()
        let crossings = ready.nodes.map { AttentionCrossing(node: $0.node, drive: $0.drive, readings: nil) }
        attention.batch = AttentionBatch(at: ready.at, mode: mode, stream: stream, crossings: crossings)
        _ = await finishAttention()
    }

    // MARK: - Sleep

    /// The night is a sleep thought: from the sleep moment until it settles, the world waits unweighed and owed happenings still open thoughts.
    public func fellAsleep() {
        attention.asleep = true
    }

    /// Waking (the night settled, something owed or the person arrived) records why and weighs what waited, once.
    public func woke(_ reason: String) async {
        guard attention.asleep else { return }
        do { try await note(Attention.wakeKind, subject: "sleep", row: ["reason": .string(reason)]) }
        catch { attentionFailed("wake", subject: "sleep", error: error); return }
        attentionSucceeded("wake", subject: "sleep")
        attention.asleep = false
        await igniteReady(mode: "waking")
        await weighWaiting(mode: "waking")
    }

    public var isAsleep: Bool { attention.asleep }

    public func recordRequestedNight(at: Date) async throws {
        let rest = try await restReading(at: at)
        try await note(Attention.nightKind, subject: "night", row: ["rule": .string("requested"), "rest": rest])
    }

    /// Re-read presence at admission: nil admits the night; a refusal names the body fact that changed.
    public func admitNight(_ attended: Attended, at: Date) async throws -> String? {
        guard let presence = PersonPresence.read(dataRoot: dataRoot, now: at).transition else { return "The person's presence is unknown." }
        guard !presence.here else { return "The person is here." }
        guard at.timeIntervalSince(presence.since) >= 1800 else { return "The person has been away for less than 30 minutes." }
        if let lastTurn = try personTurnAt(), at.timeIntervalSince(lastTurn) < 900 { return "A verified person turn occurred within 15 minutes." }
        let rest = try await restReading(at: at)
        try await note(Attention.nightKind, subject: "night", row: [
            "happenings": .array(attended.happeningIDs.map { .string($0) }), "rest": rest,
            "rule": .string(attended.happenings.contains { $0.happening?.kind == .body } ? "body" : "weigh")])
        return nil
    }

    // MARK: - What the agent feels as it weighs

    func feltReading(touch: CareTouchReading, node: String, door: String, mode: String, at: Date) async throws -> JSONValue {
        var felt: [String: JSONValue] = ["mode": .string(mode)]
        switch touch {
        case .touches(let care, let standout, let bar, let charge):
            felt["touch"] = .object(["care": .string(care.about), "id": .string(care.id.uuidString), "standout": .double(standout),
                                     "bar": .double(bar), "charge": .double(charge), "depth": .string(care.depth.rawValue),
                                     "seed": .bool(care.origin == .seed)])
        case .unavailable(let why): throw PersistenceCoreError.ioFailure("Care matching is unavailable: " + why)
        case .none: felt["touch"] = .null
        }
        let thoughts = try await Attention.thoughts(dataRoot: dataRoot, now: at)
            .filter { $0.thought?.kind == node && $0.thought?.through.contains(door) == true
                && ["hit", "empty"].contains($0.outcome?.status ?? "") }
        let hits = thoughts.filter { $0.outcome?.status == "hit" || $0.claims.contains { $0.claim == Thought.careMoved } }.count
        felt["yield"] = .object(["hits": .int(Int64(hits)), "tries": .int(Int64(thoughts.count))])
        felt["presence"] = .string(PersonPresence.read(dataRoot: dataRoot, now: at).line)
        let quiet = try TurnQuietHoursWindow.checkedRead(dataRoot: dataRoot)
        felt["quiet"] = .bool(quiet?.contains(hour: Calendar.current.component(.hour, from: at)) == true)
        let activity = await ChatTurnSteering.shared.turnActivityOrSeed(for: dataRoot, at: at)
        felt["busy"] = .object(["open": .int(Int64(ChatTurnSteering.liveSessions(dataRoot: dataRoot).count)),
                                "idleMinutes": .double(max(0, at.timeIntervalSince(activity)) / 60)])
        if let affect = await substrate.attentionAffect() {
            felt["affect"] = .object(["arousal": .double(affect.arousal), "taskPressure": .double(affect.taskPressure), "warmth": .double(affect.warmth)])
        } else { felt["affect"] = .null }
        let body = await organismSnapshot()
        felt["body"] = body.enabled ? .object(["fatigue": .double(body.chemicalState.fatigue), "curiosity": .double(body.chemicalState.curiosity),
                                              "vigilance": .double(body.chemicalState.vigilance), "novelty": .double(body.chemicalState.novelty)]) : .null
        felt["notebook"] = .object(try AttentionNotebook.read(dataRoot: dataRoot))
        return .object(felt)
    }

    // MARK: - Telling the agent

    /// The agent's turn program has no `weigh`: one body happening per program tells it of the organ and names the calls that grow it.
    func tellOrgan(_ program: String) {
        let seed: String?
        do { seed = try TurnWeigh.seedWeigh() } catch { seed = "The seed's weigh could not be read: " + error.localizedDescription }
        Attention.post(Happening(.body, subject: "turn", door: "stem", who: "self",
            words: "New organ to grow: weigh(h, felt), the worth to you of what nobody asked about; until your turn program has it, the world waits. "
                + "ability.read {id:\"turn\"} shows the seed's beside yours; ability.save {id:\"turn\", edits, why} grows yours.",
            once: "organ:weigh:" + program, shows: seed), dataRoot: dataRoot)
    }

    /// The agent's `weigh` failed: what it would weigh waits, and the repair is the agent's, said once per program.
    func tellWeighFailed(_ program: String, why: String) {
        attentionLog("weigh failed in turn program %@: %@", String(program.prefix(12)), why)
        Attention.post(Happening(.body, subject: "turn", door: "stem", who: "self",
            words: "Your weigh(h, felt) did not return a worth, so what nobody asked about waits until it does. ability.read {id:\"turn\"} shows yours "
                + "beside the seed's; ability.save {id:\"turn\", edits, why} mends it.",
            once: "organ:weigh-failed:" + program, shows: why), dataRoot: dataRoot)
    }

    func note(_ kind: String, subject: String, row: [String: JSONValue]) async throws {
        try await Attention.note(kind, subject: subject,
            row: Data(try JSONValue.object(row).serialize(pretty: false).utf8), dataRoot: dataRoot)
    }

    private func attentionFailed(_ operation: String, subject: String, error: Error) {
        attentionLog("Attention %@ for %@ is unfinished: %@", operation, subject, error.localizedDescription)
        RepairOwed.owe(dataRoot, id: "attention:" + operation + ":" + subject, kind: .act,
            operation: "attention." + operation + ":" + subject, owner: subject, words: error.localizedDescription,
            lever: "Repair the named attention source or record; its unfinished input remains owed.")
    }

    private func attentionSucceeded(_ operation: String, subject: String) {
        RepairOwed.settle(dataRoot, operation: "attention." + operation + ":" + subject,
            evidence: .init(source: "attention", id: subject))
    }

    nonisolated func attentionLog(_ format: String, _ arguments: CVarArg...) {
        FileHandle.standardError.write(Data(("[Attention] " + String(format: format, arguments: arguments) + "\n").utf8))
    }
}
