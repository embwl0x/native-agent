import Foundation
import NativeAgentCore

// MARK: - Deterministic hybrid selector

public struct ContextSelector: Sendable {
    public let configuration: ContextSelectionConfiguration

    public init(configuration: ContextSelectionConfiguration = .init()) {
        self.configuration = configuration
    }

    public func select(
        _ need: NeedSignal,
        from generation: ContextStoredGeneration,
        pinnedTo snapshot: ContextGenerationSnapshot? = nil,
        measureLatency: Bool = false
    ) throws -> ContextPacket {
        let selectionStarted = measureLatency ? DispatchTime.now().uptimeNanoseconds : nil
        guard need.characterBudget > 0 else { throw ContextSelectionError.invalidCharacterBudget }
        if let requested = need.availableGenerationID, requested != generation.generation.id {
            throw ContextSelectionError.requestedGenerationMismatch(
                requested: requested,
                actual: generation.generation.id
            )
        }
        if let snapshot {
            guard snapshot.generationID == generation.generation.id else {
                throw ContextSelectionError.snapshotGenerationMismatch(
                    snapshot: snapshot.generationID,
                    generation: generation.generation.id
                )
            }
            guard snapshot.sourceFingerprint == generation.generation.sourceFingerprint else {
                throw ContextSelectionError.snapshotFingerprintMismatch
            }
        }

        let groups = try conflictGroups(for: need, generation: generation)
        let resolutionLosers: [ContextAtomID: ContextEligibilityReason] = Dictionary(
            uniqueKeysWithValues: groups.flatMap { group -> [(ContextAtomID, ContextEligibilityReason)] in
            guard let resolved = group.resolvedAtomID else { return [] }
            return group.memberAtomIDs.filter { $0 != resolved }.map {
                ($0, ContextEligibilityReason.supersededByConflictResolution)
            }
        })
        let sourceByID = Dictionary(uniqueKeysWithValues: generation.sources.map {
            ($0.descriptor.id, $0)
        })
        let sortedAtoms = generation.atoms.sorted { $0.draft.id < $1.draft.id }
        let atomByID = Dictionary(uniqueKeysWithValues: sortedAtoms.map { ($0.draft.id, $0) })

        var decisions: [ContextEligibilityDecision] = []
        var eligible: [ContextStoredAtom] = []
        for atom in sortedAtoms {
            let reason = eligibilityReason(
                for: atom,
                generationID: generation.generation.id,
                source: sourceByID[atom.draft.sourceID],
                need: need,
                resolutionReason: resolutionLosers[atom.draft.id]
            )
            decisions.append(ContextEligibilityDecision(
                atomID: atom.draft.id,
                eligible: reason == nil,
                exclusionReason: reason
            ))
            if reason == nil { eligible.append(atom) }
        }

        var mandatoryIDs = need.mandatoryAtomIDs
        // An `always` atom is mandatory inside the request's authorized
        // source scope, not across every persona/surface represented by the
        // shared generation.  A chat picker rebuild can deliberately retain
        // another surface's identity mirror in that generation; demanding
        // those excluded atoms would turn the authorization boundary itself
        // into a false `mandatoryUnavailable` failure.
        mandatoryIDs.formUnion(eligible.lazy.filter {
            $0.draft.injectionPolicy == .always
                && !need.precoveredSourceIDs.contains($0.draft.sourceID)
        }.map(\.draft.id))
        for group in groups where group.resolvedAtomID == nil
            && !mandatoryIDs.isDisjoint(with: group.memberAtomIDs) {
            mandatoryIDs.formUnion(group.memberAtomIDs.filter {
                atomByID[$0]?.draft.injectionPolicy != .onDemand
            })
        }

        let eligibleIDs = Set(eligible.map(\.draft.id))
        let unavailableMandatory = mandatoryIDs.subtracting(eligibleIDs).sorted()
        guard unavailableMandatory.isEmpty else {
            throw ContextSelectionError.mandatoryUnavailable(unavailableMandatory)
        }

        let groupByAtom = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.memberAtomIDs.map { ($0, group.id) }
        })
        // Precovered sources are already present in the stable prompt. Keep
        // their eligibility receipts, but do not spend per-turn ranking work
        // on atoms that cannot become dynamic candidates. Explicit mandatory
        // atoms remain scorable for complete receipts.
        let scorable = eligible.filter {
            !need.precoveredSourceIDs.contains($0.draft.sourceID)
                || mandatoryIDs.contains($0.draft.id)
        }
        let lexicalIndex = Dictionary(uniqueKeysWithValues: scorable.map { atom in
            (
                atom.draft.id,
                snapshot?.selectionIndex[atom.draft.id]
                    ?? ContextSelectionIndexEntry(atom: atom.draft)
            )
        })
        let scoreContext = makeScoreContext(need, lexicalIndex: lexicalIndex)
        var scores: [ContextAtomID: ContextCandidateScoreFeatures] = [:]
        for atom in scorable {
            scores[atom.draft.id] = score(
                atom,
                need: need,
                context: scoreContext,
                lexicalEntry: lexicalIndex[atom.draft.id]
                    ?? ContextSelectionIndexEntry(atom: atom.draft),
                hasUnresolvedConflict: groupByAtom[atom.draft.id] != nil
                    && groups.first(where: { $0.id == groupByAtom[atom.draft.id] })?.resolvedAtomID == nil
            )
        }
        let baseScores = scores

        var selectedItems: [ContextPacketItem] = []
        var selectedIDs = Set<ContextAtomID>()
        var selectionOrdinals: [ContextAtomID: Int] = [:]
        let mandatoryAtoms = mandatoryIDs.compactMap { atomByID[$0] }.sorted(by: mandatoryOrder)
        let mandatoryCharacters = mandatoryAtoms.reduce(0) { $0 + $1.draft.body.count }
        let mandatoryLimit = min(need.characterBudget, need.mandatoryCharacterBudget)
        guard mandatoryCharacters <= mandatoryLimit else {
            throw ContextSelectionError.mandatoryBudgetExceeded(
                required: mandatoryCharacters,
                limit: mandatoryLimit
            )
        }
        for atom in mandatoryAtoms {
            selectedItems.append(ContextPacketItem(
                atom: atom,
                generationID: generation.generation.id,
                text: atom.draft.body,
                representation: .body,
                mandatory: true
            ))
            selectedIDs.insert(atom.draft.id)
            selectionOrdinals[atom.draft.id] = selectedItems.count
        }

        let rankedCandidates = eligible
            .filter { !mandatoryIDs.contains($0.draft.id) }
            .filter { !need.precoveredSourceIDs.contains($0.draft.sourceID) }
            .filter { relevance(of: scores[$0.draft.id]) >= configuration.minimumRelevance }
            .sorted { rankedBefore($0, $1, scores: scores) }
        let boundedCandidates = Array(rankedCandidates.prefix(configuration.maximumCandidates))
        let candidateIDs = Set(boundedCandidates.map(\.draft.id))

        // MEMORY SEMANTIC FLOOR (see `memorySemanticFloor`). Ranking alone has
        // no notion of "not relevant enough to be worth a row": a saturated
        // memory quota is filled by whatever ranks next, however far down the
        // cosine has fallen. This refuses ADMISSION rather than candidacy, so
        // floored atoms keep their eligibility and score receipts and remain
        // reachable through the pointer lanes — only their free ride into every
        // packet is gone.
        let floor = configuration.memorySemanticFloor
        let queryIsComparable = !(need.queryEmbedding?.isEmpty ?? true)
            && need.queryEmbeddingModelFingerprint != nil
        let flooredMemoryIDs: Set<ContextAtomID> = floor > 0 && queryIsComparable
            ? Set(boundedCandidates.lazy.filter { atom in
                guard atom.draft.kind == .memory,
                      let embedding = atom.draft.embedding,
                      embedding.modelFingerprint == need.queryEmbeddingModelFingerprint,
                      let features = baseScores[atom.draft.id],
                      features.semanticCosine < floor else { return false }
                return features.lexicalExact < 1
                    && features.sharedIdentifiers <= 0
                    && features.messageCoverage < 0.5
                    && features.activation < 0.5
            }.map(\.draft.id))
            : []

        // SHORT-MESSAGE ROW CAP. "Hey" is not a request for eight memories.
        // Below the coverage damp's own threshold the message cannot evidence
        // what it is about, so the memory lane narrows instead of filling.
        //
        // `memorySemanticFloor == 0` turns the WHOLE 2026-09-02 precision pass
        // off, this cap included: one switch, one claim, byte-identical to the
        // pre-floor selector. The cap also has its own off value (0).
        let effectiveMemoryRowLimit: Int? = {
            guard floor > 0, configuration.shortMessageMemoryRowCap > 0,
                  scoreContext.messageTokens.count
                    <= ContextSelectionConfiguration.shortMessageTokenCount else {
                return need.memoryAtomRowLimit
            }
            let short = configuration.shortMessageMemoryRowCap
            return min(need.memoryAtomRowLimit ?? short, short)
        }()

        // Admission, not candidacy: `candidateIDs` (score receipts, conflict
        // receipts) keeps every ranked atom, while unit construction sees only
        // what may actually enter the packet. Feeding the broader set to
        // `makeSelectionUnits` let a floored atom ride back in as a member of
        // an unresolved conflict unit, which bypasses the quotas by design.
        // Conflict completeness holds among ADMITTED atoms; a sub-floor memory
        // row is not evidence of a contradiction worth spending a row on.
        let admittedCandidates = boundedCandidates.filter {
            !flooredMemoryIDs.contains($0.draft.id)
        }
        var units = makeSelectionUnits(
            candidates: admittedCandidates.filter { $0.draft.injectionPolicy != .onDemand },
            groups: groups,
            atomByID: atomByID,
            candidateIDs: Set(admittedCandidates.map(\.draft.id)),
            mandatoryIDs: mandatoryIDs
        )
        var selectedDynamicCount = 0
        var usedCharacters = mandatoryCharacters
        var sourceCounts: [ContextSourceID: Int] = [:]
        var kindCounts: [ContextAtomKind: Int] = [:]
        let reservedPlan = reservedRolePlan(in: units, scores: baseScores)
        let reservedSlots = reservedPlan.slots
        var reservedRoleCounts: [ContextAtomKind: Int] = [:]
        // Corrections admitted this turn that the message is NOT about, and
        // the ones the cap turned away. Exempt corrections (this message is
        // about them) never consume the cap and never appear in the drop
        // count — the cap exists to stop ambient self-reproach, not to make a
        // relevant correction unreachable.
        var cappedCorrectionCount = 0
        var correctionCapDropped = 0
        var omittedConflictIDs = Set<String>()
        let selectedTokenSets = selectedItems.map { Self.tokens($0.text) }
        var redundancyByAtom = Dictionary(uniqueKeysWithValues: boundedCandidates.map { atom in
            (
                atom.draft.id,
                maximumTokenSimilarity(
                    lexicalIndex[atom.draft.id]?.bodyTokens ?? [],
                    selectedTokenSets
                )
            )
        })

        while !units.isEmpty && selectedDynamicCount < configuration.maximumDynamicAtoms {
            var reranked: [(unit: SelectionUnit, value: Double)] = []
            for unit in units {
                var total = 0.0
                for atom in unit.atoms {
                    guard let original = baseScores[atom.draft.id] else { continue }
                    let redundancy = redundancyByAtom[atom.draft.id] ?? 0
                    let diversity = diversityBonus(
                        for: atom,
                        sourceCounts: sourceCounts,
                        kindCounts: kindCounts
                    )
                    let value = original.total + diversity
                        - (configuration.weights.redundancyPenalty * redundancy)
                    scores[atom.draft.id] = original.reranked(
                        diversityBonus: diversity,
                        redundancyPenalty: redundancy,
                        total: value
                    )
                    total += value
                }
                reranked.append((unit, total / Double(max(1, unit.atoms.count))))
            }
            reranked.sort {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.unit.stableKey < $1.unit.stableKey
            }
            let remainingAtomSlots = configuration.maximumDynamicAtoms - selectedDynamicCount
            var examinedKeys = Set<String>()
            var selectedPlan: [ContextPacketItem]?
            // The floor, made real. Capping other roles only frees slots; it
            // does not hand them to the reserved role, because the ranked scan
            // below runs out of dynamic budget long before it reaches a
            // qualifying atom that scores 30-50 places down. While a kind's
            // reserve is outstanding, its best qualifying unit is considered
            // FIRST. The gate in `reservedRolePlan` is what keeps this a floor
            // for the skill this message is about rather than a free ride for
            // any pointer that cleared the global relevance threshold.
            let outstandingReserve = reservedSlots.contains { kind, slots in
                reservedRoleCounts[kind, default: 0] < slots
            }
            if outstandingReserve {
                for candidate in reranked
                where reservedPlan.qualifyingKeys.contains(candidate.unit.stableKey) {
                    let unit = candidate.unit
                    guard unit.atoms.contains(where: { atom in
                        guard let slots = reservedSlots[atom.draft.kind] else { return false }
                        return reservedRoleCounts[atom.draft.kind, default: 0] < slots
                    }) else { continue }
                    guard unit.atoms.count <= remainingAtomSlots,
                          correctionCapAllows(
                            unit,
                            admittedCorrections: cappedCorrectionCount,
                            scores: baseScores
                          ),
                          quotaAllows(
                            unit,
                            sourceCounts: sourceCounts,
                            kindCounts: kindCounts,
                            reservedSlots: reservedSlots,
                            reservedRoleCounts: reservedRoleCounts,
                            memoryAtomRowLimit: effectiveMemoryRowLimit
                          ),
                          let planned = plannedItems(
                            for: unit,
                            generationID: generation.generation.id,
                            remainingCharacters: need.characterBudget - usedCharacters
                          ) else { continue }
                    examinedKeys.insert(unit.stableKey)
                    selectedPlan = planned
                    break
                }
            }
            // Rejecting a unit changes no diversity, redundancy, quota, or
            // budget input. Its successors therefore keep this exact scored
            // order until an actual selection lands. Re-sorting after each
            // full-quota/oversized candidate made a saturated memory lane
            // quadratic while producing the same scores and receipts.
            for candidate in reranked where selectedPlan == nil {
                let unit = candidate.unit
                examinedKeys.insert(unit.stableKey)
                // Counted separately from the ordinary quota so the receipt can
                // say how much of her correction backlog this rule held back.
                // A unit is examined at most once per selection pass (rejects
                // are removed with `examinedKeys`), so this cannot double-count.
                if !correctionCapAllows(
                    unit,
                    admittedCorrections: cappedCorrectionCount,
                    scores: baseScores
                ) {
                    correctionCapDropped += unit.atoms
                        .filter { $0.draft.kind == .correction }.count
                    if let conflictID = unit.conflictID { omittedConflictIDs.insert(conflictID) }
                    continue
                }
                guard unit.atoms.count <= remainingAtomSlots,
                      quotaAllows(
                        unit,
                        sourceCounts: sourceCounts,
                        kindCounts: kindCounts,
                        reservedSlots: reservedSlots,
                        reservedRoleCounts: reservedRoleCounts,
                        memoryAtomRowLimit: effectiveMemoryRowLimit
                      ),
                      let planned = plannedItems(
                    for: unit,
                    generationID: generation.generation.id,
                    remainingCharacters: need.characterBudget - usedCharacters
                      ) else {
                    if let conflictID = unit.conflictID { omittedConflictIDs.insert(conflictID) }
                    continue
                }
                selectedPlan = planned
                break
            }
            units.removeAll { examinedKeys.contains($0.stableKey) }
            guard let planned = selectedPlan else { break }

            for item in planned {
                selectedItems.append(item)
                selectedIDs.insert(item.pointer.atomID)
                selectedDynamicCount += 1
                usedCharacters += item.characterCount
                selectionOrdinals[item.pointer.atomID] = selectedItems.count
                sourceCounts[item.pointer.sourceID, default: 0] += 1
                kindCounts[item.pointer.kind, default: 0] += 1
                if item.pointer.kind == .correction,
                   !Self.correctionIsAboutMessage(baseScores[item.pointer.atomID]) {
                    cappedCorrectionCount += 1
                }
                if let reservation = configuration.reservedRoleSlotsPerKind[item.pointer.kind],
                   atomByID[item.pointer.atomID]?.draft.contentRole == reservation.role {
                    reservedRoleCounts[item.pointer.kind, default: 0] += 1
                }
                let selectedTokens = Self.tokens(item.text)
                for remainingUnit in units {
                    for remainingAtom in remainingUnit.atoms {
                        let atomID = remainingAtom.draft.id
                        let similarity = Self.jaccard(
                            lexicalIndex[atomID]?.bodyTokens ?? [],
                            selectedTokens
                        )
                        redundancyByAtom[atomID] = max(
                            redundancyByAtom[atomID] ?? 0,
                            similarity
                        )
                    }
                }
            }
        }

        let onDemandPointers = boundedCandidates
            .filter { $0.draft.injectionPolicy == .onDemand }
            .sorted { rankedBefore($0, $1, scores: scores) }
            .prefix(configuration.maximumPointers)
            .map { ContextAtomPointer(atom: $0, generationID: generation.generation.id) }
        // TRUNCATION POINTERS (NORTHSTAR clause 6). When the caller's renderer
        // cuts a long atom down to a lead, the rest of that atom must stay
        // REACHABLE — otherwise the lead is not "fingertips", it is loss. The
        // selector is the only place that knows which items were selected, so
        // it publishes one expandable pointer per item the renderer will
        // truncate. `ContextExpander` admits exactly these (same threshold,
        // same NeedSignal) despite their non-`.onDemand` injection policy.
        //
        // THE NEW BOUND: the on-demand lane keeps `configuration
        // .maximumPointers` unchanged; this lane adds AT MOST one pointer per
        // selected item, and `selectedItems` is itself bounded by the mandatory
        // set plus `configuration.maximumDynamicAtoms`. So
        //   expandablePointers.count
        //     <= maximumPointers + mandatoryAtomIDs.count + maximumDynamicAtoms
        // and it is still a bounded packet, not a search bypass.
        var pointers = onDemandPointers
        if need.packetAtomExpandThresholdChars > 0 {
            var published = Set(pointers.map(\.atomID))
            for item in selectedItems
            where item.text.count > need.packetAtomExpandThresholdChars {
                guard published.insert(item.pointer.atomID).inserted else { continue }
                pointers.append(item.pointer)
            }
        }

        let conflicts = groups.map { group in
            conflictSet(
                group,
                generationID: generation.generation.id,
                atomByID: atomByID,
                eligibleIDs: eligibleIDs,
                candidateIDs: candidateIDs,
                selectedIDs: selectedIDs,
                omittedConflictIDs: omittedConflictIDs
            )
        }.sorted { $0.id < $1.id }
        let degraded = generation.sources.filter { $0.health == .degraded }.map {
            ContextDegradedSourceNotice(
                sourceID: $0.descriptor.id,
                reason: "last known good source retained"
            )
        }.sorted { $0.sourceID < $1.sourceID }
        let budget = ContextBudgetUsage(
            characterLimit: need.characterBudget,
            usedCharacters: usedCharacters,
            mandatoryCharacters: mandatoryCharacters
        )
        let selectedIDList = selectedItems.map(\.pointer.atomID)
        let pointerIDList = pointers.map(\.atomID)
        let mandatoryIDList = mandatoryIDs.sorted()
        let coveredMandatory = mandatoryIDList.filter { selectedIDs.contains($0) }
        let scoreReceiptIDs = mandatoryIDs.union(candidateIDs)
        let scoreReceipts = scores.compactMap { atomID, features -> ContextCandidateScore? in
            guard scoreReceiptIDs.contains(atomID) else { return nil }
            return ContextCandidateScore(
                atomID: atomID,
                features: features,
                selectionOrdinal: selectionOrdinals[atomID]
            )
        }.sorted { $0.atomID < $1.atomID }
        let receiptID = ContextStableID.digest(parts: [
            need.deterministicFingerprint,
            String(generation.generation.id),
            generation.generation.sourceFingerprint,
        ] + selectedIDList.map(\.rawValue) + pointerIDList.map(\.rawValue))
        let latency: (microseconds: Int?, provenance: ContextSelectionLatencyProvenance) = {
            if let selectionStarted {
                return (
                    Int((DispatchTime.now().uptimeNanoseconds &- selectionStarted) / 1_000),
                    .monotonicClock
                )
            }
            if let supplied = need.measuredSelectionMicroseconds {
                return supplied >= 0
                    ? (supplied, .callerSupplied)
                    : (nil, .invalidCallerSupplied)
            }
            return (nil, .unavailable)
        }()
        let receipt = ContextSelectionReceipt(
            id: receiptID,
            needFingerprint: need.deterministicFingerprint,
            generationID: generation.generation.id,
            sourceFingerprint: generation.generation.sourceFingerprint,
            selectionTimeBucket: need.selectionTimeBucket,
            eligibility: decisions,
            candidateScores: scoreReceipts,
            selectedAtomIDs: selectedIDList,
            pointerAtomIDs: pointerIDList,
            mandatoryAtomIDs: mandatoryIDList,
            coveredMandatoryAtomIDs: coveredMandatory,
            mandatoryCoverage: mandatoryIDList.isEmpty
                ? 1
                : Double(coveredMandatory.count) / Double(mandatoryIDList.count),
            conflicts: conflicts,
            budget: budget,
            degradedSources: degraded,
            cacheState: need.cacheState,
            measuredSelectionMicroseconds: latency.microseconds,
            selectionLatencyProvenance: latency.provenance,
            memoryFloorDroppedCount: flooredMemoryIDs.count,
            correctionCapDropped: correctionCapDropped
        )

        return ContextPacket(
            generationID: generation.generation.id,
            sourceFingerprint: generation.generation.sourceFingerprint,
            selectedItems: selectedItems,
            expandablePointers: Array(pointers),
            conflictSets: conflicts,
            degradedSources: degraded,
            budget: budget,
            receipt: receipt
        )
    }
}

