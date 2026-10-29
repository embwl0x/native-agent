import AuthoredCapabilities
import ChatToolRuntime
import ChatTurnContracts
import Darwin
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
import TurnTrace
// Blueprint: | `Expansion.swift` | `Expansion`: live call threads, per-mind/model/authority practice storage, settlement and one coalescing writer; `expansion/record.json` |

/// Live call threads, authority-separated practice storage and one coalescing writer.
public actor Expansion {
    public static let shared = Expansion()

    var books: [String: Book] = [:]
    var unavailable: [String: String] = [:]
    private var threads: [String: CallThread] = [:]
    private var closing: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Roots with a write running, and roots changed since it began.
    private var writing: [String: Task<Void, Never>] = [:]
    private var dirty: Set<String> = []

    // MARK: - Who is acting

    /// The mind whose call this is, and the thread of calls it belongs to.
    /// Nil for calls no mind chose in the moment: a part's own program, a
    /// native owner's read, a replay.
    struct Caller: Sendable {
        let root: String
        let agent: String
        let model: String
        let session: String
        let turn: String
        /// What woke the turn, by kind: never a name or a phrase.
        let woke: String
        /// Who steered the turn (`PeerDataTaint.abilitySources`): the untrusted
        /// principals whose turn this is, empty when the mind's own. A turn of
        /// one authority learns from and is offered only its own practice.
        let steered: [String]

        var authority: String { steered.isEmpty ? "own" : "steered:" + steered.joined(separator: ",") }
        var practice: String { [agent, model, authority].joined(separator: "\u{1}") }
        var thread: String { [root, agent, model, authority, session, turn].joined(separator: "\u{1}") }

        static func current(dataRoot: URL, session: String?, surface: String) -> Caller? {
            guard SkillRunContext.partID == nil else { return nil }
            let session = session ?? ChatToolSessionContext.verifiedSessionId ?? LLMCallContext.sessionId ?? ""
            let envelope = ChatToolSessionContext.envelope
            let agent: String
            let model: String
            // A helper's saved choice may inherit another route. Practice
            // belongs to the admitted model, never that unresolved setting.
            if let bot = StandingBotContinuity.currentBot {
                guard let admitted = LLMCallContext.admittedModel else { return nil }
                agent = "helper:" + bot.id.uuidString.lowercased()
                model = admitted
            } else if StandingBotContinuity.currentContract != nil {
                guard let id = BotDefinition.id(forSession: session),
                      let admitted = LLMCallContext.admittedModel else { return nil }
                agent = "helper:" + id.uuidString.lowercased()
                model = admitted
            } else if let turn = ChatTurnRuntimeContext.current {
                agent = "self"
                model = turn.model
            } else if let envelope, let named = envelope.agent, !named.isEmpty, named != "self" {
                // An outside agent calling the door itself: its own model is unknown here.
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
            return Caller(root: dataRoot.standardizedFileURL.path, agent: agent, model: model, session: session,
                          turn: TurnTraceContext.turnId ?? "", woke: woke, steered: PeerDataTaint.abilitySources)
        }
    }

    // MARK: - The door's three moments

    /// A call arrives: it is the next call of whatever came before it in its
    /// thread. It settles that step's predictions and is kept as an example of
    /// that step's situation. Returns whether it is the thread's first call.
    func arrive(_ caller: Caller, tool: String, input: [String: JSONValue], at: Date) -> Bool {
        load(caller.root)
        guard books[caller.root] != nil else { return true }
        guard threads[caller.thread]?.ended != true else { return false }
        let call = Self.stripped(input)
        // A new turn of this mind in this conversation ends its turns before.
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

    /// The call returned in `seconds`: what this follow-up costs when the mind
    /// makes it herself, kept on its example.
    func ran(_ caller: Caller, seconds: Double) {
        guard var thread = threads[caller.thread], let open = thread.open else { return }
        thread.open = nil
        threads[caller.thread] = thread
        guard var practice = books[caller.root]?.practices[caller.practice],
              let index = practice.situations[open.situation]?.examples.lastIndex(where: { $0.at == open.at }) else { return }
        practice.situations[open.situation]?.examples[index].ran = seconds
        books[caller.root]?.practices[caller.practice] = practice
    }

    /// The call threw: there is no result for a next call to follow.
    func broke(_ caller: Caller) {
        threads[caller.thread]?.last = nil
        threads[caller.thread]?.open = nil
    }

    /// A result came back: its situation, the predictions it makes now (each
    /// a try), and the one to deliver, when one stands and is not withheld.
    func consider(_ caller: Caller, tool: String, input: [String: JSONValue], result: JSONValue,
                  first: Bool, at: Date, deliver: Bool) -> Plan? {
        load(caller.root)
        guard var thread = threads[caller.thread], !thread.ended else { return nil }
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
        var practice = books[caller.root]?.practices[caller.practice] ?? Practice(agent: caller.agent, model: caller.model, steered: caller.steered, at: at)
        practice.lastAt = at
        var place = practice.situations[situation] ?? Situation(at: at)
        place.lastAt = at
        practice.situations[situation] = place
        let among = max(1, practice.records.values.filter { $0.lifetimeTries > 0 }.count)
        var best: (plan: Plan, gain: Double)?
        var tries: [Try] = []
        for template in Self.templateEvidence(place.examples).templates {
            guard let call = Self.fill(template, from: values) else { continue }
            let signature = situation + "\u{1}" + template.form
            var record = practice.records[signature] ?? Record(situation: situation, form: template.form, at: at)
            let nature = Self.nature(call)
            let measure = Law.measure(record, template, among: among)
            var attempt = Try(signature: signature, call: call, nature: nature, turn: caller.turn,
                              standing: measure.stands, lower: measure.lower, bar: measure.bar, known: Set(index.keys))
            if deliver, measure.stands, let nature, let cHit = measure.cHit, let cMiss = measure.cMiss {
                if Double.random(in: 0..<1) < Law.withholding(tries: record.tries, hits: record.hits) {
                    attempt.withheld = true
                    do { try record.increment(\.withheld, "withheld") }
                    catch { fail(caller.root, error); return nil }
                } else {
                    let gain = measure.lower * cHit - (1 - measure.lower) * cMiss
                    if best.map({ gain > $0.gain }) ?? true {
                        best = (Plan(invocation: attempt.invocation, signature: signature, call: call, nature: nature, within: cHit, expected: cMiss,
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

    /// What became of a planned delivery: its result rode inside the call's
    /// result (`landed`), or it did not run in time, failed, did not fit, or
    /// was never started (`seconds` nil: no time left for it), and the try
    /// stays a shadow one. Its time is the stem's own cost of it.
    func delivered(_ caller: Caller, invocation: UUID, landed: JSONValue?, seconds: Double?) {
        guard var thread = threads[caller.thread],
              let index = thread.tries.firstIndex(where: { $0.invocation == invocation && $0.planned }) else { return }
        thread.tries[index].planned = false
        let signature = thread.tries[index].signature
        guard var practice = books[caller.root]?.practices[caller.practice], var record = practice.records[signature] else {
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
            // What it showed that the mind did not already have: a later call
            // carrying one of these used it.
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
    nonisolated(nonsending) static func withTurn<T>(dataRoot: URL?, afterReply: (T) -> AfterReply? = { _ in nil },
                                                  _ work: () async throws -> T) async rethrows -> T {
        guard let dataRoot, let turn = TurnTraceContext.turnId, !turn.isEmpty else { return try await work() }
        let root = dataRoot.standardizedFileURL.path
        let bus = TurnTraceContext.bus
        let surface = LLMCallContext.surface
        let close: @Sendable () async -> Void = {
            await NativeAgentCore.settle {
                await TurnTraceContext.$bus.withValue(bus) {
                await TurnTraceContext.$turnId.withValue(turn) {
                await LLMCallContext.$surface.withValue(surface) {
                    await Self.shared.endTurn(root: root, turn: turn)
                    TurnTraceBus.fireFromContext(kind: "tool.dispatch.closed")
                } } }
            }
        }
        do {
            let result = try await work()
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
            await withCheckedContinuation { continuation in
                if threads[key] == nil { continuation.resume() }
                else { closing[key, default: []].append(continuation) }
            }
        }
        // Join the same coalescing writer used by calls, including any write
        // already in flight. There is no second writer at turn settlement.
        await writing[root]?.value
    }

    private func settle(_ tries: [Try], caller: Caller, tool: String?, next: [String: JSONValue]?,
                        observationLost: Bool = false) {
        guard !tries.isEmpty, var practice = books[caller.root]?.practices[caller.practice] else { return }
        let among = max(1, practice.records.values.filter { $0.lifetimeTries > 0 }.count)
        for attempt in tries where !attempt.planned || tool == nil {
            guard var record = practice.records[attempt.signature] else { continue }
            let outcome: Outcome = observationLost ? .unknown : Self.outcome(attempt, tool: tool, next: next)
            do { try record.note(outcome, z: Law.z(among: among)) }
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
                    surface: TurnTraceContext.turnId == caller.turn ? LLMCallContext.surface : nil,
                    payload: .object(row)),
                    on: TurnTraceContext.bus ?? .shared)
            }
        }
        books[caller.root]?.practices[caller.practice] = practice
    }

    /// A thread whose turn is over: what it predicted never came.
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

    /// Keeps the next call as an example of the step it followed: the call as
    /// the mind wrote it, and for each of its values the paths in that step's
    /// call and result that held exactly that value.
    private func learn(_ caller: Caller, situation: String, call: [String: JSONValue], index: [String: [String]],
                       gap: Double, at: Date) -> Open? {
        guard ((try? JSONValue.object(call).serialize(pretty: false))?.utf8.count ?? .max) <= Law.callCap,
              !Self.carriesSecret(call),
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
        books[root] = nil
        dirty.remove(root)
        nativeLog("Expansion record unavailable at %@; bytes preserved: %@", root, error.localizedDescription)
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
                $0.caller.root == caller.root && $0.caller.agent == caller.agent
                    && $0.caller.model == caller.model && $0.caller.steered == caller.steered
            }.flatMap { $0.tries.map(\.signature) })
            for key in practice.records.filter({ !pinned.contains($0.key) }).sorted(by: { $0.value.lastAt < $1.value.lastAt })
                .prefix(practice.records.count - Law.recordCap).map(\.key) {
                practice.records[key] = nil
            }
        }
        guard var book = books[caller.root] else { return }
        book.practices[caller.practice] = practice
        let active = Set(threads.values.filter { $0.caller.root == caller.root }.map { $0.caller.practice })
        if book.practices.count > Law.practiceCap, let stalest = book.practices.filter({ !active.contains($0.key) }).min(by: { $0.value.lastAt < $1.value.lastAt })?.key {
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

    /// Writes coalesce with no clock: one write at a time per root, off every
    /// call's path; changes made while it runs are written by the next one.
    private func scheduleWrite(_ root: String) {
        guard books[root] != nil, unavailable[root] == nil else { return }
        dirty.insert(root)
        guard writing[root] == nil else { return }
        writing[root] = Task { await self.drain(root) }
    }

    private func drain(_ root: String) async {
        while dirty.remove(root) != nil, let book = books[root] {
            await Task.detached(priority: .utility) {
                Self.write(book, root: URL(fileURLWithPath: root, isDirectory: true))
            }.value
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
        let book = try decoder.decode(Book.self, from: data)
        guard book.version == Book.current else {
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
        return book
    }

    private static func write(_ book: Book, root: URL) {
        let url = path(root)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(book), to: url)
        } catch {
            nativeLog("The expansion record was not saved to %@: %@", url.path, error.localizedDescription)
        }
    }
}
