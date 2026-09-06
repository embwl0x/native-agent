// CognitiveSubstrate+DevelopmentalRecall.swift
// Item 47 (2026-09-01) — her own change-history becomes REACHABLE.
//
// The measured defect: 275 `developmental_timeline` rows and 59 episodes exist,
// are persisted, are capped, are restored across relaunch — and the only reader
// is the Observatory, a window Agent cannot open. Her lineage was a museum.
//
// The fix is clause 6 shaped, and the direction matters: this is a PULL, never
// an injection. Nothing here reaches a prompt, no capsule line is added, no
// resident packet grows. "When did I start doing X" becomes answerable the way
// remembering is answerable — she asks, and the rows come back as bounded
// pointer-shaped hits (id, kind, title, when, lineage, artifact id, score) —
// and NO body text. Exactly the shape a recall hit already has, so the
// retrieval lane can adopt it without inventing a second row type.
//
// Pure read: no mutation, no persistence, no suspension beyond the actor hop.
// Deterministic: same state and query, same order.

import Foundation
import PersistenceCore

/// One pointer-shaped answer about her own development.
///
/// PAYLOAD-FREE, and that is enforced by what is ABSENT (review fix 3). An
/// earlier draft returned a `preview` cut from the row's summary — but a
/// developmental summary IS dream content and REM proposal text, so the pointer
/// was carrying the payload it was supposed to point at. A pointer answers
/// "when, and which row"; reading the row is a separate, separately-governed
/// act. Matching still SCANS the summary — finding is not disclosing — but no
/// body text leaves this type.
public struct CognitiveDevelopmentalRecallHit: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, Equatable, CaseIterable {
        case timeline
        case episode
    }

    /// Stable pointer id, e.g. `developmental:timeline:<uuid>`. Callers page or
    /// cite by this rather than by the artifact's raw UUID, so the id says what
    /// lane it came from.
    public let id: String
    public let source: Source
    /// `CognitiveDevelopmentalTimelineKind` raw value for timeline rows,
    /// `"episode"` for episodes.
    public let kind: String
    public let title: String
    public let occurredAt: Date
    public let lineageId: String
    /// The artifact this row is about, when it has one: the timeline event's
    /// subject artifact, or the episode itself. The handle a later expansion
    /// would resolve.
    public let artifactId: UUID?
    public let score: Double

    public init(
        id: String,
        source: Source,
        kind: String,
        title: String,
        occurredAt: Date,
        lineageId: String,
        artifactId: UUID?,
        score: Double
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.occurredAt = occurredAt
        self.lineageId = lineageId
        self.artifactId = artifactId
        self.score = score.isFinite ? max(0, score) : 0
    }

    public func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "source": .string(source.rawValue),
            "kind": .string(kind),
            "title": .string(title),
            "occurred_at": .double(occurredAt.timeIntervalSince1970),
            "lineage_id": .string(lineageId),
            "artifact_id": artifactId.map { .string($0.uuidString) } ?? .null,
            "score": .double(score),
        ])
    }
}

extension CognitiveSubstrate {

    // MARK: - Bounds (every read has a ceiling)

    /// Most hits one pull can return. A question about her own history wants a
    /// handful of dated rows, not a transcript of every change she has made.
    public static let developmentalRecallMaximumHits = 10
    public static let developmentalRecallDefaultHits = 5
    /// Longest query text considered. Beyond this the tail cannot change which
    /// rows win, only how long the scan takes.
    static let developmentalRecallMaximumQueryCharacters = 200
    /// Shortest query term that can select a row. Below this everything matches
    /// and the ranking stops meaning anything.
    static let developmentalRecallMinimumTermLength = 3
    /// Terms taken from one query.
    static let developmentalRecallMaximumTerms = 8
    /// A title match is worth more than a body match: the title is what the
    /// lineage CALLED the change.
    static let developmentalRecallTitleWeight = 2.0
    /// Recency only breaks ties. It must never outrank a real term match, so it
    /// is bounded well under the smallest single-term contribution.
    static let developmentalRecallRecencyWeight = 0.25
    /// Age at which the recency term has fully decayed.
    static let developmentalRecallRecencyHorizon: TimeInterval = 180 * 24 * 60 * 60

    // MARK: - The pull

