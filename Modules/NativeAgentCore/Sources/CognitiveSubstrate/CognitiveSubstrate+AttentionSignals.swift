// A bounded projection of resident attention for context selection. Publication compiles accepted state; cancellation belongs to the turn read. Empty attention
// contributes no packet input.

import Foundation
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+AttentionSignals.swift` | `CognitiveSubstrate.makeAttentionSignals`: bounded resident attention |

extension CognitiveSubstrate {
    func makeAttentionSignals(at date: Date) -> CognitiveAttentionSignals? {
        // Gate exactly the way the capsule path does: disabled cognition adds nothing; workspace off yields no items below.
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
        // Empty attention must return nil; an empty struct would still change the packet input.
        return signals.isEmpty ? nil : signals
    }

    func publishAttentionProjection(at date: Date) {
        dependencies.attentionProjectionSink(
            makeAttentionSignals(at: date)
        )
    }

    // MARK: - Unresolved question

    /// Phrase the open completion as a short, human "what's unresolved" line. Returns nil when no slot is open, the slot has aged past
    /// `pendingCompletionMaxAge` (a stale completion is no longer a live question), or the remembered node was evicted since it was recorded.
    private func unresolvedQuestionFromPendingCompletion(at now: Date) -> (question: String, window: OpenCompletionRead)? {
        guard let window = openCompletion(at: now), let pending = pendingCompletion,
              let node = field.node(forKey: pending.nodeKey) else { return nil }

        let summary = node.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        // The constructor bounds to 200; clip the summary first so the framing prefix always survives the bound.
        let snippet = bounded(summary, maxCharacters: 150)
        return ("Still waiting to see how this landed: \(snippet)", window)
    }

    // MARK: - Subject → lexical term cleaning

    /// Opaque routing subjects cannot match human topics. Memory identities travel through `memoryActivation`; namespaced subjects are machine keys.
    static let machineSubjectTypes: Set<String> = [
        "chat", "chat_turn", "chat_session",
        "chat.user_turn", "chat.assistant_turn", "chat.session", "chat.surface",
        "tool", "provider", "approval",
        "execution_step", "memory_proposal", "promotion_candidate",
        "inbox_item", "remote_action", "ios_action", "app", "image",
        "memory", "memory_record",
    ]

    /// Only human topics become lexical terms; exclude routing handles, UUIDs and digests rather than leaking opaque ids into ranking.
    static func lexicalTerm(from subject: CognitiveSubjectReference) -> String? {
        let type = subject.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type.isEmpty || type.contains(".") || machineSubjectTypes.contains(type) {
            return nil
        }
        let candidate = (subject.label ?? subject.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        // A ":"-composite is a machine handle (session:message, executionId:stepId).
        if candidate.contains(":") { return nil }

        let cleaned = candidate
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard cleaned.count >= 2 else { return nil }
        // Reject opaque ids: a uuid, or a token that is all hex/digits/dashes with no vowel-bearing word. Require at least two consecutive letters.
        if isOpaqueIdentifier(cleaned) { return nil }
        guard cleaned.range(of: "[a-z]{2,}", options: .regularExpression) != nil else { return nil }
        return cleaned
    }

    /// Keep stopwords small; strip routing prefixes before ranking. Felt-object extraction shares this list so lexical rules cannot drift.
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

    /// Keep first-seen salient words because summaries usually lead with their subject; routing prefixes and opaque ids carry no topical signal.
    static func summaryKeywords(from summary: String, limit: Int = 4) -> [String] {
        var text = summary
        // Routing prefixes describe transport, not the topic.
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

    /// A conservative opaque-id test: canonical uuid shape, or an all hex/digit/dash blob (a digest or numeric id) with no letters at all.
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

    /// Record references use `memoryRecordIds`, `memoryRecordId` or a memory subject's id; these are activation identities, never lexical topics.
    static func memoryRecordIDs(from node: CognitiveNode) -> [String] {
        var ids = memoryRecordIDs(fromEventMetadata: node.metadata)
        let subjectType = node.subjectReference.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if subjectType == "memory" || subjectType == "memory_record" {
            let recordID = node.subjectReference.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !recordID.isEmpty { ids.append(recordID) }
        }

        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
