import Foundation
import PersistenceCore

// Blueprint: | `ContextCorrectionScope.swift` | `ContextCorrectionScope`: applicability gates for canonical corrections and endpoint-scoped graph relations; selection utility grants no authority |

/// Applicability is not authority. Existing corrections remain global unless
/// their canonical memory explicitly supplies topics; attention/utility cannot
/// make a topic-scoped correction apply to an unrelated conversation.
///
/// Knowledge-graph relations require endpoint matches; exclusions report `outsideContextScope`.
///
/// Atoms without a scoping entity remain global.
public enum ContextCorrectionScope {
    public static let entityKind = "context_topic"
    /// Endpoint entities of a knowledge-graph relation atom.
    public static let relationshipEntityKind = "kg_entity"
    /// STUDIO pointers are scoped by work title, creator and medium, never judgment text.
    public static let studioEntityKind = "studio_work"

    /// Which entity kind scopes which atom kind. Absent ⇒ the atom is global.
    static func scopingEntityKind(for kind: ContextAtomKind) -> String? {
        switch kind {
        case .correction: entityKind
        case .relationship: relationshipEntityKind
        default: nil
        }
    }

    /// Kind-scoped atoms, explicitly scoped memories, then studio endpoints.
    /// Scope comes from the atom's own metadata, never ambient attention.
    static func scopingEntityKind(for atom: ContextAtomDraft) -> String? {
        if let byKind = scopingEntityKind(for: atom.kind) { return byKind }
        if atom.entities.contains(where: { $0.kind == entityKind }) { return entityKind }
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

    /// Build-specific topic tokens match whole words through the shared tokenizer.
    /// Interpersonal terms such as "design", "preference" and "personal" are excluded.
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

    public static func applies(
        _ atom: ContextAtomDraft, message: String, recentTurns: [String],
        subjectEntities: Set<ContextEntity> = []
    ) -> Bool {
        // Structured subjects do not depend on English follow-up recognition.
        // These are extracted turn entities, never ambient attention terms.
        let subjectWords = subjectEntities.flatMap { [$0.label, $0.id] }.joined(separator: "\n")
        // Backlog needs current-turn evidence on every turn, not just questions
        // about her inner life. Attention terms and a shared project name do
        // not make a particular engineering item relevant to casual chat.
        let isEngineering = atom.entities.contains { engineeringEntityKinds.contains($0.kind) }
        if isEngineering {
            let titles = atom.entities
                .filter { engineeringTitleEntityKinds.contains($0.kind) }
                .flatMap { [$0.label, $0.id] }
            return mentions(titles, message: message, recentTurns: recentTurns)
                || mentions(titles, message: subjectWords, recentTurns: [])
        }
        // An unscoped atom stays global unless its own metadata identifies
        // engineering work. That work needs evidence from this turn too.
        guard let scopingKind = scopingEntityKind(for: atom) else {
            return engineeringTopicsApply(atom, message: message + "\n" + subjectWords, recentTurns: recentTurns)
        }
        let topics = scopingTopics(atom, kind: scopingKind)
        guard !topics.isEmpty else {
            return engineeringTopicsApply(atom, message: message + "\n" + subjectWords, recentTurns: recentTurns)
        }
        // Personal-topic corrections also apply when this turn addresses her inner life,
        // even without a literal topic match.
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
            || mentions(topics, message: subjectWords, recentTurns: [])
    }

    static func scopingTopics(_ atom: ContextAtomDraft, kind: String) -> [String] {
        atom.entities
            .filter { $0.kind == kind }
            .map(\.label)
    }

    /// Only topic-scoped corrections are mandatory; topic-less corrections rank under the per-turn cap.
    public static func hasTopics(_ atom: ContextAtomDraft) -> Bool {
        guard let kind = scopingEntityKind(for: atom) else { return false }
        return !scopingTopics(atom, kind: kind).isEmpty
    }

    /// The fail-open exit, one question later: global unless this atom's own
    /// topic tags or memory-record label name the build, in which case the
    /// current turn has to name its subject. A broad label counts only when
    /// the memory supplies no more specific subject.
    private static func engineeringTopicsApply(
        _ atom: ContextAtomDraft, message: String, recentTurns: [String]
    ) -> Bool {
        guard let labels = engineeringTopicLabels(for: atom) else { return true }
        let subjects = labels.filter {
            !["project", "nativeagent", "codex", "worker", "workers"].contains(words($0).joined(separator: " "))
        }
        return mentions(subjects.isEmpty ? labels : subjects, message: message, recentTurns: recentTurns)
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

    // The lexical personal/taste/follow-up shortcuts below recognize English
    // only. Literal topic matching and supplied structured subjects work across
    // scripts; these shortcuts are not a universal intent classifier.

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

    /// Personal admission requires addressing her and naming her inner life.
    /// Build vocabulary and question phrasing do not constrain this predicate.
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

    /// Taste admission requires a judgment request and an aesthetic object, or an explicit taste phrase.
    /// Matching uses whole words from the shared tokenizer.
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
