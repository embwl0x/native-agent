import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Replay.swift` | `CognitiveSubstrate`: `integrateReplayChecked`; schema status and dated REM resolutions share the inbox's checked decision snapshot by proposal identity and read displaced content from the proposal owner; adoption requires its application claim; unmatched or unreadable history stays explicitly unavailable |

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
        var unavailableEvidence = input.unavailableEvidence

        do {

        for dream in input.dreamEntries.prefix(8) {
            let evidenceId = dreamReplayEvidenceID(dream)
            guard let occurredAt = dateFromFullDate(dream.date) else {
                unavailableEvidence.append("\(evidenceId): invalid dream date \(dream.date)")
                continue
            }
            guard replayEvidenceIds.insert(evidenceId).inserted,
                  episodes.values.contains(where: { $0.externalEvidenceIds.contains(evidenceId) }) == false else {
                skippedEvidenceIds.append(evidenceId)
                continue
            }
            let episode = CognitiveEpisodeReference(
                id: stableArtifactID("episode|\(evidenceId)"),
                title: bounded("Dream replay \(dream.date)", maxCharacters: 120),
                summary: dreamSummary(dream.content),
                occurredAt: occurredAt,
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
            guard let createdAt = dateFromInternetDate(proposal.createdAt) else {
                unavailableEvidence.append("\(evidenceId): invalid REM createdAt \(proposal.createdAt)")
                continue
            }
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
                createdAt: createdAt,
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
            !writes.isEmpty || !unavailableEvidence.isEmpty
            ? .object([
                    "reason": .string(bounded(input.reason, maxCharacters: 120)),
                    "unavailableEvidence": .array(unavailableEvidence.prefix(16).map {
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
        await schemaProposalSnapshot(from: Array(schemaProposals.values))
    }

    func schemaProposalSnapshot(from proposals: [CognitiveSchemaProposal]) async -> [CognitiveSchemaProposal] {
        let decisions = await dependencies.decisions()
        let replacements = await dependencies.remReplacements()
        return proposals.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.map { proposal in
            var proposal = proposal
            let id = String(proposal.lineageId.dropFirst(4))
            proposal.decision = decisions.value[id]
            proposal.replacementDescription = replacements.value[id]
                ?? (replacements.unreadable.isEmpty
                    ? "Replaced content: proposal record unavailable"
                    : "Replaced content unavailable: " + replacements.unreadable.joined(separator: "; "))
            if !decisions.unreadable.isEmpty {
                proposal.replacementDescription += "\nDecision history unavailable: " + decisions.unreadable.joined(separator: "; ")
            }
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

    public func developmentalTimelineSnapshot(limit: Int = 40) async -> [CognitiveDevelopmentalTimelineEvent] {
        developmentalTimelineSnapshot(proposals: await schemaProposalSnapshot(), limit: limit)
    }

    public func developmentalTimelineSnapshot(proposals: [CognitiveSchemaProposal], limit: Int) -> [CognitiveDevelopmentalTimelineEvent] {
        developmentalTimelineSnapshot(proposals: proposals, events: Array(developmentalTimeline.values), limit: limit)
    }

    func developmentalTimelineSnapshot(proposals: [CognitiveSchemaProposal], events: [CognitiveDevelopmentalTimelineEvent], limit: Int) -> [CognitiveDevelopmentalTimelineEvent] {
        let regenerated = Set(proposals.map(\.lineageId))
        var result = events.compactMap { event -> CognitiveDevelopmentalTimelineEvent? in
            let isProposal = event.kind == .schemaProposal || event.kind == .proposalResolution
            guard !(isProposal && regenerated.contains(event.lineageId)) else { return nil }
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
                title: proposal.title, summary: proposal.body + "\n\n" + proposal.replacementDescription, occurredAt: proposal.createdAt,
                artifactId: proposal.id, lineageId: proposal.lineageId,
                externalEvidenceIds: proposal.externalEvidenceIds)
            let decision = proposal.decision
            if let decision, let stamp = decision.outcome?.at, let at = dateFromInternetDate(stamp) {
                var resolution = event
                resolution.id = stableArtifactID("decision|\(decision.id)")
                resolution.kind = .proposalResolution
                resolution.occurredAt = at
                resolution.title = Self.growthRowTitle(for: event)
                resolution.summary = (decision.face?.words ?? "") + "\n\n" + proposal.replacementDescription
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
        let fields = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              fields.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let parts = fields.compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        // A dream's date is the Mac's local day it was keyed to.
        components.timeZone = .current
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = components.date else { return nil }
        let actual = components.calendar!.dateComponents(in: .current, from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2] else { return nil }
        return date
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
