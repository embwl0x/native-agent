import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    @discardableResult
    public func integrateReplay(
        _ input: CognitiveReplayIntegrationInput
    ) async -> CognitiveReplayIntegrationResult {
        (try? await integrateReplayChecked(input)) ?? CognitiveReplayIntegrationResult()
    }

    /// Scheduled replay's checked boundary. All replay artifacts, lineage, and
    /// its receipt commit in one SQLite transaction; in-memory state rolls back
    /// on failure so evidence remains eligible for a later retry.
    @discardableResult
    public func integrateReplayChecked(
        _ input: CognitiveReplayIntegrationInput
    ) async throws -> CognitiveReplayIntegrationResult {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.replayEnabled else { return CognitiveReplayIntegrationResult() }
        let now = dependencies.now()
        let priorEpisodes = episodes
        let priorSchemas = schemaProposals
        let priorTimeline = developmentalTimeline
        let priorDirtySince = dirtySince
        var stagedDirtyRevision = dirtyRevision
        var episodeIds: [UUID] = []
        var schemaProposalIds: [UUID] = []
        var skippedEvidenceIds: [String] = []
        var timelineEventIds: [UUID] = []
        var writes: [CognitiveArtifactWrite] = []
        var stagedEpisodes: [UUID: CognitiveEpisodeReference] = [:]
        var stagedSchemas: [UUID: CognitiveSchemaProposal] = [:]
        var stagedTimeline: [UUID: CognitiveDevelopmentalTimelineEvent] = [:]
        var insertedReplayEvidence: Set<String> = []
        /// Bounded by the `prefix(8)` on the proposal loop below.
        var acceptedIdentityBoundaries: [(title: String, summary: String, evidenceNodeIds: [UUID])] = []

        do {

        for dream in input.dreamEntries.prefix(8) {
            let evidenceId = dreamReplayEvidenceID(dream)
            guard replayEvidenceIds.insert(evidenceId).inserted,
                  episodes.values.contains(where: { $0.externalEvidenceIds.contains(evidenceId) }) == false else {
                skippedEvidenceIds.append(evidenceId)
                continue
            }
            let episode = CognitiveEpisodeReference(
                id: stableArtifactID("episode|\(evidenceId)"),
                title: bounded("Dream replay \(dream.date)", maxCharacters: 120),
                summary: dreamSummary(dream.content),
                occurredAt: dateFromFullDate(dream.date) ?? now,
                externalEvidenceIds: [evidenceId],
                lineageId: bounded("dream:\(dream.date)", maxCharacters: 120)
            )
            episodes[episode.id] = episode
            stagedEpisodes[episode.id] = episode
            insertedReplayEvidence.insert(evidenceId)
            episodeIds.append(episode.id)
            markDirty(at: now)
            writes.append(CognitiveArtifactWrite(
                kind: "episode", id: episode.id, status: "recorded",
                score: 0.5, payload: episode.toJSON()
            ))
            let timeline = recordTimelineEventInMemory(
                kind: .dreamEpisode,
                title: episode.title,
                summary: episode.summary,
                artifactId: episode.id,
                lineageId: episode.lineageId,
                externalEvidenceIds: episode.externalEvidenceIds
            )
            stagedTimeline[timeline.id] = timeline
            writes.append(CognitiveArtifactWrite(
                kind: "developmental_timeline", id: timeline.id, status: "recorded",
                score: 0.5, payload: timeline.toJSON()
            ))
            timelineEventIds.append(timeline.id)
        }

        for proposal in input.remProposals.prefix(8) {
            let evidenceId = remReplayEvidenceID(proposal)
            let status = schemaStatus(from: proposal.status)
            if let existingId = schemaProposals.values.first(where: { $0.externalEvidenceIds.contains(evidenceId) })?.id,
               var existing = schemaProposals[existingId] {
                if existing.status == status {
                    skippedEvidenceIds.append(evidenceId)
                    continue
                }
                existing.status = status
                schemaProposals[existingId] = existing
                stagedSchemas[existing.id] = existing
                // Item 47 (2026-09-01): `recordEpisode` shipped with no
                // production caller. This is the episode boundary the system
                // already HAS — a REM proposal she lived through crossing into
                // accepted is the moment experience becomes identity
                // (NORTHSTAR clause 1's episodic→identity spine). No scheduler
                // invented; the transition already happens right here.
                // Recorded AFTER the commit below so a failed transaction
                // cannot leave an episode for an integration that rolled back.
                if status == .accepted {
                    acceptedIdentityBoundaries.append((
                        title: existing.title,
                        summary: existing.body,
                        evidenceNodeIds: existing.evidenceNodeIds
                    ))
                }
                writes.append(CognitiveArtifactWrite(
                    kind: "schema_proposal", id: existing.id, status: existing.status.rawValue,
                    score: existing.confidence, payload: existing.toJSON()
                ))
                let timeline = recordTimelineEventInMemory(
                    kind: .proposalResolution,
                    title: "Schema proposal \(existing.status.rawValue)",
                    summary: existing.body,
                    artifactId: existing.id,
                    lineageId: existing.lineageId,
                    externalEvidenceIds: existing.externalEvidenceIds
                )
                stagedTimeline[timeline.id] = timeline
                writes.append(CognitiveArtifactWrite(
                    kind: "developmental_timeline", id: timeline.id, status: "recorded",
                    score: 0.5, payload: timeline.toJSON()
                ))
                timelineEventIds.append(timeline.id)
                continue
            }

            let schema = CognitiveSchemaProposal(
                id: stableArtifactID("schema|\(evidenceId)"),
                title: bounded("\(proposal.target) REM proposal", maxCharacters: 120),
                body: bounded(proposal.text.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 500),
                target: bounded(proposal.target.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
                status: status,
                confidence: proposal.confidence,
                createdAt: dateFromInternetDate(proposal.createdAt) ?? now,
                externalEvidenceIds: [evidenceId] + proposal.evidenceDates.map { bounded("dream:\($0)", maxCharacters: 120) },
                lineageId: bounded("rem:\(proposal.id)", maxCharacters: 120)
            )
            guard !schema.body.isEmpty else {
                skippedEvidenceIds.append(evidenceId)
                continue
            }
            schemaProposals[schema.id] = schema
            stagedSchemas[schema.id] = schema
            schemaProposalIds.append(schema.id)
            markDirty(at: now)
            writes.append(CognitiveArtifactWrite(
                kind: "schema_proposal", id: schema.id, status: schema.status.rawValue,
                score: schema.confidence, payload: schema.toJSON()
            ))
            let timeline = recordTimelineEventInMemory(
                kind: .schemaProposal,
                title: schema.title,
                summary: schema.body,
                artifactId: schema.id,
                lineageId: schema.lineageId,
                externalEvidenceIds: schema.externalEvidenceIds
            )
            stagedTimeline[timeline.id] = timeline
            writes.append(CognitiveArtifactWrite(
                kind: "developmental_timeline", id: timeline.id, status: "recorded",
                score: 0.5, payload: timeline.toJSON()
            ))
            timelineEventIds.append(timeline.id)
        }

        let receiptPayload: JSONValue? =
            !writes.isEmpty
            ? .object([
                    "reason": .string(bounded(input.reason, maxCharacters: 120)),
                    "episodeCount": .int(Int64(episodeIds.count)),
                    "schemaProposalCount": .int(Int64(schemaProposalIds.count)),
                    "episodeIds": .array(episodeIds.map { .string($0.uuidString) }),
                    "schemaProposalIds": .array(schemaProposalIds.map { .string($0.uuidString) }),
                    "timelineEventIds": .array(timelineEventIds.map { .string($0.uuidString) }),
                    "artifactIds": .array(writes.map { .string($0.id.uuidString) }),
                ])
            : nil
        stagedDirtyRevision = dirtyRevision
        if configuration.persistenceEnabled {
            guard let store else { throw CognitivePersistenceError.storeUnavailable }
            guard !persistenceWritesBlocked else {
                throw CognitivePersistenceError.writesBlocked(
                    status: persistenceHealth.status,
                    detail: persistenceHealth.failureDetail
                )
            }
            try await store.commitReplayIntegration(
                artifacts: writes,
                receiptPayload: receiptPayload,
                maxArtifacts: artifactCap(configuration),
                at: now
            )
        }
        // G-M2: the replay path writes episodes/schemas/evidence directly (not
        // via the single-item record helpers), so enforce their caps here, after
        // the commit succeeds. Timeline is already capped inside
        // recordTimelineEventInMemory. Newest rows survive; only old ones evict.
        enforceEpisodeCap()
        enforceSchemaProposalCap()
        enforceReplayEvidenceCap()
        // Item 47: the episode boundaries this integration crossed, recorded
        // only now that the integration is durable. `recordEpisode` enforces
        // its own cap and persists its own artifact; a failure there loses an
        // episode, never the integration.
        for boundary in acceptedIdentityBoundaries {
            await recordEpisode(
                title: "Became mine: \(boundary.title)",
                summary: boundary.summary,
                evidenceNodeIds: boundary.evidenceNodeIds
            )
        }
        return CognitiveReplayIntegrationResult(
            episodeIds: episodeIds,
            schemaProposalIds: schemaProposalIds,
            skippedEvidenceIds: skippedEvidenceIds,
            timelineEventIds: timelineEventIds
        )
        } catch {
            // Actor reentrancy permits unrelated mutations while SQLite is
            // committing. Roll back only values still equal to this replay's
            // staged delta; never overwrite a newer concurrent mutation.
            for (id, staged) in stagedEpisodes where episodes[id] == staged {
                if let prior = priorEpisodes[id] { episodes[id] = prior }
                else { episodes.removeValue(forKey: id) }
            }
            for (id, staged) in stagedSchemas where schemaProposals[id] == staged {
                if let prior = priorSchemas[id] { schemaProposals[id] = prior }
                else { schemaProposals.removeValue(forKey: id) }
            }
            for (id, staged) in stagedTimeline where developmentalTimeline[id] == staged {
                if let prior = priorTimeline[id] { developmentalTimeline[id] = prior }
                else { developmentalTimeline.removeValue(forKey: id) }
            }
            for evidenceID in insertedReplayEvidence
            where episodes.values.contains(where: { $0.externalEvidenceIds.contains(evidenceID) }) == false {
                replayEvidenceIds.remove(evidenceID)
            }
            if dirtyRevision == stagedDirtyRevision {
                dirtySince = priorDirtySince
            }
            throw error
        }
    }

    // Agent's subconscious is for feelings / emotions / views / continuity — NOT a task
    // tracker (User, 2026-06-30). The commitment/prediction extraction machinery that once
    // ran here was removed in R8c (2026-07-01); the vestigial assimilate() no-op seam and
    // its ChatOrchestration callers were retired in the follow-up (2026-07-02).

    @discardableResult
    public func recordEpisode(
        title: String,
        summary: String,
        evidenceNodeIds: [UUID] = []
    ) async -> CognitiveEpisodeReference? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.replayEnabled else { return nil }
        let now = dependencies.now()
        let episode = CognitiveEpisodeReference(
            id: dependencies.makeUUID(),
            title: bounded(title.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
            summary: bounded(summary.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 500),
            occurredAt: now,
            evidenceNodeIds: unique(evidenceNodeIds)
        )
        guard !episode.title.isEmpty || !episode.summary.isEmpty else { return nil }
        episodes[episode.id] = episode
        enforceEpisodeCap()
        await persistArtifact(kind: "episode", id: episode.id, status: "recorded", score: 0.5, payload: episode.toJSON())
        return episode
    }

    public func episodeSnapshot() async -> [CognitiveEpisodeReference] {
        episodes.values.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func schemaProposalSnapshot() async -> [CognitiveSchemaProposal] {
        schemaProposals.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func developmentalTimelineSnapshot(limit: Int = 40) async -> [CognitiveDevelopmentalTimelineEvent] {
        developmentalTimeline.values.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    public func resolveSchemaProposal(
        id: UUID,
        accepted: Bool
    ) async -> CognitiveSchemaProposal? {
        // Compatibility no-op for older callers. These rows mirror canonical
        // REM status and never owned an association-model effect. Review must
        // happen through the REM approval path, which writes GROWTH and then
        // returns here through replay integration.
        _ = id
        _ = accepted
        return nil
    }

    @discardableResult
    func recordTimelineEvent(
        kind: CognitiveDevelopmentalTimelineKind,
        title: String,
        summary: String,
        artifactId: UUID?,
        lineageId: String,
        externalEvidenceIds: [String]
    ) async -> CognitiveDevelopmentalTimelineEvent {
        let event = recordTimelineEventInMemory(
            kind: kind,
            title: title,
            summary: summary,
            artifactId: artifactId,
            lineageId: lineageId,
            externalEvidenceIds: externalEvidenceIds
        )
        await persistArtifact(kind: "developmental_timeline", id: event.id, status: "recorded", score: 0.5, payload: event.toJSON())
        return event
    }

    func recordTimelineEventInMemory(
        kind: CognitiveDevelopmentalTimelineKind,
        title: String,
        summary: String,
        artifactId: UUID?,
        lineageId: String,
        externalEvidenceIds: [String]
    ) -> CognitiveDevelopmentalTimelineEvent {
        let now = dependencies.now()
        let event = CognitiveDevelopmentalTimelineEvent(
            id: stableArtifactID("timeline|\(kind.rawValue)|\(artifactId?.uuidString ?? lineageId)|\(bounded(title, maxCharacters: 80))|\(bounded(summary, maxCharacters: 80))"),
            kind: kind,
            title: bounded(title.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
            summary: bounded(summary.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 500),
            occurredAt: now,
            artifactId: artifactId,
            lineageId: bounded(lineageId.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
            subjectId: lineageSubjectId(lineageId),
            instanceId: stableDigest("\(kind.rawValue)|\(lineageId)|\(artifactId?.uuidString ?? "")"),
            forkMetadata: ["fork": "none"],
            externalEvidenceIds: boundedExternalEvidenceIds(externalEvidenceIds)
        )
        developmentalTimeline[event.id] = event
        enforceDevelopmentalTimelineCap()
        return event
    }

    func removeTimelineEventsIfMatching(_ events: [CognitiveDevelopmentalTimelineEvent]) {
        for event in events where developmentalTimeline[event.id] == event {
            developmentalTimeline.removeValue(forKey: event.id)
        }
    }

    func timelineEvents(for artifactId: UUID) -> [CognitiveDevelopmentalTimelineEvent] {
        developmentalTimeline.values.filter { $0.artifactId == artifactId }
    }

    private func dreamReplayEvidenceID(_ dream: CognitiveDreamReplayReference) -> String {
        let file = dream.filename ?? dream.id
        return bounded("dream:\(dream.date):\(file):\(stableDigest(dream.content))", maxCharacters: 180)
    }

    private func remReplayEvidenceID(_ proposal: CognitiveREMProposalReference) -> String {
        bounded("rem:\(proposal.id)", maxCharacters: 180)
    }

    private func dreamSummary(_ content: String) -> String {
        let normalized = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return bounded(normalized, maxCharacters: 500)
    }

    private func schemaStatus(from raw: String) -> CognitiveSchemaProposalStatus {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approved", "accepted", "applied":
            return .accepted
        case "denied", "rejected", "dismissed", "archived":
            return .rejected
        default:
            return .proposed
        }
    }

    private func dateFromFullDate(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date
    }

    private func dateFromInternetDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: raw) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private func boundedExternalEvidenceIds(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in ids {
            let id = bounded(raw.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 180)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count >= 12 { break }
        }
        return out
    }

    private func lineageSubjectId(_ lineageId: String) -> String {
        let trimmed = lineageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        return bounded(trimmed.split(separator: ":").first.map(String.init) ?? trimmed, maxCharacters: 80)
    }
}