    /// Answer "when did I start doing X" from her own developmental timeline and
    /// episodes. Returns bounded pointer rows, highest score first, ties broken
    /// newest-first then by id so the order is stable.
    ///
    /// An empty query returns her most recent development (the honest reading of
    /// "what has been changing lately"), not everything.
    public func developmentalRecall(
        query: String,
        limit: Int = CognitiveSubstrate.developmentalRecallDefaultHits
    ) async -> [CognitiveDevelopmentalRecallHit] {
        guard configuration.enabled else { return [] }
        let cappedLimit = min(
            max(1, limit),
            Self.developmentalRecallMaximumHits
        )
        let terms = Self.developmentalRecallTerms(in: query)
        let now = dependencies.now()

        var scored: [CognitiveDevelopmentalRecallHit] = []
        scored.reserveCapacity(developmentalTimeline.count + episodes.count)

        for event in developmentalTimeline.values {
            let score = Self.developmentalRecallScore(
                title: event.title,
                body: "\(event.summary) \(event.lineageId)",
                occurredAt: event.occurredAt,
                terms: terms,
                now: now
            )
            guard score > 0 else { continue }
            scored.append(CognitiveDevelopmentalRecallHit(
                id: "developmental:timeline:\(event.id.uuidString)",
                source: .timeline,
                kind: event.kind.rawValue,
                title: event.title,
                occurredAt: event.occurredAt,
                lineageId: event.lineageId,
                artifactId: event.artifactId,
                score: score
            ))
        }

        for episode in episodes.values {
            let score = Self.developmentalRecallScore(
                title: episode.title,
                body: "\(episode.summary) \(episode.lineageId)",
                occurredAt: episode.occurredAt,
                terms: terms,
                now: now
            )
            guard score > 0 else { continue }
            scored.append(CognitiveDevelopmentalRecallHit(
                id: "developmental:episode:\(episode.id.uuidString)",
                source: .episode,
                kind: "episode",
                title: episode.title,
                occurredAt: episode.occurredAt,
                lineageId: episode.lineageId,
                artifactId: episode.id,
                score: score
            ))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.id < rhs.id
        }
        return Array(scored.prefix(cappedLimit))
    }

    // MARK: - Scoring (pure, deterministic, no lexicon)

    /// The distinctive words in a query. Same shape as the appraisal concern
    /// tokenizer — letters and digits only, short words dropped — but no stop
    /// list: a question about her history is a question, not a settled belief,
    /// and dropping "start" from "when did I start doing X" would remove the
    /// only word that matters.
    static func developmentalRecallTerms(in query: String) -> [String] {
        let clipped = String(query.prefix(developmentalRecallMaximumQueryCharacters)).lowercased()
        var seen: Set<String> = []
        var terms: [String] = []
        for raw in clipped.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= developmentalRecallMinimumTermLength else { continue }
            guard seen.insert(word).inserted else { continue }
            terms.append(word)
            if terms.count >= developmentalRecallMaximumTerms { break }
        }
        return terms
    }

    /// Term overlap, title-weighted, with recency as a bounded tiebreak. Returns
    /// 0 for a row no query term touches, so a specific question cannot drag
    /// unrelated history back with it.
    ///
    /// With no terms at all (an empty or all-short query) every row scores its
    /// recency term alone, which is exactly "show me what has been changing".
    static func developmentalRecallScore(
        title: String,
        body: String,
        occurredAt: Date,
        terms: [String],
        now: Date
    ) -> Double {
        let recency: Double = {
            let age = now.timeIntervalSince(occurredAt)
            guard age.isFinite, age >= 0 else { return developmentalRecallRecencyWeight }
            guard age < developmentalRecallRecencyHorizon else { return 0 }
            return developmentalRecallRecencyWeight
                * (1 - age / developmentalRecallRecencyHorizon)
        }()
        guard !terms.isEmpty else { return max(recency, Double.leastNonzeroMagnitude) }

        let loweredTitle = title.lowercased()
        let loweredBody = body.lowercased()
        var matched = 0.0
        for term in terms {
            if loweredTitle.contains(term) {
                matched += developmentalRecallTitleWeight
            } else if loweredBody.contains(term) {
                matched += 1
            }
        }
        guard matched > 0 else { return 0 }
        return matched + recency
    }
}