// MARK: - Selection internals

private extension ContextSelector {
    struct ScoreContext {
        let queryTokens: Set<String>
        let normalizedMessage: String?
        let identifiers: Set<String>
        let contextualTokens: Set<String>
        /// Tokens of the CURRENT user message alone (post-4f4b9445 this is the
        /// raw message, no wire riders) — the `messageCoverage` feature's
        /// denominator. Distinct from `queryTokens`, which folds in carried
        /// context (recent turns, attention terms, tool groups) and therefore
        /// dilutes any single source.
        let messageTokens: Set<String>
        let tokenSpecificity: [String: Double]

        func matchedWeight(_ tokens: Set<String>, in document: Set<String>) -> Double {
            tokens.intersection(document).sorted().reduce(0) {
                $0 + (tokenSpecificity[$1] ?? 1)
            }
        }
    }

    struct ConflictGroup {
        let id: String
        let memberAtomIDs: Set<ContextAtomID>
        let resolvedAtomID: ContextAtomID?
        let provenance: [String]
    }

    struct SelectionUnit {
        let stableKey: String
        let conflictID: String?
        let atoms: [ContextStoredAtom]
    }

    func eligibilityReason(
        for atom: ContextStoredAtom,
        generationID: Int64,
        source: ContextStoredSource?,
        need: NeedSignal,
        resolutionReason: ContextEligibilityReason?
    ) -> ContextEligibilityReason? {
        guard let source else { return .missingSource }
        guard atom.validFromGeneration <= generationID,
              atom.validToGeneration.map({ $0 >= generationID }) ?? true,
              source.validFromGeneration <= generationID,
              source.validToGeneration.map({ $0 >= generationID }) ?? true else {
            return .generationMismatch
        }
        if need.deletedAtomIDs.contains(atom.draft.id) { return .deleted }
        if !ContextCorrectionScope.applies(atom.draft, message: need.message, recentTurns: need.recentTurns) {
            return .outsideContextScope
        }
        if need.tombstonedAtomIDs.contains(atom.draft.id) { return .tombstoned }
        if source.health == .removed { return .sourceRemoved }
        if !need.authorization.allowedOrigins.contains(need.origin) { return .originDenied }
        if !need.authorization.allowedSourceIDs.contains(atom.draft.sourceID) {
            return .permissionDenied
        }
        if let allowedAtoms = need.authorization.allowedAtomIDs,
           !allowedAtoms.contains(atom.draft.id) {
            return .permissionDenied
        }
        if !atom.draft.permittedSurfaces.contains(need.surface)
            || !source.descriptor.permittedSurfaces.contains(need.surface) {
            return .surfaceDenied
        }
        if !need.authorization.allowedPrivacy.contains(atom.draft.privacy)
            || !need.authorization.allowedPrivacy.contains(source.descriptor.privacy) {
            return .privacyDenied
        }
        if atom.draft.injectionPolicy == .neverInject
            || source.descriptor.injectionPolicy == .neverInject {
            return .neverInject
        }
        if atom.draft.freshness.isExpired(at: need.evaluationTime) { return .expired }
        if need.staleRuntimeAtomIDs.contains(atom.draft.id) { return .staleRuntime }
        if need.secretBearingAtomIDs.contains(atom.draft.id) { return .secretBearing }
        if let resolutionReason { return resolutionReason }
        return nil
    }

