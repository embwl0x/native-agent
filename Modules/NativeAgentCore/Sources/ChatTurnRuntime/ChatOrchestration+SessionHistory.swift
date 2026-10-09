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
        quietHoursSnapshot: TurnQuietHoursSnapshot? = nil
    ) async throws -> TurnContext {
        // Non-nil queryUserMessage is authoritative EVEN WHEN BLANK — an
        // attachment-only text-compat turn must not fall back to the hinted
        // wire message (gpt-5.5 review 2026-08-13, NEEDS-FIX #1).
        let queryMessage = queryUserMessage ?? userMessage
        var trace = ContextStageTrace()
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
            let priorResult = (try? await trace.measure(.promptRead) {
                try await historyReader.promptMessagesWithStats(
                    forSessionId: sessionId,
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
                )
            }) ?? SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "prompt_read_failed")
            )
            prior = priorResult.messages
            priorStats = priorResult.stats
            if prior.count > historyLimit || priorStats.sourceBytes > priorStats.bytesRead {
                let middleResult = (try? await trace.measure(.middleSample) {
                    try await historyReader.relevanceMessagesWithStats(
                        forSessionId: sessionId,
                        excludingRunId: excludeHistoryRunId
                    )
                }) ?? SessionHistoryReadResult(
                    messages: prior,
                    stats: SessionHistoryReadStats(mode: "middle_read_failed")
                )
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
        // Capture once at the outer turn boundary. The base builder owns the
        // receipt flag and this history wrapper owns final clock rendering;
        // both must observe the same preference bytes without a second read.
        let quietHoursWindow: TurnQuietHoursWindow?
        if let quietHoursSnapshot {
            quietHoursWindow = quietHoursSnapshot.window
        } else {
            quietHoursWindow = readTurnQuietHours()
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
        let naturalExpressionCue = naturalExpressionGuidanceEnabled
            ? NaturalExpressionGuidance.pendingCues(from: prior, userMessage: queryMessage)
            : nil
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
            windowTokens: historyWindowTokens,
            surface: surface
        )
        let preparedMiddle = middleStats == nil
            ? preparedHistory : middleCandidates.compactMap(SessionHistoryPromptRenderer.renderable)
        let renderedHistory = await trace.measure(.render) {
            SessionHistoryPromptRenderer.renderDetailed(
                renderables: preparedHistory,
                middleCandidates: preparedMiddle,
                userMessage: queryMessage,
                surface: surface,
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
            surface: surface,
            windowTokens: historyWindowTokens
           ) {
            // The window head moves at most once per turn, oldest-first, and
            // never in a turn compaction already rewrote (see
            // HistoryWindowCursor). The turn-id guard inside the store makes a
            // tool loop's later iterations no-ops by construction, so a lane
            // that rebuilds context per iteration cannot slide the prefix
            // mid-turn.
            let cursorStore = await HistoryWindowCursorStoreRegistry.shared
                .store(dataRoot: historyReader.dataRoot)
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
        let historyParts = [renderedHistory.historyBlock, receiptStrip].compactMap { $0 }
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
        // The prior-session ANCHOR (two lines, one of them a pointer) is
        // injected at the HEAD of the DYNAMIC segment — after persona + REM
        // pins, before the dynamic recall/history mass — on the churning side
        // of the cache breakpoint. Its bytes change per session, so keeping it
        // out of the stable block is what lets the stable-end breakpoint hit
        // ACROSS sessions (see injectingSessionDigest). Injection happens
        // BEFORE the history guard below on purpose: the session's FIRST turn
        // has no renderable history and early-returns there, and the first
        // turn is the ONLY turn the anchor belongs on.
        guard let historyBlock else {
            let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
            let clockedBase = await contextByAppendingCurrentTurnFacts(
                base,
                clockNowOverride: clockNowOverride,
                quietHours: quietHoursWindow,
                sessionID: sessionId,
                queryUserMessage: queryMessage
            )
            var finalBase = Self.contextBySettingNaturalExpressionCue(
                clockedBase,
                cue: naturalExpressionCue
            )
            trace.record(ContextHistoryStageName.contextClockRuntime, since: runtimeStartNs)
            trace.setCount("system.stableChars", finalBase.systemSegments?.stable.count ?? 0)
            trace.setCount("system.dynamicChars", finalBase.systemSegments?.dynamic.count ?? 0)
            trace.setCount("system.combinedChars", finalBase.systemPrompt?.count ?? 0)
            trace.setCount("userMessageChars", finalBase.userMessage.count)
            trace.setCount("toolSchemaCount", finalBase.toolSchemas.count)
            finalBase.preparationMs = trace.emit(kind: "context.history.summary", surface: surface)
            // Turn Inspector W2: emit assembly.stage for the no-history case
            // too (a session's FIRST turn renders no history) — SIZES ONLY.
            Self.fireAssemblyStageEvent(
                surface: surface,
                segments: finalBase.systemSegments,
                combinedSystemPrompt: finalBase.systemPrompt,
                historyBlock: nil,
                userMessage: finalBase.userMessage,
                recalledCount: finalBase.recalled.count
            )
            return finalBase
        }
        // CACHING CONTRACT (U1 step 2, 2026-06-10): segment order is
        // STABLE → SEMI-STABLE → DYNAMIC. Provider prompt caches are prefix
        // matches, so the system prompt must keep its stable bytes first:
        //   [persona packet (identity block handled by the adapter)]
        //   → [REM pins]                     (the STABLE, cacheable mass)
        //   → [session digest (U3 item 8, per-session — DYNAMIC head)]
        //   → [memory recall]                (base.systemPrompt, in order)
        //   → [history block]                (per-turn dynamic, appended)
        // The user message stays in messages[]. Do NOT prepend dynamic
        // content above the persona — history at byte 0 churns the entire
        // prefix every turn and defeats prompt caching. History at the TAIL
        // stays in a high-attention zone (end of system prompt, adjacent to
        // the user message), so recency weighting is preserved.
        let combinedWithoutClock: String
        if let existing = base.systemPrompt, !existing.isEmpty {
            combinedWithoutClock = existing + "\n\n" + historyBlock
        } else {
            combinedWithoutClock = historyBlock
        }
        // U1 step 2b/3b: the history block is per-turn DYNAMIC content, so
        // it joins the dynamic segment tail; the stable segment
        // (persona+pins) is untouched.
        // INVARIANT: systemPrompt == segments.stable + "\n\n" + segments.dynamic
        //            (i.e. combined == segments.combined — empty segments
        //            collapse the separator). The Anthropic adapters verify
        //            this byte-for-byte before splitting system blocks, so
        //            the split can never change model-visible content.
        let segmentsWithoutClock: SystemPromptSegments? = base.systemSegments.map { seg in
            SystemPromptSegments(
                stable: seg.stable,
                stableSuffix: seg.stableSuffix,
                dynamic: seg.dynamic.isEmpty
                    ? historyBlock
                    : seg.dynamic + "\n\n" + historyBlock
            )
        }
        let contextWithHistory = TurnContext(
            surface: base.surface,
            personaID: base.personaID,
            personaDocs: base.personaDocs,
            personaFingerprint: base.personaFingerprint,
            recalled: base.recalled,
            modelId: base.modelId,
            reasoningEffort: base.reasoningEffort,
            providerId: base.providerId,
            serviceTier: base.serviceTier,
            toolsAvailable: base.toolsAvailable,
            systemPrompt: combinedWithoutClock,
            userMessage: base.userMessage,
            toolSchemas: base.toolSchemas,
            systemSegments: segmentsWithoutClock,
            imageBlocks: base.imageBlocks,
            fluidContextTurn: base.fluidContextTurn,
            naturalExpressionCue: base.naturalExpressionCue,
            historyMessages: historyMessages,
            turnVolatileBlock: base.turnVolatileBlock,
            historyWindowReceipt: historyWindowReceipt,
            preparationMs: base.preparationMs
        )
        let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
        let clocked = await contextByAppendingCurrentTurnFacts(
            contextWithHistory,
            clockNowOverride: clockNowOverride,
            quietHours: quietHoursWindow,
            sessionID: sessionId,
            queryUserMessage: queryMessage
        )
        var finalContext = Self.contextBySettingNaturalExpressionCue(
            clocked,
            cue: naturalExpressionCue
        )
        trace.record(ContextHistoryStageName.contextClockRuntime, since: runtimeStartNs)
        trace.setCount("system.stableChars", finalContext.systemSegments?.stable.count ?? 0)
        trace.setCount("system.dynamicChars", finalContext.systemSegments?.dynamic.count ?? 0)
        trace.setCount("system.combinedChars", finalContext.systemPrompt?.count ?? 0)
        trace.setCount("userMessageChars", finalContext.userMessage.count)
        trace.setCount("toolSchemaCount", finalContext.toolSchemas.count)
        finalContext.preparationMs = trace.emit(kind: "context.history.summary", surface: surface)
        // Turn Inspector W2: observe the per-turn system prompt that was just
        // assembled and fire ONE assembly.stage event carrying segment SIZES
        // (char counts) only — NEVER the content (the system prompt is the most
        // secret-dense string in the app). Read-only: this does NOT reorder,
        // rebuild, or touch the assembly (U1 invariant) — it measures `combined`
        // / `segments` / `historyBlock` AFTER they are built.
        Self.fireAssemblyStageEvent(
            surface: surface,
            segments: finalContext.systemSegments,
            combinedSystemPrompt: finalContext.systemPrompt,
            historyBlock: historyBlock,
            userMessage: finalContext.userMessage,
            recalledCount: finalContext.recalled.count,
            historyMessageCount: historyMessages.count,
            historyMessageChars: historyMessageChars,
            windowCursorAdvanceCount: historyWindowReceipt?.advanceCount ?? 0,
            windowSlid: historyWindowReceipt?.slid ?? false
        )
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
    /// Segment sizes reported:
    ///   - stable: persona packet + REM pins (+ session digest) — the cacheable
    ///     mass. Reported as ONE count because the combine site sees it as one
    ///     string (`segments.stable`); the persona/pins split happens upstream
    ///     in `buildTurnContext` and is not re-derivable here without rebuilding.
    ///   - dynamicNonHistory: the dynamic segment MINUS the history block
    ///     (i.e. memory recall + per-turn extras).
    ///   - history: the rendered session-history block.
    ///   - current: the current user message.
    ///   - systemTotal: the full combined system prompt length.
    /// Plus `recalledCount` (memory recall hit count) and `breakpointZone`
    /// (whether a stable/dynamic split exists, which drives Anthropic
    /// cache_control breakpoint placement).
    nonisolated static func fireAssemblyStageEvent(
        surface: String,
        segments: SystemPromptSegments?,
        combinedSystemPrompt: String?,
        historyBlock: String?,
        userMessage: String,
        recalledCount: Int,
        // v2Prefix receipts. Sizes and a version label only — never content.
        historyMessageCount: Int = 0,
        historyMessageChars: Int = 0,
        windowCursorAdvanceCount: Int = 0,
        windowSlid: Bool = false
    ) {
        let systemTotal = combinedSystemPrompt?.count ?? 0
        let stableChars = segments?.stable.count ?? 0
        let dynamicChars = segments?.dynamic.count ?? 0
        let historyChars = historyBlock?.count ?? 0
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
            "currentChars": .int(Int64(userMessage.count)),
            "systemTotalChars": .int(Int64(systemTotal)),
            "recalledCount": .int(Int64(recalledCount)),
            // Cache-relevant: a non-nil split means the adapter can place the
            // sys cache_control breakpoint at the end of the STABLE mass (the
            // U1 segmented layout). Segment count == number of cacheable
            // system regions the breakpoint logic distinguishes.
            "segmented": .bool(segments != nil),
            "segmentCount": .int(Int64(segments != nil ? 2 : 1)),
            // v2Prefix: how much of the turn now rides as REPLAYED MESSAGES
            // instead of system-prompt text, and whether the window head moved.
            "shapeVersion": .string("v2Prefix"),
            "historyMessageCount": .int(Int64(historyMessageCount)),
            "historyMessageChars": .int(Int64(historyMessageChars)),
            "windowCursorAdvanceCount": .int(Int64(windowCursorAdvanceCount)),
            "windowSlid": .bool(windowSlid),
        ]
        TurnTraceBus.fireFromContext(
            kind: "assembly.stage",
            surface: surface,
            payload: .object(payload)
        )
    }

    /// U3 wave-2 item 8: inject the per-session digest at the HEAD of the
    /// DYNAMIC segment. Rebuilds `systemPrompt` from the new segments so the
    /// adapter-verified invariant `systemPrompt == stable + "\n\n" + dynamic`
    /// holds by construction. Fail-open on every edge:
    ///   - no systemSegments on the context → no safe mid-string insertion
    ///     point → return the context unchanged (legacy combined behavior)
    ///   - provider returns nil/empty (fresh session, source errors, blank
    ///     sessionId) → unchanged.
    ///
    /// CACHE-CORRECTNESS (2026-07-24): this used to append to the END of the
    /// STABLE segment, on the reasoning that "the provider caches per session,
    /// so the injected bytes are identical on every turn of the session".
    /// That premise is FALSE. Anthropic's prompt cache is an exact-prefix
    /// match scoped to the ORGANIZATION, not to a session — a prefix written
    /// by session A is readable by session B iff the bytes match. The digest
    /// describes the PREVIOUS session (its title, message count, end
    /// timestamp, and activity list), so it changes on every new session and
    /// on background activity. Sitting inside the stable segment, it churned
    /// the tail of the block the stable-end cache_control breakpoint covers,
    /// so that breakpoint could only ever hit WITHIN one session and was a
    /// guaranteed miss ACROSS sessions. Measured: two identical bridge turns
    /// 7s apart shared 10,605 bytes of stable prefix and then diverged inside
    /// the "# Since last session" block — cacheRead=0 on both, paying the
    /// 1.25x write premium every turn and never collecting the 0.1x read.
    ///
    /// Moving it to the head of the DYNAMIC segment is byte-identical in
    /// `combined` for all four emptiness cases (empty segments collapse the
    /// "\n\n" separator, so stable+"\n\n"+digest+"\n\n"+dynamic is produced
    /// either way) — the model sees exactly the same system prompt, in the
    /// same order. Only the breakpoint boundary moves: the stable block is
    /// now persona packet + REM pins ONLY, which is genuinely invariant
    /// across sessions and therefore cacheable across them.
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
        guard let seg = base.systemSegments else { return base }
        guard let digest = try await provider.digest(
            forSessionId: sessionId, model: base.modelId, surface: base.surface, userMessage: base.userMessage),
              !digest.isEmpty else { return base }
        let dynamic = seg.dynamic.isEmpty ? digest : digest + "\n\n" + seg.dynamic
        let segments = SystemPromptSegments(
            stable: seg.stable, stableSuffix: seg.stableSuffix, dynamic: dynamic
        )
        return TurnContext(
            surface: base.surface,
            personaID: base.personaID,
            personaDocs: base.personaDocs,
            personaFingerprint: base.personaFingerprint,
            recalled: base.recalled,
            modelId: base.modelId,
            reasoningEffort: base.reasoningEffort,
            providerId: base.providerId,
            serviceTier: base.serviceTier,
            toolsAvailable: base.toolsAvailable,
            systemPrompt: segments.combined,
            userMessage: base.userMessage,
            toolSchemas: base.toolSchemas,
            systemSegments: segments,
            imageBlocks: base.imageBlocks,
            fluidContextTurn: base.fluidContextTurn,
            naturalExpressionCue: base.naturalExpressionCue,
            historyMessages: base.historyMessages,
            turnVolatileBlock: base.turnVolatileBlock,
            historyWindowReceipt: base.historyWindowReceipt,
            preparationMs: base.preparationMs
        )
    }
}
