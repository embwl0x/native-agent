import Foundation
import NativeAgentCore

/// Gives a correction the scope of the work that produced it, at INTAKE.
///
/// A3 / audit finding 5 (2026-09-11): `data/context/context.sqlite` holds 31
/// current correction atoms, 13 of them with no `context_topic` entity, which
/// makes them MANDATORY on every turn (ContextCorrectionScope.applies returns
/// true when an atom supplies no scoping entity — fail-open by design). 14
/// corrections were injected ahead of the ordinary memories in the first fresh
/// prompt of 2026-09-11, including an image-cache diagnosis, a git
/// stash/reflog lesson and a shell-vs-connectors distinction, on turns about
/// none of those things. They are real lessons; they are not every turn's
/// business, and they were spending the relevance budget ordinary memories
/// needed.
///
/// `commit_memory` already accepts `context_topics` and the model sometimes
/// supplies them. This closes the gap when it does not: a correction about a
/// TOOL OR TOPIC gets that topic, and a correction about the PEOPLE or about
/// AUTHORITY stays global, because those are the ones that must hold on a turn
/// that never mentions them.
///
/// FAIL-OPEN, exactly like the scope gate it feeds: when nothing can be
/// derived, the correction stays global — the behaviour every existing atom
/// already has. This never narrows a scope the model supplied itself, and it
/// never edits an atom already in the store.
public enum CorrectionScopeAtIntake {
    /// At most this many derived phrases. The store accepts 8.
    static let maximumTopics = 6

    /// A correction about HIM, about HER, or about how the two of them are with
    /// each other. Scoping one of these to a topic would let it lapse on
    /// exactly the turns it exists for.
    static let interpersonalSignals: [String] = [
        "user", "agent", "he ", "him", "his ", "her ", "she ",
        "tone", "warmth", "tender", "endearment", "pet name", "pet names",
        "affection", "flirt", "teasing", "nagging", "greet", "greeting",
        "feel", "feels", "felt", "emotional", "emotion", "mood",
        "apolog", "trust me", "respect",
    ]

    /// A correction about what she MAY DO — permission, approval, boundaries,
    /// safety. Also never topic-scoped.
    static let authorizationSignals: [String] = [
        "authori", "permission", "permitted", "approval", "approve", "consent",
        "boundary", "boundaries", "must not", "never send", "do not send",
        "don't send", "without asking", "ask first", "quiet", "trust center",
        "yolo", "full mac", "credential", "password", "secret",
    ]

    /// PROHIBITION / PERMISSION LANGUAGE. A correction carrying any of these
    /// is stating what she MAY or MAY NOT do, and a boundary that only holds
    /// on turns about its own subject is not a boundary.
    ///
    /// GPT-5.6 review, 2026-09-11: "Never contact people unless explicitly
    /// asked" trips none of `authorizationSignals`, but `contact` activates the
    /// `contacts` route group — so the correction was scoped to contacts and
    /// was therefore ABSENT from an "email Alice" turn, which is the one turn
    /// it exists for. Scope must never be inferred in a way that can weaken a
    /// boundary, so anything speaking in this vocabulary stays global.
    ///
    /// Matched as SUBSTRINGS on purpose: the failure direction here is
    /// "stayed global when it could have been scoped", which costs relevance
    /// budget, versus "scoped a boundary away", which costs the boundary.
    /// `task` tripping `ask` is the cheap mistake.
    static let boundaryLanguage: [String] = [
        "never", "always", "don't", "don\u{2019}t", "do not", "only", "unless",
        "must", "ask", "approval", "allowed", "permitted", "send", "contact",
        "delete", "pay", "money",
    ]

    /// True when this correction binds on every turn regardless of subject.
    public static func isGloballyBinding(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        return interpersonalSignals.contains { lower.contains($0) }
            || authorizationSignals.contains { lower.contains($0) }
            || boundaryLanguage.contains { lower.contains($0) }
    }

    /// Topic phrases for a correction the model left unscoped, derived from the
    /// same lexical route table the turn's own tool preload uses — so the scope
    /// is "the tool/topic this correction was about" in the system's existing
    /// vocabulary rather than a second classifier with its own opinions.
    ///
    /// Empty means "leave it global".
    public static func derivedTopics(
        correctionText: String,
        surface: String = "chat",
        turnToolNames: Set<String>? = nil
    ) -> [String] {
        let text = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGloballyBinding(text) else { return [] }
        guard let prediction = ToolPreloadHeuristics.predict(
            userMessage: text,
            surface: surface
        ) else { return [] }
        // THE TURN MUST ACTUALLY HAVE DONE THAT WORK. A lexical route match on
        // the correction's own words is a guess about what it is ABOUT; it is
        // not evidence the correction came out of that work. Auto-scope only
        // when this turn's tool DISPATCH names a concrete tool family the
        // prediction agrees with. No dispatch record, or a disjoint one, is
        // "unknown" — and unknown stays GLOBAL, the behaviour every existing
        // atom already has.
        //
        // GPT-5.6 review 2026-09-11: the fallback used to be
        // `LLMCallContext.turnActiveTools`, which is the whole offered and
        // preloaded session set — any mail tool ever offered satisfied the
        // "did mail work" check, so "explicit confirmation before emailing
        // anyone" could be scoped to mail and vanish on the next send request.
        // The caller must pass real dispatch evidence; absent it we fail OPEN
        // to global rather than substitute the offered set.
        let dispatched = turnToolNames ?? []
        guard !prediction.candidateTools.isDisjoint(with: dispatched) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        // The group name first (the coarse subject), then the phrases that
        // actually fired — those are the words a later turn on the same subject
        // is most likely to use, and the scope gate matches on words.
        for phrase in prediction.groupNames + prediction.matchedPatterns {
            let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 120 else { continue }
            guard seen.insert(clean.lowercased()).inserted else { continue }
            out.append(clean)
            if out.count >= maximumTopics { break }
        }
        return out
    }
}
