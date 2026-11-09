import AgentWorkspace
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TurnTrace
import PersonaEngine
import MemoryV2
import ProviderRouting
import DreamREMCycle
import MacControl
import Context
import CognitiveSubstrate
import Experiences
import Transcripts
// Blueprint: | `TurnContextPreparation.swift` | Admitted route, frozen facts and bounded attention input |
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
         turn: turn, work: work)
    }
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
        turn: Turn, work: ChatTurnWork
    ) async throws -> TurnContext {
        try Task.checkCancellation()
        var trace = ContextStageTrace(turn: turn)
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageBlocks.isEmpty
        {
            throw TurnEngineError.emptyMessage
        }
        let turnBudget = try ContextBudgetPolicy.resolve(turn: turn, dataRoot: remPinsDataRoot)
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
        // Blank text skips query embedding; selection can still use attention terms and entities.
        let queryMessage = queryUserMessage ?? userMessage
        trace.setCount("contextFlow.queryMessageChars", queryMessage.count)
        // Pin one instant for prompt and receipt; configured quiet hours alone do not prove the turn is inside them.
        let currentTurnClock = clockNowOverride ?? clock()
        // Gather independent facts beside assembly and consume them once at composition.
        async let currentFacts = includeClockContext
            ? try currentTurnFacts(clockNow: currentTurnClock, quietHours: quietHoursSnapshot,
                               sessionID: sessionID, queryUserMessage: queryMessage, turn: turn, work: work)
            : nil
        // Start the existing bge query lane before the bounded attention
        // read, so the vector embeds while that work runs.
        let semanticQuery = SessionHistoryPromptRenderer.semanticRecallQuery(
            userMessage: queryMessage, recentTurns: recentTurns
        )
        trace.setCount("contextFlow.semanticQueryChars", semanticQuery.count)
        // Read follow-up queries in their own words rather than merging their relevance evidence.
        let queryEmbeddingTicket = await contextFlow?.beginQueryEmbedding(
            semanticQuery, ownWords: semanticQuery == queryMessage ? nil : queryMessage, turn: turn
        )

        let attentionStartNs = DispatchTime.now().uptimeNanoseconds
        let attention = try await resolvedAttentionInputs(now: clock(), message: queryMessage, trace: &trace, turn: turn)
        trace.record(.contextFlowAttention, since: attentionStartNs)
        // Work context remains query-selectable without coloring unrelated turns.
        let suppressActiveIntent = ContextSurface(rawValue: surface) == .workshop
            || attention.residentWorkIntent
        let contextFlowMode: ContextFlowMode
        do { contextFlowMode = try await contextFlow?.contextFlowMode() ?? .off }
        catch { throw TurnEngineError.contextLoadFailed(underlying: error) }
        trace.setFlag("budget.packetDerived", turnBudget.isDerived)
        // Read the automatic recall switch once per turn for both paths; explicit memory requests remain outside that switch.
        let crossSessionRecall = try MemoryPolicyGate.crossSessionRecallEnabled(
            dataRoot: remPinsDataRoot
        )
        trace.setFlag("memory.crossSessionRecall", crossSessionRecall)
        // An unread recall input is a fact of this turn, never an empty successful
        // read and never a reason to replace the context owner or retry the read.
        var recallUnavailableReasons: [String] = []
        let recallRepairRoot = remPinsDataRoot ?? defaultDataRoot()
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
        let readyQueryEmbedding: ContextQueryEmbeddingValue?
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
                noteRecallUnavailable(error, input: "semantic recall", operation: "context.semantic_query", owner: "memory.embedding")
            }
        } else {
            readyQueryEmbedding = nil
        }
        trace.setFlag("contextFlow.semanticQueryReady", readyQueryEmbedding != nil)
        if let readyQueryEmbedding {
            RepairOwed.settle(recallRepairRoot, operation: "context.semantic_query",
                evidence: .init(source: "memory.embedding", id: readyQueryEmbedding.modelFingerprint))
        }
        // The selector's recall gate excludes memory and graph sources. Other
        // context still comes from the same published generation and lease.
        let semanticRecallEnabled = crossSessionRecall && (contextFlowMode != .active
            || semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || readyQueryEmbedding != nil)
        let userMemoryCore: [String]
        var userCoreUnavailable = false
        if !crossSessionRecall {
            userMemoryCore = []
        } else if let dataRoot = remPinsDataRoot {
            do {
                userMemoryCore = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
                    .userPromptCore(surface: surface)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                trace.setLabel("memory.userCoreErrorType", String(reflecting: type(of: error)))
                userCoreUnavailable = true
                // The named gap withholds generated facts without substituting the stored projection.
                userMemoryCore = []
                noteRecallUnavailable(error, input: "user memory", operation: "memory.user_core", owner: "memory/memory.sqlite")
            }
        } else {
            userMemoryCore = []
            userCoreUnavailable = true
            noteRecallUnavailable(
                ToolFailureError("The user memory data root is unavailable.", effects: .none,
                    owner: "memory/memory.sqlite", code: "memory_user_core_unavailable", recovery: .repair),
                input: "user memory", operation: "memory.user_core", owner: "memory/memory.sqlite"
            )
        }
        trace.setFlag("memory.userCoreUnavailable", userCoreUnavailable)
        if crossSessionRecall, remPinsDataRoot != nil, !userCoreUnavailable {
            RepairOwed.settle(recallRepairRoot, operation: "memory.user_core",
                evidence: .init(source: "memory/memory.sqlite", id: "userPromptCore"))
        }
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
            stableSegmentCarriesRequiredDocuments: true,
            userMemoryCore: userMemoryCore,
            memoryRecallEnabled: semanticRecallEnabled,
            // The same number the renderer cuts at, so the selector publishes a
            // pointer for exactly the atoms that get cut.
            packetAtomExpandThresholdChars:
                ContextBudgetPolicy.packetAtomExpandThresholdChars,
            // ContextBudgetPolicy bounds both recall paths; the per-turn recall switch can admit zero rows.
            memoryAtomRowLimit: crossSessionRecall ? turnBudget.recallRowLimit : 0
        )
        var preparedContextTurn: ContextPreparedTurn?
        switch contextFlowMode {
        case .off:
            trace.setFlag("contextFlow.enabled", false)
        case .active:
            trace.setFlag("contextFlow.enabled", true)
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                preparedContextTurn = try await contextFlow?.prepareContextTurn(contextFlowRequest, turn: turn)
                try Task.checkCancellation()
                if let expansion = preparedContextTurn?.budgetExpansion {
                    trace.setFlag("contextFlow.budgetExpanded", true)
                    trace.setCount(
                        "contextFlow.requestedCharacterBudget",
                        expansion.requestedCharacterBudget
                    )
                    trace.setCount(
                        "contextFlow.effectiveCharacterBudget",
                        expansion.effectiveCharacterBudget
                    )
                    trace.setCount(
                        "contextFlow.maximumCharacterBudget",
                        expansion.maximumCharacterBudget
                    )
                    trace.setCount(
                        "contextFlow.grantedPostMandatoryReserve",
                        expansion.grantedPostMandatoryReserve
                    )
                }
                trace.record(.contextFlowPrepare, since: start)
            } catch {
                try Task.checkCancellation()
                trace.record(.contextFlowPrepare, since: start)
                // Recall gaps were named above. Required context still must prepare;
                // a stand-in prompt cannot replace a failed generation or persona.
                throw TurnEngineError.contextLoadFailed(underlying: error)
            }
        }
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
                trace.setCount(
                    "contextFlow.selectedAtoms",
                    preparedContextTurn.packet.selectedItems.count
                )
                trace.setCount(
                    "contextFlow.packetChars",
                    preparedContextTurn.packet.characterCount
                )
                trace.setCount(
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
                    trace.setCount("contextFlow.memoryFloorDropped", memoryFloorDropped)
                }
                // Expandable count must equal truncated count; any gap means a cut body has no usable recovery pointer.
                let truncation = Self.packetTruncationCounts(preparedContextTurn)
                trace.setCount("contextFlow.truncatedAtoms", truncation.truncatedAtoms)
                trace.setCount("contextFlow.leadChars", truncation.leadChars)
                trace.setCount(
                    "contextFlow.expandableAfterTruncation",
                    truncation.expandableAfterTruncation
                )
                // Required documents belong in the cached prefix, not the per-turn packet.
                trace.setFlag("persona.inStablePrefix", true)
                trace.setCount("persona.stableDocs", stableDocuments.included.count)
                // Missing surface-permission evidence withholds the document from both prefix and packet; trace the wiring fault explicitly.
                if !stableDocuments.unprovenDocumentIDs.isEmpty {
                    trace.setCount(
                        "persona.stableDocsUnproven",
                        stableDocuments.unprovenDocumentIDs.count
                    )
                    trace.setLabel(
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
            trace.recordMicroseconds(.personaCompile, since: personaStartNs)
        } catch {
            trace.recordMicroseconds(.personaCompile, since: personaStartNs)
            try Task.checkCancellation()
            throw TurnEngineError.personaLoadFailed(underlying: error)
        }
        // Share the bounded person picture with persona readers and recall precoverage.
        let userDocument = personaMap["USER"]
        if let userDocument {
            personaMap["USER"] = UserMDAutogenMarkers.promptText(userDocument, userMemoryCore: userMemoryCore)
        }
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
                noteRecallUnavailable(error, input: "REM pins", operation: "rem_pins.read", owner: "rem_pins.json")
            }
        }
        trace.record(.remPinsRead, since: remStartNs)

        // Session-backed recall may expand the query with continuity anchors.
        let memoryStartNs = DispatchTime.now().uptimeNanoseconds
        trace.setCount("budget.windowTokens", turnBudget.windowTokens ?? 0)
        trace.setFlag("budget.derived", turnBudget.isDerived)
        trace.setCount("budget.recallRowLimit", turnBudget.recallRowLimit)
        trace.setCount("budget.memoryBlockChars", turnBudget.memoryBlockChars)
        try Task.checkCancellation()
        trace.setFlag("history.recallQueryBuilt", false)
        trace.setCount("history.recallQueryChars", 0)
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
                expandedRecallQuery = await trace.measure(.recallQuery) {
                    SessionHistoryPromptRenderer.recallQuery(
                        userMessage: queryMessage, renderables: recallHistory
                    )
                }
                trace.setFlag("history.recallQueryBuilt", true)
                trace.setCount("history.recallQueryChars", expandedRecallQuery?.count ?? 0)
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
                trace.setMemoryRecallOutcome(.succeeded(hitCount: recalled.count))
                RepairOwed.settle(recallRepairRoot, operation: "memory.turn_recall",
                    evidence: .init(source: "memory/memory.sqlite", id: "recall"))
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                trace.setMemoryRecallOutcome(.failed(
                    errorType: String(reflecting: type(of: error))
                ))
                let repairRequired = await memory.recallRepairRequired(for: error)
                try Task.checkCancellation()
                noteRecallUnavailable(error, input: "memory recall", operation: "memory.turn_recall", owner: "memory/memory.sqlite",
                    repairRequired: repairRequired)
            }
        } else {
            trace.setMemoryRecallOutcome(.notConfigured)
        }
        // Prepared turns report only the selector's measured recall latency; no sample means no timing.
        if preparedContextTurn == nil {
            trace.recordMicroseconds(.memoryRecall, since: memoryStartNs)
        } else if let selectionMicros = preparedContextTurn?.packet.receipt
            .measuredSelectionMicroseconds {
            trace.setMicroseconds(.memoryRecall, microseconds: Int64(selectionMicros))
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
        // Chat offers only `app`; internal catalogs remain discoverable and available to explicit callers.
        let toolNames: [String]
        let toolSchemas: [LLMToolSchema]
        trace.setFlag("tools.fullCatalogRequested", offeredToolNames == nil)
        do {
            (toolNames, toolSchemas) = try await holding(work.with(\.preparedContext, preparedContextTurn)) { work in
                let tools = self.tools
                if let offeredToolNames {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let schemas = try await tools.listAvailableToolSchemas(named: offeredToolNames, turn: turn, surface: surface)
                    trace.recordMicroseconds(.toolsSchemas, since: started)
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
                trace.setTiming(.toolsNames, milliseconds: Int64(catalog.0.1 / 1_000_000))
                trace.setTiming(.toolsSchemas, milliseconds: Int64(catalog.1.1 / 1_000_000))
                return (catalog.0.0.filter { !SwiftToolDispatcher.isModelHidden($0) }, catalog.1.0)
            }
        } catch {
            try Task.checkCancellation()
            throw TurnEngineError.toolCatalogLoadFailed(underlying: error)
        }
        // The stem gathers inputs and composes the prompt strings turn.js receives.
        let intentions: String
        do {
            intentions = try await intentionsContext(now: currentTurnClock, sessionID: sessionID, surface: surface, turn: turn)
        } catch let unavailable as IntentionsContextUnavailable {
            try Task.checkCancellation()
            intentions = "MY QUEUE is unavailable; no queued step was admitted this turn."
            noteRecallUnavailable(unavailable, input: "intentions", operation: unavailable.operation, owner: unavailable.owner)
        }
        let renderStartNs = DispatchTime.now().uptimeNanoseconds
        // A person picture establishes the person and suppresses first-run invitations.
        let established = !userMemoryCore.isEmpty
        let deliveredRows = Self.deliveredRecalledMemoryRows(recalled, budget: turnBudget)
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
        let recallNotice = recallUnavailableReasons.isEmpty ? "" : "Recall was unavailable this turn (\(recallUnavailableReasons.joined(separator: "; ")))."
            + " This is not evidence that a memory exists or does not exist."
        let episodic = try await episodicContext(sessionID: sessionID,
            crossSessionRecall: crossSessionRecall, now: currentTurnClock, turn: turn)
        let packetSections: [String] = [userPicture, episodic.life, intentions, contextPacket, continuationContext, recallNotice]
        let packet = packetSections.filter { !$0.isEmpty }.joined(separator: "\n\n")
        // The agent's own line with written instructions is the one they write; everything else it reaches is the agent's.
        let reach = TurnReach(
            persona: turn.lineInstructions ?? personaPrompt,
            expression: .object(["established": userCoreUnavailable ? .null : .bool(established)]),
            pins: remPins.map(\.text),
            recall: Self.renderRecalledMemoryBlock(deliveredRows) ?? "",
            packet: packet
        )
        trace.record(.promptRender, since: renderStartNs)
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
        var finalContext: TurnContext
        let quietHoursActive: Bool = {
            guard let quietHours = quietHoursSnapshot else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return quietHours.contains(hour: calendar.component(.hour, from: currentTurnClock))
        }()
        // Stamp the same frozen quiet-hour semantic even when history defers clock rendering, so the base receipt remains unambiguous.
        trace.setFlag(
            "clock.quietHoursActive",
            quietHoursActive
        )
        let factsJoinStart = DispatchTime.now().uptimeNanoseconds
        if let facts = try await currentFacts {
            trace.record(.factsJoin, since: factsJoinStart)
            // Prompt and summary share the same pinned active quiet-hour state.
            finalContext = try await contextByAppendingCurrentTurnFacts(
                baseContext, facts: facts, sessionID: sessionID, clockNowOverride: currentTurnClock, trace: &trace, turn: turn, work: work)
            trace.record(ContextStageName.contextClockRuntime, since: factsJoinStart)
        } else {
            finalContext = baseContext
        }
        try Task.checkCancellation()
        if contextFlowMode == .active {
            trace.setFlag("contextFlow.active", preparedContextTurn != nil)
        }
        if let contextFlowMemoryAtomCount {
            trace.setMemoryRecallOutcome(.contextFlow(hitCount: contextFlowMemoryAtomCount))
        }
        trace.setCount("snapshot.toolNames", toolNames.count)
        trace.setCount("snapshot.toolSchemas", toolSchemas.count)
        trace.setCount("snapshot.toolSchemaParameterBytes", toolSchemas.reduce(0) { $0 + $1.parametersJSON.count })
        trace.setCount("persona.docCount", personaMap.count)
        trace.setCount("persona.docChars", personaMap.values.reduce(0) { $0 + $1.count })
        trace.setCount("remPins.count", remPins.count)
        // Injected identities unite recalled rows and packet provenance; the separate count covers rows only.
        trace.setInjectedMemoryIDs(baseContext.resolvedRecalledIds)
        trace.setCount("memory.recallHits.direct", recalled.count)
        trace.setCount("userMessageChars", userMessage.count)
        trace.setCount("imageBlockCount", imageBlocks.count)
        trace.setFlag("snapshot.requestScoped", true)
        finalContext.preparationMs = trace.emit(kind: "context.summary", surface: surface)
        // Credit only accepted, rendered memories after pin deduplication; undelivered rows must not gain eviction-protecting use counts.
        finalContext.usageCreditMemoryIDs = servedContextMemoryIDs
            + deliveredRows.compactMap { row in
                guard case .object(let extras)? = row.hit.extras,
                      case .string(let id)? = extras["id"] else { return nil }
                return id
            }
        return finalContext
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
        // Only nonempty term keys enter the lexical query; weights cross the attention seam separately.
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
