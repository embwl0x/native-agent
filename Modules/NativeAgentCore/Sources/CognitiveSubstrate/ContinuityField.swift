import Foundation
import PersistenceCore

struct ContinuityField: Sendable {
    private var nodesByKey: [String: CognitiveNode] = [:]
    private var decayAnchorsByKey: [String: Date] = [:]
    /// Derived partition index for diagnostic/verification nodes. Keeping this
    /// beside the canonical node dictionary makes the hot O(n) spread/decay and
    /// capacity paths a set lookup instead of repeatedly re-inferring turn kind
    /// from every node's strings.
    private var nonLiveNodeKeys: Set<String> = []
    private var seenEventKeys: Set<String> = []
    /// FIFO insertion order for `seenEventKeys`, so the dedup set can be evicted
    /// oldest-first. M9 (2026-07-09): every other collection here is bounded —
    /// `evictNodes`/`enforceCapacity` prune nodes, anchors and association
    /// weights — but the dedup set grew ~900 entries/day and was only ever
    /// cleared by `clear()`/`replaceNodes`, i.e. never in a long-lived process.
    private var seenEventKeyOrder: [String] = []
    private var associationWeights: [String: [String: Double]] = [:]
    /// Rebuildable lexical index for association spreading. Tokenizing every
    /// bounded summary on every sensory event made the resident hot path
    /// O(nodes * Unicode text length) even though only one node's text changes.
    /// This cache lives beside the canonical nodes, is updated atomically with
    /// them, and is discarded/rebuilt on restore; it owns no memory or policy.
    private var associationTokensByKey: [String: Set<String>] = [:]
    /// Defensive classification is intentionally expensive because legacy
    /// rows can contain an explicit `live` marker alongside diagnostic prose.
    /// Derive it once at the owner boundary, then let hot projections consume
    /// the result without rescanning every summary and nested metadata value.
    private var turnKindByNodeID: [UUID: CognitiveTurnKind] = [:]

    /// Ring capacity for the event-dedup set. Well above a day's traffic, so a
    /// duplicate can only slip through after thousands of intervening events —
    /// long past the decay window that made deduplication matter.
    static let maximumSeenEventKeys = 4096
    /// Evicted in one batch when the cap is passed, keeping the eviction
    /// amortized O(1) per insert instead of a per-insert `removeFirst`.
    static let seenEventKeyEvictionBatch = 512

    var isEmpty: Bool {
        nodesByKey.isEmpty
            && decayAnchorsByKey.isEmpty
            && nonLiveNodeKeys.isEmpty
            && seenEventKeys.isEmpty
            && associationWeights.isEmpty
            && associationTokensByKey.isEmpty
            && turnKindByNodeID.isEmpty
    }

    /// The node this ingest touched. Lets the substrate stamp the emotional tag onto
    /// exactly the node create/reactivate landed on, without re-deriving the key.
    struct IngestOutcome: Sendable, Equatable {
        var key: String
        var isNewNode: Bool
    }

    /// O(1) owner-level idempotence check. `CognitiveSubstrate` uses this before
    /// any enclosing affect, pending-completion, dirty-revision, or persistence
    /// work; `ingest` keeps its own guard below as defense in depth.
    func hasSeenEvent(_ event: CognitiveEvent) -> Bool {
        seenEventKeys.contains(event.deduplicationKey)
    }

