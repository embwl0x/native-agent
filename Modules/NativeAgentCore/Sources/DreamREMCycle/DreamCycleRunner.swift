import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import CognitiveSubstrate
import TrustCenter
import Transcripts
import MemoryV2
// Blueprint: | `DreamCycleRunner.swift` | `DreamCycleRunner`. |


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
    /// An injected gate is authoritative for this call; absent injection requires a checked saved-policy read.
    private let gate: DreamREMGatePolicy?
    let fm = FileManager.default

    // Exclude tool calls from dream identity input.
    private static let deltaCharBudget: Int = 20_000
    private static let deltaCountLimit: Int = 150
    // Bound the felt summary at the runner boundary as well as at its substrate owner.
    private static let feltCharBudget: Int = 600
    // Retain bounded journal IDs from the felt population so diary provenance can lead back to actual entries.
    public static let studioCitationReceiptKind = "dream.studio_citation"
    private static let studioCitationLimit: Int = 4
    private static let studioEntryIDMaxCharacters: Int = 120
    // Read persona context independently of conversation and memory-delta budgets.

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

    /// Force changes the recency window and replaces the target entry without bypassing Trust.
    public func runNightlyDreamCycle(
        force: Bool = false,
        trigger: DreamTrigger = .schedule,
        preview: Bool = false,
        delivery: DreamEffectSink? = nil,
        parent: Turn? = nil,
        beganAt: Date = Date()
    ) async throws -> DreamReport {
        if try !isDreamEnabled() {
            return DreamReport(disabled: true, trigger: trigger)
        }

        let diaryDir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        let dateKey = DreamREMSchedule.todayKey(now: beganAt)
        let outPath = diaryDir.appendingPathComponent("\(dateKey).md")

        // Hold the reservation from mark reconciliation through diary and mark commit.
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

        // Use the mark to exclude consumed messages; checked absence or force selects the recency window.
        // An unreadable mark stops with its named cause rather than rereading or skipping evidence.
        var report = DreamReport(trigger: trigger)
        if !preview {
            let pending = await retryPendingWork(delivery: delivery)
            report.effectsSettled = pending.settled
            report.lessonsSaved = pending.lessonsSaved
            report.errors += pending.errors
            report.busy = pending.busy
            // Historical gaps belong to their items; new material still dreams. Force requires settling its replaceable target first.
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
        let gathered: (messages: [(sessionId: String, role: String, content: String, source: String?)],
            newest: Date?,
            sources: [DreamSourceRef],
            material: [String: CognitiveReflectionCause])
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

        // No new material means no empty entry and no mark change.
        if messages.isEmpty {
            report.skipReason = "no_new_material"
            return report
        }
        guard let newestIncluded else {
            report.errors.append("message context had no high-water timestamp")
            return report
        }

        // Resolve persona and memory deltas once so the run uses consistent inputs.
        let personaDocs = try await readDreamPersonaDocs(
            dataRoot: dataRoot, personaRoot: personaRoot, surface: "dream", preview: preview
        )
        let memoryDeltas: [String]
        do {
            memoryDeltas = try await memoryDeltaProvider(mark)
        } catch {
            report.errors.append("memory context read failed: \(error)")
            return report
        }
        // Absent felt tone is silence; failed tone reads fail the run so the same window remains available for retry.
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
            // Standalone dream work keeps its parent's identity without borrowing the parent's model route.
            let identity = parent.map { Turn(id: $0.id, run: $0.run, session: $0.session) }
            var call = LLMCall(turn: identity, surface: "dream", purpose: "dream")
            call.preview = preview
            raw = try await llm.complete(
                prompt: prompt.text, system: dreamSystem, model: nil,
                tools: nil, call: call)
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
            report.errors.append(
                """
                    Dream payload could not be decoded: \(String(describing: error)). Nothing was learned or written; repair the nightly-dream output before \
                    retrying.
                    """)
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
        // Ordinary runs append sections without changing prior writing; force replaces the day.
        // The committed footer supplies crash recovery for the mark.
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
        // Only the writer's footer can advance the cutoff; defuse matching model-authored prose.
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
        // Returned writing must settle even when Stop races the response.
        let saved = await settle {
            await self.commitDream(capturedWork)
        }
        report.errors += saved.errors
        guard saved.written else { return report }
        report.entriesWritten += 1
        let pending = await retryPendingWork(delivery: delivery)
        report.effectsSettled += pending.settled
        report.lessonsSaved += pending.lessonsSaved
        report.errors += pending.errors
        // The same owed item retried twice in one run is named once.
        let named = report.busy
        report.busy += pending.busy.filter { !named.contains($0) }
        return report
    }

    /// Use memory.commit's admission, duplicate and forgetting rules; Stop cannot cut settlement of returned dream writing.
    func commitLesson(_ lesson: DreamLesson, dateKey: String, sourcePeerIds: [String]?) async throws {
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        _ = try await memory.store(content: lesson.lesson, source: "dream:\(dateKey)", metadata: .object([
            "kind": .string(lesson.kind == "how" ? "skill" : "fact"),
            "lesson_kind": .string(lesson.kind),
            "dream": .string("dream_diary/\(dateKey).md"),
            // Use the recorded surprise as evidence for the agent's inference.
            "evidence": .object(["speaker": .string("self"), "words": .string(lesson.from)]),
        ]), context: MemoryWriteContext(
            // The agent worked it out; its root names the material's principals, and authorship cannot attest that unknown sources were clean.
            material: sourcePeerIds ?? ["unattributed dream material"], telling: MemoryRoot.Telling(how: .inferred, by: "self")))
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

    /// Only confirmed dated delivery advances the marker; absence remains owed under the substrate's result.
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
        // Keep injected authority fixed; otherwise read saved policy once.
        if let gate { return gate.dreamEnabled }
        return try DreamREMGatePolicy(policy: SwiftNativeTrustCenter(dataRoot: dataRoot).loadSavedPolicyChecked()).dreamEnabled
    }

    // MARK: high-water mark (.dream_state.json)

    private func dreamMarkPath() -> URL {
        dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
            .appendingPathComponent(".dream_state.json")
    }

    static let consumedFooter = "<!-- dream-consumed-through: "

    /// Reconcile marks under the reservation before gathering or model work; archival cannot change consumed cutoffs.
    private func reconcileDreamMark(commit: Bool = true) throws -> Date? {
        let saved = try ConversationHistory.dreamConsolidationMark(dataRoot: dataRoot)
        var committed = saved
        let diary = FileBackedDreamDiary(dataRoot: dataRoot).listEntriesChecked(limit: .max)
        guard diary.isComplete else { throw CocoaError(.fileReadUnknown) }
        let prefix = Self.consumedFooter
        for entry in diary.entries {
            for line in (entry.content ?? "").split(separator: "\n") where line.hasPrefix(prefix) {
                guard line.hasSuffix(" -->"),
                      let cutoff = ConversationHistory.parseTimestamp(.string(String(line.dropFirst(prefix.count).dropLast(4)))) else {
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

    /// Never regress the mark; force cannot return consumed material to future windows.
    func advanceDreamMark(to date: Date) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let existing = try ConversationHistory.dreamConsolidationMark(dataRoot: dataRoot)
        let mark = (existing.map { max($0, date) }) ?? date
        let body = JSONValue.object([
            "lastDreamedAt": .string(iso.string(from: mark)),
        ])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(body.serializedData(pretty: false), to: dreamMarkPath())
    }

    /// Give conversation and self-memory equal structural weight; mark session boundaries so parallel conversations cannot blur together.
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

        // Bound newest-first deltas, then render chronologically; empty input still keeps the Self header.
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
        // Render retained deltas chronologically so the model reads their natural sequence.
        let selfHalf = deltaLines.reversed().joined()
        let selfBody = selfHalf.isEmpty ? "(no new memory deltas since the last dream)\n" : selfHalf

        // Omit empty felt tone so silence stays silence; feeling colors tone without scripting content.
        let feltBlock: String
        if let felt = feltSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !felt.isEmpty {
            let bounded = String(felt.prefix(Self.feltCharBudget))
            feltBlock = try completionPolicy("nightly-dream", section: "felt", arguments: [bounded])
        } else {
            feltBlock = ""
        }

        // Prose-only providers carry no provenance attestation.
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

    // Private reflection keeps identity while changing only activity and audience.
    fileprivate static func dreamSystemPrompt(personaDocs: [String: String]) throws -> String {
        return try completionPolicy("nightly-dream", section: "system", arguments: [
            renderDreamPersonaDocs(personaDocs)
        ])
    }

    /// Attribute feeling only when a felt section exists; without it, journal citations would assert a cause the dream never claimed.
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

    /// Keep journal IDs verbatim so diary citations resolve exactly to journal.jsonl.
    static func studioCitationLine(_ entryIDs: [String]) -> String {
        guard !entryIDs.isEmpty else { return "" }
        let refs = entryIDs.map { "(studio entry \($0))" }.joined(separator: " ")
        return "_Felt from: \(refs)_\n\n"
    }

    /// Timestamp added sections locally so later dreams of the same day remain distinguishable.
    static func sectionStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = DreamREMSchedule.localCalendar()
        formatter.timeZone = formatter.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Give each section its own peers and claim lines so provenance binds to that dream rather than the entire day.
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
        // Write felt-source provenance beside mood after generation; it supplies no extra prompt context.
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

}
