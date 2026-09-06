import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// DreamCycleRunner — Swift replacement for the retired daemon nightly
// reflective-journal pass. Merges the recent stretch of user/assistant messages
// across ALL chat sessions (chronological, capped, only what's NEW since the
// last dream via the .dream_state.json high-water mark), asks the configured
// LLM (under the full-Agent-persona-bypass — see nativeagent-rem-dream-cycle
// skill) to write ONE one-paragraph episodic dream for the day, and writes
// <dataRoot>/dream_diary/<YYYY-MM-DD>.md (one per calendar day; overwritten
// only on `force`). The old one-dream-PER-SESSION scheme is gone (2026-06-16).

/// What woke the dream. `schedule` is the 03:30 America/Chicago daily job —
/// the integrity fallback. `pressure` is the organism's own identity-Dream lane
/// firing once its residual sleep pressure, quiet window and 24-hour refractory
/// all resolved (NORTHSTAR clause 4, 2026-09-01). Receipts carry it so a dream's
/// provenance is never guessed from its timestamp.
public enum DreamTrigger: String, Sendable, Equatable, CaseIterable {
    case schedule
    case pressure
}

public struct DreamReport: Sendable, Equatable {
    public var sessionsProcessed: Int
    public var entriesWritten: Int
    public var errors: [String]
    public var disabled: Bool
    public var trigger: DreamTrigger
    /// Set when a run wrote nothing for a reason that is NOT a failure, so the
    /// scheduler's existing skipped-outcome shape can say WHICH honest reason:
    /// `already_dreamt` (the target day's entry exists — typically because a
    /// pressure-fired dream beat the 03:30 job to it) or `no_new_material`.
    public var skipReason: String?

    public init(
        sessionsProcessed: Int = 0,
        entriesWritten: Int = 0,
        errors: [String] = [],
        disabled: Bool = false,
        trigger: DreamTrigger = .schedule,
        skipReason: String? = nil
    ) {
        self.sessionsProcessed = sessionsProcessed
        self.entriesWritten = entriesWritten
        self.errors = errors
        self.disabled = disabled
        self.trigger = trigger
        self.skipReason = skipReason
    }
}

/// Provider for the "self half" of the dream prompt — recent memory deltas
/// (persona-feedback episodic entries, KG nudges, anything she's absorbed
/// about herself since the last dream). Each string is one pre-formatted
/// delta. Default returns empty so tests don't need to wire one. Production
/// (BackgroundLoopsAssembly) wires this against SwiftNativeMemoryV2 filtered
/// by the `persona-feedback` tag.
public typealias DreamMemoryDeltaProvider = @Sendable () async throws -> [String]

/// Provider for the "felt" tone of the dream prompt — ONE bounded, read-time
/// summary of what the day FELT like, pulled from the cognitive substrate's
/// felt layer (per-node emotional tags + derived mood). Returns nil when nothing
/// was felt / affect is disabled, in which case the dream's felt section is
/// OMITTED entirely (feeling-silence stays silence, mirroring the capsule's
/// neutral path). Default returns nil so tests don't need to wire one. Production
/// (BackgroundLoopsAssembly) wires this against the substrate's
/// `feltDaySummary(at:)`. It colors the dream's TONE — it never scripts content.
public typealias DreamFeltSummaryProvider = @Sendable () async throws -> String?

/// The PROVENANCE half of one felt node — subject + metadata, and nothing else.
/// `DreamFeltSummaryProvider` says what the day felt like; this says where a
/// feeling CAME FROM, which is the only thing the dream needs beyond the tone.
///
/// Desk 903 phase 2 (the studio journal on the cognitive bus) mints a felt node
/// carrying its journal entry id in BOTH `subject.id` (with subject type
/// `studio_entry`) and `metadata["studioEntryId"]` — see the DREAM-CITATION
/// SEAM note in CognitiveSubstrate+StudioEvents.swift. Either alone is enough
/// here, so a node minted by either half still cites.
public struct DreamFeltOrigin: Sendable, Equatable {
    /// The seam's subject type for a filed journal entry.
    public static let studioEntrySubjectType = "studio_entry"
    /// The seam's metadata key for the same id.
    public static let studioEntryIDMetadataKey = "studioEntryId"

