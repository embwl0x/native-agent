import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Transcripts
import TurnTrace
import NativeAgentShared
// Blueprint: | `ChatCompactionDistiller.swift` | One checked compaction route executes concurrent chunks; all ordered blocks commit or none, with coverage, provenance and receipt notes; shared source/output bounds and 40,000-character history read allowance; Transcripts owns durable replacement/index writes |

/// Recollection from the preserved source, with a repair owed on failure.
/// A turn waits on a pending one a foreground compaction wrote; the aging lane
/// distills ahead of its replacement and never leaves one pending.
public struct ChatCompactionDistiller: Sendable {
    let dataRoot: URL
    /// One checked group selection for planning and all of its completions.
    let summaryRouteResolver: @Sendable (String) async throws -> TurnRouteAdmission
    let llm: any LLMClient
    let now: @Sendable () -> Date

    public static let distillSurface = "compaction"
    /// Read allowance for existing recollections; never lower it to a new
    /// chunk's writing allowance and clip the recollections already on disk.
    static let maxSummaryChars = 40_000
    /// ~8k source tokens -> ~1.6k output tokens, independently in parallel.
    static let maxSourceChunkChars = 32_000
    static let sourceToBlockRatio = 5
    static let sourceToBlockMinimumRatio = 10
    /// Headroom over the 1/5 target, still proportional for smaller chunks.
    static let sourceToBlockCapRatio = 3
    static let maxBlockChars = maxSourceChunkChars / sourceToBlockCapRatio

    public init(
        dataRoot: URL,
        summaryRouteResolver: @escaping @Sendable (String) async throws -> TurnRouteAdmission,
        llm: any LLMClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.summaryRouteResolver = summaryRouteResolver
        self.llm = llm
        self.now = now
    }

    @discardableResult public func distill(
        sessionId: String,
        summaryRowId: String,
        backupPath: String,
        rows: [JSONValue],
        turnModel: String,
        surface: String,
        runId: String?
    ) async -> Bool {
        let key = dataRoot.standardizedFileURL.path + "/" + sessionId + "/" + summaryRowId
        return await PendingDistillations.shared.run(key) {
            await completeDistillation(sessionId: sessionId, summaryRowId: summaryRowId, backupPath: backupPath,
                rows: rows, turnModel: turnModel, surface: surface, runId: runId)
        }
    }