    func score(
        _ atom: ContextStoredAtom,
        need: NeedSignal,
        context: ScoreContext,
        lexicalEntry: ContextSelectionIndexEntry,
        hasUnresolvedConflict: Bool
    ) -> ContextCandidateScoreFeatures {
        let exact = context.normalizedMessage.map {
            lexicalEntry.normalizedSearchableText.contains($0) ? 1.0 : 0.0
        } ?? 0
        let matchedWeight = context.matchedWeight(context.queryTokens, in: lexicalEntry.searchableTokens)
        let overlap = context.queryTokens.isEmpty ? 0 : (
            matchedWeight / Double(context.queryTokens.count)
                + matchedWeight / Double(max(1, context.queryTokens.union(lexicalEntry.searchableTokens).count))
        ) / 2
        let semantic: Double = {
            guard let queryFingerprint = need.queryEmbeddingModelFingerprint,
                  let atomEmbedding = atom.draft.embedding,
                  queryFingerprint == atomEmbedding.modelFingerprint else { return 0 }
            // User, 2026-09-06: the better of the question's two voices, the way
            // the legacy recall lane keeps the better of a row's two scores.
            // The packet lane scored the raw question only, so an atom written
            // in the third person ("User uses different names for Agent…") was
            // nowhere near a question asked in the first ("what does User call
            // me") and never reached the packet. `alternateQueryEmbedding` is
            // nil when the question reads the same in both voices, and cosine
            // against nil is 0, so this is the old value in that case.
            return max(
                Self.cosine(need.queryEmbedding, atomEmbedding.values),
                Self.cosine(need.alternateQueryEmbedding, atomEmbedding.values)
            )
        }()
        let shared = sharedIdentifierScore(atom.draft, context: context)
        let activation = max(
            atom.draft.activation,
            need.cognitiveActivation[atom.draft.id] ?? 0,
            need.workingAtomIDs.contains(atom.draft.id) ? 1 : 0
        )
        let authority = Double(atom.draft.authority.rank) / 6.0
        let confidence = atom.draft.confidence
        let ageDays = max(
            0,
            need.evaluationTime.timeIntervalSince(atom.draft.freshness.updatedAt) / 86_400
        )
        let recency = 1 / (1 + (ageDays / 30))
        let usefulness = need.feedbackUtilityOverrides[atom.draft.id]
            ?? atom.draft.recentUsefulness
        let decay = need.feedbackDecayOverrides[atom.draft.id]
            ?? atom.draft.decayState
        let w = configuration.weights
        let conflictPenalty = hasUnresolvedConflict ? w.conflictPenalty : 0
        let costRatio = Double(atom.draft.body.count) / Double(max(1, need.characterBudget))
        let costPenalty = min(w.characterCostPenaltyCap, costRatio * w.characterCostPenaltyCap)
        // How much of the CURRENT message's own vocabulary this atom covers.
        // Unlike tokenOverlap (denominator = the full carried-context query),
        // this feature cannot be diluted by recent turns or attention terms —
        // it is the one signal that tracks what the user just said.
        //
        // Short-message damp: on a 1-3 token message coverage is quantized so
        // coarsely (one shared token = 0.33-1.0) that it can out-vote the
        // semantic feature on paraphrase queries — the exact regression the
        // semanticQueryRecoversAParaphrase pin caught at weight 1.5. Scale by
        // min(1, tokens/4) so tiny queries lean on semantics/overlap while
        // 4+-token messages get the full evidenced weight.
        let messageCoverage: Double = {
            guard !context.messageTokens.isEmpty else { return 0 }
            let hit = context.matchedWeight(context.messageTokens, in: lexicalEntry.searchableTokens)
            let raw = hit / Double(context.messageTokens.count)
            let lengthDamp = min(1.0, Double(context.messageTokens.count) / 4.0)
            return raw * lengthDamp
        }()
        let total = (w.lexicalExact * exact)
            + (w.tokenOverlap * overlap)
            + (w.semanticCosine * semantic)
            + (w.sharedIdentifiers * shared)
            + (w.activation * activation)
            + (w.authority * authority)
            + (w.confidence * confidence)
            + (w.recency * recency)
            + (w.usefulness * usefulness)
            + (w.decay * decay)
            + (w.messageCoverage * messageCoverage)
            - conflictPenalty
            - costPenalty
        return ContextCandidateScoreFeatures(
            lexicalExact: exact,
            tokenOverlap: overlap,
            semanticCosine: semantic,
            sharedIdentifiers: shared,
            activation: activation,
            authority: authority,
            confidence: confidence,
            recency: recency,
            usefulness: usefulness,
            decay: decay,
            messageCoverage: messageCoverage,
            diversityBonus: 0,
            redundancyPenalty: 0,
            conflictPenalty: conflictPenalty,
            characterCostPenalty: costPenalty,
            total: total
        )
    }