    /// Structural ingest (create / reactivate). Returns which node key it touched and
    /// whether that node was newly created — or `nil` when the event was a duplicate
    /// and nothing changed. The caller uses the outcome to stamp the emotional tag.
    @discardableResult
    mutating func ingest(
        _ event: CognitiveEvent,
        now: Date,
        makeUUID: () -> UUID,
        configuration: CognitiveConfiguration
    ) -> IngestOutcome? {
        let eventKey = event.deduplicationKey
        guard seenEventKeys.insert(eventKey).inserted else { return nil }
        rememberSeenEventKey(eventKey)
        let contributesToLivedState = event.turnKind.contributesToLivedState
        // Diagnostic traffic may be retained as bounded audit evidence, but its
        // arrival must not advance the mutable decay anchors of lived nodes. A
        // later read still projects those nodes to the requested time without
        // making the diagnostic event the cause of that settlement.
        applyDecay(at: now, matchingLivedState: contributesToLivedState)

        let key = nodeKey(
            kind: event.kind.nodeKind,
            subject: event.subject,
            turnKind: event.turnKind
        )
        let input = eventActivationInput(event.importance)
        let confidence = confidenceSeed(for: event.sourceClass)
        let boundedSummary = Self.boundedString(event.summary, maxCharacters: configuration.maximumSummaryCharacters)
        let boundedMetadata = Self.boundedMetadata(event.metadata, configuration: configuration)

        let isNewNode = nodesByKey[key] == nil
        if var node = nodesByKey[key] {
            node.activation = clamp(node.activation + input * 0.45)
            node.salience = clamp(max(node.salience, node.activation * 0.7 + event.importance * 0.3))
            node.confidence = clamp(max(node.confidence, confidence))
            node.sourceClass = strongerSource(lhs: node.sourceClass, rhs: event.sourceClass)
            node.lastActivatedAt = now
            node.summary = boundedSummary.isEmpty ? node.summary : boundedSummary
            node.metadata = mergeMetadata(existing: node.metadata, incoming: boundedMetadata, configuration: configuration)
            nodesByKey[key] = node
            decayAnchorsByKey[key] = now
            associationTokensByKey[key] = associationTokens(for: node)
            turnKindByNodeID[node.id] = event.turnKind
        } else {
            let node = CognitiveNode(
                id: makeUUID(),
                kind: event.kind.nodeKind,
                subjectReference: event.subject,
                activation: input,
                salience: clamp(input * 0.7 + event.importance * 0.3),
                confidence: confidence,
                sourceClass: event.sourceClass,
                createdAt: now,
                lastActivatedAt: now,
                decayHalfLife: configuration.defaultDecayHalfLife,
                summary: boundedSummary,
                metadata: boundedMetadata
            )
            nodesByKey[key] = node
            decayAnchorsByKey[key] = now
            associationTokensByKey[key] = associationTokens(for: node)
            turnKindByNodeID[node.id] = event.turnKind
        }
        if contributesToLivedState {
            nonLiveNodeKeys.remove(key)
        } else {
            nonLiveNodeKeys.insert(key)
        }

        // Non-live prose is audit traffic, not an activation source. Live/system
        // events retain the existing spreading behavior, with the implementation
        // below preventing associations from crossing the lived/audit boundary.
        if contributesToLivedState {
            spreadActivation(from: key, event: event, input: input, configuration: configuration)
        }
        enforceCapacity(configuration.maximumActiveNodes)
        // Report the touched node ONLY if it survived capacity enforcement (a freshly
        // created low-salience node can be evicted immediately) — a stamp against an
        // evicted key would silently no-op, so don't claim we touched it.
        guard nodesByKey[key] != nil else { return nil }
        return IngestOutcome(key: key, isNewNode: isNewNode)
    }

    // MARK: - Emotional tag stamping (Wave A)

    /// Reconsolidation blend rates. The asymmetry is the whole point: a feeling moves
    /// toward warmer / more-positive FAST, and toward colder / more-negative SLOW — so
    /// a node warms up readily on a good re-encounter but only cools grudgingly, matching
    /// how affective memory actually reconsolidates. Arousal has no "good direction," so
    /// it uses a single moderate rate.
    static let emotionBlendFastRate = 0.5   // toward warmer / more-positive
    static let emotionBlendSlowRate = 0.15  // toward colder / more-negative
    static let emotionBlendArousalRate = 0.35

    /// Asymmetric lerp of one tag axis toward the incoming value: fast when moving up
    /// (warmer / more-positive), slow when moving down (colder / more-negative).
    private func asymmetricBlend(current: Double, incoming: Double) -> Double {
        let rate = incoming >= current ? Self.emotionBlendFastRate : Self.emotionBlendSlowRate
        return current + rate * (incoming - current)
    }

