import Foundation

public enum MemoryCandidateQuality {
    public static func rejectionReason(text: String, source: String? = nil, kind: String? = nil) -> String? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return "empty memory candidate" }
        if isTransientSessionState(normalized) {
            return "transient session/context state is not durable memory"
        }
        if isToolTranscriptNoise(normalized) {
            return "tool transcript/status output is not durable memory"
        }
        if isIncompleteSemanticFragment(normalized, kind: kind) {
            return "incomplete semantic fragment is not durable memory"
        }
        if isIncompleteThought(normalized, source: source) {
            return "mid-thought fragment is not durable memory"
        }
        if isConversationalVapor(normalized, kind: kind) {
            return "low-quality conversational fragment is not durable memory"
        }
        if isAutomaticExtractionSource(source),
           isContextDependentAutomaticSemantic(normalized, kind: kind) {
            return "context-dependent automatic extraction is not durable memory"
        }
        return nil
    }

    public static func isDurableCandidate(text: String, source: String? = nil, kind: String? = nil) -> Bool {
        rejectionReason(text: text, source: source, kind: kind) == nil
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            .lowercased()
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isTransientSessionState(_ text: String) -> Bool {
        let lifecyclePatterns = [
            #"^(?:the\s+)?(?:user'?s|agent'?s|assistant'?s|nativeagent'?s)?\s*(?:current\s+)?(?:session|conversation|chat)\s+context\s+(?:is|was|has\s+been|got|gets)?\s*(?:reset|cleared|compacted|truncated)\.?$"#,
            #"^(?:the\s+)?(?:current\s+)?(?:session|conversation|chat)\s+(?:is|was|has\s+been|got|gets)?\s*(?:reset|cleared|compacted|truncated)\.?$"#,
            #"^(?:the\s+)?(?:context|context\s+window)\s+(?:is|was|has\s+been|got|gets)?\s*(?:reset|cleared|compacted|truncated)\.?$"#,
        ]
        return lifecyclePatterns.contains { matches(text, $0) }
    }

    private static func isToolTranscriptNoise(_ text: String) -> Bool {
        let prefixes = [
            "[cognitivesubstrate]",
            "cognitive capsule:",
            "private working state",
            "app lifecycle:",
            "applifecycle:",
            "focus:",
            "correction:",
            "thread:",
            "inner:",
            "body:",
            "open:",
            "expect:",
            "feeling:",
            "voice:",
            "- body:",
            "conversation focus:",
            "conversationfocus:",
            "current focus:",
            "currentfocus:",
            "recent correction:",
            "recentcorrection:",
            "inner thread:",
            "innerthread:",
            "open commitment:",
            "opencommitment:",
            "expectation:",
            "affect:",
            "reflection takeaway:",
            "reflectiontakeaway:",
            "tool observation:",
            "toolobservation:",
            "bash ok:",
            "read_file ok:",
            "write_file ok:",
            "list_dir ok:",
            "run_id:",
            "session_id:",
        ]
        return prefixes.contains { text.hasPrefix($0) }
    }

    /// 2026-08-14 proposal-hygiene fix: kind-INDEPENDENT fragment gate. The
    /// existing checks below are prefix- and kind-guarded (identity/location/
    /// employment candidates bypassed every one of them), and their open-tail
    /// patterns only catch preposition/verb stubs — so word-safe but
    /// meaning-dead captures like "user wants agent", "user likes how
    /// sometimes she", and "user's design review is now" all reached the
    /// review queue. A durable fact never ENDS on a function word, and a
    /// verb-form capture whose object is a single bare token is a clipped
    /// sentence, not a fact — whatever its kind claims.
    /// Closed-class words that essentially never end a durable sentence, for
    /// ANY source — articles, prepositions, conjunctions, aux/copulas,
    /// wh-words, possessive determiners. "user's design review is" or
    /// "user wants out of" is clipped no matter who wrote it.
    private static let hardTailStopwords: Set<String> = [
        "a", "an", "the", "this", "these", "those", "some", "any",
        "my", "your", "their", "our",
        "is", "are", "was", "were", "be", "been", "being", "am",
        "do", "does", "have", "has", "had",
        "can", "could", "will", "would", "shall", "should", "may", "might",
        "must",
        "to", "of", "in", "on", "at", "by", "for", "with", "without",
        "about", "into", "onto", "over", "under", "between", "through",
        "from", "as", "than",
        "and", "or", "but", "nor", "because", "since", "if", "while",
        "when", "where", "how", "which", "whom", "why",
        "whether",
    ]
    // "his"/"her"/"who" are deliberately NOT hard tails: pronoun records
    // ("user's pronouns are she/her") and proper names ("The Who") are
    // legitimate deliberate stores. They reject only for automatic sources.

    /// Additional tails rejected only for AUTOMATIC extraction sources: bare
    /// pronouns and dangling adverbs. Deliberate stores may legitimately end
    /// on these ("...and User loved it"); a regex capture ending there is a
    /// clipped sentence ("user likes how sometimes she").
    private static let automaticTailStopwords: Set<String> = [
        // 2026-08-16 ("…think of some other" escape): determiner/quantifier
        // tails reject for AUTOMATIC extraction only. Deliberate stores keep
        // them — "prefers Signal over any other" is a legit sentence ending
        // (same lesson as his/her/who: lexical ambiguity over-rejects the
        // deliberate lane, and chat.commit_memory is her GOOD lane).
        "other", "another", "more", "most", "such", "several", "certain",
        "few", "fewer", "each", "every", "either", "neither",
        "i", "me", "we", "us", "you", "he", "him", "she", "they", "them",
        "it", "its", "mine", "yours", "hers", "theirs", "ours", "that",
        "his", "her", "who",
        "now", "then", "just", "still", "yet", "very", "really", "quite",
        "too", "also", "sometimes", "often", "always", "never", "not",
        "no", "yes", "so", "what",
    ]

    private static let verbLeadIns = [
        "user wants ", "user likes ", "user needs ", "user prefers ",
        "user dislikes ", "user values ", "user would like ", "user is ",
        "user has ",
    ]

    private static func isIncompleteThought(_ text: String, source: String?) -> Bool {
        let words = text.split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
        guard let last = words.last?.lowercased() else { return true }
        if hardTailStopwords.contains(last) { return true }
        // A copula followed by a bare adverb/yes/no is a missing complement
        // for any source ("user's design review is now", "user's answer is
        // no") — the adverb alone is only suspicious after the copula.
        if matches(text, #"\b(?:is|are|was|were|be|been|being)\s+(?:now|then|still|yet|often|sometimes|always|never|really|very|quite|too|also|no|yes)$"#) {
            return true
        }
        guard isAutomaticExtractionSource(source) else { return false }
        if automaticTailStopwords.contains(last) { return true }
        // Verb-form captures need a real object: after the lead-in, a single
        // remaining token ("agent", "coffee") is a clipped sentence.
        for lead in verbLeadIns where text.hasPrefix(lead) {
            let payload = String(text.dropFirst(lead.count))
            let payloadWords = payload
                .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            if payloadWords.count < 2 { return true }
        }
        return false
    }

    private static func isIncompleteSemanticFragment(_ text: String, kind: String?) -> Bool {
        let normalizedKind = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let semanticKinds: Set<String> = [
            "preference", "goal", "fact", "attribute", "cognitive_proposal"
        ]
        if let normalizedKind, !semanticKinds.contains(normalizedKind) {
            return false
        }
        let prefixes = [
            "likes:", "prefers:", "values:", "goal:",
            "user likes", "user prefers", "user values", "user wants",
            "user needs", "user would like"
        ]
        guard prefixes.contains(where: { text.hasPrefix($0) }) else { return false }
        let openTailPatterns = [
            #"\b(?:to|for|with|without|about|as|of|in|on|at|by)\s+(?:be|feel|do|have|get|make|use|see|know|work|run|go|look|act|become|stay)\.?$"#,
            #"\b(?:to|for|with|without|about|because|so|that|when|while|where|how|as|of|in|on|at|by)\.?$"#,
        ]
        return openTailPatterns.contains { matches(text, $0) }
    }

    /// Reject the low-precision conversational captures the adaptive promoter's
    /// "user likes/wants X" path lets through even when the tail is closed:
    /// over-long sentences, ephemeral "trying to …"/"being able to …" activity
    /// openers, and relational sentiment about the assistant ("…with you", "how
    /// honest you are"). None of these survive detachment from the turn as a
    /// durable USER fact.
    ///
    /// Prefix-guarded to the same "user likes/…" family isIncompleteSemanticFragment
    /// inspects, so structured facts phrased "user's X is Y" ("user's sleep
    /// pattern is 1900-0300") and assistant/self-authored rows ("User likes
    /// Agent's quirks") — which don't match the prefix — are never touched.
    ///
    /// Live audit 2026-07-01: seven such rows had landed in Agent's memory
    /// ("user likes working with yiu", "user likes trying to push it and see",
    /// "user likes how honest you are", plus four comma run-ons). Precision-bias
    /// is intentional — a rare false-reject just means the fact isn't
    /// auto-saved; User can still commit it explicitly.
    private static func isConversationalVapor(_ text: String, kind: String?) -> Bool {
        let normalizedKind = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let semanticKinds: Set<String> = [
            "preference", "goal", "fact", "attribute", "cognitive_proposal"
        ]
        if let normalizedKind, !semanticKinds.contains(normalizedKind) {
            return false
        }
        let prefixes = [
            "likes:", "prefers:", "values:", "dislikes:", "goal:",
            "user likes", "user prefers", "user values", "user dislikes",
            "user wants", "user needs", "user would like"
        ]
        guard let matched = prefixes.first(where: { text.hasPrefix($0) }) else { return false }
        let body = String(text.dropFirst(matched.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return true }
        let words = body.split { !($0.isLetter || $0.isNumber) }.map(String.init)

        // (B) Over-long capture: a distilled durable fact is terse; a dozen-plus
        // words is a captured sentence, not a fact. Deliberately NOT gating on
        // commas — "tabs, not spaces" and "honesty, directness, follow-through"
        // are legitimate list-preferences; the comma run-ons this path produced
        // are all caught by length or the opener/relational rules below.
        if words.count > 12 { return true }

        // (C) Ephemeral/filler opener: the capture is an in-the-moment activity
        // ("trying to push it and see", "being able to do this"), not a durable
        // trait. Openers are specific multi-word phrases, so gerund/adverbial
        // facts ("being outdoors", "trying new restaurants", "just enough
        // structure") are untouched. NB: a bare "it"/"this" rule was removed —
        // lowercasing made it indistinguishable from "IT" (information
        // technology), false-rejecting "user values IT security".
        let ephemeralOpeners = ["trying to ", "being able to ", "getting to ", "wanting to "]
        if ephemeralOpeners.contains(where: { body.hasPrefix($0) }) { return true }

        // (D) Relational sentiment about the assistant/self — not a durable USER
        // fact ("…with you", "how honest you are/you're"). Objects restricted to
        // you/yiu/me so acronyms and third parties ("with U.S. teams",
        // "US-based", "with her wife") are untouched. (Bare "with us"/"to u"
        // relational vapor is deliberately not chased here — it would reintroduce
        // the u.s./us-based false-rejects, and length/other rules catch the
        // run-ons that phrasing actually appears in.)
        let paddedBody = " " + body + " "
        if matches(paddedBody, #"\b(?:with|to|about|toward|towards|for)\s+(?:you|yiu|me)\b"#) {
            return true
        }
        if matches(paddedBody, #"\byou\s+are\b"#) || matches(paddedBody, #"\byou're\b"#) {
            return true
        }
        if let last = words.last, ["you", "yiu", "me"].contains(last) { return true }

        return false
    }

    /// Automatic extraction is a precision-first convenience lane. Unlike an
    /// explicit `commit_memory` call, it must reject wording that only makes
    /// sense while the original turn (or a quoted reply) is still visible.
    ///
    /// The stricter rules are source-scoped so deliberate memories retain the
    /// normal shared durability contract. They target unresolved/deictic goals
    /// such as "user wants actually gone" and "user wants whatever signature
    /// you want there dont worry" without rejecting anchored goals such as
    /// "user wants Slack to be live like Telegram".
    private static func isContextDependentAutomaticSemantic(_ text: String, kind: String?) -> Bool {
        let normalizedKind = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let automaticSemanticKinds: Set<String> = [
            "preference", "goal", "fact", "attribute", "relationship",
            "cognitive_proposal"
        ]
        if let normalizedKind, !automaticSemanticKinds.contains(normalizedKind) {
            return false
        }

        let prefixes = [
            "goal:", "likes:", "prefers:", "values:", "dislikes:",
            "user likes", "user prefers", "user values", "user dislikes",
            "user wants", "user needs", "user would like"
        ]
        guard let matched = prefixes.first(where: { text.hasPrefix($0) }) else {
            return false
        }
        let body = String(text.dropFirst(matched.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = body.split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).lowercased() }
        guard let first = words.first else { return true }

        let unresolvedOpeners: Set<String> = [
            "actually", "really", "whatever", "whichever", "something",
            "anything", "nothing", "everything"
        ]
        if unresolvedOpeners.contains(first) { return true }

        let unresolvedTokens: Set<String> = [
            // Do not match bare `it` here: normalization erases the distinction
            // between the pronoun and the IT acronym ("strong IT security").
            // Leading pronoun payloads are already rejected by cleanPayload.
            "this", "that", "these", "those", "here", "there",
            "you", "your", "yours"
        ]
        if words.contains(where: unresolvedTokens.contains) { return true }

        let padded = " " + body.lowercased() + " "
        let conversationalClosers = [
            " don't worry ", " dont worry ", " that's fine ",
            " thats fine ", " is fine ", " no worries "
        ]
        if conversationalClosers.contains(where: padded.contains) { return true }

        let unresolvedTerminalStates: Set<String> = [
            "gone", "done", "fine", "okay", "ok", "ready", "back",
            "built", "fixed", "working"
        ]
        if words.count <= 2,
           let last = words.last,
           unresolvedTerminalStates.contains(last) {
            return true
        }

        return false
    }

    private static func isAutomaticExtractionSource(_ source: String?) -> Bool {
        guard let source = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !source.isEmpty else {
            return false
        }
        return source == "semantic-adaptive-extractor"
            || source == "adaptive-promoter"
            || source.hasPrefix("adaptive-promoter:")
    }
}
