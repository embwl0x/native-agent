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
// Blueprint: | `TurnPart.swift` | `TurnPart`: their turn as a part (`abilities/turn.js` `step(state, event)`) in one held helper per turn (a helper short of resources is an observation retried on the helper backoff until Stop; any other start failure ends the turn with its fix), version choice (prior shipped bodies come from generated `shipped`) and seed install (write failures name the person and storage repair), the effect queue, the turn's event log and reconstruction for resume and heal; `provider_failure` carries the repair's callable input, permits explicit `app` repair calls through the ordinary dispatcher or a re-issued `model.call`, and can end incomplete without healing an authored part; compare-and-swap heal in one store transaction |

/// Her turn as a part (docs/AGENT_IS_THE_APP.md, contract 1). `abilities/turn.js`
/// exports `step(state, event) → {state, do: [effects]}` and runs no loop of its
/// own: the stem hands each event here and runs the effects queued here.
///
/// The log holds events only: what each step was handed (with the reach answers
/// it read), each effect the stem started (by identity and payload digest) and
/// the reply text it streamed. Resume and heal rebuild from it the same way
/// (`reconstruct`). A step that throws or answers malformed heals the part, the
/// one law applied to the part that must always exist: the version before it
/// (or the seed the app ships) comes back and the log replays through it. She
/// hears about it when the turn ends, with the evidence.
struct TurnPart {
    static let id = "turn"
    static let effects: Set<String> = ["model.call", "app", "reply.stream", "reply.end", "after"]

    let dataRoot: URL
    let surface: String
    /// The turn's cancel flag: Stop ends every wait here.
    let stop: URL?
    let gathered: TurnReach
    let tools: [String]
    private(set) var log: [JSONValue]
    /// What the opening model.call of the version now running named.
    private(set) var system: SystemPromptSegments?
    private(set) var offeredTools: [String]?
    private(set) var afterTurn = false
    /// Her final words as the log holds them, in order: the model's answer and
    /// the reply text the part streamed. A resumed turn settles with them.
    private(set) var answered = ""
    /// The calls her log shows started with no result: a relaunch names them
    /// to her exactly, so a call she proposes again is the same call.
    private(set) var uncertain: [JSONValue] = []
    private var finished = false
    private var queue: [(effect: [String: JSONValue], identity: String, digest: String, step: Int)] = []
    private var state: JSONValue = .null
    /// The current model round: its ordinal, call ids and payload digests; an
    /// app effect runs each call once.
    private var round: (ordinal: Int, ids: [String], digests: [String], used: Set<Int>, repair: Bool)?
    private var rounds = 0
    private var seen: [String: Int] = [:]
    private var file: AbilityStore.File
    private let seed: AbilityStore.File
    private var failed: Set<String> = []
    /// One helper for the whole turn; nil until a step needs it, again after a heal.
    private var helper: OwnedProgramRunner.Held?
    private var arrivals: [ResidentWake.Item] = []
    private var heals = 0