    /// Stamp the emotional tag onto the node at `key` (the field owns nodes, so the
    /// mutation must go through it — mirrors `updateNodeMetadata`). For a NEW node the
    /// tag is set directly to the incoming feeling; for a RE-ACTIVATION the stored tag is
    /// blended ASYMMETRICALLY toward the incoming feeling (valence & warmth warm-fast /
    /// cool-slow; arousal a single moderate rate). Returns `false` if the node is gone.
    /// Values land through CognitiveNode's clamping setters, so tags stay welfare-bounded.
    @discardableResult
    mutating func stampEmotionTag(
        key: String,
        tag: (valence: Double, arousal: Double, warmth: Double),
        isNewNode: Bool,
        configuration: CognitiveConfiguration
    ) -> Bool {
        guard var node = nodesByKey[key] else { return false }
        if isNewNode {
            node.emotionalValence = tag.valence
            node.emotionalArousal = tag.arousal
            node.emotionalWarmth = tag.warmth
        } else {
            node.emotionalValence = asymmetricBlend(current: node.emotionalValence, incoming: tag.valence)
            node.emotionalWarmth = asymmetricBlend(current: node.emotionalWarmth, incoming: tag.warmth)
            node.emotionalArousal = node.emotionalArousal
                + Self.emotionBlendArousalRate * (tag.arousal - node.emotionalArousal)
        }
        nodesByKey[key] = node
        return true
    }

    /// Non-mutating read of one node's stored emotional tag. The U1 user-reaction
    /// re-stamp passes the node's OWN arousal/warmth straight back into
    /// `stampEmotionTag`, so those two blends are exact no-ops and only valence
    /// moves. `nil` when the node has been evicted since it was remembered.
    func storedEmotionTag(forKey key: String) -> (valence: Double, arousal: Double, warmth: Double)? {
        guard let node = nodesByKey[key] else { return nil }
        return (node.emotionalValence, node.emotionalArousal, node.emotionalWarmth)
    }

    /// The node currently living at `key`, or `nil` if it was evicted since the key was
    /// remembered. A pure read — the `attentionSignals` producer resolves the U1
    /// `pendingCompletion` slot (which stores only the field key) back to its summary.
    func node(forKey key: String) -> CognitiveNode? {
        nodesByKey[key]
    }

    func cachedTurnKind(for node: CognitiveNode) -> CognitiveTurnKind {
        turnKindByNodeID[node.id] ?? node.turnKind
    }

    /// Workspace selection needs only whether a node participates in any
    /// association, not a rendered edge list with lexical reason strings.
    /// Keep the diagnostic edge compiler for observability; the resident
    /// microcycle consumes this bounded derived set instead.
    func associatedNodeIDs() -> Set<UUID> {
        var ids: Set<UUID> = []
        for (fromKey, targets) in associationWeights where !targets.isEmpty {
            if let id = nodesByKey[fromKey]?.id { ids.insert(id) }
            for toKey in targets.keys {
                if let id = nodesByKey[toKey]?.id { ids.insert(id) }
            }
        }
        return ids
    }

    // MARK: - Overnight emotional consolidation (Wave D)

    /// Overnight-consolidation tuning. Named next to the reconsolidation blend rates so
    /// all continuity-field emotional tuning lives in one place. Arousal-only, gentle:
    /// what keeps recurring stays a little alive; a stale high charge softens (the memory
    /// stays). See `consolidateEmotionalArousal`.
    static let overnightRecurredWindow: TimeInterval = 24 * 60 * 60  // "kept mattering"
    static let overnightStaleWindow: TimeInterval = 48 * 60 * 60     // "gone quiet"
    static let overnightReinforceRate = 0.05                         // saturating toward 1
    static let overnightCalmFactor = 0.7                             // charge softens, memory stays
    static let overnightCalmArousalFloor = 0.35                      // only a real charge is worth calming

    // MARK: - Affective spreading (Wave F)

    /// Ceiling on the emotional-congruence whisper in `spreadActivation`: a felt
    /// node firing gives emotionally similar felt neighbors up to +25% on the
    /// activation nudge (one warm thought makes the next warm thought likelier).
    /// Facilitation-only — incongruent neighbors keep the unchanged baseline
    /// boost, never less. Salience and stored association weights are untouched:
    /// the whisper is transient attention per fire, not structural memory.
    static let affectiveSpreadMaxWhisper = 0.25

