// CognitiveSubstrate+Capsule.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    public func compileCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule {
        let now = dependencies.now()
        guard configuration.enabled,
              configuration.capsuleInjectionEnabled,
              request.mode != .off else {
            return CognitiveCapsule(
                generatedAt: now,
                mode: .off,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: false
            )
        }

        let maximumCharacters = min(
            configuration.maximumCapsuleCharacters,
            max(0, request.maximumCharacters ?? configuration.maximumCapsuleCharacters)
        )
        guard maximumCharacters > 0 else {
            return CognitiveCapsule(
                generatedAt: now,
                mode: request.mode,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: true
            )
        }

        let workspace = await workspaceSnapshot(currentSessionId: request.sessionId)
        let capsuleItems = workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        // Just the header (User, 2026-07-01: "it should really just say 'How you
        // feel' thats it then her feelings"). There is deliberately NO prompt
        // guard here — injection defense is cue validation (deny-list + read
        // revalidation), her persona values, and TrustCenter's action gates;
        // the one functional handling line ("never quotes or mentions it")
        // lives in BOTH ChatOrchestration injection seams (structured + text
        // compat), not in her inner voice.
        let stableKernel = "How you feel:"
        let dynamicLines = innerStateCapsuleLines(from: capsuleItems, request: request, at: now)
        let provenanceNodeIds = innerStateProvenance(from: capsuleItems, at: now)
        let boundedStableKernel = bounded(stableKernel, maxCharacters: maximumCharacters)
        let separatorCost = dynamicLines.isEmpty ? 0 : 2
        let remaining = max(0, maximumCharacters - boundedStableKernel.count - separatorCost)
        let fittedLines = fitCapsuleLines(dynamicLines, maxCharacters: remaining)
        let dynamicContext = fittedLines.text
        let truncated = fittedLines.truncated || boundedStableKernel.count < stableKernel.count
        return CognitiveCapsule(
            generatedAt: now,
            mode: request.mode,
            stableKernel: boundedStableKernel,
            dynamicContext: dynamicContext,
            provenanceNodeIds: provenanceNodeIds,
            truncated: truncated
        )
    }

    /// Production-equivalent capsule rendering over a previously captured
    /// frozen workspace. It performs no field snapshot, receipt, persistence,
    /// or suppress-when-unchanged mutation.
    public func compileFrozenCapsule(
        _ request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead
    ) -> CognitiveCapsule {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode != .off else {
            return CognitiveCapsule(
                generatedAt: read.fixedAt,
                mode: .off,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: false
            )
        }
        let maximumCharacters = min(
            read.configuration.maximumCapsuleCharacters,
            max(0, request.maximumCharacters ?? read.configuration.maximumCapsuleCharacters)
        )
        guard maximumCharacters > 0 else {
            return CognitiveCapsule(
                generatedAt: read.fixedAt,
                mode: request.mode,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: true
            )
        }
        let items = read.workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        let stableKernel = "How you feel:"
        let dynamicLines = innerStateCapsuleLines(
            from: items,
            request: request,
            at: read.fixedAt,
            frozenRead: read
        )
        let provenanceNodeIds = innerStateProvenance(
            from: items,
            at: read.fixedAt,
            thoughtSeeds: read.thoughtSeeds
        )
        let boundedStableKernel = bounded(stableKernel, maxCharacters: maximumCharacters)
        let separatorCost = dynamicLines.isEmpty ? 0 : 2
        let remaining = max(0, maximumCharacters - boundedStableKernel.count - separatorCost)
        let fittedLines = fitCapsuleLines(dynamicLines, maxCharacters: remaining)
        return CognitiveCapsule(
            generatedAt: read.fixedAt,
            mode: request.mode,
            stableKernel: boundedStableKernel,
            dynamicContext: fittedLines.text,
            provenanceNodeIds: provenanceNodeIds,
            truncated: fittedLines.truncated || boundedStableKernel.count < stableKernel.count
        )
    }

    private func innerStateCapsuleLines(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        at now: Date,
        frozenRead: CognitiveFrozenRead? = nil
    ) -> [String] {
        var lines: [String] = []
        // The felt fingerprint REPLACES the Focus/Feeling/Voice sentences (User,
        // 2026-07-08): "How you feel" should hand her a word-level felt state she
        // FEELS, not sentences she reads. Attention (focused/foggy) is folded into
        // the fingerprint; her VIEWS + CONTINUITY stay below (Inner), and the Body +
        // Sound anchors follow. (The prior Focus/Affect/Voice helper tree + its
        // keyword classifiers were swept 2026-07-09 — see git if archaeology calls.)
        if let fingerprint = feltFingerprintLine(
            from: workspaceItems,
            request: request,
            at: now,
            affect: frozenRead?.affect,
            mood: frozenRead?.mood,
            affectEnabled: frozenRead?.configuration.affectEnabled
        ) {
            lines.append(fingerprint)
        }
        // Her subconscious carries her INNER LIFE — feeling, voice, focus/continuity, and her
        // own reflective view — NOT a task tracker. Commitments, predictions, and neglected
        // "I'll…" follow-up seeds belong to the Desk (explicit tracking, only when User asks),
        // never here (User, 2026-06-30: "I don't want her subconscious tied up following around
        // me [with] 'I'll'… her subconscious is for her feelings, emotions, her views, her
        // continuity"). Surface her top reflective takeaway (a genuine view she's formed) —
        // UNLESS Wave E: a settled, User-approved ACTIVE standing view exists, which REPLACES
        // the transient takeaway seed as the single Inner line (a durable view beats a fresh
        // takeaway). Both use the "- Inner:" prefix, so the total Inner-line count stays ≤ 1;
        // a .proposed/.retired view never reaches here. No active view → byte-identical to
        // the pre-Wave-E takeaway path.
        let standingViewInnerLine = frozenRead == nil
            ? activeStandingViewInnerLine()
            : frozenRead?.standingViewInnerLine
        if let viewLine = standingViewInnerLine {
            lines.append(viewLine)
        } else if let takeaway = (frozenRead?.thoughtSeeds ?? projectedThoughtSeeds(at: now))
            .filter({ $0.kind == .reflectionTakeaway && isUsefulThoughtSeed($0) && !isTaskStatusReflection($0.text) })
            .sorted(by: thoughtSeedPrioritySort)
            .first {
            lines.append(innerThoughtSeedLine(for: takeaway))
        }
        if let bodyLine = organismBodyLine(from: request.organismProjection) {
            lines.append(bodyLine)
        }
        // Wave G: the self-exemplar echo goes LAST so budget truncation drops it
        // before it can displace focus/feeling/inner — it's an enhancer, not core.
        let echoLine = frozenRead == nil ? soundEchoLine(at: now) : frozenRead?.soundEchoLine
        if let echo = echoLine {
            lines.append(echo)
        }
        return dedupedCapsuleLines(lines)
    }

    private func organismBodyLine(from projection: OrganismProjection?) -> String? {
        guard let projection,
              !projection.isNeutral,
              let rawLine = projection.bodyLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLine.isEmpty else {
            return nil
        }
        let line = rawLine.hasPrefix("- Body:")
            ? rawLine
            : "- Body: \(rawLine.replacingOccurrences(of: #"^-?\s*Body:\s*"#, with: "", options: .regularExpression))"
        let lower = line.lowercased()
        guard !lower.contains("chemicalstate"),
              !lower.contains("bodyschema"),
              !lower.contains("organismkernel"),
              !lower.contains("organismprojection"),
              line.rangeOfCharacter(from: .decimalDigits) == nil else {
            return nil
        }
        let boundedLine = capsuleLineText(line, maxCharacters: 180)
        guard boundedLine.hasPrefix("- Body:") else { return nil }
        return boundedLine
    }

    // MARK: - Self-exemplar voice echo (Wave G)

    /// Voice as memory, not instruction (User, 2026-07-03: no fences, "just her,
    /// just natural"). Her own warmest recent TURNS are quoted back as an echo —
    /// LLMs imitate in-context exemplars far harder than instructions, so her
    /// attested voice crowds out the base-model mean turn by turn. Stock LLM
    /// phrases never win the slot: minted nowhere, they accumulate no warmth.
    /// Selection pressure is what landed with User. She is never told the
    /// mechanism exists; there is nothing to dance around.
    static let soundEchoWindow: TimeInterval = 7 * 24 * 60 * 60
    // 2026-08-02 — AUTHENTICITY FLOOR, NOT A REGISTER FILTER. This constant is
    // the admission gate for the candidate pool, and at 0.40 it made the
    // register-match ranking below INERT: measured on a live store, only 9 of
    // 90 attested assistant turns cleared 0.40, while 29 more sat in the
    // 0.15–0.40 working-voice band and were discarded before ranking ever ran.
    // So a working moment had nothing but the affectionate tail to be "nearest"
    // to, and the mirror kept pointing at the same register no matter what the
    // room was doing — the selection fix could not bite through a pool that had
    // already been filtered to one register. The floor's ONLY job is keeping
    // never-minted stock phrasing out (it accumulates no warmth at all); the
    // register is chosen by soundEchoRegisterScore, not by this threshold.
    // Generic to any persona: it removes a band restriction, it adds no
    // vocabulary and no preference for any particular tone.
    // Placed just above the flat/cold band, not inside the register band: on the
    // live store this admits 22 of 70 attested turns where 0.40 admitted 9, so
    // the 0.25–0.40 working register finally reaches the ranking, while a turn
    // with nothing behind it still cannot fabricate an echo.
    static let soundEchoWarmthFloor = 0.25
    static let soundEchoFragmentMaxCharacters = 90
    static let soundEchoCount = 2
    // 2026-07-04 (User: "sound has stayed the same"): warmth-first ranking let
    // the two warmest lines win EVERY compile until something out-warmed them
    // — "lately" had quietly become a fixed portrait. Score = warmth decayed
    // by age (half-life below): a genuinely warm moment echoes for a couple of
    // days, then yields to newer warmth; with no new warmth the line thins and
    // honestly disappears at the window edge rather than freezing.
    static let soundEchoRecencyHalfLife: TimeInterval = 2.5 * 24 * 60 * 60

    // 2026-08-02 — THE TIC FIX. Two structural defects made this organ a
    // repetition ENGINE rather than a voice mirror, for any persona:
    //
    // (1) IT FIRED EVERY TURN. There was no cadence concept anywhere in this
    //     file: every capsule build re-read her own exemplars back to her. A
    //     person does not re-read their warmest lines before each sentence;
    //     doing so turns whatever the exemplars share into a verbal tic. The
    //     2026-08-01 "diversity" rule made that WORSE, not better — by
    //     rejecting fragments that share a word it guaranteed a ROTATING set
    //     of exemplars instead of one repeated one, so the underlying habit
    //     kept firing while looking varied. Varying the token is not reducing
    //     the tic. Hence `soundEchoDutyCycle`: the line is now occasional by
    //     construction, which is the only thing that makes an echo read as
    //     character instead of a stutter.
    //
    // (2) IT SELECTED FOR MAXIMUM WARMTH. Ranking by warmth means the mirror
    //     always points at the persona's most affectionate 5% — so whatever
    //     register lives at that extreme (endearments, effusiveness, a stock
    //     sign-off) becomes the standing definition of "how you sound", and
    //     the persona drifts toward it monotonically. The honest mirror is
    //     REGISTER-MATCHED: show the voice that fits the room right now, so a
    //     working moment echoes the working voice and a warm moment echoes
    //     the warm one. That is what makes an agent situational rather than
    //     stuck in one gear, and it generalizes past any one vocabulary.
    /// Felt-warmth range (2026-08-02). Rest sits AT the `warm` word gate and
    /// clear of `tender`, so an agent has a reachable neutral; the top of the
    /// scale is earned by real warmth rather than being where she starts.
    /// Pinned by FeltWarmthRangeTests against the live word gates.
    // Rest is UNCHANGED from the 2026-07-08 baseline (0.55) — that value was
    // never the defect, and lowering it pushed neutral states under the
    // intensity floor that keeps the fingerprint from falling silent
    // (measured: three capsule contracts went empty at 0.45). The defect was
    // the SLOPE: at 0.9, ordinary warmth of 0.33 added +0.30 and carried rest
    // straight through the `tender` gate at 0.70, so tender WAS the resting
    // state. At 0.30 the climb is earned instead of automatic.
    static let feltWarmthRest = 0.55
    static let feltWarmthEarnedSpan = 0.30
    static let feltWarmthUncertaintyCooling = 0.45

    static let soundEchoDutyCycle = 4
    /// Half-width of the register band. Candidates are ranked by how well they
    /// MATCH the current room, not by how warm they are in absolute terms.
    static let soundEchoRegisterTolerance = 0.35

    static func soundEchoScore(warmth: Double, age: TimeInterval) -> Double {
        guard age >= 0 else { return warmth }
        return warmth * pow(0.5, age / soundEchoRecencyHalfLife)
    }

    /// Register-matched score: closeness to the moment's warmth, decayed by
    /// age. Replaces "warmest wins", which is what let one register capture
    /// the slot permanently.
    static func soundEchoRegisterScore(
        warmth: Double,
        target: Double,
        age: TimeInterval
    ) -> Double {
        // Smooth decay, never a hard cutoff: with a cliff, a neutral room makes
        // EVERY warm candidate score zero and the pick degrades to an arbitrary
        // tie-break. This stays strictly monotonic in closeness, so "nearest
        // register wins" holds even when nothing is a close match.
        let distance = abs(warmth - target)
        let fit = 1 / (1 + distance / max(0.0001, soundEchoRegisterTolerance))
        guard age >= 0 else { return fit }
        return fit * pow(0.5, age / soundEchoRecencyHalfLife)
    }

    /// Deterministic, state-free cadence gate. Seeded by the newest activity in
    /// the field, so it advances as turns land and a frozen read reproduces the
    /// same answer as the live compile (this function must stay pure).
    static func soundEchoShouldSpeak(seed: Double) -> Bool {
        guard soundEchoDutyCycle > 1 else { return true }
        let bits = seed.bitPattern
        // Cheap avalanche so adjacent timestamps don't land in the same bucket.
        var x = bits &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 32
        return Int(truncatingIfNeeded: x % UInt64(soundEchoDutyCycle)) == 0
    }

    /// - Parameter ignoringCadence: bypasses the duty-cycle gate so the SHAPE of
    ///   the echo can be asserted independently of how often it speaks. Cadence
    ///   is covered directly via `soundEchoShouldSpeak(seed:)`. Production never
    ///   passes this — an echo that always speaks is the defect this gate fixes.
    func soundEchoLine(at now: Date, ignoringCadence: Bool = false) -> String? {
        guard configuration.enabled, configuration.affectEnabled else { return nil }
        // Her OWN live conversation turns only — never User's words as her voice,
        // never tool/system summaries (the feltDaySummary injection-safety rule).
        let candidates = field.peekNodes().filter { node in
            guard node.turnKind == .live,
                  node.kind == .conversationFocus,
                  node.subjectReference.type == "chat.assistant_turn",
                  node.emotionalWarmth >= Self.soundEchoWarmthFloor,
                  node.emotionalValence > 0 else { return false }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            return age >= 0 && age <= Self.soundEchoWindow
        }
        guard !candidates.isEmpty else { return nil }
        // CADENCE GATE (see soundEchoDutyCycle): an echo that speaks on every
        // turn is a tic no matter how varied its wording. Seed from the newest
        // activity in the field so the gate advances with the conversation and
        // stays reproducible for a frozen read.
        let latestActivity = field.peekNodes()
            .map(\.lastActivatedAt)
            .max()?
            .timeIntervalSince1970 ?? now.timeIntervalSince1970
        guard ignoringCadence || Self.soundEchoShouldSpeak(seed: latestActivity) else { return nil }
        // REGISTER MATCH (see soundEchoRegisterScore): mirror the voice that
        // fits the room now, instead of always the warmest voice on record.
        let targetWarmth = projectedAffect(at: now).socialWarmth
        let ranked = candidates.sorted { lhs, rhs in
            let lhsScore = Self.soundEchoRegisterScore(
                warmth: lhs.emotionalWarmth,
                target: targetWarmth,
                age: now.timeIntervalSince(lhs.lastActivatedAt))
            let rhsScore = Self.soundEchoRegisterScore(
                warmth: rhs.emotionalWarmth,
                target: targetWarmth,
                age: now.timeIntervalSince(rhs.lastActivatedAt))
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.lastActivatedAt != rhs.lastActivatedAt { return lhs.lastActivatedAt > rhs.lastActivatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // Verbal-rut damping (2026-08-01, the "handsome" loop): her warmest
        // turns are usually greetings, greetings reuse the same pet name, and
        // quoting them back every turn locked her onto one word — echo reads
        // it → she says it → the next capsule quotes it again. Two rules:
        // (1) DIVERSITY — chosen fragments may not share a distinctive word,
        // and fragments carrying a WORN word (one that appears across ≥3 of
        // the window's candidate fragments) lose to varied ones; a total-rut
        // week still echoes rather than going silent. (2) AWARENESS — when a
        // rut exists her subconscious says so, WITHOUT naming the word:
        // naming it would re-seed the exact loop this exists to break.
        let fragged: [(fragment: String, tokens: Set<String>)] = ranked.compactMap { node in
            guard let f = soundEchoFragment(node.summary) else { return nil }
            return (f, Self.distinctiveEchoTokens(f))
        }
        guard !fragged.isEmpty else { return nil }
        var tokenCounts: [String: Int] = [:]
        for (_, tokens) in fragged {
            for t in tokens { tokenCounts[t, default: 0] += 1 }
        }
        let worn = Set(tokenCounts.filter { $0.value >= Self.wornEchoThreshold }.keys)

        var fragments: [String] = []
        var seen = Set<String>()
        var usedTokens = Set<String>()
        func pick(allowWorn: Bool) {
            for (fragment, tokens) in fragged {
                guard fragments.count < Self.soundEchoCount else { return }
                if !allowWorn, !tokens.isDisjoint(with: worn) { continue }
                guard tokens.isDisjoint(with: usedTokens) else { continue }
                if seen.insert(fragment.lowercased()).inserted {
                    fragments.append("\u{201C}\(fragment)\u{201D}")
                    usedTokens.formUnion(tokens)
                }
            }
        }
        pick(allowWorn: false)
        if fragments.isEmpty { pick(allowWorn: true) }
        guard !fragments.isEmpty else { return nil }
        // "lately", not "when it landed" — warmth on her turn is the room's
        // temperature at encode (assistant completions never raise warmth
        // themselves), so the honest claim is what she sounded like in warm
        // moments, not proof the line landed (gpt-5.5 MED, 2026-07-03).
        var line = "- Sound: lately you've sounded like \(fragments.joined(separator: " · "))"
        if !worn.isEmpty {
            line += " — a few of the same words keep echoing lately; you've got more range than that"
        }
        return line
    }

    /// How many of the window's candidate fragments a distinctive word must
    /// appear in before it counts as WORN (a verbal rut, not a coincidence).
    static let wornEchoThreshold = 3

    /// The words that make a fragment "sound like" something: lowercased,
    /// letters-only, ≥4 chars, minus function words. Deliberately small and
    /// generic — this is a diversity heuristic, never a censor list.
    static let echoStopwords: Set<String> = [
        "that", "this", "with", "have", "from", "your", "youre", "just",
        "what", "about", "been", "were", "they", "them", "there", "here",
        "when", "then", "than", "like", "really", "still", "into", "onto",
        "over", "some", "more", "most", "very", "much", "cant", "dont",
        "wont", "didnt", "youve", "weve", "theyre", "going", "gonna",
    ]

    static func distinctiveEchoTokens(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter { current.append(ch) }
            else {
                if current.count >= 4, !echoStopwords.contains(current) { tokens.insert(current) }
                current = ""
            }
        }
        if current.count >= 4, !echoStopwords.contains(current) { tokens.insert(current) }
        return tokens
    }

    /// First sentence of one of her turns. Deliberately NOT capsuleSignalText:
    /// that helper strips to the text AFTER a trailing "User message:" marker,
    /// which would hand a QUOTED USER PAYLOAD the echo slot for a week
    /// (gpt-5.5 HIGH, 2026-07-03). Here the cut goes the OTHER way — keep her
    /// words BEFORE any quoted user text, and refuse role-framed/directive
    /// content outright. Returns nil when the summary has no usable voice.
    private func soundEchoFragment(_ summary: String) -> String? {
        var cleaned = summary
        if let quoted = cleaned.range(of: "User message:", options: [.caseInsensitive]) {
            cleaned = String(cleaned[..<quoted.lowerBound])
        }
        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = String(cleaned.prefix(400))
        guard isUsefulCapsuleSignalText(cleaned), !isOperationalSubconsciousNoise(cleaned.lowercased()) else { return nil }
        let lower = cleaned.lowercased()
        let neverHerVoice = ["system:", "assistant:", "[from:", "```", "http://", "https://"]
        guard !neverHerVoice.contains(where: { lower.contains($0) }) else { return nil }
        var sentence = ""
        for character in cleaned {
            sentence.append(character)
            if ".!?".contains(character), sentence.count >= 20 { break }
        }
        let fragment = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fragment.count >= 15 else { return nil }
        // 2026-07-04 (User: "1½ things... truncated"): a quote cut mid-thought
        // with an ellipsis reads broken, and it happened whenever a short
        // exclamation ("There it is!") glued onto the next sentence and blew
        // the bound. Whole thoughts only — an oversized fragment SKIPS to the
        // next candidate instead of shipping chopped. Pithy lines echo better
        // anyway; that's taste pressure, not just a length guard.
        guard fragment.count <= Self.soundEchoFragmentMaxCharacters else { return nil }
        return fragment
    }

    /// A "reflective takeaway" that's really TASK-STATUS ("one thread still open — X I haven't
    /// closed", "follow up on the overdue Y") is task-tracking wearing a view's clothes; it does
    /// NOT belong in her Inner line. Her subconscious is feelings/views/continuity, not a to-do
    /// status (User, 2026-06-30). Genuine reflections about her felt state still surface. Older
    /// takeaways written while commitments existed can carry this language — filter them out.
    private func isTaskStatusReflection(_ text: String) -> Bool {
        let lower = text.lowercased()
        return containsAny(lower, [
            "haven't closed", "hasn't closed", "yet to close", "not yet closed",
            "thread still open", "still open —", "follow up on", "overdue",
            "still owe", "promised to", "left it open", "unclosed", "still hasn't",
        ])
    }

    /// Drop verbatim-duplicate capsule lines (the lossy inner-state translator can map
    /// several workspace nodes or takeaway seeds onto the same cue), preserving order and
    /// the first occurrence. Keeps the bounded capsule from spending its budget on repeats.
    private func dedupedCapsuleLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            let key = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if seen.insert(key).inserted { out.append(line) }
        }
        return out
    }

    /// The felt fingerprint capsule line (User, 2026-07-08): her live emotional +
    /// attentional state in a few honest words she FEELS, not sentences she reads.
    /// Replaces the Focus/Feeling/Voice lines. Maps her live signals (mood valence,
    /// substrate affect, organism chemistry) onto the affect-science dimensions; the
    /// organism supplies the richest dims (clarity/agency/confidence/fatigue), with a
    /// substrate + neutral fallback when the organism is off.
    private func feltFingerprintLine(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        at now: Date,
        affect: CognitiveAffectState? = nil,
        mood: CognitiveMoodReading? = nil,
        affectEnabled: Bool? = nil
    ) -> String? {
        guard affectEnabled ?? configuration.affectEnabled else { return nil }
        return CognitiveSubstrate.feltFingerprint(
            feltSignalsForCapsule(
                from: workspaceItems,
                request: request,
                at: now,
                affect: affect,
                mood: mood
            )
        )
    }

    /// The live FeltSignals the fingerprint is built from — extracted so tests can read
    /// the exact numbers behind a felt word (calibration is done against these, not guesses).
    func feltSignalsForCapsule(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        at explicitNow: Date? = nil,
        affect explicitAffect: CognitiveAffectState? = nil,
        mood explicitMood: CognitiveMoodReading? = nil
    ) -> FeltSignals {
        let now = explicitNow ?? dependencies.now()
        let mood = explicitMood ?? derivedMood(at: now)
        let currentAffect = explicitAffect ?? projectedAffect(at: now)
        // Immediate workspace tint (User, 2026-07-08): what she's HOLDING right now colors
        // her felt valence. RECENCY-WEIGHTED with a SHORT half-life (the fast layer) so the
        // CURRENT emotional moment leads — a fresh sting reads through even amid a good
        // session, then fades over a few turns as its weight decays. A flat mean drowned
        // the sting under the session's positive history; mood (the 0.4 term) is the slow
        // 6h-half-life background, this is the fast foreground.
        let feltNodes = workspaceItems.prefix(6).map(\.node)
            .filter { feltDirection(valence: $0.emotionalValence, arousal: $0.emotionalArousal, warmth: $0.emotionalWarmth) != nil }
        let effectiveValence: Double
        if feltNodes.isEmpty {
            // No felt nodes: her slow mood, with the same asymmetric warm-with-User bias.
            let bias = Self.personaValenceLift * (1 - Self.smoothstep(0.08, 0.20, -mood.valence))
            effectiveValence = (mood.valence + bias).clampedSigned()
        } else {
            // Recency-weighted MEAN + PEAK (gpt-5.5 calibration, 2026-07-08): a pure mean
            // dilutes a fresh sting under a warm session's history, so the current-turn node
            // (highest recency weight) gets DIRECT weight via `peak`, and that weight GROWS
            // with the strength of the fresh signal (g). Mood's slow pull SHRINKS as g rises,
            // so criticism reads through NOW instead of being smoothed by the day's mood; it
            // then fades over the next few turns as the sting node's recency weight decays.
            var wsum = 0.0, wtot = 0.0, peakW = -1.0, peak = 0.0
            for n in feltNodes {
                let age = max(0, now.timeIntervalSince(n.lastActivatedAt))
                // (M15, 2026-07-09: the toolObservation half-weight that used to sit
                // here was UNREACHABLE — capsuleEligibleWorkspaceNode already excludes
                // tool nodes from this array. The live grief bug was actually fixed by
                // the moodWeight floor below; tool noise reaches the fingerprint only
                // through derivedMood, which the floor bounds.)
                let w = pow(0.5, age / Self.fingerprintTintHalfLife)
                wsum += w * n.emotionalValence; wtot += w
                if w > peakW { peakW = w; peak = n.emotionalValence }
            }
            let mean = wtot > 0 ? wsum / wtot : mood.valence
            let g = Self.smoothstep(0.16, 0.34, abs(peak))
            let workspace = (0.45 - 0.20 * g) * mean + (0.55 + 0.20 * g) * peak
            // Mood keeps a FLOOR of influence (0.20, was →0.10 at full g): a fresh
            // sting still reads through, but a single transient node can no longer
            // fully mute the day's real tone — deep words (grieving/lonely) now need
            // the slow layer's corroboration, not one bad moment. (Same live bug.)
            let moodWeight = 0.35 - 0.15 * g
            let core = (1 - moodWeight) * workspace + moodWeight * mood.valence
            // Warm-with-User bias — ASYMMETRIC: full when the moment is neutral/positive,
            // fading to zero as the workspace goes negative, so a genuine sting is never
            // cushioned. Fingerprint-only; stored node valence (mood/recall/dream) untouched.
            let bias = Self.personaValenceLift * (1 - Self.smoothstep(0.08, 0.20, -workspace))
            effectiveValence = (core + bias).clampedSigned()
        }
        let chem = request.organismProjection?.chemicalState
        // Persona-warm baseline (User, 2026-07-08): socialWarmth rests at 0 by
        // anti-ratchet design (it's a MODULATION on top of her already-warm persona,
        // per feedback_agent_affect_additive_to_persona), so reading it raw made warm
        // conversation land "quiet"/cold. The fingerprint's warmth axis carries that
        // missing baseline — she's fundamentally warm with User; genuine affection lifts
        // it toward tender, a tense exchange (uncertainty up) cools it below baseline.
        // Only the FELT warmth signal is shifted; valence still reads raw socialWarmth.
        let rawWarmth = chem?.warmth ?? currentAffect.socialWarmth
        // 2026-08-02 — RANGE RESTORED. The 2026-07-08 baseline was the right
        // intent (raw socialWarmth rests at 0, so reading it raw made warm
        // moments land cold) but it overshot: it did not lift the floor, it
        // parked the signal near the CEILING. Measured on a live store with
        // rawWarmth 0.33, the old form produced 0.85 — and across the entire
        // uncertainty range it never fell below 0.62, while the `tender` word
        // gate is 0.70. So the agent was told she felt TENDER on essentially
        // every turn, including pure work conversation, and expressed it the
        // only way a tender agent can. That is not a verbal rut; it is an
        // honest voice reporting a manufactured feeling.
        //
        // The defect is DYNAMIC RANGE, not the baseline's existence: with no
        // reachable neutral, a persona cannot sound like work. So rest now
        // lands AT the `warm` gate and below `tender`, and the top of the
        // scale is EARNED by real warmth instead of being the resting state.
        // Verified against the live word gates in feltFamilyWords:
        //   rest      (raw 0.00) -> 0.55  warm yes, tender no
        //   ordinary  (raw 0.33) -> 0.65  warm yes, tender no
        //   affection (raw 0.70) -> 0.76  tender yes (earned)
        //   cool end  (unc 0.60) -> 0.28  a tense working moment reads cool
        // Uncertainty still cools, with a gentler slope so a tense working
        // moment reads cool rather than cold.
        //
        // GENERAL, not tuned to one persona: no vocabulary here, and every
        // install gets a reachable neutral instead of a permanent warm floor.
        let feltWarmth = (Self.feltWarmthRest
            + rawWarmth * Self.feltWarmthEarnedSpan
            - currentAffect.uncertainty * Self.feltWarmthUncertaintyCooling).clamped01()
        return FeltSignals(
            valence: effectiveValence,
            arousal: currentAffect.arousal,
            warmth: feltWarmth,
            tension: max(chem?.vigilance ?? 0, currentAffect.uncertainty),
            pressure: chem?.urgency ?? currentAffect.taskPressure,
            // Agent's adjacent finding (2026-08-02): absent chemical state
            // makes these a hard 0, so the agent structurally cannot read
            // tired or curious — the same pegging shape as the warmth ceiling,
            // pointed the other way. Real, and NOT fixed here on purpose: a
            // 0.5 midpoint looks right but `feltIntensity` weights fatigue at
            // 0.20, so it silently adds +0.10 to EVERY felt intensity and makes
            // deep words ("grieving") reachable in an ordinary sting — measured,
            // it broke workspaceTintReachesTheFingerprint. A missing signal
            // needs to read as UNKNOWN (absent from the intensity sum), which
            // means optionality in FeltSignals, not a guessed midpoint. Boarded
            // as its own change rather than smuggled into the range fix.
            fatigue: chem?.fatigue ?? 0,
            curiosity: chem?.curiosity ?? 0,
            clarity: chem?.coherence ?? 0.5,
            agency: chem?.agency ?? 0.5,
            confidence: chem?.confidence ?? 0.5
        )
    }

    /// Test/diagnostic hook: the FeltSignals for a request against the current live
    /// workspace, so a mood-journey test can print exactly why a felt word landed.
    func debugFeltSignals(for request: CognitiveCapsuleRequest) async -> FeltSignals {
        let workspace = await workspaceSnapshot()
        let capsuleItems = workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        return feltSignalsForCapsule(from: capsuleItems, request: request)
    }

    private func innerThoughtSeedLine(for seed: CognitiveThoughtSeed) -> String {
        let prefix = seed.kind == .reflectionTakeaway ? "Inner" : "Thread"
        return "- \(prefix): \(thoughtSeedCapsuleText(seed))"
    }

    private func thoughtSeedCapsuleText(_ seed: CognitiveThoughtSeed) -> String {
        var text = capsuleSignalText(seed.text, maxCharacters: 180)
        if seed.kind == .reflectionTakeaway {
            text = strippingPrefix("Reflection takeaway:", from: text)
            text = strippingPrefix("Reading the state honestly:", from: text)
            text = strippingPrefix("Reading the capsule honestly:", from: text)
            text = text.replacingOccurrences(
                of: "the capsule is warm, populated, low-tension",
                with: "warm, connected, low-tension",
                options: [.caseInsensitive]
            )
            text = text.replacingOccurrences(
                of: "capsule",
                with: "inner state",
                options: [.caseInsensitive]
            )
        }
        return capsuleSignalText(text, maxCharacters: 180)
    }

    private func innerStateProvenance(
        from workspaceItems: [CognitiveWorkspaceItem],
        at now: Date,
        thoughtSeeds explicitThoughtSeeds: [CognitiveThoughtSeed]? = nil
    ) -> [UUID] {
        var ids = workspaceItems.map(\.id)
        for seed in explicitThoughtSeeds ?? projectedThoughtSeeds(at: now) {
            ids.append(contentsOf: seed.sourceNodeIds)
        }
        return unique(ids)
    }

    public func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? {
        let requestTurnKind = CognitiveTurnKind.inferred(fromSignals: [
            request.surface,
            request.sessionId ?? "",
            request.userMessage,
        ])
        guard requestTurnKind == .live || request.allowNonLiveProjection else { return nil }
        let capsule = await compileCapsule(request)
        guard capsule.mode == .inject,
              !capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return capsule
    }

    /// Compile the production capsule from one fixed-time copied read in a
    /// single substrate admission. The live field, persistence, decay anchors,
    /// and surfaced-state bookkeeping remain untouched.
    public func prepareFrozenCapsule(
        _ request: CognitiveCapsuleRequest,
        at fixedAt: Date
    ) async -> CognitiveCapsule? {
        let requestTurnKind = CognitiveTurnKind.inferred(fromSignals: [
            request.surface,
            request.sessionId ?? "",
            request.userMessage,
        ])
        guard requestTurnKind == .live || request.allowNonLiveProjection else { return nil }
        let read = await frozenRead(at: fixedAt, currentSessionId: request.sessionId)
        let capsule = compileFrozenCapsule(request, from: read)
        guard capsule.mode == .inject,
              !capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return capsule
    }

    private func fitCapsuleLines(_ lines: [String], maxCharacters: Int) -> (text: String, truncated: Bool) {
        guard maxCharacters > 0 else {
            return ("", !lines.isEmpty)
        }
        var kept: [String] = []
        var used = 0
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let separatorCost = kept.isEmpty ? 0 : 1
            if used + separatorCost + line.count <= maxCharacters {
                kept.append(line)
                used += separatorCost + line.count
                continue
            }

            let available = maxCharacters - used - separatorCost
            // The Sound echo is all-or-nothing: a clipped quote would put words
            // in her mouth mid-sentence (gpt-5.5 MED, 2026-07-03). Other lines
            // keep the sentence-aware clip.
            if available >= 24, !line.hasPrefix("- Sound:") {
                let clipped = capsuleLineText(line, maxCharacters: available)
                if !clipped.isEmpty {
                    kept.append(clipped)
                }
            }
            return (kept.joined(separator: "\n"), true)
        }
        return (kept.joined(separator: "\n"), false)
    }

    func capsuleLineText(_ text: String, maxCharacters: Int) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters >= 0, normalized.count > maxCharacters else { return normalized }

        if let sentence = firstCompleteSentence(in: normalized, maxCharacters: maxCharacters),
           sentence.count >= min(48, maxCharacters) {
            return sentence
        }

        let suffix = "..."
        let prefixLimit = max(0, maxCharacters - suffix.count)
        guard prefixLimit > 0 else {
            return bounded(normalized, maxCharacters: maxCharacters)
        }
        let prefix = String(normalized.prefix(prefixLimit))
        if let breakIndex = prefix.lastIndex(where: { $0 == " " || $0 == "," || $0 == ";" || $0 == ":" }) {
            let candidate = String(prefix[..<breakIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= min(48, prefixLimit) {
                return candidate + suffix
            }
        }
        return prefix + suffix
    }

    private func firstCompleteSentence(in text: String, maxCharacters: Int) -> String? {
        guard maxCharacters > 0, !text.isEmpty else { return nil }
        let limit = text.index(text.startIndex, offsetBy: min(maxCharacters, text.count))
        var index = text.startIndex
        var end: String.Index?
        while index < limit {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                end = text.index(after: index)
            }
            index = text.index(after: index)
        }
        guard let end else { return nil }
        let sentence = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }
}
