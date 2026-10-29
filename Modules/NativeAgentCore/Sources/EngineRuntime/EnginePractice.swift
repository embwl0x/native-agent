import AgentWorkspace
import ApprovalTransactions
import AppToolRuntime
import AuthoredCapabilities
import BackgroundWork
import ChatToolParsing
import ChatToolRuntime
import ChatTurnContracts
import ChatTurnRuntime
import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import ToolExecution
import TurnTrace
import NativeAgentShared
// Blueprint: | `EnginePractice.swift` | `EnginePractice`: the night's practice pass after each dream, one at a time, Autonomy read again before every keep turn, replay and keep, Stop (termination) cancelling it while its ledger still settles: per agent (the resident, each helper) nominate from the retained traces (`TurnPractice`), start the tape for what is nominated, offer a sequence with two or more replayable recorded examples (arguments exact, results as far as kept) whose later arguments are not mostly judgment to that agent's own keep moment (their ephemeral turn on their resident session, a helper's own turn) under `Parts.compiling`, each keep turn bounded by `TurnTokenBudget` and `TurnDeadline` at `BotRunLimits` (a helper's by its own run budget), a version the store holds for the practice adopted by its `compiled` key, then verify the staged version by tape replay (`ability.validate`) and admit it (`ability.enable`: theirs under Full Mac for their own work, else the owner's card) through the gated app door; at most three offers per agent a night; a `practice.night` trace row |

