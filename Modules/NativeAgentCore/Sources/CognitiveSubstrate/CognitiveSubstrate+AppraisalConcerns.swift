// CognitiveSubstrate+AppraisalConcerns.swift
// COGNITION STEP 1 (APPRAISAL) · D-1 — the concerns that generate her feelings
// come from HER. (2026-08-02)
//
// The measured defect (appraisal-gap-analysis-v2.md, 256 felt nodes / 4 weeks):
// `appraisalConcernLexicon()` returned a hardcoded six-entry array with fixed
// keyword lists, identical on every install, unchanged by anything she had
// lived, valued, or been corrected on. Only `relationship` was personalized (it
// spliced the configured user name). Her User-approved standing views existed and
// were read elsewhere — the appraisal layer never consulted them.
//
// The fix, in one sentence: the shipped six become the FLOOR (a fresh install
// still feels something), and every ACTIVE standing view — the only durable
// belief channel she has, and User-approved by construction — contributes a LIVED
// concern that weighs MORE than any shipped default.
//
// Invariants held: derived at READ TIME from state that already exists (no new
// persisted axis, no second store, no new sense) · pure and synchronous, so it
// stays callable inside the await-free ingest segment · bounded (a hard cap on
// lived concerns and on terms per concern) · zero active views degrades to
// byte-identical floor behaviour.

import Foundation

extension CognitiveSubstrate {

    // MARK: - Model

    /// One thing she cares about, and the words that mean it.
    struct AppraisalConcern: Equatable {
        /// Where this concern came from — the whole point of D-1.
        enum Origin: Equatable {
            /// Shipped default. Present on a fresh install; identical for everyone.
            case floor
            /// Derived from one of HER ACTIVE standing views (User-approved).
            case lived
        }

        let name: String
        let keywords: [String]
        /// 1.0 for the shipped floor; > 1.0 for a concern she formed by living,
        /// scaled by how much evidence the view settled on.
        let weight: Double
        let origin: Origin

        init(name: String, keywords: [String], weight: Double = 1.0, origin: Origin = .floor) {
            self.name = name
            self.keywords = keywords
            self.weight = weight
            self.origin = origin
        }
    }

    // MARK: - Bounds (every add has a remove; the keyspace itself is the bound)

    /// At most this many LIVED concerns ride alongside the floor. The active
    /// standing-view cap is 5 today, so this can only bind if that cap moves.
    static let appraisalLivedConcernCap = 8
    /// Terms taken from any one view. A view is prose; six distinctive words is
    /// a concern, sixty is a search index.
    static let appraisalLivedConcernTermCap = 6
    /// Shortest word that can carry a concern. Below this everything matches.
    static let appraisalLivedConcernMinimumTermLength = 5
    /// Ceiling on how far past the floor a lived concern can weigh. She should
    /// trust what she formed more than what shipped — not infinitely more.
    static let appraisalLivedConcernMaximumWeight = 2.0

    // MARK: - The floor

    /// The shipped six. A fresh install with no standing views still feels
    /// something — this is the warm floor, not the whole of what she cares about.
    func appraisalConcernFloor() -> [AppraisalConcern] {
        let configuredUserName = userAddress.lowercased()
        let relationshipKeywords = (configuredUserName == "you" ? [] : [configuredUserName])
            + ["together", "trust", "warm", "with you"]

        return [
            AppraisalConcern(name: "relationship", keywords: relationshipKeywords),
            AppraisalConcern(name: "truth", keywords: ["honest", "verify", "accurate", "truth", "instrument"]),
            AppraisalConcern(name: "followThrough", keywords: ["finish", "follow through", "commit", "promised", "deliver"]),
            AppraisalConcern(name: "repair", keywords: ["fix", "repair", "broke", "recover", "debug"]),
            AppraisalConcern(name: "learning", keywords: ["learn", "understand", "curious", "figure out", "why"]),
            AppraisalConcern(name: "userCare", keywords: ["care", "help", "support", "there for", "look after"]),
        ]
    }

    // MARK: - The derived set (what every appraisal surface now consults)

    /// Her concern set: the floor, plus one LIVED concern per ACTIVE standing
    /// view, ordered heaviest-first and deterministic. Pure — same state, same
    /// answer; no suspension, so the ingest hot segment can call it.
    ///
    /// The relationship floor concern additionally leans on the relationship's
    /// current state: sustained social warmth makes the relationship concern
    /// weigh more, because it demonstrably matters more right now. That lean is
    /// bounded to the same ceiling as a lived concern and can never invert the
    /// order between a lived concern and a shipped one at equal evidence.
    func appraisalConcerns() -> [AppraisalConcern] {
        var out: [AppraisalConcern] = []
        let warmthLean = 1.0 + 0.4 * affect.socialWarmth.clamped01()
        for concern in appraisalConcernFloor() {
            guard !concern.keywords.isEmpty else { continue }
            out.append(AppraisalConcern(
                name: concern.name,
                keywords: concern.keywords,
                weight: concern.name == "relationship"
                    ? min(Self.appraisalLivedConcernMaximumWeight, warmthLean)
                    : 1.0,
                origin: .floor
            ))
        }
        out.append(contentsOf: livedAppraisalConcerns())
        return out
    }

