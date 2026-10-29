import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import TrustCenter
import CryptoKit
import GRDB
import PersonaEngine
// Blueprint: | `ContextPreparation+TurnSelection.swift` | Generation-derived authorization and precoverage, exact turn leases and mandatory-budget retry; verification filters delivery while preserving selection receipts, budgets and feedback IDs |

extension ContextPreparation {
    struct GenerationDerivedCacheKey: Hashable, Sendable {
        let generationID: Int64
        let generationSourceFingerprint: String
        let surface: String
        let personaID: String
        let mirrorSourceFingerprint: String
        let kernelPersonaID: String
        let kernelSurface: String
        let kernelSourceFingerprint: String
        let stableIncludedDocumentIDs: [String]
        let allowedPrivacy: [String]
        /// Part of the key because it changes the DERIVED value: it decides
        /// whether every persona source is precovered or only the kernel's.
        let stableSegmentCarriesRequiredDocuments: Bool
        let userMemoryCore: [String]?
        let memoryRecallDisabled: Bool
        let excludedSourceOwners: Set<String>

        init(
            generation: ContextStoredGeneration,
            request: ContextTurnRequest,
            mirror: RequiredDocumentMirror,
            kernel: StablePromptKernel,
            excludedSourceOwners: Set<String>
        ) {
            generationID = generation.generation.id
            generationSourceFingerprint = generation.generation.sourceFingerprint
            surface = request.surface.rawValue
            personaID = mirror.personaID.rawValue
            mirrorSourceFingerprint = mirror.sourceFingerprint
            kernelPersonaID = kernel.key.personaID.rawValue
            kernelSurface = kernel.key.surfaceVariant.rawValue
            kernelSourceFingerprint = kernel.key.sourceFingerprint
            stableIncludedDocumentIDs = kernel.includedDocumentIDs.map(\.rawValue)
            allowedPrivacy = request.allowedPrivacy.map(\.rawValue).sorted()
            stableSegmentCarriesRequiredDocuments = request.stableSegmentCarriesRequiredDocuments
            userMemoryCore = request.userMemoryCore
            memoryRecallDisabled = !request.memoryRecallEnabled
            self.excludedSourceOwners = excludedSourceOwners
        }
    }

    struct GenerationDerivedTurnState: Sendable {
        let allowedSourceIDs: Set<ContextSourceID>
        let precoveredSourceIDs: Set<ContextSourceID>
        let protectedCorrectionAtomIDs: Set<ContextAtomID>
        let memoryPersonaPrefix: String
        let slotScopedMemorySourceCount: Int
    }

