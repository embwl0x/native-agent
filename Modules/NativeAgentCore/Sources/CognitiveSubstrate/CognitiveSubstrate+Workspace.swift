import Foundation
import NativeAgentCore
// Blueprint: | `CognitiveSubstrate+Workspace.swift` | `CognitiveSubstrate`: `workspaceSnapshot`, `frozenRead` |

extension CognitiveSubstrate {
    /// Build a workspace from the exact field settlement already owned by the
    /// caller. A microcycle uses this once-settled node set for both selection
    /// and durability, avoiding a second full 256-node decay/sort at the same
    /// timestamp without changing canonical state.
    func workspaceSnapshot(
        at now: Date,
        settledNodes: [CognitiveNode]
    ) -> CognitiveWorkspaceSnapshot {
        guard configuration.enabled else {
            return CognitiveWorkspaceSnapshot(generatedAt: now, items: [])
        }
        let associatedNodeIds = field.associatedNodeIDs()
        // Capture mood and affect once for selection and reasons.
        let dyn = dynamics
        let currentAffect = projectedAffect(at: now, dynamics: dyn)
        let mood = derivedMood(at: now, dynamics: dyn, affect: currentAffect)
        return makeWorkspaceSnapshot(
            at: now,
            nodes: settledNodes,
            associatedNodeIds: associatedNodeIds,
            mood: mood,
            affect: currentAffect
        )
    }