    /// One concern per ACTIVE standing view, keyed by the view's lineage so the
    /// name is stable across a view being revised. Views with no distinctive
    /// terms contribute nothing rather than an empty concern that matches all
    /// text (the failure mode a naive term-split would ship).
    func livedAppraisalConcerns() -> [AppraisalConcern] {
        let active = standingViews.values
            .filter { $0.status == .active }
            .sorted { lhs, rhs in
                // Deterministic under equal timestamps; freshest first so the
                // cap drops the stalest view, not an arbitrary one.
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var out: [AppraisalConcern] = []
        for view in active {
            guard out.count < Self.appraisalLivedConcernCap else { break }
            let terms = Self.appraisalConcernTerms(in: "\(view.title) \(view.body)")
            guard !terms.isEmpty else { continue }
            // Conviction: what the view settled on. Same shape as the stance
            // read already used, lifted above the floor because she formed it.
            let conviction = min(1.0, 0.5 + 0.1 * Double(view.evidenceNodeIds.count))
            out.append(AppraisalConcern(
                name: "view:\(view.lineageId.isEmpty ? view.id.uuidString : view.lineageId)",
                keywords: terms,
                weight: min(
                    Self.appraisalLivedConcernMaximumWeight,
                    1.0 + conviction
                ),
                origin: .lived
            ))
        }
        return out
    }

    /// The distinctive words in a view. Deterministic, bounded, and biased to
    /// long words: a concern must be able to MISS, so common connective prose is
    /// stripped and anything short is dropped. Longest-first then alphabetical
    /// so the same view always yields the same terms.
    static func appraisalConcernTerms(in text: String) -> [String] {
        let lowered = text.lowercased()
        var seen: Set<String> = []
        var candidates: [String] = []
        for raw in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= appraisalLivedConcernMinimumTermLength else { continue }
            guard !appraisalConcernStopWords.contains(word) else { continue }
            guard !seen.contains(word) else { continue }
            seen.insert(word)
            candidates.append(word)
        }
        candidates.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs < rhs
        }
        return Array(candidates.prefix(appraisalLivedConcernTermCap))
    }

    /// Words long enough to survive the length filter but too ordinary to mean
    /// anything. Kept deliberately small — this is a floor against noise, not an
    /// attempt at linguistics.
    static let appraisalConcernStopWords: Set<String> = [
        "about", "after", "again", "against", "along", "already", "also",
        "always", "another", "anything", "around", "because", "been", "before",
        "being", "between", "both", "cannot", "could", "doesn", "doing", "done",
        "during", "each", "either", "enough", "even", "ever", "every",
        "everything", "from", "further", "getting", "going", "have", "having",
        "here", "however", "instead", "into", "itself", "just", "keep", "like",
        "made", "make", "making", "many", "matter", "maybe", "might", "more",
        "most", "much", "must", "myself", "never", "nothing", "often", "only",
        "other", "over", "quite", "rather", "really", "same",
        "should", "since", "some", "someone", "something", "still", "such",
        "than", "that", "their", "them", "then", "there", "these", "they",
        "thing", "things", "think", "this", "those", "though", "through",
        "toward", "under", "until", "upon", "very", "want", "were",
        "what", "when", "where", "whether", "which", "while", "will", "with",
        "within", "without", "would", "your", "yours", "yourself",
    ]

    // MARK: - Matching

    /// Does `text` touch this concern? Substring match, same semantics the
    /// standing-view lens already used — kept identical so the change is in
    /// WHICH concerns exist, not in how a concern is recognised.
    static func concernMatches(_ concern: AppraisalConcern, in loweredText: String) -> Bool {
        concern.keywords.contains { loweredText.contains($0) }
    }

    /// Does `text` touch a concern SHE formed (not one that shipped)? This is the
    /// stake test D-2 leans on: a machine identifier can trip a floor keyword by
    /// accident ("tool:commit_memory" contains "commit"), but it can only trip a
    /// lived concern if one of her own approved views actually names that thing.
    func livedConcernHit(in text: String, concerns: [AppraisalConcern]? = nil) -> Bool {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return false }
        return (concerns ?? appraisalConcerns())
            .contains { $0.origin == .lived && Self.concernMatches($0, in: lower) }
    }
}