/// The night's practice (docs/AGENT_IS_THE_APP.md, "Practice compiles"):
/// what an agent did over and over by hand becomes, with its own model's
/// word, one of its abilities. The dream owns the night and raises this
/// after it; the agent's own keep moment writes the ability; the tape
/// verifies it; the store admits it by the keep law; live runs then record
/// execution evidence, without an automatic standing transition.
actor EnginePractice {
    static let shared = EnginePractice()
    /// The pass in flight: one at a time, and quit cancels it and waits for its settlement.
    private var flight: Task<Void, Never>?
    private var stopped = false

    /// Offers per agent a night: a resource bound (a night is not a working
    /// day); the rest wait for the next night, strongest first.
    static let offersPerNight = 3
    /// One packet's examples: the newest within these bounds (resource bounds
    /// for one model call; the replay checks exactly the examples she saw).
    static let packetExamples = 8
    static let packetBytes = 96 * 1024

    /// After a dream: off the dream's own path, one pass at a time.
    static func wake(dataRoot: URL) {
        Task.detached(priority: .utility) { await EnginePractice.shared.start(dataRoot: dataRoot) }
    }

    private func start(dataRoot root: URL) {
        guard flight == nil, !stopped else { return }
        flight = Task.detached(priority: .utility) { [self] in
            await night(dataRoot: root)
            await finished()
        }
    }

    private func finished() { flight = nil }

    /// Quit: Stop cancels the pass (no new turn, replay or keep starts) and
    /// waits for its settlement (its ledger and trace row are written).
    func stop() async {
        stopped = true
        let pass = flight
        pass?.cancel()
        await pass?.value
    }

    /// Unattended work may start now: not stopped, and Autonomy still on.
    /// Read before every turn and door call, not once per pass, so switching
    /// it off stops the next one.
    private static func allowed(_ root: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: root)
    }

    private func night(dataRoot root: URL) async {
        guard await Self.allowed(root) else {
            return nativeLog("[practice] the night's practice waits: Autonomy is off or the app is quitting")
        }
        let now = Date()
        let events: [TurnTraceEvent]
        do {
            let read = try await TurnTraceRecentReader(dataRootOverride: root).read(now: now,
                since: now.addingTimeInterval(-Double(TurnTraceRetention.defaultKeepDays) * 86_400), holding: ["tool.dispatch", "tool.dispatch.closed"])
            guard read.completeSequences else {
                return nativeLog("[practice] incomplete trace coverage; nomination waits (malformed %d, partial %@, truncated %@)",
                    read.malformedRows, String(read.trailingPartialLine), String(read.truncated))
            }
            events = read.events
        } catch {
            return nativeLog("[practice] the night's practice did not run: the turn traces did not read (%@)", error.localizedDescription)
        }
        var helpers: [String: UUID] = [:]
        let byAgent = TurnPractice.turns(events) { session in
            let helper = BotDefinition.id(forSession: session)
            let principal = TurnPractice.principal(helper: helper)
            if let helper { helpers[principal] = helper }
            return principal
        }
        var summary: [String: JSONValue] = [:]
        for principal in Set(byAgent.keys).union(TurnPractice.principals(root)).sorted() {
            guard !Task.isCancelled else { break }
            summary[principal] = await pass(principal, turns: byAgent[principal] ?? [], helper: helpers[principal], root: root, now: now)
        }
        TurnTraceBus.fire(TurnTraceEvent(turnId: "practice-" + UUID().uuidString.lowercased(), kind: "practice.night",
            sessionId: ResidentWake.session, surface: "chat", payload: .object(summary)))
    }

    /// One agent's night: nominate, record, offer, verify, admit.
    private func pass(_ principal: String, turns: [TurnPractice.Turn], helper: UUID?, root: URL, now: Date) async -> JSONValue {
        var ledger: TurnPractice.Ledger
        do { ledger = try TurnPractice.ledger(root, principal: principal) } catch {
            nativeLog("[practice] %@'s practice ledger did not read; it is left as it is: %@", principal, error.localizedDescription)
            return .object(["status": .string("ledger_unreadable"), "detail": .string(error.localizedDescription)])
        }
        let nominated = TurnPractice.nominate(turns, succeeded: ChatToolOutcome.ExactResultClass.succeeded.rawValue)
        ledger.merge(nominated.nominees, tested: nominated.tested, bar: nominated.bar, turns: turns.count, at: now)
        // Saved first, so the tape starts recording tonight's nominees at once.
        guard await save(ledger, root: root) else { return .object(["status": .string("ledger_unwritable")]) }
        let tape = TurnPractice.tape(root, principal: principal)
        for index in ledger.candidates.indices {
            guard !Task.isCancelled else { break }
            var candidate = ledger.candidates[index]
            await advance(&candidate, ledger: &ledger, principal: principal, turns: turns, tape: tape.rows, helper: helper, root: root)
            guard candidate != ledger.candidates[index] else { continue }
            candidate.updatedAt = Date()
            ledger.candidates[index] = candidate
            await save(ledger, root: root)
        }
        return .object([
            "turns": .int(Int64(turns.count)), "tested": .int(Int64(ledger.tested)), "bar": .double(ledger.bar),
            "unreadable_tape_rows": .int(Int64(tape.unreadable)),
            "candidates": .array(ledger.candidates.prefix(12).map { candidate -> JSONValue in
                var fields: [String: JSONValue] = ["key": .string(candidate.key), "state": .string(candidate.state),
                    "count": .int(Int64(candidate.count)), "seen": .int(Int64(candidate.seen)), "examples": .int(Int64(candidate.examples)),
                    "partial": .int(Int64(candidate.partial ?? 0))]
                if let ability = candidate.ability { fields["ability"] = .string(ability) }
                if let detail = candidate.detail { fields["detail"] = .string(String(detail.prefix(300))) }
                return .object(fields)
            }),
        ])
    }

    /// The ledger is the pass's record: written through `settle`, so a Stop
    /// mid-pass still leaves what each candidate came to.
    @discardableResult
    private func save(_ ledger: TurnPractice.Ledger, root: URL) async -> Bool {
        await settle {
            do { try TurnPractice.save(ledger, dataRoot: root); return true }
            catch {
                nativeLog("[practice] %@'s practice ledger was not saved: %@", ledger.principal, error.localizedDescription)
                return false
            }
        }
    }

    private func advance(_ candidate: inout TurnPractice.Candidate, ledger: inout TurnPractice.Ledger,
                         principal: String, turns: [TurnPractice.Turn], tape: [String: TurnPractice.TapeRow], helper: UUID?, root: URL) async {
        if ["staged", "verified", "waiting_owner", "admitted", "off"].contains(candidate.state) {
            return await conclude(&candidate, root: root)
        }
        guard candidate.records else { return }
        // A version saved under this practice the ledger never heard of (a
        // keep moment cut at its bound, a quit between save and ledger) is its own.
        if adopt(&candidate, principal: principal, root: root) { return await conclude(&candidate, root: root) }
        let found = TurnPractice.examples(of: candidate.symbols, in: turns, tape: tape, since: candidate.nominatedAt)
        candidate.seen = found.seen
        candidate.examples = found.examples.count
        candidate.partial = found.examples.filter(\.partial).count
        let evidence: String
        do { evidence = try TurnPractice.evidence(Array(found.examples.prefix(Self.packetExamples))) }
        catch { candidate.detail = "Its evidence could not be serialized: " + error.localizedDescription; return }
        if candidate.state == "blocked" {
            guard candidate.blockedEvidence != evidence else { return }
            candidate.state = "nominated"; candidate.detail = nil
        }
        // Two replayable examples at least (one cannot tell a constant from a flow);
        // offered again only once its examples have doubled since the last offer.
        guard found.examples.count >= 2, candidate.offeredAt.map({ found.examples.count / 2 >= $0 }) ?? true else { return }
        var packet: [TurnPractice.Example] = [], packetWords: String?
        for example in found.examples.prefix(Self.packetExamples) {
            let proposed = packet + [example]
            let flow = TurnPractice.valueFlow(proposed)
            let steer = Array(Set(proposed.flatMap { $0.calls.flatMap(\.steer) })).sorted()
            // The actual packet includes framing, flow, provenance and omissions.
            let words: String
            do { words = try Self.words(candidate, packet: proposed, flow: flow, steer: steer) }
            catch { candidate.detail = "Its packet could not be serialized: " + error.localizedDescription; return }
            guard words.utf8.count <= Self.packetBytes else { continue }
            packet = proposed
            packetWords = words
        }
        guard packet.count >= 2, let packetWords else {
            candidate.state = "blocked"; candidate.detail = "Its examples are too large for one packet."
            candidate.blockedEvidence = evidence
            return
        }
        let flow = TurnPractice.valueFlow(packet)
        if TurnPractice.mostlyJudgment(flow) {
            let judged = flow.filter { $0.source == .judgment }.count
            candidate.state = "blocked"
            candidate.blockedEvidence = evidence
            candidate.detail = "\(judged) of the \(flow.count) arguments of its later calls were her own judgment each time: it saves no thought."
            return
        }
        // Switched off since the pass began, or quitting: no new turn starts.
        guard await Self.allowed(root) else { return }
        let offered = Date()
        do {
            guard try ledger.offersThisNight(at: offered) < Self.offersPerNight else { return }
        } catch { candidate.detail = error.localizedDescription; return }
        // Charge the existing ledger before handing work to a model. A stop,
        // failed keep, removed candidate or app relaunch cannot refill it.
        ledger.offerTimes = (ledger.offerTimes ?? []) + [offered]
        guard await save(ledger, root: root), !Task.isCancelled else { return }
        let steer = Array(Set(packet.flatMap { $0.calls.flatMap(\.steer) })).sorted()
        let compiling = Parts.Compiling(key: candidate.key, principal: principal,
            examples: packet.map { $0.calls.compactMap(\.fixtureCall) }, steer: steer, operations: candidate.operations)
        let ended = await keep(compiling, words: packetWords, helper: helper, root: root)
        guard let saved = compiling.saved else {
            if adopt(&candidate, principal: principal, root: root) { return await conclude(&candidate, root: root) }
            switch ended {
            case .answered(let reply):
                candidate.state = "declined"; candidate.offeredAt = found.examples.count
                candidate.detail = reply.split(separator: "\n").first.map { String($0.prefix(300)) } ?? "She kept nothing."
            case .bounded(let bound):
                candidate.state = "declined"; candidate.offeredAt = found.examples.count
                candidate.detail = "Her keep moment reached its bound (\(bound)) before she kept anything."
            case .stopped(let why), .failed(let why):
                // Not an answer: offered again on a later night, unchanged.
                candidate.detail = "Her keep moment did not finish: " + String(why.prefix(280))
            }
            return
        }
        candidate.offeredAt = found.examples.count
        candidate.state = "staged"; candidate.ability = saved.id; candidate.version = saved.digest; candidate.detail = nil
        await conclude(&candidate, root: root)
    }

    /// How a keep moment ended: she answered; it reached its bound; Stop
    /// ended it; or it failed.
    enum KeepEnd: Sendable { case answered(String), bounded(String), stopped(String), failed(String) }

    private static func keepDeadline<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let lifetime = TurnBodyLifetime<T>()
        do {
            let result = try await TurnDeadline.withThrowingDeadline(seconds: seconds) { try await lifetime.run(work) }
            await lifetime.finish()
            return result
        } catch {
            await lifetime.finish()
            throw error
        }
    }

    /// The agent's own keep moment for one practice: her turn on her resident
    /// session, or the helper's own turn, with the practice bound so its save
    /// is staged against the tape.
    ///
    /// Bounded by the existing owners of a turn's work, never a counter of our
    /// own: the output allowance every model request of one turn shares
    /// (`TurnTokenBudget`; every round spends from it, so it bounds the rounds
    /// too) and the active-work ceiling (`TurnDeadline`, paused while a card
    /// waits on the person). Her night turn takes the app's ceiling for one
    /// unattended run (`BotRunLimits`: 32,000 output tokens, 120 s of work),
    /// the most a helper's run may be given: it writes one ability from one
    /// packet, one run's work. A helper's turn keeps its own run budget and
    /// ceiling. At the bound the loop ends the turn and settles it as any
    /// spent budget or Stop does (what was produced stays; a save it made is
    /// staged, and adopted from the store if it lands after the bound).
    private func keep(_ compiling: Parts.Compiling, words: String, helper: UUID?, root: URL) async -> KeepEnd {
        let engine = NativeAgentEngine.forRoot(root)
        let budget = TurnTokenBudget(tokens: BotRunLimits.maximumTokens)
        do {
            if let helper {
                let bot = try BotDefinitionStore(dataRoot: root).get(helper)
                guard bot.deleted != true, !bot.paused else { return .failed("Its helper is paused or deleted.") }
                let session = engine.standingBotSession()
                let reply = try await Self.keepDeadline(seconds: bot.budget.seconds) {
                    try await Parts.$compiling.withValue(compiling) { try await session(bot, words) }
                }
                if reply.status == .stopped { return Task.isCancelled ? .stopped("Stop") : .bounded("its run budget") }
                return .answered(reply.reply)
            }
            let client = engine.chatClient(profile: .background, approvalFiler: NativeAgentChatApprovalFiler(dataRoot: root))
            let reply = try await Self.keepDeadline(seconds: BotRunLimits.maximumSeconds) {
                try await Parts.$compiling.withValue(compiling) {
                    try await LLMCallContext.$turnTokenBudget.withValue(budget) {
                        try await ChatToolSessionContext.$envelope.withValue(TurnEnvelope.native("practice")) {
                            try await client.runEphemeralToolTurn(message: words, fileAccess: "auto",
                                verifiedSessionId: ResidentWake.session, surface: "chat").output
                        }
                    }
                }
            }
            return budget.exhausted ? .bounded("\(BotRunLimits.maximumTokens) output tokens") : .answered(reply)
        } catch is TurnDeadline.DeadlineExceeded {
            return .bounded("its active-work ceiling")
        } catch {
            if Task.isCancelled || error is CancellationError { return .stopped("Stop") }
            if budget.exhausted { return .bounded("\(BotRunLimits.maximumTokens) output tokens") }
            nativeLog("[practice] the keep moment for %@ did not complete: %@", compiling.key, error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    /// The version the store holds for this practice, by its manifest's
    /// `compiled` key and agent, when it is not the one the ledger names:
    /// the store is the truth, the ledger reconciles to it.
    private func adopt(_ candidate: inout TurnPractice.Candidate, principal: String, root: URL) -> Bool {
        guard let rows = try? Parts(root: root).rows() else { return false }
        for row in rows {
            let review = Parts.fields(row["keepReview"] ?? .null)
            let compiled = Parts.fields(Parts.fields(review["manifest"] ?? .null)["compiled"] ?? .null)
            guard Parts.string(compiled, "key") == candidate.key, Parts.string(compiled, "principal") == principal,
                  let id = Parts.string(row, "id"), let version = Parts.string(row, "candidateDigest") ?? Parts.string(review, "version"),
                  version != candidate.version else { continue }
            candidate.state = "staged"; candidate.ability = id; candidate.version = version; candidate.detail = nil
            return true
        }
        return false
    }

    /// A staged version: replayed from its tape, then kept by the keep law.
    private func conclude(_ candidate: inout TurnPractice.Candidate, root: URL) async {
        guard let id = candidate.ability, let version = candidate.version else { return }
        let parts = Parts(root: root)
        let row: [String: JSONValue]
        do {
            guard let found = try parts.row(id) else {
                candidate.state = "declined"; candidate.detail = "\(id) is gone: dropped."
                return
            }
            row = found
        } catch { candidate.detail = "Her abilities did not read: " + error.localizedDescription; return }
        let waiting = Parts.string(row, "candidateDigest")
        if Parts.string(row, "codeFingerprint") == version, waiting == nil {
            let on = row["status"] == .string("active")
            candidate.state = on ? "admitted" : "off"; candidate.detail = on ? nil : "Kept, then switched off."
            return
        }
        guard waiting == version else {
            candidate.state = "revised"; candidate.detail = "\(id) has another version now."
            return
        }
        // The owner's card waits on its own; an admitted or switched-off one is settled.
        guard ["staged", "verified"].contains(candidate.state) else { return }
        // A replay or a keep is unattended work too: none starts once it is off or quitting.
        guard await Self.allowed(root) else { return }
        if candidate.state == "staged" {
            if row["candidateValidation"] != .string("replayed") {
                let replay = await door("ability.validate", ["id": .string(id)], root: root)
                guard ChatToolOutcome.outputLooksSuccessful(replay) else {
                    candidate.state = "failed"
                    candidate.detail = Parts.string(Parts.fields(replay), "detail").map { String($0.prefix(300)) } ?? "Its tape replay did not pass."
                    return
                }
            }
            candidate.state = "verified"
            guard await Self.allowed(root) else { return }
        }
        let kept = await door("ability.enable", ["id": .string(id), "version": .string(version)], root: root)
        if let after = try? parts.row(id), Parts.string(after, "codeFingerprint") == version, after["status"] == .string("active") {
            candidate.state = "admitted"; candidate.detail = nil
        } else if ChatToolOutcome.isWaitingOnPerson(kept) || Parts.fields(kept)["needs_owner"] == .bool(true)
                    || Parts.fields(kept)["reason"] == .string("owners_call") {
            candidate.state = "waiting_owner"
            candidate.detail = Parts.string(Parts.fields(kept), "detail").map { String($0.prefix(300)) }
        } else {
            candidate.detail = Parts.string(Parts.fields(kept), "detail").map { String($0.prefix(300)) } ?? "Keeping it did not complete."
        }
    }

    /// One call through her gated app door, as her own unattended work (a
    /// part's wake runs the same way). It has no turn, so it is not practice.
    private func door(_ action: String, _ args: [String: JSONValue], root: URL) async -> JSONValue {
        do {
            return try await NativeAgentEngine.forRoot(root).tools.withPartDoor(envelope: .native("practice")) {
                guard let dispatch = AppDoorReentry.perform else { throw PartError.invalid("The part door has no dispatcher.") }
                return try await dispatch("app", ["action": .string(action), "args": .object(args)])
            }
        } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }

    /// The packet her keep moment reads: the route, where each later argument
    /// came from, and the examples exactly as they went.
    static func words(_ candidate: TurnPractice.Candidate, packet: [TurnPractice.Example], flow: [TurnPractice.Slot], steer: [String]) throws -> String {
        let day = ISO8601DateFormatter.string(from: candidate.nominatedAt, timeZone: .current, formatOptions: [.withFullDate])
        let calls = candidate.operations.enumerated().map { "\($0.offset + 1). " + Self.shown($0.element) }.joined(separator: "\n")
        let sources = flow.map { slot -> String in
            let at = "call \(slot.call) args" + (slot.path.isEmpty ? "" : " " + slot.path)
            switch slot.source {
            case .constant: return "- \(at): the same value every time"
            case .result(let call, let path): return "- \(at): call \(call)'s result at \(path.isEmpty ? "(whole)" : path)"
            case .argument(let call, let path): return "- \(at): call \(call)'s arguments at \(path.isEmpty ? "(whole)" : path)"
            case .judgment: return "- \(at): your own choice each time (no earlier value held it), so an input"
            }
        }.joined(separator: "\n")
        let examples = packet.enumerated().map { index, example -> JSONValue in
            .object(["example": .int(Int64(index + 1)), "calls": .array(example.calls.compactMap { row -> JSONValue? in
                guard case .object(var call)? = row.fixtureCall else { return nil }
                if !row.omitted.isEmpty { call["omitted"] = .array(row.omitted.map { .string($0.path + " (" + $0.reason + ")") }) }
                return .object(call)
            })])
        }
        let json = try JSONValue.array(examples).serialize(pretty: false)
        var lines = [
            try completionPolicy("nightly-practice-keep", section: "prompt", arguments: [String(candidate.seen), day, String(candidate.symbols.count)]),
            calls,
        ]
        if !sources.isEmpty { lines += [try completionPolicy("nightly-practice-keep", section: "sources"), sources] }
        if !steer.isEmpty {
            lines.append(try completionPolicy("nightly-practice-keep", section: "steer", arguments: [steer.joined(separator: ", ")]))
        }
        lines += [
            try completionPolicy("nightly-practice-keep", section: "keep"),
            try completionPolicy("nightly-practice-keep", section: "examples", arguments: [String(packet.count)]),
            json,
        ]
        return lines.joined(separator: "\n\n")
    }

    private static func shown(_ operation: String) -> String {
        switch operation {
        case "read": return "app.read(…)"
        case "find": return "app.find(…)"
        default: return operation + "(…)"
        }
    }
}