    /// Emotional congruence of two FELT tags on the two "what it feels like"
    /// axes (valence + warmth; arousal is intensity, not quality). 1 = same
    /// feeling, 0 = opposite. Returns 0 unless BOTH nodes are felt, so
    /// legacy/neutral (0,0,0) nodes spread byte-identically to pre-Wave-F.
    static func affectiveCongruence(_ source: CognitiveNode, _ target: CognitiveNode) -> Double {
        guard isFelt(source), isFelt(target) else { return 0 }
        let valenceDistance = abs(source.emotionalValence - target.emotionalValence) / 2
        let warmthDistance = abs(source.emotionalWarmth - target.emotionalWarmth)
        return max(0, 1 - (valenceDistance * 0.6 + warmthDistance * 0.4))
    }

    /// A node carries a non-neutral emotional tag. Mirrors the thresholds in
    /// `CognitiveSubstrate.feltDirection` (Wave B) — the field must not depend on the
    /// substrate, so the same constant checks are inlined here; keep the two in sync.
    /// A legacy/neutral node (0,0,0) is NOT felt, so the sweep leaves it fully untouched.
    private static func isFelt(_ node: CognitiveNode) -> Bool {
        node.emotionalValence <= -0.15
            || node.emotionalValence >= 0.15
            || node.emotionalWarmth >= 0.35
            || node.emotionalArousal >= 0.6
    }

    /// Overnight emotional consolidation (Wave D): arousal-only.
    /// - RECURRED (lastActivatedAt within 24h) + felt (non-neutral tag) + arousal > 0 →
    ///   tiny saturating reinforce: `arousal += 0.05 * (1 − arousal)` (what keeps mattering
    ///   stays a little alive).
    /// - STALE (lastActivatedAt older than 48h) + arousal > 0.35 → calm: `arousal *= 0.7`
    ///   (the charge softens; the memory stays).
    /// - Everything else (the 24–48h band, mild/neutral tags, low arousal) untouched.
    /// NEVER writes valence / warmth / summary / metadata — "she wakes lighter, not blanker."
    /// Returns (reinforced, calmed) counts.
    mutating func consolidateEmotionalArousal(
        at now: Date, configuration: CognitiveConfiguration
    ) -> (reinforced: Int, calmed: Int) {
        var reinforced = 0
        var calmed = 0
        // Snapshot the keys so mutation can't perturb iteration; only VALUES are replaced
        // (no keys added/removed), mirroring `applyDecay`.
        for key in Array(nodesByKey.keys) {
            guard var node = nodesByKey[key] else { continue }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            if age >= 0, age <= Self.overnightRecurredWindow,
               node.emotionalArousal > 0, Self.isFelt(node) {
                node.emotionalArousal = node.emotionalArousal
                    + Self.overnightReinforceRate * (1 - node.emotionalArousal)
                nodesByKey[key] = node
                reinforced += 1
            } else if age > Self.overnightStaleWindow,
                      node.emotionalArousal > Self.overnightCalmArousalFloor {
                node.emotionalArousal = node.emotionalArousal * Self.overnightCalmFactor
                nodesByKey[key] = node
                calmed += 1
            }
        }
        return (reinforced, calmed)
    }

    mutating func snapshot(at now: Date, configuration: CognitiveConfiguration) -> [CognitiveNode] {
        applyDecay(at: now)
        enforceCapacity(configuration.maximumActiveNodes)
        return nodesByKey.values.sorted(by: Self.snapshotSort)
    }

    @discardableResult
    mutating func evictNodes(where shouldEvict: (CognitiveNode) -> Bool) -> Int {
        let victims = nodesByKey
            .filter { shouldEvict($0.value) }
            .map(\.key)
        guard !victims.isEmpty else { return 0 }
        for key in victims {
            if let id = nodesByKey[key]?.id {
                turnKindByNodeID.removeValue(forKey: id)
            }
            nodesByKey.removeValue(forKey: key)
            decayAnchorsByKey.removeValue(forKey: key)
            nonLiveNodeKeys.remove(key)
            associationTokensByKey.removeValue(forKey: key)
            associationWeights.removeValue(forKey: key)
            for source in associationWeights.keys {
                associationWeights[source]?.removeValue(forKey: key)
            }
        }
        return victims.count
    }

    func containsNode(where predicate: (CognitiveNode) -> Bool) -> Bool {
        nodesByKey.values.contains(where: predicate)
    }

