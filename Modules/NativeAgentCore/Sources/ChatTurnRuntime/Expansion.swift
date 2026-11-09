import AuthoredCapabilities
import ChatToolRuntime
import ChatTurnContracts
import Darwin
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
import TurnTrace
// Blueprint: | `Expansion.swift` | `Expansion`; `expansion/record.json`; Coalesced practice writes with repair owed |

public actor Expansion {
    public static let shared = Expansion()

    var books: [String: Book] = [:]
    var unavailable: [String: String] = [:]
    private var threads: [String: CallThread] = [:]
    private var closing: [String: [ScopedWaiter]] = [:]
    private var writing: [String: Task<Void, Never>] = [:]
    private var dirty: Set<String> = []

    func savePending(_ root: String) -> Bool { dirty.contains(root) || writing[root] != nil }

    // MARK: - Who is acting

    /// Only model-chosen calls bind a mind and call thread; native reads, program steps and replays cannot learn as chosen calls.
    struct Caller: Sendable {
        let root: String
        let agent: String
        let model: String
        let surface: String
        let session: String
        let heldTurn: Turn
        var turn: String { heldTurn.id }
        /// Classify wake by kind, never a person's name or phrase.
        let woke: String
        /// Separate learning and offered practice by the full steering-principal set; empty means the mind's own authority.
        let steered: [String]

        var authority: String { steered.isEmpty ? "own" : "steered:" + steered.joined(separator: ",") }
        var practice: String { [agent, authority].joined(separator: "\u{1}") }
        var thread: String { [root, agent, authority, session, turn].joined(separator: "\u{1}") }

        static func current(dataRoot: URL, session: String?, surface: String, turn: Turn) -> Caller? {
            guard turn.partID == nil else { return nil }
            let session = session ?? turn.verifiedSessionID ?? turn.session ?? ""
            let envelope = turn.envelope
            let agent: String
            let model: String
            // Keep the admitted model for diagnostics, never practice identity.
            if let bot = turn.standingBot {
                guard let admitted = turn.admission?.model else { return nil }
                agent = "helper:" + bot.id.uuidString.lowercased()
                model = admitted
            } else if turn.botContract != nil {
                guard let id = BotDefinition.id(forSession: session),
                      let admitted = turn.admission?.model else { return nil }
                agent = "helper:" + id.uuidString.lowercased()
                model = admitted
            } else if let runtime = turn.runtime {
                agent = "self"
                model = runtime.model
            } else if let envelope, let named = envelope.agent, !named.isEmpty, named != "self" {
                // External callers have no attested model here; leave it unknown.
                agent = "agent:" + (envelope.verifiedUserId ?? named)
                model = ""
            } else {
                return nil
            }
            var woke = "surface:" + (envelope?.surface ?? surface)
            if let named = envelope?.agent, !named.isEmpty { woke += " agent:" + named }
            if let work = envelope?.workIdentity, let kind = work.split(separator: ":").first, !kind.isEmpty {
                woke += " work:" + String(kind)
            }
            return Caller(root: dataRoot.standardizedFileURL.path, agent: agent, model: model, surface: surface, session: session,
                          heldTurn: turn, woke: woke, steered: PeerDataTaint.abilitySources(turn: turn))
        }
    }

    // MARK: - The door's three moments

    /// Label the opening read with the actual first call even if the read arrived before thought.
    func start(_ caller: Caller, at: Date, deliver: Bool) -> Plan? {
        load(caller.root)
        guard unavailable[caller.root] == nil, books[caller.root] != nil, threads[caller.thread] == nil else { return nil }
        let situation = "start woke:" + caller.woke
        var thread = CallThread(caller, at: at)
        thread.last = Last(situation: situation, index: [:], returnedAt: at)
        let plan = predict(caller, thread: thread, situation: situation, values: [:], index: [:],
                           at: at, deliver: deliver, firstCall: true)
        trimThreads()
        return plan
    }

    /// Use the actual next call to settle prior predictions and record its situation; preserve whether it opened the thread.
    func arrive(_ caller: Caller, tool: String, input: [String: JSONValue], at: Date) -> Bool {
        load(caller.root)
        guard unavailable[caller.root] == nil, books[caller.root] != nil else { return true }
        guard threads[caller.thread]?.ended != true else { return false }
        let call = Self.stripped(input)
        // A new turn closes prior threads for the same mind and conversation.
        if !caller.turn.isEmpty {
            let ended = threads.filter { key, thread in
                key != caller.thread && thread.caller.root == caller.root && thread.caller.agent == caller.agent
                    && thread.caller.session == caller.session && thread.caller.turn != caller.turn
            }.map(\.key)
            for key in ended { end(key) }
        }
        var thread = threads[caller.thread] ?? CallThread(caller, at: at)
        thread.open = nil
        if let last = thread.last, tool == "app" {
            thread.open = learn(caller, situation: last.situation, call: call, index: last.index,
                                gap: max(0, at.timeIntervalSince(last.returnedAt)), at: at)
        }
        settle(thread.tries.filter { !$0.planned }, caller: caller, tool: tool, next: call)
        thread.tries = thread.tries.filter(\.planned).map { attempt in
            var attempt = attempt
            if attempt.next == nil { attempt.next = Observation(tool: tool, call: call) }
            return attempt
        }
        thread.last = nil
        let first = thread.calls == 0
        thread.calls += 1
        thread.at = at
        threads[caller.thread] = thread
        trimThreads()
        scheduleWrite(caller.root)
        return first
    }

    /// Measure follow-up cost on the call the mind actually made.
    func ran(_ caller: Caller, seconds: Double) {
        guard unavailable[caller.root] == nil else { return }
        guard var thread = threads[caller.thread], let open = thread.open else { return }
        thread.open = nil
        threads[caller.thread] = thread
        guard var practice = books[caller.root]?.practices[caller.practice],
              let index = practice.situations[open.situation]?.examples.lastIndex(where: { $0.at == open.at }) else { return }
        practice.situations[open.situation]?.examples[index].ran = seconds
        books[caller.root]?.practices[caller.practice] = practice
    }

    /// A thrown call has no result from which to predict a follow-up.
    func broke(_ caller: Caller) {
        threads[caller.thread]?.last = nil
        threads[caller.thread]?.open = nil
    }

    /// Each returned result records a prediction trial; deliver only standing, unwithheld predictions.
    func consider(_ caller: Caller, tool: String, input: [String: JSONValue], result: JSONValue,
                  first: Bool, at: Date, deliver: Bool) -> Plan? {
        load(caller.root)
        guard unavailable[caller.root] == nil, var thread = threads[caller.thread], !thread.ended else { return nil }
        let situation = Self.situation(tool: tool, input: input, result: result, woke: first ? caller.woke : nil)
        var flat: [(path: String, value: JSONValue)] = []
        guard JSONValue.object(Self.stripped(input)).leaves(prefix: "in", into: &flat, limit: Law.leafCap, depthLimit: 128),
              result.leaves(prefix: "out", into: &flat, limit: Law.leafCap, depthLimit: 128) else {
            thread.last = nil
            threads[caller.thread] = thread
            return nil
        }
        var values: [String: JSONValue] = [:]
        var index: [String: [String]] = [:]
        for leaf in flat {
            values[leaf.path] = leaf.value
            if let token = Self.sourceToken(leaf.value), index[token, default: []].count < Law.pathsPerValue {
                index[token, default: []].append(leaf.path)
            }
        }
        thread.last = Last(situation: situation, index: index, returnedAt: at)
        return predict(caller, thread: thread, situation: situation, values: values, index: index,
                       at: at, deliver: deliver)
    }

    private func predict(_ caller: Caller, thread: CallThread, situation: String, values: [String: JSONValue],
                         index: [String: [String]], at: Date, deliver: Bool, firstCall: Bool = false) -> Plan? {
        var thread = thread
        var practice = books[caller.root]?.practices[caller.practice] ?? Practice(agent: caller.agent, steered: caller.steered, at: at)
        practice.lastAt = at
        var place = practice.situations[situation] ?? Situation(at: at)
        place.lastAt = at
        practice.situations[situation] = place
        let among = max(1, practice.records.values.filter { $0.lifetimeTries > 0 }.count)
        var best: (plan: Plan, gain: Double)?
        var tries: [Try] = []
        let templates: [Template]
        do { templates = try Self.templateEvidence(place.examples, turn: caller.heldTurn).templates }
        catch { fail(caller.root, error); return nil }
        for template in templates {
            guard let call = Self.fill(template, from: values) else { continue }
            let signature = situation + "\u{1}" + template.form
            var record = practice.records[signature] ?? Record(situation: situation, form: template.form, at: at)
            let nature: Nature?
            do {
                nature = try Self.nature(call, turn: caller.heldTurn)
                if firstCall, try !Self.openingRead(call, turn: caller.heldTurn) { continue }
            } catch { fail(caller.root, error); return nil }
            let measure = Law.measure(record, template, among: among)
            var attempt = Try(signature: signature, call: call, nature: nature, turn: caller.turn,
                              standing: measure.stands, lower: measure.lower, bar: measure.bar, known: Set(index.keys), firstCall: firstCall)
            if deliver, measure.stands, let nature, let cHit = measure.cHit, let cMiss = measure.cMiss {
                if Double.random(in: 0..<1) < Expectation.withholding(tries: record.tries, hits: record.hits) {
                    attempt.withheld = true
                    do { try record.increment(\.withheld, "withheld") }
                    catch { fail(caller.root, error); return nil }
                } else {
                    let gain = measure.lower * cHit - (1 - measure.lower) * cMiss
                    if best.map({ gain > $0.gain }) ?? true {
                        best = (Plan(invocation: attempt.invocation, signature: signature, call: call, nature: nature,
                                     why: .object(["lane": .string("expansion"), "situation": .string(situation),
                                                   "prediction": .string(template.form), "call": .object(call),
                                                   "nature": .string(nature.rawValue), "tries": .int(Int64(record.tries)),
                                                   "hits": .int(Int64(record.hits)), "lower": .double(Self.rounded(measure.lower)),
                                                   "bar": .double(Self.rounded(measure.bar ?? 1)),
                                                   "c_hit_s": .double(Self.rounded(cHit)), "c_miss_s": .double(Self.rounded(cMiss)),
                                                   "steered_by": .array(caller.steered.map(JSONValue.string))])),
                                gain)
                    }
                }
            }
            record.lastAt = at
            practice.records[signature] = record
            tries.append(attempt)
        }
        if let best, let index = tries.firstIndex(where: { $0.invocation == best.plan.invocation }) {
            tries[index].planned = true
        }
        thread.tries += tries
        threads[caller.thread] = thread
        store(practice, caller)
        return best?.plan
    }

    /// A delivery that fails, misses its deadline, does not fit or never starts remains a shadow trial.
    /// Measure the stem's actual cost separately from whether the result landed.
    func delivered(_ caller: Caller, invocation: UUID, landed: JSONValue?, seconds: Double?) {
        guard var thread = threads[caller.thread],
              let index = thread.tries.firstIndex(where: { $0.invocation == invocation && $0.planned }) else { return }
        thread.tries[index].planned = false
        let signature = thread.tries[index].signature
        guard unavailable[caller.root] == nil,
              var practice = books[caller.root]?.practices[caller.practice], var record = practice.records[signature] else {
            thread.tries.remove(at: index)
            retain(thread, key: caller.thread)
            return
        }
        if let seconds { record.costs = Array((record.costs + [seconds]).suffix(Law.costCap)) }
        if let landed {
            thread.tries[index].delivered = true
            do {
                if thread.tries[index].nature == .act { try record.increment(\.prepared, "prepared") }
                else { try record.increment(\.delivered, "delivered") }
            } catch {
                fail(caller.root, error)
                thread.tries.remove(at: index)
                retain(thread, key: caller.thread)
                return
            }
            // Only later calls using newly delivered data can prove the read was useful.
            let had = thread.tries[index].known
            var flat: [(path: String, value: JSONValue)] = []
            let complete = landed.leaves(into: &flat, limit: Law.leafCap, depthLimit: 128)
            thread.tries[index].distinctive = complete ? Set(flat.compactMap { leaf -> String? in
                guard case .string = leaf.value, let token = Self.sourceToken(leaf.value), !had.contains(token) else { return nil }
                return token
            }.prefix(Law.leafCap)) : []
        }
        practice.records[signature] = record
        books[caller.root]?.practices[caller.practice] = practice
        if let next = thread.tries[index].next {
            settle([thread.tries.remove(at: index)], caller: caller, tool: next.tool, next: next.call,
                   observationLost: thread.observationLost)
        } else if thread.ended {
            settle([thread.tries.remove(at: index)], caller: caller, tool: nil, next: nil,
                   observationLost: thread.observationLost)
        }
        retain(thread, key: caller.thread)
        scheduleWrite(caller.root)
    }

    // MARK: - Settling

    /// Resident, ephemeral and helper turns close their own practice, on every
    /// exit. Capture the trace before crossing `settle`: Stop cancels work,
    /// never its outcomes or the write that keeps them across a restart.
    nonisolated(nonsending) static func withTurn<T>(dataRoot: URL?, turn: Turn,
        afterReply: (T) -> AfterReply? = { _ in nil }, _ operation: () async throws -> T
    ) async rethrows -> T {
        guard let dataRoot else { return try await operation() }
        let root = dataRoot.standardizedFileURL.path
        let bus = TurnTraceContext.bus
        let close: @Sendable () async -> Void = { [turn] in
            await NativeAgentCore.settle {
                await TurnTraceContext.$bus.withValue(bus) {
                    await TurnTraceContext.$turnId.withValue(turn.id) {
                        await Self.shared.endTurn(root: root, turn: turn.id)
                        TurnTraceBus.fireFromContext(kind: "tool.dispatch.closed", turn: turn)
                    }
                }
            }
        }
        do {
            let result = try await operation()
            if let continuation = afterReply(result) { continuation.onSettled(close) }
            else { await close() }
            return result
        } catch {
            await close()
            throw error
        }
    }

    private func endTurn(root: String, turn: String) async {
        let ended = threads.filter { $0.value.caller.root == root && $0.value.caller.turn == turn }.map(\.key)
        for key in ended { end(key) }
        for key in ended {
            if threads[key] != nil {
                let done = ScopedWaiter()
                closing[key, default: []].append(done)
                await Task { await done.park() }.value
            }
        }
        // Join the same coalescing writer used by calls, including any write
        // already in flight. There is no second writer at turn settlement.
        await writing[root]?.value
    }

    private func settle(_ tries: [Try], caller: Caller, tool: String?, next: [String: JSONValue]?,
                        observationLost: Bool = false) {
        guard unavailable[caller.root] == nil, !tries.isEmpty,
              var practice = books[caller.root]?.practices[caller.practice] else { return }
        let among = max(1, practice.records.values.filter { $0.lifetimeTries > 0 }.count)
        for attempt in tries where !attempt.planned || tool == nil {
            guard var record = practice.records[attempt.signature] else { continue }
            let outcome: Outcome = observationLost ? .unknown : Self.outcome(attempt, tool: tool, next: next)
            do { try record.note(outcome, z: Expectation.z(among: among)) }
            catch { fail(caller.root, error); return }
            practice.records[attempt.signature] = record
            var row: [String: JSONValue] = [
                "agent": .string(caller.agent), "model": .string(caller.model),
                "invocation": .string(attempt.invocation.uuidString.lowercased()),
                "situation": .string(record.situation), "prediction": .string(record.form),
                "outcome": .string(outcome.rawValue), "delivered": .bool(attempt.delivered),
                "withheld": .bool(attempt.withheld), "standing": .bool(attempt.standing),
                "lower": .double(Self.rounded(attempt.lower)), "tries": .int(Int64(record.tries)),
                "hits": .int(Int64(record.hits)), "turn": .string(attempt.turn),
            ]
            if let nature = attempt.nature { row["nature"] = .string(nature.rawValue) }
            if let bar = attempt.bar { row["bar"] = .double(Self.rounded(bar)) }
            if !caller.turn.isEmpty {
                TurnTraceBus.fire(TurnTraceEvent(turnId: caller.turn, kind: "expansion.check",
                    sessionId: caller.session.isEmpty ? nil : caller.session,
                    surface: caller.surface,
                    payload: .object(row), turn: caller.heldTurn),
                    on: TurnTraceContext.bus ?? .shared)
            }
        }
        books[caller.root]?.practices[caller.practice] = practice
    }

    /// An ended thread cannot later receive its predicted call.
    private func end(_ key: String, observationLost: Bool = false) {
        guard var thread = threads[key] else { return }
        let caller = thread.caller
        settle(thread.tries.filter { !$0.planned }, caller: caller, tool: nil, next: nil, observationLost: observationLost)
        thread.tries = thread.tries.filter(\.planned)
        thread.ended = true; thread.observationLost = observationLost || thread.observationLost
        thread.last = nil; thread.open = nil
        retain(thread, key: key)
        scheduleWrite(caller.root)
    }

    private func retain(_ thread: CallThread, key: String) {
        if thread.ended && thread.tries.isEmpty {
            threads[key] = nil
            for waiter in closing.removeValue(forKey: key) ?? [] { waiter.resume() }
        } else { threads[key] = thread }
    }

    // MARK: - Learning

    /// Keep exact next-call values with the preceding call/result paths that supplied them.
    private func learn(_ caller: Caller, situation: String, call: [String: JSONValue], index: [String: [String]],
                       gap: Double, at: Date) -> Open? {
        do {
            if situation.hasPrefix("start woke:"), try !Self.openingRead(call, turn: caller.heldTurn) { return nil }
            if try Self.carriesSecret(call, turn: caller.heldTurn) { return nil }
        } catch { fail(caller.root, error); return nil }
        guard ((try? JSONValue.object(call).serialize(pretty: false))?.utf8.count ?? .max) <= Law.callCap,
              var practice = books[caller.root]?.practices[caller.practice],
              var place = practice.situations[situation] else { return nil }
        var flat: [(path: String, value: JSONValue)] = []
        guard JSONValue.object(call).leaves(into: &flat, limit: Law.leafCap, depthLimit: 128) else { return nil }
        var sources: [String: [String]] = [:]
        for leaf in flat {
            if let token = Self.sourceToken(leaf.value), let paths = index[token] { sources[leaf.path] = paths }
        }
        place.examples = Array((place.examples + [Example(at: at, call: call, sources: sources, gap: gap, ran: nil)])
            .suffix(Law.examplesPerSituation))
        place.lastAt = at
        practice.situations[situation] = place
        practice.lastAt = at
        store(practice, caller)
        return Open(situation: situation, at: at)
    }

    // MARK: - The record

    func load(_ root: String) {
        guard books[root] == nil, unavailable[root] == nil else { return }
        do { books[root] = try Self.read(URL(fileURLWithPath: root, isDirectory: true)) }
        catch { fail(root, error) }
    }

    private func fail(_ root: String, _ error: Error) {
        unavailable[root] = error.localizedDescription
        // Keep any unsaved practice and dirty state, but never use or rewrite
        // it after a failure. A failed publication may already have renamed
        // the destination: neither old bytes nor durability can be promised.
        nativeLog("Expansion record unavailable at %@: %@", Self.path(URL(fileURLWithPath: root)).path, error.localizedDescription)
    }

    private func store(_ practice: Practice, _ caller: Caller) {
        var practice = practice
        if practice.situations.count > Law.situationCap {
            for key in practice.situations.sorted(by: { $0.value.lastAt < $1.value.lastAt })
                .prefix(practice.situations.count - Law.situationCap).map(\.key) {
                practice.situations[key] = nil
            }
        }
        if practice.records.count > Law.recordCap {
            let pinned = Set(threads.values.filter {
                $0.caller.root == caller.root && $0.caller.practice == caller.practice
            }.flatMap { $0.tries.map(\.signature) })
            for key in practice.records.filter({ !pinned.contains($0.key) }).sorted(by: { $0.value.lastAt < $1.value.lastAt })
                .prefix(practice.records.count - Law.recordCap).map(\.key) {
                practice.records[key] = nil
            }
        }
        guard unavailable[caller.root] == nil, var book = books[caller.root] else { return }
        book.practices[caller.practice] = practice
        let active = Set(threads.values.filter { $0.caller.root == caller.root }.map { $0.caller.practice })
        if book.practices.count > Law.practiceCap, let stalest = book.practices.filter({ !active.contains($0.key) }).min(by: { $0.value.lastAt < $1.value
            .lastAt })?.key {
            book.practices[stalest] = nil
        }
        books[caller.root] = book
        scheduleWrite(caller.root)
    }

    private func trimThreads() {
        guard threads.count > Law.threadCap else { return }
        // A live thread trimmed for room has no known terminal outcome.
        // Retire every pending try as unknown rather than lose it or invent a miss.
        for key in threads.sorted(by: { $0.value.at < $1.value.at }).prefix(threads.count - Law.threadCap).map(\.key) {
            end(key, observationLost: true)
        }
    }

    /// Coalesce writes per root off the call path; changes during a write belong to the next write.
    private func scheduleWrite(_ root: String) {
        guard books[root] != nil, unavailable[root] == nil else { return }
        dirty.insert(root)
        guard writing[root] == nil else { return }
        writing[root] = Task { await self.drain(root) }
    }

    private func drain(_ root: String) async {
        while unavailable[root] == nil, dirty.remove(root) != nil, let book = books[root] {
            let dataRoot = URL(fileURLWithPath: root, isDirectory: true)
            let url = Self.path(dataRoot)
            do {
                try await Task.detached(priority: .utility) {
                    try Self.write(book, root: dataRoot)
                }.value
            } catch {
                dirty.insert(root)
                let words = """
                    Durable expansion save unproven at \(url.path): \(error.localizedDescription). Inspect this exact file before repairing; \
                    publication may have preceded the failure. Unsaved practice is retained but unavailable in this runtime; no automatic write will \
                    retry.
                    """
                fail(root, NSError(domain: "Expansion", code: 3, userInfo: [NSLocalizedDescriptionKey: words]))
                TurnTraceBus.fireFromContext(kind: "expansion.record.failed", payload: .object([
                    "path": .string(url.path), "message": .string(words)
                ]), turn: nil)
                RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run,
                    operation: "expansion.record.save", owner: url.path, words: words,
                    lever: """
                        Inspect and repair the named storage failure without replacing retained practice with an empty record; then restart \
                        NativeAgent to read the repaired record.
                        """)
                writing[root] = nil
                return
            }
            TurnTraceBus.fireFromContext(kind: "expansion.record.saved", payload: .object([
                "path": .string(url.path), "version": .int(Int64(book.version)),
                "pending_changes": .bool(dirty.contains(root))
            ]), turn: nil)
            RepairOwed.settle(dataRoot, operation: "expansion.record.save", evidence: .init(source: url.path, id: "durable-save"))
        }
        writing[root] = nil
    }

    static func path(_ root: URL) -> URL {
        root.appendingPathComponent("expansion", isDirectory: true).appendingPathComponent("record.json")
    }

    private static func read(_ root: URL) throws -> Book {
        let url = path(root)
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            let code = errno
            guard code == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            return Book()
        }
        // An existing entry (including a dangling symlink) is never absence.
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var book = try decoder.decode(Book.self, from: data)
        guard book.version == 2 || book.version == Book.current else {
            throw NSError(domain: "Expansion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported record version \(book.version)"])
        }
        for (practice, value) in book.practices {
            for (key, record) in value.records { try record.validate(at: "practices.\(practice).records.\(key)") }
            for (key, situation) in value.situations {
                for example in situation.examples {
                    guard example.gap.isFinite, example.gap >= 0,
                          example.ran.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                        throw Record.invalid("practices.\(practice).situations.\(key).examples timing")
                    }
                }
            }
        }
        try book.fold()
        return book
    }

    private static func write(_ book: Book, root: URL) throws {
        let url = path(root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(book), to: url)
    }
}