    func queryText(_ need: NeedSignal) -> String {
        // Match the existing semantic-recall and correction-scope contract:
        // prior conversation helps resolve a referential follow-up, but is
        // not fresh topic evidence after a self-contained user request.
        // Otherwise old work can clear minimumRelevance on lexical overlap
        // alone even when the current message has changed subjects.
        let recentTurns = ContextCorrectionScope.isReferentialFollowup(need.message)
            ? need.recentTurns.suffix(2).map { String($0.prefix(600)) }
            : []
        return ([
            need.message,
            need.activeTask,
            need.unresolvedQuestion,
            need.goal,
            need.currentProjectID,
            need.sessionID,
            need.executionID,
        ].compactMap { $0 }
            + recentTurns
            + need.contextualTerms.sorted()
            + need.predictedToolGroups.sorted()
            + need.extractedEntities.flatMap { [$0.id, $0.label] })
            .joined(separator: " ")
    }

    func makeScoreContext(
        _ need: NeedSignal,
        lexicalIndex: [ContextAtomID: ContextSelectionIndexEntry]
    ) -> ScoreContext {
        let contextualIDs = [need.currentProjectID, need.sessionID, need.executionID]
            .compactMap { $0 }
        var identifiers = Set(need.extractedEntities.map {
            "\($0.kind.lowercased()):\($0.id.lowercased())"
        })
        identifiers.formUnion(contextualIDs.map { "id:\($0.lowercased())" })
        let trimmedMessage = need.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTokens = Self.tokens(queryText(need))
        // Smoothed, normalized inverse document frequency: ubiquitous names
        // and boilerplate are weak relevance evidence, not multiple strong
        // votes against a semantic paraphrase. Only eligible/scorable atoms
        // participate, so inaccessible sources cannot influence ranking.
        // Uses the resident lexical index; no tokenization, I/O or model call.
        let documentCount = Double(lexicalIndex.count)
        let normalization = 1 + log(documentCount + 1)
        let specificity = Dictionary(uniqueKeysWithValues: queryTokens.map { token in
            let frequency = lexicalIndex.values.reduce(0) {
                $0 + ($1.searchableTokens.contains(token) ? 1 : 0)
            }
            return (token, (1 + log((documentCount + 1) / Double(frequency + 1))) / normalization)
        })
        return ScoreContext(
            queryTokens: queryTokens,
            normalizedMessage: trimmedMessage.isEmpty ? nil : need.message.lowercased(),
            identifiers: identifiers,
            contextualTokens: Set(contextualIDs.flatMap { Self.tokens($0) }),
            messageTokens: Self.tokens(need.message),
            tokenSpecificity: specificity
        )
    }