    /// Settle one copied continuity field at an explicit timestamp. The
    /// resulting snapshot/workspace may be rendered into a frozen provider
    /// packet without advancing the live field's decay anchors.
    public func frozenRead(at fixedAt: Date) async -> CognitiveFrozenRead {
        let frozenConfiguration = configuration
        let frozenDynamics = dynamics
        let fixedAffect = projectedAffect(at: fixedAt, dynamics: frozenDynamics)
        let fixedMood = derivedMood(at: fixedAt, dynamics: frozenDynamics, affect: fixedAffect)
        // Sound selection must happen after the capsule has derived this turn's
        // actual felt mode/valence. Capture its immutable inputs here instead of
        // preselecting with nil/default register values.
        let frozenSoundLandingScores = soundLandingScoreSnapshot()
        let frozenPresentationState = capsulePresentationState
        let frozenSuppressions = associationSuppressions
        let peerIds = Set(field.peekNodes().compactMap { Self.peerIdentity(metadata: $0.metadata, dataRoot: conversationDataRoot) })
        let frozenTrustedPeers = Set(peerIds.filter { dependencies.peerTrusted($0) })
        // Curiosity is workspace-relative, so it is captured below where
        // the frozen workspace is known; the other two are workspace-independent.
        let frozenFatigue = substrateFatigueProxy(at: fixedAt)
        let frozenClarity = substrateClarityProxy(affect: fixedAffect, at: fixedAt)
        var copiedField = field
        let settledNodes = frozenConfiguration.enabled
            ? copiedField.snapshot(at: fixedAt, configuration: frozenConfiguration) : []
        let snapshot = CognitiveSubstrateSnapshot(
            generatedAt: fixedAt,
            enabled: frozenConfiguration.enabled,
            maximumActiveNodes: frozenConfiguration.maximumActiveNodes,
            nodes: settledNodes,
            persistenceHealth: persistenceHealth
        )
        let workspace: CognitiveWorkspaceSnapshot
        if frozenConfiguration.enabled, ablations["workspace"] != false {
            workspace = makeWorkspaceSnapshot(
                at: fixedAt,
                nodes: settledNodes,
                associatedNodeIds: copiedField.associatedNodeIDs(),
                mood: fixedMood,
                affect: fixedAffect
            )
        } else {
            workspace = CognitiveWorkspaceSnapshot(generatedAt: fixedAt, items: [])
        }
        return CognitiveFrozenRead(
            fixedAt: fixedAt,
            configuration: frozenConfiguration,
            personalityDynamics: frozenDynamics,
            snapshot: snapshot,
            workspace: workspace,
            affect: fixedAffect,
            mood: fixedMood,
            feltProxies: CognitiveFeltProxyReads(
                fatigue: frozenFatigue,
                // Curiosity is novelty of what she is HOLDING, so it is captured
                // against the frozen workspace — the same items the capsule
                // renders from.
                curiosity: substrateCuriosityProxy(
                    from: workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) },
                    at: fixedAt),
                clarity: frozenClarity),
            soundLandingScores: frozenSoundLandingScores,
            capsulePresentationState: frozenPresentationState,
            associationSuppressions: frozenSuppressions,
            trustedPeerIds: frozenTrustedPeers,
            mindEpoch: mindEpoch,
            cares: Array(cares.values)
        )
    }

    private func makeWorkspaceSnapshot(
        at now: Date,
        nodes: [CognitiveNode],
        associatedNodeIds: Set<UUID>,
        mood: CognitiveMoodReading,
        affect currentAffect: CognitiveAffectState
    ) -> CognitiveWorkspaceSnapshot {
        // Classify and score candidates before materializing selected reasons.
        let scored = nodes.filter { workspaceEligible($0) }.map { node in
            (
                node: node,
                score: workspaceScore(
                    for: node,
                    mood: mood,
                    affect: currentAffect
                )
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.node.lastActivatedAt != rhs.node.lastActivatedAt {
                return lhs.node.lastActivatedAt > rhs.node.lastActivatedAt
            }
            return lhs.node.id.uuidString < rhs.node.id.uuidString
        }

        var kept: [CognitiveWorkspaceItem] = []
        var inhibited: [UUID] = []
        var seenSubjects: Set<String> = []
        var keptSystemItems = 0
        // Bound each session's user turns while storage remains per turn.
        var userTurnsPerSession: [String: Int] = [:]
        let maximumUserTurnsPerSession = 2
        let maximumSystemItems = max(1, min(3, configuration.maximumWorkspaceItems / 3))
        var processedCount = 0
        for candidate in scored {
            processedCount += 1
            let subjectKey = candidate.node.subjectReference.stableKey
            if seenSubjects.contains(subjectKey) {
                inhibited.append(candidate.node.id)
                continue
            }
            if candidate.node.subjectReference.type == "chat.user_turn" {
                let sessionKey = candidate.node.metadata["sessionId"].flatMap { v -> String? in
                    if case .string(let sid) = v { return sid }
                    return nil
                } ?? "unknown"
                let count = userTurnsPerSession[sessionKey, default: 0]
                if count >= maximumUserTurnsPerSession {
                    inhibited.append(candidate.node.id)
                    continue
                }
                userTurnsPerSession[sessionKey] = count + 1
            }
            if candidate.node.turnKind == .system,
               keptSystemItems >= maximumSystemItems {
                inhibited.append(candidate.node.id)
                continue
            }
            seenSubjects.insert(subjectKey)
            kept.append(CognitiveWorkspaceItem(
                node: candidate.node,
                score: candidate.score,
                reasons: workspaceReasons(
                    for: candidate.node,
                    associatedNodeIds: associatedNodeIds,
                    mood: mood,
                    affect: currentAffect
                )
            ))
            if candidate.node.turnKind == .system {
                keptSystemItems += 1
            }
            if kept.count >= configuration.maximumWorkspaceItems { break }
        }
        if scored.count > processedCount {
            inhibited.append(contentsOf: scored.dropFirst(processedCount).map { $0.node.id })
        }
        return CognitiveWorkspaceSnapshot(generatedAt: now, items: kept, inhibitedNodeIds: inhibited)
    }

    func evictSpentVerificationNodes(before event: CognitiveEvent, at now: Date) -> Int {
        guard verificationNodeMayExist else { return 0 }
        guard event.turnKind == .live,
              let currentSessionId = event.sessionId,
              !currentSessionId.isEmpty else {
            return 0
        }
        let evicted = field.evictNodes { node in
            guard node.turnKind == .verification else { return false }
            let nodeSessionId = node.sessionId
            if let nodeSessionId, !nodeSessionId.isEmpty, nodeSessionId != currentSessionId {
                return true
            }
            return verificationNodeExpired(node, currentSessionId: currentSessionId, at: now)
        }
        if evicted > 0 {
            verificationNodeMayExist = field.containsNode { $0.turnKind == .verification }
        }
        return evicted
    }

    func workspaceEligible(_ node: CognitiveNode) -> Bool {
        node.turnKind.contributesToLivedState
    }

    func capsuleEligibleWorkspaceNode(_ node: CognitiveNode) -> Bool {
        guard node.turnKind == .live else { return false }
        guard !isAssistantAuthoredFocus(node) else { return false }
        switch node.kind {
        case .conversationFocus, .correction:
            return !isCapsuleMetaOrOperationalTrace(node)
        case .toolObservation, .providerHealth, .workshopExecution, .appLifecycle, .feltResolution:
            return false
        }
    }

    private func isAssistantAuthoredFocus(_ node: CognitiveNode) -> Bool {
        if metadataString(node.metadata["role"])?.lowercased() == "assistant" {
            return true
        }
        let subjectType = node.subjectReference.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return subjectType == "chat.assistant_turn"
    }

    private func isCapsuleMetaOrOperationalTrace(_ node: CognitiveNode) -> Bool {
        let signals = [
            node.kind.rawValue,
            node.subjectReference.type,
            node.subjectReference.id,
            node.subjectReference.label ?? "",
            node.summary,
        ] + node.metadata.keys.sorted().flatMap { key -> [String] in
            [key] + CognitiveMetadataSignals.stringSignals(from: node.metadata[key] ?? .null)
        }
        let haystack = signals
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let markers = [
            "[cognitivesubstrate]",
            "cognitive capsule:",
            "cognition_microcycle",
            "cognitive_microcycle",
            "context.snapshot",
            "ctx-snapshot",
            "turncontext",
            "capsule injection",
            "cognitive preview",
            "rejectmemoryproposal",
            "memoryproposal rejected",
            "ios rejectmemoryproposal",
            "subconscious context is provisional runtime state",
            "provisional runtime state to read",
        ]
        return markers.contains { haystack.contains($0) }
    }

    private func verificationNodeExpired(
        _ node: CognitiveNode,
        currentSessionId: String?,
        at now: Date
    ) -> Bool {
        if let currentSessionId,
           let nodeSessionId = node.sessionId,
           !currentSessionId.isEmpty,
           !nodeSessionId.isEmpty,
           nodeSessionId != currentSessionId {
            return true
        }
        let age = max(0, now.timeIntervalSince(node.lastActivatedAt))
        return age >= Self.verificationWorkspaceMaxAge
    }

    func workspaceScore(
        for node: CognitiveNode,
        mood: CognitiveMoodReading,
        affect currentAffect: CognitiveAffectState
    ) -> Double {
        let kindBoost: Double
        switch node.kind {
        case .correction: kindBoost = 0.15
        case .workshopExecution: kindBoost = 0.12
        case .providerHealth, .toolObservation: kindBoost = 0.08
        case .conversationFocus: kindBoost = 0.05
        case .appLifecycle: kindBoost = 0
        case .feltResolution: kindBoost = 0.06
        }
        let affectBoost = configuration.enabled
            ? min(0.12, currentAffect.taskPressure * 0.08 + currentAffect.uncertainty * 0.04)
            : 0
        // Mood congruence applies only to felt nodes under a non-neutral mood.
        let congruence = moodCongruence(for: node, mood: mood)
        let base = node.activation * 0.45 + node.salience * 0.35 + node.confidence * 0.2 + kindBoost + affectBoost + congruence
        let turnKindMultiplier: Double
        switch node.turnKind {
        case .live: turnKindMultiplier = 1
        case .system: turnKindMultiplier = 0.5
        case .debug: turnKindMultiplier = 0.05
        case .verification: turnKindMultiplier = 0.18
        // Card copy is real product text and stays findable, but it is
        // boilerplate she emitted, not something she has to think about.
        case .mechanical: turnKindMultiplier = 0.1
        }
        return (base * turnKindMultiplier).clamped01()
    }

    private func workspaceReasons(
        for node: CognitiveNode,
        associatedNodeIds: Set<UUID>,
        mood: CognitiveMoodReading,
        affect currentAffect: CognitiveAffectState
    ) -> [String] {
        var reasons = ["activation", "salience"]
        if node.confidence >= 0.8 { reasons.append("high-confidence") }
        if node.kind == .correction { reasons.append("correction-priority") }
        let turnKind = node.turnKind
        if turnKind != .live { reasons.append("turn-\(turnKind.rawValue)") }
        if configuration.enabled && currentAffect.taskPressure > 0.4 { reasons.append("task-pressure") }
        if associatedNodeIds.contains(node.id) { reasons.append("spreading-activation") }
        // Name meaningful mood-congruent contributions in the provenance.
        if moodCongruence(for: node, mood: mood) > Self.moodCongruenceReasonThreshold {
            reasons.append("mood-congruent")
        }
        return reasons
    }
}
