import Foundation
import Context
import MemoryV2
import CryptoKit
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace
// v2Prefix delivery ladder: supportsMidConversationSystem / …ClearAt.
import ProviderRouting

// MARK: - SwiftNativeTurnEngine + history threading

extension SwiftNativeTurnEngine {
    /// Build per-turn context with prior conversation replayed as messages and
    /// bounded derived history in the dynamic context. Missing session history
    /// leaves the normal `buildTurnContext` shape. The two-line prior-session
    /// anchor is opt-in through the explicit-provider overload and lands on a
    /// session's first turn only.
    public func buildTurnContextWithHistory(
        surface: String,
        userMessage: String,
        sessionId: String,
        historyLimit: Int = 400,
        historyReader: SessionHistoryReader = SessionHistoryReader()
    ) async throws -> TurnContext {
        return try await buildTurnContextWithHistory(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            historyLimit: historyLimit,
            historyReader: historyReader,
            personaOverride: nil,
            excludeHistoryRunId: nil
        )
    }

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
        // Non-nil queryUserMessage is authoritative EVEN WHEN BLANK — an
        // attachment-only text-compat turn must not fall back to the hinted
        // wire message (gpt-5.5 review 2026-08-13, NEEDS-FIX #1).
        let queryMessage = queryUserMessage ?? userMessage
        var trace = ContextStageTrace()
        // Capture once at the outer turn boundary. The base builder owns the
        // receipt flag and this history wrapper owns final clock rendering;
        // both must observe the same preference bytes without a second read.
        let quietHoursWindow = readTurnQuietHours()
        // The read-only facts of this moment read nothing the history and base
        // context assemble, so they gather beside that work from the start.
        // The composition below reads the facts that consume state, and the
        // peer-sensitive elsewhere line after this history latched its evidence.
        async let currentFacts = currentTurnFacts(
            clockNowOverride: clockNowOverride,
            quietHours: quietHoursWindow,
            sessionID: sessionId,
            queryUserMessage: queryMessage
        )
        // v2 replays history as REAL messages behind a cache breakpoint, so
        // carrying more of it is nearly free and continuity is the whole point
        // — a broad replay window. The cursor fires at `* 1.15` (92) and
        // trims to `* 0.70` (56), so the live window sits between those.
        let prefixRowCap = max(1, historyLimit * 2)
        let prior: [ChatMessage]
        let middleCandidates: [ChatMessage]
        let priorStats: SessionHistoryReadStats
        let middleStats: SessionHistoryReadStats?
        if historyLimit > 0 {
            // One transcript read per turn: the bytes this turn's compaction
            // pass already read under its lock, else the file once, here.
            // Every selection below (prompt head and tail, middle candidates)
            // runs over those bytes.
            let selected = try? await trace.measure(.promptRead) {
                let bytes: Data?
                if let transcript { bytes = transcript } else {
                    bytes = try await historyReader.transcriptBytes(forSessionId: sessionId)
                }
                return (bytes, historyReader.promptMessagesWithStats(
                    transcript: bytes,
                    anchorLimit: 3,
                    // v2: the reader must NOT be the head. Its tail limit
                    // slides by a few rows every turn as the transcript grows,
                    // and on v2 the projection admits everything it returns —
                    // so the replayed prefix started at a different row every
                    // turn and the message history never cached (live
                    // CD041E66). The window cursor owns the head now; this
                    // number only has to be wide enough that the cursor's
                    // boundary is always INSIDE it. The cursor trims to
                    // `historyLimit * 0.70` rows and fires at `* 1.15`, so a
                    // 2x read leaves the boundary with most of the window
                    // beneath it — it can never slide out from under.
                    tailLimit: max(96, prefixRowCap * 2),
                    excludingRunId: excludeHistoryRunId
                ))
            }
            let priorResult = selected?.1 ?? SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "prompt_read_failed")
            )
            prior = priorResult.messages
            priorStats = priorResult.stats
            if prior.count > historyLimit || priorStats.sourceBytes > priorStats.bytesRead {
                let middleResult = await trace.measure(.middleSample) {
                    historyReader.relevanceMessagesWithStats(
                        transcript: selected?.0,
                        excludingRunId: excludeHistoryRunId
                    )
                }
                middleCandidates = middleResult.messages
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
                recentTurns: prior.filter { $0.role == "user" || $0.role == "assistant" }.suffix(4).map(\.content),
                queryUserMessage: queryMessage,
                clockNowOverride: clockNowOverride,
                quietHoursSnapshot: quietHoursWindow,
                offeredToolNames: SwiftToolDispatcher.normalModelToolNames(activeTools: LLMCallContext.turnActiveTools ?? []),
                recallHistory: preparedHistory
            )
            trace.record(.contextBase, since: baseStartNs)
        } catch {
            trace.record(.contextBase, since: baseStartNs)
            throw error
        }
        let base = try await trace.measure(.digest) {
            try await Self.injectingSessionDigest(
                into: rawBase,
                sessionId: sessionId,
                hasPriorHistory: !prior.isEmpty,
                provider: sessionDigest
            )
        }
        let naturalExpressionCue = NaturalExpressionGuidance.pendingCues(from: prior, userMessage: queryMessage)
        trace.setFlag("expression.rhythmCuePending", naturalExpressionCue != nil)
        // Sweep R4 W3: the ONLY production caller of the history renderer, and
        // the first place in prompt assembly where the admitted model for this
        // turn is known (`buildTurnContext` resolved it above). That makes this
        // the interception point for window-aware budgets — everything the
        // renderer sizes flows from `ContextBudgetPolicy.resolve`. An unknown
        // or unresolvable model yields nil and the floor regime, i.e. exactly
        // the pre-policy budgets.
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
        let renderedHistory = await trace.measure(.render) {
            SessionHistoryPromptRenderer.renderDetailed(
                renderables: preparedHistory,
                middleCandidates: preparedMiddle,
                userMessage: queryMessage,
                historyLimit: historyLimit,
                windowTokens: historyWindowTokens,
                consumeToolReceipt: SwiftToolDispatcher.consumeRenderedToolReceipt
            )
        }
        var historyMessages: [LLMMessage] = []
        var historyMessageChars = 0
        var historyWindowReceipt: HistoryWindowReceipt?
        var replayedRunIds = Set<String>()
        // CROSS-SESSION CONTINUITY. A session with no recollection of its own
        // borrows the conversation anchor's, read-only, at the head of the
        // replayed prefix — see `CarriedAnchorRecollection`. Seeded HERE and
        // nowhere else: `prior` itself is untouched, so nothing that persists,
        // ages, recalls or summarises this session ever sees the borrowed row.
        // Borrowing another conversation's recollection IS remembering across
        // conversations, so the same switch gates it (Codex review 2026-09-05).
        let priorForPrefix = MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: historyReader.dataRoot)
            ? CarriedAnchorRecollection.seeded(
                prior, sessionId: sessionId, dataRoot: historyReader.dataRoot
            )
            : prior
        trace.setFlag("prefix.carriedRecollection", priorForPrefix.count != prior.count)
        if let admission = SessionHistoryMessageProjection.admission(
            renderables: priorForPrefix.prefix(priorForPrefix.count - prior.count)
                .compactMap(SessionHistoryPromptRenderer.renderable) + preparedHistory,
            historyLimit: historyLimit,
            windowTokens: historyWindowTokens
           ) {
            // The window head moves at most once per turn, oldest-first, and
            // never in a turn compaction already rewrote (see
            // HistoryWindowCursor). The turn-id guard inside the store makes a
            // tool loop's later iterations no-ops by construction, so a lane
            // that rebuilds context per iteration cannot slide the prefix
            // mid-turn.
            let cursorStore = HistoryWindowCursorStore(dataRoot: historyReader.dataRoot)
            let advance = try await cursorStore.advanceIfNeeded(
                sessionId: sessionId,
                admitted: admission.rows,
                budgetChars: historyBudget.historyChars,
                // The bound that actually bites: char pressure never fires
                // because the reader hands us a pre-trimmed slice. Enforced
                // ONCE per several turns instead of every turn.
                rowCap: prefixRowCap,
                turnId: TurnTraceContext.turnId,
                compactionRanThisTurn: HistoryWindowTurnFacts.compactionRanThisTurn
            )
            // Replay earlier turns' turn-scoped system messages ONLY where the
            // provider actually supports clear_at. Everywhere else the block was
            // never sent as a system message in the first place, so there is
            // nothing to keep byte-stable and replaying one would ADD a message
            // the previous request did not have — the same divergence, mirrored.
            // Replay is per-CAPABILITY, not per-lane: a turn-scoped block is
            // only replayable where clear_at is supported. An archived
            // tool-change message is never replayed: `app` is the whole tools
            // array, so the names it adds or removes are declared nowhere.
            let replaysClearAt = supportsMidConversationSystemClearAt(forModel: base.modelId)
            var archivedTurnMessages: [String: [LLMMessage]] = [:]
            let archive = await TurnVolatileArchiveRegistry.shared
                .archive(dataRoot: historyReader.dataRoot)
            if replaysClearAt {
                archivedTurnMessages = await archive.load(sessionId: sessionId)
                    .mapValues { entries in
                        entries.filter { $0.toolChanges.isEmpty }.map(\.message)
                    }
                    .filter { !$0.value.isEmpty }
            }
            let projected = SessionHistoryMessageProjection.project(
                admission,
                cursor: advance.cursor,
                archivedTurnMessages: archivedTurnMessages
            )
            // Bound the sidecar to the window the prefix actually replays: when
            // the cursor drops a turn, its archived messages go with it.
            if !archivedTurnMessages.isEmpty {
                await archive.prune(
                    sessionId: sessionId, keeping: projected.replayedRunIds
                )
            }
            replayedRunIds = projected.replayedRunIds
            historyMessages = projected.messages
            for message in historyMessages {
                for case .text(let text) in message.content {
                    SwiftToolDispatcher.consumeRenderedToolReceipt(text)
                }
            }
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
        let receiptStrip = SessionHistoryPromptRenderer.recentReceiptStrip(from: prior)
        if let receiptStrip, let evidence = try? JSONValue.parse(Data(receiptStrip.utf8)) {
            SwiftToolDispatcher.consumePersistedHistoryEvidence(evidence)
        }
        let historyParts = [renderedHistory, SessionHistoryPromptRenderer.worldRecord(from: prior), receiptStrip].compactMap { $0 }
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
            contextWithHistory.historyMessages = historyMessages
            contextWithHistory.historyWindowReceipt = historyWindowReceipt
        }
        let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
        let clocked = await contextByAppendingCurrentTurnFacts(
            contextWithHistory, facts: currentFacts, sessionID: sessionId, clockNowOverride: clockNowOverride)
        var finalContext = Self.contextBySettingNaturalExpressionCue(
            clocked,
            cue: naturalExpressionCue
        )
        trace.record(ContextHistoryStageName.contextClockRuntime, since: runtimeStartNs)
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
    ) async throws -> TurnContext {
        // Guard before provider/cache access: a surface that did not ask for
        // the carry-over never reads or writes anchor bytes.
        guard let provider else { return base }
        guard MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: provider.dataRoot) else { return base }
        // FIRST TURN ONLY. The anchor exists to hand a BRAND-NEW session the
        // thread it was cut from. From turn 2 the session's own history block
        // carries that thread, and re-injecting two lines that point at a
        // conversation she has already moved past is duplication paid for on
        // every turn. `prior` rows are the same signal the history guard below
        // uses — non-empty prior ⇒ a history block renders — and the current
        // turn's own user row is excluded by runId, so turn 1 is empty here.
        guard !hasPriorHistory else { return base }
        let digest: String
        do {
            guard let value = try await provider.digest(
                forSessionId: sessionId, model: base.modelId, surface: base.surface, userMessage: base.userMessage),
                  !value.isEmpty else { return base }
            digest = value
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            TurnTraceBus.fireFromContext(
                kind: "context.digest.failed", sessionId: sessionId, surface: base.surface,
                payload: .object(["reason": .string(String(describing: error))])
            )
            return base
        }
        var copy = base
        copy.turnReach.digest = digest
        return copy
    }
}