    /// The version that runs: the root's turn.js if it reads cleanly, else a
    /// clean `.prev`, else the seed. Installing the seed is recorded when the
    /// store accepts it; it is never a precondition of the turn.
    init(dataRoot: URL, surface: String, stop: URL?, context: TurnContext, log: [JSONValue]) async throws {
        self.dataRoot = dataRoot; self.surface = surface; self.stop = stop; self.log = log
        gathered = context.turnReach; tools = context.toolSchemas.map(\.name)
        seed = try AbilityStore.decode(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/abilities/turn.js"))
        let store = AbilityStore(dataRoot: dataRoot)
        let current = Self.read(store, .current)
        if let chosen = current.file ?? Self.read(store, .previous).file {
            file = chosen
            var metadata = chosen.metadata
            metadata["version"] = seed.metadata["version"]
            // Upgrade only an unchanged shipped version, never an authored part.
            if current.unread == nil, case .int(let version)? = chosen.metadata["version"], metadata == seed.metadata,
               Self.shipped[version]?.contains(chosen.bodyDigest) == true {
                file = await Self.install(seed, over: chosen, store: store, dataRoot: dataRoot)
            }
        } else {
            file = seed
            if current.unread == nil { file = await Self.install(seed, over: nil, store: store, dataRoot: dataRoot) }
        }
        // Another version running in place of an unreadable one is hers to hear.
        if let why = current.unread {
            arrivals.append(.init(id: "turn-unreadable:" + file.bodyDigest, line:
                "Your turn part abilities/turn.js could not be read (\(why)), so I ran \(Self.name(file, seed: seed)) for that turn.",
                key: "turn-heal", home: true))
        }
    }

    /// Installing the shipped part is the stem's bookkeeping, never a
    /// precondition of the turn: a store that refuses the write leaves the turn
    /// running the shipped part, and the abilities directory owes repair until
    /// a later turn's install works. What someone else wrote meanwhile is adopted.
    private static func install(_ seed: AbilityStore.File, over expected: AbilityStore.File?,
                                store: AbilityStore, dataRoot: URL) async -> AbilityStore.File {
        do {
            let installed = try await asStem {
                try AbilityStore.withLock {
                    if let latest = try store.read(id: id), latest != expected { return latest }
                    try store.write(seed)
                    return seed
                }
            }
            RepairOwed.settle(dataRoot, operation: "turn.part.install", evidence: .init(source: "abilities", id: seed.bodyDigest))
            return installed
        } catch {
            let owner = store.root.path + " (turn.js)"
            let words = "The shipped turn part was not written to \(owner): \(error.localizedDescription). Turns run the shipped part meanwhile; repair is owed until a turn installs it."
            RepairOwed.owe(dataRoot, id: "turn-part-install:" + UUID().uuidString, kind: .run,
                operation: "turn.part.install", owner: owner, words: words,
                tap: "Tell the person: repair NativeAgent's turn-part installation/storage failure at \(owner). Restore write access there, preserving every ability file and its .prev version; repair is proved only when a turn installs the shipped part.")
            return seed
        }
    }

    /// Each event is one step. A fault anywhere in the batch heals and replays
    /// the whole batch.
    mutating func deliver(_ events: [JSONValue]) async throws {
        let first = log.count
        log += events.map { .object(["event": $0]) }
        do { for index in first..<log.count { try await step(index) } }
        catch let fault as Fault {
            _ = try await heal(fault)
        }
    }

    /// A relaunched turn rebuilds from its log. True when the part must hear
    /// `resumed`: an effect was in flight (never re-run), or one it queued
    /// before the last start matches nothing the log started, or a model
    /// round's calls were left undispatched (the round is gone with the
    /// process). After a heal the healed version's pending effects stand.
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

    /// The next effect to run, logged as started; nil once the turn is done.
    mutating func next() async throws -> [String: JSONValue]? {
        while queue.isEmpty {
            if finished { return nil }
            if Task.isCancelled || ChatCancelFlag.isRaised(stop) { throw CancellationError() }
            _ = try await heal(Fault(code: "stalled", why: "Its steps left the turn with nothing to do and no reply.end."))
        }
        let item = queue.removeFirst()
        log.append(.object(["start": .object(["id": .string(item.identity), "digest": .string(item.digest)])]))
        if case .object(let entry) = log[item.step], case .object(let event)? = entry["event"],
           event["type"] == .string("provider_failure") {
            if item.effect["effect"] == .string("model.call") {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L22"), "site": .string("TurnPart.swift:next")]))
            } else if item.effect["effect"] == .string("reply.stream"), item.effect["text"] == event["text"] {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L23"), "site": .string("TurnPart.swift:next")]))
            }
        }
        if item.effect["effect"] == .string("reply.end") { finished = true }
        if item.effect["effect"] == .string("after") { afterTurn = true }
        return item.effect
    }

    var nextIsApp: Bool { queue.first?.effect["effect"] == .string("app") }
    /// The person's turn is over: reply.end started, and the after-turn work
    /// her part asked for with it. What it queued after that is hers alone.
    var replied: Bool { finished && queue.first?.effect["effect"] != .string("after") }
    var continues: Bool { !queue.isEmpty }

    /// A reply.stream chunk the stem sent; a resumed turn restores it.
    mutating func sent(_ text: String) {
        answered += text
        log.append(.object(["streamed": .string(text)]))
    }

    /// Told when the turn ends, never into the turn it happened in, and again
    /// for what her keep moment queued after the reply: each arrival once.
    mutating func tellHer() {
        guard !arrivals.isEmpty else { return }
        if !ResidentWake.shared.request(dataRoot: dataRoot, reason: "her turn part was swapped back", items: arrivals) {
            nativeLog("Her turn part: the arrival telling her about the swap was not kept")
        }
        arrivals = []
    }

    private struct Fault: Error { let code: String; let why: String }

    /// `unread`: why the slot holds no usable turn part, when it holds something.
    private static func read(_ store: AbilityStore, _ slot: AbilityStore.Slot) -> (file: AbilityStore.File?, unread: String?) {
        do {
            let found = try store.read(id: id, slot: slot)
            return (found?.kind == .turn ? found : nil, found.flatMap { $0.kind != .turn ? "it is not a turn part" : nil })
        } catch {
            nativeLog("Her turn part's %@ file is unreadable: %@", slot.rawValue, error.localizedDescription)
            return (nil, error.localizedDescription)
        }
    }

    private static func digest(_ value: JSONValue) -> String {
        let text = (try? value.serialize(pretty: false)) ?? ""
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One reconstruction for resume and heal: the log replays through `file`.
    /// Starts and results match effects by identity, never by position. A
    /// started effect with a logged result is done; true when one started
    /// without one (in flight). Everything else it queued is pending.
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
                    }
                default: break
                }
                try await step(index)
                if event["type"] == .string("model"), let round, case .array(let calls)? = event["calls"] {
                    for (at, call) in calls.enumerated() where round.ids.indices.contains(at) {
                        named[Self.callIdentity(round, at)] = call
                    }
                }
            }
        }
        uncertain = open.sorted().compactMap { named[$0] }
        return !open.isEmpty
    }

    private mutating func rebuild() async throws -> Bool {
        do { return try await reconstruct() }
        catch let fault as Fault {
            return try await heal(fault)
        }
    }

    private static func callIdentity(_ round: (ordinal: Int, ids: [String], digests: [String], used: Set<Int>, repair: Bool), _ at: Int) -> String {
        round.ids[at].isEmpty ? "app:\(round.ordinal):\(at)" : "app:" + round.ids[at]
    }

    private mutating func step(_ index: Int) async throws {
        guard case .object(var entry) = log[index], case .object(let event)? = entry["event"] else { return }
        var logged: [String: JSONValue] = [:]
        if case .object(let answers)? = entry["reach"] { logged = answers }
        let host = Reach(gathered: gathered, tools: tools, answers: logged)
        defer { entry["reach"] = .object(host.answers); log[index] = .object(entry) }
        guard let answer = try await run(.object(["state": state, "event": .object(event)]), host: host) else { return }
        guard let next = answer["state"], case .array(let list)? = answer["do"] else {
            throw Fault(code: "malformed", why: "Its step returned no {state, do: [effects]}.")
        }
        var calls: [JSONValue] = []
        if case .array(let given)? = event["calls"] { calls = given }
        if event["type"] == .string("model") || event["type"] == .string("provider_failure") {
            rounds += 1
            round = (rounds, calls.map { if case .object(let call) = $0, case .string(let id)? = call["id"] { id } else { "" } },
                     calls.map(Self.digest), [], event["type"] == .string("provider_failure"))
        } else if event["type"] != .string("result") { round = nil }
        var effects: [(effect: [String: JSONValue], identity: String, digest: String, step: Int)] = []
        var opened: (system: SystemPromptSegments, tools: [String]?)?
        for item in list {
            guard case .object(var effect) = item, case .string(let name)? = effect["effect"], Self.effects.contains(name) else {
                throw Fault(code: "malformed", why: "Its step returned an effect the stem does not run: \((try? item.serialize(pretty: false)) ?? "?").")
            }
            var admittedCall: (identity: String, digest: String)?
            switch name {
            case "app":
                if event["type"] == .string("provider_failure"), var current = round,
                   case .object(var call)? = effect["call"], call["tool"] == .string("app"),
                   case .object? = call["input"] {
                    let position = current.ids.count
                    let id = "repair:\(current.ordinal):\(position)"
                    call["id"] = .string(id)
                    current.ids.append(id); current.digests.append(Self.digest(.object(call))); current.used.insert(position)
                    round = current
                    effect = ["effect": .string("app"), "index": .int(Int64(position)), "call": .object(call)]
                    admittedCall = (Self.callIdentity(current, position), current.digests[position])
                    break
                }
                // A call of this model round, by id (index when id-less), each once.
                guard var current = round, case .object(let call)? = effect["call"] else {
                    throw Fault(code: "malformed", why: "Its app effect names no call of the current model round.")
                }
                var position: Int?
                if case .string(let id)? = call["id"], !id.isEmpty { position = current.ids.firstIndex(of: id) }
                else if case .int(let at)? = call["index"] { position = Int(at) }
                guard let position, current.ids.indices.contains(position), current.used.insert(position).inserted else {
                    throw Fault(code: "malformed", why: "Its app effect names a call the model did not ask for, or one already run.")
                }
                round = current
                effect = ["effect": .string("app"), "index": .int(Int64(position))]
                admittedCall = (Self.callIdentity(current, position), current.digests[position])
            case "reply.end":
                let repairResult = event["type"] == .string("result") && round?.repair == true
                guard (event["type"] == .string("model") && calls.isEmpty) || event["type"] == .string("provider_failure") || repairResult else {
                    throw Fault(code: "malformed", why: "Its reply.end did not follow a model reply without calls or an owned provider failure.")
                }
            case "model.call":
                let opening = system == nil && opened == nil
                let supported: Set<String> = opening
                    ? ["effect", "id", "purpose", "note", "system", "tools"]
                    : ["effect", "id", "purpose", "note"]
                let unsupported = effect.keys.filter { !supported.contains($0) }.sorted()
                guard unsupported.isEmpty else {
                    throw Fault(code: "malformed", why: "Its model.call has unsupported fields: \(unsupported.joined(separator: ", ")). The stem owns messages and streaming; system and tools belong only on the first call.")
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
            // App effects already have the model call's identity and digest.
            // Hash only effects whose own payload supplies their digest.
            let digest = admittedCall?.digest ?? Self.digest(item)
            var identity: String
            if let admittedCall { identity = admittedCall.identity }
            else if case .string(let own)? = effect["id"], !own.isEmpty { identity = name + ":" + own }
            else {
                identity = name + ":" + digest
                seen[identity, default: 0] += 1
                identity += "#\(seen[identity] ?? 1)"
            }
            effects.append((effect, identity, digest, index))
        }
        if let opened { (system, offeredTools) = opened }
        if event["type"] == .string("message"), system == nil {
            throw Fault(code: "malformed", why: "Its message step did not open with a model.call naming the system.")
        }
        state = next
        queue += effects
        if event["type"] == .string("model"), calls.isEmpty, case .string(let text)? = event["text"] { answered += text }
    }

    /// The step's answer object; nil when the turn was stopped meanwhile. A
    /// helper that cannot start for want of resources (`spawn_busy`) is an
    /// observation, retried on the provider backoff until it starts or the
    /// turn is stopped; any other start failure is the stem's own and permanent,
    /// and ends the turn at once with its fix.
    private mutating func run(_ input: JSONValue, host: Reach) async throws -> [String: JSONValue]? {
        let helperURL = SenseHostLocator.helperURL, root = dataRoot
        let runner = OwnedProgramRunner(helperURL: helperURL, dataRoot: root) { scratch in
            try SenseSandboxProfile.build(reach: SenseReach(), helperURL: helperURL, scratch: scratch,
                dataRoot: root, personaRoot: defaultPersonaRoot(dataRoot: root))
        }
        var attempt = 0
        while helper == nil {
            if Task.isCancelled || ChatCancelFlag.isRaised(stop) { return nil }
            do { helper = try runner.hold() } catch {
                guard (error as? SenseFailure)?.code == "spawn_busy" else {
                    let code = (error as? SenseFailure)?.code ?? "helper_start_failed"
                    throw TurnEngineError.turnHelperUnavailable("\(code): \(error.localizedDescription) Tell the person: this copy of NativeAgent could not start its turn helper at \(helperURL.path).")
                }
                attempt += 1
                let delay = ProviderRecoveryPolicy.backoffSeconds(forRetry: attempt)
                TurnObservation.record(.helperUnavailable(why: error.localizedDescription, retryIn: Int(delay)), surface: surface)
                guard await waitUnlessStopped(delay) else { return nil }
            }
        }
        guard let held = helper else { return nil }
        let program = OwnedProgram(kind: .turn, id: file.id, version: file.bodyDigest, source: file.body, entry: .run, resident: true)
        let receipt = await runner.run(program, input: input, host: host, on: held)
        if Task.isCancelled { return nil }
        guard case .object(let out) = receipt, out["status"] == .string("ok") else {
            helper = nil
            var why = "Its step did not finish.", code = "threw"
            if case .object(let fields) = receipt {
                if fields["status"] == .string("timed_out") { code = "timed_out" }
                if case .object(let error)? = fields["error"] {
                    if case .string(let message)? = error["message"] { why = message }
                    if case .string(let reason)? = error["reason"] { code = reason }
                }
            }
            throw Fault(code: code, why: why)
        }
        guard case .object(let answer)? = out["returned"] else {
            throw Fault(code: "malformed", why: "Its step returned no {state, do: [effects]}.")
        }
        return answer
    }

    /// False when Stop (the turn's cancellation or its cancel flag) ends the wait.
    private func waitUnlessStopped(_ seconds: TimeInterval) async -> Bool {
        let stop = stop
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))) != nil }
            if let stop {
                group.addTask {
                    let changes = FileChangeEvents(paths: [stop])
                    defer { changes.cancel() }
                    for await _ in changes.stream where ChatCancelFlag.isRaised(stop) { return false }
                    return false
                }
            }
            let slept = await group.next() ?? false
            group.cancelAll()
            return slept && !Task.isCancelled && !ChatCancelFlag.isRaised(stop)
        }
    }

    /// Compare-and-swap on the failing version, in one store transaction: only
    /// when the store still holds it does the stem swap. The version before it
    /// comes back unless it failed this turn too, then the seed; a `.prev` that
    /// failed is never overwritten (the seed takes the current slot and `.prev`
    /// keeps her newer version). What someone else put there meanwhile is
    /// adopted as it is.
    private mutating func heal(_ fault: Fault) async throws -> Bool {
        let broken = file
        failed.insert(broken.bodyDigest)
        helper = nil; heals += 1
        guard broken.bodyDigest != seed.bodyDigest else { throw TurnEngineError.turnPartFailed(fault.why) }
        let store = AbilityStore(dataRoot: dataRoot), seed = seed, failed = failed
        let outcome = try await Task.detached { () -> (file: AbilityStore.File, swapped: Bool, kept: String, refused: String?, unread: String?) in
            AbilityStore.withLock {
                let usable = { (file: AbilityStore.File?) in file.flatMap { failed.contains($0.bodyDigest) ? nil : $0 } }
                let read = Self.read(store, .current), current = read.file, previous = Self.read(store, .previous).file
                guard current?.bodyDigest == broken.bodyDigest else {
                    return (usable(current) ?? usable(previous) ?? seed, false, "", nil, read.unread)
                }
                var chosen = seed, kept = "\(Self.name(broken, seed: seed)) is kept as abilities/turn.prev.js."
                do {
                    if let back = usable(previous) {
                        chosen = back
                        try store.swap(id: Self.id)
                    } else if let previous {
                        kept = "abilities/turn.prev.js still holds \(Self.name(previous, seed: seed))."
                        try store.write(seed)
                    } else {
                        try store.write(seed, slot: .previous)
                        try store.swap(id: Self.id)
                    }
                    return (chosen, true, kept, nil, nil)
                } catch { return (chosen, true, kept, error.localizedDescription, nil) }
            }
        }.value
        file = outcome.file
        if outcome.swapped {
            let from = Self.name(broken, seed: seed), to = Self.name(file, seed: seed)
            TurnObservation.record(.healed(from: from, to: to, why: fault.why), surface: surface)
            var line = outcome.refused.map {
                "Your turn part \(from) failed (\(fault.code)), so I ran \(to) in its place for that turn; the swap was not recorded (\($0))."
            } ?? "Your turn part \(from) failed (\(fault.code)), so I swapped in \(to) and replayed the same turn through it. " + outcome.kept
            let steering = (PeerDataTaint.current?.checkpointSources ?? []).filter { !PeerDataTaint.ownerTrusts($0) }
            if !steering.isEmpty { line += " The turn was steered by \(steering.joined(separator: ", "))." }
            arrivals.append(.init(id: "turn-heal:" + broken.bodyDigest, line: line, key: "turn-heal", home: true))
        } else if let why = outcome.unread {
            arrivals.append(.init(id: "turn-unreadable:" + file.bodyDigest, line:
                "Your turn part \(Self.name(broken, seed: seed)) failed (\(fault.code)) and abilities/turn.js could not be read (\(why)), so I ran \(Self.name(file, seed: seed)) for that turn.",
                key: "turn-heal", home: true))
        }
        return try await rebuild()
    }

    private static func name(_ file: AbilityStore.File, seed: AbilityStore.File) -> String {
        if file.bodyDigest == seed.bodyDigest { return "the seed" }
        if case .int(let version)? = file.metadata["version"] { return "v\(version)" }
        return "version " + file.bodyDigest.prefix(8)
    }

    /// Writes the stem makes under its own law. A peer-steered turn may not
    /// change her parts (CapabilityLifecycle.requireWrite reads the turn's
    /// provenance); the seed and the swap-back are not the turn's doing.
    private static func asStem<T: Sendable>(_ write: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached { try write() }.value
    }

    /// Reach the part calls synchronously: what this step was already answered
    /// (from the log), else exactly what the stem gathered, recorded for the log.
    private final class Reach: OwnedProgramHostProfile, @unchecked Sendable {
        let gathered: TurnReach
        let tools: [String]
        private let lock = NSLock()
        private var logged: [String: JSONValue]
        var answers: [String: JSONValue] { lock.withLock { logged } }

        init(gathered: TurnReach, tools: [String], answers: [String: JSONValue]) {
            self.gathered = gathered; self.tools = tools; logged = answers
        }

        func reach(_ name: String) async throws -> JSONValue {
            if let known = lock.withLock({ logged[name] }) { return known }
            let value: JSONValue
            switch name {
            case "persona": value = .object(["prompt": .string(gathered.persona), "guidance": .string(gathered.guidance),
                                            "expression": gathered.expression])
            case "pins": value = .array(gathered.pins.map(JSONValue.string))
            case "recall": value = .string(gathered.recall)
            case "context":
                value = .object(["digest": .string(gathered.digest), "packet": .string(gathered.packet),
                                 "history": .string(gathered.history), "facts": .array(gathered.facts.map(JSONValue.string)),
                                 "tools": .array(tools.map(JSONValue.string)), "runtime": gathered.runtime])
            default: throw SenseFailure(code: "unknown_reach", message: "turn.\(name)() is not her reach; she has persona, pins, recall and context.")
            }
            lock.withLock { logged[name] = value }
            return value
        }

        var actionIDs: [String] { [] }
        var floorReasons: Set<String> { [] }
        var scriptKey: String { "" }
        func action(_ id: String) -> OwnedProgramAction? { nil }
        func canonicalAction(_ id: String) -> String { id }
        func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError> {
            .failure(.init(reason: "effects_only", detail: "Her turn reaches the door through app effects, not app.* calls."))
        }
        func opensHomeItem(_ input: [String: JSONValue]) -> Bool { false }
        func secretLine(_ text: String) -> Bool { false }
        func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence {
            .init(successful: false, waiting: false, resultClass: "refused", pending: false, effectUnconfirmed: false)
        }
        func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? { nil }
        func perform(_ input: [String: JSONValue]) async -> JSONValue { .null }
    }
}
