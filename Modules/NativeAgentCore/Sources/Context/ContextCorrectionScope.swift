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

    /// Entity kinds that mark an atom as BELONGING TO THE BUILD: a Desk item, a
    /// project, a workshop execution. An atom carrying one of these is a piece
    /// of engineering backlog, whatever its atom kind.
    public static let engineeringEntityKinds: Set<String> = [
        "desk_handle", "project", "workshop_execution",
    ]

    /// The subset of those kinds whose label NAMES THE ITEM ITSELF. The resident
    /// projection puts a `desk_handle` (the item's title) AND a `project` (the
    /// shared label, "NativeAgent" on every item) on every atom it emits
    /// (NativeResidentWorkContextProjection.swift:196-198), so matching the
    /// project label would re-admit the entire backlog the moment a personal
    /// question happened to say the product's name. Only a title counts as
    /// naming a specific work item.
    public static let engineeringTitleEntityKinds: Set<String> = [
        "desk_handle", "workshop_execution",
    ]

    /// Comb 4 lane 5 item 1: the entity-kind gate above catches the RESIDENT
    /// WORK projection, which stamps `desk_handle`/`project` on what it emits.
    /// Committed MEMORIES carry no such entity — only `memory_record`,
    /// `memory_authority` and `provenance` — so four engineering instructions
    /// still entered the 05:41Z personal packet (context_atom_versions 18193,
    /// 18172, 18018, 18073). Their engineering identity lives in their own
    /// topic tags instead ("delegation", "orchestration", "codex", "testing",
    /// "verification", "evals", "desk-751", "onboarding", "north-star") and, for
    /// 18073, in the memory-record label `project`.
    ///
    /// These are the tag tokens that name THE BUILD and nothing else. Words an
    /// interpersonal memory plausibly carries are deliberately absent:
    /// "design" (her artistic taste is a personal subject), "preference",
    /// "communication", "personal", and every bare name. A tag is engineering
    /// when one of its own word tokens is in here, so "execution-drift",
    /// "desk-751" and "north-star" all read correctly through the shared
    /// tokenizer.
    public static let engineeringTopicTokens: Set<String> = [
        "backlog", "branch", "build", "builds", "ci", "codex", "commit",
        "compile", "delegation", "deploy", "deployment", "desk", "diff",
        "dmg", "eval", "evals", "git", "install", "installation", "lint",
        "merge", "migration", "nativeagent", "onboarding", "orchestration",
        "packaging", "refactor", "regression", "release", "releases", "repo",
        "repository", "schema", "ship", "shipping", "star", "swift", "test",
        "tests", "testing", "verification", "worker", "workers", "workshop",
        "worktree",
    ]

    /// Memory-record labels (the record's own `kind`/`layer`) that name the
    /// build rather than the person. `instruction`, `preference` and
    /// `correction` are excluded on purpose: interpersonal memory uses exactly
    /// those labels.
    public static let engineeringRecordLabels: Set<String> = ["project"]

    /// Does this atom's OWN metadata mark it as build material, by topic tag or
    /// memory-record label? Returns the labels a turn could name to bring it
    /// back in; `nil` means the atom carries no engineering marker and stays
    /// global, exactly as before.
    static func engineeringTopicLabels(for atom: ContextAtomDraft) -> [String]? {
        var labels: [String] = []
        for tag in atom.triggers where !Set(words(tag)).isDisjoint(with: engineeringTopicTokens) {
            labels.append(tag)
        }
        let recordLabels = atom.entities
            .filter { $0.kind == "memory_record" && engineeringRecordLabels.contains($0.label.lowercased()) }
            .map(\.label)
        labels.append(contentsOf: recordLabels)
        return labels.isEmpty ? nil : labels
    }

    public static func applies(_ atom: ContextAtomDraft, message: String, recentTurns: [String]) -> Bool {
        // Comb 3 lane 2 item 1: on 2026-09-11 at 22:13 User asked what she had
        // been thinking and feeling and whether she had new artistic tastes, and
        // four of the eighteen selected atoms were resident engineering work
        // ("emit turn-dead marker on retry exhaustion", "Synthesize recommended
        // generative UI plan", …). Backlog is not an answer to that question.
        //
        // Narrow on purpose, and fail-open: it needs a turn the personal
        // predicate admits, it only touches atoms that carry an engineering
        // entity OF THEIR OWN, and NAMING A SPECIFIC ITEM still brings it in —
        // by its own title, never by the project label every item shares.
        // Interpersonal material — corrections about User, how to talk to him,
        // what he has asked for — carries none of these entities and is
        // untouched.
        let isEngineering = atom.entities.contains { engineeringEntityKinds.contains($0.kind) }
        if isEngineering, isPersonalTask(message) {
            let titles = atom.entities
                .filter { engineeringTitleEntityKinds.contains($0.kind) }
                .map(\.label)
            return mentions(titles, message: message, recentTurns: recentTurns)
        }
        // The two fail-open exits below now ask one more question of the atom's
        // OWN metadata: an atom that supplies no scoping entity still stays
        // global UNLESS its topic tags or memory-record label name the build, in
        // which case a personal turn must name one of them — the same rule the
        // resident projection already lives under, applied at the memory
        // admission boundary. An atom carrying no engineering marker is
        // untouched, so nothing that existed before this changes behaviour.
        guard let scopingKind = scopingEntityKind(for: atom) else {
            return engineeringTopicsApply(atom, message: message, recentTurns: recentTurns)
        }
        let topics = atom.entities.filter { $0.kind == scopingKind }.map(\.label)
        guard !topics.isEmpty else {
            return engineeringTopicsApply(atom, message: message, recentTurns: recentTurns)
        }
        // The other half of the same finding: the one correction that DID apply
        // — topics ["response length", "personal conversations"], "User likes
        // fuller, personal answers when he asks about me" — was excluded,
        // because neither topic phrase appears contiguously in his question. A
        // personal turn is the second admission route for a personal-topic
        // correction, exactly as a taste-judgment turn is for a studio pointer.
        if scopingKind == entityKind,
           isPersonalTask(message),
           topics.contains(where: isPersonalTopic) {
            return true
        }
        // A studio pointer has a SECOND admission: the turn itself is a taste
        // judgment (a design review, an aesthetic call). Naming the work is the
        // ordinary way in; being asked which of two things is better is the
        // other. Neither is "the message happened to be long".
        if scopingKind == studioEntityKind, isTasteJudgmentTask(message) { return true }
        return mentions(topics, message: message, recentTurns: recentTurns)
    }

    /// The fail-open exit, one question later: global unless this atom's own
    /// topic tags or memory-record label name the build AND the turn is personal,
    /// in which case the turn has to name one of those topics.
    private static func engineeringTopicsApply(
        _ atom: ContextAtomDraft, message: String, recentTurns: [String]
    ) -> Bool {
        guard isPersonalTask(message),
              let labels = engineeringTopicLabels(for: atom)
        else { return true }
        return mentions(labels, message: message, recentTurns: recentTurns)
    }

    /// Does the turn NAME one of these labels, as a contiguous word run?
    /// Extracted unchanged from `applies` so the engineering check above uses the
    /// same notion of "the message is about this" as the topic check below.
    private static func mentions(
        _ labels: [String], message: String, recentTurns: [String]
    ) -> Bool {
        // Carry scope through a short referential follow-up, not through a
        // greeting or an unrelated topic simply because it follows work.
        let followup = isReferentialFollowup(message)
        let texts = [message] + (followup ? Array(recentTurns.suffix(2)) : [])
        return labels.contains { label in
            let needle = words(label)
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

    // MARK: - Personal turns

    /// Topics that make a correction a rule about PERSONAL conversation rather
    /// than about the work. Matched as a word run inside the topic label, so
    /// "personal conversations" and "personal answers" both qualify.
    static func isPersonalTopic(_ topic: String) -> Bool {
        let tokens = Set(words(topic))
        return !tokens.isDisjoint(with: [
            "personal", "personally", "feelings", "feeling", "emotional",
            "inner", "intimacy", "tenderness", "affection",
        ])
    }

    /// Is THIS turn User asking HER about her own inner life?
    ///
    /// Same shape and same discipline as `isTasteJudgmentTask`: a bounded
    /// predicate over the message, no second classifier, and deliberately hard
    /// to trip. Two conjuncts must hold — the turn is addressed to her, and it
    /// names her inner life.
    ///
    /// There is deliberately NO build-word veto and no "is it phrased as a
    /// question" requirement. Both rejected ordinary personal turns: "Tell me
    /// about your inner life" asks nothing lexically, "Have your tastes changed
    /// since the release?" says `release`, and neither is about the build. The
    /// mixed case is handled where it belongs instead — in `applies`, where an
    /// engineering atom on a personal turn survives exactly when the turn NAMES
    /// that item's own title — so a turn that really is about a work item keeps
    /// it, and a turn that merely borrows build vocabulary does not drag the
    /// whole backlog along.
    ///
    /// Still fail-open: when nothing here matches, the turn is not personal and
    /// selection behaves exactly as it did before any of this existed.
    public static func isPersonalTask(_ message: String) -> Bool {
        let tokens = words(message)
        guard !tokens.isEmpty else { return false }
        var present = Set(tokens)
        for token in tokens where token.count > 3 && token.hasSuffix("s") {
            present.insert(String(token.dropLast()))
        }
        let addressed = !present.isDisjoint(with: ["you", "your", "yours", "yourself"])
        guard addressed else { return false }
        // Her inner life, named. Bare "think" and "like" are excluded on
        // purpose: "what do you think" is the most common ops question there is.
        return !present.isDisjoint(with: [
            "feeling", "feelings", "feel", "felt", "thinking", "thought",
            "thoughts", "experienced", "experience", "experiences",
            "learned", "learnt", "changed", "developed", "development",
            "taste", "tastes", "mood", "inner", "yourself", "dream", "dreams",
            "lonely", "happy", "sad", "enjoyed", "enjoying", "artistic",
        ])
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
