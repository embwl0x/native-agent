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
// Blueprint: | `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`: `buildTurnContextWithHistory` pins selection to the persisted window before row/character advancement; exact sent user context and keyframe/window metadata replayed from the row; history and digest gathered for their turn part; `fireAssemblyStageEvent`, `injectingSessionDigest` |

// MARK: - SwiftNativeTurnEngine + history threading

public enum TurnHistoryError: Error, LocalizedError {
    case unsupportedLimit(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLimit(let limit): return "History limit \(limit) exceeds the supported row budget."
        }
    }
}

extension SwiftNativeTurnEngine {
    /// Same as `buildTurnContextWithHistory(...)` but with a Mac UI
    /// `UserDefaults["chatPersona"]` override forwarded into the compiled
    /// persona packet. nil → no override (legacy callers unaffected).
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
        // Admit the row budget before any context reads or multiplication.
        // Nonpositive limits disable history, including Int.min.
        let prefixRows = max(0, historyLimit).multipliedReportingOverflow(by: 2)
        let tailRows = prefixRows.partialValue.multipliedReportingOverflow(by: 2)
        guard !prefixRows.overflow, !tailRows.overflow else {
            throw TurnHistoryError.unsupportedLimit(historyLimit)
        }
        // A non-nil queryUserMessage is authoritative even when blank, including attachment-only turns.
        let queryMessage = queryUserMessage ?? userMessage
        func beforeReplacedQuestion(_ messages: [ChatMessage]) -> [ChatMessage] {
            guard let id = ChatPersistenceContext.replacementUserMessageID,
                  let index = messages.firstIndex(where: {
                      if case .object(let row)? = $0.extras { return row["id"] == .string(id) }
                      return false
                  }) else { return messages }
            return Array(messages[..<index])
        }
        var trace = ContextStageTrace()
        // One instant and preference snapshot feed facts, base receipts and composition.
        let currentTurnClock = clockNowOverride ?? clock()
        let quietHoursWindow = readTurnQuietHours()
        // The read-only facts of this moment read nothing the history and base
        // context assemble, so they gather beside that work from the start.
        // The composition below reads the facts that consume state, and the
        // peer-sensitive elsewhere line after this history latched its evidence.
        async let currentFacts = currentTurnFacts(
            clockNow: currentTurnClock,
            quietHours: quietHoursWindow,
            sessionID: sessionId,
            queryUserMessage: queryMessage
        )
        // v2 replays history as REAL messages behind a cache breakpoint, so
        // carrying more of it is nearly free and continuity is the whole point
        // — a broad replay window. Both row and character pressure use the
        // cursor's 1.15 trigger and 0.70 target.
        let prefixRowCap = max(1, prefixRows.partialValue)
        let cursorStore = HistoryWindowCursorStore(dataRoot: historyReader.dataRoot)
        let windowCursor = historyLimit > 0
            ? try await cursorStore.current(sessionId: sessionId) : HistoryWindowCursor(sessionId: sessionId)
        let prior: [ChatMessage]
        let middleCandidates: [ChatMessage]
        let priorStats: SessionHistoryReadStats
        let middleStats: SessionHistoryReadStats?
        var unreadHistory: Error?
        if historyLimit > 0 {
            // One transcript read per turn: the bytes this turn's compaction
            // pass already read under its lock, else the file once, here.
            // Every selection below (prompt head and tail, middle candidates)
            // runs over those bytes.
            let selected: (prompt: SessionHistoryReadResult, relevance: SessionHistoryReadResult?)?
            // Measured inline: the read's closure holds actor state and cannot be sent to the trace.
            let promptReadStart = DispatchTime.now().uptimeNanoseconds
            do {
                let bytes: Data?
                if let transcript { bytes = transcript } else {
                    bytes = try await historyReader.transcriptBytes(forSessionId: sessionId)
                }
                selected = historyReader.promptMessagesWithStats(
                    transcript: bytes,
                    anchorLimit: 3,
                    // 2C > 1.15C + the boundary row; selection also retains
                    // the exact boundary if raw/filtered rows exceed that slack.
                    tailLimit: max(96, tailRows.partialValue),
                    windowCursor: windowCursor,
                    excludingRunId: excludeHistoryRunId,
                    relevanceWhen: { beforeReplacedQuestion($0.messages).count > historyLimit || $0.stats.truncated }
                )
                trace.record(.promptRead, since: promptReadStart)
            } catch {
                trace.record(.promptRead, since: promptReadStart)
                if error is CancellationError { throw error }
                selected = nil
                unreadHistory = error
            }
            let priorResult = selected?.prompt ?? SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "prompt_read_failed")
            )
            prior = beforeReplacedQuestion(priorResult.messages)
            priorStats = priorResult.stats
            if let middleResult = selected?.relevance {
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
            providerID: LLMCallContext.providerId,
            dataRoot: historyReader.dataRoot
        )
        let historyBudget = ContextBudgetPolicy.resolve(
            windowTokens: historyWindowTokens
        )
        let preparedMiddle = middleStats == nil
            ? preparedHistory : middleCandidates.compactMap(SessionHistoryPromptRenderer.renderable)
        var deliveredHistoryIdentities = Set<String>()
        var historyMessages: [LLMMessage] = []
        var historyMessageChars = 0
        var historyWindowReceipt: HistoryWindowReceipt?
        var replayedRunIds = Set<String>()
        var replayedContexts: [SentTurnContext] = []
        var contextWindow = "0:"
        // With cross-session recall enabled, absent recollection borrows the anchor only in the replay prefix; prior stays untouched.
        let priorForPrefix = MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: historyReader.dataRoot)
            ? CarriedAnchorRecollection.seeded(
                prior, sessionId: sessionId, dataRoot: historyReader.dataRoot,
                admittedPriorSessionId: sessionDigest?.dataRoot == historyReader.dataRoot ? admittedPriorSessionId : nil
            )
            : prior
        trace.setFlag("prefix.carriedRecollection", priorForPrefix.count != prior.count)
        if let admission = SessionHistoryMessages.admission(
            renderables: priorForPrefix.prefix(priorForPrefix.count - prior.count)
                .compactMap(SessionHistoryPromptRenderer.renderable) + preparedHistory,
            historyLimit: historyLimit,
            windowTokens: historyWindowTokens
           ) {
            // The window head moves at most once per turn, oldest-first, and
            // after compaction only if its result still exceeds a budget (see
            // HistoryWindowCursor). The turn-id guard inside the store makes a
            // tool loop's later iterations no-ops by construction, so a lane
            // that rebuilds context per iteration cannot slide the prefix
            // mid-turn.
            let advance = try await cursorStore.advanceIfNeeded(
                sessionId: sessionId,
                admitted: admission.rows,
                budgetChars: historyBudget.historyChars,
                // The same row budget whose 2x tail is read above.
                rowCap: prefixRowCap,
                turnId: TurnTraceContext.turnId,
                compactionRanThisTurn: HistoryWindowTurnFacts.compactionRanThisTurn
            )
            let projected = SessionHistoryMessages.project(admission, cursor: advance.cursor)
            deliveredHistoryIdentities = projected.historyIdentities
            replayedContexts = projected.replayedContexts
            contextWindow = projected.contextWindow
            replayedRunIds = projected.replayedRunIds
            historyMessages = projected.messages
            historyMessageChars = projected.messages.reduce(0) { total, message in
                total + message.content.reduce(0) {
                    if case .text(let text) = $1 { return $0 + text.count }
                    return $0
                }
            }
            historyWindowReceipt = HistoryWindowReceipt(
                advanceCount: advance.cursor.advanceCount,
                slid: advance.didAdvance
            )
        }
        trace.setLabel("prefix.shapeVersion", "v2Prefix")
        trace.setCount("prefix.historyMessageCount", historyMessages.count)
        trace.setCount("prefix.historyMessageChars", historyMessageChars)
        trace.setCount(
            "prefix.windowCursorAdvanceCount", historyWindowReceipt?.advanceCount ?? 0
        )
        trace.setFlag("prefix.windowSlid", historyWindowReceipt?.slid ?? false)
        trace.setCount("prefix.replayedTurnCount", replayedRunIds.count)
        trace.setCount("budget.windowTokens", historyWindowTokens ?? 0)
        trace.setFlag("budget.derived", historyBudget.isDerived)
        trace.setCount("budget.historyChars", historyBudget.historyChars)
        trace.setCount("budget.memoryBlockChars", historyBudget.memoryBlockChars)
        trace.setCount("budget.recallRowLimit", historyBudget.recallRowLimit)
        // History is context, not a read this turn: an agent's words kept here are
        // labelled untrusted for the model, and never steer the person's new turn.
        // A steer lives for exactly the turn that read the words; a resumed turn
        // restores its own (`ChatOrchestration+Continuation`).
        let receiptStrip = ChatTranscriptEvidenceRendering.recentReceiptStrip(from: prior)
        deliveredHistoryIdentities.formUnion(receiptStrip?.historyIdentities ?? [])
        let renderedHistory = await trace.measure(.render) {
            SessionHistoryPromptRenderer.renderDetailed(
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
        contextWithHistory.historyWindowReceipt = historyWindowReceipt
        contextWithHistory.replayedTurnContexts = replayedContexts
        contextWithHistory.historyContextWindow = contextWindow
        let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
        let clocked = await contextByAppendingCurrentTurnFacts(
            contextWithHistory, facts: currentFacts, sessionID: sessionId, clockNowOverride: currentTurnClock)
        var finalContext = clocked
        // An unread history is a fact of this turn, never a quiet empty one.
        if let unreadHistory {
            finalContext = Self.contextByAppendingRuntimeContext(finalContext, runtimeContext:
                "This conversation's history could not be read for this turn (\(unreadHistory.localizedDescription)); nothing before this message is in front of you.")
        }
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
            "windowCursorAdvanceCount": .int(Int64(context.historyWindowReceipt?.advanceCount ?? 0)),
            "windowSlid": .bool(context.historyWindowReceipt?.slid ?? false),
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
        guard MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: provider.dataRoot) else { return (base, nil) }
        // FIRST TURN ONLY. The anchor exists to hand a BRAND-NEW session the
        // thread it was cut from. From turn 2 the session's own history block
        // carries that thread, and re-injecting two lines that point at a
        // conversation she has already moved past is duplication paid for on
        // every turn. `prior` rows are the same signal the history guard below
        // uses — non-empty prior ⇒ a history block renders — and the current
        // turn's own user row is excluded by runId, so turn 1 is empty here.
        guard !hasPriorHistory else { return (base, nil) }
        // The handoff is housekeeping: the turn takes what is published. When
        // none is, its builder runs on its own and the turn says what is missing.
        let unavailable: String
        do {
            if let digest = try await provider.published(forSessionId: sessionId) {
                guard !digest.text.isEmpty else { return (base, digest.priorSessionId) }
                var copy = base
                copy.turnReach.digest = digest.text
                return (copy, digest.priorSessionId)
            }
            guard let prior = try PriorChatSession.latest(excluding: sessionId, dataRoot: provider.dataRoot) else { return (base, nil) }
            let (model, surface, message) = (base.modelId, base.surface, base.userMessage)
            Task {
                do { _ = try await provider.digest(forSessionId: sessionId, prior: prior, model: model, surface: surface, userMessage: message) }
                catch {
                    TurnTraceBus.fireFromContext(kind: "context.digest.failed", sessionId: sessionId, surface: surface,
                        payload: .object(["reason": .string(String(describing: error))]))
                }
            }
            unavailable = "The handoff from your previous conversation with this participant was not ready for this message; the handoff builder is writing it from that conversation now. "
                + SessionDigestProvider.pointerSentence(sessionId: prior.id)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            TurnTraceBus.fireFromContext(
                kind: "context.digest.failed", sessionId: sessionId, surface: base.surface,
                payload: .object(["reason": .string(String(describing: error))])
            )
            unavailable = "The handoff from your previous conversation with this participant could not be read (\(error.localizedDescription))."
        }
        return (contextByAppendingRuntimeContext(base, runtimeContext: unavailable), nil)
    }
}
