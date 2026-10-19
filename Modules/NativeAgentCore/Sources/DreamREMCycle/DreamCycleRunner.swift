import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import CognitiveSubstrate

// DreamCycleRunner — Swift replacement for the retired daemon nightly
// reflective-journal pass. Merges the recent stretch of user/assistant messages
// across ALL chat sessions (chronological, capped, only what's NEW since the
// last dream via the .dream_state.json high-water mark), asks the configured
// LLM (under the full-Agent-persona-bypass — see nativeagent-rem-dream-cycle
// skill) to write ONE one-paragraph episodic dream for the day, and writes
// <dataRoot>/dream_diary/<YYYY-MM-DD>.md (one per calendar day; overwritten
// only on `force`). The old one-dream-PER-SESSION scheme is gone (2026-06-16).

public actor DreamCycleRunner {
    let dataRoot: URL
    private let personaRoot: URL
    private let llm: any LLMClient
    private let router: any ProviderRoutingProtocol
    private let now: @Sendable () -> Date
    private let recencyWindow: TimeInterval
    private let memoryDeltaProvider: DreamMemoryDeltaProvider
    private let feltSummaryProvider: DreamFeltSummaryProvider
    private let feltOriginProvider: DreamFeltOriginProvider
    private let receiptSink: DreamReceiptSink
    private let datedMoodSink: DreamDatedMoodSink?
    /// The already-resolved trust gate, when the caller has one. Supplied, it
    /// IS the answer; nil falls back to the local policy read below.
    private let gate: DreamREMGatePolicy?
    let fm = FileManager.default

    // Dream feeding caps (mirror the daemon's `_DREAM_*_BUDGET` constants
    // pinned by the vault skill). Newest-message-first; tool calls excluded.
    private static let deltaCharBudget: Int = 20_000
    private static let deltaCountLimit: Int = 150
    // Felt-tone section: the substrate already bounds its summary to 600 chars;
    // this is the runner-side belt-and-suspenders ceiling on that same section.
    private static let feltCharBudget: Int = 600
    // Studio citation (desk 903 phase 2). The dream's felt line names the
    // journal entries the feeling came from, so the causal chain runs from the
    // dream artifact back to the entry that caused it. Same node ceiling the
    // substrate's felt-day summary uses, and ids are bounded because they come
    // from a store this module does not own.
    public static let studioCitationReceiptKind = "dream.studio_citation"
    private static let studioCitationLimit: Int = 4
    private static let studioEntryIDMaxCharacters: Int = 120
    // Persona docs are loaded UNTRUNCATED for the full-Agent bypass per the
    // vault skill. The conversation + delta budgets above keep the request
    // bounded; truncating identity here would re-introduce the "reflecting
    // on a stub of Agent" bug the bypass was added to fix.

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        personaRoot: URL? = nil,
        llm: any LLMClient,
        router: any ProviderRoutingProtocol = SwiftNativeProviderRouting(),
        recencyWindow: TimeInterval = 24 * 60 * 60,
        memoryDeltaProvider: @escaping DreamMemoryDeltaProvider = { [] },
        feltSummaryProvider: @escaping DreamFeltSummaryProvider = { nil },
        feltOriginProvider: @escaping DreamFeltOriginProvider = { [] },
        receiptSink: @escaping DreamReceiptSink = { _, _ in },
        datedMoodSink: DreamDatedMoodSink? = nil,
        gate: DreamREMGatePolicy? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.personaRoot = personaRoot
            ?? PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        self.llm = llm
        self.router = router
        self.recencyWindow = recencyWindow
        self.memoryDeltaProvider = memoryDeltaProvider
        self.feltSummaryProvider = feltSummaryProvider
        self.feltOriginProvider = feltOriginProvider
        self.receiptSink = receiptSink
        self.datedMoodSink = datedMoodSink
        self.gate = gate
        self.now = now
    }

    /// `force` re-dreams the recent window even if the target entry already
    /// exists, re-reading the last `recencyWindow` and ignoring the high-water
    /// mark. It does NOT bypass the trust gate — mirrors how
    /// `runWeeklyREM(force:)` treats its weekly marker.
    ///
    /// MODEL (2026-06-16/17, the user): ONE dream per night at 03:30 Central,
    /// written under the previous Central calendar date and reflecting the
    /// recent stretch of life — the last `convCountLimit` user/assistant
    /// messages merged across ALL sessions in chronological order, bounded to
    /// what's NEW since the last dream (the high-water mark in
    /// `.dream_state.json`).
    /// Replaces the old one-dream-PER-SESSION walk, which split a single day
    /// into N entries (one per touched session, so a 9-line "three heys"
    /// session produced its own full dream) AND re-dreamed stale sessions on
    /// consecutive nights whenever their file mtime stayed inside the 24h
    /// window — manufacturing fake multi-date "evidence" for REM.
    ///
    /// `trigger` records WHO woke this pass and picks the target day. The
    /// scheduled 03:30 run writes the Central day that just ended (unchanged).
    /// A manual run happens mid-life, so it writes the day it is
    /// dreaming ABOUT — the current Central day — which is exactly the entry the
    /// NEXT 03:30 job would have written. That single file is the dedupe: the
    /// scheduled tick then finds it and skips honestly (`already_dreamt`), and
    /// the shared `.dream_state.json` high-water mark keeps either order from
    /// re-dreaming material the other already consumed.
    public func runNightlyDreamCycle(
        force: Bool = false,
        trigger: DreamTrigger = .schedule
    ) async throws -> DreamReport {
        if !isDreamEnabled() {
            return DreamReport(disabled: true, trigger: trigger)
        }

        let diaryDir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        let dateKey = entryDateKey(for: trigger)
        let outPath = diaryDir.appendingPathComponent("\(dateKey).md")

        // One dream per target day. A non-force run that already wrote the
        // target Central day's entry is a no-op — the mark advanced past that
        // material on the first run, so there's nothing new to add.
        if !force, fm.fileExists(atPath: outPath.path) {
            // 2026-09-06: except for the mood. When the previous run's sink
            // reported the integration was not durable it RELEASED the day's
            // claim so a later run could retry — but every later run for the
            // same night stopped right here, so the release bought nothing and
            // the night was still lost. The entry on disk carries the same
            // `_Mood: …_` line the sink was given, and the claim's
            // exclusive-create is the exclusion, so retry from the entry.
            await retryMoodIntegration(from: outPath, in: diaryDir, dateKey: dateKey)
            return DreamReport(trigger: trigger, skipReason: "already_dreamt")
        }

        // ONE dream run at a time (2026-09-06). The existence check above is
        // taken before the providers and the model are awaited — minutes before
        // the commit below — so two runs (the 03:30 job and a manual
        // one, or two clients) both passed it, both wrote the diary, and the
        // later one replaced the earlier entry while the mood claim at commit
        // had already integrated the EARLIER dream's tone: the diary then
        // described a different mood from the one she actually absorbed. The
        // same window let the unlocked high-water read-modify-write lose an
        // advance. A run that cannot take the reservation exits here having
        // written nothing; the reservation is released on every exit path,
        // and a crashed run's flock is released by the kernel.
        try? fm.createDirectory(at: diaryDir, withIntermediateDirectories: true)
        let reservation: DreamRunReservation?
        do {
            reservation = try DreamRunReservation.acquire(
                at: diaryDir.appendingPathComponent(".dream_run.lock"))
        } catch {
            return DreamReport(errors: ["dream reservation error: \(error)"], trigger: trigger)
        }
        guard let reservation else {
            return DreamReport(trigger: trigger, skipReason: "already_running")
        }
        defer { reservation.release() }

        // Re-read under the reservation: a run that finished while this one was
        // still starting has now written the target day's entry.
        if !force, fm.fileExists(atPath: outPath.path) {
            return DreamReport(trigger: trigger, skipReason: "already_dreamt")
        }

        // High-water mark: dream ONLY over messages new since the last dream, so
        // a 150-message day reflects on exactly those 150 and never re-reads what
        // a prior dream already covered. First-ever run (no mark) — and every
        // `force` run — falls back to `now - recencyWindow` (the last day) rather
        // than all of history. An unreadable mark is not a first run: the
        // dream stops and names the file instead of re-reading or skipping.
        var report = DreamReport(trigger: trigger)
        let mark: Date
        do {
            mark = force
                ? now().addingTimeInterval(-recencyWindow)
                : (try readDreamMark() ?? now().addingTimeInterval(-recencyWindow))
        } catch {
            report.errors.append("dream high-water mark \(dreamMarkPath().path) is unreadable (\(error)); "
                + "repair its lastDreamedAt or remove it to restart from the last day")
            return report
        }
        let feltOrigins: [DreamFeltOrigin]
        do {
            feltOrigins = try await feltOriginProvider()
        } catch {
            report.errors.append("felt origin read failed: \(error)")
            return report
        }
        let gathered: (messages: [(sessionId: String, role: String, content: String, source: String?)], newest: Date?, sources: [DreamSourceRef], material: [String: CognitiveReflectionCause])
        do {
            gathered = try gatherRecentMessagesAcrossSessions(
                since: mark,
                feltRank: Self.feltRankIndex(from: feltOrigins)
            )
        } catch {
            let message = "transcript read failed; dream will retry: \(error)"
            report.errors.append(message)
            FileHandle.standardError.write(Data("DreamCycleRunner: \(message)\n".utf8))
            return report
        }
        let (messages, newestIncluded, messageSources, sourceMaterial) = gathered
        report.sessionsProcessed = Set(messages.map { $0.sessionId }).count

        // Nothing new since the last dream → no empty entry, mark untouched.
        if messages.isEmpty {
            report.skipReason = "no_new_material"
            return report
        }
        guard let newestIncluded else {
            report.errors.append("message context had no high-water timestamp")
            return report
        }

        // Resolve the full Agent persona + memory-delta channel ONCE per run.
        let personaDocs = try await readDreamPersonaDocs(
            dataRoot: dataRoot, personaRoot: personaRoot, surface: "dream"
        )
        let memoryDeltas: [String]
        do {
            memoryDeltas = try await memoryDeltaProvider()
        } catch {
            report.errors.append("memory context read failed: \(error)")
            return report
        }
        // Felt tone — the substrate's read-time sense of what the day felt like.
        // nil means nothing was felt / affect is off. A provider failure is not
        // equivalent to silence: fail the run so the same day can be retried.
        let feltSummary: String?
        do {
            feltSummary = try await feltSummaryProvider()
        } catch {
            report.errors.append("felt context read failed: \(error)")
            return report
        }
        let citedStudioEntryIDs = Self.studioEntryCitations(
            from: feltOrigins, feltSummary: feltSummary)
        let dreamSystem = Self.dreamSystemPrompt(personaDocs: personaDocs)
        // Use the lane preference, including its unattended default or explicit pin.
        let pickedModel = await router.modelStringForSurface("dream")

        let prompt = buildCombinedPrompt(
            dateKey: dateKey,
            messages: messages, memoryDeltas: memoryDeltas, feltSummary: feltSummary,
            sourcePeerIds: CognitiveReflectionCause.unionPeerIds(messages.map { row in
                row.source.flatMap { sourceMaterial[$0]?.sourcePeerIds }
            }))
        let raw: String
        do {
            raw = try await llm.complete(
                prompt: prompt.text,
                system: dreamSystem,
                model: pickedModel,
                surface: "dream", purpose: "dream"
            )
        } catch {
            report.errors.append("llm error: \(error)")
            if ProviderFailure.classify(error) == .authExpired {
                let provider: String? = if case LLMError.authRejected(let provider, _) = error { provider }
                    else { await llm.servingProviderID(model: pickedModel, surface: "dream") }
                let account: String? = switch provider {
                case "openai_oauth_direct", "codex": "ChatGPT"
                case "anthropic_oauth_direct": "Claude"
                case "xai_oauth_direct": "xAI Grok"
                default: nil
                }
                if let account {
                    let signedIn = NativeOAuthFlow.signInStatus(providerID: provider ?? "", dataRoot: dataRoot).isSignedIn
                    let control = signedIn ? "Re-authenticate \(account)" : "Sign in with \(account)"
                    report.repair = Repair.remedy(owner: (provider ?? "dream provider") + " authorization", nextCall: nil,
                        tap: "Providers > Sign in, reconnect or add an account > \(account) > \(control)")
                }
            }
            return report
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            report.errors.append("invalid dream payload")
            return report
        }
        let payload: DreamPayload
        do {
            payload = try JSONDecoder().decode(DreamPayload.self, from: data)
        } catch {
            report.errors.append("invalid dream payload")
            return report
        }
        let markdown = try renderCombinedEntry(
            dateKey: dateKey,
            sessionCount: report.sessionsProcessed,
            payload: payload,
            studioEntryIDs: citedStudioEntryIDs,
            sources: messageSources,
            sourcePeerIds: prompt.peerIds
        )
        // A timed-out scheduler body is cancel()ed and abandoned; the LLM call
        // above honors cancellation, but a body that already got its response
        // could still fall through to commit this diary artifact. Bail before
        // any artifact write in this runner so a cancelled dream leaves no diary
        // directory/file and does NOT advance the high-water mark below.
        try Task.checkCancellation()
        if !fm.fileExists(atPath: diaryDir.path) {
            do {
                try fm.createDirectory(at: diaryDir, withIntermediateDirectories: true)
            } catch {
                report.errors.append("dream_diary mkdir failed: \(error)")
                return report
            }
        }

        // A force run can replace an existing diary entry. Capture it before the
        // first commit write so a subsequent high-water failure can restore the
        // exact prior entry rather than leaving a half-committed rewrite.
        let previousDiary: Data?
        if fm.fileExists(atPath: outPath.path) {
            do {
                previousDiary = try Data(contentsOf: outPath)
            } catch {
                report.errors.append("diary snapshot error: \(error)")
                return report
            }
        } else {
            previousDiary = nil
        }

        do {
            try markdown.data(using: .utf8)!.write(to: outPath, options: [.atomic])
        } catch {
            report.errors.append("write error: \(error)")
            return report
        }
        // Advance the mark forward-only to the newest message that fed this
        // dream so the next run starts strictly after it. The diary and mark are
        // one logical commit: if the mark cannot persist, restore/remove the
        // diary entry and report failure so the input remains retryable.
        do {
            try advanceDreamMark(to: newestIncluded)
        } catch {
            report.errors.append("high-water mark write error: \(error)")
            do {
                try rollbackDiary(at: outPath, previousDiary: previousDiary)
            } catch {
                report.errors.append("diary rollback error: \(error)")
            }
            return report
        }
        report.entriesWritten += 1
        report.reflectionMaterial = sourceMaterial
        report.reflectionMaterial["dream_diary/\(dateKey).md"] = CognitiveReflectionCause(
            text: markdown, sourcePeerIds: prompt.peerIds, sourceRefs: sourceMaterial.keys.sorted())
        // Change-only: a dream whose feeling owes nothing to the journal emits
        // NO receipt at all — the ordinary case must not become the loudest
        // thing in the ledger. Fired after the entry committed, for the same
        // reason the mood sink is: a dream that never happened cites nothing.
        if !citedStudioEntryIDs.isEmpty {
            await receiptSink(Self.studioCitationReceiptKind, .object([
                "date": .string(dateKey),
                "trigger": .string(trigger.rawValue),
                "entries": .array(citedStudioEntryIDs.map { .string($0) }),
            ]))
        }
        // The dream's own felt tone flows back into her slow disposition layer —
        // AFTER the entry committed, so a cancelled/failed/no-op dream can never
        // move her. The optional affect value is her judgment from that same call;
        // the mood phrase remains her prose and is never scored.
        //
        // At most ONE nudge per calendar day (gpt-5.5 review, 2026-07-09): the
        // file-exists guard above is skipped by `force` and racy between two
        // non-force runners, so the sink is gated on an exclusive-create claim
        // instead. A forced rewrite of today's entry keeps the FIRST dream's
        // nudge — one night, one felt tone, however many times it re-renders.
        //
        // 2026-09-06: the claim is taken FIRST (it is the exclusion that makes
        // the sink fire once) but RELEASED when the sink reports the
        // integration did not land. It used to be write-and-forget: a disk
        // full, a blocked substrate store, or an unavailable one left the day
        // permanently marked as integrated while nothing had moved — the night
        // was spent without ever being felt, and no retry could ever reclaim
        // it. The dream's own date key goes to the sink so the residue is
        // claimed against THIS night rather than whichever marker sorts last.
        await integrateMood(
            affect: payload.affect, in: diaryDir, dateKey: dateKey)
        return report
    }

    /// The marker records a confirmed integration only: the substrate's own
    /// per-night claims make a repeated delivery harmless, so a crash before
    /// the effect leaves the night retryable. The `already_dreamt` path retries here too.
    private func integrateMood(
        affect: Double?,
        in diaryDir: URL,
        dateKey: String
    ) async {
        let integrated = diaryDir.appendingPathComponent(".mood_integrated_\(dateKey)")
        guard let affect, let datedMoodSink, !fm.fileExists(atPath: integrated.path) else { return }
        guard await datedMoodSink(affect, dateKey) else {
            FileHandle.standardError.write(Data(
                "DreamCycleRunner: mood integration for \(dateKey) did not persist; a later run retries it\n".utf8))
            return
        }
        do { try Data().write(to: integrated, options: .atomic) } catch {
            FileHandle.standardError.write(Data(
                "DreamCycleRunner: mood for \(dateKey) integrated, marker not written (\(error)); a later run re-delivers it harmlessly\n".utf8))
        }
    }

    /// Retry an unclaimed night from the entry already on disk. Claiming is
    /// what makes this fire at most once, exactly as on the commit path: a
    /// night that integrated durably still holds its claim and is skipped here.
    private func retryMoodIntegration(
        from entry: URL,
        in diaryDir: URL,
        dateKey: String
    ) async {
        guard let markdown = try? String(contentsOf: entry, encoding: .utf8),
              let affect = Self.affectJudgment(inDiaryMarkdown: markdown) else { return }
        await integrateMood(affect: affect, in: diaryDir, dateKey: dateKey)
    }

    /// Retry only a recorded judgment; older prose is never reinterpreted.
    static func affectJudgment(inDiaryMarkdown markdown: String) -> Double? {
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("_Affect: "), line.hasSuffix("_") else { continue }
            let body = String(line.dropFirst(9).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(body), value.isFinite, (-1...1).contains(value) else { return nil }
            return value
        }
        return nil
    }

    // MARK: - Helpers

    private func isDreamEnabled() -> Bool {
        // One decision. When the caller resolved the gate from the NORMALIZED
        // trust policy, re-reading the raw file here could only disagree with
        // it — and did, on every fresh install. Without a gate, fall back to
        // the module's single saved-authority predicate rather than a second
        // hand-written copy of it.
        if let gate { return gate.dreamEnabled }
        return DreamREMGatePolicy.fromSavedAuthority(dataRoot: dataRoot).dreamEnabled
    }

    // MARK: high-water mark (.dream_state.json)

    private func dreamMarkPath() -> URL {
        dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
            .appendingPathComponent(".dream_state.json")
    }

    /// The createdAt of the newest message the last dream consumed. nil → no
    /// dream has run yet (caller falls back to `now - recencyWindow`); a mark
    /// that exists but cannot be read throws.
    private func readDreamMark() throws -> Date? {
        guard fm.fileExists(atPath: dreamMarkPath().path) else { return nil }
        guard case .object(let o) = try JSONValue.parse(Data(contentsOf: dreamMarkPath())),
              case .string(let s)? = o["lastDreamedAt"],
              let mark = Self.parseDaemonISO(s) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: dreamMarkPath().path])
        }
        return mark
    }

    /// Never regress the mark, so a re-run/force cannot return already-dreamed
    /// material to a future window. Completion metadata carries the trigger.
    private func advanceDreamMark(to date: Date) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let existing = try readDreamMark()
        let mark = (existing.map { max($0, date) }) ?? date
        let body = JSONValue.object([
            "lastDreamedAt": .string(iso.string(from: mark)),
        ])
        try body.serializedData(pretty: false).write(to: dreamMarkPath(), options: [.atomic])
    }

    private func rollbackDiary(at path: URL, previousDiary: Data?) throws {
        if let previousDiary {
            try previousDiary.write(to: path, options: [.atomic])
        } else if fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
    }

    /// World half (the recent cross-session messages — already chronological +
    /// capped by the gather) + Self half (memory deltas she's absorbed about
    /// herself since the last dream), fed at equal structural weight per the
    /// vault skill convention. A lightweight `[conversation <id>]` marker is
    /// emitted when the session changes so two parallel conversations in the
    /// same window don't blur together in her reflection.
    private func buildCombinedPrompt(
        dateKey: String,
        messages: [(sessionId: String, role: String, content: String, source: String?)],
        memoryDeltas: [String],
        feltSummary: String? = nil,
        sourcePeerIds: [String]?
    ) -> (text: String, peerIds: [String]?) {
        var convLines: [String] = []
        var lastSession: String? = nil
        for m in messages {
            if m.sessionId != lastSession {
                convLines.append("\n[conversation \(String(m.sessionId.prefix(8)))]\n")
                lastSession = m.sessionId
            }
            convLines.append("[\(m.role) | \(m.source ?? "source unavailable")] \(m.content)\n")
        }
        let worldHalf = convLines.joined()

        // Self half — newest-first memory-delta walk, bounded by the daemon
        // `_DREAM_DELTA_CHAR_BUDGET` / `_DREAM_DELTA_COUNT_LIMIT`. Empty
        // input → empty section; we still emit the header so the prompt
        // shape stays constant for the model. The provider hands us deltas
        // already newest-first, so iterate directly and chronological print
        // is `.reversed()` at output time only.
        var deltaLines: [String] = []
        var deltaUsed = 0
        var deltaCount = 0
        for entry in memoryDeltas {
            if deltaCount >= Self.deltaCountLimit { break }
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let line = "- \(trimmed)\n"
            if deltaUsed + line.count > Self.deltaCharBudget { break }
            deltaLines.append(line)
            deltaUsed += line.count
            deltaCount += 1
        }
        // deltaLines is newest-first (kept the newest entries). Print
        // oldest→newest so the model reads them in natural chronology.
        let selfHalf = deltaLines.reversed().joined()
        let selfBody = selfHalf.isEmpty ? "(no new memory deltas since the last dream)\n" : selfHalf

        // Felt tone — OMITTED entirely when nil/empty (unlike the always-emitted
        // World/Self headers). A felt section colors TONE, not content: the header
        // invites coloring, never scripting. Bounded again here as belt-and-braces.
        let feltBlock: String
        if let felt = feltSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !felt.isEmpty {
            let bounded = String(felt.prefix(Self.feltCharBudget))
            feltBlock = """
            --- HOW THE DAY FELT (her inner sense — let it color the dream's tone) ---
            \(bounded)

            """
        } else {
            feltBlock = ""
        }

        // These prose-only providers carry no provenance attestation.
        let peers = CognitiveReflectionCause.unionPeerIds([sourcePeerIds]
            + (selfHalf.isEmpty && feltBlock.isEmpty ? [] : [nil]))
        return ("""
        Date: \(dateKey)

        --- WORLD HALF (what happened recently across the user's conversations) ---
        \(worldHalf)
        --- SELF HALF (what you've absorbed about yourself since the last dream) ---
        \(selfBody)
        \(feltBlock)Reflect on BOTH halves at equal weight and produce the JSON dream \
        entry described in the system prompt. The summary is YOUR reflective \
        voice — neither a recap of the user's side nor a status report. If the \
        recent stretch was user-heavy, the Self half is what keeps this from \
        echoing him.
        """, peers)
    }

    // Full-Agent-persona-bypass: the dream pass runs OUTSIDE the live
    // assistant persona contract — but "outside" means freed from the
    // user-facing surface budget, NOT stripped of identity. The whole
    // untruncated persona is embedded so she dreams as herself instead of
    // as a generic reflective voice. (See nativeagent-rem-dream-cycle.)
    fileprivate static func dreamSystemPrompt(personaDocs: [String: String]) -> String {
        func body(_ name: String) -> String {
            let raw = personaDocs[name] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(empty)" : raw
        }
        return """
        You are the configured NativeAgent assistant writing a private nightly reflective dream-journal entry. \
        This pass runs OUTSIDE the live assistant persona — speak as your \
        reflective inner voice, not the user-facing assistant. You are NOT \
        in a chat with the user. The full untruncated persona is loaded \
        below so you reflect as yourself.

        --- SOUL.md ---
        \(body("SOUL.md"))

        --- VOICE.md ---
        \(body("VOICE.md"))

        --- GROWTH.md ---
        \(body("GROWTH.md"))

        --- USER.md ---
        \(body("USER.md"))

        --- AGENTS.md ---
        \(body("AGENTS.md"))

        --- OUTPUT CONTRACT ---
        Output ONLY a single JSON object with these exact keys: title \
        (string), summary (string, one paragraph), mood (string), affect \
        (your own optional felt judgment: a number from -1 to 1, or null when none), \
        emerging_themes (array of strings), surprising_moments (array of \
        strings), claims (array of {quote: string, source_refs: array of strings}). \
        For each claim in the summary, themes or moments, quote its exact words \
        and cite only the source identities beside the exchanges supporting it. \
        Use an empty source_refs array when no supplied exchange supports it. \
        No prose outside the JSON. No code fences.
        """
    }

    /// The journal entries the day's feeling actually came from, in the order
    /// the felt population gave them, deduped and bounded.
    ///
    /// Gated on there BEING a felt section: with no felt summary there is no
    /// feeling to attribute, and a citation with nothing to cite in would be an
    /// assertion the dream never made. Feeling-silence stays silence.
    static func studioEntryCitations(
        from origins: [DreamFeltOrigin],
        feltSummary: String?
    ) -> [String] {
        guard let felt = feltSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !felt.isEmpty else { return [] }
        var seen = Set<String>()
        var cited: [String] = []
        for origin in origins {
            guard let id = origin.studioEntryID else { continue }
            let bounded = String(id.prefix(studioEntryIDMaxCharacters))
            guard seen.insert(bounded).inserted else { continue }
            cited.append(bounded)
            if cited.count >= studioCitationLimit { break }
        }
        return cited
    }

    /// The citation line, or "" when nothing is cited. Verbatim ids: the whole
    /// point is that the string in the dream artifact matches the id in
    /// `journal.jsonl` exactly, so the chain can be walked by hand.
    static func studioCitationLine(_ entryIDs: [String]) -> String {
        guard !entryIDs.isEmpty else { return "" }
        let refs = entryIDs.map { "(studio entry \($0))" }.joined(separator: " ")
        return "_Felt from: \(refs)_\n\n"
    }

    private func renderCombinedEntry(
        dateKey: String,
        sessionCount: Int,
        payload: DreamPayload,
        studioEntryIDs: [String] = [],
        sources: [DreamSourceRef] = [],
        sourcePeerIds: [String]?
    ) throws -> String {
        var out = "# Dream — \(dateKey)\n\n"
        out += "**\(payload.title)**\n\n"
        out += "\(payload.summary)\n\n"
        out += "_Mood: \(payload.mood)_\n\n"
        if let affect = payload.affect { out += "_Affect: \(affect)_\n\n" }
        // Beside the mood, because it is that line's provenance: the dream's
        // felt-summary naming the entries it owes the feeling to. NOTHING about
        // this rides the prompt (NORTHSTAR clause 6) — it is written after the
        // model has spoken, and dreams are off-context besides.
        out += Self.studioCitationLine(studioEntryIDs)
        if !payload.emergingThemes.isEmpty {
            out += "**Emerging themes:**\n"
            for theme in payload.emergingThemes { out += "- \(theme)\n" }
            out += "\n"
        }
        if !payload.surprisingMoments.isEmpty {
            out += "**Surprising moments:**\n"
            for moment in payload.surprisingMoments { out += "- \(moment)\n" }
            out += "\n"
        }
        let convNote = sessionCount == 1 ? "1 conversation" : "\(sessionCount) conversations"
        out += "_(woven from \(convNote))_\n"
        let claims = try DreamEntryProvenance.renderBlock(payload.claims, content: out, sources: sources)
        out += try DreamEntryProvenance.peerBlock(sourcePeerIds)
        out += claims
        return out
    }

    /// The scheduled 03:30 run writes the Central day that just ended. A
    /// manually requested run happens mid-life and writes the
    /// day it is dreaming about — the current local (Central) calendar day, i.e.
    /// the entry the NEXT 03:30 job would have written. That collision is
    /// deliberate: it is the dedupe.
    ///
    /// 2026-09-17: a manual pass used to borrow the scheduled trigger, so an
    /// evening "run now" filed itself under YESTERDAY's date — the previous-day
    /// rule only makes sense for the 03:30 job, which wakes after the day it is
    /// reflecting on has ended.
    private func entryDateKey(for trigger: DreamTrigger) -> String {
        switch trigger {
        case .schedule:
            return DreamREMSchedule.dreamEntryDateKey(now: now())
        case .manual:
            return DreamREMSchedule.todayKey(
                now: now(),
                calendar: DreamREMSchedule.localCalendar()
            )
        }
    }
}