    func sharedIdentifierScore(_ atom: ContextAtomDraft, context: ScoreContext) -> Double {
        let atomIdentifiers = Set(atom.entities.flatMap { entity in
            [
                "\(entity.kind.lowercased()):\(entity.id.lowercased())",
                "id:\(entity.id.lowercased())",
            ]
        })
        if !context.identifiers.isDisjoint(with: atomIdentifiers) { return 1 }
        let labels = Set(atom.entities.flatMap { Self.tokens($0.label) })
        return labels.isDisjoint(with: context.contextualTokens) ? 0 : 0.5
    }

    func relevance(of score: ContextCandidateScoreFeatures?) -> Double {
        guard let score else { return 0 }
        // messageCoverage enters WEIGHTED (unlike the historical unweighted
        // terms) so a zero weight reproduces the pre-seam threshold pass-set
        // exactly; with the shipped 1.5 default it widens the pass-set only
        // for atoms that speak the current message's vocabulary.
        return score.lexicalExact + score.tokenOverlap + score.semanticCosine
            + score.sharedIdentifiers + score.activation
            + (configuration.weights.messageCoverage * score.messageCoverage)
    }

    func rankedBefore(
        _ lhs: ContextStoredAtom,
        _ rhs: ContextStoredAtom,
        scores: [ContextAtomID: ContextCandidateScoreFeatures]
    ) -> Bool {
        let left = scores[lhs.draft.id]?.total ?? -.infinity
        let right = scores[rhs.draft.id]?.total ?? -.infinity
        if left != right { return left > right }
        return lhs.draft.id < rhs.draft.id
    }

