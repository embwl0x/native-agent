import Foundation
import NativeAgentCore
// Blueprint: | `ContextSelection.swift` | `ContextSelector.select` owns eligibility, mandatory coverage, memory touch/rest admission, quotas, deterministic reranking and packet receipts; `commonEligibilityFailure` is shared with expansion |

// MARK: - Deterministic hybrid selector

public struct ContextSelector: Sendable {
    public let configuration = ContextSelectionConfiguration()
    /// How far a memory must stand out to come to mind: what she is told
    /// gets the ordinary bar; an ambient moment (something she read, something
    /// that happened) only reminds her of what it singles out clearly.
    public let memoryStandout: Double

    public init(memoryStandout: Double = ContextSelectionConfiguration.memoryStandoutDeviations) {
        self.memoryStandout = memoryStandout
    }

    public func select(
        _ need: NeedSignal,
        from generation: ContextStoredGeneration,
        pinnedTo snapshot: ContextGenerationSnapshot? = nil
    ) throws -> ContextPacket {
        let selectionStarted = DispatchTime.now().uptimeNanoseconds
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
            groups.flatMap { group -> [(ContextAtomID, ContextEligibilityReason)] in
            guard let resolved = group.resolvedAtomID else { return [] }
            return group.memberAtomIDs.filter { $0 != resolved }.map {
                ($0, ContextEligibilityReason.supersededByConflictResolution)
            }
        }, uniquingKeysWith: { first, _ in first })
        let sourceByID = Dictionary(generation.sources.map {
            ($0.descriptor.id, $0)
        }, uniquingKeysWith: { first, _ in first })
        let sortedAtoms = generation.atoms.sorted { $0.draft.id < $1.draft.id }
        let atomByID = Dictionary(sortedAtoms.map { ($0.draft.id, $0) }, uniquingKeysWith: { first, _ in first })

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
        // Always-atoms are mandatory only within this request's authorized source scope.
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

        // Budget expansion must not pay for a scoring pass it will discard.
        let mandatoryAtoms = mandatoryIDs.compactMap { atomByID[$0] }.sorted(by: mandatoryOrder)
        let mandatoryCharacters = mandatoryAtoms.reduce(0) { $0 + $1.draft.body.count }
        let mandatoryLimit = min(need.characterBudget, need.mandatoryCharacterBudget)
        guard mandatoryCharacters <= mandatoryLimit else {
            throw ContextSelectionError.mandatoryBudgetExceeded(
                required: mandatoryCharacters,
                limit: mandatoryLimit
            )
        }

        let conflictedIDs = Set(groups.filter { $0.resolvedAtomID == nil }.flatMap(\.memberAtomIDs))
        // Precovered sources are already present in the stable prompt. Keep
        // their eligibility receipts, but do not spend per-turn ranking work
        // on atoms that cannot become dynamic candidates. Explicit mandatory
        // atoms remain scorable for complete receipts.
        let scorable = eligible.filter {
            !need.precoveredSourceIDs.contains($0.draft.sourceID)
                || mandatoryIDs.contains($0.draft.id)
        }
        let lexicalIndex = Dictionary(scorable.map { atom in
            (
                atom.draft.id,
                snapshot?.selectionIndex[atom.draft.id]
                    ?? ContextSelectionIndexEntry(atom: atom.draft)
            )
        }, uniquingKeysWith: { first, _ in first })
        let scoreContext = makeScoreContext(need, lexicalIndex: lexicalIndex)
        var scores: [ContextAtomID: ContextCandidateScoreFeatures] = [:]
        for atom in scorable {
            scores[atom.draft.id] = score(
                atom,
                need: need,
                context: scoreContext,
                lexicalEntry: lexicalIndex[atom.draft.id]
                    ?? ContextSelectionIndexEntry(atom: atom.draft),
                hasUnresolvedConflict: conflictedIDs.contains(atom.draft.id)
            )
        }
        let baseScores = scores

