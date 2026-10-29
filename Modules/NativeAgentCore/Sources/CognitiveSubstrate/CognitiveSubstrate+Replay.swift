import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Replay.swift` | `CognitiveSubstrate`: `integrateReplayChecked`; schema status and dated REM resolutions share the inbox's decision snapshot by proposal identity; adoption requires its application claim; unmatched retained history stays explicitly unavailable; retired view/opinion/interest events never enter timeline or growth-week readouts |

extension CognitiveSubstrate {
    /// Scheduled replay's checked boundary. All replay artifacts, lineage, and
    /// its receipt commit in one SQLite transaction; in-memory state rolls back
    /// on failure so evidence remains eligible for a later retry.
    @discardableResult
    public func integrateReplayChecked(
        _ input: CognitiveReplayIntegrationInput
    ) async throws -> CognitiveReplayIntegrationResult {
        await waitForMaintenanceTransition()
        guard configuration.enabled else { return CognitiveReplayIntegrationResult() }
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
            if schemaProposals.values.contains(where: { $0.externalEvidenceIds.contains(evidenceId) }) {
                skippedEvidenceIds.append(evidenceId)
                continue
            }

            let schema = CognitiveSchemaProposal(
                id: stableArtifactID("schema|\(evidenceId)"),
                title: bounded("\(proposal.target) REM proposal", maxCharacters: 120),
                body: bounded(proposal.text.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 500),
                target: bounded(proposal.target.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
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
                kind: "schema_proposal", id: schema.id, status: "referenced",
                score: schema.confidence, payload: schema.toJSON()
            ))
        }

        let receiptPayload: JSONValue? =
            !writes.isEmpty || !input.unavailableEvidence.isEmpty
            ? .object([
                    "reason": .string(bounded(input.reason, maxCharacters: 120)),
                    "unavailableEvidence": .array(input.unavailableEvidence.prefix(16).map {
                        .string(bounded($0, maxCharacters: 240))
                    }),
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
            guard !persistenceHealth.writesBlocked, !forgettingInFlight else {
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

    // Cognition owns feelings and continuity; the Desk owns explicit task tracking.

    public func schemaProposalSnapshot() async -> [CognitiveSchemaProposal] {
        let decisions = await dependencies.decisions()
        return schemaProposals.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.map { proposal in
            var proposal = proposal
            proposal.decision = decisions[String(proposal.lineageId.dropFirst(4))]
            return proposal
        }
    }

    // Canonical timeline source titles also feed developmental recall. Keep
    // those bytes native; growth-week.js owns only the readout projection.
    static func growthRowTitle(for event: CognitiveDevelopmentalTimelineEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.lowercased()
        let namesTheActNotTheThing =
            lower.hasPrefix("schema proposal")
            || lower.hasPrefix("identity proposal")
            || lower.hasSuffix("rem proposal")
        guard namesTheActNotTheThing else { return title }
        // THE FIRST SENTENCE, not the whole lesson. A title is a name; a
        // paragraph in the name slot pushes the verdict and the reason off the
        // end of the line, which is the same failure by another route.
        let lesson = {
            let flat = event.summary.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
        }()
        guard !lesson.isEmpty else { return title }
        guard let stop = lesson.firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) else {
            return lesson
        }
        let sentence = String(lesson[lesson.startIndex...stop])
        // A "sentence" of three words is an abbreviation the scanner tripped
        // on, not a name; keep the whole lesson rather than a stub.
        return sentence.count >= 16 ? sentence : lesson
    }

    /// These immutable titles identify history from the retired view family,
    /// including its opinion and interest statuses. Her story now lives in cares.
    static func isRetiredViewTimelineEvent(_ event: CognitiveDevelopmentalTimelineEvent) -> Bool {
        let title = event.title.lowercased()
        return ["standing view", "opinion formed", "opinion reconsidered", "opinion revised",
                "interest from her hour", "returned to an interest", "out of the current set"]
            .contains(where: title.hasPrefix)
    }

    public func developmentalTimelineSnapshot(limit: Int = 40) async -> [CognitiveDevelopmentalTimelineEvent] {
        developmentalTimelineSnapshot(proposals: await schemaProposalSnapshot(), limit: limit)
    }

    public func developmentalTimelineSnapshot(proposals: [CognitiveSchemaProposal], limit: Int) -> [CognitiveDevelopmentalTimelineEvent] {
        let regenerated = Set(proposals.map(\.lineageId))
        var result = developmentalTimeline.values.compactMap { event -> CognitiveDevelopmentalTimelineEvent? in
            let isProposal = event.kind == .schemaProposal || event.kind == .proposalResolution
            guard !(isProposal && regenerated.contains(event.lineageId)),
                  !Self.isRetiredViewTimelineEvent(event) else { return nil }
            var event = event
            if isProposal && event.lineageId.hasPrefix("rem:") {
                event.externalEvidenceIds.removeAll { $0.hasPrefix("outcome:") }
                event.externalEvidenceIds += growthOutcomeTagIds(for: nil)
                event.summary = "Proposal reference unavailable. Recorded: \(event.summary)"
            }
            return event
        }
        // REM history is a view of its proposal and current decision, including
        // decisions made after the creation left the retained timeline window.
        for proposal in proposals {
            var event = CognitiveDevelopmentalTimelineEvent(
                id: stableArtifactID("proposal|\(proposal.id)"), kind: .schemaProposal,
                title: proposal.title, summary: proposal.body, occurredAt: proposal.createdAt,
                artifactId: proposal.id, lineageId: proposal.lineageId,
                externalEvidenceIds: proposal.externalEvidenceIds)
            let decision = proposal.decision
            if let decision, let stamp = decision.outcome?.at, let at = dateFromInternetDate(stamp) {
                var resolution = event
                resolution.id = stableArtifactID("decision|\(decision.id)")
                resolution.kind = .proposalResolution
                resolution.occurredAt = at
                resolution.title = Self.growthRowTitle(for: event)
                resolution.summary = decision.face?.words ?? ""
                resolution.externalEvidenceIds += growthOutcomeTagIds(for: decision)
                result.append(resolution)
            } else {
                event.externalEvidenceIds += growthOutcomeTagIds(for: decision)
            }
            result.append(event)
        }
        return Array(result.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.prefix(max(0, limit)))
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

    private func dateFromFullDate(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        // A dream's date is the Mac's local day it was keyed to.
        components.timeZone = .current
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date
    }

    private func dateFromInternetDate(_ raw: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(raw)
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