    private func completeDistillation(sessionId: String, summaryRowId: String, backupPath: String,
                                     rows: [JSONValue], turnModel: String, surface: String, runId: String?) async -> Bool {
        await performDistillation(
            sessionId: sessionId, summaryRowId: summaryRowId, rows: rows, turnModel: turnModel,
            surface: surface, runId: runId
        )
        guard !Task.isCancelled else { return false }
        let operation = "chat.compact:" + sessionId + ":" + summaryRowId
        do {
            let rows = try await SwiftNativePersistenceCore.readJSONL(messagesPath(sessionId: sessionId))
            let ready = rows.contains {
                guard case .object(let row) = $0, row["id"] == .string(summaryRowId),
                      case .object(let metadata)? = row["metadata"] else { return false }
                return metadata["distill"] == .string("llm")
            }
            if ready {
                RepairOwed.settle(dataRoot, operation: operation,
                    evidence: .init(source: "chat/messages/\(sessionId).jsonl", id: summaryRowId))
                return true
            }
        } catch { nativeLog("Recollection readiness could not be read: %@", error.localizedDescription) }
        RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run, operation: operation,
            owner: "chat/messages/\(sessionId).jsonl#\(summaryRowId); providers.memory_and_mind_model",
            words: "Recollection is unavailable. The original turns remain in \(backupPath); no substitute recollection is accepted.",
            nextCall: ToolFailureError.call("app", ["action": .string("chat.compact"),
                "args": .object(["session_id": .string(sessionId)])]))
        return false
    }

    private actor PendingDistillations {
        static let shared = PendingDistillations()
        var active: [String: (task: Task<Bool, Never>, done: ScopedWaiter)] = [:]
        func run(_ key: String, work: @escaping @Sendable () async -> Bool) async -> Bool {
            guard !Task.isCancelled else { return false }
            if let flight = active[key] {
                await flight.done.park()
                return Task.isCancelled ? false : await flight.task.value
            }
            let done = ScopedWaiter()
            let task = Task {
                let result = await work()
                active[key] = nil
                done.resume()
                return result
            }
            active[key] = (task, done)
            return await withTaskCancellationHandler {
                await done.park()
                return Task.isCancelled ? false : await task.value
            } onCancel: { task.cancel() }
        }
    }

    private func performDistillation(
        sessionId: String,
        summaryRowId: String,
        rows: [JSONValue],
        turnModel: String,
        surface: String,
        runId: String?
    ) async {
        guard !rows.isEmpty else {
            await emitDistillTrace(
                sessionId: sessionId, surface: surface, model: turnModel,
                charsIn: 0, charsOut: 0, runId: runId, status: "failed", failure: DistillError.empty
            )
            return
        }

        guard let recollection = await prepareRecollection(
            rows: rows, sessionId: sessionId, turnModel: turnModel,
            surface: surface, runId: runId,
            stillWanted: { try await destinationExists(sessionId: sessionId, summaryRowId: summaryRowId) },
            goneStatus: "row_missing"
        ) else {
            return
        }
        await settle { [self] in
            let model = recollection.model
            let outputChars = recollection.blocks.reduce(0) { $0 + $1.text.count }
            let promptCharsPerPass = recollection.promptCharsPerPass
            let promptChars = promptCharsPerPass.reduce(0, +)
            let thirdPerson = recollection.thirdPerson

            // Replace only the pending destination, under its compound lock.
            let messagesPath = messagesPath(sessionId: sessionId)
            let status: String
            do {
                status = try await SwiftNativePersistenceCore.withFileLock(messagesPath) {
                    let raw = try Data(contentsOf: messagesPath)
                    guard let edited = try ContactThread.editingRow(in: raw, matching: { obj in
                        guard case .string(let id)? = obj["id"],
                              id == summaryRowId,
                              case .object(let meta)? = obj["metadata"],
                              case .string(let kind)? = meta["kind"],
                              kind == "compaction_summary",
                              meta["distill"] == .string("pending")
                        else { return false }
                        return true
                    }, replacement: { obj in
                        guard case .object(let meta)? = obj["metadata"] else { throw CocoaError(.fileReadCorruptFile) }
                        // The "cards kept below" clause, from the count the
                        // compactor wrote (see `recollectionContent`).
                        var preservedCards = 0
                        if case .int(let value)? =
                            meta[InlineInteractionCompactionRetention.preservedMetadataKey] {
                            preservedCards = Int(value)
                        }
                        // All chunks succeeded before the lock. Expand the one
                        // pending destination to ordered blocks in ONE write;
                        // retaining its first id also preserves readiness checks.
                        return Self.recollectionRows(
                            recollection.blocks, template: obj, sessionId: sessionId,
                            model: model, preservedCards: preservedCards
                        )
                    }) else { return "row_missing" }
                    try Task.checkCancellation()
                    try ContactThread.replace(edited, to: messagesPath)
                    return "ok"
                }
            } catch {
                await emitDistillTrace(
                    sessionId: sessionId, surface: surface, model: model,
                    charsIn: promptChars, charsOut: outputChars, runId: runId, status: "failed",
                    promptCharsPerPass: promptCharsPerPass, failure: error
                )
                return
            }

            // In-place rewrites advance transcript ordering so the phone receives the recollection.
            if status == "ok" {
                await Self.publishTranscriptChange(
                    sessionId: sessionId, dataRoot: dataRoot
                )
            }

            await emitDistillTrace(
                sessionId: sessionId, surface: surface, model: model,
                charsIn: promptChars,
                charsOut: status == "ok" ? outputChars : 0,
                runId: runId, status: status,
                thirdPerson: status == "ok" ? thirdPerson : false,
                promptCharsPerPass: promptCharsPerPass
            )
        }
    }

    /// The stored text of a finished recollection. The mechanical header
    /// carried the "cards kept below" clause; the distilled text replaces that
    /// header, so the clause is re-stated from the count the compactor wrote.
    /// Without it the recollection reads as if the preserved cards were folded
    /// away too.
    package static func recollectionContent(_ distilled: String, sourceNote: String, preservedCards: Int) -> String {
        let clause = InlineInteractionCompactionRetention.summaryClause(preservedCount: preservedCards)
        return sourceNote + "\n" + (clause.isEmpty
            ? distilled
            : distilled + "\n[" + clause.trimmingCharacters(in: .whitespaces) + "]")
    }

    /// Source stays attached through preparation so every stored block names
    /// its OWN receipt, coverage and trust provenance, including a split row.
    package struct Block: Sendable {
        let text: String
        let source: [JSONValue]
    }

    package static func recollectionRows(
        _ blocks: [Block], template: [String: JSONValue], sessionId: String,
        model: String, preservedCards: Int
    ) -> [JSONValue] {
        // Whose conversation this is belongs to the whole fold, as it did when a
        // fold wrote one block: a chunk of tool rows alone carries no speaker.
        let provenance = ChatSessionRecollections.continuityProvenance(for: blocks.flatMap(\.source))
        return blocks.enumerated().map { index, block in
            var row = template
            if index > 0 { row["id"] = .string("compact-\(UUID().uuidString.lowercased())") }
            var metadata: [String: JSONValue]
            if case .object(let original)? = row["metadata"] { metadata = original }
            else { metadata = [:] }
            let sourceNote = ChatCompactionRowRendering.receiptSourceNote(block.source, sessionId: sessionId)
            let cards = index == blocks.count - 1 ? preservedCards : 0
            row["content"] = .string(recollectionContent(
                block.text, sourceNote: sourceNote, preservedCards: cards
            ))
            metadata["distill"] = .string("llm")
            metadata["distill_model"] = .string(model)
            metadata["receipt_source_note"] = .string(sourceNote)
            metadata["messages_replaced"] = .int(Int64(block.source.count))
            metadata[ChatSessionRecollections.continuityProvenanceKey] = provenance
            metadata.removeValue(forKey: "distill_backup")
            metadata.removeValue(forKey: "distill_process")
            metadata.removeValue(forKey: "distill_preserved_pending_ids")
            metadata.removeValue(forKey: InlineInteractionCompactionRetention.preservedMetadataKey)
            if cards > 0 {
                metadata[InlineInteractionCompactionRetention.preservedMetadataKey] = .int(Int64(cards))
            }
            let coverage = ChatSessionAutocompactor.coverageRange(block.source)
            metadata[ChatSessionRecollections.coversFromKey] = coverage.from.map { .string($0) }
            metadata[ChatSessionRecollections.coversUntilKey] = coverage.until.map { .string($0) }
            row["metadata"] = .object(metadata)
            return .object(row)
        }
    }

    /// Background recollection precedes locked replacement, preserves raw turns on failure and never blocks a turn.
    package func distillAhead(
        sessionId: String,
        rows: [JSONValue],
        turnModel: String,
        surface: String,
        runId: String?,
        stillCurrent: @escaping @Sendable () async throws -> Bool,
        commit: @escaping @Sendable (_ blocks: [Block], _ model: String) async throws -> Bool
    ) async -> Bool {
        guard let recollection = await prepareRecollection(
            rows: rows, sessionId: sessionId, turnModel: turnModel,
            surface: surface, runId: runId,
            stillWanted: stillCurrent, goneStatus: "source_changed"
        ) else { return false }
        return await settle { [self] in
            let promptChars = recollection.promptCharsPerPass.reduce(0, +)
            let outputChars = recollection.blocks.reduce(0) { $0 + $1.text.count }
            let committed: Bool
            do {
                try Task.checkCancellation()
                committed = try await commit(recollection.blocks, recollection.model)
            } catch {
                await emitDistillTrace(
                    sessionId: sessionId, surface: surface, model: recollection.model,
                    charsIn: promptChars, charsOut: outputChars, runId: runId, status: "failed",
                    promptCharsPerPass: recollection.promptCharsPerPass, failure: error
                )
                return false
            }
            await emitDistillTrace(
                sessionId: sessionId, surface: surface, model: recollection.model,
                charsIn: promptChars,
                charsOut: committed ? outputChars : 0,
                runId: runId, status: committed ? "ok" : "source_changed",
                thirdPerson: committed ? recollection.thirdPerson : false,
                promptCharsPerPass: recollection.promptCharsPerPass
            )
            return committed
        }
    }

    private struct PreparedRecollection: Sendable {
        let blocks: [Block]
        let model: String
        let promptCharsPerPass: [Int]
        let thirdPerson: Bool
    }

    /// `stillWanted` false before a pass ends the work with `goneStatus`: the
    /// recollection's destination (or source) is gone and a completion now
    /// would buy nothing.
    private func prepareRecollection(
        rows: [JSONValue],
        sessionId: String,
        turnModel: String,
        surface: String,
        runId: String?,
        stillWanted: @escaping @Sendable () async throws -> Bool,
        goneStatus: String
    ) async -> PreparedRecollection? {
        // The compaction group owns routing and prompt budgets; an unavailable route leaves recollection owed.
        let route: TurnRouteAdmission
        do {
            route = try await ProviderTurnChoice.$current.withValue(nil) {
                try await summaryRouteResolver(Self.distillSurface)
            }
            guard !route.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !(route.providerId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DistillError.routeUnavailable
            }
        } catch {
            await emitDistillTrace(
                sessionId: sessionId, surface: surface, model: turnModel,
                charsIn: 0, charsOut: 0, runId: runId, status: "failed", failure: error
            )
            return nil
        }
        let model = route.modelId

        var promptCharsPerPass: [Int] = []
        var promptChars = 0
        let blocks: [Block]
        do {
            let plan = Self.buildPlan(
                from: rows,
                budget: try Self.promptBudgetChars(forModel: model, providerID: route.providerId, dataRoot: dataRoot)
            )
            let prompts = try plan.chunks.enumerated().map {
                try Self.composePrompt(chunk: $0.element, index: $0.offset, count: plan.chunks.count)
            }
            promptCharsPerPass = prompts.map(\.count)
            promptChars = promptCharsPerPass.reduce(0, +)
            try Task.checkCancellation()
            guard !plan.chunks.isEmpty else { throw DistillError.empty }
            guard try await stillWanted() else { throw DistillError.sourceChanged }
            // Each chunk has its own proportional output allowance. No
            // serial carry/rewrite: wall time is the slowest chunk. Throwing
            // cancels siblings and the group drains before any durable write.
            blocks = try await withThrowingTaskGroup(of: (Int, Block).self) { group in
                for (index, chunk) in plan.chunks.enumerated() {
                    let prompt = prompts[index]
                    group.addTask {
                        try Task.checkCancellation()
                        guard try await stillWanted() else { throw DistillError.sourceChanged }
                        let output = try await self.callLLM(route: route, prompt: prompt)
                        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { throw DistillError.empty }
                        // The minimum is the prompt's ask, not a verdict: a short block is still her
                        // recollection, and refusing it threw away every chunk and left the whole span
                        // unremembered (10-29: 27 chunks dropped over one 144-character block).
                        guard text.count <= chunk.maximumBlockChars else {
                            throw DistillError.oversized(chunk: index + 1, characters: text.count,
                                                        maximum: chunk.maximumBlockChars)
                        }
                        return (index, Block(text: text, source: chunk.source))
                    }
                }
                var completed: [(Int, Block)] = []
                for try await result in group { completed.append(result) }
                return completed.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        } catch {
            await emitDistillTrace(
                sessionId: sessionId, surface: surface, model: model,
                charsIn: promptChars, charsOut: 0, runId: runId,
                status: (error as? DistillError) == .sourceChanged ? goneStatus : "failed",
                promptCharsPerPass: promptCharsPerPass, failure: error
            )
            return nil
        }

        // Voice flags are advisory and appear only in the receipt.
        let thirdPersonLines = Self.configuredAgentName(dataRoot: dataRoot)
            .map { name in blocks.reduce(0) { $0 + Self.thirdPersonSubjectCount($1.text, agentName: name) } } ?? 0
        let thirdPerson = thirdPersonLines > Self.thirdPersonFlagThreshold

        return PreparedRecollection(
            blocks: blocks, model: model, promptCharsPerPass: promptCharsPerPass,
            thirdPerson: thirdPerson
        )
    }

    /// Eligibility uses the final swap's exact row identity. Release the
    /// transcript lock before buying a completion; the locked swap remains
    /// authoritative if the destination disappears during that call.
    private func destinationExists(sessionId: String, summaryRowId: String) async throws -> Bool {
        try Task.checkCancellation()
        let path = messagesPath(sessionId: sessionId)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let raw = try String(contentsOf: path, encoding: .utf8)
            return raw.components(separatedBy: "\n").contains { line in
                guard let data = line.data(using: .utf8),
                      let parsed = try? JSONValue.parse(data),
                      case .object(let obj) = parsed,
                      obj["id"] == .string(summaryRowId),
                      case .object(let meta)? = obj["metadata"] else { return false }
                return meta["kind"] == .string("compaction_summary")
                    && meta["distill"] == .string("pending")
            }
        }
    }

    private enum DistillError: Error, Equatable {
        case routeUnavailable
        case empty
        case oversized(chunk: Int, characters: Int, maximum: Int)
        case sourceChanged
    }

    /// Provider transport and cancellation own the lifetime. A full-window
    /// reasoning pass cannot share a fixed short interactive-call deadline.
    private func callLLM(route: TurnRouteAdmission, prompt: String) async throws -> String {
        // A foreground fold inherits Chat's admission unless every member of
        // this group's tuple is rebound, including its turn-local choice.
        try await ProviderTurnChoice.$current.withValue(nil) {
        try await route.withModelContext {
            try await llm.complete(prompt: prompt, system: Self.distillSystem, model: route.modelId,
                surface: Self.distillSurface, purpose: "compaction", tools: nil)
        }
        }
    }

    /// Advance and publish transcript ordering after durable rewrites; failure never undoes stored recollection.
    static func publishTranscriptChange(
        sessionId: String,
        dataRoot: URL
    ) async {
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        do {
            try await ChatSessionIndexFile.mutate(at: sessionsPath) { rows in
                guard let index = rows.firstIndex(where: {
                    $0["id"] == .string(sessionId)
                }) else { return }
                ChatSessionIndexFile.bumpTranscriptGeneration(in: &rows[index])
            }
        } catch {
            nativeLog("Chat transcript generation bump failed: \(error)")
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .nativeAgentChatTranscriptDidChange, object: sessionId
            )
        }
    }

    private func messagesPath(sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    private func emitDistillTrace(
        sessionId: String,
        surface: String,
        model: String,
        charsIn: Int,
        charsOut: Int,
        runId: String?,
        status: String,
        thirdPerson: Bool = false,
        promptCharsPerPass: [Int] = [],
        failure: (any Error)? = nil
    ) async {
        var payload: [String: JSONValue] = [
            "schema": .string("context.compact.distill.v1"),
            "sessionId": .string(sessionId),
            "surface": .string(surface),
            "model": .string(model),
            "charsIn": .int(Int64(charsIn)),
            "charsOut": .int(Int64(charsOut)),
        ]
        if let runId, !runId.isEmpty {
            payload["runId"] = .string(runId)
        }
        if let failure {
            payload["distill.errorType"] = .string(String(reflecting: type(of: failure)))
            payload["distill.error"] = .string(String(describing: failure))
            payload["distill.deadlineExpired"] = .bool(
                failure is TurnDeadline.DeadlineExceeded
                    || (failure as? ProviderFailure.Diagnostic)?.deadlineExpired == true
                    || (failure as? URLError)?.code == .timedOut
            )
            payload["distill.cancelled"] = .bool(failure is CancellationError)
        }
        if thirdPerson {
            payload["distill.thirdPerson"] = .bool(true)
        }
        // This is the plan, including on failure/cancellation before every
        // child has dispatched. Never count planned work as completed calls.
        if !promptCharsPerPass.isEmpty {
            payload["distill.parallel"] = .bool(true)
            payload["distill.plannedChunks"] = .int(Int64(promptCharsPerPass.count))
            payload["distill.plannedPromptCharsPerChunk"] = .array(
                promptCharsPerPass.map { .int(Int64($0)) }
            )
            payload["distill.rowsOmitted"] = .int(0)
        }
        await TurnTracePersistLane(dataRootOverride: dataRoot).append(
            TurnTraceEvent(kind: "context.compact.distill", title: sessionId, status: status,
                payload: .object(payload), createdAt: ISO8601DateFormatter().string(from: now())))
    }
}

public extension Notification.Name {
    /// Fired by AppModel.sendChat after a turn lands so any ContextFillBar
    /// instance can re-poll the session context.
    static let chatTurnCompleted = Notification.Name("chatTurnCompleted")
    /// Posted after transcript appends and rewrites, with its version bumped.
    /// `object` is the session id; transcript and world projections invalidate.
    static let nativeAgentChatTranscriptDidChange = Notification.Name(
        "NativeAgent.chatTranscriptDidChange"
    )
}