        var selectedItems: [ContextPacketItem] = []
        var selectedIDs = Set<ContextAtomID>()
        var selectionOrdinals: [ContextAtomID: Int] = [:]
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
        // Memories need touch past chance across all readings, then rank by relevance × reachability.
        // Recent service rests unless the message singles it out. Corrections share the rows;
        // triggered scoped corrections are mandatory. Unresolved conflicts stay atomic below.
        let memoryKinds: Set<ContextAtomKind> = [.memory, .correction]
        let memoryTouch = memoryRelevance(
            scorable.filter { memoryKinds.contains($0.draft.kind) }, need: need, scores: baseScores
        )
        let relevanceByAtom = memoryTouch.relevance
        let smallMemoryPopulation = relevanceByAtom.count < 3
        // The chance bar counts every look: memories × readings of the message.
        let relevanceFloor = memoryStandout
        let restFloor = memoryStandout + 1
        func touched(_ atom: ContextStoredAtom) -> Bool {
            // A relative floor is in standard deviations; a small population
            // instead uses the ordinary model-scaled semantic contribution.
            let floor = smallMemoryPopulation ? configuration.minimumRelevance : relevanceFloor
            if let relevance = relevanceByAtom[atom.draft.id], relevance >= floor { return true }
            // Or her words: half the message, or the whole message as words.
            guard let features = baseScores[atom.draft.id] else { return false }
            return features.messageCoverage >= 0.5 || (features.lexicalExact >= 1 && features.messageCoverage > 0)
        }
        let memoryCandidates = rankedCandidates.filter { memoryKinds.contains($0.draft.kind) }
        let flooredMemoryIDs = Set(memoryCandidates.filter { !touched($0) }.map(\.draft.id))
        var memoryRecall: [ContextMemoryRecallScore] = []
        var memoryRank: [ContextAtomID: Double] = [:]
        for atom in memoryCandidates where !flooredMemoryIDs.contains(atom.draft.id) {
            let id = atom.draft.id
            let relevance = relevanceByAtom[id]
            // No use history supplied (a caller without feedback): relevance alone.
            let reachability = need.memoryReachability[id] ?? 1
            let rested = (need.servedTurnsAgo[id].map { $0 < configuration.memoryRestTurns } ?? false)
                && (relevance ?? -.infinity) < restFloor
            memoryRecall.append(ContextMemoryRecallScore(
                atomID: id, relevance: relevance, reachability: reachability, rested: rested
            ))
            if !rested {
                let rank: Double
                if smallMemoryPopulation {
                    // Semantic scores use their own scale; a lexical-only touch
                    // still needs a positive rank when no semantic score exists.
                    if let relevance, relevance > 0 {
                        rank = relevance
                    } else {
                        rank = configuration.minimumRelevance
                    }
                } else {
                    rank = max(relevance ?? 0, relevanceFloor)
                }
                memoryRank[id] = rank * reachability
            }
        }
        let memoryPicks = memoryCandidates.filter {
            memoryRank[$0.draft.id] != nil && $0.draft.injectionPolicy != .onDemand
                && !conflictedIDs.contains($0.draft.id)
        }.sorted {
            let left = memoryRank[$0.draft.id] ?? 0, right = memoryRank[$1.draft.id] ?? 0
            if left != right { return left > right }
            return $0.draft.id < $1.draft.id
        }

        // Short messages narrow memory rows at the message-coverage damp's own threshold.
        let effectiveMemoryRowLimit: Int? = {
            guard configuration.shortMessageMemoryRowCap > 0,
                  scoreContext.messageTokens.count
                    <= ContextSelectionConfiguration.shortMessageTokenCount else {
                return need.memoryAtomRowLimit
            }
            let short = configuration.shortMessageMemoryRowCap
            return min(need.memoryAtomRowLimit ?? short, short)
        }()

        let boundedCandidates = Array(rankedCandidates.prefix(configuration.maximumCandidates))
        let candidateIDs = Set(boundedCandidates.map(\.draft.id)).union(memoryPicks.map(\.draft.id))

