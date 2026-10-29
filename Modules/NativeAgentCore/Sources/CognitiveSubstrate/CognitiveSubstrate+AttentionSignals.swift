// A bounded projection of resident attention for context selection.
// Publication compiles accepted state; cancellation belongs to the turn read.
// Empty attention contributes no packet input.

import Foundation
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+AttentionSignals.swift` | `CognitiveSubstrate.makeAttentionSignals`: pure bounded workspace/question/subject projection for resident handoff publication |

extension CognitiveSubstrate {
    /// Actor-isolated compiler for owner-published resident snapshots.
    func makeAttentionSignals(at date: Date) -> CognitiveAttentionSignals? {
        // Gate exactly the way the capsule path does: disabled cognition adds
        // nothing; workspace off yields no items below.
        guard configuration.enabled else { return nil }

        // Read decayed copies with workspace eligibility and scoring; attention reads never mutate the field.
        let dyn = dynamics
        let currentAffect = projectedAffect(at: date, dynamics: dyn)
        let mood = derivedMood(at: date, dynamics: dyn, affect: currentAffect)
        let hotItems = field.peekDecayedNodes(at: date)
            .filter {
                ablations["workspace"] != false && workspaceEligible($0)
            }
            .map { candidate in
                (
                    node: candidate,
                    score: workspaceScore(
                        for: candidate,
                        mood: mood,
                        affect: currentAffect
                    )
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(max(1, configuration.maximumWorkspaceItems))

        // 1. TERMS — hot subjects, cleaned to human lexical tokens. Weight =
        //    the clamped selection score.
        var terms: [String: Double] = [:]
        for item in hotItems {
            guard let term = Self.lexicalTerm(from: item.node.subjectReference) else { continue }
            terms[term] = max(terms[term] ?? 0, (item.score).clamped01())
        }
        // Summary keywords are score-weighted and discounted below subject-level topics.
        for item in hotItems.prefix(6) {
            // System nodes count toward the hot set but never mint attention terms from machine status text.
            guard item.node.turnKind == .live else { continue }
            let weight = (item.score).clamped01() * 0.8
            for word in Self.summaryKeywords(from: item.node.summary) {
                terms[word] = max(terms[word] ?? 0, weight)
            }
        }

        // 2. UNRESOLVED QUESTION — the pendingCompletion slot, if one is open:
        //    her latest completed turn still waiting to find out how it landed.
        let completion = unresolvedQuestionFromPendingCompletion(at: date)

        // Memory activation carries record IDs; the app projection derives atom IDs.
        var memoryActivation: [String: Double] = [:]
        for item in hotItems {
            let recordIDs = Self.memoryRecordIDs(from: item.node)
            guard !recordIDs.isEmpty else { continue }
            let activation = (item.node.activation).clamped01()
            for recordID in recordIDs {
                memoryActivation[recordID] = max(memoryActivation[recordID] ?? 0, activation)
            }
        }

        let signals = CognitiveAttentionSignals(
            terms: terms,
            unresolvedQuestion: completion?.question,
            completionWindow: completion?.window,
            memoryActivation: memoryActivation,
            suppressedMemory: suppressedMemoryAssociations()
        )
        // Empty → nil, so the default inert path stays byte-identical. Never
        // return an empty struct (that would still be a distinct packet input).
        return signals.isEmpty ? nil : signals
    }

    func publishAttentionProjection(at date: Date) {
        dependencies.attentionProjectionSink(
            makeAttentionSignals(at: date)
        )
    }

    // MARK: - Unresolved question

    /// Phrase the open completion as a short, human "what's unresolved" line.
    /// Returns nil when no slot is open, the slot has aged past
    /// `pendingCompletionMaxAge` (a stale completion is no longer a live
    /// question), or the remembered node was evicted since it was recorded.
    private func unresolvedQuestionFromPendingCompletion(at now: Date) -> (question: String, window: OpenCompletionRead)? {
        guard let window = openCompletion(at: now), let pending = pendingCompletion,
              let node = field.node(forKey: pending.nodeKey) else { return nil }

        let summary = node.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        // The constructor bounds to 200; clip the summary first so the framing
        // prefix always survives the bound.
        let snippet = bounded(summary, maxCharacters: 150)
        return ("Still waiting to see how this landed: \(snippet)", window)
    }

    // MARK: - Subject → lexical term cleaning

    /// Subject `type`s that are MACHINE ROUTING KEYS, not topics. Their id/label
    /// is an opaque handle (`<session>:<message>`, a tool name, a provider id, a
    /// uuid) the lexical ranker can't meaningfully match against persona/memory
    /// text — so they never become terms. Grounded in the real subject formats
    /// this codebase emits:
    ///   - ChatOrchestration message persistence: `chat.user_turn`,
    ///     `chat.assistant_turn`, `chat.session`, `chat.surface` (id =
    ///     `<sessionId>:<messageId>` or a surface/session handle), `tool`
    ///     (id/label = tool name).
    ///   - NativeCognitionRuntime event factory: `chat_turn` (id =
    ///     `<session>:<message>`, label = "<surface> <role>"), `provider`,
    ///     `approval`, `mission_step`, `memory_proposal`, `promotion_candidate`,
    ///     `inbox_item`, `chat_session`, `remote_action`, `ios_action`.
    ///   - Memory-derived nodes: `memory` / `memory_record` (id = record id, an
    ///     opaque digest) — excluded here because their record id is surfaced
    ///     through `memoryActivation`, not as a lexical term.
    /// Any namespaced type (one containing ".") is treated as machine-keyed too:
    /// every namespaced subject in the codebase is a `chat.*` routing key.
    static let machineSubjectTypes: Set<String> = [
        "chat", "chat_turn", "chat_session",
        "chat.user_turn", "chat.assistant_turn", "chat.session", "chat.surface",
        "tool", "provider", "approval",
        "mission_step", "memory_proposal", "promotion_candidate",
        "inbox_item", "remote_action", "ios_action", "app", "image",
        "memory", "memory_record",
    ]

    /// Clean a subject into a human lexical term, or `nil` to EXCLUDE it.
    ///
    /// Rule (documented here because it is the seam's contract):
    ///   1. EXCLUDE machine-keyed subject types outright (see
    ///      `machineSubjectTypes`) — their id/label is a routing handle.
    ///   2. For the remaining subjects (topic, mention, person, Workshop execution, file,
    ///      and any future human-topic type), take the human-facing string —
    ///      the `label` when present, else the `id` — and keep it only if it
    ///      still reads as a topic after cleaning: no `:`-composite handle, not
    ///      a uuid/hex digest, and containing a real alphabetic run.
    /// This strips-or-excludes rather than passing opaque ids through, so terms
    /// stay words the ranker can match.
    static func lexicalTerm(from subject: CognitiveSubjectReference) -> String? {
        let type = subject.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type.isEmpty || type.contains(".") || machineSubjectTypes.contains(type) {
            return nil
        }
        let candidate = (subject.label ?? subject.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        // A ":"-composite is a machine handle (session:message, missionId:stepId).
        if candidate.contains(":") { return nil }

        let cleaned = candidate
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard cleaned.count >= 2 else { return nil }
        // Reject opaque ids: a uuid, or a token that is all hex/digits/dashes
        // with no vowel-bearing word. Require at least two consecutive letters.
        if isOpaqueIdentifier(cleaned) { return nil }
        guard cleaned.range(of: "[a-z]{2,}", options: .regularExpression) != nil else { return nil }
        return cleaned
    }

    /// Common words that carry no topical signal — kept SHORT and boring on
    /// purpose (the ranker's lexical overlap tolerates a little noise; a big
    /// clever list is maintenance debt). Bracketed routing prefixes like
    /// "[from: claude, via bridge]" are stripped before tokenizing.
    /// Internal (was private) so the felt line's SAFE object extractor can
    /// reuse the same boring list rather than growing a second one that drifts.
    static let summaryStopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "was", "were", "you",
        "your", "yours", "she", "her", "hers", "him", "his", "its", "our",
        "are", "but", "not", "all", "any", "can", "had", "has", "have",
        "how", "what", "when", "where", "which", "who", "why", "will",
        "would", "could", "should", "been", "being", "from", "into", "just",
        "like", "more", "most", "much", "about", "after", "before", "over",
        "under", "again", "then", "than", "them", "they", "there", "here",
        "did", "does", "doing", "don", "let", "lets", "got", "get", "gets",
        "one", "two", "out", "still", "same", "some", "such", "too", "very",
        "yeah", "yes", "okay", "hey", "well", "also", "really", "actually",
        "thing", "things", "today", "tonight", "day", "long", "via", "bridge",
        "assistant", "agent", "owner",
        // Contractions, function verbs and evaluations do not name attention topics.
        "dont", "cant", "wont", "didnt", "isnt", "arent", "wasnt", "werent",
        "doesnt", "hasnt", "havent", "youre", "thats", "theyre", "whats",
        "wheres", "hows", "those", "these", "went", "goes", "going", "gone",
        "come", "came", "make", "made", "take", "took", "know", "knew",
        "think", "thought", "said", "says", "tell", "told", "want", "need",
        "because", "cause", "kind", "sort", "little", "stuff", "something",
        "anything", "nothing", "everything", "someone", "anyone", "whether",
        "either", "only", "even", "ever", "never", "always", "maybe", "mean",
        "means", "sure", "fine", "good", "nice", "great", "cool",
    ]

    /// Up to 4 salient content words from a node summary: bracketed routing
    /// prefixes stripped, lowercased word-boundary tokens, stopwords and
    /// opaque ids dropped, ≥4 letters, first-seen order (the summary leads
    /// with its subject more often than not).
    static func summaryKeywords(from summary: String, limit: Int = 4) -> [String] {
        var text = summary
        // Strip a leading "[...]" routing prefix ("[from: claude, via bridge]").
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...])
        }
        var seen: Set<String> = []
        var keywords: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let word = String(raw)
            guard word.count >= 4,
                  !summaryStopwords.contains(word),
                  !isOpaqueIdentifier(word),
                  !seen.contains(word) else { continue }
            seen.insert(word)
            keywords.append(word)
            if keywords.count >= limit { break }
        }
        return keywords
    }

    /// A conservative opaque-id test: canonical uuid shape, or an all
    /// hex/digit/dash blob (a digest or numeric id) with no letters at all.
    static func isOpaqueIdentifier(_ value: String) -> Bool {
        if value.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil {
            return true
        }
        // Long unbroken hex/digit run (>= 16) reads as a digest, never a topic.
        if value.range(of: "^[0-9a-f]{16,}$", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - Node → memory record ids

    /// The MemoryV2 record ids a workspace node references, if any.
    ///
    /// Convention (this seam's contract):
    ///   - metadata key `memoryRecordIds`: a JSON array of record-id strings, OR
    ///   - metadata key `memoryRecordId`: a single record-id string, OR
    ///   - a subject of type `memory` / `memory_record` whose `id` IS the record
    ///     id (the natural shape a recalled-memory node would take; `memory_record`
    ///     already exists as a projection entity kind).
    static func memoryRecordIDs(from node: CognitiveNode) -> [String] {
        var ids = memoryRecordIDs(fromEventMetadata: node.metadata)
        let subjectType = node.subjectReference.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if subjectType == "memory" || subjectType == "memory_record" {
            let recordID = node.subjectReference.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !recordID.isEmpty { ids.append(recordID) }
        }

        // De-dup, preserve first-seen order.
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