    public var subjectType: String?
    public var subjectID: String?
    public var metadata: [String: String]

    public init(
        subjectType: String? = nil,
        subjectID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.subjectType = subjectType
        self.subjectID = subjectID
        self.metadata = metadata
    }

    /// The journal entry this feeling came from, or nil when it came from
    /// anywhere else. Nil is the common case and is not a gap.
    public var studioEntryID: String? {
        if let value = metadata[Self.studioEntryIDMetadataKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if subjectType == Self.studioEntrySubjectType,
           let value = subjectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }
}

/// Provider for the felt nodes' provenance behind `DreamFeltSummaryProvider`'s
/// text — the same last-24h felt population, subject/metadata only. Default is
/// empty, so a dream with nothing wired cites nothing and reads exactly as it
/// did before.
public typealias DreamFeltOriginProvider = @Sendable () async throws -> [DreamFeltOrigin]

/// Receipt channel for the dream lane. DreamREMCycle holds no substrate
/// reference (and must not: cognition lives above it), so a receipt it owns is
/// handed OUT to whoever holds the store — the same shape
/// `CognitiveSubstrate.recordReceipt(kind:payload:)` already takes. Default is
/// a no-op.
public typealias DreamReceiptSink = @Sendable (_ kind: String, _ payload: JSONValue) async -> Void

/// Completion sink for the nightly dream's own MOOD line — the felt tone of what she
/// dreamt. Fired exactly once per dream, AFTER the diary entry has actually been written
/// (a cancelled, failed, or no-op dream must never move her), and only when the LLM
/// emitted a non-empty `mood` field. The counterpart to `DreamFeltSummaryProvider`:
/// that one carries the day's feeling INTO the dream, this one carries the dream's
/// feeling back OUT into her slow disposition layer. Default is a no-op so
/// focused runner tests need not wire one.
///
/// 2026-09-06, two changes:
///   • the DATE KEY of the dream being delivered is passed explicitly. The sink
///     used to recover it by scanning for the greatest `.mood_integrated_*`
///     marker on disk, and those markers accumulate — a 03:30 scheduled dream
///     keys to the PREVIOUS day, so any newer marker named a different dream
///     and the residue mint was suppressed against the wrong night's claim.
///   • it returns whether the integration is DURABLE. The runner claims the day
///     before calling (that claim is what makes the sink fire once), and
///     releases the claim again when this returns false, so a night whose
///     disposition write failed is retryable instead of permanently spent.
///
/// 2026-09-06 (second pass): both of those ride a SECOND, optional sink rather
/// than a widened parameter list. A Swift closure type cannot give a parameter
/// a default, so changing `DreamMoodSink` in place broke every one-argument
/// caller in the tree, test targets included. The plain sink is restored
/// exactly as it was and is still honoured; a runner given the dated one
/// prefers it.
public typealias DreamMoodSink = @Sendable (String) async -> Void

/// The dated, answering form of `DreamMoodSink` — see the two changes above.
public typealias DreamDatedMoodSink = @Sendable (
    _ mood: String,
    _ dateKey: String
) async -> Bool

private struct DreamPayload: Decodable {
    let title: String
    let summary: String
    let mood: String
    let emergingThemes: [String]
    let surprisingMoments: [String]

    private enum CodingKeys: String, CodingKey {
        case title
        case summary
        case mood
        case emergingThemes = "emerging_themes"
        case surprisingMoments = "surprising_moments"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        mood = try container.decode(String.self, forKey: .mood)
        emergingThemes = try container.decode([String].self, forKey: .emergingThemes)
        surprisingMoments = try container.decode([String].self, forKey: .surprisingMoments)

        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "title must not be blank"
            )
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .summary,
                in: container,
                debugDescription: "summary must not be blank"
            )
        }
        guard !mood.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .mood,
                in: container,
                debugDescription: "mood must not be blank"
            )
        }
    }
}

