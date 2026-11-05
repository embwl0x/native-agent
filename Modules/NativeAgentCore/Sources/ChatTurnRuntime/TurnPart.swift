import AuthoredCapabilities
import AgentWorkspace
import CryptoKit
import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Senses
import Transcripts
import TurnTrace
import NativeAgentShared
// Blueprint: | `TurnPart.swift` | `TurnPart`; Source-bound helper and bounded throwing-program recovery |

/// The part steps events and returns effects without running its own loop; the stem executes them.
/// Resume and repair replay the same event log, matching effect identities rather than positions.
/// Malformed or throwing programs use the bounded previous/seed repair exception and owe the agent its evidence.
struct TurnPart {
    static let id = "turn"
    static let effects: Set<String> = ["model.call", "app", "reply.stream", "reply.end", "after"]

    let dataRoot: URL
    let surface: String
    let turn: Turn
    let deadlines: OperationDeadlines
    /// The turn's cancel flag: Stop ends every wait here.
    let stop: URL?
    let gathered: TurnReach
    let tools: [String]
    private(set) var log: [JSONValue]
    private(set) var system: SystemPromptSegments?
    private(set) var offeredTools: [String]?
    private(set) var afterTurn = false
    /// Retain model and part-streamed words in log order so resumed settlement keeps the same answer.
    private(set) var answered = ""
    /// Keep started calls without results so a re-proposal identifies the same uncertain effect.
    private(set) var uncertain: [JSONValue] = []
    private var finished = false
    private var queue: [(effect: [String: JSONValue], identity: String, step: Int)] = []
    private var state: JSONValue = .null
    /// Track round and call identity so each model call dispatches once.
    private var round: (ordinal: Int, ids: [String], used: Set<Int>)?
    private var rounds = 0
    private var seen: [String: Int] = [:]
    private var file: AbilityStore.File
    private let seed: AbilityStore.File
    private var failed: Set<String> = []
    /// Exclusive source-bound opened program; each event gets fresh frozen input.
    private var helper: OwnedProgramRunner.Held?
    private var arrivals: [ResidentWake.Item] = []
    private var heals = 0
    /// A helper failure can happen before the seed ever executes. Allow one
    /// fresh seed lease, independently of defective source recovery.
    private var seedHelperRetried = false

