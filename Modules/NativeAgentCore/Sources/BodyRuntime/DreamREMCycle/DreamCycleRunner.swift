import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import MindCore
import DeskCore
import SenseCore
// Blueprint: | `DreamCycleRunner.swift` | `DreamCycleRunner`. |


public actor DreamCycleRunner {
    static let stopPendingWords = "dream delivery remains pending after Stop"

    let dataRoot: URL
    private let personaRoot: URL
    private let llm: any LLMClient
    private let now: @Sendable () -> Date
    private static let recencyWindow: TimeInterval = 24 * 60 * 60
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

    private static let deltaCharBudget: Int = 20_000
    private static let deltaCountLimit: Int = 150
    // Bound the felt summary at the runner boundary as well as at its substrate owner.
    private static let feltCharBudget: Int = 600
    // Retain bounded journal IDs from the felt population so diary provenance can lead back to actual entries.
    public static let studioCitationReceiptKind = "dream.studio_citation"
    private static let studioCitationLimit: Int = 4
    private static let studioEntryIDMaxCharacters: Int = 120

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        personaRoot: URL? = nil,
        llm: any LLMClient,
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

    public func runNightlyDreamCycle(
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

        // An unreadable mark stops with its named cause rather than rereading or skipping evidence.
        var report = DreamReport(trigger: trigger)
        var owedBefore: [(journal: URL?, words: String)] = []
        if !preview {
            let pending = await retryPendingWork(delivery: delivery)
            report.effectsSettled = pending.settled
            report.lessonsSaved = pending.lessonsSaved
            report.errors += pending.errors.map { $0.words }
            owedBefore = pending.errors
            report.busy = pending.busy
            guard !pending.discoveryUnavailable, !Task.isCancelled else { return report }
        }
        do {
            let (prepared, draft) = try await prepareNightlyDream(report, preview: preview, parent: parent, dateKey: dateKey, outPath: outPath)
            guard let draft else { return prepared }
            return await publishNightlyDream(prepared, draft: draft, trigger: trigger, delivery: delivery,
                dateKey: dateKey, owedBefore: owedBefore)
        } catch is CancellationError where !preview {
            report.errors.append(Self.stopPendingWords)
            return report
        }
    }

    private typealias NightlyDreamDraft = (payload: DreamPayload, prose: String, previousDiary: Data?, lessons: [DreamLesson],
        careNight: CognitiveCareNight?, newestIncluded: Date, citedStudioEntryIDs: [String],
        sourceMaterial: [String: CognitiveReflectionCause], feltSummary: String?, began: Date)

    private func prepareNightlyDream(_ initial: DreamReport, preview: Bool, parent: Turn?, dateKey: String, outPath: URL) async throws
        -> (DreamReport, NightlyDreamDraft?) {
        var report = initial
        let mark: Date
        do {
            let committedMark = try ConversationHistory.dreamConsolidationMark(dataRoot: dataRoot)
            mark = committedMark ?? now().addingTimeInterval(-Self.recencyWindow)
        } catch {
            report.errors.append("Dream cutoff could not be read at \(dreamMarkPath().path) (\(error)). Repair the saved cutoff before retrying.")
            return (report, nil)
        }
        let began = now()
        let materialMark = (try? Data(contentsOf: dreamMarkPath())).flatMap { try? JSONValue.parse($0) }
            .flatMap { NativeTimestampFormat.parseTrimmedISO8601FractionalFirst($0.objectValue?["materialThrough"]?.stringValue) }
        let feltOrigins: [CognitiveFeltOrigin]
        do {
            feltOrigins = try await feltOriginProvider()
        } catch let stopped as CancellationError where !preview {
            throw stopped
        } catch {
            report.errors.append("felt origin read failed: \(error)")
            return (report, nil)
        }
        let gathered: (messages: [(sessionId: String, role: String, content: String, source: String?)],
            newest: Date?,
            sources: [DreamSourceRef],
            material: [String: CognitiveReflectionCause],
            moreMessagesRemain: Bool)
        do {
            gathered = try gatherRecentMessagesAcrossSessions(since: mark)
        } catch {
            let message = "transcript read failed; dream will retry: \(error)"
            report.errors.append(message)
            FileHandle.standardError.write(Data("DreamCycleRunner: \(message)\n".utf8))
            return (report, nil)
        }
        let (messages, newest, messageSources, sourceMaterial, moreMessagesRemain) = gathered
        report.moreMessagesRemain = moreMessagesRemain
        report.sessionsProcessed = Set(messages.map { $0.sessionId }).count

        // A night with messages reads what is not conversation since the message mark, as it always has. A night without any reads it
        // since the last dream of either kind began, so a day without a conversation still has a night and no quiet night repeats one.
        // The message mark moves only with messages.
        let materialSince = messages.isEmpty ? max(mark, materialMark ?? mark) : mark
        let memoryDeltas: [String]
        do {
            memoryDeltas = try await memoryDeltaProvider(materialSince)
        } catch let stopped as CancellationError where !preview {
            throw stopped
        } catch {
            report.errors.append("memory context read failed: \(error)")
            return (report, nil)
        }
        let surprises: String
        do {
            let material = try await surpriseProvider(materialSince, began).trimmingCharacters(in: .whitespacesAndNewlines)
            surprises = String(DreamPart.redact(material).prefix(2_400))
        } catch let stopped as CancellationError where !preview {
            throw stopped
        } catch {
            report.errors.append("surprise context read failed: \(error)")
            return (report, nil)
        }
        // No new material means no empty entry and no mark change. Felt tone and cares are always there and are not a day's material.
        if messages.isEmpty, memoryDeltas.isEmpty, surprises.isEmpty {
            report.skipReason = "no_new_material"
            return (report, nil)
        }
        guard let newestIncluded = newest ?? (messages.isEmpty ? mark : nil) else {
            report.errors.append("message context had no high-water timestamp")
            return (report, nil)
        }

        // Resolve persona once so the run uses consistent inputs.
        let personaDocs = try await readDreamPersonaDocs(
            dataRoot: dataRoot, personaRoot: personaRoot, surface: "dream", preview: preview
        )
        // Absent felt tone is silence; failed tone reads fail the run so the same window remains available for retry.
        let feltSummary: String?
        do {
            feltSummary = try await feltSummaryProvider()
        } catch let stopped as CancellationError where !preview {
            throw stopped
        } catch {
            report.errors.append("felt context read failed: \(error)")
            return (report, nil)
        }
        let careNight: CognitiveCareNight?
        do { careNight = try await careNightProvider() }
        catch let stopped as CancellationError where !preview { throw stopped }
        catch {
            report.errors.append("care night evidence unavailable; cutoff unchanged: \(error)")
            return (report, nil)
        }
        let citedStudioEntryIDs = Self.studioEntryCitations(
            from: feltOrigins, feltSummary: feltSummary)
        let dreamSystem = try Self.dreamSystemPrompt(personaDocs: personaDocs)
        let evidence = Self.dreamEvidence(dateKey: dateKey, messages: messages, memoryDeltas: memoryDeltas,
            feltSummary: feltSummary, surprises: surprises, careBlock: careNight?.block ?? "")
        let identity = parent.map { Turn(dataRoot: $0.dataRoot, id: $0.id, run: $0.run, session: $0.session) }
        var call = LLMCall(turn: identity, surface: "dream", purpose: "dream")
        call.session = nil
        call.preview = preview
        let providerCall = call
        let llm = self.llm
        let sessionCount = report.sessionsProcessed
        let previousDiary: Data?
        if !preview, fm.fileExists(atPath: outPath.path) {
            do { previousDiary = try Data(contentsOf: outPath) }
            catch {
                report.errors.append("diary snapshot error: \(error)")
                return (report, nil)
            }
        } else { previousDiary = nil }
        let addsSection = previousDiary != nil
        let clock = now
        let required = ["world", "cares", "surprises"] + (citedStudioEntryIDs.isEmpty ? [] : ["felt"]) + (messages.isEmpty ? ["memories"] : [])
        let part = DreamPart(mode: .dream, evidence: evidence, required: required, preview: preview) { prompt in
            let raw = try await llm.complete(prompt: prompt, system: dreamSystem, model: nil, tools: nil, call: providerCall)
            let completion: DreamPayload
            // Plain JSON is read as it always was; the extractor is for a reply wrapped in a fence or prose.
            do {
                completion = try (try? JSONDecoder().decode(DreamPayload.self, from: Data(raw.utf8)))
                    ?? JSONValue.decodeCompletion(raw, as: DreamPayload.self)
            }
            catch {
                try Task.checkCancellation()
                let fault = String(DreamPart.redact(String(describing: error)).prefix(300))
                let request = prompt + "\n\nYour last reply could not be read (\(fault)). Return one JSON object with the required fields."
                let revised = try await llm.complete(prompt: request, system: dreamSystem, model: nil, tools: nil, call: providerCall)
                do { completion = try JSONValue.decodeCompletion(revised, as: DreamPayload.self) }
                catch {
                    throw PartCallError(code: "bad_dream_policy",
                        message: "Dream could not decode the second reply: " + DreamPart.redact(String(describing: error)))
                }
            }
            return (.object(completion.retainedFields), .dreamDrops(completion.drops))
        } validate: { value, reading in
            var payload = try JSONDecoder().decode(DreamPayload.self, from: value.serializedData(pretty: false))
            if case .dreamDrops(let original)? = reading {
                payload.drops.total += original.total
                payload.drops.mergesMalformed += original.mergesMalformed
            }
            if let careNight { payload.bindSelfReading(to: careNight) }
            let heading = addsSection ? "## Dreamt again — \(Self.sectionStamp(clock()))" : "# Dream — \(dateKey)"
            let diaryBody = Self.renderDreamBody(sessionCount: sessionCount, payload: payload,
                lessons: surprises.isEmpty ? [] : payload.lessons, studioEntryIDs: citedStudioEntryIDs)
            let prose = try Self.renderCombinedEntry(heading: heading, body: diaryBody, claims: payload.claims,
                sources: messageSources)
            return .dream(payload, prose: prose)
        }
        let payload: DreamPayload
        let prose: String
        do {
            guard case .dream(let reading, let body) = try await part.read(root: dataRoot, parent: parent) else {
                throw DreamREMCycleError.underlying("The dream cycle returned a reading for the wrong mode.")
            }
            payload = reading
            prose = body
        } catch let stopped as CancellationError where !preview {
            throw stopped
        } catch {
            report.errors.append("Dream policy failed: \(DreamPart.redact(error.localizedDescription))")
            report.repair = (error as? ProviderFailure.Diagnostic)?.repair?.remedy()
            return (report, nil)
        }
        let lessons = surprises.isEmpty ? [] : payload.lessons
        report.droppedOptionalItems = payload.drops.total
        report.careNight = careNight.map {
            CognitiveCareNight(block: $0.block, readAt: $0.readAt, keys: $0.keys, answers: payload.cares, source: "dream_diary/\(dateKey).md",
                clusters: $0.clusters, merges: payload.careMerges, mergesMalformed: payload.drops.mergesMalformed,
                stanceChanges: payload.careStanceChanges,
                mindEpoch: $0.mindEpoch, selfStoryRefs: $0.selfStoryRefs, selfChangeRefs: $0.selfChangeRefs,
                selfPeople: $0.selfPeople, traits: payload.traits, story: payload.story, people: payload.people)
        }
        if preview {
            report.preview = .object(["title": .string(payload.title), "summary": .string(payload.summary),
                "mood": .string(payload.mood), "affect": payload.affect.map(JSONValue.double) ?? .null,
                "careAnswers": .array(payload.cares.map(JSONValue.string)),
                "droppedOptionalItems": .int(Int64(payload.drops.total)),
                "lessonsNotRecorded": .int(Int64(lessons.count)), "date": .string(dateKey),
                "consumedThroughUnchanged": .string(NativeTimestampFormat.fractionalZulu(newestIncluded))])
            return (report, nil)
        }
        return (report, (payload, prose, previousDiary, lessons, careNight, newestIncluded, citedStudioEntryIDs, sourceMaterial,
            feltSummary, began))
    }

    private func publishNightlyDream(_ initial: DreamReport, draft: NightlyDreamDraft, trigger: DreamTrigger,
                                     delivery: DreamEffectSink?, dateKey: String,
                                     owedBefore: [(journal: URL?, words: String)]) async -> DreamReport {
        var report = initial
        let (payload, prose, previousDiary, lessons, careNight, newestIncluded, citedStudioEntryIDs, sourceMaterial, feltSummary, began) = draft
        let citedSources = Set(DreamEntryProvenance.readClaims(in: prose, as: DreamEntryProvenance.self)
            .flatMap { $0.claims.flatMap(\.sourceRefs) })
        // Her dreams are hers (User, 2026-11-26): what she dreams from is her own mind and conversations she herself was in, so a dream
        // and the rows it cites name no outside source. Who said what stays on each transcript row and memory, where it is recorded.
        var reflectionMaterial = sourceMaterial.filter { citedSources.contains($0.key) }
        reflectionMaterial["dream_diary/\(dateKey).md"] = CognitiveReflectionCause(
            text: prose, sourcePeerIds: [], sourceRefs: citedSources.sorted())
        var work = DreamPendingWork(id: UUID(), date: dateKey, trigger: trigger, force: false,
            sessionsProcessed: report.sessionsProcessed, sourcePeerIds: [],
            lessons: lessons, reflection: reflectionMaterial, care: report.careNight.map(DreamPendingWork.Care.init),
            affect: payload.affect, studioEntries: citedStudioEntryIDs,
            completion: .init(occurredAt: now(), feltSummary: feltSummary, droppedOptionalItems: payload.drops.total),
            completedSteps: [:])
        if careNight == nil {
            work.finish("care", result: "skipped: inner life off")
            // An organ that is off says so, so an old "worked" stamp cannot stand in for a night that never ran.
            OrganJudge.beatOff("care_night", because: "inner life is off")
        }
        if payload.affect == nil { work.finish("mood", result: "skipped: no affect judgment") }
        let markdown = prose + "\n" + work.identityMarker + "\n"
        let entry: Data
        if let previousDiary { entry = previousDiary + Data(("\n" + markdown).utf8) }
        else { entry = Data(markdown.utf8) }
        work.publication = .init(entry: entry, previousDiary: previousDiary, consumedThrough: newestIncluded, materialThrough: began)
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
        report.errors.replaceSubrange(0..<owedBefore.count,
            with: owedBefore.filter { !pending.revisited.contains($0.journal) }.map { $0.words })
        report.errors += pending.errors.map { $0.words }
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
            material: sourcePeerIds ?? ["unattributed dream material"], telling: MemoryRoot.Telling(how: .inferred, by: "self"),
            lifecycle: MemoryLifecycle.inferred))
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

    @discardableResult
    func integrateMood(
        affect: Double?,
        dateKey: String,
        dreamId: UUID
    ) async throws -> String? {
        guard let affect else { return nil }
        guard let datedMoodSink else {
            throw PersistenceCoreError.ioFailure("mood delivery for \(dateKey) is unavailable; the saved judgment remains pending")
        }
        switch try await datedMoodSink(affect, dateKey, dreamId) {
        case .done: break
        case .skipped(let reason): return reason
        case .reflection:
            throw PersistenceCoreError.ioFailure("mood delivery returned a reflection instead of effect acknowledgment")
        }
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

    func advanceDreamMark(to date: Date, materialThrough: Date?) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let existing = try ConversationHistory.dreamConsolidationMark(dataRoot: dataRoot)
        let mark = (existing.map { max($0, date) }) ?? date
        // The mark for what is not conversation moves forward only, beside the message mark; a file without it reads as the message mark.
        let saved = (try? Data(contentsOf: dreamMarkPath())).flatMap { try? JSONValue.parse($0) }
            .flatMap { NativeTimestampFormat.parseTrimmedISO8601FractionalFirst($0.objectValue?["materialThrough"]?.stringValue) }
        var fields: [String: JSONValue] = ["lastDreamedAt": .string(iso.string(from: mark))]
        if let material = [saved, materialThrough].compactMap({ $0 }).max() { fields["materialThrough"] = .string(iso.string(from: material)) }
        let body = JSONValue.object(fields)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(body.serializedData(pretty: false), to: dreamMarkPath())
    }

    private static func dreamEvidence(
        dateKey: String,
        messages: [(sessionId: String, role: String, content: String, source: String?)],
        memoryDeltas: [String],
        feltSummary: String?,
        surprises: String,
        careBlock: String
    ) -> [String: String] {
        var convLines: [String] = []
        var lastSession: String? = nil
        for m in messages {
            if m.sessionId != lastSession {
                convLines.append("\n[conversation \(DreamPart.redact(m.sessionId).prefix(8))]\n")
                lastSession = m.sessionId
            }
            convLines.append("[\(m.role) | \(m.source ?? "source unavailable")] \(m.content)\n")
        }

        var deltaLines: [String] = []
        var deltaUsed = 0
        var deltaCount = 0
        for entry in memoryDeltas {
            if deltaCount >= Self.deltaCountLimit { break }
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let line = "- \(trimmed)\n"
            if deltaUsed + line.count > Self.deltaCharBudget { break }
            deltaLines.append("- \(DreamPart.redact(trimmed))\n")
            deltaUsed += line.count
            deltaCount += 1
        }
        let felt = feltSummary.map(DreamPart.redact)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ["night": dateKey, "world": convLines.joined(), "memories": deltaLines.reversed().joined(),
            "felt": String(felt.prefix(Self.feltCharBudget)), "surprises": surprises, "cares": DreamPart.redact(careBlock)]
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
            guard let id = origin.studioEntryID, DreamPart.redact(id) == id else { continue }
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

    private static func renderDreamBody(
        sessionCount: Int,
        payload: DreamPayload,
        lessons: [DreamLesson],
        studioEntryIDs: [String]
    ) -> String {
        var out = "**\(payload.title)**\n\n"
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
            for lesson in lessons { out += lesson.diaryLine }
            out += "\n"
        }
        let convNote = sessionCount == 1 ? "1 conversation" : "\(sessionCount) conversations"
        out += "_(woven from \(convNote))_\n"
        return out
    }

    /// Give each section its own peers and claim lines so provenance binds to that dream rather than the entire day.
    private static func renderCombinedEntry(heading: String, body: String, claims: [DreamClaim],
                                            sources: [DreamSourceRef]) throws -> String {
        var out = "\(heading)\n\n" + body
        var dropped: [String] = []
        let bound = try DreamEntryProvenance.renderBlock(claims, content: out, sources: sources, dropped: &dropped)
        if !dropped.isEmpty {
            let diagnostic = "_(\(dropped.count == 1 ? "1 claim" : "\(dropped.count) claims") left without sources: \(dropped.joined(separator: "; ")))_"
            out += DreamPart.redact(diagnostic) + "\n"
        }
        try DreamEntryProvenance.checkProse(out)
        out += try DreamEntryProvenance.peerBlock([])
        out += bound
        return out
    }

}
