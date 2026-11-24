import MindCore
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import SenseCore
import DeskCore
import ProviderRouting
import MacNerves
// Blueprint: | `TurnContextPreparation.swift` | Admitted route, frozen facts and bounded attention input; `buildTurnContext` reads as its stages over one `ContextGathering` (the build's trace and recall gaps): admission, attention and the recall gate, query embedding, user core, context flow, persona, REM pins and recall, tool catalog, reach, base context, summary |
extension SwiftNativeTurnEngine {
    /// Current-turn image blocks stay on the in-flight user message, never in cached system segments.
    public func buildTurnContext(
        surface: String,
        userMessage: String,
        personaOverride: String?,
        imageBlocks: [LLMContentBlock] = [],
        recallQueryOverride: String? = nil,
        includeClockContext: Bool = true,
        sessionID: String? = nil,
        recentTurns: [String] = [],
        recentExchanges: [[String]] = [],
        // Relevance consumers use raw user text so wire tool hints cannot become recall vocabulary; nil uses the supplied message.
        queryUserMessage: String? = nil,
        // Freeze one turn-start instant so repeated builds cannot churn the dynamic clock line mid-turn.
        clockNowOverride: Date? = nil,
        offeredToolNames: Set<String>? = nil,
        turn: Turn, work: ChatTurnWork
    ) async throws -> TurnContext {
        let quietHoursWindow = try readTurnQuietHours()
        return try await buildTurnContext(
            surface: surface,
            userMessage: userMessage,
            personaOverride: personaOverride,
            imageBlocks: imageBlocks,
            recallQueryOverride: recallQueryOverride,
            includeClockContext: includeClockContext,
            sessionID: sessionID,
            recentTurns: recentTurns,
            recentExchanges: recentExchanges,
            queryUserMessage: queryUserMessage,
            clockNowOverride: clockNowOverride,
            quietHoursSnapshot: quietHoursWindow,
            offeredToolNames: offeredToolNames,
            budget: nil,
            startedNs: DispatchTime.now().uptimeNanoseconds,
         turn: turn, work: work).context
    }
    /// `budget` is the turn's budget when the caller already resolved it from the same data root; nil resolves it here.
    /// `startedNs` opens `context.base` at the caller's clock read; the result carries the instant its summary closed.
    func buildTurnContext(
        surface: String,
        userMessage: String,
        personaOverride: String?,
        imageBlocks: [LLMContentBlock],
        recallQueryOverride: String?,
        includeClockContext: Bool,
        sessionID: String?,
        recentTurns: [String],
        recentExchanges: [[String]],
        queryUserMessage: String?,
        clockNowOverride: Date?,
        quietHoursSnapshot: TurnQuietHoursWindow?,
        offeredToolNames: Set<String>? = nil,
        recallHistory: [SessionHistoryPromptRenderer.Renderable]? = nil,
        budget: ContextBudgetPolicy.Resolved?,
        startedNs: UInt64,
        turn: Turn, work: ChatTurnWork
    ) async throws -> (context: TurnContext, closedNs: UInt64) {
        let gathering = try openContextGathering(userMessage: userMessage, imageBlocks: imageBlocks,
            queryUserMessage: queryUserMessage, clockNowOverride: clockNowOverride, budget: budget, startedNs: startedNs, turn: turn)
        let queryMessage = gathering.queryMessage, currentTurnClock = gathering.currentTurnClock
        // Gather independent facts beside assembly and consume them once at composition.
        async let currentFacts = includeClockContext
            ? try currentTurnFacts(clockNow: currentTurnClock, quietHours: quietHoursSnapshot,
                               sessionID: sessionID, queryUserMessage: queryMessage, turn: turn, work: work)
            : nil
        let read = try await readAttentionAndRecallGate(gathering, surface: surface, recentTurns: recentTurns, turn: turn)
        let semantic = try await awaitQueryEmbedding(gathering, semanticQuery: read.semanticQuery, queryEmbeddingTicket: read.queryEmbeddingTicket,
            contextFlowMode: read.contextFlowMode, crossSessionRecall: read.crossSessionRecall)
        let core = try await readUserCore(gathering, surface: surface, crossSessionRecall: read.crossSessionRecall)
        let preparedContextTurn = try await prepareContextFlow(gathering, surface: surface, personaOverride: personaOverride,
            sessionID: sessionID, recentTurns: recentTurns, recentExchanges: recentExchanges, attention: read.attention,
            suppressActiveIntent: read.suppressActiveIntent, contextFlowMode: read.contextFlowMode, crossSessionRecall: read.crossSessionRecall,
            readyQueryEmbedding: semantic.readyQueryEmbedding, semanticRecallEnabled: semantic.semanticRecallEnabled,
            userMemoryCore: core.userMemoryCore, turn: turn)
        let personaPick = try await compilePersona(gathering, surface: surface, personaOverride: personaOverride, sessionID: sessionID,
            preparedContextTurn: preparedContextTurn, userMemoryCore: core.userMemoryCore, turn: turn)
        let memories = try await recallMemories(gathering, surface: surface, recallQueryOverride: recallQueryOverride,
            recallHistory: recallHistory, preparedContextTurn: preparedContextTurn, crossSessionRecall: read.crossSessionRecall)
        let catalog = try await loadToolCatalog(gathering, surface: surface, offeredToolNames: offeredToolNames,
            preparedContextTurn: preparedContextTurn, turn: turn, work: work)
        let composed = try await composeTurnReach(gathering, intentionsStartNs: catalog.intentionsStartNs, surface: surface,
            sessionID: sessionID, crossSessionRecall: read.crossSessionRecall, preparedContextTurn: preparedContextTurn,
            userMemoryCore: core.userMemoryCore, userEstablished: core.userEstablished, compiledPersonaPrompt: personaPick.compiledPersonaPrompt,
            stableDocuments: personaPick.stableDocuments, stableUserCore: personaPick.stableUserCore, userDocument: personaPick.userDocument,
            remPins: memories.remPins, recalled: memories.recalled, turn: turn, work: work)
        let baseContext = baseTurnContext(gathering, surface: surface, userMessage: userMessage, imageBlocks: imageBlocks,
            quietHoursSnapshot: quietHoursSnapshot, preparedContextTurn: preparedContextTurn, resolvedPersonaID: personaPick.resolvedPersonaID,
            personaMap: personaPick.personaMap, personaFingerprint: personaPick.personaFingerprint, recalled: memories.recalled,
            toolNames: catalog.toolNames, toolSchemas: catalog.toolSchemas, reach: composed.reach, episodic: composed.episodic)
        var finalContext: TurnContext
        let factsJoinStart = DispatchTime.now().uptimeNanoseconds
        if let facts = try await currentFacts {
            let joinedNs = DispatchTime.now().uptimeNanoseconds
            gathering.trace.record(.factsJoin, since: factsJoinStart, until: joinedNs, of: .contextBase)
            // Prompt and summary share the same pinned active quiet-hour state.
            finalContext = try await contextByAppendingCurrentTurnFacts(
                baseContext, facts: facts, sessionID: sessionID, clockNowOverride: currentTurnClock, trace: &gathering.trace, turn: turn, work: work)
            let composedNs = DispatchTime.now().uptimeNanoseconds
            gathering.trace.record(.factsCompose, since: joinedNs, until: composedNs, of: .contextBase)
            gathering.trace.record(ContextStageName.contextClockRuntime, since: factsJoinStart, until: composedNs)
        } else {
            finalContext = baseContext
        }
        let closedNs = try closeContextSummary(gathering, finalContext: &finalContext, baseContext: baseContext, surface: surface,
            userMessage: userMessage, imageBlocks: imageBlocks, contextFlowMode: read.contextFlowMode, preparedContextTurn: preparedContextTurn,
            personaMap: personaPick.personaMap, remPins: memories.remPins, recalled: memories.recalled,
            servedContextMemoryIDs: memories.servedContextMemoryIDs, contextFlowMemoryAtomCount: memories.contextFlowMemoryAtomCount,
            toolNames: catalog.toolNames, toolSchemas: catalog.toolSchemas, deliveredRows: composed.deliveredRows)
        return (finalContext, closedNs)
    }
    /// One context build's running record, from admission to the summary: its trace, the admitted facts every stage reads, and
    /// the recall inputs it could not read. The build's stages are engine methods that take it; it lives for one build and never
    /// crosses isolation.
    private final class ContextGathering {
        var trace: ContextStageTrace
        let turnBudget: ContextBudgetPolicy.Resolved
        let effort: String
        let modelId: String
        let admittedProvider: String
        let admittedServiceTier: String?
        let queryMessage: String
        let currentTurnClock: Date
        let recallRepairRoot: URL
        // An unread recall input is a fact of this turn, never an empty successful
        // read and never a reason to replace the context owner or retry the read.
        var recallUnavailableReasons: [String] = []
        init(trace: ContextStageTrace, turnBudget: ContextBudgetPolicy.Resolved, effort: String, modelId: String, admittedProvider: String,
             admittedServiceTier: String?, queryMessage: String, currentTurnClock: Date, recallRepairRoot: URL) {
            self.trace = trace
            self.turnBudget = turnBudget
            self.effort = effort
            self.modelId = modelId
            self.admittedProvider = admittedProvider
            self.admittedServiceTier = admittedServiceTier
            self.queryMessage = queryMessage
            self.currentTurnClock = currentTurnClock
            self.recallRepairRoot = recallRepairRoot
        }
        func noteRecallUnavailable(_ error: Error, input: String, operation: String, owner: String, repairRequired: Bool = true) {
            let reason = error.localizedDescription.split(whereSeparator: \.isNewline).joined(separator: " ")
            recallUnavailableReasons.append("\(input): \(reason)")
            trace.setLabel(operation + ".unavailable", reason)
            if repairRequired && (error as? NativeSemanticQueryError)?.repairRequired != false {
                RepairOwed.owe(recallRepairRoot, id: UUID().uuidString, kind: .run,
                    operation: operation, owner: owner, words: reason,
                    nextCall: "app {\"action\":\"doctor.run\"}")
            }
        }
    }
    /// Admits the build: a message to answer, the turn's budget and admitted model, the relevance text and the one pinned instant.
    private func openContextGathering(userMessage: String, imageBlocks: [LLMContentBlock], queryUserMessage: String?,
        clockNowOverride: Date?, budget: ContextBudgetPolicy.Resolved?, startedNs: UInt64, turn: Turn) throws -> ContextGathering {
        try Task.checkCancellation()
        var trace = ContextStageTrace(turn: turn, partitioning: .contextBase, startedNs: startedNs)
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageBlocks.isEmpty
        {
            throw TurnEngineError.emptyMessage
        }
        let turnBudget: ContextBudgetPolicy.Resolved
        if let budget { turnBudget = budget } else {
            let budgetStart = DispatchTime.now().uptimeNanoseconds
            turnBudget = try ContextBudgetPolicy.resolve(turn: turn, dataRoot: remPinsDataRoot)
            trace.record(.contextBudget, since: budgetStart, of: .contextBase)
        }
        guard let admission = turn.admission,
              let effort = admission.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
              !effort.isEmpty else {
            throw ProviderRoutingError.configurationFailed("The turn's admitted Think level is unavailable.")
        }
        let modelId = admission.model
        let admittedProvider = admission.provider
        let admittedServiceTier = admission.serviceTier
        trace.setFlag("provider.admissionReused", true)
        // Explicit relevance text is authoritative even when blank, keeping wire hints out of recall.
        // Blank text skips query embedding; attention's topic terms do not stand in for it, since they do not enter selection.
        let queryMessage = queryUserMessage ?? userMessage
        trace.setCount("contextFlow.queryMessageChars", queryMessage.count)
        // Pin one instant for prompt and receipt; configured quiet hours alone do not prove the turn is inside them.
        let currentTurnClock = clockNowOverride ?? clock()
        return ContextGathering(trace: trace, turnBudget: turnBudget, effort: effort, modelId: modelId, admittedProvider: admittedProvider,
            admittedServiceTier: admittedServiceTier, queryMessage: queryMessage, currentTurnClock: currentTurnClock,
            recallRepairRoot: remPinsDataRoot ?? defaultDataRoot())
    }
    /// Starts the query embedding, reads attention and the context flow mode, and reads the automatic recall switch once for the turn.
    private func readAttentionAndRecallGate(_ gathering: ContextGathering, surface: String, recentTurns: [String], turn: Turn) async throws
        -> (semanticQuery: String, queryEmbeddingTicket: ContextQueryEmbeddingTicket?, attention: AttentionInputs, suppressActiveIntent: Bool,
            contextFlowMode: ContextFlowMode, crossSessionRecall: Bool) {
        let queryMessage = gathering.queryMessage, turnBudget = gathering.turnBudget
        // Start the existing bge query lane before the bounded attention
        // read, so the vector embeds while that work runs.
        let embeddingStartNs = DispatchTime.now().uptimeNanoseconds
        let semanticQuery = SessionHistoryPromptRenderer.semanticRecallQuery(
            userMessage: queryMessage, recentTurns: recentTurns
        )
        gathering.trace.setCount("contextFlow.semanticQueryChars", semanticQuery.count)
        // Read follow-up queries in their own words rather than merging their relevance evidence.
        let queryEmbeddingTicket = await contextFlow?.beginQueryEmbedding(
            semanticQuery, ownWords: semanticQuery == queryMessage ? nil : queryMessage, turn: turn
        )
        let attentionStartNs = DispatchTime.now().uptimeNanoseconds
        gathering.trace.record(.queryEmbeddingStart, since: embeddingStartNs, until: attentionStartNs, of: .contextBase)
        let attention = try await resolvedAttentionInputs(now: clock(), message: queryMessage, trace: &gathering.trace, turn: turn)
        let modeStartNs = DispatchTime.now().uptimeNanoseconds
        gathering.trace.record(.contextFlowAttention, since: attentionStartNs, until: modeStartNs, of: .contextBase)
        // Work context remains query-selectable without coloring unrelated turns.
        let suppressActiveIntent = ContextSurface(rawValue: surface) == .workshop
            || attention.residentWorkIntent
        let contextFlowMode: ContextFlowMode
        do { contextFlowMode = try await contextFlow?.contextFlowMode() ?? .off }
        catch { throw TurnEngineError.contextLoadFailed(underlying: error) }
        gathering.trace.record(.contextFlowMode, since: modeStartNs, of: .contextBase)
        gathering.trace.setFlag("budget.packetDerived", turnBudget.isDerived)
        // Read the automatic recall switch once per turn for both paths; explicit memory requests remain outside that switch.
        let gateStartNs = DispatchTime.now().uptimeNanoseconds
        // A turn an untrusted contact steers recalls none of the person's memories or person facts on its own.
        let crossSessionRecall = try MemoryPolicyGate.crossSessionRecallEnabled(
            dataRoot: remPinsDataRoot
        ) && turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) != true
        gathering.trace.record(.recallGate, since: gateStartNs, of: .contextBase)
        gathering.trace.setFlag("memory.crossSessionRecall", crossSessionRecall)
        return (semanticQuery, queryEmbeddingTicket, attention, suppressActiveIntent, contextFlowMode, crossSessionRecall)
    }
    /// Waits, within its bound, for the query vector the gate admitted; an unread vector is a named recall gap.
    private func awaitQueryEmbedding(_ gathering: ContextGathering, semanticQuery: String,
        queryEmbeddingTicket: ContextQueryEmbeddingTicket?, contextFlowMode: ContextFlowMode, crossSessionRecall: Bool) async throws
        -> (readyQueryEmbedding: ContextQueryEmbeddingValue?, semanticRecallEnabled: Bool) {
        let recallRepairRoot = gathering.recallRepairRoot
        let readyQueryEmbedding: ContextQueryEmbeddingValue?
        let embeddingWaitStartNs = DispatchTime.now().uptimeNanoseconds
        if contextFlowMode == .active, crossSessionRecall,
           !semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                guard let queryEmbeddingTicket else {
                    throw NativeSemanticQueryError(detail: "No semantic reader admitted this turn. Repair the context embedding owner.")
                }
                readyQueryEmbedding = try await queryEmbeddingTicket.checkedValue(within: Self.queryEmbeddingWaitNanos)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                readyQueryEmbedding = nil
                gathering.noteRecallUnavailable(error, input: "semantic recall", operation: "context.semantic_query", owner: "memory.embedding")
            }
        } else {
            readyQueryEmbedding = nil
        }
        gathering.trace.setFlag("contextFlow.semanticQueryReady", readyQueryEmbedding != nil)
        if let readyQueryEmbedding {
            RepairOwed.settle(recallRepairRoot, operation: "context.semantic_query",
                evidence: .init(source: "memory.embedding", id: readyQueryEmbedding.modelFingerprint))
        }
        gathering.trace.record(.queryEmbeddingWait, since: embeddingWaitStartNs, of: .contextBase)
        // The selector's recall gate excludes memory and graph sources. Other
        // context still comes from the same published generation and lease.
        let semanticRecallEnabled = crossSessionRecall && (contextFlowMode != .active
            || semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || readyQueryEmbedding != nil)
        return (readyQueryEmbedding, semanticRecallEnabled)
    }
    /// Reads the person's bounded memory core when cross-session recall is on; an unread core is a named gap, never a stored stand-in.
    private func readUserCore(_ gathering: ContextGathering, surface: String, crossSessionRecall: Bool) async throws
        -> (userMemoryCore: [String], userEstablished: JSONValue) {
        let recallRepairRoot = gathering.recallRepairRoot
        let userMemoryCore: [String]
        var userEstablished: JSONValue = .null
        var userCoreUnavailable = false
        let userCoreStartNs = DispatchTime.now().uptimeNanoseconds
        if !crossSessionRecall {
            userMemoryCore = []
        } else if let dataRoot = remPinsDataRoot {
            do {
                let core = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).userPromptCoreTimed(surface: surface)
                userMemoryCore = core.facts
                userEstablished = .bool(core.established)
                // The stage below is the whole call; this is the read itself, so the difference is the wait for the memory actor.
                gathering.trace.setCount("memory.userCoreWorkMs", Int(core.workNanoseconds / 1_000_000))
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                gathering.trace.setLabel("memory.userCoreErrorType", String(reflecting: type(of: error)))
                userCoreUnavailable = true
                // The named gap withholds generated facts without substituting the stored projection.
                userMemoryCore = []
                gathering.noteRecallUnavailable(error, input: "user memory", operation: "memory.user_core", owner: "memory/memory.sqlite")
            }
        } else {
            userMemoryCore = []
            userCoreUnavailable = true
            gathering.noteRecallUnavailable(
                ToolFailureError("The user memory data root is unavailable.", effects: .none,
                    owner: "memory/memory.sqlite", code: "memory_user_core_unavailable", recovery: .repair),
                input: "user memory", operation: "memory.user_core", owner: "memory/memory.sqlite"
            )
        }
        gathering.trace.setFlag("memory.userCoreUnavailable", userCoreUnavailable)
        if crossSessionRecall, remPinsDataRoot != nil, !userCoreUnavailable {
            RepairOwed.settle(recallRepairRoot, operation: "memory.user_core",
                evidence: .init(source: "memory/memory.sqlite", id: "userPromptCore"))
        }
        gathering.trace.record(.userCore, since: userCoreStartNs, of: .contextBase)
        // Facts the core delivered after disclosure, not the rows its query read.
        gathering.trace.setCount("memory.userCoreFacts", userMemoryCore.count)
        return (userMemoryCore, userEstablished)
    }
    /// Asks the context flow for this turn's packet when it is active; required context that cannot prepare fails the turn.
    private func prepareContextFlow(_ gathering: ContextGathering, surface: String, personaOverride: String?, sessionID: String?,
        recentTurns: [String], recentExchanges: [[String]], attention: AttentionInputs, suppressActiveIntent: Bool,
        contextFlowMode: ContextFlowMode, crossSessionRecall: Bool, readyQueryEmbedding: ContextQueryEmbeddingValue?,
        semanticRecallEnabled: Bool, userMemoryCore: [String], turn: Turn) async throws -> ContextPreparedTurn? {
        let queryMessage = gathering.queryMessage, turnBudget = gathering.turnBudget, currentTurnClock = gathering.currentTurnClock
        let contextFlowRequest = ContextTurnRequest(
            surface: ContextSurface(rawValue: surface),
            origin: Self.contextOrigin(for: surface),
            userMessage: queryMessage,
            personaIDHint: personaOverride,
            sessionID: sessionID,
            recentTurns: recentTurns,
            recentExchanges: recentExchanges,
            activeTask: suppressActiveIntent ? nil : attention.activeTask,
            unresolvedQuestion: attention.unresolvedQuestion,
            goal: suppressActiveIntent ? nil : attention.goal,
            predictedToolGroups: attention.predictedToolGroups,
            contextualTerms: attention.contextualTerms,
            cognitiveActivation: attention.cognitiveActivation,
            suppressedAtomIDs: attention.suppressedAtomIDs,
            queryEmbedding: readyQueryEmbedding,
            // One bounded expansion preserves mandatory context and room for ranked context.
            characterBudget: turnBudget.packetChars,
            maximumCharacterBudget: turnBudget.packetExpandedChars,
            postMandatoryCharacterReserve: turnBudget.packetPostMandatoryReserve,
            // Required persona documents already ride the stable segment; do not duplicate them in the volatile packet.
            userMemoryCore: userMemoryCore,
            memoryRecallEnabled: semanticRecallEnabled,
            // The same number the renderer cuts at, so the selector publishes a
            // pointer for exactly the atoms that get cut.
            packetAtomExpandThresholdChars:
                ContextBudgetPolicy.packetAtomExpandThresholdChars,
            // ContextBudgetPolicy bounds both recall paths; the per-turn recall switch can admit zero rows.
            memoryAtomRowLimit: crossSessionRecall ? turnBudget.recallRowLimit : 0,
            // Memory ages read the same pinned instant as the turn's clock facts; selection keeps its own bucket.
            turnTime: currentTurnClock
        )
        var preparedContextTurn: ContextPreparedTurn?
        switch contextFlowMode {
        case .off:
            gathering.trace.setFlag("contextFlow.enabled", false)
        case .active:
            gathering.trace.setFlag("contextFlow.enabled", true)
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                preparedContextTurn = try await contextFlow?.prepareContextTurn(contextFlowRequest, turn: turn)
                try Task.checkCancellation()
                if let expansion = preparedContextTurn?.budgetExpansion {
                    gathering.trace.setFlag("contextFlow.budgetExpanded", true)
                    gathering.trace.setCount(
                        "contextFlow.requestedCharacterBudget",
                        expansion.requestedCharacterBudget
                    )
                    gathering.trace.setCount(
                        "contextFlow.effectiveCharacterBudget",
                        expansion.effectiveCharacterBudget
                    )
                    gathering.trace.setCount(
                        "contextFlow.maximumCharacterBudget",
                        expansion.maximumCharacterBudget
                    )
                    gathering.trace.setCount(
                        "contextFlow.grantedPostMandatoryReserve",
                        expansion.grantedPostMandatoryReserve
                    )
                }
                gathering.trace.record(.contextFlowPrepare, since: start, of: .contextBase)
            } catch {
                try Task.checkCancellation()
                gathering.trace.record(.contextFlowPrepare, since: start, of: .contextBase)
                // Recall gaps were named above. Required context still must prepare;
                // a stand-in prompt cannot replace a failed generation or persona.
                throw TurnEngineError.contextLoadFailed(underlying: error)
            }
        }
        return preparedContextTurn
    }
    /// Compiles the persona from the prepared kernel, or from the persona engine without one, and shares the bounded person picture.
    private func compilePersona(_ gathering: ContextGathering, surface: String, personaOverride: String?, sessionID: String?,
        preparedContextTurn: ContextPreparedTurn?, userMemoryCore: [String], turn: Turn) async throws
        -> (personaMap: [String: String], personaFingerprint: String, resolvedPersonaID: String?, compiledPersonaPrompt: String,
            stableUserCore: [String], stableDocuments: StablePrefixPersonaDocuments, userDocument: String?) {
        let queryMessage = gathering.queryMessage
        // PersonaCompiler owns canonical document order, surface guidance, overrides and fingerprinting.
        var personaMap: [String: String]
        let personaFingerprint: String
        let resolvedPersonaID: String?
        let compiledPersonaPrompt: String
        let personaStartNs = DispatchTime.now().uptimeNanoseconds
        // Only the USER preamble belongs in the stable prefix; the same bounded facts ride the dynamic packet on every turn.
        let stableUserCore: [String] = []
        let stableDocuments = Self.stablePrefixPersonaDocuments(preparedContextTurn)
        do {
            if let preparedContextTurn {
                resolvedPersonaID = preparedContextTurn.mirror.personaID.rawValue
                var documents = Dictionary(preparedContextTurn.mirror.documents.map {
                    (String($0.id.rawValue.dropLast(3)), $0.text)
                }, uniquingKeysWith: { first, _ in first })
                // The saved name is read at admission, independent of cached documents.
                documents["IDENTITY"] = try PersonaCompiler.identityPrompt(dataRoot: await persona.dataRootURL)
                if !preparedContextTurn.kernel.surfaceGuidance.isEmpty {
                    documents["surfaceGuidance"] = preparedContextTurn.kernel.surfaceGuidance
                }
                personaFingerprint = PersonaCompiler.fingerprint(documents: documents, surface: surface)
                personaMap = documents
                compiledPersonaPrompt = PersonaCompiler.renderPrompt(documents: documents.filter { $0.key == "IDENTITY" })
                    + "\n\n" + preparedContextTurn.kernel.renderedPrompt
                gathering.trace.setCount(
                    "contextFlow.selectedAtoms",
                    preparedContextTurn.packet.selectedItems.count
                )
                gathering.trace.setCount(
                    "contextFlow.packetChars",
                    preparedContextTurn.packet.characterCount
                )
                gathering.trace.setCount(
                    "contextFlow.memoryRecords",
                    preparedContextTurn.selectedMemoryRecordIDs.count
                )
                // Memory selection reasons belong only in the trace.
                if let why = Self.memoryWhyPayload(preparedContextTurn, message: queryMessage) {
                    TurnTraceBus.fireFromContext(kind: "mind.why", sessionId: sessionID, surface: surface, payload: why, turn: turn)
                }
                // Count semantic-floor refusals so a quiet packet distinguishes irrelevant memory from unavailable embedding evidence.
                let memoryFloorDropped = preparedContextTurn.packet.receipt
                    .memoryFloorDroppedCount
                if memoryFloorDropped > 0 {
                    gathering.trace.setCount("contextFlow.memoryFloorDropped", memoryFloorDropped)
                }
                // Expandable count must equal truncated count; any gap means a cut body has no usable recovery pointer.
                let truncation = Self.packetTruncationCounts(preparedContextTurn)
                gathering.trace.setCount("contextFlow.truncatedAtoms", truncation.truncatedAtoms)
                gathering.trace.setCount("contextFlow.leadChars", truncation.leadChars)
                gathering.trace.setCount(
                    "contextFlow.expandableAfterTruncation",
                    truncation.expandableAfterTruncation
                )
                // Required documents belong in the cached prefix, not the per-turn packet.
                gathering.trace.setFlag("persona.inStablePrefix", true)
                gathering.trace.setCount("persona.stableDocs", stableDocuments.included.count)
                // Missing surface-permission evidence withholds the document from both prefix and packet; trace the wiring fault explicitly.
                if !stableDocuments.unprovenDocumentIDs.isEmpty {
                    gathering.trace.setCount(
                        "persona.stableDocsUnproven",
                        stableDocuments.unprovenDocumentIDs.count
                    )
                    gathering.trace.setLabel(
                        "persona.stable_doc_unproven",
                        stableDocuments.unprovenDocumentIDs
                            .map(\.rawValue)
                            .sorted()
                            .joined(separator: ",")
                    )
                }
            } else {
                let compiler = PersonaCompiler(engine: persona)
                // The saved name is required, as above: an unreadable profile
                // fails the turn with the compiler's repair text.
                let packet = try await compiler.compile(
                    surface: surface, personaOverride: personaOverride, userMemoryCore: stableUserCore
                )
                resolvedPersonaID = packet.personaId
                personaFingerprint = packet.fingerprint
                personaMap = packet.activeDocs
                compiledPersonaPrompt = packet.compiledSystemPrompt
            }
            // Microseconds retain the cost of mapping an already-compiled kernel's documents.
            gathering.trace.recordMicroseconds(.personaCompile, since: personaStartNs, of: .contextBase)
        } catch {
            gathering.trace.recordMicroseconds(.personaCompile, since: personaStartNs, of: .contextBase)
            try Task.checkCancellation()
            throw TurnEngineError.personaLoadFailed(underlying: error)
        }
        // Share the bounded person picture with persona readers and recall precoverage.
        let userDocument = personaMap["USER"]
        if let userDocument {
            personaMap["USER"] = UserMDAutogenMarkers.promptText(userDocument, userMemoryCore: userMemoryCore)
        }
        return (personaMap, personaFingerprint, resolvedPersonaID, compiledPersonaPrompt, stableUserCore, stableDocuments, userDocument)
    }
    /// Reads REM pins, then the memories this turn recalls (the prepared packet's selection, or the builder's own recall), pins first.
    private func recallMemories(_ gathering: ContextGathering, surface: String, recallQueryOverride: String?,
        recallHistory: [SessionHistoryPromptRenderer.Renderable]?, preparedContextTurn: ContextPreparedTurn?, crossSessionRecall: Bool)
        async throws -> (remPins: [REMPin], recalled: [MemoryRecallHit], servedContextMemoryIDs: [String], contextFlowMemoryAtomCount: Int?) {
        let queryMessage = gathering.queryMessage, turnBudget = gathering.turnBudget, recallRepairRoot = gathering.recallRepairRoot
        // REM-approved pins take precedence over overlapping recalls.
        let remStartNs = DispatchTime.now().uptimeNanoseconds
        var remPins: [REMPin] = []
        if let dataRoot = remPinsDataRoot {
            do {
                remPins = REMPinsReader.latest(try REMPinsReader.read(dataRoot: dataRoot), latestN: 3)
                RepairOwed.settle(dataRoot, operation: "rem_pins.read",
                    evidence: .init(source: "rem_pins.json", id: "turn_pins"))
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                gathering.noteRecallUnavailable(error, input: "REM pins", operation: "rem_pins.read", owner: "rem_pins.json")
            }
        }
        gathering.trace.record(.remPinsRead, since: remStartNs, of: .contextBase)

        // Session-backed recall may expand the query with continuity anchors.
        let memoryStartNs = DispatchTime.now().uptimeNanoseconds
        gathering.trace.setCount("budget.windowTokens", turnBudget.windowTokens ?? 0)
        gathering.trace.setFlag("budget.derived", turnBudget.isDerived)
        gathering.trace.setCount("budget.recallRowLimit", turnBudget.recallRowLimit)
        gathering.trace.setCount("budget.memoryBlockChars", turnBudget.memoryBlockChars)
        try Task.checkCancellation()
        gathering.trace.setFlag("history.recallQueryBuilt", false)
        gathering.trace.setCount("history.recallQueryChars", 0)
        var recalled: [MemoryRecallHit] = []
        var servedContextMemoryIDs: [String] = []
        var contextFlowMemoryAtomCount: Int?
        if let preparedContextTurn {
            contextFlowMemoryAtomCount = preparedContextTurn.packet.selectedItems.reduce(into: 0) {
                if $1.pointer.kind == .memory || $1.pointer.kind == .correction { $0 += 1 }
            }
            // Selection alone is not a completed serve: the credit waits for
            // the provider to accept this context (`creditDeliveredMemories`).
            servedContextMemoryIDs = preparedContextTurn.selectedMemoryRecordIDs
        } else if let memory, crossSessionRecall {
            // Disabling cross-session recall skips automatic root-wide reads, never explicit memory requests.
            let expandedRecallQuery: String?
            if recallQueryOverride == nil, let recallHistory {
                expandedRecallQuery = await gathering.trace.measure(.recallQuery) {
                    SessionHistoryPromptRenderer.recallQuery(
                        userMessage: queryMessage, renderables: recallHistory
                    )
                }
                gathering.trace.setFlag("history.recallQueryBuilt", true)
                gathering.trace.setCount("history.recallQueryChars", expandedRecallQuery?.count ?? 0)
            } else {
                expandedRecallQuery = recallQueryOverride
            }
            let recallQuery = expandedRecallQuery?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveRecallQuery: String
            if let recallQuery, !recallQuery.isEmpty { effectiveRecallQuery = recallQuery }
            else { effectiveRecallQuery = queryMessage }
            do {
                recalled = try await memory.recall(
                    effectiveRecallQuery,
                    k: turnBudget.recallRowLimit,
                    // Persona slots select documents; MemoryV2 owns every
                    // ordinary write under this same memory identity.
                    persona: MemoryV2Defaults.personaID,
                    surface: surface
                )
                gathering.trace.setMemoryRecallOutcome(.succeeded(hitCount: recalled.count))
                RepairOwed.settle(recallRepairRoot, operation: "memory.turn_recall",
                    evidence: .init(source: "memory/memory.sqlite", id: "recall"))
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                gathering.trace.setMemoryRecallOutcome(.failed(
                    errorType: String(reflecting: type(of: error))
                ))
                let repairRequired = await memory.recallRepairRequired(for: error)
                try Task.checkCancellation()
                gathering.noteRecallUnavailable(error, input: "memory recall", operation: "memory.turn_recall", owner: "memory/memory.sqlite",
                    repairRequired: repairRequired)
            }
        } else {
            gathering.trace.setMemoryRecallOutcome(.notConfigured)
        }
        // Prepared turns report only the selector's measured recall latency, nested in contextFlow.prepare;
        // no sample means no timing. Without a prepared turn, recall is this builder's own step.
        if preparedContextTurn == nil {
            gathering.trace.recordMicroseconds(.memoryRecall, since: memoryStartNs, of: .contextBase)
        } else if let selectionMicros = preparedContextTurn?.packet.receipt
            .measuredSelectionMicroseconds {
            gathering.trace.setMicroseconds(.memoryRecall, microseconds: Int64(selectionMicros))
        }
        // REM pins are authoritative; remove overlapping recall keys or verbatim pin text to avoid duplicated context.
        if !remPins.isEmpty {
            recalled = recalled.filter { hit in
                !remPins.contains(where: { pin in
                    !hit.preview.isEmpty
                        && !pin.text.isEmpty
                        && (hit.preview.contains(pin.text) || pin.text.contains(hit.preview))
                })
            }
        }
        return (remPins, recalled, servedContextMemoryIDs, contextFlowMemoryAtomCount)
    }
    /// Reads the tool catalog the turn offers, under the prepared context; returns the instant the catalog step closed.
    private func loadToolCatalog(_ gathering: ContextGathering, surface: String, offeredToolNames: Set<String>?,
        preparedContextTurn: ContextPreparedTurn?, turn: Turn, work: ChatTurnWork) async throws
        -> (toolNames: [String], toolSchemas: [LLMToolSchema], intentionsStartNs: UInt64) {
        // Chat offers only `app`; internal catalogs remain discoverable and available to explicit callers.
        let toolNames: [String]
        let toolSchemas: [LLMToolSchema]
        gathering.trace.setFlag("tools.fullCatalogRequested", offeredToolNames == nil)
        // One step for the catalog: names and schemas can read at once, so their own times are nested, never summed.
        let catalogStartNs = DispatchTime.now().uptimeNanoseconds
        do {
            (toolNames, toolSchemas) = try await holding(work.with(\.preparedContext, preparedContextTurn)) { work in
                let tools = self.tools
                if let offeredToolNames {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let schemas = try await tools.listAvailableToolSchemas(named: offeredToolNames, turn: turn, surface: surface)
                    gathering.trace.recordMicroseconds(.toolsSchemas, since: started)
                    return (schemas.map(\.name), schemas)
                }
                async let names: ([String], UInt64) = {
                    let started = DispatchTime.now().uptimeNanoseconds
                    return (try await tools.listAvailableTools(turn: turn, surface: surface), DispatchTime.now().uptimeNanoseconds &- started)
                }()
                async let schemas: ([LLMToolSchema], UInt64) = {
                    let started = DispatchTime.now().uptimeNanoseconds
                    return (try await tools.listAvailableToolSchemas(turn: turn, surface: surface), DispatchTime.now().uptimeNanoseconds &- started)
                }()
                let catalog = try await (names, schemas)
                gathering.trace.setTiming(.toolsNames, milliseconds: Int64(catalog.0.1 / 1_000_000))
                gathering.trace.setTiming(.toolsSchemas, milliseconds: Int64(catalog.1.1 / 1_000_000))
                return (catalog.0.0.filter { !SwiftToolDispatcher.isModelHidden($0) }, catalog.1.0)
            }
        } catch {
            try Task.checkCancellation()
            throw TurnEngineError.toolCatalogLoadFailed(underlying: error)
        }
        let intentionsStartNs = DispatchTime.now().uptimeNanoseconds
        gathering.trace.record(.toolsCatalog, since: catalogStartNs, until: intentionsStartNs, of: .contextBase)
        return (toolNames, toolSchemas, intentionsStartNs)
    }
    /// Reads the queue and recent life, and composes what the turn reaches: persona, pins, recall and the packet.
    private func composeTurnReach(_ gathering: ContextGathering, intentionsStartNs: UInt64, surface: String, sessionID: String?,
        crossSessionRecall: Bool, preparedContextTurn: ContextPreparedTurn?, userMemoryCore: [String], userEstablished: JSONValue,
        compiledPersonaPrompt: String, stableDocuments: StablePrefixPersonaDocuments, stableUserCore: [String], userDocument: String?,
        remPins: [REMPin], recalled: [MemoryRecallHit], turn: Turn, work: ChatTurnWork) async throws
        -> (reach: TurnReach, deliveredRows: [(hit: MemoryRecallHit, line: String)],
            episodic: (life: String, working: String, acts: Set<String>)) {
        let turnBudget = gathering.turnBudget, currentTurnClock = gathering.currentTurnClock
        // The stem gathers inputs and composes the prompt strings turn.js receives.
        let intentions: String
        do {
            intentions = try await intentionsContext(now: currentTurnClock, sessionID: sessionID, surface: surface, turn: turn)
        } catch let unavailable as IntentionsContextUnavailable {
            try Task.checkCancellation()
            intentions = "MY QUEUE is unavailable; no queued step was admitted this turn."
            gathering.noteRecallUnavailable(unavailable, input: "intentions", operation: unavailable.operation, owner: unavailable.owner)
        }
        let renderStartNs = DispatchTime.now().uptimeNanoseconds
        gathering.trace.record(.intentions, since: intentionsStartNs, until: renderStartNs, of: .contextBase)
        let deliveredRows = Self.deliveredRecalledMemoryRows(dataRoot: turn.dataRoot, recalled, budget: turnBudget)
        let personaPrompt = Self.renderPersonaPrompt(
            compiledPersonaPrompt: compiledPersonaPrompt,
            requiredDocuments: stableDocuments.included,
            userMemoryCore: stableUserCore,
            surfaceGuidance: preparedContextTurn?.kernel.surfaceGuidance ?? ""
        )
        let userPicture = userDocument.map {
            UserMDAutogenMarkers.userSection($0, userMemoryCore: userMemoryCore)
        } ?? ""
        let contextPacket = preparedContextTurn.map(Self.renderContextPacket) ?? ""
        let macContext = work.invocation.macContext(dataRoot: remPinsDataRoot ?? defaultDataRoot())
        let continuationContext = turn.envelope?.macContinuation?.modelContext(context: macContext) ?? ""
        // One availability notice: what could not be read, then what was chosen but held back by its owner's check.
        let unreadNotice = gathering.recallUnavailableReasons.isEmpty ? "" : "Recall was unavailable this turn (\(gathering.recallUnavailableReasons.joined(separator: "; ")))."
            + " This is not evidence that a memory exists or does not exist."
        let recallNotice = [unreadNotice, preparedContextTurn.flatMap(Self.withheldContextNotice) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let episodicStartNs = DispatchTime.now().uptimeNanoseconds
        let episodic = try await episodicContext(sessionID: sessionID,
            crossSessionRecall: crossSessionRecall, now: currentTurnClock, turn: turn)
        gathering.trace.record(.episodic, since: episodicStartNs)
        let packetSections: [String] = [userPicture, episodic.life, intentions, contextPacket, continuationContext, recallNotice]
        let packet = packetSections.filter { !$0.isEmpty }.joined(separator: "\n\n")
        // The agent's own line with written instructions is the one they write; everything else it reaches is the agent's.
        var reach = TurnReach(
            persona: turn.lineInstructions ?? personaPrompt,
            expression: .object(["established": userEstablished]),
            pins: remPins.map(\.text),
            recall: Self.renderRecalledMemoryBlock(deliveredRows) ?? "",
            packet: packet
        )
        gathering.trace.record(.promptRender, since: renderStartNs, of: .contextBase)
        if let root = remPinsDataRoot { reach.body = await TurnBodyAccess.read(bodyField, root: root, turn: turn, session: sessionID) }
        return (reach, deliveredRows, episodic)
    }
    /// The turn's base context from what was gathered, with the frozen quiet-hour state stamped on its trace.
    private func baseTurnContext(_ gathering: ContextGathering, surface: String, userMessage: String, imageBlocks: [LLMContentBlock],
        quietHoursSnapshot: TurnQuietHoursWindow?, preparedContextTurn: ContextPreparedTurn?, resolvedPersonaID: String?,
        personaMap: [String: String], personaFingerprint: String, recalled: [MemoryRecallHit], toolNames: [String],
        toolSchemas: [LLMToolSchema], reach: TurnReach, episodic: (life: String, working: String, acts: Set<String>)) -> TurnContext {
        let modelId = gathering.modelId, effort = gathering.effort, admittedProvider = gathering.admittedProvider,
            admittedServiceTier = gathering.admittedServiceTier, currentTurnClock = gathering.currentTurnClock
        var baseContext = TurnContext(
            surface: surface,
            personaID: resolvedPersonaID,
            personaDocs: personaMap,
            personaFingerprint: personaFingerprint,
            recalled: recalled,
            modelId: modelId,
            reasoningEffort: effort,
            providerId: admittedProvider,
            serviceTier: admittedServiceTier,
            toolsAvailable: toolNames,
            userMessage: userMessage,
            toolSchemas: toolSchemas,
            imageBlocks: imageBlocks,
            fluidContextTurn: preparedContextTurn,
            turnReach: reach
        )
        baseContext.privateWorkingMemory = episodic.working
        baseContext.recentLifeActs = episodic.acts
        let quietHoursActive: Bool = {
            guard let quietHours = quietHoursSnapshot else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return quietHours.contains(hour: calendar.component(.hour, from: currentTurnClock))
        }()
        // Stamp the same frozen quiet-hour semantic even when history defers clock rendering, so the base receipt remains unambiguous.
        gathering.trace.setFlag(
            "clock.quietHoursActive",
            quietHoursActive
        )
        return baseContext
    }
    /// Closes the build's summary on the final context and credits the memories it delivered; returns the instant the summary closed.
    private func closeContextSummary(_ gathering: ContextGathering, finalContext: inout TurnContext, baseContext: TurnContext,
        surface: String, userMessage: String, imageBlocks: [LLMContentBlock], contextFlowMode: ContextFlowMode,
        preparedContextTurn: ContextPreparedTurn?, personaMap: [String: String], remPins: [REMPin], recalled: [MemoryRecallHit],
        servedContextMemoryIDs: [String], contextFlowMemoryAtomCount: Int?, toolNames: [String], toolSchemas: [LLMToolSchema],
        deliveredRows: [(hit: MemoryRecallHit, line: String)]) throws -> UInt64 {
        try Task.checkCancellation()
        if contextFlowMode == .active {
            gathering.trace.setFlag("contextFlow.active", preparedContextTurn != nil)
        }
        if let contextFlowMemoryAtomCount {
            gathering.trace.setMemoryRecallOutcome(.contextFlow(hitCount: contextFlowMemoryAtomCount))
        }
        gathering.trace.setCount("snapshot.toolNames", toolNames.count)
        gathering.trace.setCount("snapshot.toolSchemas", toolSchemas.count)
        gathering.trace.setCount("snapshot.toolSchemaParameterBytes", toolSchemas.reduce(0) { $0 + $1.parametersJSON.count })
        gathering.trace.setCount("persona.docCount", personaMap.count)
        gathering.trace.setCount("persona.docChars", personaMap.values.reduce(0) { $0 + $1.count })
        gathering.trace.setCount("remPins.count", remPins.count)
        // Injected identities unite recalled rows and packet provenance; the separate count covers rows only.
        gathering.trace.setInjectedMemoryIDs(baseContext.resolvedRecalledIds)
        gathering.trace.setCount("memory.recallHits.direct", recalled.count)
        gathering.trace.setCount("userMessageChars", userMessage.count)
        gathering.trace.setCount("imageBlockCount", imageBlocks.count)
        gathering.trace.setFlag("snapshot.requestScoped", true)
        let closedNs = DispatchTime.now().uptimeNanoseconds
        finalContext.preparationMs = gathering.trace.emit(kind: "context.summary", surface: surface, closedAt: closedNs)
        // Credit only accepted, rendered memories after pin deduplication; undelivered rows must not gain eviction-protecting use counts.
        finalContext.usageCreditMemoryIDs = servedContextMemoryIDs
            + deliveredRows.compactMap { row in
                guard case .object(let extras)? = row.hit.extras,
                      case .string(let id)? = extras["id"] else { return nil }
                return id
            }
        return closedNs
    }
    private struct AttentionInputs {
        var contextualTerms: Set<String> = []
        var unresolvedQuestion: String?
        var activeTask: String?
        var goal: String?
        var residentWorkIntent = false
        var predictedToolGroups: Set<String> = []
        var cognitiveActivation: [ContextAtomID: Double] = [:]
        var suppressedAtomIDs: Set<ContextAtomID> = []
    }
    private enum AttentionRaceOutcome: Sendable {
        case signals(CognitiveAttentionSignals?, CognitiveAttentionTraceRecorder.Snapshot)
    }
    /// Bound attention reads and trace only counts and timeout state. Only no provider or successful emptiness yields empty input;
    /// unavailable reads fail preparation.
    private func resolvedAttentionInputs(
        now: Date,
        message: String,
        trace: inout ContextStageTrace,
        turn: Turn
    ) async throws -> AttentionInputs {
        try Task.checkCancellation()
        guard let cognitiveRuntime else { return AttentionInputs() }

        // Bound the provider seam even though the live owner reads published cache without waits.
        // The race cancels the losing deadline/read without joining noncooperative work; late reads cannot publish into the turn.
        let attentionTrace = CognitiveAttentionTraceRecorder()
        let outcome = await raceAgainstTimeout(seconds: Double(Self.attentionSignalsTimeoutNanos) / 1_000_000_000) {
            let signals = await CognitiveAttentionTraceContext.$recorder.withValue(attentionTrace) {
                await cognitiveRuntime.attentionSignals(at: now)
            }
            attentionTrace.markCompleted()
            let snapshot = attentionTrace.snapshot()
            if Task.isCancelled {
                // Only the cancelled read's eventual exit emits this receipt;
                // it cannot publish attention into the turn that moved on.
                var stages: [String: JSONValue] = [:]
                if let milliseconds = snapshot.admissionMilliseconds {
                    stages["actorAdmission"] = .int(milliseconds)
                }
                TurnTraceBus.fireFromContext(
                    kind: "context.attention.late-completion",
                    payload: .object([
                        "schema": .string("context.attention.late-completion.v1"),
                        "totalMs": .int(snapshot.totalMilliseconds),
                        "cancellationObserved": .bool(snapshot.cancellationObserved),
                        "stageMs": .object(stages),
                    ]),
                    turn: turn
                )
            }
            return AttentionRaceOutcome.signals(signals, snapshot)
        }
        try Task.checkCancellation()

        let signals: CognitiveAttentionSignals?
        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            recordAttentionTrace(attentionTrace.snapshot(), into: &trace)
            trace.setFlag("contextFlow.attentionTimedOut", true)
            throw TurnEngineError.contextLoadFailed(underlying: ToolFailureError(
                "Attention could not be read within its deadline. Repair the cognitive attention owner before preparing this turn.",
                effects: .none, recovery: .repair))
        case .failure(let reason):
            recordAttentionTrace(attentionTrace.snapshot(), into: &trace)
            throw TurnEngineError.contextLoadFailed(underlying: ToolFailureError(
                "Attention could not be read: \(reason). Repair the cognitive attention owner.",
                effects: .none, recovery: .repair))
        case .value(.signals(let value, let snapshot)):
            recordAttentionTrace(snapshot, into: &trace)
            signals = value
        }
        guard let signals, !signals.isEmpty else {
            trace.setFlag("contextFlow.attentionPresent", false)
            return AttentionInputs()
        }
        trace.setFlag("contextFlow.attentionPresent", true)

        var inputs = AttentionInputs()
        // Topic terms are counted in the trace and do not enter selection: taken out on purpose 10-07 (10e00a710b), because attention terms
        // do not make an item relevant to the current message.
        inputs.contextualTerms = Set(signals.terms.keys.filter { !$0.isEmpty })
        inputs.predictedToolGroups = signals.predictedToolGroups
        inputs.unresolvedQuestion = Self.nonEmpty(signals.unresolvedQuestion)
        inputs.activeTask = Self.nonEmpty(signals.activeTask)
        inputs.goal = Self.nonEmpty(signals.goal)
        inputs.residentWorkIntent = signals.residentWorkIntent

        // The app maps memory record IDs to owned atoms; absent mapping drops only memory activation, preserving terms and intent.
        if let memoryAtomTranslator {
            for (recordID, weight) in signals.memoryActivation {
                guard let atomID = memoryAtomTranslator(recordID) else { continue }
                inputs.cognitiveActivation[atomID] = max(
                    inputs.cognitiveActivation[atomID] ?? 0, weight
                )
            }
            // Suppress memories the agent rejected for this kind of thing.
            for recordID in signals.suppressedMemoryRecordIDs(for: message) {
                if let atomID = memoryAtomTranslator(recordID) {
                    inputs.suppressedAtomIDs.insert(atomID)
                }
            }
        }
        trace.setCount("contextFlow.attentionTerms", inputs.contextualTerms.count)
        trace.setCount("contextFlow.attentionToolGroups", inputs.predictedToolGroups.count)
        trace.setCount("contextFlow.attentionActivation", inputs.cognitiveActivation.count)
        return inputs
    }
    private func recordAttentionTrace(
        _ snapshot: CognitiveAttentionTraceRecorder.Snapshot,
        into trace: inout ContextStageTrace
    ) {
        if let milliseconds = snapshot.admissionMilliseconds {
            trace.setTiming(.contextFlowAttentionActorAdmission, milliseconds: milliseconds)
        }
        trace.setFlag("contextFlow.attentionCompleted", snapshot.completed)
        trace.setFlag("contextFlow.attentionCancellationObserved", snapshot.cancellationObserved)
    }
    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
    nonisolated private static func contextOrigin(for surface: String) -> ContextOriginClass {
        switch ContextSurface(rawValue: surface) {
        case .telegram, .ios, .slack:
            .remoteAuthenticated
        default:
            .localAuthenticated
        }
    }
}
