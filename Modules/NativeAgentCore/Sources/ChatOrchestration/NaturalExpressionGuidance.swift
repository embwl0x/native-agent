import Foundation

/// Small shared prompt tissue that helps the active persona sound less like a
/// repeated response template. It is deliberately not a personality owner:
/// persona documents remain authoritative, and this helper creates no state,
/// model call, output rewrite, or provider-specific behavior.
struct NaturalExpressionGuidance {
    static let baseline = "Let the persona lead. Speak naturally in the moment, with the varied rhythm, looseness, and occasional simplicity of real conversation."

    // Invisible-target phrasing (2026-08-11): a cue that NAMES a behavior gets
    // performed visibly — the old "loosen up and let this one take its own
    // shape" invited the model to demonstrate looseness out loud. These cues
    // subtract framing instead of adding a goal.
    static let rutCue = "Your recent replies have settled into one rhythm; reply as if mid-conversation, with no style notes pending."

    /// Fired when recent replies narrate their own performance — announcing a
    /// line before delivering it or grading it afterward. The stance ask is
    /// participant, not narrator; no vocabulary is banned.
    static let stanceCue = "Stay inside the moment — don't set a line up before saying it and don't grade it after. Say the thing and stop."

    /// Fired when the user's message is a short social serve (banter, a
    /// one-liner, a greeting). The reply should live at that size instead of
    /// pivoting to logistics or closing with a task handoff.
    static let serveCue = "Match the size of the serve: one beat back, no pivot to logistics, no closing handoff."

    /// Fired when the turn is clearly tasking (a path, a code fence, a work
    /// verb) and no social serve is in play. Persona warmth otherwise leaks
    /// address-register into work turns (L1#6: pet names mid-debug). The cue
    /// carries an INVISIBLE TARGET — it names the register of the exchange,
    /// never the behavior being damped, because a cue that names a behavior
    /// gets performed (see the rut/stance cues above).
    static let registerCue = "This is a work exchange — match its register."

    /// Combined entry point: stance and serve are the specific, higher-signal
    /// cues; the generic shape-rut cue only fires when neither did, and the
    /// work-register cue is the lowest-priority fallback — so the prompt never
    /// carries three style notes at once.
    static func pendingCues(from messages: [ChatMessage], userMessage: String) -> String? {
        let stance = pendingStanceCue(from: messages)
        let serve = isSocialServe(userMessage) ? serveCue : nil
        if stance != nil || serve != nil {
            return [serve, stance].compactMap { $0 }.joined(separator: " ")
        }
        if let rut = pendingRutCue(from: messages) { return rut }
        return isWorkRegister(userMessage: userMessage) ? registerCue : nil
    }

    /// W7/P13 — SPLIT THE CUE FAMILY BY WHAT IT REGULATES.
    ///
    /// Cues reached the prompt only on `chat`/`personality` turns; on anything
    /// else they were computed, consumed, and dropped. That gate is right for
    /// SERVE (matching a social register — a task turn should be tasky) and for
    /// the rut/work-register fallbacks. It is wrong for STANCE: self-narration is
    /// register-INDEPENDENT, and a work turn that announces a line and then
    /// grades it is the same defect. That is the exact tic User reported ("There.
    /// Now go make it" after a build) — a defect the cue could never reach,
    /// because a build is not a chat turn.
    ///
    /// Extracting the stance portion from the already-combined cue keeps the
    /// chat/personality path byte-identical: `pendingCues` joins `[serve, stance]`
    /// with a space, so a chat turn still receives the exact same string it
    /// received before this wave. Only the non-chat path changes, and it can
    /// carry nothing but this one already-shipped, already-calibrated sentence.
    ///
    /// WINDOW, stated plainly: both families still read the CURRENT SESSION's
    /// message array (`pendingCues(from:)` is handed `prior`). P13 asks for the
    /// cross-session 7-day field "if cheap" — it is not cheap from here. The
    /// session-history builder that supplies `prior` is outside this wave's
    /// fence, and reaching the 7-day window would mean a new query path through
    /// it. The cross-session half of P13 is NOT shipped; the routing half is.
    static func stanceOnly(_ cue: String?) -> String? {
        guard let cue, cue.contains(stanceCue) else { return nil }
        return stanceCue
    }