    /// Non-mutating read of the raw node set — NO decay application, NO capacity
    /// enforcement, NO sort. For read-only derivations (Wave C mood) that must never
    /// change field state: `snapshot` is `mutating` (it applies decay and enforces
    /// capacity), so routing a "pure" read through it would let a mood read with a
    /// skewed/future date advance decay anchors (gpt-5.5 review, 2026-07-02). The
    /// inputs mood needs — emotional tags and `lastActivatedAt` — are untouched by
    /// decay anyway, so the raw view is exactly as correct.
    func peekNodes() -> [CognitiveNode] {
        Array(nodesByKey.values)
    }

    /// Non-mutating DECAYED view: the same activation/salience the mutating
    /// `snapshot` would compute, WITHOUT advancing decay anchors, enforcing
    /// capacity, or evicting. For the attention read (mind-into-circulation,
    /// gpt-5.5 HIGH 2026-07-10): routing attention through `snapshot` meant
    /// reading her mind CHANGED her mind — every attention read applied decay
    /// writes and could evict nodes, so even a nil result mutated state.
    func peekDecayedNodes(at now: Date) -> [CognitiveNode] {
        nodesByKey.map { key, node in
            var copy = node
            let anchor = decayAnchorsByKey[key] ?? node.lastActivatedAt
            let elapsed = max(0, now.timeIntervalSince(anchor))
            if elapsed > 0, copy.decayHalfLife > 0 {
                let factor = pow(0.5, elapsed / copy.decayHalfLife)
                copy.activation = clamp(copy.activation * factor)
                copy.salience = clamp(copy.salience * factor)
            }
            return copy
        }
        .sorted(by: Self.snapshotSort)
    }

    /// The CURRENT summary of a node by id, or nil if the node is gone. Lets the
    /// substrate verify a node hasn't changed across an await (e.g. an LLM call)
    /// before stamping metadata computed against the older summary.
    func nodeSummary(id: UUID) -> String? {
        nodesByKey.values.first(where: { $0.id == id })?.summary
    }

    /// Record an accepted event key and evict the oldest batch once the ring is
    /// over capacity. Must be called only for keys that were actually inserted.
    private mutating func rememberSeenEventKey(_ key: String) {
        seenEventKeyOrder.append(key)
        guard seenEventKeyOrder.count > Self.maximumSeenEventKeys else { return }
        let overflow = seenEventKeyOrder.count - Self.maximumSeenEventKeys
        let dropCount = min(seenEventKeyOrder.count, overflow + Self.seenEventKeyEvictionBatch)
        for stale in seenEventKeyOrder.prefix(dropCount) {
            seenEventKeys.remove(stale)
        }
        seenEventKeyOrder.removeFirst(dropCount)
    }

    mutating func replaceNodes(
        _ nodes: [CognitiveNode],
        decayAnchorsByID: [UUID: Date] = [:],
        configuration: CognitiveConfiguration
    ) {
        nodesByKey.removeAll(keepingCapacity: true)
        decayAnchorsByKey.removeAll(keepingCapacity: true)
        nonLiveNodeKeys.removeAll(keepingCapacity: true)
        seenEventKeys.removeAll(keepingCapacity: true)
        seenEventKeyOrder.removeAll(keepingCapacity: true)
        associationTokensByKey.removeAll(keepingCapacity: true)
        turnKindByNodeID.removeAll(keepingCapacity: true)
        for node in nodes {
            // Restore honors CognitiveNode's defensive inference (an explicit
            // live marker cannot override diagnostic text signals). This scan
            // runs once per bounded restored node, never on the hot spread path.
            let turnKind = node.turnKind
            let key = nodeKey(
                kind: node.kind,
                subject: node.subjectReference,
                turnKind: turnKind
            )
            nodesByKey[key] = node
            // `lastActivatedAt` is semantic recency, not the decay checkpoint.
            // SQLite's row `updated_at` is the exact instant the already-decayed
            // value was materialized. Keeping the two separate prevents restore
            // from applying the pre-checkpoint interval a second time.
            decayAnchorsByKey[key] = max(
                node.lastActivatedAt,
                decayAnchorsByID[node.id] ?? node.lastActivatedAt
            )
            if !turnKind.contributesToLivedState {
                nonLiveNodeKeys.insert(key)
            }
            associationTokensByKey[key] = associationTokens(for: node)
            turnKindByNodeID[node.id] = turnKind
        }
        associationWeights.removeAll(keepingCapacity: true)
        enforceCapacity(configuration.maximumActiveNodes)
    }