    private func generationDerivedTurnState(
        generation: ContextStoredGeneration,
        request: ContextTurnRequest,
        mirror: RequiredDocumentMirror,
        kernel: StablePromptKernel
    ) -> GenerationDerivedTurnState {
        let excludedSourceOwners = Set(compiledProjectionProviders.flatMap(\.excludedSourceOwners))
        let key = GenerationDerivedCacheKey(
            generation: generation,
            request: request,
            mirror: mirror,
            kernel: kernel,
            excludedSourceOwners: excludedSourceOwners
        )
        if let cached = generationDerivedCache[key] {
            return cached
        }

        let personaPrefix = ContextPersonaSourceNaming.locatorPrefix(for: mirror.personaID)
        let normalizedPersonaID = mirror.personaID.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let memoryPersonaPrefix = "memory-v2/personas/\(ContextStableID.digest(parts: [normalizedPersonaID]))/"
        var selectedSources: [ContextStoredSource] = []
        selectedSources.reserveCapacity(generation.sources.count)
        var slotScopedMemorySourceCount = 0
        for source in generation.sources {
            if excludedSourceOwners.contains(source.descriptor.owner) { continue }
            if !request.memoryRecallEnabled,
               ["nativeagent.memory-v2", "nativeagent.knowledge-graph"].contains(source.descriptor.owner) { continue }
            if source.descriptor.owner == "nativeagent.memory-v2",
               source.descriptor.canonicalLocator.hasPrefix(memoryPersonaPrefix) {
                slotScopedMemorySourceCount += 1
            }
            if source.descriptor.permittedSurfaces.contains(request.surface),
               request.allowedPrivacy.contains(source.descriptor.privacy),
               source.descriptor.owner != ContextPersonaSourceNaming.owner
                    || source.descriptor.canonicalLocator.hasPrefix(personaPrefix) {
                // Preserve generation order for precoverage derivation.
                selectedSources.append(source)
            }
        }

        let allowedSourceIDs = Set(selectedSources.map(\.descriptor.id))
        let precoveredDocumentNames = Set(kernel.includedDocumentIDs.map {
            String($0.rawValue.dropLast(3))
        })
        let surfaceSuffix = "/surfaces/\(request.surface.rawValue).md"
        // Precover persona sources carried verbatim by the stable segment;
        // otherwise precover only kernel and surface documents.
        // Rendering and precoverage must both enforce the source's surface permission.
        var precoveredSourceIDs = Set(selectedSources.lazy.filter { source in
            guard source.descriptor.owner == ContextPersonaSourceNaming.owner,
                  source.descriptor.permittedSurfaces.contains(request.surface)
            else { return false }
            if request.stableSegmentCarriesRequiredDocuments { return true }
            let locator = source.descriptor.canonicalLocator
            if locator.hasSuffix(surfaceSuffix) { return true }
            let documentName = locator.split(separator: "/").last.map(String.init)?
                .replacingOccurrences(of: ".md", with: "")
            return documentName.map(precoveredDocumentNames.contains) ?? false
        }.map(\.descriptor.id))
        // Precover persona USER atoms, but suppress canonical memory only for carried USER facts.
        if let user = mirror.documents.first(where: { $0.id.rawValue == "USER.md" }),
           let userSourceID = user.sourceID, precoveredSourceIDs.contains(userSourceID) {
            let carried = UserMDAutogenMarkers.promptText(user.text, pinnedCore: request.userMemoryCore)
            let facts = Self.generatedUserFacts(in: carried) ?? Set(carried.split(separator: "\n").compactMap { line in
                line.hasPrefix("- ") ? MemoryDisplayText.projectionJoinKey(String(line.dropFirst(2))) : nil
            })
            let factsByCore = Dictionary(grouping: facts, by: \.core)
            let memorySourceIDs = Set(selectedSources.lazy.filter {
                $0.descriptor.owner == "nativeagent.memory-v2"
            }.map(\.descriptor.id))
            for atom in generation.atoms where atom.validToGeneration == nil
                && memorySourceIDs.contains(atom.draft.sourceID) {
                let body = MemoryDisplayText.projectionJoinKey(MemoryDisplayText.attributed(
                    atom.draft.body, sources: ContextMemoryLead.untrustedSources(for: atom.draft)))
                if factsByCore[body.core]?.contains(where: { $0.isCovered(by: body) }) == true {
                    precoveredSourceIDs.insert(atom.draft.sourceID)
                }
            }
        }

        let protectedCorrectionAtomIDs = Set(generation.atoms.lazy.filter { atom in
            atom.validToGeneration == nil
                && atom.draft.kind == .correction
                && atom.draft.authority == .explicitCorrection
                // Only topic-scoped corrections receive mandatory protection.
                && ContextCorrectionScope.hasTopics(atom.draft)
                && allowedSourceIDs.contains(atom.draft.sourceID)
                && request.allowedPrivacy.contains(atom.draft.privacy)
                && atom.draft.permittedSurfaces.contains(request.surface)
        }.map(\.draft.id))
        let derived = GenerationDerivedTurnState(
            allowedSourceIDs: allowedSourceIDs,
            precoveredSourceIDs: precoveredSourceIDs,
            protectedCorrectionAtomIDs: protectedCorrectionAtomIDs,
            memoryPersonaPrefix: memoryPersonaPrefix,
            slotScopedMemorySourceCount: slotScopedMemorySourceCount
        )
        generationDerivedCache[key] = derived
        return derived
    }

    func invalidateGenerationDerivedCache() {
        guard !generationDerivedCache.isEmpty else { return }
        generationDerivedCache.removeAll(keepingCapacity: true)
    }

