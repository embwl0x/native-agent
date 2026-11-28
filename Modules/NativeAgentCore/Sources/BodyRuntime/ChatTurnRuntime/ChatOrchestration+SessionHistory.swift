import Foundation
import MindCore
import NativeAgentCore
import Synchronization
import PersistenceCore
import SenseCore
import ProviderRouting
import DeskCore
// Blueprint: | `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`; `fireAssemblyStageEvent` |

// MARK: - SwiftNativeTurnEngine + history threading

extension SwiftNativeTurnEngine {
    /// Forward the Mac persona override into the packet; nil uses the selected persona.
    /// Returns the instant its `context.history.summary` closed, so the caller can time its own return from it.
    public func buildTurnContextWithHistory(
        surface: String,
        userMessage: String,
        sessionId: String,
        historyLimit: Int,
        historyReader: SessionHistoryReader,
        personaOverride: String?,
        excludeHistoryRunId: String? = nil,
        imageBlocks: [LLMContentBlock] = [],
        // Relevance uses raw user text without turn-scoped wire hints; nil uses `userMessage`.
        queryUserMessage: String? = nil,
        // The caller's clock read opening `turn.history_context`, so the hop onto this actor is a timed step.
        startedNs: UInt64,
        turn: Turn, work: ChatTurnWork
    ) async throws -> (context: TurnContext, closedNs: UInt64) {
        var trace = ContextStageTrace(turn: turn, partitioning: .historyBuild, startedNs: startedNs)
        trace.record(.historyEntry, since: startedNs, of: .historyBuild)
        let budgetStart = DispatchTime.now().uptimeNanoseconds
        let historyBudget = try ContextBudgetPolicy.resolve(turn: turn, dataRoot: historyReader.dataRoot)
        trace.record(.historyBudget, since: budgetStart, of: .historyBuild)
        // A non-nil queryUserMessage is authoritative even when blank, including attachment-only turns.
        let queryMessage = queryUserMessage ?? userMessage
        let replacementAnswerID = turn.rows.replacementAssistantMessageID
        // One instant and preference snapshot feed facts, base receipts and composition.
        let currentTurnClock = clock()
        let quietHoursStart = DispatchTime.now().uptimeNanoseconds
        let quietHoursWindow = try readTurnQuietHours()
        trace.record(.historyQuietHours, since: quietHoursStart, of: .historyBuild)
        // Gather independent facts beside history and context; defer consuming and peer-sensitive reads until history binds its evidence.
        async let currentFacts = try currentTurnFacts(
            clockNow: currentTurnClock,
            quietHours: quietHoursWindow,
            sessionID: sessionId,
            queryUserMessage: queryMessage, turn: turn, work: work
        )
        let build = HistoryContextBuild(trace: trace)
        let (prior, priorStats, replacementQuestion) = try await readPromptHistory(build, sessionId: sessionId, surface: surface,
            historyLimit: historyLimit, historyReader: historyReader,
            excludeHistoryRunId: excludeHistoryRunId, replacementAnswerID: replacementAnswerID, turn: turn)
        let (base, preparedHistory) = try await buildHistoryBase(build, prior: prior, surface: surface,
            userMessage: userMessage, sessionId: sessionId, personaOverride: personaOverride, imageBlocks: imageBlocks,
            queryMessage: queryMessage, currentTurnClock: currentTurnClock, quietHoursWindow: quietHoursWindow,
            historyBudget: historyBudget, turn: turn, work: work)
        let contextWithHistory = historyThreadedContext(build, base: base, prior: prior, priorStats: priorStats,
            preparedHistory: preparedHistory, historyLimit: historyLimit, historyBudget: historyBudget,
            queryMessage: queryMessage, excludeHistoryRunId: excludeHistoryRunId,
            replacementQuestion: replacementQuestion)
        trace = build.trace
        let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
        let facts = try await currentFacts
        let joinedNs = DispatchTime.now().uptimeNanoseconds
        trace.record(.factsJoin, since: runtimeStartNs, until: joinedNs, of: .historyBuild)
        let clocked = try await contextByAppendingCurrentTurnFacts(
            contextWithHistory, facts: facts, sessionID: sessionId, clockNowOverride: currentTurnClock, trace: &trace, turn: turn, work: work)
        var finalContext = clocked
        let composedNs = DispatchTime.now().uptimeNanoseconds
        trace.record(.factsCompose, since: joinedNs, until: composedNs, of: .historyBuild)
        trace.record(ContextStageName.contextClockRuntime, since: runtimeStartNs, until: composedNs)
        trace.setCount("userMessageChars", finalContext.userMessage.count)
        trace.setCount("toolSchemaCount", finalContext.toolSchemas.count)
        let closedNs = DispatchTime.now().uptimeNanoseconds
        finalContext.preparationMs = trace.emit(kind: "context.history.summary", surface: surface, closedAt: closedNs)
        return (finalContext, closedNs)
    }