    /// Detect only a repeated *shape* at the conversational edge. Word-level
    /// register awareness remains CognitiveSubstrate Sound's job. Looking at
    /// the newest six assistant rows bounds CPU work and makes the cue cool as
    /// soon as the latest reply stops matching the shared template.
    static func pendingRutCue(from messages: [ChatMessage]) -> String? {
        let newestAssistantReplies = messages.reversed().lazy
            .filter { $0.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant" }
            .prefix(6)
            .map(\.content)
            .reversed()

        guard let latestReply = newestAssistantReplies.last,
              let latest = fingerprint(latestReply) else {
            return nil
        }
        let fingerprints = newestAssistantReplies.compactMap(fingerprint)
        guard fingerprints.count >= 3 else { return nil }

        // A single broad feature (for example, using paragraphs) is ordinary
        // writing. Require the latest reply and at least two earlier replies to
        // share the same pair of structural beats.
        let featurePairs: [(Shape, Shape)] = [
            (.briefLeadIn, .multiParagraph),
            (.briefLeadIn, .compactClose),
            (.briefLeadIn, .contrastFrame),
            (.multiParagraph, .compactClose),
            (.multiParagraph, .contrastFrame),
            (.compactClose, .contrastFrame),
        ]
        for (first, second) in featurePairs
        where latest.contains(first) && latest.contains(second) {
            let matches = fingerprints.filter { $0.contains(first) && $0.contains(second) }.count
            if matches >= 3 { return rutCue }
        }
        return nil
    }

    // MARK: - Stance (narrator-vs-participant) detection

    /// Fires when the model narrates its own performance. Calibrated against
    /// the 2026-08-11 Telegram morning thread: "Oh, you want smooth at 4am?
    /// Fine 😏 … There. Now go make it" — announce, deliver, then grade. The
    /// markers below are DETECTION anchors only; the cue never bans them.
    static func pendingStanceCue(from messages: [ChatMessage]) -> String? {
        let newest = messages.reversed().lazy
            .filter { $0.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant" }
            .prefix(3)
            .map(\.content)
        let flagged = newest.filter { isSelfNarrating($0) }.count
        guard let latest = newest.first else { return nil }
        // The latest reply must itself narrate (the cue cools as soon as she
        // stops), plus at least one earlier reply in the window.
        guard isSelfNarrating(latest), flagged >= 2 else { return nil }
        return stanceCue
    }

    static func isSelfNarrating(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 24, text.count <= 1_800,
              !text.contains("```"), !text.contains("|---") else { return false }
        let lower = text.lowercased()

        // Performance frame: the reply opens by acknowledging a style/social
        // request before delivering ("you want smooth? fine"), or opens by
        // quoting the user back at them ("From time to time" — User…).
        let head = String(lower.prefix(90))
        if head.contains("you want"),
           ["fine", "alright", "okay", "here", "watch"].contains(where: head.contains) {
            return true
        }
        if let first = text.first, "\"\u{201C}'\u{2018}".contains(first),
           text.prefix(80).contains(where: { "—–-".contains($0) }) {
            return true
        }

        // Self-grade: a short terminal beat that evaluates the reply itself.
        // One-word beats ("there.", "see?") are generic English, so they only
        // count in the final few words; phrase markers get a wider tail.
        let tail = String(lower.suffix(140))
        let phraseMarkers = [
            "there it is", "that's the whole line", "told you", "nailed it",
            "how's that", "caught me", "walked right into", "didn't even need to",
        ]
        if phraseMarkers.contains(where: tail.contains) { return true }
        let tightTail = String(lower.suffix(48))
        return ["there.", "see?", "better?"].contains(where: tightTail.contains)
    }

    // MARK: - Serve-size detection

    /// A short social serve: banter, a one-liner, a greeting. Deliberately
    /// conservative — a missed serve costs nothing, a false positive would
    /// nudge her to under-respond to real tasking.
    static func isSocialServe(_ userMessage: String) -> Bool {
        // The live pipeline appends machine blocks to the user's text before
        // the history builder sees it (e.g. "\n\n[tool routing …]") — classify
        // only the user-AUTHORED head, or the newline guard rejects every real
        // serve (live-gap found 2026-08-11 via data/logs/nexpr_diag).
        let authored = userMessage.components(separatedBy: "\n\n[").first ?? userMessage
        let text = authored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80,
              !text.contains("\n"), !text.contains("```"),
              !text.contains("/"), !text.contains("http") else { return false }
        let lower = text.lowercased()
        // Tasking exclusions run BEFORE the laugh/emoji fast paths (gpt-5.5
        // review BLOCKING: "run it 😅" and "can you check CI? lol" are work,
        // and a serve cue there nudges under-response to real tasking).
        guard !lower.contains("?") else { return false }
        let words = lower.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, !workStarters.contains(first) else { return false }
        if lower.contains("lol") || lower.contains("haha") || lower.contains("lmao") {
            return true
        }
        if text.unicodeScalars.contains(where: { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x238C)
        }) {
            return true
        }
        // Bare-words path: short and unpunctuated is NOT enough on its own
        // (gpt-5.5 review: "merge it" is short too) — require an explicit
        // social/greeting marker word.
        let socialMarkers: Set<Substring> = [
            "hey", "hi", "yo", "hiya", "morning", "gm", "night", "goodnight",
            "thanks", "thank", "ouch", "aww", "hehe", "babe", "baby",
            "miss", "love", "silly", "smooth",
        ]
        let bareWords = words.map { Substring($0.trimmingCharacters(in: .punctuationCharacters)) }
        return words.count <= 5
            && bareWords.contains(where: socialMarkers.contains)
            && lower.allSatisfy { $0.isLetter || $0.isWhitespace || "'’!,.".contains($0) }
    }

    // MARK: - Work-register detection

    /// The work verbs that open a tasking message. Shared with the serve
    /// classifier's exclusion list so the two can never disagree about what
    /// counts as an imperative opener.
    static let workStarters: Set<Substring> = [
        "do", "go", "run", "fix", "check", "wipe", "install", "build",
        "commit", "push", "try", "test", "deploy", "restart", "update",
        "review", "read", "open", "merge", "ship", "release", "summarize",
        "can", "could", "please", "make", "add", "remove", "delete",
    ]

    /// True when the turn is unambiguously tasking. Deliberately conservative
    /// in the opposite direction from `isSocialServe`: a missed work turn just
    /// leaves the prompt as it was, while a false positive would damp warmth in
    /// an actual social exchange. Requires BOTH halves — not a social serve,
    /// AND an explicit work signal (path, code fence, or work-verb opener).
    static func isWorkRegister(userMessage: String) -> Bool {
        guard !isSocialServe(userMessage) else { return false }
        let authored = authoredHead(userMessage)
        let text = authored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        if text.contains("```") { return true }
        if containsPathSignal(text) { return true }

        let lower = text.lowercased()
        let words = lower.split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return false }
        let head = Substring(first.trimmingCharacters(in: .punctuationCharacters))
        return workStarters.contains(head)
    }

