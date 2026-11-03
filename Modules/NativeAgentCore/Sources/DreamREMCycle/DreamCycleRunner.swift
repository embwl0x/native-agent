import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import CognitiveSubstrate
import TrustCenter
import Transcripts
import MemoryV2
// Blueprint: | `DreamCycleRunner.swift` | `DreamCycleRunner`: required dream assembly and generation; preview returns before effects; a durable work journal precedes immutable diary publication and independently checked effects |

// Writes cross-session dreams to <dataRoot>/dream_diary/<YYYY-MM-DD>.md.

public actor DreamCycleRunner {
    let dataRoot: URL
    private let personaRoot: URL
    private let llm: any LLMClient
    private let now: @Sendable () -> Date
    private let recencyWindow: TimeInterval
    private let memoryDeltaProvider: DreamMemoryDeltaProvider
    private let surpriseProvider: DreamSurpriseProvider
    private let feltSummaryProvider: DreamFeltSummaryProvider
    private let feltOriginProvider: DreamFeltOriginProvider
    private let careNightProvider: DreamCareNightProvider
    let receiptSink: DreamReceiptSink
    private let datedMoodSink: DreamDatedMoodSink?
    /// The already-resolved trust gate, when the caller has one. Supplied, it
    /// IS the answer; nil falls back to the local policy read below.
    private let gate: DreamREMGatePolicy?
    let fm = FileManager.default

    // Dream feeding caps: newest-message-first; tool calls excluded.
    private static let deltaCharBudget: Int = 20_000
    private static let deltaCountLimit: Int = 150
    // Felt-tone section: the substrate already bounds its summary to 600 chars;
    // this is the runner-side belt-and-suspenders ceiling on that same section.
    private static let feltCharBudget: Int = 600
    // Studio citation. The dream's felt line names the
    // journal entries the feeling came from, so the causal chain runs from the
    // dream artifact back to the entry that caused it. Same node ceiling the
    // substrate's felt-day summary uses, and ids are bounded because they come
    // from a store this module does not own.
    public static let studioCitationReceiptKind = "dream.studio_citation"
    private static let studioCitationLimit: Int = 4
    private static let studioEntryIDMaxCharacters: Int = 120
    // Persona context uses the active selection and USER projection from
    // readDreamPersonaDocs; the conversation and delta budgets are separate.

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        personaRoot: URL? = nil,
        llm: any LLMClient,
        recencyWindow: TimeInterval = 24 * 60 * 60,
        memoryDeltaProvider: @escaping DreamMemoryDeltaProvider = { _ in [] },
        surpriseProvider: @escaping DreamSurpriseProvider = { _, _ in "" },
        feltSummaryProvider: @escaping DreamFeltSummaryProvider = { nil },
        feltOriginProvider: @escaping DreamFeltOriginProvider = { [] },
        careNightProvider: @escaping DreamCareNightProvider = { throw PersistenceCoreError.ioFailure("care night evidence provider is unavailable") },
        receiptSink: @escaping DreamReceiptSink = { _, _ in throw PersistenceCoreError.ioFailure("dream receipt delivery is unavailable") },
        datedMoodSink: DreamDatedMoodSink? = nil,
        gate: DreamREMGatePolicy? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.personaRoot = personaRoot
            ?? PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        self.llm = llm
        self.recencyWindow = recencyWindow
        self.memoryDeltaProvider = memoryDeltaProvider
        self.surpriseProvider = surpriseProvider
        self.feltSummaryProvider = feltSummaryProvider
        self.feltOriginProvider = feltOriginProvider
        self.careNightProvider = careNightProvider
        self.receiptSink = receiptSink
        self.datedMoodSink = datedMoodSink
        self.gate = gate
        self.now = now
    }

    /// Reflects new user/assistant messages across sessions in chronological order.
    /// `force` rereads `recencyWindow` and replaces the target day's entry without bypassing Trust.
    public func runNightlyDreamCycle(
        force: Bool = false,
        trigger: DreamTrigger = .schedule,
        preview: Bool = false,
        delivery: DreamEffectSink? = nil
    ) async throws -> DreamReport {
        if preview, !LLMCallContext.preview {
            return try await LLMCallContext.$preview.withValue(true) {
                try await runNightlyDreamCycle(force: force, trigger: trigger, preview: true, delivery: delivery)
            }
        }
        if try !isDreamEnabled() {
            return DreamReport(disabled: true, trigger: trigger)
        }

        let diaryDir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        let dateKey = entryDateKey(for: trigger)
        let outPath = diaryDir.appendingPathComponent("\(dateKey).md")

        // One run holds the reservation from mark reconciliation through diary and mark commit.
        let reservation: DreamRunReservation?
        if preview {
            reservation = nil
        } else {
            do {
                try fm.createDirectory(at: diaryDir, withIntermediateDirectories: true)
                reservation = try DreamRunReservation.acquire(
                    at: diaryDir.appendingPathComponent(".dream_run.lock"))
            } catch {
                return DreamReport(errors: ["dream reservation error: \(error)"], trigger: trigger)
            }
            guard reservation != nil else {
                return DreamReport(trigger: trigger, skipReason: "already_running")
            }
        }
        defer { reservation?.release() }

        // High-water mark: dream ONLY over messages new since the last dream, so
        // a 150-message day reflects on exactly those 150 and never re-reads what
        // a prior dream already covered. First-ever run (no mark) — and every
        // `force` run — falls back to `now - recencyWindow` (the last day) rather
        // than all of history. An unreadable mark is not a first run: the
        // dream stops and names the file instead of re-reading or skipping.
        var report = DreamReport(trigger: trigger)
        if !preview {
            let pending = await retryPendingWork(delivery: delivery)
            report.effectsSettled = pending.settled
            report.errors += pending.errors
            // A failed historical item reports its own gap; new material still dreams.
            // Force alone can destroy returned work, so only its target must be settled.
            guard !pending.discoveryUnavailable, !Task.isCancelled,
                  !force || !pending.pendingPaths.contains(outPath.path) else { return report }
        }
        let mark: Date
        do {
            let committedMark = try reconcileDreamMark(commit: !preview)
            mark = force
                ? now().addingTimeInterval(-recencyWindow)
                : (committedMark ?? now().addingTimeInterval(-recencyWindow))
        } catch {
            report.errors.append("dream progress could not be recovered from \(diaryDir.path) (\(error)); "
                + "repair the unreadable diary or high-water mark before retrying")
            return report
        }
        let feltOrigins: [CognitiveFeltOrigin]
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

        // Resolve selected persona context and memory deltas once per run.
        let personaDocs = try await readDreamPersonaDocs(
            dataRoot: dataRoot, personaRoot: personaRoot, surface: "dream"
        )
        let memoryDeltas: [String]
        do {
            memoryDeltas = try await memoryDeltaProvider(mark)
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
        let careNight: CognitiveCareNight?
        do { careNight = try await careNightProvider() }
        catch {
            report.errors.append("care night evidence unavailable; cutoff unchanged: \(error)")
            return report
        }
        let surpriseBlock: String
        do {
            let surprises = try await surpriseProvider(mark, now())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            surpriseBlock = surprises.isEmpty ? "" : try completionPolicy(
                "nightly-dream", section: "surprises", arguments: [String(surprises.prefix(2_400))])
        } catch {
            report.errors.append("surprise context read failed: \(error)")
            return report
        }
        let citedStudioEntryIDs = Self.studioEntryCitations(
            from: feltOrigins, feltSummary: feltSummary)
        let dreamSystem = try Self.dreamSystemPrompt(personaDocs: personaDocs)
        let prompt = try buildCombinedPrompt(
            dateKey: dateKey,
            messages: messages, memoryDeltas: memoryDeltas, feltSummary: feltSummary,
            surpriseBlock: surpriseBlock,
            careBlock: careNight?.block ?? "",
            sourcePeerIds: CognitiveReflectionCause.unionPeerIds(messages.map { row in
                row.source.flatMap { sourceMaterial[$0]?.sourcePeerIds }
            }))
        let raw: String
        do {
            try Task.checkCancellation()
            raw = try await PrivateWorkContextAssembly.$current.withValue(.suppliedPersona) {
                try await llm.complete(
                    prompt: prompt.text,
                    system: dreamSystem,
                    model: nil,
                    surface: "dream", purpose: "dream", tools: nil
                )
            }
        } catch {
            report.errors.append("llm error: \(error)")
            report.repair = (error as? ProviderFailure.Diagnostic)?.repair?.remedy()
            return report
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            report.errors.append("Dream payload is empty or not UTF-8; nothing was learned or written. Repair the nightly-dream output before retrying.")
            return report
        }
        let payload: DreamPayload
        do {
            payload = try JSONDecoder().decode(DreamPayload.self, from: data)
        } catch {
            report.errors.append("Dream payload could not be decoded: \(String(describing: error)). Nothing was learned or written; repair the nightly-dream output before retrying.")
            return report
        }
        let lessons = surpriseBlock.isEmpty ? [] : payload.lessons
        report.careNight = careNight.map {
            CognitiveCareNight(block: $0.block, readAt: $0.readAt, keys: $0.keys, answers: payload.cares, source: "dream_diary/\(dateKey).md",
                clusters: $0.clusters, merges: payload.careMerges, mergesMalformed: payload.careMergesMalformed, stanceChanges: payload.careStanceChanges,
                mindEpoch: $0.mindEpoch, selfStoryRefs: $0.selfStoryRefs, selfChangeRefs: $0.selfChangeRefs,
                selfPeople: $0.selfPeople, traits: payload.traits, story: payload.story, people: payload.people)
        }
        if preview {
            report.preview = .object(["title": .string(payload.title), "summary": .string(payload.summary),
                "mood": .string(payload.mood), "affect": payload.affect.map(JSONValue.double) ?? .null,
                "careAnswers": .array(payload.cares.map(JSONValue.string)),
                "lessonsNotRecorded": .int(Int64(lessons.count)), "date": .string(dateKey),
                "consumedThroughUnchanged": .string(NativeTimestampFormat.fractionalZulu(newestIncluded))])
            return report
        }
        // The day's entry as it stands. A non-force run adds its dream to it as
        // a further section, never touching what is there; `force` replaces it
        // whole. Its committed footer is the recovery source for the mark.
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
        let addsSection = !force && previousDiary != nil
        let prose = try renderCombinedEntry(
            heading: addsSection ? "## Dreamt again — \(Self.sectionStamp(now()))" : "# Dream — \(dateKey)",
            sessionCount: report.sessionsProcessed,
            payload: payload,
            lessons: lessons,
            studioEntryIDs: citedStudioEntryIDs,
            sources: messageSources,
            sourcePeerIds: prompt.peerIds
        // Only the footer this writes is a cutoff: the same words in what the model wrote are defused.
        ).replacingOccurrences(of: Self.consumedFooter, with: "<!-- dream consumed through: ")
        var reflectionMaterial = sourceMaterial
        reflectionMaterial["dream_diary/\(dateKey).md"] = CognitiveReflectionCause(
            text: prose, sourcePeerIds: prompt.peerIds, sourceRefs: sourceMaterial.keys.sorted())
        var work = DreamPendingWork(id: UUID(), date: dateKey, trigger: trigger, force: force,
            sessionsProcessed: report.sessionsProcessed, sourcePeerIds: prompt.peerIds,
            lessons: lessons, reflection: reflectionMaterial, care: report.careNight.map(DreamPendingWork.Care.init),
            affect: payload.affect, studioEntries: citedStudioEntryIDs,
            completion: .init(occurredAt: now(), feltSummary: feltSummary),
            completedSteps: [:])
        if careNight == nil { work.finish("care", result: "skipped: inner life off") }
        if payload.affect == nil { work.finish("mood", result: "skipped: no affect judgment") }
        let markdown = prose + "\n" + work.identityMarker + "\n"
            + Self.consumedFooter + "\(NativeTimestampFormat.fractionalZulu(newestIncluded)) -->\n"
        let entry: Data
        if addsSection, let previousDiary { entry = previousDiary + Data(("\n" + markdown).utf8) }
        else { entry = Data(markdown.utf8) }
        work.publication = .init(entry: entry, previousDiary: previousDiary, consumedThrough: newestIncluded)
        let capturedWork = work
        // Returned writing is settlement, even when Stop raced the response.
        let saved = await settle {
            await self.commitDream(capturedWork)
        }
        report.errors += saved.errors
        guard saved.written else { return report }
        report.entriesWritten += 1
        let pending = await retryPendingWork(delivery: delivery)
        report.effectsSettled += pending.settled
        report.errors += pending.errors
        return report
    }

    /// Her own memory write, using the same admission, duplicate and forgotten
    /// content rules as memory.commit. Stop cannot cut settlement after the
    /// dream has already returned its writing.
    func commitLesson(_ lesson: DreamLesson, dateKey: String, sourcePeerIds: [String]?) async throws {
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        _ = try await memory.store(content: lesson.lesson, source: "dream:\(dateKey)", metadata: .object([
            "kind": .string(lesson.kind == "how" ? "skill" : "fact"),
            "lesson_kind": .string(lesson.kind),
            // Her own inference from what surprised her; the surprise itself is the evidence.
            "provenance": .string("inferred"),
            "provenance_by": .string("self"),
            "dream": .string("dream_diary/\(dateKey).md"),
            "evidence": .object(["speaker": .string("self"), "words": .string(lesson.from)]),
            // Authorship never attests that unknown source material was clean.
            "peer_sources": .array((sourcePeerIds ?? ["unattributed dream material"]).map(JSONValue.string)),
        ]))
    }

    private func commitDream(_ captured: DreamPendingWork) -> (written: Bool, errors: [String]) {
        var work = captured
        do { try work.save(in: dataRoot) }
        catch { return (false, ["returned dream work could not be saved: \(error)"]) }
        do {
            try publishPendingDream(&work)
        } catch {
            return (false, ["dream publication remains owed in its work journal: \(error)"])
        }
        return (true, [])
    }

    /// The marker records confirmed dated delivery only. An absent marker is
    /// still owed; the substrate's result controls acknowledgment.
    @discardableResult
    func integrateMood(
        affect: Double?,
        in diaryDir: URL,
        dateKey: String
    ) async throws -> String? {
        let integrated = diaryDir.appendingPathComponent(".mood_integrated_\(dateKey)")
        guard let affect, !fm.fileExists(atPath: integrated.path) else { return nil }
        guard let datedMoodSink else {
            throw PersistenceCoreError.ioFailure("mood delivery for \(dateKey) is unavailable; the saved judgment remains pending")
        }
        switch try await datedMoodSink(affect, dateKey) {
        case .done: break
        case .skipped(let reason): return reason
        case .reflection:
            throw PersistenceCoreError.ioFailure("mood delivery returned a reflection instead of effect acknowledgment")
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(), to: integrated)
        return nil
    }

    // MARK: - Helpers

    private func isDreamEnabled() throws -> Bool {
        // An injected gate keeps the caller's snapshot; otherwise read saved authority once.
        if let gate { return gate.dreamEnabled }
        return try DreamREMGatePolicy(authority: .read(dataRoot: dataRoot)).dreamEnabled
    }

    // MARK: high-water mark (.dream_state.json)

    private func dreamMarkPath() -> URL {
        dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
            .appendingPathComponent(".dream_state.json")
    }

    static let consumedFooter = "<!-- dream-consumed-through: "

    /// Called under the run reservation, before gathering or spending a model
    /// call. Archival moves sections without changing their consumed cutoffs.
    private func reconcileDreamMark(commit: Bool = true) throws -> Date? {
        let saved = try ChatSessionRecollections.dreamConsolidationMark(dataRoot: dataRoot)
        var committed = saved
        let diary = FileBackedDreamDiary(dataRoot: dataRoot).listEntriesChecked(limit: .max)
        guard diary.isComplete else { throw CocoaError(.fileReadUnknown) }
        let prefix = Self.consumedFooter
        for entry in diary.entries {
            for line in (entry.content ?? "").split(separator: "\n") where line.hasPrefix(prefix) {
                guard line.hasSuffix(" -->"),
                      let cutoff = ChatSessionRecollections.parseTimestamp(.string(String(line.dropFirst(prefix.count).dropLast(4)))) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                committed = committed.map { max($0, cutoff) } ?? cutoff
            }
        }
        if commit, let committed, saved.map({ committed > $0 }) ?? true {
            try advanceDreamMark(to: committed)
        }
        return committed
    }

    /// Never regress the mark, so a re-run/force cannot return already-dreamed
    /// material to a future window. Completion metadata carries the trigger.
    func advanceDreamMark(to date: Date) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let existing = try ChatSessionRecollections.dreamConsolidationMark(dataRoot: dataRoot)
        let mark = (existing.map { max($0, date) }) ?? date
        let body = JSONValue.object([
            "lastDreamedAt": .string(iso.string(from: mark)),
        ])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(body.serializedData(pretty: false), to: dreamMarkPath())
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
        surpriseBlock: String = "",
        careBlock: String = "",
        sourcePeerIds: [String]?
    ) throws -> (text: String, peerIds: [String]?) {
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

        // Keep bounded newest-first deltas, then render them chronologically.
        // Empty input keeps the Self header.
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
            feltBlock = try completionPolicy("nightly-dream", section: "felt", arguments: [bounded])
        } else {
            feltBlock = ""
        }

        // These prose-only providers carry no provenance attestation.
        let peers = CognitiveReflectionCause.unionPeerIds([sourcePeerIds]
            + (selfHalf.isEmpty && surpriseBlock.isEmpty && feltBlock.isEmpty && careBlock.isEmpty ? [] : [nil]))
        return (try completionPolicy("nightly-dream", section: "prompt", arguments: [
            dateKey,
            worldHalf,
            selfBody,
            surpriseBlock,
            feltBlock,
            careBlock
        ]), peers)
    }

    // Private reflection keeps identity; only the activity and audience differ.
    fileprivate static func dreamSystemPrompt(personaDocs: [String: String]) throws -> String {
        return try completionPolicy("nightly-dream", section: "system", arguments: [
            renderDreamPersonaDocs(personaDocs)
        ])
    }

    /// The journal entries the day's feeling actually came from, in the order
    /// the felt population gave them, deduped and bounded.
    ///
    /// Gated on there BEING a felt section: with no felt summary there is no
    /// feeling to attribute, and a citation with nothing to cite in would be an
    /// assertion the dream never made. Feeling-silence stays silence.
    static func studioEntryCitations(
        from origins: [CognitiveFeltOrigin],
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

    /// Local wall time an added section was dreamt, so a day's later sections
    /// say when they came.
    static func sectionStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = DreamREMSchedule.localCalendar()
        formatter.timeZone = formatter.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// One dream as markdown under `heading`: the day's `# Dream — <date>`, or
    /// a `## Dreamt again — <time>` section added to an existing day. Each
    /// section closes with its own peers line and claim lines, which
    /// `DreamEntryProvenance` reads per section.
    private func renderCombinedEntry(
        heading: String,
        sessionCount: Int,
        payload: DreamPayload,
        lessons: [DreamLesson],
        studioEntryIDs: [String] = [],
        sources: [DreamSourceRef] = [],
        sourcePeerIds: [String]?
    ) throws -> String {
        var out = "\(heading)\n\n"
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
        if !lessons.isEmpty {
            out += "**What I learned:**\n"
            for lesson in lessons { out += "- \(lesson.lesson) (from: \(lesson.from))\n" }
            out += "\n"
        }
        let convNote = sessionCount == 1 ? "1 conversation" : "\(sessionCount) conversations"
        out += "_(woven from \(convNote))_\n"
        var dropped: [String] = []
        let claims = try DreamEntryProvenance.renderBlock(payload.claims, content: out, sources: sources, dropped: &dropped)
        if !dropped.isEmpty {
            out += "_(\(dropped.count == 1 ? "1 claim" : "\(dropped.count) claims") left without sources: \(dropped.joined(separator: "; ")))_\n"
        }
        out += try DreamEntryProvenance.peerBlock(sourcePeerIds)
        out += claims
        return out
    }

    /// The scheduled 03:30 run writes the local day that just ended. A
    /// manually requested run happens mid-life and writes the
    /// day it is dreaming about — the current local calendar day, i.e.
    /// the entry the NEXT 03:30 job also targets. The mark, not this file, is
    /// the dedupe: that job dreams only what came after the manual pass and
    /// adds it to the same entry as a further section.
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
