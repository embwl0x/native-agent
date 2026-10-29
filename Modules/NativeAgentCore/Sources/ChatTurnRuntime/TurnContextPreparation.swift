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
import Transcripts
// Blueprint: | `TurnContextPreparation.swift` | SwiftNativeTurnEngine context preparation, checked route admission, frozen reach and bounded attention inputs |
extension SwiftNativeTurnEngine {
    /// Build the per-turn context, optionally carrying per-turn DYNAMIC image
    /// content blocks attached to the CURRENT user message. The image blocks
    /// NEVER enter systemPrompt/systemSegments (cache invariant) — they sit on
    /// `TurnContext.imageBlocks` and are consumed when the first user message
    /// of the conversation is built (ToolLoop/Streaming/Text-compat).
    public func buildTurnContext(
        surface: String,
        userMessage: String,
        personaOverride: String?,
        imageBlocks: [LLMContentBlock] = [],
        recallQueryOverride: String? = nil,
        includeClockContext: Bool = true,
        sessionID: String? = nil,
        recentTurns: [String] = [],
        // The raw user text for RELEVANCE consumers (selection queryText,
        // memory recall, query embedding) when `userMessage` carries
        // turn-scoped wire riders — e.g. the text-compat tool-routing hint,
        // which otherwise makes tool names query vocabulary on every turn.
        // nil → `userMessage`.
        // `userMessage` stays the wire/persona-visible turn text.
        queryUserMessage: String? = nil,
        // Turn-start instant for the clock line; a multi-iteration tool loop
        // passes the same value every iteration so the dynamic segment's
        // time line can't churn the cache mid-turn. nil = clock() per build.
        clockNowOverride: Date? = nil,
        offeredToolNames: Set<String>? = nil
    ) async throws -> TurnContext {
        let quietHoursWindow = readTurnQuietHours()
        return try await buildTurnContext(
            surface: surface,
            userMessage: userMessage,
            personaOverride: personaOverride,
            imageBlocks: imageBlocks,
            recallQueryOverride: recallQueryOverride,
            includeClockContext: includeClockContext,
            sessionID: sessionID,
            recentTurns: recentTurns,
            queryUserMessage: queryUserMessage,
            clockNowOverride: clockNowOverride,
            quietHoursSnapshot: quietHoursWindow,
            offeredToolNames: offeredToolNames
        )
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
        queryUserMessage: String?,
        clockNowOverride: Date?,
        quietHoursSnapshot: TurnQuietHoursWindow?,
        offeredToolNames: Set<String>? = nil,
        recallHistory: [SessionHistoryPromptRenderer.Renderable]? = nil
    ) async throws -> TurnContext {
        // Normalize the Workshop spelling once for routing, context, autonomy and telemetry.
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        try Task.checkCancellation()
        var trace = ContextStageTrace()
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageBlocks.isEmpty
        {
            throw TurnEngineError.emptyMessage
        }
        // Explicit relevance text is authoritative even when blank, keeping wire hints out of recall.
        // Blank text skips query embedding; selection can still use attention terms and entities.
        let queryMessage = queryUserMessage ?? userMessage
        trace.setCount("contextFlow.queryMessageChars", queryMessage.count)
        // Pin one clock instant for both the dynamic clock line and the receipt
        // flag. The flag is the active semantic, not mere preference-file
        // availability: an outside-window turn must never look quiet merely
        // because a window happens to be configured.
        let currentTurnClock = clockNowOverride ?? clock()
        // The facts of this moment read nothing assembled below, so they
        // gather beside it and the composition at the end consumes them once.
        async let currentFacts = includeClockContext
            ? currentTurnFacts(clockNow: currentTurnClock, quietHours: quietHoursSnapshot,
                               sessionID: sessionID, queryUserMessage: queryMessage)
            : nil
        // Start the existing bge query lane before the bounded attention
        // read, so the vector embeds while that work runs.
        let semanticQuery = SessionHistoryPromptRenderer.semanticRecallQuery(
            userMessage: queryMessage, recentTurns: recentTurns
        )
        trace.setCount("contextFlow.semanticQueryChars", semanticQuery.count)
        // A follow-up also asks in its own words, each a separate reading.
        let queryEmbeddingTicket = await contextFlow?.beginQueryEmbedding(
            semanticQuery, ownWords: semanticQuery == queryMessage ? nil : queryMessage
        )

        // Read attention within its deadline before constructing the context request.
        let attentionStartNs = DispatchTime.now().uptimeNanoseconds
        let attention = try await resolvedAttentionInputs(now: clock(), message: queryMessage, trace: &trace)
        trace.record(.contextFlowAttention, since: attentionStartNs)
        // Work context remains query-selectable without coloring unrelated turns.
        let suppressActiveIntent = ContextSurface(rawValue: surface) == .workshop
            || attention.residentWorkIntent
        let contextFlowMode = await contextFlow?.contextFlowMode() ?? .off
        // Recall by meaning is what this turn's memory is for, so it waits a
        // bounded moment for the vector; one that misses leaves the turn
        // lexical-only, and the trace flag says it was not there.
        let readyQueryEmbedding = await queryEmbeddingTicket?.value(within: Self.queryEmbeddingWaitNanos)
        trace.setFlag("contextFlow.semanticQueryReady", readyQueryEmbedding != nil)
        // 1. Reuse the facade's already-checked route when present. Direct
        //    context callers still admit here. This avoids adding a second
        //    provider-store read to ordinary chat; the shared adapter performs
        //    its existing checked reread immediately before transport, so
        //    corrupt/revoked authority still fails closed without allowing a
        //    newer valid generation to splice into this turn.
        let boundModel = LLMCallContext.admittedModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundEffort = LLMCallContext.reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId: String
        let effort: String
        let admittedProvider: String?
        let admittedServiceTier: String?
        if let boundModel, !boundModel.isEmpty,
           let boundEffort, !boundEffort.isEmpty {
            modelId = boundModel
            effort = boundEffort
            // The admission owns the route; model names never select a provider.
            admittedProvider = LLMCallContext.providerId
            admittedServiceTier = LLMCallContext.serviceTier
            trace.setFlag("provider.admissionReused", true)
        } else {
            let prefsStartNs = DispatchTime.now().uptimeNanoseconds
            let admission = try await router.checkedRouteAdmission(for: surface)
            trace.record(.providerPreferences, since: prefsStartNs)
            modelId = admission.modelId
            effort = admission.reasoningEffort
            admittedProvider = admission.providerId
            admittedServiceTier = admission.serviceTier
            trace.setFlag("provider.admissionReused", false)
        }
        let turnBudget = ContextBudgetPolicy.resolve(
            model: modelId,
            providerID: admittedProvider,
            dataRoot: remPinsDataRoot
        )
        trace.setFlag("budget.packetDerived", turnBudget.isDerived)
        // Settings ▸ "Remember across conversations". One fresh read per turn,
        // shared by the packet's memory lane and the legacy recall lane below.
        // The explicit `recall_memory` tool is deliberately NOT gated: this
        // switch is about AUTOMATIC recall, not about asking.
        let crossSessionRecall = MemoryPolicyGate.crossSessionRecallEnabled(
            dataRoot: remPinsDataRoot
        )
        trace.setFlag("memory.crossSessionRecall", crossSessionRecall)
        let userMemoryCore: [String]?
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
                throw TurnEngineError.contextLoadFailed(underlying: error)
            }
        } else {
            userMemoryCore = nil
        }
        let contextFlowRequest = ContextTurnRequest(
            surface: ContextSurface(rawValue: surface),
            origin: Self.contextOrigin(for: surface),
            userMessage: queryMessage,
            personaIDHint: personaOverride,
            sessionID: sessionID,
            recentTurns: recentTurns,
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
            // The chat turn renders the persona's required documents into the
            // STABLE segment, so the
            // packet must not mirror them into the volatile block as well.
            stableSegmentCarriesRequiredDocuments: true,
            userMemoryCore: userMemoryCore,
            memoryRecallEnabled: crossSessionRecall,
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
                preparedContextTurn = try await contextFlow?.prepareContextTurn(contextFlowRequest)
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
                // No legacy prompt stands in: a reply without her context
                // would read as her while missing what she knows.
                throw TurnEngineError.contextLoadFailed(underlying: error)
            }
        }
        // PersonaCompiler owns canonical document order, surface guidance, overrides and fingerprinting.
        var personaMap: [String: String]
        let personaFingerprint: String
        let resolvedPersonaID: String?
        let compiledPersonaPrompt: String
        let personaStartNs = DispatchTime.now().uptimeNanoseconds
        // The stable segment holds only what changes when her documents
        // change: USER renders there with its preamble alone, and the facts
        // memory adds each day ride the dynamic tail, so a new fact does not
        // rewrite the cached history behind it. Nil (no memory root) keeps the
        // whole document, which only changes when the document does.
        let stableUserCore = userMemoryCore.map { _ in [String]() }
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
                    TurnTraceBus.fireFromContext(kind: "mind.why", sessionId: sessionID, surface: surface, payload: why)
                }
                // How many ranked memory rows the semantic floor refused. A
                // packet that is quiet because nothing was relevant and one
                // that is quiet because the embedder was cold look identical
                // downstream; this is the number that tells them apart.
                let memoryFloorDropped = preparedContextTurn.packet.receipt
                    .memoryFloorDroppedCount
                if memoryFloorDropped > 0 {
                    trace.setCount("contextFlow.memoryFloorDropped", memoryFloorDropped)
                }
                // Lead-and-pointer receipts. `truncatedAtoms` is how many bodies
                // became a rule plus a pointer, `leadChars` is what those leads
                // cost, and `expandableAfterTruncation` must equal
                // `truncatedAtoms` — any gap is a cut body the model cannot get
                // back, which is the one failure mode of this whole change.
                let truncation = Self.packetTruncationCounts(preparedContextTurn)
                trace.setCount("contextFlow.truncatedAtoms", truncation.truncatedAtoms)
                trace.setCount("contextFlow.leadChars", truncation.leadChars)
                trace.setCount(
                    "contextFlow.expandableAfterTruncation",
                    truncation.expandableAfterTruncation
                )
                // The persona's required documents ride the CACHED prefix on
                // this path, not the per-turn packet.
                trace.setFlag("persona.inStablePrefix", true)
                trace.setCount("persona.stableDocs", stableDocuments.included.count)
                // A document that could not PROVE a surface permission is
                // withheld from the prefix AND refused by the packet, so it is
                // absent from the turn entirely. That is a wiring fault, never a
                // policy outcome, and it must never be silent: name the
                // documents so the trace says which identity went missing.
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
                    surface: surface, personaOverride: personaOverride, userMemoryCore: stableUserCore,
                    identityRequired: true
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
        // What USER carried this turn: its preamble in the stable segment, its
        // pinned facts in the dynamic tail (`UserMDAutogenMarkers.pinnedSection`).
        let userDocument = personaMap["USER"]
        if let userDocument {
            personaMap["USER"] = UserMDAutogenMarkers.promptText(userDocument, pinnedCore: userMemoryCore)
        }
        // REM-approved pins take precedence over overlapping recalls.
        let remStartNs = DispatchTime.now().uptimeNanoseconds
        var remPins: [REMPin] = []
        if let dataRoot = remPinsDataRoot {
            do {
                remPins = REMPinsReader.latest(try REMPinsReader.read(dataRoot: dataRoot), latestN: 3)
            } catch {
                trace.record(.remPinsRead, since: remStartNs)
                throw error
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
        var recallIssue: String?
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
            // Settings ▸ "Remember across conversations": off skips the
            // automatic root-wide recall entirely (see `crossSessionRecall`).
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
                    persona: nil,
                    surface: surface
                )
                trace.setMemoryRecallOutcome(.succeeded(hitCount: recalled.count))
            } catch {
                try Task.checkCancellation()
                recalled = []
                recallIssue = "[memory.recall reason=recall_read_failed] Recall could not be read for this message: "
                    + error.localizedDescription.split(whereSeparator: \.isNewline).joined(separator: " ")
                    + ". Read app {page:\"memory\"} for memory store and search model status; resolve the reported cause before relying on recall."
                trace.setMemoryRecallOutcome(.failed(
                    errorType: String(reflecting: type(of: error))
                ))
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
        // Dedup: drop recalls whose text is superseded by a REM pin sharing
        // the same key or whose preview contains the pin's text verbatim.
        // This keeps the context tight — the pin IS the authoritative fact.
        if !remPins.isEmpty {
            recalled = recalled.filter { hit in
                !remPins.contains(where: { pin in
                    !hit.preview.isEmpty
                        && !pin.text.isEmpty
                        && (hit.preview.contains(pin.text) || pin.text.contains(hit.preview))
                })
            }
        }
        // Ordinary turns offer only app. Internal catalogs remain available
        // on discovery and to lanes that supply their own tool lists.
        let toolNames: [String]
        let toolSchemas: [LLMToolSchema]
        trace.setFlag("tools.fullCatalogRequested", offeredToolNames == nil)
        do {
            (toolNames, toolSchemas) = try await FluidContextToolScope.$current.withValue(preparedContextTurn) {
                if let offeredToolNames {
                    let schemas = try await tools.listAvailableToolSchemas(named: offeredToolNames)
                    return (schemas.map(\.name), schemas)
                }
                async let names: ([String], UInt64) = {
                    let started = DispatchTime.now().uptimeNanoseconds
                    return (try await tools.listAvailableTools(), DispatchTime.now().uptimeNanoseconds &- started)
                }()
                async let schemas: ([LLMToolSchema], UInt64) = {
                    let started = DispatchTime.now().uptimeNanoseconds
                    return (try await tools.listAvailableToolSchemas(), DispatchTime.now().uptimeNanoseconds &- started)
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
        // The stem gathers prompt inputs; abilities/turn.js owns their composition and order.
        let renderStartNs = DispatchTime.now().uptimeNanoseconds
        // A pinned USER core establishes the person and suppresses first-run invitations.
        let established = !(userMemoryCore ?? []).isEmpty
        let deliveredRows = Self.deliveredRecalledMemoryRows(recalled, budget: turnBudget)
        let reach = TurnReach(
            persona: Self.renderPersonaPrompt(
                compiledPersonaPrompt: compiledPersonaPrompt,
                requiredDocuments: stableDocuments.included,
                userMemoryCore: stableUserCore,
                surfaceGuidance: preparedContextTurn?.kernel.surfaceGuidance ?? ""
            ),
            expression: .object(["established": .bool(established)]),
            pins: remPins.map(\.text),
            recall: Self.renderRecalledMemoryBlock(deliveredRows) ?? "",
            packet: [
                userDocument.map { UserMDAutogenMarkers.pinnedSection($0, pinnedCore: userMemoryCore) } ?? "",
                preparedContextTurn.map(Self.renderContextPacket) ?? "",
                MacWorkContinuation.current?.modelContext ?? "",
            ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        )
        trace.record(.promptRender, since: renderStartNs)
        let baseContext = TurnContext(
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
        var finalContext: TurnContext
        let quietHoursActive: Bool = {
            guard let quietHours = quietHoursSnapshot else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return quietHours.contains(hour: calendar.component(.hour, from: currentTurnClock))
        }()
        // The summary is emitted even when a history caller asks this base
        // builder to defer clock rendering, so stamp the same pinned semantic
        // before the branch. The history assembler then owns the one eventual
        // prompt rendering without leaving its base context receipt ambiguous.
        trace.setFlag(
            "clock.quietHoursActive",
            quietHoursActive
        )
        if let facts = await currentFacts {
            // Receipt truth: the dynamic prompt gets the quiet-hours marker
            // only on an active turn, and the summary carries that same pinned
            // active state for live-rate observation.
            let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
            finalContext = await contextByAppendingCurrentTurnFacts(
                baseContext, facts: facts, sessionID: sessionID, clockNowOverride: currentTurnClock)
            trace.record(ContextStageName.contextClockRuntime, since: runtimeStartNs)
        } else {
            finalContext = baseContext
        }
        try Task.checkCancellation()
        if contextFlowMode == .active {
            trace.setFlag("contextFlow.active", preparedContextTurn != nil)
            // A missing query vector is a fact of this turn, not a quiet weaker one.
            if let queryEmbeddingTicket, readyQueryEmbedding == nil {
                let cause = queryEmbeddingTicket.unavailable ?? "the query embedding did not land within half a second"
                finalContext = Self.contextByAppendingRuntimeContext(finalContext, runtimeContext:
                    "[memory.recall reason=semantic_recall_unavailable] Recall matched words only: \(cause). Read app {page:\"memory\"} for the memory search model's current state before relying on semantic coverage.")
            }
        }
        if let recallIssue {
            finalContext = Self.contextByAppendingRuntimeContext(finalContext, runtimeContext: recallIssue)
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
        trace.setCount("memory.recallHits.legacy", recalled.count)
        trace.setCount("userMessageChars", userMessage.count)
        trace.setCount("imageBlockCount", imageBlocks.count)
        trace.setFlag("snapshot.requestScoped", true)
        finalContext.preparationMs = trace.emit(kind: "context.summary", surface: surface)
        // creditDeliveredMemories credits accepted context only, after pin dedup and render limits.
        // Undelivered rows must not gain use_count, which vetoes eviction.
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
    /// Bounded, pure read of the cognitive provider's attention signals,
    /// translated into ContextTurnRequest inputs. Records per-input trace
    /// counts + a timeout flag. Returns all-default inputs when no provider is
    /// wired, the provider returns nil/empty, or the read exceeds the deadline.
    private func resolvedAttentionInputs(
        now: Date,
        message: String,
        trace: inout ContextStageTrace
    ) async throws -> AttentionInputs {
        try Task.checkCancellation()
        guard let cognitiveRuntime else { return AttentionInputs() }

        // The live provider reads an already-published cache without actor or
        // storage waits. Keep the protocol seam bounded for other providers.
        // The operation's race owner cancels the deadline on success, the read
        // on expiry, and both on requester cancellation, without joining a
        // non-cooperative read or publishing its late result.
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
                    ])
                )
            }
            return AttentionRaceOutcome.signals(signals, snapshot)
        }
        try Task.checkCancellation()

        let signals: CognitiveAttentionSignals?
        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .timedOut, .failure:
            recordAttentionTrace(attentionTrace.snapshot(), into: &trace)
            trace.setFlag("contextFlow.attentionTimedOut", true)
            return AttentionInputs()
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
        // Terms carry weights across the seam but fold into queryText lexically —
        // only the keys are needed here (empties dropped: never pass empty text).
        inputs.contextualTerms = Set(signals.terms.keys.filter { !$0.isEmpty })
        inputs.predictedToolGroups = signals.predictedToolGroups
        inputs.unresolvedQuestion = Self.nonEmpty(signals.unresolvedQuestion)
        inputs.activeTask = Self.nonEmpty(signals.activeTask)
        inputs.goal = Self.nonEmpty(signals.goal)
        inputs.residentWorkIntent = signals.residentWorkIntent

        // Memory RECORD ids → ContextAtomID is app-owned (owner string lives
        // app-side). Without a translator, memory-keyed activation is dropped;
        // terms/intent still flow.
        if let memoryAtomTranslator {
            for (recordID, weight) in signals.memoryActivation {
                guard let atomID = memoryAtomTranslator(recordID) else { continue }
                inputs.cognitiveActivation[atomID] = max(
                    inputs.cognitiveActivation[atomID] ?? 0, weight
                )
            }
            // Suppress memories she rejected for this kind of thing.
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