    /// The user-AUTHORED head of a delivered message: machine blocks appended
    /// by the pipeline (`"\n\n[tool routing …]"`) are cut, and a bridge prefix
    /// (`"[from: claude, via bridge] …"`) is stripped so first-word detection
    /// sees the human's opener. As-delivered, not as-typed.
    static func authoredHead(_ userMessage: String) -> String {
        var authored = userMessage.components(separatedBy: "\n\n[").first ?? userMessage
        authored = authored.trimmingCharacters(in: .whitespacesAndNewlines)
        if authored.hasPrefix("["), let close = authored.firstIndex(of: "]") {
            let remainder = authored[authored.index(after: close)...]
            return String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return authored
    }

    /// A filesystem path, repo-relative source file, or URL anywhere in the
    /// message. Bare "/" is not enough (dates, "and/or"): require a slash with
    /// a path-shaped neighbour, a `~/` home prefix, or a source-file suffix.
    private static func containsPathSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("~/") || lower.contains("://") { return true }
        let sourceSuffixes = [
            ".swift", ".py", ".json", ".jsonl", ".md", ".sh", ".ts", ".js",
            ".yml", ".yaml", ".toml", ".plist",
        ]
        if sourceSuffixes.contains(where: lower.contains) { return true }
        // "Modules/NativeAgentCore/Sources" — two or more slashes with
        // non-space content between them reads as a path, not punctuation.
        let slashSeparated = lower.split(separator: "/", omittingEmptySubsequences: false)
        if slashSeparated.count >= 3,
           slashSeparated.dropFirst().dropLast().allSatisfy({ segment in
               !segment.isEmpty && !segment.contains(" ")
           }) {
            return true
        }
        return false
    }