    func mandatoryOrder(_ lhs: ContextStoredAtom, _ rhs: ContextStoredAtom) -> Bool {
        let left = mandatoryKindRank(lhs.draft.kind)
        let right = mandatoryKindRank(rhs.draft.kind)
        if left != right { return left < right }
        return lhs.draft.id < rhs.draft.id
    }

    func mandatoryKindRank(_ kind: ContextAtomKind) -> Int {
        switch kind {
        case .identity: 0
        case .relationship: 1
        case .correction: 2
        case .runtimeTruth: 3
        default: 4
        }
    }

    func makeSelectionUnits(
        candidates: [ContextStoredAtom],
        groups: [ConflictGroup],
        atomByID: [ContextAtomID: ContextStoredAtom],
        candidateIDs: Set<ContextAtomID>,
        mandatoryIDs: Set<ContextAtomID>
    ) -> [SelectionUnit] {
        var consumed = Set<ContextAtomID>()
        var result: [SelectionUnit] = []
        for group in groups where group.resolvedAtomID == nil {
            let ids = group.memberAtomIDs
                .intersection(candidateIDs)
                .subtracting(mandatoryIDs)
            guard ids.count == group.memberAtomIDs.subtracting(mandatoryIDs).count,
                  ids.count > 1 else { continue }
            let atoms = ids.compactMap { atomByID[$0] }.sorted { $0.draft.id < $1.draft.id }
            guard atoms.allSatisfy({ $0.draft.injectionPolicy != .onDemand }) else { continue }
            result.append(SelectionUnit(stableKey: "conflict:\(group.id)", conflictID: group.id, atoms: atoms))
            consumed.formUnion(ids)
        }
        for atom in candidates where !consumed.contains(atom.draft.id) {
            result.append(SelectionUnit(
                stableKey: "atom:\(atom.draft.id.rawValue)",
                conflictID: nil,
                atoms: [atom]
            ))
        }
        return result
    }

    func quotaAllows(
        _ unit: SelectionUnit,
        sourceCounts: [ContextSourceID: Int],
        kindCounts: [ContextAtomKind: Int],
        reservedSlots: [ContextAtomKind: Int],
        reservedRoleCounts: [ContextAtomKind: Int],
        memoryAtomRowLimit: Int?
    ) -> Bool {
        // An unresolved conflict is atomic: completeness takes precedence over
        // diversity caps, while the character and atom budgets still apply.
        if unit.conflictID != nil { return true }
        for atom in unit.atoms {
            if sourceCounts[atom.draft.sourceID, default: 0] + 1
                > configuration.maximumAtomsPerSource { return false }
            let kind = atom.draft.kind
            var cap = configuration.maximumAtoms(forKind: kind)
            // ONE owner for the memory row count. Before this, the caller's
            // `recallRowLimit` bounded only the legacy recall lane — empty on
            // ContextFlow turns — while the packet's memory lane answered to
            // the selector's per-kind quota alone (20 rows observed against a
            // 12-row limit). The limit is applied to `.memory` atoms ONLY:
            // identity, correction and instruction atoms are authority, not
            // recall breadth, and mandatory atoms never reach this loop.
            if kind == .memory, let memoryAtomRowLimit {
                cap = min(cap, memoryAtomRowLimit)
            }
            // Shrink the cap for OTHER roles by whatever is still owed to the
            // reserved role. Once the reserve is filled (or was never claimable
            // this turn) the cap is the ordinary one.
            if let reservation = configuration.reservedRoleSlotsPerKind[kind],
               reservation.role != atom.draft.contentRole,
               let reserved = reservedSlots[kind] {
                cap -= max(0, reserved - reservedRoleCounts[kind, default: 0])
            }
            if kindCounts[kind, default: 0] + 1 > cap { return false }
        }
        return true
    }