/// Exclusive, crash-safe reservation for a dream run (2026-09-06). Same
/// `<target>.lock` + nonblocking `flock` shape the rest of the tree uses; the
/// lock lives on the open file description, so a second runner in THIS process
/// conflicts with the first exactly as another process would, and a crash
/// releases it without leaving a stale claim file to clear by hand.
///
/// 2026-09-06: module-internal (was private) so the weekly REM pass takes the
/// same reservation — a forced manual REM and the scheduled one could otherwise
/// distil the same dreams concurrently.
struct DreamRunReservation {
    private let fd: Int32

    /// nil when another run holds the reservation. Throws only when the lock
    /// file cannot be opened or flock fails for a reason other than contention.
    static func acquire(at path: URL) throws -> DreamRunReservation? {
        let fd = Darwin.open(path.path, O_CREAT | O_WRONLY, 0o600)
        if fd < 0 {
            throw NSError(
                domain: "DreamRunReservation",
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "open lock failed: \(String(cString: strerror(errno)))",
                ]
            )
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return DreamRunReservation(fd: fd)
        }
        let lockError = errno
        Darwin.close(fd)
        if lockError == EWOULDBLOCK { return nil }
        throw NSError(
            domain: "DreamRunReservation",
            code: Int(lockError),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "flock LOCK_EX failed: \(String(cString: strerror(lockError)))",
            ]
        )
    }

    func release() {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}