    /// The installed current version runs. Only an absent current slot admits
    /// seed installation; a failed read or write ends with its storage cause.
    init(dataRoot: URL, surface: String, stop: URL?, context: TurnContext, log: [JSONValue], turn: Turn, deadlines: OperationDeadlines) async throws {
        self.turn = turn
        self.deadlines = deadlines
        self.dataRoot = dataRoot; self.surface = surface; self.stop = stop; self.log = log
        gathered = context.turnReach; tools = context.toolSchemas.map(\.name)
        seed = try AbilityStore.decode(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/abilities/turn.js"))
        let store = AbilityStore(dataRoot: dataRoot)
        if let chosen = try Self.read(store, .current) {
            file = chosen
        } else {
            file = try await Self.install(seed, store: store, dataRoot: dataRoot, turn: turn)
        }
    }

    /// Seed installation must land before it runs. A concurrent current write
    /// wins under the same lock; its checked bytes are adopted without a swap.
    private static func install(_ seed: AbilityStore.File,
                                store: AbilityStore, dataRoot: URL, turn: Turn) async throws -> AbilityStore.File {
        do {
            let installed = try await asStem(turn: turn) { turn in
                try AbilityStore.withLock {
                    if let latest = try Self.read(store, .current) { return (file: latest, written: false) }
                    try store.write(seed, turn: turn)
                    return (file: seed, written: true)
                }
            }
            if installed.written {
                RepairOwed.settle(dataRoot, operation: "turn.part.install", evidence: .init(source: "abilities", id: seed.bodyDigest))
            }
            return installed.file
        } catch {
            let owner = store.root.appendingPathComponent("turn.js")
            let words = "The turn part could not be installed at \(owner.path): \(error.localizedDescription). This turn ended incomplete."
            RepairOwed.owe(dataRoot, id: "turn-part-install:" + UUID().uuidString, kind: .run,
                operation: "turn.part.install", owner: owner.path, words: words,
                tap: """
                    Tell the person: repair NativeAgent's turn-part installation/storage failure at \(owner.path). Restore access there, preserving \
                    every ability file and its .prev version; repair is proved only when a turn installs the shipped part.
                    """)
            throw store.repairFailure(source: owner, detail: words)
        }
    }

    /// Each event is one step. A program/helper fault heals and replays the
    /// batch; Stop and storage failures retain their own boundaries.
    mutating func deliver(_ events: [JSONValue]) async throws {
        let first = log.count
        log += events.map { .object(["event": $0]) }
        do { for index in first..<log.count { try await step(index) } }
        catch let fault as Fault {
            _ = try await heal(fault, turn: turn)
        }
    }

    /// Resume reports unmatched starts, queued effects or undispatched model calls without rerunning uncertain work.
    /// After repair, use the repaired version's pending effects.
    mutating func resume() async throws -> Bool {
        let before = heals
        let inFlight = try await rebuild()
        let lastStart = log.lastIndex { if case .object(let entry) = $0 { entry["start"] != nil } else { false } } ?? -1
        let pending = queue.filter {
            $0.effect["effect"] != .string("app") && (heals != before || $0.step > lastStart)
        }
        let dropped = pending.count != queue.count
        queue = pending
        return inFlight || dropped
    }

    /// Log an effect as started before returning it for execution.
    mutating func next() async throws -> [String: JSONValue]? {
        while queue.isEmpty {
            if finished { return nil }
            if Task.isCancelled || ChatCancelFlag.isRaised(stop) { throw CancellationError() }
            _ = try await heal(Fault(code: "stalled", why: "Its steps left the turn with nothing to do and no reply.end."), turn: turn)
        }
        let item = queue.removeFirst()
        log.append(.object(["start": .object(["id": .string(item.identity)])]))
        if case .object(let entry) = log[item.step], case .object(let event)? = entry["event"],
           event["type"] == .string("provider_failure") {
            if item.effect["effect"] == .string("model.call") {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L22"), "site": .string("TurnPart.swift:next")]), turn: turn)
            } else if item.effect["effect"] == .string("reply.stream"), item.effect["text"] == event["text"] {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L23"), "site": .string("TurnPart.swift:next")]), turn: turn)
            }
        }
        if item.effect["effect"] == .string("reply.end") { finished = true }
        if item.effect["effect"] == .string("after") { afterTurn = true }
        return item.effect
    }

    /// One dispatch round holds either the model's calls or the agent's program's own, never both.
    func nextIsApp(authored: Bool) -> Bool {
        guard let effect = queue.first?.effect, effect["effect"] == .string("app") else { return false }
        return (effect["index"] == nil) == authored
    }
    /// Reply-end closes the turn once the after-turn line it asked for is queued.
    var replied: Bool { finished && queue.first?.effect["effect"] != .string("after") }

    /// Retain streamed reply chunks in the log so recovery restores delivered words.
    mutating func sent(_ text: String) {
        answered += text
        log.append(.object(["streamed": .string(text)]))
    }

    /// Deliver each repair notice once after the affected turn ends, never into its own failed execution.
    mutating func tellAgent() {
        guard !arrivals.isEmpty else { return }
        if !ResidentWake.shared.request(dataRoot: dataRoot, reason: "the agent's turn part was swapped back", items: arrivals) {
            nativeLog("The agent's turn part: the arrival telling the agent about the swap was not kept")
        }
        arrivals = []
    }

    private struct Fault: Error { let code: String; let why: String; var helperFailure = false }

    /// Nil is a missing slot only. Unreadable or wrong-kind bytes stay a
    /// storage failure, never evidence that another version should run.
    private static func read(_ store: AbilityStore, _ slot: AbilityStore.Slot) throws -> AbilityStore.File? {
        let found = try store.read(id: id, slot: slot)
        if let found, found.kind != .turn {
            throw store.repairFailure(source: try store.path(id: id, slot: slot, pathExtension: found.pathExtension),
                                      detail: "The turn slot does not hold a turn part.")
        }
        return found
    }

    private static func digest(_ value: JSONValue) throws -> String {
        let text = try value.serialize(pretty: false)
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Replay one log for resume and repair; match effects by identity, retain unknown in-flight starts and queue only unstarted work.
    private mutating func reconstruct() async throws -> Bool {
        state = .null; queue = []; round = nil; rounds = 0; seen = [:]
        system = nil; offeredTools = nil; finished = false; afterTurn = false; answered = ""
        var open: Set<String> = []
        var named: [String: JSONValue] = [:]
        for index in log.indices {
            guard case .object(let entry) = log[index] else { continue }
            if case .object(let start)? = entry["start"], case .string(let identity)? = start["id"] {
                if let at = queue.firstIndex(where: { $0.identity == identity }) { queue.remove(at: at) }
                if identity.hasPrefix("reply.end:") { finished = true }
                if identity.hasPrefix("after:") { afterTurn = true }
                if identity.hasPrefix("model.call:") || identity.hasPrefix("app:") { open.insert(identity) }
            } else if case .string(let text)? = entry["streamed"] {
                answered += text
            } else if case .object(let event)? = entry["event"] {
                switch event["type"] {
                case .string("model"), .string("observation"), .string("provider_failure"):
                    open = open.filter { !$0.hasPrefix("model.call:") }
                case .string("result"):
                    if let round, case .int(let at)? = event["index"], round.ids.indices.contains(Int(at)) {
                        open.remove(Self.callIdentity(round, Int(at)))
                    } else if event["index"] == nil, case .string(let id)? = event["id"] {
                        open.remove("app:" + id)
                    }
                case .string("resumed"):
                    // Resume dropped every app effect it had not started; replay keeps that, so none runs later.
                    queue.removeAll { $0.effect["effect"] == .string("app") }
                default: break
                }
                try await step(index)
                if event["type"] == .string("model"), let round, case .array(let calls)? = event["calls"] {
                    for (at, call) in calls.enumerated() where round.ids.indices.contains(at) {
                        named[Self.callIdentity(round, at)] = call
                    }
                }
                for item in queue where item.step == index {
                    guard case .object(let call)? = item.effect["call"], case .string(let id)? = call["id"] else { continue }
                    named["app:" + id] = .object(["name": .string("app"), "input": call["input"] ?? .object([:])])
                }
            }
        }
        uncertain = open.sorted().compactMap { named[$0] }
        return !open.isEmpty
    }

    private mutating func rebuild() async throws -> Bool {
        do { return try await reconstruct() }
        catch let fault as Fault {
            return try await heal(fault, turn: turn)
        }
    }

    private static func callIdentity(_ round: (ordinal: Int, ids: [String], used: Set<Int>), _ at: Int) -> String {
        round.ids[at].isEmpty ? "app:\(round.ordinal):\(at)" : "app:" + round.ids[at]
    }

    private mutating func step(_ index: Int) async throws {
        guard case .object(var entry) = log[index], case .object(let event)? = entry["event"] else { return }
        var logged: [String: JSONValue] = [:]
        if case .object(let answers)? = entry["reach"] { logged = answers }
        let host = Reach(gathered: gathered, tools: tools, answers: logged)
        defer { entry["reach"] = .object(host.answers); log[index] = .object(entry) }
        let answer = try await run(.object(["state": state, "event": .object(event)]), host: host)
        guard let next = answer["state"], case .array(let list)? = answer["do"] else {
            throw Fault(code: "malformed", why: "Its step returned no {state, do: [effects]}.")
        }
        var calls: [JSONValue] = []
        if case .array(let given)? = event["calls"] { calls = given }
        if event["type"] == .string("model") || event["type"] == .string("provider_failure") {
            rounds += 1
            round = (rounds, calls.map { if case .object(let call) = $0, case .string(let id)? = call["id"] { id } else { "" } }, [])
        } else if event["type"] != .string("result") { round = nil }
        var effects: [(effect: [String: JSONValue], identity: String, step: Int)] = []
        var opened: (system: SystemPromptSegments, tools: [String]?)?
        // The agent's reply ends the turn: in the step that returns it, only the after-turn line may follow.
        var ended = false
        for (place, item) in list.enumerated() {
            guard case .object(var effect) = item, case .string(let name)? = effect["effect"], Self.effects.contains(name) else {
                throw Fault(code: "malformed", why: "Its step returned an effect the stem does not run: \((try? item.serialize(pretty: false)) ?? "?").")
            }
            if ended, name != "after" {
                throw Fault(code: "malformed", why: "Its step returned \(name) after reply.end; the agent's reply ends the turn, "
                    + "and only the after line follows.")
            }
            var admittedCall: String?
            switch name {
            case "app":
                guard case .object(let call)? = effect["call"] else {
                    throw Fault(code: "malformed", why: "Its app effect names no call.")
                }
                if call["tool"] != nil {
                    // The agent's own call is identified by its moment, its place and what it asks, so replay never runs it twice.
                    guard call["tool"] == .string("app"), case .object(let input)? = call["input"] else {
                        throw Fault(code: "malformed", why: "Its own app call must be {tool: \"app\", input: {…}}.")
                    }
                    let digest = try Self.digest(.object(input))
                    let id = "own_\(index)_\(place)_" + String(digest.prefix(16))
                    effect = ["effect": .string("app"), "call": .object(["id": .string(id), "tool": .string("app"), "input": .object(input)])]
                    admittedCall = "app:" + id
                    break
                }
                // Match round calls by provider ID or stable index when absent, each at most once.
                guard var current = round else {
                    throw Fault(code: "malformed", why: "Its app effect names a model call, but no model round is current.")
                }
                var position: Int?
                if case .string(let id)? = call["id"], !id.isEmpty { position = current.ids.firstIndex(of: id) }
                else if case .int(let at)? = call["index"] { position = Int(at) }
                guard let position, current.ids.indices.contains(position), current.used.insert(position).inserted else {
                    throw Fault(code: "malformed", why: "Its app effect names a call the model did not ask for, or one already run.")
                }
                round = current
                effect = ["effect": .string("app"), "index": .int(Int64(position))]
                admittedCall = Self.callIdentity(current, position)
            case "reply.end":
                ended = true
            case "model.call":
                let opening = system == nil && opened == nil
                let supported: Set<String> = opening
                    ? ["effect", "id", "purpose", "note", "system", "tools"]
                    : ["effect", "id", "purpose", "note"]
                let unsupported = effect.keys.filter { !supported.contains($0) }.sorted()
                guard unsupported.isEmpty else {
                    throw Fault(code: "malformed", why: """
                        Its model.call has unsupported fields: \(unsupported.joined(separator: ", ")). The stem owns messages and streaming; system \
                        and tools belong only on the first call.
                        """)
                }
                guard opening else { break }
                guard case .object(let named)? = effect["system"], case .string(let stable)? = named["stable"],
                      case .string(let dynamic)? = named["dynamic"] else {
                    throw Fault(code: "malformed", why: "Its first model.call names no system {stable, dynamic}.")
                }
                var tools: [String]?
                if let offered = effect["tools"] {
                    guard case .array(let names) = offered,
                          names.allSatisfy({ if case .string = $0 { true } else { false } }) else {
                        throw Fault(code: "malformed", why: "Its first model.call tools must be an array of names.")
                    }
                    tools = names.compactMap { if case .string(let name) = $0 { name } else { nil } }
                }
                opened = (SystemPromptSegments(stable: stable, dynamic: dynamic), tools)
            default: break
            }
            var identity: String
            if let admittedCall { identity = admittedCall }
            else if case .string(let own)? = effect["id"], !own.isEmpty { identity = name + ":" + own }
            else {
                identity = name + ":" + (try Self.digest(item))
                seen[identity, default: 0] += 1
                identity += "#\(seen[identity] ?? 1)"
            }
            effects.append((effect, identity, index))
        }
        if let opened { (system, offeredTools) = opened }
        state = next
        queue += effects
        if event["type"] == .string("model"), calls.isEmpty, case .string(let text)? = event["text"] { answered += text }
    }

    /// Each selected source gets one helper attempt. Every non-Stop failure
    /// reaches the same bounded turn-program recovery, regardless of origin.
    private mutating func run(_ input: JSONValue, host: Reach) async throws -> [String: JSONValue] {
        let runner = OwnedProgramRunner(dataRoot: dataRoot)
        let program = OwnedProgram(kind: .turn, id: file.id, version: file.bodyDigest, source: file.body, entry: .run, resident: true)
        let opening = helper == nil
        if Task.isCancelled || ChatCancelFlag.isRaised(stop) { throw CancellationError() }
        if helper == nil {
            do {
                helper = try runner.holdTurn(program)
            } catch is CancellationError { throw CancellationError() }
            catch {
                let code = (error as? SenseFailure)?.code ?? "helper_start_failed"
                TurnTraceBus.fireFromContext(kind: "turn.part.unavailable", surface: surface,
                    payload: .object(["phase": .string("admission"), "reason": .string(code),
                                      "detail": .string(error.localizedDescription)]), turn: turn)
                throw Fault(code: code, why: "\(error.localizedDescription) Helper: \(SenseHostLocator.helperURL.path).", helperFailure: true)
            }
        }
        guard let held = helper else { throw Fault(code: "helper_lease_missing", why: "The helper owner returned no lease.", helperFailure: true) }
        let receipt = await runner.run(program, input: input, host: host,
            execution: .init(turn: turn, surface: surface, deadlines: deadlines, input: input), on: held)
        if opening, case .object(let out) = receipt {
            var payload: [String: JSONValue] = ["reused": .bool(held.reused),
                "sourceDigest": .string(program.digest), "version": .string(program.version)]
            payload["status"] = out["status"]
            if case .bool(let reused)? = out["programReused"] {
                payload["programReused"] = .bool(reused)
                payload["freshContext"] = .bool(!reused)
            }
            TurnTraceBus.fireFromContext(kind: "turn.part.helper", surface: surface, payload: .object(payload), turn: turn)
        }
        if Task.isCancelled || ChatCancelFlag.isRaised(stop) { throw CancellationError() }
        guard case .object(let out) = receipt, out["status"] == .string("ok") else {
            helper = nil
            var why = "The helper returned no terminal receipt.", code = "helper_receipt_invalid"
            var remedy: JSONValue?
            var helperFailure = true
            if case .object(let fields) = receipt {
                if case .string(let status)? = fields["status"] {
                    code = status; why = "The helper returned \(status) without failure detail."
                }
                if case .string(let reason)? = fields["reason"] { code = reason }
                if case .string(let detail)? = fields["detail"] { why = detail }
                if case .object(let stopped)? = fields["stopped"] {
                    if stopped["reason"] == .string("cancelled") { throw CancellationError() }
                    if case .string(let reason)? = stopped["reason"] { code = reason }
                    if case .string(let detail)? = stopped["detail"] { why = detail }
                }
                if case .object(let error)? = fields["error"] {
                    if case .string(let message)? = error["message"] { why = message }
                    if case .string(let reason)? = error["reason"] { code = reason }
                    remedy = error["remedy"]
                    helperFailure = error["origin"] != .string("javascript")
                }
            }
            TurnTraceBus.fireFromContext(kind: "turn.part.unavailable", surface: surface,
                payload: .object(["phase": .string("execution"), "reason": .string(code), "detail": .string(why),
                                  "remedy": remedy ?? .null]), turn: turn)
            throw Fault(code: code, why: why, helperFailure: helperFailure)
        }
        guard case .object(let answer)? = out["returned"] else {
            throw Fault(code: "malformed", why: "Its step returned no {state, do: [effects]}.")
        }
        return answer
    }

    /// Swap only while the store still holds the failing version; concurrent authored writes win.
    /// Choose an unfailed previous version, otherwise the seed, and preserve a failed previous slot for repair evidence.
    private mutating func heal(_ fault: Fault, turn: Turn) async throws -> Bool {
        let broken = file
        let retrySeedHelper = broken.bodyDigest == seed.bodyDigest && fault.helperFailure && !seedHelperRetried
        if !retrySeedHelper { failed.insert(broken.bodyDigest) }
        helper = nil; heals += 1
        let store = AbilityStore(dataRoot: dataRoot), seed = seed, failed = failed
        let outcome = try await Self.asStem(turn: turn) { (turn: Turn) throws -> (file: AbilityStore.File, swapped: Bool, kept: String, freshHelper: Bool) in
            try AbilityStore.withLock {
                guard let current = try Self.read(store, .current) else {
                    throw store.repairFailure(source: store.root.appendingPathComponent("turn.js"),
                                              detail: "The failing turn's current slot disappeared before recovery.")
                }
                guard current.bodyDigest == broken.bodyDigest else {
                    guard !failed.contains(current.bodyDigest) else {
                        throw store.repairFailure(source: store.root.appendingPathComponent("turn.js"),
                                                  detail: "A concurrently selected turn version already failed this turn.")
                    }
                    return (current, false, "", false)
                }
                // Even a fresh seed lease admits checked current bytes; concurrent writes win and storage failures stay failures.
                if retrySeedHelper { return (current, false, "", true) }
                // Only a turn-program/helper fault reaches this read. An unreadable
                // previous slot is a storage error, never permission to seed.
                let previous = try Self.read(store, .previous)
                let chosen: AbilityStore.File
                let kept: String
                do {
                    if let back = previous, !failed.contains(back.bodyDigest) {
                        chosen = back
                        kept = "\(Self.name(broken, seed: seed)) is kept as abilities/turn.prev.js."
                        try store.swap(id: Self.id, turn: turn)
                    } else if failed.contains(seed.bodyDigest) {
                        throw TurnEngineError.turnPartFailed("No unfailed turn program remains after \(fault.code): \(fault.why)")
                    } else if let previous {
                        chosen = seed
                        kept = "abilities/turn.prev.js still holds \(Self.name(previous, seed: seed))."
                        try store.write(seed, turn: turn)
                    } else {
                        chosen = seed
                        kept = "\(Self.name(broken, seed: seed)) is kept as abilities/turn.prev.js."
                        try store.write(seed, slot: .previous, turn: turn)
                        try store.swap(id: Self.id, turn: turn)
                    }
                    return (chosen, true, kept, false)
                } catch {
                    throw store.repairFailure(source: store.root.appendingPathComponent("turn.js"),
                                              detail: "Authored turn recovery could not be committed: \(error.localizedDescription)")
                }
            }
        }
        file = outcome.file
        if outcome.freshHelper { seedHelperRetried = true }
        TurnTraceBus.fireFromContext(kind: "turn.part.recovered", surface: surface, payload: .object([
            "reason": .string(fault.code), "detail": .string(fault.why),
            "fromDigest": .string(broken.bodyDigest), "sourceDigest": .string(file.bodyDigest),
            "program": .string(file.bodyDigest == seed.bodyDigest ? "seed" : outcome.swapped ? "previous" : "current"),
            "swapped": .bool(outcome.swapped),
            "freshHelper": .bool(outcome.freshHelper),
        ]), turn: turn)
        if outcome.freshHelper {
            arrivals.append(.init(id: "turn-heal:seed-helper:" + broken.bodyDigest,
                line: """
                    Your seed turn helper failed (\(fault.code): \(fault.why)); the stem replayed the turn through the seed with a fresh helper \
                    lease. The helper cause still needs repair.
                    """,
                key: "turn-heal", home: true))
        }
        if outcome.swapped {
            let from = Self.name(broken, seed: seed), to = Self.name(file, seed: seed)
            TurnObservation.record(.healed(from: from, to: to, why: fault.why), surface: surface, turn: turn)
            var line = "Your turn part \(from) failed (\(fault.code)), so I swapped in \(to) and replayed the same turn through it. " + outcome.kept
            let steering = (turn.peerSteering?.checkpointSources ?? []).filter { !PeerDataTaint.ownerTrusts($0) }
            if !steering.isEmpty { line += " The turn was steered by \(steering.joined(separator: ", "))." }
            arrivals.append(.init(id: "turn-heal:" + broken.bodyDigest, line: line, key: "turn-heal", home: true))
        }
        return try await rebuild()
    }

    private static func name(_ file: AbilityStore.File, seed: AbilityStore.File) -> String {
        if file.bodyDigest == seed.bodyDigest { return "the seed" }
        if case .int(let version)? = file.metadata["version"] { return "v\(version)" }
        return "version " + file.bodyDigest.prefix(8)
    }

    /// Seed and recovery writes belong to the stem, outside the turn's authorship; ordinary peer-steered part writes remain refused.
    private static func asStem<T: Sendable>(turn: Turn, _ write: @escaping @Sendable (Turn) throws -> T) async throws -> T {
        // The native installation/throwing-turn repair is the stem's act,
        // carrying the same identity without the authored request's steering.
        let stem = turn.with(\.peerSteering, nil).with(\.origin, nil).with(\.envelope, .native("turn-stem"))
        return try await Task.detached { try write(stem) }.value
    }

    /// Synchronous reach answers must use logged values or the exact gathered input so replay sees the same evidence.
    private final class Reach: OwnedProgramHostProfile, @unchecked Sendable {
        let gathered: TurnReach
        let tools: [String]
        private let lock = NSLock()
        private var logged: [String: JSONValue]
        var answers: [String: JSONValue] { lock.withLock { logged } }

        init(gathered: TurnReach, tools: [String], answers: [String: JSONValue]) {
            self.gathered = gathered; self.tools = tools; logged = answers
        }

        func reach(_ name: String, execution: OwnedProgramExecution) async throws -> JSONValue {
            if let known = lock.withLock({ logged[name] }) { return known }
            let value: JSONValue
            switch name {
            case "persona": value = .object(["prompt": .string(gathered.persona), "guidance": .string(gathered.guidance),
                                            "expression": gathered.expression])
            case "pins": value = .array(gathered.pins.map(JSONValue.string))
            case "recall": value = .string(gathered.recall)
            case "context":
                value = .object(["packet": .string(gathered.packet),
                                 "history": .string(gathered.history), "facts": .array(gathered.facts.map(JSONValue.string)),
                                 "tools": .array(tools.map(JSONValue.string)), "runtime": gathered.runtime])
            default: throw SenseFailure(code: "unknown_reach", message:
                "turn.\(name)() is not in the turn part's reach; it has persona, pins, recall and context.")
            }
            lock.withLock { logged[name] = value }
            return value
        }

        var actionIDs: [String] { [] }
        var floorReasons: Set<String> { [] }
        var scriptKey: String { "" }
        func action(_ id: String) -> OwnedProgramAction? { nil }
        func canonicalAction(_ id: String) -> String { id }
        /// A step replays on every resume and repair, so the agent's turn acts by returning app effects, each run once by the stem.
        func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError> {
            .failure(.init(reason: "effects_only", detail: """
                The agent's turn acts by returning {effect: "app", call: {tool: "app", input: {action: "\(id)", args: {…}}}}; the stem runs it once through \
                the door and steps the result. A call inside the step would run again whenever the step replays.
                """))
        }
        func opensHomeItem(_ input: [String: JSONValue]) -> Bool { false }
        func secretLine(_ text: String) -> Bool { false }
        func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence {
            .init(successful: false, waiting: false, resultClass: "refused", pending: false, effectUnconfirmed: false)
        }
        func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? { nil }
        func perform(_ input: [String: JSONValue], execution: OwnedProgramExecution) async -> JSONValue { .null }
    }
}
