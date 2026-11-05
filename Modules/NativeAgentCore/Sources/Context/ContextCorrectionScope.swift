import Foundation
import PersistenceCore

// Blueprint: | `ContextCorrectionScope.swift` | `ContextCorrectionScope`: canonical scope gates, never authority |

/// Applicability grants no authority: only canonical topics scope corrections; attention cannot widen them. Graph relations require endpoint matches
/// (`outsideContextScope` otherwise); unscoped atoms stay global.
public enum ContextCorrectionScope {
    public static let entityKind = "context_topic"
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

    /// Scope comes from the atom's own metadata, never ambient attention.
    static func scopingEntityKind(for atom: ContextAtomDraft) -> String? {
        if let byKind = scopingEntityKind(for: atom.kind) { return byKind }
        if atom.entities.contains(where: { $0.kind == entityKind }) { return entityKind }
        return atom.entities.contains { $0.kind == studioEntityKind } ? studioEntityKind : nil
    }

    /// Engineering entities mark backlog regardless of atom kind.
    public static let engineeringEntityKinds: Set<String> = [
        "desk_handle", "project",
    ]

    /// Only an item's title names specific work; the shared project label would admit the entire backlog whenever the product is mentioned.
    public static let engineeringTitleEntityKinds: Set<String> = [
        "desk_handle",
    ]

    /// Build-specific topic tokens match whole words through the shared tokenizer. Interpersonal terms such as "design", "preference" and "personal" are
    /// excluded.
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

    /// Exclude instruction, preference and correction labels: interpersonal memories use them too.
    public static let engineeringRecordLabels: Set<String> = ["project"]

    /// Nil means no engineering marker: the atom stays global.
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
        // Extracted turn subjects work across languages; ambient attention grants no scope.
        let subjectWords = subjectEntities.flatMap { [$0.label, $0.id] }.joined(separator: "\n")
        // Backlog always needs current-turn evidence; ambient attention and a shared project name do not identify a work item.
        let isEngineering = atom.entities.contains { engineeringEntityKinds.contains($0.kind) }
        if isEngineering {
            let titles = atom.entities
                .filter { engineeringTitleEntityKinds.contains($0.kind) }
                .flatMap { [$0.label, $0.id] }
            return mentions(titles, message: message, recentTurns: recentTurns)
                || mentions(titles, message: subjectWords, recentTurns: [])
        }
        // Engineering metadata requires evidence from this turn even on an otherwise unscoped atom.
        guard let scopingKind = scopingEntityKind(for: atom) else {
            return engineeringTopicsApply(atom, message: message + "\n" + subjectWords, recentTurns: recentTurns)
        }
        let topics = scopingTopics(atom, kind: scopingKind)
        guard !topics.isEmpty else {
            return engineeringTopicsApply(atom, message: message + "\n" + subjectWords, recentTurns: recentTurns)
        }
        // Inner-life questions admit personal corrections without a literal topic match.
        if scopingKind == entityKind,
           isPersonalTask(message),
           topics.contains(where: isPersonalTopic) {
            return true
        }
        // A taste judgment can admit a studio pointer without naming the work; message length grants no admission.
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

    /// Engineering metadata requires the turn to name its subject; a broad label counts only without a more specific subject.
    private static func engineeringTopicsApply(
        _ atom: ContextAtomDraft, message: String, recentTurns: [String]
    ) -> Bool {
        guard let labels = engineeringTopicLabels(for: atom) else { return true }
        let subjects = labels.filter {
            !["project", "nativeagent", "codex", "worker", "workers"].contains(words($0).joined(separator: " "))
        }
        return mentions(subjects.isEmpty ? labels : subjects, message: message, recentTurns: recentTurns)
    }

    /// Share contiguous-word matching between engineering and topic admission.
    private static func mentions(
        _ labels: [String], message: String, recentTurns: [String]
    ) -> Bool {
        // Carry scope through a short referential follow-up, not through a greeting or an unrelated topic simply because it follows work.
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

    // English-only intent shortcuts supplement cross-script literal topics and structured subjects.

    /// Whole-word runs admit related personal-topic labels without requiring exact label equality.
    static func isPersonalTopic(_ topic: String) -> Bool {
        let tokens = Set(words(topic))
        return !tokens.isDisjoint(with: [
            "personal", "personally", "feelings", "feeling", "emotional",
            "inner", "intimacy", "tenderness", "affection",
        ])
    }

    /// Personal admission requires addressing the agent's inner life, independent of build vocabulary or question phrasing.
    public static func isPersonalTask(_ message: String) -> Bool {
        let tokens = words(message)
        guard !tokens.isEmpty else { return false }
        var present = Set(tokens)
        for token in tokens where token.count > 3 && token.hasSuffix("s") {
            present.insert(String(token.dropLast()))
        }
        let addressed = !present.isDisjoint(with: ["you", "your", "yours", "yourself"])
        guard addressed else { return false }
        // Bare "think" and "like" also occur in operational questions and cannot establish personal intent.
        return !present.isDisjoint(with: [
            "feeling", "feelings", "feel", "felt", "thinking", "thought",
            "thoughts", "experienced", "experience", "experiences",
            "learned", "learnt", "changed", "developed", "development",
            "taste", "tastes", "mood", "inner", "yourself", "dream", "dreams",
            "lonely", "happy", "sad", "enjoyed", "enjoying", "artistic",
        ])
    }

    // MARK: - Taste-judgment turns

    /// Whole-word matching requires a judgment request with an aesthetic object, or an explicit taste phrase.
    public static func isTasteJudgmentTask(_ message: String) -> Bool {
        let tokens = words(message)
        guard !tokens.isEmpty else { return false }
        let joined = " " + tokens.joined(separator: " ") + " "
        for phrase in ["design review", "art direction", "aesthetic call"]
        where joined.contains(" " + phrase + " ") {
            return true
        }
        // Bare singulars admit plural objects; fixed-set membership keeps a mistaken singular from inventing a match.
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

    /// Incidental pronouns in greetings or weather questions must not carry work forward.
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