        // Admission, not candidacy: score/conflict receipts keep untouched
        // memories, but conflict units cannot carry them back into the packet.
        let admittedCandidates = boundedCandidates.filter {
            !flooredMemoryIDs.contains($0.draft.id)
        }
        var units = makeSelectionUnits(
            candidates: admittedCandidates.filter {
                $0.draft.injectionPolicy != .onDemand
                    && (!memoryKinds.contains($0.draft.kind) || conflictedIDs.contains($0.draft.id))
            },
            groups: groups,
            atomByID: atomByID,
            candidateIDs: Set(admittedCandidates.map(\.draft.id)),
            mandatoryIDs: mandatoryIDs
        )
        var selectedDynamicCount = 0
        var usedCharacters = mandatoryCharacters
        var sourceCounts: [ContextSourceID: Int] = [:]
        var kindCounts: [ContextAtomKind: Int] = [:]
        // The memory rows are taken BEFORE the ordinary lane runs, so ops
        // cannot crowd out what the message touched.
        for atom in memoryPicks where selectedDynamicCount < configuration.maximumDynamicAtoms {
            let unit = SelectionUnit(stableKey: "atom:\(atom.draft.id.rawValue)", conflictID: nil, atoms: [atom])
            guard quotaAllows(
                unit,
                sourceCounts: sourceCounts,
                kindCounts: kindCounts,
                memoryAtomRowLimit: effectiveMemoryRowLimit
            ), let item = plannedItems(
                for: unit,
                generationID: generation.generation.id,
                remainingCharacters: need.characterBudget - usedCharacters
            )?.first else { continue }
            selectedItems.append(item)
            selectedIDs.insert(item.pointer.atomID)
            selectionOrdinals[item.pointer.atomID] = selectedItems.count
            selectedDynamicCount += 1
            usedCharacters += item.characterCount
            sourceCounts[item.pointer.sourceID, default: 0] += 1
            kindCounts[item.pointer.kind, default: 0] += 1
        }
        var omittedConflictIDs = Set<String>()
        let selectedTokenSets = selectedItems.map { Self.tokens($0.text) }
        var redundancyByAtom = Dictionary(boundedCandidates.map { atom in
            (
                atom.draft.id,
                maximumTokenSimilarity(
                    lexicalIndex[atom.draft.id]?.bodyTokens ?? [],
                    selectedTokenSets
                )
            )
        }, uniquingKeysWith: { first, _ in first })

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
                    var reranked = original
                    reranked.diversityBonus = diversity
                    reranked.redundancyPenalty = redundancy
                    reranked.total = value
                    scores[atom.draft.id] = reranked
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
            // Rejected units change no ranking input; retain this order until a selection lands.
            for candidate in reranked where selectedPlan == nil {
                let unit = candidate.unit
                examinedKeys.insert(unit.stableKey)
                guard unit.atoms.count <= remainingAtomSlots,
                      quotaAllows(
                        unit,
                        sourceCounts: sourceCounts,
                        kindCounts: kindCounts,
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

        // Summaries and renderer-truncated bodies retain a route to the full
        // atom. This adds at most one pointer per bounded selected item.
        var pointers: [ContextAtomPointer] = []
        var published: Set<ContextAtomID> = []
        for item in selectedItems where item.isExpandable(thresholdChars: need.packetAtomExpandThresholdChars) {
            guard published.insert(item.pointer.atomID).inserted else { continue }
            pointers.append(item.pointer)
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
                reason: $0.lastError.map { "last known good source retained: \($0)" }
                    ?? "last known good source retained"
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
        let needFingerprint = need.deterministicFingerprint
        let receiptID = ContextStableID.digest(parts: [
            needFingerprint,
            String(generation.generation.id),
            generation.generation.sourceFingerprint,
        ] + selectedIDList.map(\.rawValue) + pointerIDList.map(\.rawValue))
        let measuredSelectionMicroseconds = Int((DispatchTime.now().uptimeNanoseconds &- selectionStarted) / 1_000)
        let receipt = ContextSelectionReceipt(
            id: receiptID,
            needFingerprint: needFingerprint,
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
            measuredSelectionMicroseconds: measuredSelectionMicroseconds,
            selectionLatencyProvenance: .monotonicClock,
            memoryPopulation: memoryTouch.looks,
            memoryFloorDroppedCount: flooredMemoryIDs.count,
            memoryRecall: memoryRecall.sorted { $0.atomID < $1.atomID }
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

extension ContextSelector {
    /// Shared admission, in selection-policy order. Expansion keeps pointer checks.
    static func commonEligibilityFailure(
        for atom: ContextStoredAtom, generationID: Int64,
        source: ContextStoredSource, need: NeedSignal
    ) -> (reason: ContextEligibilityReason, expansionError: ContextExpansionError)? {
        let id = atom.draft.id, sourceID = source.descriptor.id
        guard atom.validFromGeneration <= generationID,
              atom.validToGeneration.map({ $0 >= generationID }) ?? true else {
            return (.generationMismatch, .atomGenerationMismatch(id))
        }
        guard source.validFromGeneration <= generationID,
              source.validToGeneration.map({ $0 >= generationID }) ?? true else {
            return (.generationMismatch, .sourceGenerationMismatch(sourceID))
        }
        if need.deletedAtomIDs.contains(id) { return (.deleted, .deleted(id)) }
        if need.tombstonedAtomIDs.contains(id) { return (.tombstoned, .tombstoned(id)) }
        if source.health == .removed { return (.sourceRemoved, .sourceRemoved(sourceID)) }
        if !need.authorization.allowedOrigins.contains(need.origin) { return (.originDenied, .originDenied(need.origin)) }
        if !need.authorization.allowedSourceIDs.contains(sourceID) { return (.permissionDenied, .sourcePermissionDenied(sourceID)) }
        if let allowed = need.authorization.allowedAtomIDs, !allowed.contains(id) { return (.permissionDenied, .atomPermissionDenied(id)) }
        if !source.descriptor.permittedSurfaces.contains(need.surface) { return (.surfaceDenied, .sourceSurfaceDenied(source: sourceID, surface: need.surface)) }
        if !atom.draft.permittedSurfaces.contains(need.surface) { return (.surfaceDenied, .atomSurfaceDenied(atom: id, surface: need.surface)) }
        if !need.authorization.allowedPrivacy.contains(source.descriptor.privacy) { return (.privacyDenied, .sourcePrivacyDenied(source: sourceID, privacy: source.descriptor.privacy)) }
        if !need.authorization.allowedPrivacy.contains(atom.draft.privacy) { return (.privacyDenied, .atomPrivacyDenied(atom: id, privacy: atom.draft.privacy)) }
        if atom.draft.injectionPolicy == .neverInject { return (.neverInject, .atomNotExpandable(policy: .neverInject)) }
        if source.descriptor.injectionPolicy == .neverInject { return (.neverInject, .sourceInjectionDenied(sourceID)) }
        if atom.draft.freshness.isExpired(at: need.evaluationTime) { return (.expired, .expired(id)) }
        if need.staleRuntimeAtomIDs.contains(id) { return (.staleRuntime, .staleRuntime(id)) }
        if need.secretBearingAtomIDs.contains(id) { return (.secretBearing, .secretBearing(id)) }
        return nil
    }
}

private extension ContextSelector {
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
        let failure = Self.commonEligibilityFailure(for: atom, generationID: generationID, source: source, need: need)
        if let failure, failure.reason == .generationMismatch || failure.reason == .deleted { return failure.reason }
        if !ContextCorrectionScope.applies(atom.draft, message: need.message, recentTurns: need.recentTurns,
                                          subjectEntities: need.extractedEntities) {
            return .outsideContextScope
        }
        return failure?.reason ?? resolutionReason
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
        memoryAtomRowLimit: Int?
    ) -> Bool {
        // An unresolved conflict is atomic: completeness takes precedence over
        // diversity caps, while the character and atom budgets still apply.
        if unit.conflictID != nil { return true }
        for atom in unit.atoms {
            if sourceCounts[atom.draft.sourceID, default: 0] + 1
                > configuration.maximumAtomsPerSource { return false }
            let kind = atom.draft.kind
            // Corrections and memories compete for the same rows.
            let memoryLane = kind == .memory || kind == .correction
            var cap = configuration.maximumAtoms(forKind: memoryLane ? .memory : kind)
            // The caller's memory row limit also bounds the kind quota; mandatory atoms bypass it.
            if memoryLane, let memoryAtomRowLimit {
                cap = min(cap, memoryAtomRowLimit)
            }
            let used = memoryLane
                ? kindCounts[.memory, default: 0] + kindCounts[.correction, default: 0]
                : kindCounts[kind, default: 0]
            if used + 1 > cap { return false }
        }
        return true
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
}