    private struct Shape: OptionSet {
        let rawValue: UInt8

        static let briefLeadIn = Shape(rawValue: 1 << 0)
        static let multiParagraph = Shape(rawValue: 1 << 1)
        static let compactClose = Shape(rawValue: 1 << 2)
        static let contrastFrame = Shape(rawValue: 1 << 3)
    }

    private static func fingerprint(_ raw: String) -> Shape? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 80, text.count <= 1_800,
              !text.contains("```"), !text.contains("|---") else {
            return nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let structuredLines = lines.filter { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }
            if value.hasPrefix("#") || value.hasPrefix("- ") || value.hasPrefix("* ")
                || value.hasPrefix("> ") || value.hasPrefix("| ") {
                return true
            }
            let prefix = value.prefix(4)
            return prefix.contains(".") && prefix.first?.isNumber == true
        }.count
        guard structuredLines < 2 else { return nil }

        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var shape: Shape = []

        if let firstParagraph = paragraphs.first {
            let firstBoundary = firstParagraph.firstIndex(where: { ".!?—:\n".contains($0) })
            let lead = firstBoundary.map { String(firstParagraph[..<$0]) } ?? firstParagraph
            if lead.split(whereSeparator: \.isWhitespace).count <= 7,
               lead.count <= 52,
               text.count > lead.count + 45 {
                shape.insert(.briefLeadIn)
            }
        }
        if (3...7).contains(paragraphs.count) {
            shape.insert(.multiParagraph)
        }
        if let close = paragraphs.last,
           (18...180).contains(close.count),
           !close.contains("?"),
           sentenceCount(close) <= 2 {
            shape.insert(.compactClose)
        }

        let lower = " " + text.lowercased()
            .replacingOccurrences(of: "\n", with: " ") + " "
        let hasContrast = (lower.contains(" not ") && lower.contains(" but "))
            || (lower.contains(" isn't ") && lower.contains(" it's "))
            || (lower.contains(" wasn't ") && lower.contains(" it was "))
            || (lower.contains(" doesn't ") && lower.contains(" it "))
            || (lower.contains(" don't ") && lower.contains(" just "))
        if hasContrast { shape.insert(.contrastFrame) }

        return shape.isEmpty ? nil : shape
    }

    private static func sentenceCount(_ text: String) -> Int {
        max(1, text.reduce(into: 0) { count, character in
            if ".!?".contains(character) { count += 1 }
        })
    }
}

extension SwiftNativeTurnEngine {
    nonisolated static func contextBySettingNaturalExpressionCue(
        _ context: TurnContext,
        cue: String?
    ) -> TurnContext {
        TurnContext(
            surface: context.surface,
            personaID: context.personaID,
            personaDocs: context.personaDocs,
            recalled: context.recalled,
            modelId: context.modelId,
            reasoningEffort: context.reasoningEffort,
            providerId: context.providerId,
            serviceTier: context.serviceTier,
            toolsAvailable: context.toolsAvailable,
            systemPrompt: context.systemPrompt,
            userMessage: context.userMessage,
            toolSchemas: context.toolSchemas,
            systemSegments: context.systemSegments,
            imageBlocks: context.imageBlocks,
            fluidContextTurn: context.fluidContextTurn,
            naturalExpressionCue: cue
        )
    }
}