    public func prepareTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        guard started, mode != .off else {
            throw ContextTurnPreparationError.coordinatorNotStarted
        }
        // The turn reads the published generation; it never joins a compile.
        guard let generation = activeStoredGeneration else {
            reconcileInBackground(reason: "turn_generation_recovery")
            throw ContextTurnPreparationError.generationUnavailable
        }
        let lease = try arena.acquireSnapshot()
        do {
            let surfaceVariant = ContextSurfaceVariant(rawValue: request.surface.rawValue)
            let mirrorCandidates = lease.snapshot.requiredDocumentMirrors.filter {
                $0.kernel(for: surfaceVariant) != nil
            }
            let mirror = request.personaIDHint.flatMap { hint in
                mirrorCandidates.first { $0.personaID.rawValue == hint }
            } ?? (mirrorCandidates.count == 1 ? mirrorCandidates[0] : nil)
            guard let mirror, let kernel = mirror.kernel(for: surfaceVariant) else {
                throw ContextTurnPreparationError.kernelUnavailable(
                    surface: request.surface,
                    personaIDHint: request.personaIDHint
                )
            }

            // Slots change presentation; agent-named memory shares MemoryRecordDisclosurePolicy.
            let generationDerived = generationDerivedTurnState(
                generation: generation,
                request: request,
                mirror: mirror,
                kernel: kernel
            )
            // Diagnose slot-ID memory scopes, including slot/agent name collisions.
            // Emit once per turn, never per atom.
            if generationDerived.slotScopedMemorySourceCount > 0 {
                diagnostics(
                    "[context-flow] ERROR memory-scope vocabulary drift: "
                    + "\(generationDerived.slotScopedMemorySourceCount) live memory source(s) are scoped by "
                    + "persona SLOT id \"\(mirror.personaID.rawValue)\" (prefix "
                    + "\(generationDerived.memoryPersonaPrefix)). MemoryV2 record persona ids are AGENT NAMES; "
                    + "a slot-id-scoped record means the two vocabularies merged. Memory is "
                    + "deliberately shared across persona slots — re-review that decision "
                    + "before shipping a per-slot memory shard."
                )
            }
            let feedback = try feedbackSnapshot(for: generation)
            let feedbackByAtom = Dictionary(uniqueKeysWithValues: feedback.states.map {
                ($0.atomID, $0)
            })
            var activation = request.cognitiveActivation
            for state in feedback.states where state.temporaryActivation > 0 {
                activation[state.atomID] = max(
                    activation[state.atomID] ?? 0,
                    state.temporaryActivation
                )
            }
            let makeNeed: (Int) -> NeedSignal = { characterBudget in
                NeedSignal(
                    message: request.userMessage,
                    surface: request.surface,
                    origin: request.origin,
                    authorization: ContextSelectionAuthorization(
                        allowedOrigins: [request.origin],
                        allowedPrivacy: request.allowedPrivacy,
                        allowedSourceIDs: generationDerived.allowedSourceIDs,
                        permissionLabels: request.permissionLabels
                    ),
                    sessionID: request.sessionID,
                    recentTurns: request.recentTurns,
                    activeTask: request.activeTask,
                    unresolvedQuestion: request.unresolvedQuestion,
                    goal: request.goal,
                    predictedToolGroups: request.predictedToolGroups,
                    contextualTerms: request.contextualTerms,
                    cognitiveActivation: activation,
                    feedbackUtilityOverrides: feedbackByAtom.mapValues(\.utility),
                    feedbackDecayOverrides: feedbackByAtom.mapValues(\.decay),
                    memoryReachability: feedbackByAtom.mapValues(\.reachability),
                    servedTurnsAgo: self.servedTurnsAgo(sessionID: request.sessionID, recentTurns: request.recentTurns),
                    precoveredSourceIDs: generationDerived.precoveredSourceIDs,
                    mandatoryAtomIDs: Set(generation.atoms.lazy.filter {
                        generationDerived.protectedCorrectionAtomIDs.contains($0.draft.id)
                            && ContextCorrectionScope.applies(
                                $0.draft, message: request.userMessage, recentTurns: request.recentTurns
                            )
                    }.map(\.draft.id)),
                    // Her rejected atoms use the selector's exclusion set.
                    deletedAtomIDs: request.suppressedAtomIDs,
                    queryEmbedding: request.queryEmbedding?.values,
                    alternateQueryEmbedding: request.queryEmbedding?.alternateValues,
                    ownWordsQueryEmbeddings: request.queryEmbedding?.ownWordsValues,
                    queryEmbeddingModelFingerprint: request.queryEmbedding?.modelFingerprint,
                    queryEmbeddingModelID: request.queryEmbedding?.modelID,
                    availableGenerationID: generation.generation.id,
                    characterBudget: characterBudget,
                    packetAtomExpandThresholdChars: request.packetAtomExpandThresholdChars,
                    memoryAtomRowLimit: request.memoryAtomRowLimit,
                    cacheState: .hit
                )
            }
            var need = makeNeed(request.characterBudget)
            var budgetExpansion: ContextFlowBudgetExpansion?
            var packet: ContextPacket
            do {
                packet = try selector.select(
                    need,
                    from: generation,
                    pinnedTo: lease.snapshot
                )
            } catch ContextSelectionError.mandatoryBudgetExceeded(let required, _)
                where request.maximumCharacterBudget > request.characterBudget
            {
                let expandedBudget = min(
                    request.maximumCharacterBudget,
                    max(
                        request.characterBudget,
                        required + request.postMandatoryCharacterReserve
                    )
                )
                guard expandedBudget >= required else {
                    throw ContextSelectionError.mandatoryBudgetExceeded(
                        required: required,
                        limit: request.maximumCharacterBudget
                    )
                }
                need = makeNeed(expandedBudget)
                budgetExpansion = ContextFlowBudgetExpansion(
                    requestedCharacterBudget: request.characterBudget,
                    effectiveCharacterBudget: expandedBudget,
                    maximumCharacterBudget: request.maximumCharacterBudget,
                    mandatoryCharacterBudget: required,
                    grantedPostMandatoryReserve: max(0, expandedBudget - required)
                )
                packet = try selector.select(
                    need,
                    from: generation,
                    pinnedTo: lease.snapshot
                )
            }
            let verifier = Self.verifier(compiledProjectionProviders, generation: generation, surface: request.surface)
            packet = await Self.verified(packet, by: verifier, in: generation)
            let recordsFeedback = !Self.isTestSession(request.sessionID)
            let feedbackHandler: (@Sendable (
                ContextFeedbackSignal,
                [ContextAtomID],
                [String]
            ) async -> Void)?
            if recordsFeedback {
                feedbackHandler = { [weak self] signal, atomIDs, evidenceIDs in
                    await self?.recordFeedback(
                        signal: signal,
                        atomIDs: atomIDs,
                        evidenceIDs: evidenceIDs,
                        generationID: generation.generation.id,
                        sessionID: request.sessionID,
                        historyMessageFingerprint: ContextStableID.digest(parts: [request.userMessage])
                    )
                }
            } else {
                feedbackHandler = nil
            }
            let providers = compiledProjectionProviders
            let selectionReceiptID = packet.receipt.id
            let deliveryHandler: @Sendable ([ContextPacketItem]) async -> Void = { items in
                await feedbackHandler?(.selection, items.map(\.pointer.atomID), [selectionReceiptID])
                for provider in providers { await provider.didDeliver(items) }
            }
            return ContextPreparedTurn(
                mode: mode,
                kernel: kernel,
                mirror: mirror,
                packet: packet,
                lease: lease,
                generation: generation,
                need: need,
                budgetExpansion: budgetExpansion,
                deliveryHandler: deliveryHandler,
                feedbackHandler: feedbackHandler,
                verifier: verifier
            )
        } catch {
            lease.release()
            throw error
        }
    }

    /// Every projection checks exactly the atoms chosen against its owner.
    private static func verifier(
        _ providers: [any ContextCompiledProjectionProvider], generation: ContextStoredGeneration, surface: ContextSurface
    ) -> @Sendable ([ContextStoredAtom]) async -> ContextTurnExclusion {
        { chosen in
            var exclusion = ContextTurnExclusion()
            for provider in providers {
                let check = await provider.verify(chosen, in: generation, surface: surface)
                exclusion.atomIDs.formUnion(check.atomIDs)
                exclusion.unverified += check.unverified
            }
            return exclusion
        }
    }

    /// Excludes rejected items/pointers and adds verification notices. Selection
    /// receipt and budget stay unchanged; outcome feedback retains the original IDs.
    private static func verified(
        _ packet: ContextPacket, by verifier: @Sendable ([ContextStoredAtom]) async -> ContextTurnExclusion,
        in generation: ContextStoredGeneration
    ) async -> ContextPacket {
        let chosenIDs = Set(packet.selectedItems.map(\.pointer.atomID) + packet.expandablePointers.map(\.atomID))
        let check = await verifier(generation.atoms.filter { chosenIDs.contains($0.draft.id) })
        guard !check.atomIDs.isEmpty || !check.unverified.isEmpty else { return packet }
        return ContextPacket(
            generationID: packet.generationID, sourceFingerprint: packet.sourceFingerprint,
            selectedItems: packet.selectedItems.filter { !check.atomIDs.contains($0.pointer.atomID) },
            expandablePointers: packet.expandablePointers.filter { !check.atomIDs.contains($0.atomID) },
            conflictSets: packet.conflictSets, degradedSources: packet.degradedSources + check.unverified,
            budget: packet.budget, receipt: packet.receipt)
    }

    private static func generatedUserFacts(in text: String) -> Set<MemoryDisplayText.Key>? {
        let preambleStart = UserMDAutogenMarkers.preambleStart
        let preambleEnd = UserMDAutogenMarkers.preambleEnd
        let bodyStart = UserMDAutogenMarkers.bodyStart
        let bodyEnd = UserMDAutogenMarkers.bodyEnd
        guard !text.contains(preambleStart),
              !text.contains(preambleEnd),
              let start = text.range(of: bodyStart),
              let end = text.range(of: bodyEnd, range: start.upperBound..<text.endIndex),
              text[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var facts = Set<MemoryDisplayText.Key>()
        for rawLine in text[start.upperBound..<end.lowerBound].split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.hasPrefix("- ") else { return nil }
            // Use the same join key as the canonical memory atom body.
            let fact = MemoryDisplayText.projectionJoinKey(String(line.dropFirst(2)))
            guard !fact.isEmpty else { return nil }
            facts.insert(fact)
        }
        return facts
    }

}
