import Foundation
import PersistenceCore

// Blueprint: | `ContinuityField.swift` | `ContinuityField`: bounded canonical node/association field, event deduplication, activation/decay and emotional-tag blending |

struct ContinuityField: Sendable {
    private var nodesByKey: [String: CognitiveNode] = [:]
    private var decayAnchorsByKey: [String: Date] = [:]
    /// Derived lived/audit partition for spreading, decay and eviction.
    private var nonLiveNodeKeys: Set<String> = []
    private var seenEventKeys: Set<String> = []
    /// FIFO insertion order bounds the dedup set by evicting oldest keys first.
    private var seenEventKeyOrder: [String] = []
    private var associationWeights: [String: [String: Double]] = [:]
    /// Rebuildable lexical index for association spreading. Tokenizing every
    /// bounded summary on every sensory event made the resident hot path
    /// O(nodes * Unicode text length) even though only one node's text changes.
    /// This cache lives beside the canonical nodes, is updated atomically with
    /// them, and is discarded/rebuilt on restore; it owns no memory or policy.
    private var associationTokensByKey: [String: Set<String>] = [:]
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
            node.activation = (node.activation + input * 0.45).clamped01()
            node.salience = (max(node.salience, node.activation * 0.7 + event.importance * 0.3)).clamped01()
            node.confidence = (max(node.confidence, confidence)).clamped01()
            node.sourceClass = strongerSource(lhs: node.sourceClass, rhs: event.sourceClass)
            node.lastActivatedAt = now
            node.summary = boundedSummary.isEmpty ? node.summary : boundedSummary
            node.metadata = mergeMetadata(existing: node.metadata, incoming: boundedMetadata, configuration: configuration)
            nodesByKey[key] = node
            decayAnchorsByKey[key] = now
            associationTokensByKey[key] = associationTokens(for: node)
        } else {
            let node = CognitiveNode(
                id: makeUUID(),
                kind: event.kind.nodeKind,
                subjectReference: event.subject,
                activation: input,
                salience: (input * 0.7 + event.importance * 0.3).clamped01(),
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

    // MARK: - Emotional tag stamping

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

    /// Whether the lived moment `seq` already changed this node's feeling
    /// (its watermark is at or past it). A node evicted since reads false.
    func hasLived(_ seq: UInt64, key: String) -> Bool {
        guard let lived = nodesByKey[key]?.livedSeq else { return false }
        return lived >= seq
    }

    /// Stamp the node's watermark: the lived moment `seq` changed its feeling.
    /// Never lowered.
    mutating func markLived(_ seq: UInt64, key: String) {
        guard var node = nodesByKey[key] else { return }
        node.livedSeq = max(node.livedSeq ?? 0, seq)
        nodesByKey[key] = node
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

    // MARK: - Overnight emotional consolidation

    /// Overnight-consolidation tuning. Named next to the reconsolidation blend rates so
    /// all continuity-field emotional tuning lives in one place. Arousal-only, gentle:
    /// what keeps recurring stays a little alive; a stale high charge softens (the memory
    /// stays). See `consolidateEmotionalArousal`.
    static let overnightRecurredWindow: TimeInterval = 24 * 60 * 60  // "kept mattering"
    static let overnightStaleWindow: TimeInterval = 48 * 60 * 60     // "gone quiet"
    static let overnightReinforceRate = 0.05                         // saturating toward 1
    static let overnightCalmFactor = 0.7                             // charge softens, memory stays
    static let overnightCalmArousalFloor = 0.35                      // only a real charge is worth calming

    // MARK: - Affective spreading

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
        guard source.feltDirection != nil, target.feltDirection != nil else { return 0 }
        let valenceDistance = abs(source.emotionalValence - target.emotionalValence) / 2
        let warmthDistance = abs(source.emotionalWarmth - target.emotionalWarmth)
        return max(0, 1 - (valenceDistance * 0.6 + warmthDistance * 0.4))
    }

    /// Consolidation changes arousal only: recurring felt nodes strengthen and stale strong charges soften.
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
               node.emotionalArousal > 0, node.feltDirection != nil {
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
            removeNode(forKey: key)
        }
        return victims.count
    }

    func containsNode(where predicate: (CognitiveNode) -> Bool) -> Bool {
        nodesByKey.values.contains(where: predicate)
    }

    /// Reads raw nodes without decay, capacity enforcement or sorting; mood reads never advance field state.
    func peekNodes() -> [CognitiveNode] {
        Array(nodesByKey.values)
    }

    /// Reads decayed copies without advancing anchors, enforcing capacity or evicting nodes.
    func peekDecayedNodes(at now: Date) -> [CognitiveNode] {
        nodesByKey.map { key, node in
            decayedNode(node, forKey: key, at: now) ?? node
        }
        .sorted(by: Self.snapshotSort)
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
        for node in nodes {
            // Restore the node's classification and lived/audit partition together.
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
        }
        associationWeights.removeAll(keepingCapacity: true)
        enforceCapacity(configuration.maximumActiveNodes)
    }

    /// Initial restoration may suspend while resident events are accepted.
    /// Their values, decay checkpoints and replay guards take precedence.
    mutating func mergeRestoredNodes(
        _ nodes: [CognitiveNode],
        decayAnchorsByID: [UUID: Date],
        configuration: CognitiveConfiguration
    ) {
        let resident = self
        replaceNodes(nodes, decayAnchorsByID: decayAnchorsByID, configuration: configuration)
        nodesByKey.merge(resident.nodesByKey) { _, live in live }
        decayAnchorsByKey.merge(resident.decayAnchorsByKey) { _, live in live }
        associationTokensByKey.merge(resident.associationTokensByKey) { _, live in live }
        nonLiveNodeKeys = Set(nodesByKey.compactMap { key, node in
            node.turnKind.contributesToLivedState ? nil : key
        })
        seenEventKeys = resident.seenEventKeys
        seenEventKeyOrder = resident.seenEventKeyOrder
        associationWeights = resident.associationWeights
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
        for key in Array(nodesByKey.keys) {
            guard let node = nodesByKey[key] else { continue }
            if let matchingLivedState {
                if matchingLivedState {
                    if !nonLiveNodeKeys.isEmpty, nonLiveNodeKeys.contains(key) { continue }
                } else if !nonLiveNodeKeys.contains(key) {
                    continue
                }
            }
            guard let decayed = decayedNode(node, forKey: key, at: now) else { continue }
            nodesByKey[key] = decayed
            decayAnchorsByKey[key] = now
        }
    }

    private func decayedNode(_ node: CognitiveNode, forKey key: String, at now: Date) -> CognitiveNode? {
        let anchor = decayAnchorsByKey[key] ?? node.lastActivatedAt
        let elapsed = max(0, now.timeIntervalSince(anchor))
        guard elapsed > 0, node.decayHalfLife > 0 else { return nil }
        let factor = pow(0.5, elapsed / node.decayHalfLife)
        var decayed = node
        decayed.activation = (decayed.activation * factor).clamped01()
        decayed.salience = (decayed.salience * factor).clamped01()
        return decayed
    }

    private mutating func removeNode(forKey key: String) {
        nodesByKey.removeValue(forKey: key)
        decayAnchorsByKey.removeValue(forKey: key)
        nonLiveNodeKeys.remove(key)
        associationTokensByKey.removeValue(forKey: key)
        associationWeights.removeValue(forKey: key)
        for source in Array(associationWeights.keys) {
            associationWeights[source]?.removeValue(forKey: key)
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
            removeNode(forKey: key)
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
        for otherKey in Array(nodesByKey.keys) where otherKey != key {
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
            // With affect enabled, felt congruence can only increase neighboring activation.
            let whisper = configuration.enabled
                ? Self.affectiveSpreadMaxWhisper * Self.affectiveCongruence(source, node)
                : 0
            node.activation = (node.activation + input * stored * 0.18 * (1 + whisper)).clamped01()
            node.salience = (node.salience + input * stored * 0.10).clamped01()
            nodesByKey[otherKey] = node
            boosted.append((otherKey, stored))
        }
        let workspaceItems = max(0, configuration.maximumWorkspaceItems)
        let associationCap = workspaceItems > Int.max / 4 ? Int.max : workspaceItems * 4
        if boosted.count > associationCap {
            let keep = Set(boosted.sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return lhs.key < rhs.key
            }
            .prefix(associationCap)
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
        return (weight).clamped01()
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
        (0.2 + (importance).clamped01() * 0.8).clamped01()
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
            // Attention maps these record IDs to context activation; retain them under the metadata key cap.
            "memoryRecordIds",
            "sessionId",
            "runId",
            "messageId",
            "surface",
            "role",
            "source",
            "toolName",
            "event_class",
            // The Sound rut detector's view of a long reply's sign-off.
            "replyCharacterCount",
            "replyTail",
        ]
        let presentPriority = priority.filter { metadata[$0] != nil }
        let prioritySet = Set(presentPriority)
        return presentPriority + metadata.keys.sorted().filter { !prioritySet.contains($0) }
    }

}