    /// Per-turn correction cap. Returns false when admitting `unit` would push
    /// the turn past `configuration.maximumCorrectionAtomsPerTurn` corrections
    /// the message is not about.
    ///
    /// WHY: her store is nine-tenths corrections, so a recall for "memory"
    /// handed back twelve `[correction]` rows and two facts — the person she
    /// remembers being was mostly someone who got things wrong. The cap is on
    /// AMBIENT corrections only. A correction the current message is actually
    /// about is exempt and rides in on its score like any other atom, and a
    /// mandatory/pinned correction never reaches the dynamic quota loop at all.
    /// An unresolved conflict is atomic but NOT exempt: `quotaAllows` waives the
    /// diversity caps for a conflict because a half-shown conflict misleads, and
    /// the honest way to keep that property under a correction cap is to admit
    /// the whole unit or none of it. A four-claim correction conflict therefore
    /// stays out entirely rather than smuggling four ambient corrections past a
    /// cap of three.
    func correctionCapAllows(
        _ unit: SelectionUnit,
        admittedCorrections: Int,
        scores: [ContextAtomID: ContextCandidateScoreFeatures]
    ) -> Bool {
        var admitted = admittedCorrections
        for atom in unit.atoms where atom.draft.kind == .correction {
            if Self.correctionIsAboutMessage(scores[atom.draft.id]) { continue }
            admitted += 1
            if admitted > configuration.maximumCorrectionAtomsPerTurn { return false }
        }
        return true
    }

    /// Is THIS message about that correction? `messageCoverage` is the one
    /// score feature carried context cannot dilute, and `lexicalExact` is 1
    /// only when the normalized message appears verbatim in the atom — both are
    /// "the user just raised this", not "this scored well overall".
    static func correctionIsAboutMessage(_ score: ContextCandidateScoreFeatures?) -> Bool {
        guard let score else { return false }
        return score.messageCoverage >= 0.5 || score.lexicalExact == 1
    }

    /// The reserved-role units this turn actually qualifies, and how many slots
    /// they can claim per kind.
    ///
    /// Qualification is per atom: the reserved role AND the reservation's
    /// message-coverage gate. A turn with no qualifying atom reserves nothing
    /// and takes no promotion, so selection is byte-identical to having no
    /// reservation configured at all.
    func reservedRolePlan(
        in units: [SelectionUnit],
        scores: [ContextAtomID: ContextCandidateScoreFeatures]
    ) -> (slots: [ContextAtomKind: Int], qualifyingKeys: Set<String>) {
        guard !configuration.reservedRoleSlotsPerKind.isEmpty else { return ([:], []) }
        var available: [ContextAtomKind: Int] = [:]
        var keys = Set<String>()
        for unit in units where unit.conflictID == nil {
            for atom in unit.atoms {
                guard let reservation = configuration.reservedRoleSlotsPerKind[atom.draft.kind],
                      reservation.role == atom.draft.contentRole,
                      (scores[atom.draft.id]?.messageCoverage ?? 0)
                        >= reservation.minimumMessageCoverage else { continue }
                available[atom.draft.kind, default: 0] += 1
                keys.insert(unit.stableKey)
            }
        }
        let slots: [ContextAtomKind: Int] = available.reduce(into: [:]) { result, entry in
            guard let reservation = configuration.reservedRoleSlotsPerKind[entry.key] else { return }
            let value = min(reservation.slots, entry.value)
            if value > 0 { result[entry.key] = value }
        }
        return (slots, slots.isEmpty ? [] : keys)
    }

