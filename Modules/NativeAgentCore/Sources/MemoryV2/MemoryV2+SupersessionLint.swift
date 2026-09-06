// Supersession lint + fragment-protection, both halves of one complaint she
// filed against her own store (2026-09-01):
//
//   "Retired rules don't leave. The GitHub-API-only rule and its retirement
//    ride in side by side, equal weight. I re-litigate it every time."
//
// Live store the same day: 242 active rows, six of them RETIRED/WITHDRAWN/
// CORRECTION records sitting at `lifecycle = confirmed` right next to the rows
// they retire, which are also `confirmed`. Recall cannot tell which one won.
//
// The lint reads the retirement records the way a person would — the phrase
// they quote, or failing that the row they are unmistakably about — and marks
// the TARGET `corrected` (recall-excluded, ranking factor 0). The retirement
// record itself is never touched: it is the reason, and the reason has to stay
// readable. Nothing here archives or deletes.
//
// The second half is the opposite failure. The 2026-08-24 hygiene pass archived
// "user's dyslexia is a bitch sometimes" (use_count 477) and a Desk v2 row
// (use_count 666) as "mid-thought fragment is not durable memory". A row she
// reached for 477 times is durable BY EVIDENCE, whatever its grammar looks
// like; access outranks a shape heuristic.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Tunables

/// Quoted phrase (path a) must be at least this long to bind a retirement to a
/// target. Shorter quotes ("it", "the rule") match half the store.
public let memorySupersessionQuotedPhraseMinimumLength = 12

/// Cosine floor for the fallback path (b), when the retirement quotes nothing.
///
/// MEASURED, and higher than this store currently reaches: dry-run against a
/// copy of the live store 2026-09-02, the one real pair the quote path cannot
/// see — "CORRECTION (2026-08-16 …): The 2026-08-15 rule 'anything GitHub,
/// always use API access, never the browser' is RETIRED" against "User's
/// standing rule (2026-08-15): anything GitHub goes through Agent's direct
/// GitHub API access" — scores 0.5701, top-1 by a clear margin (runner-up
/// 0.4245) but nowhere near 0.80. So path (b) fires on nothing in today's
/// store; every pair it finds today comes from a quoted phrase. Left at the
/// specified 0.80 rather than tuned in passing — this constant is the one knob,
/// and lowering it is a decision with evidence attached, not a silent edit.
public let memorySupersessionLintCosineFloor: Double = 0.80

/// Two candidates within this of each other at the top are a tie: the lint
/// refuses to guess which row the retirement meant and reports it instead.
public let memorySupersessionLintAmbiguityWindow: Double = 0.02

/// Access signals that veto the "mid-thought fragment" archive. Either one is
/// evidence the row is load-bearing regardless of how it reads.
public let memoryFragmentProtectionUseCount: Int64 = 25
public let memoryFragmentProtectionRecencySeconds: TimeInterval = 14 * 24 * 60 * 60

// MARK: - Shapes

/// One planned retirement. `evidence` says WHICH path found it, because the two
/// paths carry different confidence and a receipt that hides that is useless.
public struct MemorySupersessionPair: Sendable, Equatable {
    public enum Evidence: String, Sendable {
        /// The retirement quotes a phrase that appears in the target verbatim.
        case quotedPhrase = "quoted_phrase"
        /// No usable quote; the target is the single nearest older active row.
        case cosine
    }

    public let retirerId: String
    public let targetId: String
    public let evidence: Evidence

    public init(retirerId: String, targetId: String, evidence: Evidence) {
        self.retirerId = retirerId
        self.targetId = targetId
        self.evidence = evidence
    }
}

public struct MemorySupersessionLintResult: Sendable, Equatable {
    /// Pairs the lint would apply (dry run) or did apply (`apply: true`).
    public let pairs: [MemorySupersessionPair]
    /// Pairs whose write actually landed. Equals `pairs.count` on a clean
    /// apply; 0 on a dry run.
    public let applied: Int
    /// Retirements skipped because their top two candidates tied.
    public let ambiguous: Int

