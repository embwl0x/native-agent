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
// Blueprint: | `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`; `fireAssemblyStageEvent` |

// MARK: - SwiftNativeTurnEngine + history threading

extension SwiftNativeTurnEngine {
    /// Forward the Mac persona override into the packet; nil uses the selected persona.
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
        // Reuse the turn-start instant for the clock line on every iteration.
        clockNowOverride: Date? = nil,
        // Supplied bytes and disk reads share the same replay path.
        transcript: Data? = nil,
        turn: Turn, work: ChatTurnWork
    ) async throws -> TurnContext {
        let historyBudget = try ContextBudgetPolicy.resolve(turn: turn, dataRoot: historyReader.dataRoot)
        // A non-nil queryUserMessage is authoritative even when blank, including attachment-only turns.
        let queryMessage = queryUserMessage ?? userMessage
        let replacementAnswerID = turn.rows.replacementAssistantMessageID
        let replacementQuestion = OSAllocatedUnfairLock(initialState: turn.rows.replacementUserMessageID)
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
            return SessionHistoryTail.select(messages, beforeQuestionID: id, excludingRunID: excludeHistoryRunId)
        }
        var trace = ContextStageTrace(turn: turn)
        // One instant and preference snapshot feed facts, base receipts and composition.
        let currentTurnClock = clockNowOverride ?? clock()
        let quietHoursWindow = try readTurnQuietHours()
        // Gather independent facts beside history and context; defer consuming and peer-sensitive reads until history binds its evidence.
        async let currentFacts = try currentTurnFacts(
            clockNow: currentTurnClock,
            quietHours: quietHoursWindow,
            sessionID: sessionId,
            queryUserMessage: queryMessage, turn: turn, work: work
        )
        // Read verbatim history once; fitting selects its tail and positive history limits never cap rows.
        let prior: [ChatMessage]
        let priorStats: SessionHistoryReadStats
        if historyLimit > 0 {
            // Select every history region from the same transcript bytes to avoid mixing generations.
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
                    excludingRunId: nil
                )
                prior = beforeReplacedQuestion(try selected.prompt.checkedMessages())
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
                    payload: .object(["code": .string("transcript_unavailable"), "reason": .string(error.localizedDescription)]), turn: turn)
                throw failure
            }
            if selected.prompt.stats.mode != "missing" {
                RepairOwed.settle(historyReader.dataRoot, operation: "chat.history:\(sessionId)",
                    evidence: .init(source: "transcript", id: sessionId))
            }
            priorStats = selected.prompt.stats
        } else {
            prior = []
            priorStats = SessionHistoryReadStats(mode: "history_disabled")
        }
        let preparedHistory = await trace.measure(.prepare) {
            prior.compactMap(SessionHistoryPromptRenderer.renderable)
        }
        let baseStartNs = DispatchTime.now().uptimeNanoseconds
        // Use the transcript owner's exchange pairing, including repeated runs
        // and interrupted replies. The four-message relevance window is not a clock.
        let paired = ConversationHistory.pairExchanges(prior.map {
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
                offeredToolNames: SwiftToolDispatcher.normalModelToolNames(activeTools: turn.offeredTools ?? []),
                recallHistory: preparedHistory,
             turn: turn, work: work)
            trace.record(.contextBase, since: baseStartNs)
        } catch {
            trace.record(.contextBase, since: baseStartNs)
            throw error
        }
        let base = rawBase
        var deliveredHistoryIdentities = Set<String>()
        var historyMessages: [LLMMessage] = []
        var historyMessageChars = 0
        var replayedRunIds = Set<String>()
        var replayedContexts: [SentTurnContext] = []
        var historyRowCharacters: [String: Int] = [:]
        var historySnapshot: SessionHistoryTail?
        var contextWindow = "0:"
        if let admission = SessionHistoryMessages.admission(
            renderables: preparedHistory,
            historyLimit: historyLimit,
            budget: historyBudget
           ) {
            let projected = SessionHistoryMessages.project(admission)
            deliveredHistoryIdentities = projected.historyIdentities
            replayedContexts = projected.replayedContexts
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
        trace.setLabel("prefix.shapeVersion", "v2Prefix")
        trace.setCount("prefix.historyMessageCount", historyMessages.count)
        trace.setCount("prefix.historyMessageChars", historyMessageChars)
        trace.setCount("prefix.replayedTurnCount", replayedRunIds.count)
        trace.setCount("budget.windowTokens", historyBudget.windowTokens ?? 0)
        trace.setFlag("budget.derived", historyBudget.isDerived)
        trace.setCount("budget.memoryBlockChars", historyBudget.memoryBlockChars)
        trace.setCount("budget.recallRowLimit", historyBudget.recallRowLimit)
        // History labels untrusted words without steering the new turn. Only that turn's own restored provenance steers it.
        let receiptStrip = ChatTranscriptEvidenceRendering.recentReceiptStrip(from: prior)
        deliveredHistoryIdentities.formUnion(receiptStrip?.historyIdentities ?? [])
        let renderedHistory = await trace.measure(.render) {
            SessionHistoryPromptRenderer.renderDetailed(
                renderables: preparedHistory,
                middleCandidates: preparedHistory,
                deliveredHistoryIdentities: deliveredHistoryIdentities,
                userMessage: queryMessage,
                historyLimit: historyLimit,
                budget: historyBudget
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
            replacementUserMessageID: replacementQuestion.withLock { $0 })
        contextWithHistory.historyReplaySpec?.historySnapshot = historySnapshot
        contextWithHistory.replayedTurnContexts = replayedContexts
        contextWithHistory.historyContextWindow = contextWindow
        let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
        let facts = try await currentFacts
        trace.record(.factsJoin, since: runtimeStartNs)
        let clocked = try await contextByAppendingCurrentTurnFacts(
            contextWithHistory, facts: facts, sessionID: sessionId, clockNowOverride: currentTurnClock, trace: &trace, turn: turn, work: work)
        var finalContext = clocked
        trace.record(ContextStageName.contextClockRuntime, since: runtimeStartNs)
        trace.setCount("userMessageChars", finalContext.userMessage.count)
        trace.setCount("toolSchemaCount", finalContext.toolSchemas.count)
        finalContext.preparationMs = trace.emit(kind: "context.history.summary", surface: surface)
        return finalContext
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