    mutating func clear() {
        nodesByKey.removeAll(keepingCapacity: false)
        decayAnchorsByKey.removeAll(keepingCapacity: false)
        nonLiveNodeKeys.removeAll(keepingCapacity: false)
        seenEventKeys.removeAll(keepingCapacity: false)
        seenEventKeyOrder.removeAll(keepingCapacity: false)
        associationWeights.removeAll(keepingCapacity: false)
        associationTokensByKey.removeAll(keepingCapacity: false)
        turnKindByNodeID.removeAll(keepingCapacity: false)
    }

    mutating func associationEdges(at now: Date, configuration: CognitiveConfiguration) -> [CognitiveAssociationEdge] {
        applyDecay(at: now)
        enforceCapacity(configuration.maximumActiveNodes)
        var edges: [CognitiveAssociationEdge] = []
        for fromKey in associationWeights.keys.sorted() {
            guard let from = nodesByKey[fromKey] else { continue }
            for toKey in (associationWeights[fromKey] ?? [:]).keys.sorted() {
                guard fromKey < toKey,
                      let to = nodesByKey[toKey],
                      let weight = associationWeights[fromKey]?[toKey] else {
                    continue
                }
                edges.append(CognitiveAssociationEdge(
                    fromNodeId: from.id,
                    toNodeId: to.id,
                    weight: weight,
                    reasons: associationReasons(from: from, to: to)
                ))
            }
        }
        return edges.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return $0.id < $1.id
        }
    }

    private mutating func applyDecay(
        at now: Date,
        matchingLivedState: Bool? = nil
    ) {
        for key in nodesByKey.keys {
            guard var node = nodesByKey[key] else { continue }
            if let matchingLivedState {
                if matchingLivedState {
                    if !nonLiveNodeKeys.isEmpty, nonLiveNodeKeys.contains(key) { continue }
                } else if !nonLiveNodeKeys.contains(key) {
                    continue
                }
            }
            let anchor = decayAnchorsByKey[key] ?? node.lastActivatedAt
            let elapsed = max(0, now.timeIntervalSince(anchor))
            guard elapsed > 0, node.decayHalfLife > 0 else { continue }
            let factor = pow(0.5, elapsed / node.decayHalfLife)
            node.activation = clamp(node.activation * factor)
            node.salience = clamp(node.salience * factor)
            nodesByKey[key] = node
            decayAnchorsByKey[key] = now
        }
    }

    private mutating func enforceCapacity(_ maximumActiveNodes: Int) {
        let cap = max(1, maximumActiveNodes)
        guard nodesByKey.count > cap else { return }
        let hasNonLiveNodes = !nonLiveNodeKeys.isEmpty
        let victims = nodesByKey
            .sorted { lhs, rhs in
                if hasNonLiveNodes {
                    let lhsLived = !nonLiveNodeKeys.contains(lhs.key)
                    let rhsLived = !nonLiveNodeKeys.contains(rhs.key)
                    if lhsLived != rhsLived {
                        // Audit traffic yields before lived state regardless of its
                        // importance, so a diagnostic burst cannot evict attention.
                        return !lhsLived
                    }
                }
                if lhs.value.salience != rhs.value.salience {
                    return lhs.value.salience < rhs.value.salience
                }
                if lhs.value.activation != rhs.value.activation {
                    return lhs.value.activation < rhs.value.activation
                }
                if lhs.value.lastActivatedAt != rhs.value.lastActivatedAt {
                    return lhs.value.lastActivatedAt < rhs.value.lastActivatedAt
                }
                return lhs.value.id.uuidString < rhs.value.id.uuidString
            }
            .prefix(nodesByKey.count - cap)
            .map(\.key)
        for key in victims {
            if let id = nodesByKey[key]?.id {
                turnKindByNodeID.removeValue(forKey: id)
            }
            nodesByKey.removeValue(forKey: key)
            decayAnchorsByKey.removeValue(forKey: key)
            nonLiveNodeKeys.remove(key)
            associationTokensByKey.removeValue(forKey: key)
            associationWeights.removeValue(forKey: key)
            for source in associationWeights.keys {
                associationWeights[source]?.removeValue(forKey: key)
            }
        }
    }

    private mutating func spreadActivation(
        from key: String,
        event: CognitiveEvent,
        input: Double,
        configuration: CognitiveConfiguration
    ) {
        guard nodesByKey.count > 1, let source = nodesByKey[key] else { return }
        let sourceTokens = (associationTokensByKey[key] ?? associationTokens(for: source))
            .union(significantTokens(in: event.summary))
        var boosted: [(key: String, weight: Double)] = []
        let hasNonLiveNodes = !nonLiveNodeKeys.isEmpty
        for otherKey in nodesByKey.keys where otherKey != key {
            guard var node = nodesByKey[otherKey] else { continue }
            if hasNonLiveNodes, nonLiveNodeKeys.contains(otherKey) { continue }
            let weight = associationWeight(
                source: source,
                target: node,
                event: event,
                sourceTokens: sourceTokens,
                targetTokens: associationTokensByKey[otherKey] ?? associationTokens(for: node)
            )
            guard weight >= 0.15 else { continue }
            let stored = max(associationWeights[key]?[otherKey] ?? 0, weight)
            associationWeights[key, default: [:]][otherKey] = stored
            associationWeights[otherKey, default: [:]][key] = stored
            // Wave F: felt memories nudge emotionally congruent felt neighbors a
            // little harder — activation only, facilitation-only (see constant doc).
            // Gated on affectEnabled like every other affect path: stale persisted
            // tags must not keep steering spread after User turns affect off.
            let whisper = configuration.affectEnabled
                ? Self.affectiveSpreadMaxWhisper * Self.affectiveCongruence(source, node)
                : 0
            node.activation = clamp(node.activation + input * stored * 0.18 * (1 + whisper))
            node.salience = clamp(node.salience + input * stored * 0.10)
            nodesByKey[otherKey] = node
            boosted.append((otherKey, stored))
        }
        if boosted.count > configuration.maximumWorkspaceItems * 4 {
            let keep = Set(boosted.sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return lhs.key < rhs.key
            }
            .prefix(configuration.maximumWorkspaceItems * 4)
            .map(\.key))
            for (otherKey, _) in boosted where !keep.contains(otherKey) {
                associationWeights[key]?.removeValue(forKey: otherKey)
                associationWeights[otherKey]?.removeValue(forKey: key)
            }
        }
    }

    private func associationWeight(
        source: CognitiveNode,
        target: CognitiveNode,
        event: CognitiveEvent,
        sourceTokens: Set<String>,
        targetTokens: Set<String>
    ) -> Double {
        var weight = 0.0
        if source.subjectReference.type == target.subjectReference.type {
            weight += 0.12
        }
        let sharedMetadataKeys = ["sessionId", "runId", "missionId", "toolName", "surface"]
        for key in sharedMetadataKeys {
            if let lhs = event.metadata[key], let rhs = target.metadata[key], lhs == rhs {
                weight += 0.22
            }
        }
        if !sourceTokens.isEmpty, !targetTokens.isEmpty {
            let overlap = sourceTokens.intersection(targetTokens)
            let denominator = max(1, min(sourceTokens.count, targetTokens.count))
            weight += min(0.5, Double(overlap.count) / Double(denominator) * 0.5)
        }
        return clamp(weight)
    }

    private func associationReasons(from: CognitiveNode, to: CognitiveNode) -> [String] {
        var reasons: [String] = []
        if from.subjectReference.type == to.subjectReference.type {
            reasons.append("subject-type")
        }
        for key in ["sessionId", "runId", "missionId", "toolName", "surface"] {
            if from.metadata[key] == to.metadata[key], from.metadata[key] != nil {
                reasons.append(key)
            }
        }
        if !significantTokens(in: from.summary).isDisjoint(with: significantTokens(in: to.summary)) {
            reasons.append("summary-token-overlap")
        }
        return reasons
    }

    private func significantTokens(in text: String) -> Set<String> {
        let stop: Set<String> = [
            "about", "after", "also", "because", "from", "should", "that",
            "this", "with", "will", "your", "nativeagent",
        ]
        let cleaned = text.lowercased().map { char -> Character in
            char.isLetter || char.isNumber ? char : " "
        }
        return Set(String(cleaned)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !stop.contains($0) })
    }

    private func associationTokens(for node: CognitiveNode) -> Set<String> {
        significantTokens(in: [
            node.summary,
            node.subjectReference.label ?? node.subjectReference.id,
        ].joined(separator: " "))
    }

    private func nodeKey(
        kind: CognitiveNodeKind,
        subject: CognitiveSubjectReference,
        turnKind: CognitiveTurnKind? = nil
    ) -> String {
        let base = "\(kind.rawValue)|\(subject.stableKey)"
        guard let turnKind, !turnKind.contributesToLivedState else { return base }
        // Preserve the pre-existing key space for lived state. Only diagnostic
        // traffic receives a partition suffix, so it cannot reactivate, rewrite,
        // or demote a live/system node that happens to share the same subject.
        return "\(base)|turnKind:\(turnKind.rawValue)"
    }

    private func eventActivationInput(_ importance: Double) -> Double {
        clamp(0.2 + (importance).clamped01() * 0.8)
    }

    private func confidenceSeed(for source: CognitiveSourceClass) -> Double {
        switch source {
        case .observed, .verified: return 0.9
        case .userStated: return 0.85
        case .imported: return 0.7
        case .inferred: return 0.55
        case .selfReported: return 0.5
        case .dreamed, .simulated: return 0.35
        }
    }

    private func strongerSource(lhs: CognitiveSourceClass, rhs: CognitiveSourceClass) -> CognitiveSourceClass {
        confidenceSeed(for: rhs) > confidenceSeed(for: lhs) ? rhs : lhs
    }

    private func mergeMetadata(
        existing: [String: JSONValue],
        incoming: [String: JSONValue],
        configuration: CognitiveConfiguration
    ) -> [String: JSONValue] {
        guard configuration.maximumMetadataKeys > 0 else { return [:] }
        var merged = existing
        for key in incoming.keys.sorted() {
            merged[key] = incoming[key]
        }
        var out: [String: JSONValue] = [:]
        for key in Self.orderedMetadataKeys(merged).prefix(configuration.maximumMetadataKeys) {
            out[key] = merged[key]
        }
        return out
    }

    private func clamp(_ value: Double) -> Double {
        value.clamped01()
    }

    private static func snapshotSort(_ lhs: CognitiveNode, _ rhs: CognitiveNode) -> Bool {
        if lhs.activation != rhs.activation { return lhs.activation > rhs.activation }
        if lhs.salience != rhs.salience { return lhs.salience > rhs.salience }
        if lhs.lastActivatedAt != rhs.lastActivatedAt { return lhs.lastActivatedAt > rhs.lastActivatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func boundedMetadata(
        _ metadata: [String: JSONValue],
        configuration: CognitiveConfiguration
    ) -> [String: JSONValue] {
        guard configuration.maximumMetadataKeys > 0 else { return [:] }
        var out: [String: JSONValue] = [:]
        for key in orderedMetadataKeys(metadata).prefix(configuration.maximumMetadataKeys) {
            let value = metadata[key] ?? .null
            out[key] = key == CognitiveTurnKind.metadataKey
                ? value
                : JSONValueBounding.bounded(
                    value,
                    bounds: OrganismMetadataBounds(
                        maximumKeys: 8,
                        maximumStringCharacters: configuration.maximumMetadataStringCharacters,
                        maximumArrayItems: 8,
                        maximumDepth: JSONValueBounding.uncappedDepth
                    ),
                    redactSecrets: true,
                    keyPath: key.lowercased()
                )
        }
        return out
    }

    private static func boundedString(_ string: String, maxCharacters: Int) -> String {
        guard maxCharacters >= 0, string.count > maxCharacters else { return string }
        return String(string.prefix(maxCharacters))
    }

    private static func orderedMetadataKeys(_ metadata: [String: JSONValue]) -> [String] {
        let priority = [
            CognitiveTurnKind.metadataKey,
            // Mind-into-circulation (2026-07-10): the felt-memory bridge —
            // attentionSignals maps these record ids to context activation;
            // dropped under the key cap, that channel silently goes dark.
            "memoryRecordIds",
            "sessionId",
            "runId",
            "messageId",
            "surface",
            "role",
            "source",
            "toolName",
            "event_class",
        ]
        let presentPriority = priority.filter { metadata[$0] != nil }
        let prioritySet = Set(presentPriority)
        return presentPriority + metadata.keys.sorted().filter { !prioritySet.contains($0) }
    }

}
