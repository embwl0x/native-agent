import Foundation

/// Applicability is not authority. Existing corrections remain global unless
/// their canonical memory explicitly supplies topics; attention/utility cannot
/// make a topic-scoped correction apply to an unrelated conversation.
///
/// The same gate scopes knowledge-graph relations (2026-09-01). A relation is
/// reached BY ITS ENDPOINTS or not at all: its body reads "User —owns→ Hermes",
/// and the selector's lexical index folds every body token in, so without this
/// gate a generic "who owns what?" pulls edges whose subject and object the
/// message never mentioned — prompt mass wearing reach's name. Excluding them
/// here rather than hoping they rank low also leaves an honest receipt
/// (`outsideContextScope`) instead of a silent loss.
///
/// Both kinds keep the same fail-open rule: an atom that supplies no scoping
/// entity stays global, so nothing that existed before either scope was
/// introduced changes behaviour.
public enum ContextCorrectionScope {
    public static let entityKind = "context_topic"
    /// Endpoint entities of a knowledge-graph relation atom.
    public static let relationshipEntityKind = "kg_entity"
    /// Endpoint entities of a STUDIO pointer atom — the work's title, its
    /// creator, and its medium, and nothing else. The judgment text is what the
    /// pointer stands for, never how it is found: admitting response words here
    /// would let an ops turn pull a taste memory, and "if it shows up on ops
    /// turns I'll learn to ignore it, and ignored is worse than absent" (the
    /// agent's own build brief, 2026-09-01).
    public static let studioEntityKind = "studio_work"

    /// Which entity kind scopes which atom kind. Absent ⇒ the atom is global.
    static func scopingEntityKind(for kind: ContextAtomKind) -> String? {
        switch kind {
        case .correction: entityKind
        case .relationship: relationshipEntityKind
        default: nil
        }
    }

    /// Which entity kind scopes THIS atom. Atom kind decides first (corrections
    /// and relations, unchanged); otherwise an atom is studio-scoped exactly
    /// when it carries studio endpoints of its own. Keying the studio scope on
    /// the atom's OWN entities rather than on its kind is what keeps every
    /// pre-existing atom of the same kind global: it supplies no `studio_work`
    /// entity, so nothing about it changes.
    static func scopingEntityKind(for atom: ContextAtomDraft) -> String? {
        if let byKind = scopingEntityKind(for: atom.kind) { return byKind }
        return atom.entities.contains { $0.kind == studioEntityKind } ? studioEntityKind : nil
    }

    public static func applies(_ atom: ContextAtomDraft, message: String, recentTurns: [String]) -> Bool {
        guard let scopingKind = scopingEntityKind(for: atom) else { return true }
        let topics = atom.entities.filter { $0.kind == scopingKind }.map(\.label)
        guard !topics.isEmpty else { return true }
        // A studio pointer has a SECOND admission: the turn itself is a taste
        // judgment (a design review, an aesthetic call). Naming the work is the
        // ordinary way in; being asked which of two things is better is the
        // other. Neither is "the message happened to be long".
        if scopingKind == studioEntityKind, isTasteJudgmentTask(message) { return true }
        // Carry scope through a short referential follow-up, not through a
        // greeting or an unrelated topic simply because it follows work.
        let followup = isReferentialFollowup(message)
        let texts = [message] + (followup ? Array(recentTurns.suffix(2)) : [])
        return topics.contains { topic in
            let needle = words(topic)
            guard !needle.isEmpty else { return false }
            return texts.contains { text in
                let haystack = words(text)
                guard haystack.count >= needle.count else { return false }
                return (0...(haystack.count - needle.count)).contains {
                    Array(haystack[$0..<($0 + needle.count)]) == needle
                }
            }
        }
    }

    // MARK: - Taste-judgment turns

    /// Is THIS turn a taste judgment — a design review, an aesthetic call?
    ///
    /// There is deliberately no classifier read here. The system does compute a
    /// goal type (`TurnPlan.goalType`, from the router's own lexical chain), but
    /// it is produced CONCURRENTLY with context compilation and awaited after
    /// the packet is already built, so selection genuinely cannot see it. The
    /// honest alternative is a bounded predicate over the message itself, which
    /// is what this is — not a second classifier competing with the router's.
    ///
    /// It is deliberately hard to trip. A single word never qualifies: the turn
    /// must both ASK for a judgment and name an AESTHETIC object, or use one of
    /// the three phrases that are a taste call on their face. "Review this diff"
    /// and "does this look right?" are ops turns and must stay ops turns —
    /// a pointer that shows up on those gets learned as noise, and ignored is
    /// worse than absent.
    ///
    /// Word-boundary matched on the shared tokenizer, so "art" never matches
    /// inside "start" and "color" never inside "colorectal".
    public static func isTasteJudgmentTask(_ message: String) -> Bool {
        let tokens = words(message)
        guard !tokens.isEmpty else { return false }
        let joined = " " + tokens.joined(separator: " ") + " "
        // A taste call on its face — no second signal needed.
        for phrase in ["design review", "art direction", "aesthetic call"]
        where joined.contains(" " + phrase + " ") {
            return true
        }
        // Each token also contributes its bare singular, so "which of these
        // covers is better" reads the same as "which cover is better". This is
        // the only stemming here and it is deliberately one rule: membership is
        // tested against fixed sets, so a wrong singular matches nothing.
        var present = Set(tokens)
        for token in tokens where token.count > 3 && token.hasSuffix("s") {
            present.insert(String(token.dropLast()))
        }
        let asks = !present.isDisjoint(with: [
            "review", "critique", "criticism", "opinion", "verdict",
            "judge", "prefer", "better", "worse", "which",
        ]) || ["what do you think", "how does it read", "how does it look"]
            .contains { joined.contains(" " + $0 + " ") }
        guard asks else { return false }
        let aesthetic = !present.isDisjoint(with: [
            "design", "aesthetic", "aesthetics", "aesthetically", "visual",
            "visually", "typography", "typeface", "type", "palette",
            "colour", "color", "layout", "composition", "art", "artwork",
            "photograph", "photography", "film", "cinematography",
            "architecture", "beautiful", "ugly", "elegant", "style",
            "styling", "taste", "cover", "poster", "logo",
        ])
        return aesthetic
    }

    /// Deliberately conservative: an incidental "it" in "how is it going?"
    /// or "is it raining?" is not permission to bring prior work forward.
    public static func isReferentialFollowup(_ message: String) -> Bool {
        let tokens = words(message)
        guard !tokens.isEmpty, tokens.count <= 16 else { return false }
        if !Set(tokens).isDisjoint(with: ["that", "those", "them", "continue", "resume", "same"]) { return true }
        let normalized = " " + tokens.joined(separator: " ") + " "
        return ["do it", "fix it", "use it", "try it", "finish it", "change it", "go ahead", "keep going"]
            .contains { normalized.contains(" " + $0 + " ") }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