public actor DreamCycleRunner {
    private let dataRoot: URL
    private let personaRoot: URL
    private let llm: any LLMClient
    private let router: any ProviderRoutingProtocol
    private let now: @Sendable () -> Date
    private let recencyWindow: TimeInterval
    private let memoryDeltaProvider: DreamMemoryDeltaProvider
    private let feltSummaryProvider: DreamFeltSummaryProvider
    private let feltOriginProvider: DreamFeltOriginProvider
    private let receiptSink: DreamReceiptSink
    private let moodSink: DreamMoodSink?
    private let datedMoodSink: DreamDatedMoodSink?
    private let fm = FileManager.default

    // Dream feeding caps (mirror the daemon's `_DREAM_*_BUDGET` constants
    // pinned by the vault skill). Newest-message-first; tool calls excluded.
    private static let convCharBudget: Int = 80_000
    private static let deltaCharBudget: Int = 20_000
    private static let convCountLimit: Int = 300
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
        moodSink: DreamMoodSink? = nil,
        datedMoodSink: DreamDatedMoodSink? = nil,
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
        self.moodSink = moodSink
        self.datedMoodSink = datedMoodSink
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
    /// A pressure-fired run happens mid-life, so it writes the day it is
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
        // the commit below — so two runs (the 03:30 job and a pressure-fired
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
        // than all of history.
        let mark: Date = force
            ? now().addingTimeInterval(-recencyWindow)
            : (readDreamMark() ?? now().addingTimeInterval(-recencyWindow))

        var report = DreamReport(trigger: trigger)
        let (messages, newestIncluded) = gatherRecentMessagesAcrossSessions(since: mark)
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
        let personaDocs = readFullPersonaDocs()
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
        // WHERE that feeling came from (desk 903 phase 2). Unlike the summary
        // itself, a citation is evidence ABOUT a dream, never a reason to lose
        // one: a failed origin read cites nothing and the dream still happens.
        let feltOrigins = (try? await feltOriginProvider()) ?? []
        let citedStudioEntryIDs = Self.studioEntryCitations(
            from: feltOrigins, feltSummary: feltSummary)
        let dreamSystem = Self.dreamSystemPrompt(personaDocs: personaDocs)
        // Pin-only lookup on `dream` so a daemon-era seed (the picker
        // historically seeded `dream → gpt-5.4-mini` even when the user never
        // explicitly pinned it) can't override Agent's current chat voice.
        // Falls back to the chat-surface picker. `??` autoclosure can't
        // carry `await`, so the chain is expanded.
        let pinnedDream = await router.pinnedModelStringForSurface("dream")
        let pickedModel: String?
        if let m = pinnedDream {
            pickedModel = m
        } else {
            pickedModel = await router.modelStringForSurface("chat")
        }

        let prompt = buildCombinedPrompt(
            dateKey: dateKey,
            messages: messages, memoryDeltas: memoryDeltas, feltSummary: feltSummary)
        let raw: String
        do {
            raw = try await llm.complete(
                prompt: prompt,
                system: dreamSystem,
                model: pickedModel,
                surface: "dream"
            )
        } catch {
            report.errors.append("llm error: \(error)")
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
        let markdown = renderCombinedEntry(
            dateKey: dateKey,
            sessionCount: report.sessionsProcessed,
            payload: payload,
            studioEntryIDs: citedStudioEntryIDs
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
            try advanceDreamMark(to: newestIncluded, trigger: trigger)
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
        // move her. Same `mood` string the diary renders as `_Mood: …_`; empty
        // mood has already passed the typed, nonblank payload boundary.
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
        await integrateMoodIfClaimed(
            mood: payload.mood, in: diaryDir, dateKey: dateKey)
        return report
    }

    /// Take the day's claim and deliver the mood, releasing the claim when the
    /// sink says the integration is not durable. One place, because the
    /// `already_dreamt` path below retries through it too.
    private func integrateMoodIfClaimed(
        mood: String,
        in diaryDir: URL,
        dateKey: String
    ) async {
        guard claimMoodIntegration(in: diaryDir, dateKey: dateKey) else { return }
        if await deliverMood(mood, dateKey: dateKey) { return }
        releaseMoodIntegrationClaim(in: diaryDir, dateKey: dateKey)
        FileHandle.standardError.write(Data(
            ("DreamCycleRunner: mood integration for \(dateKey) did not persist; "
             + "claim released so a later run can retry it\n").utf8
        ))
    }

    /// Whichever sink this runner was built with. The dated one wins when both
    /// are present; the plain one never sees the date and cannot report back,
    /// so it counts as durable — exactly the behaviour it had before.
    private func deliverMood(_ mood: String, dateKey: String) async -> Bool {
        if let datedMoodSink { return await datedMoodSink(mood, dateKey) }
        if let moodSink {
            await moodSink(mood)
            return true
        }
        return true
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
              let mood = Self.moodLine(inDiaryMarkdown: markdown) else { return }
        await integrateMoodIfClaimed(mood: mood, in: diaryDir, dateKey: dateKey)
    }

    /// The `_Mood: …_` line of an already-written diary entry, so a night whose
    /// integration failed can be retried from the entry rather than re-dreamt.
    static func moodLine(inDiaryMarkdown markdown: String) -> String? {
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("_Mood: "), line.hasSuffix("_"), line.count > 8 else { continue }
            let body = String(line.dropFirst(7).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    /// Exclusive-create claim marker beside the diary entry. Returns true for
    /// exactly one caller per date; `.withoutOverwriting` makes the create
    /// atomic so concurrent runners cannot both win.
    private func claimMoodIntegration(in diaryDir: URL, dateKey: String) -> Bool {
        let claim = diaryDir.appendingPathComponent(".mood_integrated_\(dateKey)")
        do {
            try Data().write(to: claim, options: [.withoutOverwriting])
            return true
        } catch {
            return false
        }
    }

    /// Undo the claim above when the integration it guarded did not land.
    private func releaseMoodIntegrationClaim(in diaryDir: URL, dateKey: String) {
        try? fm.removeItem(at: diaryDir.appendingPathComponent(".mood_integrated_\(dateKey)"))
    }

    // MARK: - Helpers

    private func isDreamEnabled() -> Bool {
        let path = dataRoot.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .object(let root) = parsed else {
            // Daemon default: dream_scheduler defaults False — so no policy
            // means disabled. Mirrors DreamCycle.is_enabled() short-circuit.
            return false
        }
        func obj(_ key: String) -> [String: JSONValue] {
            if case .object(let o)? = root[key] { return o }
            return [:]
        }
        let training = obj("trainingPolicy")
        let personality = obj("personalityPolicy")
        let scheduler: Bool = {
            if case .bool(let b)? = training["dream_scheduler"] { return b }
            return false
        }()
        let dreamEnabled: Bool = {
            if case .bool(let b)? = personality["dream_cycle_enabled"] { return b }
            return true
        }()
        return scheduler && dreamEnabled
    }

    // MARK: high-water mark (.dream_state.json)

    private func dreamMarkPath() -> URL {
        dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
            .appendingPathComponent(".dream_state.json")
    }

    /// The createdAt of the newest message the last dream consumed. nil → no
    /// dream has run yet (caller falls back to `now - recencyWindow`).
    private func readDreamMark() -> Date? {
        guard let data = try? Data(contentsOf: dreamMarkPath()),
              let parsed = try? JSONValue.parse(data),
              case .object(let o) = parsed,
              case .string(let s)? = o["lastDreamedAt"] else { return nil }
        return Self.parseDaemonISO(s)
    }

    /// Forward-only for the MARK: never regress it, so a re-run/force can't let
    /// already-dreamed material back into a future window. The trigger receipt
    /// beside it is not a mark — it records which lane actually wrote the entry
    /// this call committed (`schedule` vs `pressure`), so a dream's provenance
    /// is evidence rather than an inference from its timestamp. It lives here,
    /// in the runner's own sidecar, and never in the diary body: nothing about
    /// the mechanism enters her prompt (NORTHSTAR clause 6).
    private func advanceDreamMark(to date: Date, trigger: DreamTrigger) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let existing = readDreamMark()
        let mark = (existing.map { max($0, date) }) ?? date
        let body = JSONValue.object([
            "lastDreamedAt": .string(iso.string(from: mark)),
            "lastDreamTrigger": .string(trigger.rawValue),
            "lastDreamAt": .string(iso.string(from: now())),
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

    // MARK: cross-session message gather

    /// Merge user/assistant messages from EVERY session whose createdAt is after
    /// `mark`, sort globally by time, and keep the most-recent `convCountLimit` /
    /// `convCharBudget`. Per-row timestamp prefers the row's `createdAt`, falling
    /// back to the file's mtime for legacy rows that lack it (so old-shape JSONL
    /// still orders + dedups). Returns the picked messages (chronological) plus
    /// the newest timestamp included (the next mark). Tool/system rows excluded.
    private func gatherRecentMessagesAcrossSessions(
        since mark: Date
    ) -> (messages: [(sessionId: String, role: String, content: String)], newest: Date?) {
        let messagesDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: messagesDir.path) else {
            return ([], nil)
        }
        struct Row { let at: Date; let sid: String; let role: String; let content: String }
        var all: [Row] = []
        for name in names where name.hasSuffix(".jsonl") {
            let url = messagesDir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            // Cheap prefilter: skip files clearly older than the mark so a
            // months-old session archive isn't re-parsed every night. A 1h
            // slack absorbs the rare case where a row's createdAt runs slightly
            // AHEAD of the file mtime (clock skew on append) — without it the
            // whole file could be skipped while holding a genuinely-new row
            // (gpt-5.5 review, 2026-06-16). The per-row `at <= mark` check below
            // is the real gate; this only avoids needless reads.
            if mtime.addingTimeInterval(3600) <= mark { continue }
            let sid = (name as NSString).deletingPathExtension
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty, let d = s.data(using: .utf8),
                      let parsed = try? JSONValue.parse(d),
                      case .object(let obj) = parsed else { continue }
                // ONE consolidation owner (NORTHSTAR clause 1, sweep item 45).
                // The chat lane distills a session's older turns into
                // recollection rows as they age — those raw turns are GONE from
                // the transcript, and the recollection is what remains of them.
                // The dream reads that row instead of re-summarizing the same
                // stretch of life a second time.
                //
                // The mark comparison uses `consolidatedThrough` — the newest
                // turn the recollection COVERS — never the row's own write
                // time. A recollection written today can stand for turns from
                // last week; comparing against its write time would re-dream
                // material this lane already consumed raw.
                if let recollection = ChatSessionRecollections.recollection(
                    fromTranscriptRow: parsed,
                    sessionId: sid
                ) {
                    let coveredThrough = recollection.consolidatedThrough ?? mtime
                    if coveredThrough <= mark { continue }
                    // DEFENSIVE (the writer clamps so this row is never made):
                    // a recollection that STRADDLES the mark would be admitted
                    // whole, re-dreaming the pre-mark stretch this lane already
                    // consumed raw. Refuse it and say so, rather than double
                    // count. A legacy straddling row loses its post-mark tail —
                    // cheaper than counting its head twice.
                    if ChatSessionRecollections.straddles(recollection, mark: mark) {
                        FileHandle.standardError.write(Data(
                            "DreamCycleRunner: skipped recollection straddling the dream mark (session \(sid), row \(recollection.rowId ?? "?"))\n".utf8
                        ))
                        continue
                    }
                    all.append(Row(
                        at: coveredThrough,
                        sid: sid,
                        role: Self.recollectionRole,
                        content: recollection.text
                    ))
                    continue
                }
                var role = "user"
                var content = ""
                if case .string(let r)? = obj["role"] { role = r }
                if case .string(let c)? = obj["content"] { content = c }
                if content.isEmpty { continue }
                // Only her + the user's turns shape identity (tool/system rows dropped).
                if !Self.identityRoles.contains(role.lowercased()) { continue }
                let at: Date = {
                    if case .string(let ca)? = obj["createdAt"], let p = Self.parseDaemonISO(ca) {
                        return p
                    }
                    return mtime
                }()
                if at <= mark { continue }   // already dreamed — skip
                all.append(Row(at: at, sid: sid, role: role, content: content))
            }
        }
        all.sort { $0.at < $1.at }
        // Keep the most-recent messages within the count + char budgets
        // (tail-first walk, then restore chronological order). INTENTIONAL drop:
        // on a gap with more than convCountLimit new messages, the OLDEST
        // overflow (older than picked.first) is not dreamed and the mark advances
        // past it — a reflective journal weights the most recent stretch, and
        // this matches the old per-session budget's drop-oldest behavior. In
        // practice a since-last-dream window rarely exceeds the cap.
        var picked: [Row] = []
        var used = 0
        var count = 0
        for r in all.reversed() {
            if count >= Self.convCountLimit { break }
            let lineLen = r.role.count + r.content.count + 4
            if used + lineLen > Self.convCharBudget { break }
            picked.append(r)
            used += lineLen
            count += 1
        }
        picked.reverse()
        return (picked.map { ($0.sid, $0.role, $0.content) }, picked.last?.at)
    }

    // Tool-call rows are NOT identity input — only her own turns and the
    // user's turns shape who she is. Drop tool/tool_use/tool_result rows
    // BEFORE feeding to the dream prompt so a tool-heavy day doesn't dilute
    // the World-half with tool exhaust. (See the vault skill — this is the
    // "tool calls are excluded" invariant.)
    private static let identityRoles: Set<String> = ["user", "assistant"]

    /// The role label a consolidated recollection carries into the dream
    /// prompt. Deliberately NOT "assistant": it is her own memory of a stretch
    /// of life, not a turn she took, and the World half should read it as such.
    static let recollectionRole = "recollection"

    /// Parse the daemon's ISO8601 createdAt shape. Live JSONL uses
    /// microsecond precision (`2026-05-07T11:33:32.167835+00:00`), but
    /// `ISO8601DateFormatter.withFractionalSeconds` only accepts 3-digit
    /// fractions. Try fractional, plain, then truncate to milliseconds.
    /// Returns nil only on truly unparseable input — that case keeps the
    /// row, mirroring the daemon's "no createdAt → don't filter" rule.
    /// Public so the BackgroundLoopsAssembly Self-half provider can reuse
    /// it without duplicating the regex (the duplicate inline copy drifted
    /// — see pass-3 review).
    public static func parseDaemonISO(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: trimmed) { return d }
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        if let d = isoPlain.date(from: trimmed) { return d }
        // Microsecond fallback: truncate the fractional component to 3
        // digits and retry the fractional parser. Match the timezone
        // suffix (`Z` or `±HH:MM`/`±HHMM`) so we splice cleanly.
        if let dotRange = trimmed.range(of: "."),
           let tzMatch = trimmed.range(
               of: #"([Zz]|[+-]\d{2}:?\d{2})$"#,
               options: .regularExpression
           ),
           tzMatch.lowerBound > dotRange.upperBound {
            let fracStart = dotRange.upperBound
            let frac = trimmed[fracStart..<tzMatch.lowerBound]
            if frac.count > 3 {
                let truncated = String(trimmed[..<fracStart])
                    + String(frac.prefix(3))
                    + String(trimmed[tzMatch.lowerBound...])
                return isoFrac.date(from: truncated)
            }
        }
        return nil
    }

    /// World half (the recent cross-session messages — already chronological +
    /// capped by the gather) + Self half (memory deltas she's absorbed about
    /// herself since the last dream), fed at equal structural weight per the
    /// vault skill convention. A lightweight `[conversation <id>]` marker is
    /// emitted when the session changes so two parallel conversations in the
    /// same window don't blur together in her reflection.
    private func buildCombinedPrompt(
        dateKey: String,
        messages: [(sessionId: String, role: String, content: String)],
        memoryDeltas: [String],
        feltSummary: String? = nil
    ) -> String {
        var convLines: [String] = []
        var lastSession: String? = nil
        for m in messages {
            if m.sessionId != lastSession {
                convLines.append("\n[conversation \(String(m.sessionId.prefix(8)))]\n")
                lastSession = m.sessionId
            }
            convLines.append("[\(m.role)] \(m.content)\n")
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

        return """
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
        """
    }

    /// Load the full Agent persona (SOUL/VOICE/GROWTH/USER/AGENTS)
    /// untruncated for the bypass system prompt. Missing files → empty
    /// bodies (the model still gets the section heading so the prompt
    /// shape stays constant). GROWTH.md gets the same episodic-line strip
    /// PersonaEngine applies for chat retrieval, so any stale `- <ts> ·
    /// feedback · ...` line can't leak into the dream context either.
    private func readFullPersonaDocs() -> [String: String] {
        let ids = ["SOUL.md", "VOICE.md", "GROWTH.md", "USER.md", "AGENTS.md"]
        var out: [String: String] = [:]
        for name in ids {
            let url = personaRoot.appendingPathComponent(name)
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            out[name] = (name == "GROWTH.md") ? stripEpisodicGrowthLines(raw) : raw
        }
        return out
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
        (string), summary (string, one paragraph), mood (string), \
        emerging_themes (array of strings), surprising_moments (array of \
        strings). No prose outside the JSON. No code fences.
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
        studioEntryIDs: [String] = []
    ) -> String {
        var out = "# Dream — \(dateKey)\n\n"
        out += "**\(payload.title)**\n\n"
        out += "\(payload.summary)\n\n"
        out += "_Mood: \(payload.mood)_\n\n"
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
        return out
    }

    /// The scheduled 03:30 run writes the Central day that just ended. A
    /// pressure-fired run happens mid-life and writes the day it is dreaming
    /// about — the current Central day, i.e. the entry the NEXT 03:30 job would
    /// have written. That collision is deliberate: it is the dedupe.
    private func entryDateKey(for trigger: DreamTrigger) -> String {
        switch trigger {
        case .schedule:
            return DreamREMSchedule.dreamEntryDateKey(now: now())
        case .pressure:
            return DreamREMSchedule.todayKey(
                now: now(),
                calendar: DreamREMSchedule.centralCalendar()
            )
        }
    }

    fileprivate func stripEpisodicGrowthLines(_ body: String) -> String {
        DreamREMGrowthHygiene.stripEpisodicLines(body)
    }
}

// MARK: - GROWTH.md episodic-line hygiene (shared with REMConsolidator)

/// Read-side guard that drops `- <ts> · feedback · ...` and `- <ts> ·
/// dream_candidate · ...` dash lines from a GROWTH.md body before it's
/// injected into the dream / REM bypass prompts. Mirrors the same drop
/// PersonaEngine applies for chat retrieval (see the
/// nativeagent-rem-dream-cycle vault skill). Distilled prose bullets and
/// `## DATE · category` headers are preserved.
enum DreamREMGrowthHygiene {
    /// Pattern: dash-bullet, any non-whitespace timestamp token, middle-dot
    /// separator (U+00B7), the category word `feedback` OR `dream_candidate`,
    /// then another middle-dot. Distilled prose bullets don't carry the
    /// timestamp+category prefix so they survive.
    private static let episodicLineRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^- \S+\s+·\s+(feedback|dream_candidate)\s+·"#,
            options: []
        )
    }()

    static func stripEpisodicLines(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if episodicLineRegex.firstMatch(in: line, options: [], range: range) != nil {
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
