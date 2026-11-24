import SenseCore
import MacNerves
import MindCore
import DeskCore
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import os
import NativeAgentShared
// Blueprint: | `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: opens the agent's turn part and its `TurnStem` (`TurnStem+Opening.swift`), drives the stem (`TurnStem+Effects.swift`, `TurnStem+ModelRound.swift`) and settles the part's run); the familiarity nerve's `practiceRoute`, `practiceSignal` and `coveringAbility` (the active ability that already makes a route, or the step its run failed at); `joinedProse`; `took` is the after-turn line, and each part called records its rounds |

extension SwiftNativeTurnEngine {
    func executeContinuationTurnBody(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil,
        /// Request-scoped identity keeps ephemeral turns distinct without inventing a transcript session.
        toolSessionId: String? = nil,
        runId: String? = nil,
        llm: any LLMClient,
        tools: any ToolDispatchClient,
        context: LazyContextBox,
        progress: ToolProgress? = nil,
        onDelivery: (@Sendable () async -> Void)? = nil,
        cancelFlagPath: URL? = nil,
        /// Asked before every provider call, retries included. Admission errors
        /// stay with their owner; provider recovery cannot override them.
        providerAdmission: (@Sendable () async throws -> Void)? = nil,
        turn: Turn, work: ChatTurnWork, call: LLMCall
    ) async throws -> TurnEngineResult {
        let partRounds = AbilityRounds()
        return try await holding(turn.with(\.userText, userMessage).with(\.abilityRounds, partRounds)) { turn in
        try await holding(work.with(\.senseReads, work.senseReads ?? SenseTurnReads())) { work in
        // Prepared document text and image-only turns need no caption.
        if context.opening.userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && context.opening.imageBlocks.isEmpty {
            throw TurnEngineError.emptyMessage
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        var dispatchTrace = ContextStageTrace(turn: turn)
        // The turn part decides; this loop executes effects. Recovery rebuilds the log and reports in-flight effects as resumed.
        let restarted = turn.resumingCheckpoint.flatMap {
            $0.runId == runId && $0.turnId == turn.id ? $0 : nil
        }
        let stem: TurnStem, inFlight: Bool
        do {
            // Once the stem holds the part this copy is gone, so nothing after the opening can read or settle a stale part.
            var part = try await TurnPart(dataRoot: remPinsDataRoot ?? defaultDataRoot(), surface: surface, stop: cancelFlagPath,
                                          context: context, log: restarted?.log ?? [], turn: turn, deadlines: work.deadlines)
            do {
                inFlight = try await openPart(&part, gathered: context.opening, surface: surface, turn: turn)
                stem = try await openStem(part: part, dispatchTrace: &dispatchTrace, surface: surface, userMessage: userMessage,
                    sessionId: sessionId, toolSessionId: toolSessionId, runId: runId, llm: llm, tools: tools, gathered: context.opening,
                    progress: progress, onDelivery: onDelivery, cancelFlagPath: cancelFlagPath, providerAdmission: providerAdmission,
                    startNs: startNs, restarted: restarted, turn: turn, work: work, call: call, partRounds: partRounds)
            } catch {
                var status = Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) || error is CancellationError ? "stopped" : "error"
                if case TurnEngineError.streamCancelled = error { status = "stopped" }
                settleTurnPart(part, rounds: partRounds, status: status, turn: turn)
                part.tellAgent()
                throw error
            }
        }
        defer { stem.part.tellAgent() }
        do {
        do {
        defer { turn.observation?.record(stem.tally.counters, dispatches: stem.tally.dispatches, reply: stem.voice.visibleText) }
        if let restarted { try await replayRestart(stem, restarted, inFlight: inFlight) }
        guard let result = try await drive(stem) else {
            throw TurnEngineError.turnPartFailed("Its steps ended the turn without a reply.end.")
        }
        await stem.wire.bookkeeping.value
        let reason = result.resolvedTerminalReason(dataRoot: remPinsDataRoot)
        // A turn that ends waiting on the person asked correctly: it counts as a clean run, never against its version.
        settleTurnPart(stem.part, rounds: partRounds,
            status: reason == .replyCompleted || reason.state == .waiting ? "ok" : reason == .cancelled ? "stopped" : "error", turn: turn)
        return result
        } catch {
            await stem.wire.bookkeeping.value
            throw error
        }
        } catch {
            var status = Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) || error is CancellationError ? "stopped" : "error"
            if case TurnEngineError.streamCancelled = error { status = "stopped" }
            settleTurnPart(stem.part, rounds: partRounds, status: status, turn: turn)
            throw error
        }
        }
        }
    }

    /// Records the turn program's run and each part version's rounds, however the turn ended.
    func settleTurnPart(_ part: TurnPart, rounds partRounds: AbilityRounds, status: String, turn: Turn) {
        do {
            let store = AbilityStore(dataRoot: remPinsDataRoot ?? defaultDataRoot())
            do { try store.recordRun(id: TurnPart.id, version: part.version,
                receipt: .object(["status": .string(status), "reason": .string(status == "stopped" ? "cancelled" : "")]), turn: turn) }
            catch { nativeLog("The turn program's run was not recorded: %@", error.localizedDescription) }
            for (version, rounds) in try partRounds.take().sorted(by: { ($0.key.id, $0.key.key) < ($1.key.id, $1.key.key) }) {
                // The rounds ledger owns repair for its own failed writes; one version's failure does not discard its siblings.
                do { try store.recordRounds(id: version.id, version: version.key, rounds: rounds, turn: turn) }
                catch { nativeLog("The agent's part %@'s rounds were not recorded: %@", version.id, error.localizedDescription) }
            }
        } catch { nativeLog("This turn's ability rounds were not recorded: %@", error.localizedDescription) }
    }

    /// Only landed hand work forms a practice; incidental reads and arguments cannot count. A lone write is just using the tool:
    /// a route needs two steps, or one call made 3+ rounds in a row.
    nonisolated static func practiceRoute(_ dispatches: [TurnEngineResult.ToolDispatchRecord],
        repeated: (calls: [JSONValue], call: String, count: Int)) throws -> (signature: String, sequence: [JSONValue], hand: Bool, looped: Bool)? {
        func identity(_ name: String, _ input: [String: JSONValue]) -> JSONValue {
            var ids = [JSONValue.string(name)]
            if name == "app", case .string(let action)? = input["action"] { ids.append(.string(action)) }
            return .array(ids)
        }
        // Use each landed action ID in batches and scripts so unrelated `app` calls cannot look like repetition.
        func steps(_ record: TurnEngineResult.ToolDispatchRecord) -> [JSONValue] {
            if record.name != "app" || record.input["action"]?.stringValue?.isEmpty == false {
                return [identity(record.name, record.input)]
            }
            let fields = record.result.objectValue ?? [:]
            let rows = fields["receipts"]?.arrayValue ?? fields["calls"]?.arrayValue ?? []
            return rows.compactMap { row -> JSONValue? in
                guard let step = row.objectValue,
                      Self.landedEffect(row).map({ ["write", "irreversible"].contains($0) }) == true,
                      let id = step["action"]?.stringValue ?? step["call"]?.stringValue, !id.isEmpty,
                      ToolNameAliases.authoredTool(id) == nil else { return nil }
                return .array([.string("app"), .string(id)])
            }
        }
        var sequence = dispatches.filter { record in
            let action = record.name == "app" ? record.input["action"]?.stringValue ?? "" : ""
            guard ToolNameAliases.authoredTool(record.ranCall.tool) == nil,
                  ToolNameAliases.authoredTool(action) == nil else { return false }
            return Self.landedEffect(record.result).map { ["write", "irreversible"].contains($0) } ?? false
        }.flatMap(steps)
        let hand = !sequence.isEmpty
        if sequence.isEmpty, repeated.count >= 3, repeated.calls.count == 1,
           let call = repeated.calls.first?.objectValue, let name = call["name"]?.stringValue,
           let input = call["input"]?.objectValue {
            sequence = [identity(name, input)]
        }
        let looped = repeated.count >= 3 && repeated.calls.count == 1
        guard sequence.count >= 2 || (sequence.count == 1 && looped) else { return nil }
        return (try JSONValue.array(sequence).serialize(pretty: false), sequence, hand, looped)
    }

    /// The familiarity nerve: a route met in an earlier turn returns its practice signal for the agent's next thought in this turn, naming the active
    /// ability that already makes it (to run) or whose run of it failed (to repair). A first meeting is recorded and stays quiet; a failed read is
    /// traced and the turn goes on.
    nonisolated static func practiceSignal(_ dispatches: [TurnEngineResult.ToolDispatchRecord],
        repeated: (calls: [JSONValue], call: String, count: Int), checked: inout Set<String>, dataRoot: URL, turn: Turn) -> JSONValue? {
        let practice: (signature: String, sequence: [JSONValue], hand: Bool, looped: Bool)
        do {
            guard let route = try practiceRoute(dispatches, repeated: repeated), checked.insert(route.signature).inserted else { return nil }
            practice = route
        } catch {
            TurnTraceBus.fireFromContext(kind: "practice.keep", payload: .object(["failed": .string(error.localizedDescription)]), turn: turn)
            return nil
        }
        let sequence = practice.sequence
        do {
            let first = try !FamiliarLines.firstMet(["practice: " + practice.signature], dataRoot: dataRoot).isEmpty
            var noted = false
            var covering: JSONValue?
            defer {
                var payload: [String: JSONValue] = [
                    "practice": .string(practice.signature), "met": .string(first ? "first" : "again"), "noted": .bool(noted),
                ]
                if let fields = covering?.objectValue {
                    payload["ability"] = .object(fields.filter { ["id", "worked", "failed"].contains($0.key) })
                }
                TurnTraceBus.fireFromContext(kind: "practice.keep", payload: .object(payload), turn: turn)
            }
            guard !first else { return nil }
            let ability = try coveringAbility(sequence, dataRoot: dataRoot)
            covering = ability
            noted = true
            var signal: [String: JSONValue] = ["route": .string(practice.signature), "hand": .bool(practice.hand)]
            if practice.looped { signal["loop"] = .object(["call": .string(repeated.call), "count": .int(Int64(repeated.count))]) }
            if let ability { signal["ability"] = ability }
            return .object(signal)
        } catch {
            TurnTraceBus.fireFromContext(kind: "practice.keep", payload: .object([
                "practice": .string(practice.signature), "failed": .string(error.localizedDescription)]), turn: turn)
            return nil
        }
    }

    /// The active ability whose recorded route makes exactly this hand work: its steps that are not reads are these, in order, and nothing more,
    /// so an ability that would also send is never named for hand work that did not. Each ability's newest covering run decides (live runs before
    /// validation), by that run's own outcome: one that completed or passed is hers to use; otherwise the first such ability comes with the step its
    /// run failed at, to repair. Nil when no ability covers it.
    nonisolated static func coveringAbility(_ sequence: [JSONValue], dataRoot: URL) throws -> JSONValue? {
        guard case .array(let abilities) = try AbilityStore(dataRoot: dataRoot).registry(kind: .part) else {
            throw TurnEngineError.turnPartFailed("The ability index did not return rows for practice.")
        }
        // A recorded step is a read when its call says it had no effect or its action only reads; every other step must be hand work she did.
        let readVerbs: Set<String> = ["read", "query", "list", "find", "look", "search", "names", "get", "recall", "status"]
        func covers(_ calls: [JSONValue]) -> Bool {
            let route = calls.compactMap { call -> JSONValue? in
                guard let fields = call.objectValue, let label = fields["call"]?.stringValue else { return .null }
                if label.hasPrefix("read ") || label.hasPrefix("find ") || fields["effects"] == .string("none") { return nil }
                if let verb = label.split(separator: ".").last, readVerbs.contains(String(verb)) { return nil }
                return .array([.string("app"), .string(label)])
            }
            return route == sequence
        }
        var broken: JSONValue?
        for ability in abilities {
            guard let row = ability.objectValue, row["status"] == .string("active"), let id = row["id"]?.stringValue else { continue }
            let named: [String: JSONValue] = ["id": .string(id), "description": row["description"] ?? .string("")]
            let operations = (row["learned"]?.objectValue?["use"]?.objectValue?["operations"]?.objectValue ?? [:]).values.compactMap(\.objectValue)
            let validated = (row["validation_evidence"]?.objectValue?["runs"]?.arrayValue ?? []).compactMap(\.objectValue)
            var runs: [(calls: [JSONValue], worked: Bool, outcome: String, at: String)] = operations.map { operation in
                // The newest run's own outcome; a record kept before it was written is read only when its counters name one outcome.
                let outcomes = ["completed", "error", "cut", "network", "refused"].filter { (operation[$0]?.exactIntegerValue ?? 0) > 0 }
                let last = operation["last"]?.stringValue ?? (outcomes.count == 1 ? outcomes[0] : "unknown")
                return (calls: operation["scope"]?.objectValue?["calls"]?.arrayValue ?? [], worked: last == "completed",
                        outcome: last, at: operation["at"]?.stringValue ?? "")
            }
            runs += validated.map { run in
                (calls: run["calls"]?.arrayValue ?? [], worked: run["status"] == .string("ok"), outcome: run["status"]?.stringValue ?? "error", at: "")
            }
            // ISO times order as text; validation runs carry none and sort before every live run.
            if let run = runs.filter({ covers($0.calls) }).max(by: { $0.at < $1.at }) {
                if run.worked { return .object(named.merging(["worked": .bool(true)]) { _, new in new }) }
                guard broken == nil else { continue }
                // The step it failed at: its first call that did not come back ok, else past its last call.
                let step = run.calls.compactMap(\.objectValue).first {
                    ![JSONValue.string("ok"), .string("preview"), .string("answered")].contains($0["status"] ?? .null)
                }
                let at = step.map { call -> String in
                    let line = call["line"]?.exactIntegerValue.map { " at line \($0)" } ?? ""
                    return (call["call"]?.stringValue ?? "a call") + line + " (" + (call["status"]?.stringValue ?? run.outcome) + ")"
                } ?? "after its last call (" + run.outcome + ")"
                broken = .object(named.merging(["failed": .string(at)]) { _, new in new })
            }
        }
        return broken
    }

    nonisolated static func took(rounds: Int, tokens: Int?, seconds: Int, repeated: (call: String, count: Int)) -> String {
        let amount: String
        if let tokens {
            amount = tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1_000_000)
                : tokens >= 1_000 ? "\(tokens / 1_000)k" : "\(tokens)"
        } else { amount = "unavailable" }
        var line = "This took \(rounds) round\(rounds == 1 ? "" : "s")" + (tokens == nil ? ", token usage unavailable" : ", \(amount) tokens")
            + (seconds < 90 ? ", \(seconds) seconds" : ", \(Int((Double(seconds) / 60).rounded())) minutes")
        if repeated.count > 1 { line += "; \(repeated.count) rounds in a row called \(repeated.call)" }
        return line + "."
    }

    /// One blank line separates retained prose and anchors the commentary offset.
    nonisolated static func joinedProse(_ head: String, _ tail: String) -> String {
        let head = String(head[..<(head.lastIndex { !$0.isWhitespace }.map(head.index(after:)) ?? head.startIndex)])
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty || tail.isEmpty ? head + tail : head + "\n\n" + tail
    }
}
