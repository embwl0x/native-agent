import Foundation
import Context
import MemoryV2
import CryptoKit
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace
import ChatSessionWork
import ChatTurnContracts
import ProviderRouting
import Experiences
import Transcripts
// Blueprint: | `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`: checked whole-transcript replay fails with repair owed before provider admission; only measured recollection folds move the head; exact sent user context and recollection-window metadata replayed from the row; `fireAssemblyStageEvent`, `injectingSessionDigest` |

// MARK: - SwiftNativeTurnEngine + history threading

extension SwiftNativeTurnEngine {
    /// Same as `buildTurnContextWithHistory(...)` but with a Mac UI
    /// `UserDefaults["chatPersona"]` override forwarded into the compiled
    /// persona packet. nil uses the selected persona.
    /// `sessionDigest` is an explicit opt-in: nil never builds or reads the
    /// prior-session anchor. Supplied, it is injected on the first turn only.
    public func buildTurnContextWithHistory(
        surface: String,
        userMessage: String,
        sessionId: String,
        historyLimit: Int,
        historyReader: SessionHistoryReader,
        personaOverride: String?,
        excludeHistoryRunId: String? = nil,
        sessionDigest: SessionDigestProvider? = nil,
        imageBlocks: [LLMContentBlock] = [],
        // Raw user text for relevance consumers (recall query, expression
        // cues, and the selection/embedding inputs downstream) when
        // `userMessage` carries turn-scoped wire riders (text-compat
        // tool-routing hint). nil → `userMessage`.
        queryUserMessage: String? = nil,
        // Turn-start instant for the clock line (see buildTurnContext) —
        // tool loops pass the same value every iteration.
        clockNowOverride: Date? = nil,
        // The transcript bytes this turn's compaction pass already read under
        // its lock; nil reads the file once here.
        transcript: Data? = nil
    ) async throws -> TurnContext {
        // A non-nil queryUserMessage is authoritative even when blank, including attachment-only turns.
        let queryMessage = queryUserMessage ?? userMessage
        let replacementAnswerID = ChatPersistenceContext.replacementAssistantMessageID
        let replacementQuestion = OSAllocatedUnfairLock(initialState: ChatPersistenceContext.replacementUserMessageID)
        @Sendable func beforeReplacedQuestion(_ messages: [ChatMessage]) -> [ChatMessage] {
            let id = replacementQuestion.withLock { questionID in
                // Some ingress names only the answer. Resolve its saved
                // question once; a selection without it leaves it unresolved.
                if questionID == nil,
                   let answer = replacementAnswerID,
                   let end = messages.firstIndex(where: { $0.extras?.objectValue?["id"] == .string(answer) }),
                   let question = messages[..<end].last(where: { $0.role == "user" }),
                   let savedID = question.extras?.objectValue?["id"]?.stringValue {
                    questionID = savedID
                }
                return questionID
            }
            return SessionReplaySpec.beforeQuestion(messages, id: id)
        }
        var trace = ContextStageTrace()
        // One instant and preference snapshot feed facts, base receipts and composition.
        let currentTurnClock = clockNowOverride ?? clock()
        let quietHoursWindow = try readTurnQuietHours()
        // The read-only facts of this moment read nothing the history and base
        // context assemble, so they gather beside that work from the start.
        // The composition below reads the facts that consume state, and the
        // peer-sensitive elsewhere line after this history latched its evidence.
        async let currentFacts = try currentTurnFacts(
            clockNow: currentTurnClock,
            quietHours: quietHoursWindow,
            sessionID: sessionId,
            queryUserMessage: queryMessage
        )
        // Replay the complete current transcript. Only a measured recollection
        // fold may move its head; positive historyLimit values never cap rows.
        let prior: [ChatMessage]
        let middleCandidates: [ChatMessage]
        let priorStats: SessionHistoryReadStats
        let middleStats: SessionHistoryReadStats?
        if historyLimit > 0 {
            // One transcript read per turn: the bytes this turn's compaction
            // pass already read under its lock, else the file once, here.
            // Every selection below (prompt head and tail, middle candidates)
            // runs over those bytes.
            let selected: (prompt: SessionHistoryReadResult, relevance: SessionHistoryReadResult?)
            // Measured inline: the read's closure holds actor state and cannot be sent to the trace.
            let promptReadStart = DispatchTime.now().uptimeNanoseconds
            do {
                let bytes: Data?
                if let transcript { bytes = transcript } else {
                    bytes = try await historyReader.transcriptBytes(forSessionId: sessionId)
                }
                selected = historyReader.promptMessagesWithStats(
                    transcript: bytes,
                    excludingRunId: excludeHistoryRunId,
                    relevanceWhen: { beforeReplacedQuestion($0.messages).count > historyLimit || $0.stats.truncated }
                )
                _ = try selected.prompt.checkedMessages()
                if let relevance = selected.relevance { _ = try relevance.checkedMessages() }
                trace.record(.promptRead, since: promptReadStart)
            } catch {
                trace.record(.promptRead, since: promptReadStart)
                if error is CancellationError { throw error }
                let path = historyReader.dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl").path
                let nextCall = ToolFailureError.call("app", ["action": .string("files.read"), "args": .object(["path": .string(path)])])
                let failure = ToolFailureError(
                    "This conversation's history could not be read: \(error.localizedDescription) Repair its retained transcript before continuing.",
                    effects: .none, owner: path, nextCall: nextCall, code: "transcript_unavailable", recovery: .repair)
                RepairOwed.owe(historyReader.dataRoot, id: UUID().uuidString, kind: .run,
                    operation: "chat.history:\(sessionId)", owner: path, words: failure.localizedDescription, nextCall: nextCall)
                TurnTraceBus.fireFromContext(kind: "context.history.failed", sessionId: sessionId, surface: surface,
                    payload: .object(["code": .string("transcript_unavailable"), "reason": .string(error.localizedDescription)]))
                throw failure
            }
            if selected.prompt.stats.mode != "missing" {
                RepairOwed.settle(historyReader.dataRoot, operation: "chat.history:\(sessionId)",
                    evidence: .init(source: "transcript", id: sessionId))
            }
            let priorResult = selected.prompt
            prior = beforeReplacedQuestion(priorResult.messages)
            priorStats = priorResult.stats
            if let middleResult = selected.relevance {
                middleCandidates = beforeReplacedQuestion(middleResult.messages)
                middleStats = middleResult.stats
            } else {
                middleCandidates = prior
                middleStats = nil
            }
        } else {
            prior = []
            middleCandidates = []
            priorStats = SessionHistoryReadStats(mode: "history_disabled")
            middleStats = nil
        }
        let preparedHistory = await trace.measure(.prepare) {
            prior.compactMap(SessionHistoryPromptRenderer.renderable)
        }
        let baseStartNs = DispatchTime.now().uptimeNanoseconds
        // Use the transcript owner's exchange pairing, including repeated runs
        // and interrupted replies. The four-message relevance window is not a clock.
        let paired = ChatSessionRecollections.pairExchanges(prior.map {
            (sessionId, $0.extras?.objectValue?["runId"]?.stringValue, $0.role,
             $0.role == "user" || $0.role == "assistant")
        })
        var exchangeWords: [Int: [String]] = [:]
        var exchangeOrder: [Int] = []
        for entry in paired {
            if exchangeWords[entry.exchange] == nil {
                exchangeOrder.append(entry.exchange)
                exchangeWords[entry.exchange] = []
            }
            if prior[entry.row].role == "user" {
                exchangeWords[entry.exchange, default: []].append(prior[entry.row].content)
            }
        }
        let rawBase: TurnContext
        do {
            rawBase = try await buildTurnContext(
                surface: surface,
                userMessage: userMessage,
                personaOverride: personaOverride,
                imageBlocks: imageBlocks,
                recallQueryOverride: nil,
                includeClockContext: false,
                sessionID: sessionId,
                recentTurns: prior.filter { $0.role == "user" || $0.role == "assistant" }.suffix(4)
                    .map { $0.content },
                recentExchanges: exchangeOrder.map { exchangeWords[$0, default: []] },
                queryUserMessage: queryMessage,
                clockNowOverride: currentTurnClock,
                quietHoursSnapshot: quietHoursWindow,
                offeredToolNames: SwiftToolDispatcher.normalModelToolNames(activeTools: LLMCallContext.turnActiveTools ?? []),
                recallHistory: preparedHistory
            )
            trace.record(.contextBase, since: baseStartNs)
        } catch {
            trace.record(.contextBase, since: baseStartNs)
            throw error
        }
        let (base, admittedPriorSessionId) = try await trace.measure(.digest) {
            try await Self.injectingSessionDigest(
                into: rawBase,
                sessionId: sessionId,
                hasPriorHistory: !prior.isEmpty,
                provider: sessionDigest
            )
        }
        // The admitted model determines every history budget through ContextBudgetPolicy.resolve.
        let historyWindowTokens = ContextBudgetPolicy.windowTokens(
            forModel: base.modelId,
            providerID: base.providerId,
            dataRoot: historyReader.dataRoot
        )
        let historyBudget = try ContextBudgetPolicy.resolve(
            windowTokens: historyWindowTokens
        )
        let preparedMiddle = middleStats == nil
            ? preparedHistory : middleCandidates.compactMap(SessionHistoryPromptRenderer.renderable)
        var deliveredHistoryIdentities = Set<String>()
        var historyMessages: [LLMMessage] = []
        var historyMessageChars = 0
        var replayedRunIds = Set<String>()
        var replayedContexts: [SentTurnContext] = []
        var historyRowCharacters: [String: Int] = [:]
        var contextWindow = "0:"
        // With cross-session recall enabled, absent recollection borrows the anchor only in the replay prefix; prior stays untouched.
        let priorForPrefix = try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: historyReader.dataRoot)
            ? try CarriedAnchorRecollection.seeded(
                prior, sessionId: sessionId, dataRoot: historyReader.dataRoot,
                admittedPriorSessionId: sessionDigest?.dataRoot == historyReader.dataRoot ? admittedPriorSessionId : nil
            )
            : prior
        trace.setFlag("prefix.carriedRecollection", priorForPrefix.count != prior.count)
        if let admission = try SessionHistoryMessages.admission(
            renderables: priorForPrefix.prefix(priorForPrefix.count - prior.count)
                .compactMap(SessionHistoryPromptRenderer.renderable) + preparedHistory,
            historyLimit: historyLimit,
            windowTokens: historyWindowTokens
           ) {
            let projected = SessionHistoryMessages.project(admission)
            deliveredHistoryIdentities = projected.historyIdentities
            replayedContexts = projected.replayedContexts
            historyRowCharacters = projected.rowCharacters
            contextWindow = projected.contextWindow
            replayedRunIds = projected.replayedRunIds
            historyMessages = projected.messages
            historyMessageChars = projected.messages.reduce(0) { total, message in
                total + message.content.reduce(0) {
                    if case .text(let text) = $1 { return $0 + text.count }
                    return $0
                }
            }
        }
        trace.setLabel("prefix.shapeVersion", "v2Prefix")
        trace.setCount("prefix.historyMessageCount", historyMessages.count)
        trace.setCount("prefix.historyMessageChars", historyMessageChars)
        trace.setCount("prefix.replayedTurnCount", replayedRunIds.count)
        trace.setCount("budget.windowTokens", historyWindowTokens ?? 0)
        trace.setFlag("budget.derived", historyBudget.isDerived)
        trace.setCount("budget.memoryBlockChars", historyBudget.memoryBlockChars)
        trace.setCount("budget.recallRowLimit", historyBudget.recallRowLimit)
        // History is context, not a read this turn: an agent's words kept here are
        // labelled untrusted for the model, and never steer the person's new turn.
        // A steer lives for exactly the turn that read the words; a resumed turn
        // restores its own (`ChatOrchestration+Continuation`).
        let receiptStrip = ChatTranscriptEvidenceRendering.recentReceiptStrip(from: prior)
        deliveredHistoryIdentities.formUnion(receiptStrip?.historyIdentities ?? [])
        let renderedHistory = try await trace.measure(.render) {
            try SessionHistoryPromptRenderer.renderDetailed(
                renderables: preparedHistory,
                middleCandidates: preparedMiddle,
                deliveredHistoryIdentities: deliveredHistoryIdentities,
                userMessage: queryMessage,
                historyLimit: historyLimit,
                windowTokens: historyWindowTokens
            )
        }
        let historyParts = [renderedHistory, SessionHistoryPromptRenderer.worldRecord(from: prior), receiptStrip?.text].compactMap { $0 }
        let historyBlock = historyParts.isEmpty ? nil : historyParts.joined(separator: "\n\n")
        trace.setCount("history.prompt.sourceBytes", priorStats.sourceBytes)
        trace.setCount("history.prompt.bytesRead", priorStats.bytesRead)
        trace.setCount("history.prompt.linesRead", priorStats.linesRead)
        trace.setCount("history.prompt.decoded", priorStats.decodedCount)
        trace.setCount("history.prompt.decodeCacheHits", priorStats.decodeCacheHits)
        trace.setCount("history.prompt.decodeCacheMisses", priorStats.decodeCacheMisses)
        trace.setCount("history.prompt.excludedByRunId", priorStats.excludedByRunId)
        trace.setCount("history.prompt.returned", priorStats.returnedCount)
        trace.setFlag("history.prompt.truncated", priorStats.truncated)
        if let middleStats {
            trace.setCount("history.middle.sourceBytes", middleStats.sourceBytes)
            trace.setCount("history.middle.bytesRead", middleStats.bytesRead)
            trace.setCount("history.middle.linesRead", middleStats.linesRead)
            trace.setCount("history.middle.decoded", middleStats.decodedCount)
            trace.setCount("history.middle.returned", middleStats.returnedCount)
            trace.setFlag("history.middle.fullRead", middleStats.mode == "full")
            trace.setFlag("history.middle.sampled", middleStats.mode == "relevance_sampled")
            trace.setFlag("history.middle.truncated", middleStats.truncated)
        } else {
            trace.setFlag("history.middle.fullRead", false)
            trace.setFlag("history.middle.sampled", false)
        }
        trace.setCount("history.priorCount", prior.count)
        trace.setCount("history.middleCandidateCount", middleCandidates.count)
        trace.setCount("historyBlockChars", historyBlock?.count ?? 0)
        // The history block joins her turn part's context after the packet and
        // recall; the session digest (injected above, first turn only) leads
        // it. No history leaves the base context's shape as it was.
        var contextWithHistory = base
        if let historyBlock {
            contextWithHistory.turnReach.history = historyBlock
        }
        contextWithHistory.historyMessages = historyMessages
        contextWithHistory.historyRowCharacters = historyRowCharacters
        contextWithHistory.historyReplaySpec = SessionReplaySpec(historyLimit: historyLimit,
            excludedRunID: excludeHistoryRunId,
            replacementUserMessageID: replacementQuestion.withLock { $0 },
            carryAnchor: true, admittedPriorSessionID: sessionDigest?.dataRoot == historyReader.dataRoot ? admittedPriorSessionId : nil)
        contextWithHistory.replayedTurnContexts = replayedContexts
        contextWithHistory.historyContextWindow = contextWindow
        let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
        let facts = try await currentFacts
        trace.record(.factsJoin, since: runtimeStartNs)
        let clocked = try await contextByAppendingCurrentTurnFacts(
            contextWithHistory, facts: facts, sessionID: sessionId, clockNowOverride: currentTurnClock, trace: &trace)
        var finalContext = clocked
        trace.record(ContextStageName.contextClockRuntime, since: runtimeStartNs)
        trace.setCount("userMessageChars", finalContext.userMessage.count)
        trace.setCount("toolSchemaCount", finalContext.toolSchemas.count)
        finalContext.preparationMs = trace.emit(kind: "context.history.summary", surface: surface)
        return finalContext
    }

    /// Turn Inspector W2 — assembly.stage emitter (SIZES AND COUNTS ONLY).
    ///
    /// Fires ONE `assembly.stage` event per turn carrying char counts of the
    /// already-built system-prompt segments + cache-relevant metadata. NEVER
    /// the content — the system prompt is the most secret-dense string in the
    /// app, so this payload is structurally counts-only (no string leaf carries
    /// prompt text). Skipped when no turn is bound (the `fireFromContext`
    /// contract). Fire-and-forget, drop-on-backpressure — zero hot-path cost
    /// beyond the bounded emission.
    ///
    /// Segment sizes reported, from the system her turn part composed:
    ///   - stable: persona packet + REM pins — the cacheable mass.
    ///   - dynamicNonHistory: the dynamic segment MINUS the history block
    ///     (i.e. memory recall + per-turn extras).
    ///   - history: the rendered session-history block.
    ///   - current: the current user message.
    ///   - systemTotal: the full combined system prompt length.
    /// Plus `recalledCount` (memory recall hit count) and `breakpointZone`
    /// (whether a stable/dynamic split exists, which drives Anthropic
    /// cache_control breakpoint placement).
    nonisolated static func fireAssemblyStageEvent(surface: String, context: TurnContext) {
        let segments = context.systemSegments
        let historyBlock = context.turnReach.history
        let historyMessageChars = context.historyMessages.reduce(0) { total, message in
            total + message.content.reduce(0) { if case .text(let text) = $1 { $0 + text.count } else { $0 } }
        }
        let systemTotal = context.systemPrompt?.count ?? 0
        let stableChars = segments?.stable.count ?? 0
        let dynamicChars = segments?.dynamic.count ?? 0
        let historyChars = historyBlock.count
        // The dynamic segment includes the history block when present; report
        // the recall/extras portion separately so the Inspector can show the
        // recall mass distinct from the (recency-weighted) history mass.
        let dynamicNonHistoryChars = max(0, dynamicChars - historyChars
            - (historyChars > 0 && dynamicChars > historyChars ? 2 : 0)) // "\n\n" join
        let payload: [String: JSONValue] = [
            "stableChars": .int(Int64(stableChars)),
            "dynamicChars": .int(Int64(dynamicChars)),
            "dynamicNonHistoryChars": .int(Int64(dynamicNonHistoryChars)),
            "historyChars": .int(Int64(historyChars)),
            "currentChars": .int(Int64(context.userMessage.count)),
            "systemTotalChars": .int(Int64(systemTotal)),
            "recalledCount": .int(Int64(context.recalled.count)),
            // Cache-relevant: a non-nil split means the adapter can place the
            // sys cache_control breakpoint at the end of the STABLE mass (the
            // U1 segmented layout). Segment count == number of cacheable
            // system regions the breakpoint logic distinguishes.
            "segmented": .bool(segments != nil),
            "segmentCount": .int(Int64(segments != nil ? 2 : 1)),
            // v2Prefix: how much of the turn now rides as REPLAYED MESSAGES
            // instead of system-prompt text, and whether the window head moved.
            "shapeVersion": .string("v2Prefix"),
            "historyMessageCount": .int(Int64(context.historyMessages.count)),
            "historyMessageChars": .int(Int64(historyMessageChars)),
        ]
        TurnTraceBus.fireFromContext(
            kind: "assembly.stage",
            surface: surface,
            payload: .object(payload)
        )
    }

    /// A handoff belongs at the dynamic head so it cannot churn the shared
    /// stable cache prefix. It is optional context: failure leaves the turn
    /// intact and traced, while cancellation still stops assembly.
    nonisolated static func injectingSessionDigest(
        into base: TurnContext,
        sessionId: String,
        hasPriorHistory: Bool,
        provider: SessionDigestProvider?
    ) async throws -> (context: TurnContext, priorSessionId: String?) {
        // Guard before provider/cache access: a surface that did not ask for
        // the carry-over never reads or writes anchor bytes.
        guard let provider else { return (base, nil) }
        guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: provider.dataRoot) else { return (base, nil) }
        // FIRST TURN ONLY. The anchor exists to hand a BRAND-NEW session the
        // thread it was cut from. From turn 2 the session's own history block
        // carries that thread, and re-injecting two lines that point at a
        // conversation she has already moved past is duplication paid for on
        // every turn. `prior` rows are the same signal the history guard below
        // uses — non-empty prior ⇒ a history block renders — and the current
        // turn's own user row is excluded by runId, so turn 1 is empty here.
        guard !hasPriorHistory else { return (base, nil) }
        // The first turn is the handoff's delivery opportunity. Join the
        // existing single-flight builder before admitting that first answer.
        do {
            if let digest = try await provider.published(forSessionId: sessionId) {
                guard !digest.text.isEmpty else { return (base, nil) }
                var copy = base
                copy.turnReach.digest = digest.text
                return (copy, digest.priorSessionId)
            }
            guard let prior = try PriorChatSession.latest(excluding: sessionId, dataRoot: provider.dataRoot) else { return (base, nil) }
            _ = try await provider.digest(forSessionId: sessionId, prior: prior,
                model: base.modelId, surface: base.surface, userMessage: base.userMessage)
            guard let digest = try await provider.published(forSessionId: sessionId) else {
                throw ChatOrchestrationError.underlying("The conversation handoff builder completed without publishing its result. Repair the session digest owner.")
            }
            var copy = base
            if !digest.text.isEmpty { copy.turnReach.digest = digest.text }
            return (copy, digest.priorSessionId.isEmpty ? nil : digest.priorSessionId)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            TurnTraceBus.fireFromContext(
                kind: "context.digest.failed", sessionId: sessionId, surface: base.surface,
                payload: .object(["reason": .string(String(describing: error))])
            )
            throw TurnEngineError.contextLoadFailed(underlying: error)
        }
    }
}