    /// The conversation's verbatim history from one transcript read, before any replaced question; a failed read is owed repair.
    private func readPromptHistory(
        _ build: HistoryContextBuild, sessionId: String, surface: String, historyLimit: Int,
        historyReader: SessionHistoryReader, excludeHistoryRunId: String?,
        replacementAnswerID: String?, turn: Turn
    ) async throws -> (prior: [HistoryChatMessage], priorStats: SessionHistoryReadStats, replacementQuestion: String?) {
        var trace = build.trace
        let replacementQuestion = Mutex(turn.rows.replacementUserMessageID)
        @Sendable func beforeReplacedQuestion(_ messages: [HistoryChatMessage]) -> [HistoryChatMessage] {
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
            return SessionHistoryTail.select(messages, beforeQuestionID: id, excludingRunID: excludeHistoryRunId)
        }
        // Read verbatim history once; fitting selects its tail and positive history limits never cap rows.
        let prior: [HistoryChatMessage]
        let priorStats: SessionHistoryReadStats
        if sessionId == Attention.stream {
            // The agent's own stream is never replayed: a thought carries its breath and what it attends.
            prior = []
            priorStats = SessionHistoryReadStats(mode: "mind_stream")
        } else if historyLimit > 0 {
            // Select every history region from the same transcript bytes to avoid mixing generations.
            let selected: SessionHistoryReadResult
            // Measured inline: the read's closure holds actor state and cannot be sent to the trace.
            let promptReadStart = DispatchTime.now().uptimeNanoseconds
            do {
                let readStart = DispatchTime.now().uptimeNanoseconds
                let read = try await historyReader.transcriptBytes(forSessionId: sessionId)
                let readNs = DispatchTime.now().uptimeNanoseconds &- readStart
                trace.record(.promptReadFile, nanoseconds: read.fileNanoseconds, of: .promptRead)
                trace.record(.promptReadReaderHop, nanoseconds: readNs &- read.fileNanoseconds, of: .promptRead)
                selected = historyReader.promptMessagesWithStats(transcript: read.bytes)
                let replay = selected.stats
                trace.record(.promptReadLines, nanoseconds: replay.splitNanoseconds, of: .promptRead)
                trace.record(.promptReadRowMemo, nanoseconds: replay.rowMemoNanoseconds, of: .promptRead)
                trace.record(.promptReadSelect, nanoseconds: replay.selectNanoseconds, of: .promptRead)
                trace.record(.promptReadMemoWrite, nanoseconds: replay.memoWriteNanoseconds, of: .promptRead)
                prior = beforeReplacedQuestion(try selected.checkedMessages())
                trace.record(.promptRead, since: promptReadStart, of: .historyBuild)
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
                    payload: .object(["code": .string("transcript_unavailable"), "reason": .string(error.localizedDescription)]), turn: turn)
                throw failure
            }
            if selected.stats.mode != "missing" {
                RepairOwed.settle(historyReader.dataRoot, operation: "chat.history:\(sessionId)",
                    evidence: .init(source: "transcript", id: sessionId))
            }
            priorStats = selected.stats
        } else {
            prior = []
            priorStats = SessionHistoryReadStats(mode: "history_disabled")
        }
        build.trace = trace
        return (prior, priorStats, replacementQuestion.withLock { $0 })
    }

    /// The base context, built with history's exchanges as its relevance window.
    private func buildHistoryBase(
        _ build: HistoryContextBuild, prior: [HistoryChatMessage], surface: String, userMessage: String, sessionId: String,
        personaOverride: String?, imageBlocks: [LLMContentBlock], queryMessage: String, currentTurnClock: Date,
        quietHoursWindow: TurnQuietHoursWindow?, historyBudget: ContextBudgetPolicy.Resolved, turn: Turn, work: ChatTurnWork
    ) async throws -> (base: TurnContext, preparedHistory: [SessionHistoryPromptRenderer.Renderable]) {
        var trace = build.trace
        let preparedHistory = await trace.measure(.prepare, of: .historyBuild) {
            prior.compactMap(SessionHistoryPromptRenderer.renderable)
        }
        let exchangesStart = DispatchTime.now().uptimeNanoseconds
        // Use the transcript owner's exchange pairing, including repeated runs
        // and interrupted replies. The four-message relevance window is not a clock.
        let paired = ConversationHistory.pairExchanges(prior.map {
            (sessionId, $0.extras?.objectValue?["runId"]?.stringValue, $0.role,
             $0.role == "user" || $0.role == "assistant")
        })
        var exchangeWords: [Int: [String]] = [:]
        var exchangeOrder: [Int] = []
        // Use the actual earlier request within the bounded relevance window. Keep full origin and trust framing in replay.
        func relevanceWords(_ row: HistoryChatMessage) -> String {
            let origin = row.extras?.objectValue?["metadata"]?.objectValue?["origin"]?.objectValue
            guard row.role == "user", origin?["surface"] == .string("agent-bridge"), origin?["authored"] == .string("agent"),
                  row.content.hasPrefix(PeerTurnEffectPolicy.turnHeaderOpening) else { return row.content }
            return PeerTurnEffectPolicy.contactMessage(in: row.content) ?? row.content
        }
        for entry in paired {
            if exchangeWords[entry.exchange] == nil {
                exchangeOrder.append(entry.exchange)
                exchangeWords[entry.exchange] = []
            }
            if prior[entry.row].role == "user" {
                exchangeWords[entry.exchange, default: []].append(relevanceWords(prior[entry.row]))
            }
        }
        // Built in the order the call evaluated them, so the base step times only the inner builder.
        let recentTurns = prior.filter { $0.role == "user" || $0.role == "assistant" }.suffix(4).map(relevanceWords)
        let recentExchanges = exchangeOrder.map { exchangeWords[$0, default: []] }
        let offeredToolNames = SwiftToolDispatcher.alwaysOnCoreNames
        let baseStartNs = DispatchTime.now().uptimeNanoseconds
        trace.record(.historyExchanges, since: exchangesStart, until: baseStartNs, of: .historyBuild)
        let rawBase: TurnContext
        do {
            let built = try await buildTurnContext(
                surface: surface,
                userMessage: userMessage,
                personaOverride: personaOverride,
                imageBlocks: imageBlocks,
                recallQueryOverride: nil,
                includeClockContext: false,
                sessionID: sessionId,
                recentTurns: recentTurns,
                recentExchanges: recentExchanges,
                queryUserMessage: queryMessage,
                clockNowOverride: currentTurnClock,
                quietHoursSnapshot: quietHoursWindow,
                offeredToolNames: offeredToolNames,
                recallHistory: preparedHistory,
                budget: historyBudget,
                startedNs: baseStartNs,
             turn: turn, work: work)
            // The base step ends where the inner summary closed, so it equals that summary's total exactly.
            let returnedNs = DispatchTime.now().uptimeNanoseconds
            rawBase = built.context
            trace.record(.contextBase, since: baseStartNs, until: built.closedNs, of: .historyBuild)
            trace.record(.contextBaseReturn, since: built.closedNs, until: returnedNs, of: .historyBuild)
        } catch {
            trace.record(.contextBase, since: baseStartNs)
            throw error
        }
        let base = rawBase
        build.trace = trace
        return (base, preparedHistory)
    }

    /// History admitted onto the base context: replayed messages, receipts and the replay spec that refits them.
    private func historyThreadedContext(
        _ build: HistoryContextBuild, base: TurnContext, prior: [HistoryChatMessage], priorStats: SessionHistoryReadStats,
        preparedHistory: [SessionHistoryPromptRenderer.Renderable], historyLimit: Int,
        historyBudget: ContextBudgetPolicy.Resolved, queryMessage: String, excludeHistoryRunId: String?,
        replacementQuestion: String?
    ) -> TurnContext {
        var trace = build.trace
        var historyMessages: [LLMMessage] = []
        var historyMessageChars = 0
        var replayedRunIds = Set<String>()
        var heldRows = 0
        var historyRowCharacters: [String: Int] = [:]
        var historySnapshot: SessionHistoryTail?
        var contextWindow = "0:"
        let admissionStart = DispatchTime.now().uptimeNanoseconds
        if let admission = SessionHistoryMessages.admission(
            renderables: preparedHistory,
            historyLimit: historyLimit,
            budget: historyBudget
           ) {
            let projected = SessionHistoryMessages.project(admission)
            heldRows = admission.heldRows
            historyRowCharacters = projected.rowCharacters
            historySnapshot = SessionHistoryTail(admission, rowCharacters: projected.rowCharacters)
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
        trace.record(.historyAdmission, since: admissionStart, of: .historyBuild)
        trace.setLabel("prefix.shapeVersion", "v2Prefix")
        trace.setCount("prefix.historyMessageCount", historyMessages.count)
        trace.setCount("prefix.historyMessageChars", historyMessageChars)
        trace.setCount("prefix.replayedTurnCount", replayedRunIds.count)
        // Admission holds the conversation whole; request fitting reports the rows kept within the input budget.
        trace.setCount("history.heldRows", heldRows)
        trace.setCount("history.reachedRows", preparedHistory.count - heldRows)
        trace.setCount("budget.windowTokens", historyBudget.windowTokens ?? 0)
        trace.setFlag("budget.derived", historyBudget.isDerived)
        trace.setCount("budget.memoryBlockChars", historyBudget.memoryBlockChars)
        trace.setCount("budget.recallRowLimit", historyBudget.recallRowLimit)
        // History labels untrusted words without steering the new turn. Only that turn's own restored provenance steers it.
        let worldStart = DispatchTime.now().uptimeNanoseconds
        let historyBlock = SessionHistoryPromptRenderer.worldRecord(from: prior)
        trace.record(.historyWorld, since: worldStart, of: .historyBuild)
        trace.setCount("history.prompt.sourceBytes", priorStats.sourceBytes)
        trace.setCount("history.prompt.bytesRead", priorStats.bytesRead)
        trace.setCount("history.prompt.linesRead", priorStats.linesRead)
        trace.setCount("history.prompt.decoded", priorStats.decodedCount)
        trace.setCount("history.prompt.decodeCacheHits", priorStats.decodeCacheHits)
        trace.setCount("history.prompt.decodeCacheMisses", priorStats.decodeCacheMisses)
        trace.setCount("history.prompt.excludedByRunId", priorStats.excludedByRunId)
        trace.setCount("history.prompt.returned", priorStats.returnedCount)
        trace.setFlag("history.prompt.truncated", priorStats.truncated)
        trace.setCount("history.priorCount", prior.count)
        trace.setCount("historyBlockChars", historyBlock?.count ?? 0)
        // The tail supplies history; current facts and recall keep their own owners.
        var contextWithHistory = base
        if let historyBlock {
            contextWithHistory.turnReach.history = historyBlock
        }
        contextWithHistory.historyMessages = historyMessages
        contextWithHistory.historyRowCharacters = historyRowCharacters
        contextWithHistory.historyReplaySpec = SessionReplaySpec(historyLimit: historyLimit,
            excludedRunID: excludeHistoryRunId,
            replacementUserMessageID: replacementQuestion)
        contextWithHistory.historyReplaySpec?.historySnapshot = historySnapshot
        contextWithHistory.historyReplaySpec?.historyReceipts = { heldIdentities in
            ChatTranscriptEvidenceRendering.recentReceiptStrip(from: prior, excluding: heldIdentities)
        }
        contextWithHistory.historyReplaySpec?.historyLeads = { heldIdentities in
            SessionHistoryPromptRenderer.renderDetailed(
                renderables: preparedHistory,
                deliveredHistoryIdentities: heldIdentities,
                userMessage: queryMessage,
                historyLimit: historyLimit,
                budget: historyBudget
            ).text
        }
        contextWithHistory.historyContextWindow = contextWindow
        build.trace = trace
        return contextWithHistory
    }

    /// One history-threaded context build: the trace its stages record into, in order.
    final class HistoryContextBuild {
        var trace: ContextStageTrace
        init(trace: ContextStageTrace) { self.trace = trace }
    }

    /// Emit bounded counts only: prompt text is secret-dense and must never enter trace payloads.
    /// Segment counts distinguish stable, dynamic, history and current mass; breakpoint metadata describes cache placement.
    nonisolated static func fireAssemblyStageEvent(surface: String, context: TurnContext, turn: Turn) {
        let segments = context.systemSegments
        let historyBlock = context.turnReach.history
        let historyMessageChars = context.historyMessages.reduce(0) { total, message in
            total + message.content.reduce(0) { if case .text(let text) = $1 { $0 + text.count } else { $0 } }
        }
        let systemTotal = context.systemPrompt?.count ?? 0
        let stableChars = segments?.stable.count ?? 0
        let dynamicChars = segments?.dynamic.count ?? 0
        let historyChars = historyBlock.count
        // Separate recall/extras from history so the Inspector distinguishes their different weighting.
        let dynamicNonHistoryChars = max(0, dynamicChars - historyChars
            - (historyChars > 0 && dynamicChars > historyChars ? 2 : 0))
        let payload: [String: JSONValue] = [
            "stableChars": .int(Int64(stableChars)),
            "dynamicChars": .int(Int64(dynamicChars)),
            "dynamicNonHistoryChars": .int(Int64(dynamicNonHistoryChars)),
            "historyChars": .int(Int64(historyChars)),
            "currentChars": .int(Int64(context.userMessage.count)),
            "systemTotalChars": .int(Int64(systemTotal)),
            "recalledCount": .int(Int64(context.recalled.count)),
            // A stable/dynamic split permits a cache breakpoint after the stable segment; count only distinct cacheable regions.
            "segmented": .bool(segments != nil),
            "segmentCount": .int(Int64(segments != nil ? 2 : 1)),
            // Count replayed messages separately from system text and record whether the replay head moved.
            "shapeVersion": .string("v2Prefix"),
            "historyMessageCount": .int(Int64(context.historyMessages.count)),
            "historyMessageChars": .int(Int64(historyMessageChars)),
        ]
        TurnTraceBus.fireFromContext(
            kind: "assembly.stage",
            surface: surface,
            payload: .object(payload),
            turn: turn
        )
    }
}