    public init(pairs: [MemorySupersessionPair], applied: Int, ambiguous: Int) {
        self.pairs = pairs
        self.applied = applied
        self.ambiguous = ambiguous
    }
}

// MARK: - Lint

public enum MemorySupersessionLint {

    /// Does this row read as a retirement record?
    ///
    /// Leading keyword only, case-insensitive, with whatever date/parenthetical
    /// the writer put after it ("RETIRED 2026-08-02:", "CORRECTION (2026-08-16,
    /// from User via Codex review):", "CORRECTION to my 2026-07-25 filing").
    /// Word-bounded so "Corrections are cheap" is prose, not a retirement.
    public static func isRetirementRecord(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(
            of: #"^(retired|withdrawn|correction|superseded)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Phrases the retirement quotes, long enough to identify a row.
    /// Both straight and curly quotes — she writes both.
    static func quotedPhrases(in content: String) -> [String] {
        let patterns = [
            #""([^"]+)""#,
            #"'([^']+)'"#,
            "\u{201C}([^\u{201D}]+)\u{201D}",
            "\u{2018}([^\u{2019}]+)\u{2019}",
        ]
        var phrases: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            for match in regex.matches(in: content, range: range) {
                guard match.numberOfRanges > 1,
                      let captured = Range(match.range(at: 1), in: content) else { continue }
                let phrase = String(content[captured])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard phrase.count >= memorySupersessionQuotedPhraseMinimumLength else { continue }
                phrases.append(phrase)
            }
        }
        return phrases
    }

    /// Case- and whitespace-insensitive containment: quotes get re-typed with
    /// different capitalisation and line wrapping, and a lint that misses those
    /// falls back to cosine for no reason.
    static func normalizedForMatch(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// The whole decision, as a pure function over rows, so a test and a dry run
    /// see exactly what an apply would do.
    ///
    /// Target set: ACTIVE, recall-eligible rows strictly older than the
    /// retirement, minus retirement records themselves — a retirement is the
    /// record of what happened, and this pass never retires one.
    public static func plan(actives: [StoredMemory]) -> (pairs: [MemorySupersessionPair], ambiguous: Int) {
        let eligible = actives.filter {
            $0.status == "active" && MemoryLifecycle.isRecallEligible($0.lifecycle)
        }
        let retirers = eligible
            .filter { isRetirementRecord($0.content) }
            .sorted { $0.id < $1.id }
        guard !retirers.isEmpty else { return ([], 0) }
        let retirerIDs = Set(retirers.map(\.id))

        var pairs: [MemorySupersessionPair] = []
        var ambiguous = 0
        var claimed = Set<String>()

        for retirer in retirers {
            guard let retirerDate = MemoryRecallScoring.parseTimestamp(retirer.createdAt) else { continue }
            let candidates = eligible.filter { candidate in
                guard candidate.id != retirer.id, !retirerIDs.contains(candidate.id) else { return false }
                guard !claimed.contains(candidate.id) else { return false }
                guard let created = MemoryRecallScoring.parseTimestamp(candidate.createdAt) else { return false }
                return created < retirerDate
            }
            guard !candidates.isEmpty else { continue }

            // (a) A quoted phrase is the writer telling us which row she meant —
            // but only when it names ONE row. A generic quote ("completed
            // without reply", "did the message actually land") can appear in
            // several older rows, and demoting all of them on one phrase is a
            // bulk edit nobody reviewed. Two or more matches is the same
            // "I cannot tell which" the cosine tie reports, so it lands in the
            // same bucket: skipped, counted, left for a human.
            let phrases = quotedPhrases(in: retirer.content).map(normalizedForMatch)
            if !phrases.isEmpty {
                let quoted = candidates.filter { candidate in
                    let haystack = normalizedForMatch(candidate.content)
                    return phrases.contains { haystack.contains($0) }
                }.sorted { $0.id < $1.id }
                if quoted.count > 1 {
                    ambiguous += 1
                    continue
                }
                if let target = quoted.first {
                    claimed.insert(target.id)
                    pairs.append(MemorySupersessionPair(
                        retirerId: retirer.id, targetId: target.id, evidence: .quotedPhrase
                    ))
                    continue
                }
            }

            // (b) No usable quote: the single nearest older row, and only if
            // nothing else is nearly as close.
            let scored = candidates
                .map { (candidate: $0, cosine: VectorMath.cosine(retirer.embedding, $0.embedding)) }
                .filter { $0.cosine >= memorySupersessionLintCosineFloor }
                .sorted {
                    if $0.cosine != $1.cosine { return $0.cosine > $1.cosine }
                    return $0.candidate.id < $1.candidate.id
                }
            guard let best = scored.first else { continue }
            if scored.count > 1,
               best.cosine - scored[1].cosine <= memorySupersessionLintAmbiguityWindow {
                ambiguous += 1
                continue
            }
            claimed.insert(best.candidate.id)
            pairs.append(MemorySupersessionPair(
                retirerId: retirer.id, targetId: best.candidate.id, evidence: .cosine
            ))
        }
        return (pairs, ambiguous)
    }

    /// Dry run (`apply: false`) returns the plan and writes nothing. Applying
    /// marks each target `corrected` with the existing correction lineage and
    /// stamps `metadata.superseded_by`; the retirement record is left active.
    @discardableResult
    public static func run(
        storage: MemoryStorage,
        apply: Bool
    ) async throws -> MemorySupersessionLintResult {
        let actives = try await storage.listMemories(persona: nil, status: "active", limit: nil)
        let planned = plan(actives: actives)
        guard apply else {
            return MemorySupersessionLintResult(
                pairs: planned.pairs, applied: 0, ambiguous: planned.ambiguous
            )
        }
        var applied = 0
        for pair in planned.pairs {
            // ONE transaction: lifecycle, correction lineage and superseded_by
            // land together or not at all. Two writes could leave a row demoted
            // with no pointer to what demoted it — and `plan` reads the ACTIVE
            // set, which excludes corrected rows, so no later run would ever
            // see the half-written row to repair it.
            let marked = try await storage.markCorrected(
                id: pair.targetId,
                by: pair.retirerId,
                reason: "superseded by retirement record (\(pair.evidence.rawValue))",
                supersededBy: pair.retirerId
            )
            if marked { applied += 1 }
        }
        return MemorySupersessionLintResult(
            pairs: planned.pairs, applied: applied, ambiguous: planned.ambiguous
        )
    }
}

// MARK: - Fragment protection by usage

public enum MemoryFragmentUsageProtection {

    /// Access is evidence. A row recalled `memoryFragmentProtectionUseCount`
    /// times, or used within the last two weeks, is not a "mid-thought
    /// fragment" no matter how the sentence scans — that heuristic reads
    /// grammar, and grammar is the weaker witness of the two.
    public static func isProtected(_ memory: StoredMemory, now: Date) -> Bool {
        if memory.useCount >= memoryFragmentProtectionUseCount { return true }
        guard let lastUsedAt = memory.lastUsedAt,
              let used = MemoryRecallScoring.parseTimestamp(lastUsedAt) else { return false }
        return now.timeIntervalSince(used) <= memoryFragmentProtectionRecencySeconds
    }

    /// How many ALREADY-archived rows this rule would have spared. Reported,
    /// never acted on: un-archiving on its own would be the same unreviewed
    /// bulk edit that created the problem.
    public static func archivedRowsNowProtected(_ archived: [StoredMemory], now: Date) -> Int {
        archived.filter { memory in
            guard case .object(let meta)? = memory.metadata,
                  case .string(let reason)? = meta["hygiene_archive_reason"],
                  reason.contains(MemoryCandidateQuality.midThoughtFragmentReason) else { return false }
            return isProtected(memory, now: now)
        }.count
    }
}