    func plannedItems(
        for unit: SelectionUnit,
        generationID: Int64,
        remainingCharacters: Int
    ) -> [ContextPacketItem]? {
        let bodyCount = unit.atoms.reduce(0) { $0 + $1.draft.body.count }
        if bodyCount <= remainingCharacters {
            return unit.atoms.map {
                ContextPacketItem(
                    atom: $0,
                    generationID: generationID,
                    text: $0.draft.body,
                    representation: .body,
                    mandatory: false
                )
            }
        }
        let summaries = unit.atoms.map { $0.draft.deterministicSummary?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard summaries.allSatisfy({ !($0 ?? "").isEmpty }) else { return nil }
        let summaryCount = summaries.reduce(0) { $0 + ($1?.count ?? 0) }
        guard summaryCount <= remainingCharacters else { return nil }
        return zip(unit.atoms, summaries).map { atom, summary in
            ContextPacketItem(
                atom: atom,
                generationID: generationID,
                text: summary ?? "",
                representation: .deterministicSummary,
                mandatory: false
            )
        }
    }

    func diversityBonus(
        for atom: ContextStoredAtom,
        sourceCounts: [ContextSourceID: Int],
        kindCounts: [ContextAtomKind: Int]
    ) -> Double {
        (sourceCounts[atom.draft.sourceID, default: 0] == 0
            ? configuration.weights.diversityNewSourceBonus : 0)
            + (kindCounts[atom.draft.kind, default: 0] == 0
                ? configuration.weights.diversityNewKindBonus : 0)
    }

    func maximumTokenSimilarity(
        _ candidateTokens: Set<String>,
        _ selectedTokenSets: [Set<String>]
    ) -> Double {
        selectedTokenSets.reduce(0) { current, selectedTokens in
            max(current, Self.jaccard(candidateTokens, selectedTokens))
        }
    }

    func conflictGroups(
        for need: NeedSignal,
        generation: ContextStoredGeneration
    ) throws -> [ConflictGroup] {
        var adjacency: [ContextAtomID: Set<ContextAtomID>] = [:]
        var relationshipProvenance: [(members: Set<ContextAtomID>, value: String)] = []
        var explicitByID: [String: ContextConflictDefinition] = [:]

        for definition in need.explicitConflicts.sorted(by: { $0.id < $1.id }) {
            guard definition.memberAtomIDs.count >= 2 else { continue }
            if let resolved = definition.resolvedAtomID,
               !definition.memberAtomIDs.contains(resolved) {
                throw ContextSelectionError.invalidConflictResolution(
                    conflictID: definition.id,
                    atomID: resolved
                )
            }
            explicitByID[definition.id] = definition
            connect(definition.memberAtomIDs, adjacency: &adjacency)
        }
        for relationship in generation.relationships.sorted(by: { $0.draft.id < $1.draft.id })
            where Self.isConflictKind(relationship.draft.kind) {
            let pair: Set<ContextAtomID> = [
                relationship.draft.sourceAtomID,
                relationship.draft.targetAtomID,
            ]
            connect(pair, adjacency: &adjacency)
            relationshipProvenance.append((pair, relationship.draft.provenance))
        }

        var visited = Set<ContextAtomID>()
        var groups: [ConflictGroup] = []
        for start in adjacency.keys.sorted() where !visited.contains(start) {
            var stack = [start]
            var members = Set<ContextAtomID>()
            while let current = stack.popLast() {
                guard visited.insert(current).inserted else { continue }
                members.insert(current)
                stack.append(contentsOf: (adjacency[current] ?? []).sorted(by: >))
            }
            let matchingDefinitions = explicitByID.values.filter {
                !$0.memberAtomIDs.isDisjoint(with: members)
            }.sorted { $0.id < $1.id }
            let resolutions = Set(matchingDefinitions.compactMap(\.resolvedAtomID))
            if resolutions.count > 1, let conflicting = resolutions.sorted().last {
                throw ContextSelectionError.invalidConflictResolution(
                    conflictID: matchingDefinitions.map(\.id).joined(separator: "+"),
                    atomID: conflicting
                )
            }
            let exactDefinition = matchingDefinitions.first { $0.memberAtomIDs == members }
            let id = exactDefinition?.id ?? "conflict:" + ContextStableID.digest(
                parts: members.map(\.rawValue).sorted()
            )
            var provenance = matchingDefinitions.map(\.provenance)
            provenance.append(contentsOf: relationshipProvenance.compactMap { edge in
                edge.members.isSubset(of: members) ? edge.value : nil
            })
            groups.append(ConflictGroup(
                id: id,
                memberAtomIDs: members,
                resolvedAtomID: resolutions.first,
                provenance: Array(Set(provenance)).sorted()
            ))
        }
        return groups.sorted { $0.id < $1.id }
    }

    func connect(
        _ members: Set<ContextAtomID>,
        adjacency: inout [ContextAtomID: Set<ContextAtomID>]
    ) {
        let sorted = members.sorted()
        for atom in sorted where adjacency[atom] == nil { adjacency[atom] = [] }
        guard let first = sorted.first else { return }
        for atom in sorted.dropFirst() {
            adjacency[first, default: []].insert(atom)
            adjacency[atom, default: []].insert(first)
        }
    }

    func conflictSet(
        _ group: ConflictGroup,
        generationID: Int64,
        atomByID: [ContextAtomID: ContextStoredAtom],
        eligibleIDs: Set<ContextAtomID>,
        candidateIDs: Set<ContextAtomID>,
        selectedIDs: Set<ContextAtomID>,
        omittedConflictIDs: Set<String>
    ) -> ContextConflictSet {
        let eligibleMembers = group.memberAtomIDs.intersection(eligibleIDs)
        let claims = eligibleMembers.compactMap { atomByID[$0] }
            .sorted { $0.draft.id < $1.draft.id }
            .map { ContextAtomPointer(atom: $0, generationID: generationID) }
        let handling: ContextConflictHandling
        if let resolved = group.resolvedAtomID {
            handling = eligibleIDs.contains(resolved) ? .resolved : .ineligible
        } else if eligibleMembers.count != group.memberAtomIDs.count {
            handling = .ineligible
        } else if group.memberAtomIDs.isSubset(of: selectedIDs) {
            handling = .includedUncertainty
        } else if omittedConflictIDs.contains(group.id)
            || !group.memberAtomIDs.intersection(candidateIDs).isEmpty {
            handling = .omittedBudget
        } else {
            handling = .omittedIrrelevant
        }
        return ContextConflictSet(
            id: group.id,
            claims: claims,
            resolvedAtomID: group.resolvedAtomID,
            provenance: group.provenance,
            handling: handling
        )
    }

    static func isConflictKind(_ kind: String) -> Bool {
        let normalized = kind.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized == "conflict" || normalized == "conflicts"
            || normalized == "contradicts" || normalized == "contradiction"
    }

    static func tokens(_ text: String) -> Set<String> {
        ContextLexicalTokenizer.tokens(text)
    }

    static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    static func cosine(_ lhs: [Float]?, _ rhs: [Float]?) -> Double {
        // Single source of truth: VectorMath.cosine (raw, finiteness-guarded,
        // equal-length required). Context selection preserves its historical
        // [0, 1] clamp at THIS call site — negative similarity is treated as
        // "no relevance" for selection.
        min(1, max(0, VectorMath.cosine(lhs, rhs)))
    }
}

enum ContextLexicalTokenizer {
    /// Structural English words are useful to a model after selection but are
    /// not evidence that an adaptive source is relevant. Keeping them in the
    /// overlap gate made any prose-heavy resident truth match unrelated chat
    /// through words such as "the" or "is". Identifiers, numbers, domain
    /// terms, explicit triggers, and semantic vectors remain untouched.
    // 2026-09-06: this list now lives beside the stemmer both lanes already
    // share, because MemoryV2's BM25 lane needed the same one. Same members,
    // one definition. See RecallLexicalNormalization.stopWords.
    private static let routingStopWords: Set<String> = RecallLexicalNormalization.stopWords

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap {
            let token = String($0)
            return routingStopWords.contains(token) ? nil : RecallLexicalNormalization.term(token)
        })
    }
}
