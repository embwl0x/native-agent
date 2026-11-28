import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore

// Blueprint: | `DreamPendingWork.swift` | DreamPendingWork owner. |

/// Write progress before diary publication or effects; checkpoints cannot rewrite immutable diary evidence.
struct DreamPendingWork: Codable, Sendable {
    static let identityPrefix = "<!-- dream-id "
    let id: UUID
    let date: String
    let trigger: DreamTrigger
    let force: Bool
    let sessionsProcessed: Int
    let sourcePeerIds: [String]?
    var lessons: [DreamLesson]
    var reflection: [String: CognitiveReflectionCause]?
    var care: Care?
    var affect: Double?
    var studioEntries: [String]
    /// Retain exact diary write and cutoff until both land to close the two-file crash window.
    var publication: Publication?
    var reflectionReceipt: CognitiveReflectionReceipt?
    var reflectionAcknowledgment: UUID?
    var completion: Completion?
    /// Terminal entries require effect proof or an explicitly disabled owner; pending inputs remain work rather than saved errors.
    var completedSteps: [String: String]?
    var notes: [String: String]?

    struct Completion: Codable, Sendable {
        let occurredAt: Date
        let feltSummary: String?
        let droppedOptionalItems: Int?
    }

    mutating func finish(_ step: String, result: String = "done") {
        if completedSteps == nil { completedSteps = [:] }
        completedSteps?[step] = result
        notes?[step] = nil
    }

    mutating func note(_ step: String, error: Error) {
        if notes == nil { notes = [:] }
        notes?[step] = String(describing: error)
    }

    struct Publication: Codable, Sendable {
        let entry: Data
        let previousDiary: Data?
        let consumedThrough: Date
        /// When the dream began reading what is not conversation; absent in journals written before it existed.
        var materialThrough: Date? = nil
    }

    var isSettled: Bool {
        publication == nil && lessons.isEmpty && reflection == nil && reflectionReceipt == nil && reflectionAcknowledgment == nil
            && care == nil && affect == nil && studioEntries.isEmpty && (completion == nil || completedSteps?["dreamCompleted"] != nil)
    }

    var identityMarker: String { Self.identityPrefix + id.uuidString + " -->" }

    static func directory(_ root: URL) -> URL {
        root.appendingPathComponent("dream_diary/work", isDirectory: true)
    }

    func save(in root: URL) throws {
        let directory = Self.directory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(self),
            to: directory.appendingPathComponent(id.uuidString + ".json"))
    }

    /// Transport retained care judgments and shown revisions unchanged across Stop/restart without creating another authority.
    struct Care: Codable, Sendable {
        struct Merge: Codable, Sendable {
            let keep: UUID?
            let intoIt: [UUID]
            let why: String
        }
        struct Stance: Codable, Sendable {
            let care: UUID
            let pressure: [Int]
            let stance: CognitiveCare.Stance
        }
        let block: String
        let readAt: Date
        let keys: [String: CognitiveCare]
        let answers: [String]
        let source: String
        let clusters: [[UUID]]
        let merges: [Merge]
        let mergesMalformed: Int
        let stanceChanges: [Stance]
        let mindEpoch: UInt64?
        let selfStoryRefs: Set<String>
        let selfChangeRefs: Set<String>
        let selfPeople: Set<String>
        let traits: [CognitiveSelfKnowledge.Trait]
        let story: [CognitiveSelfKnowledge.Story]
        let people: [CognitiveSelfKnowledge.Person]

        init(_ night: CognitiveCareNight) {
            block = night.block; readAt = night.readAt; keys = night.keys; answers = night.answers; source = night.source
            clusters = night.clusters
            merges = night.merges.map { Merge(keep: $0.keep, intoIt: $0.intoIt, why: $0.why) }
            mergesMalformed = night.mergesMalformed
            stanceChanges = night.stanceChanges.map { Stance(care: $0.care, pressure: $0.pressure, stance: $0.stance) }
            mindEpoch = night.mindEpoch; selfStoryRefs = night.selfStoryRefs
            selfChangeRefs = night.selfChangeRefs; selfPeople = night.selfPeople
            traits = night.traits; story = night.story; people = night.people
        }

        var night: CognitiveCareNight {
            CognitiveCareNight(block: block, readAt: readAt, keys: keys, answers: answers, source: source,
                clusters: clusters, merges: merges.map { .init(keep: $0.keep, intoIt: $0.intoIt, why: $0.why) },
                mergesMalformed: mergesMalformed,
                stanceChanges: stanceChanges.map { .init(care: $0.care, pressure: $0.pressure, stance: $0.stance) },
                mindEpoch: mindEpoch, selfStoryRefs: selfStoryRefs, selfChangeRefs: selfChangeRefs,
                selfPeople: selfPeople, traits: traits, story: story, people: people)
        }
    }
}

extension FileBackedDreamDiary {
    /// Publication and its original completion input belong to the same section journal, independent of tone and body effects.
    public static func savedCompletion(dataRoot: URL, since: Date, through: Date) throws -> CognitiveSleepDreamReading.Completion? {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: DreamPendingWork.directory(dataRoot), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        var latest: CognitiveSleepDreamReading.Completion?
        var failures: [String] = []
        for file in files {
            do {
                let work = try JSONDecoder().decode(DreamPendingWork.self, from: Data(contentsOf: file))
                guard file.lastPathComponent == work.id.uuidString + ".json" else {
                    throw PersistenceCoreError.ioFailure("dream work identity differs from its path")
                }
                guard work.publication == nil, work.completedSteps?["publication"] == "done",
                      let completion = work.completion, completion.occurredAt >= since, completion.occurredAt <= through else { continue }
                if latest.map({ $0.occurredAt < completion.occurredAt }) ?? true {
                    latest = .init(id: work.id, occurredAt: completion.occurredAt)
                }
            } catch {
                failures.append("\(file.path) completion unavailable: \(error)")
            }
        }
        if let latest { return latest }
        if !failures.isEmpty { throw PersistenceCoreError.ioFailure(failures.joined(separator: "; ")) }
        return nil
    }
}

extension DreamCycleRunner {
    /// Keep item payloads owed on failure while independent items and nights proceed through the same section journal.
    func retryPendingWork(delivery: DreamEffectSink?) async
        -> (settled: Int, lessonsSaved: Int, errors: [(journal: URL?, words: String)],
            discoveryUnavailable: Bool, busy: [String], revisited: Set<URL?>) {
        guard !Task.isCancelled else { return (0, 0, [(nil, Self.stopPendingWords)], false, [], []) }
        let directory = DreamPendingWork.directory(dataRoot)
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            files = []
        } catch {
            return (0, 0, [(nil, "dream work discovery failed: \(error)")], true, [], [])
        }
        let progress = DreamRetryProgress()
        let records = readPendingDreams(files, progress: progress)
        var revisited: Set<URL?> = [nil]
        for (file, saved) in records.sorted(by: {
            $0.1.date == $1.1.date ? $0.0.path < $1.0.path : $0.1.date < $1.1.date
        }) {
            if Task.isCancelled { progress.errors.append((nil, Self.stopPendingWords)); break }
            var work = saved
            guard !work.isSettled else { continue }
            do {
                do { try publishPendingDream(&work) }
                catch { progress.publicationUnavailable = true; throw error }
                work = try await retryDreamLessonsAndReflection(work, file: file, delivery: delivery, progress: progress)
                work = try await retryRemainingDreamEffects(work, file: file, delivery: delivery, progress: progress)
                if work.isSettled { progress.settled += 1 }
            } catch is CancellationError {
                progress.errors.append((nil, Self.stopPendingWords))
                break
            } catch {
                progress.errors.append((file, "\(file.path) settlement unavailable: \(error)"))
            }
            revisited.insert(file)
        }
        return (progress.settled, progress.lessonsSaved, progress.errors, progress.publicationUnavailable, progress.busy, revisited)
    }

    private final class DreamRetryProgress {
        var errors: [(journal: URL?, words: String)] = []
        var busy: [String] = []
        var settled = 0
        var lessonsSaved = 0
        var publicationUnavailable = false
    }

    private func readPendingDreams(_ files: [URL], progress: DreamRetryProgress) -> [(URL, DreamPendingWork)] {
        // Read before delivery so damaged records cannot be replaced silently.
        var records: [(URL, DreamPendingWork)] = []
        for file in files {
            do {
                let work = try JSONDecoder().decode(DreamPendingWork.self, from: Data(contentsOf: file))
                guard file.lastPathComponent == work.id.uuidString + ".json",
                      work.date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
                    throw PersistenceCoreError.ioFailure("dream work identity differs from its path or date")
                }
                if let receipt = work.reflectionReceipt {
                    guard receipt.request.reason == "dream:\(work.id.uuidString)", let judgment = receipt.judgment else {
                        throw PersistenceCoreError.ioFailure("retained reflection differs from its dream or has no judgment")
                    }
                    try judgment.validate(material: receipt.request.material, cares: receipt.request.cares)
                }
                records.append((file, work))
            } catch {
                progress.errors.append((nil, "\(file.path) settlement unavailable: \(error)"))
                // An unreadable journal may still owe publication.
                progress.publicationUnavailable = true
            }
        }
        // Resolve work by actual diary identity; missing retained input owes repair and cannot be reconstructed from prose.
        let journalIDs = Set(records.map { $0.1.id })
        do {
            let diary = FileBackedDreamDiary(dataRoot: dataRoot)
            for file in try diary.discover(in: .active, matching: .dated) {
                do {
                    let content = try String(contentsOf: file.url, encoding: .utf8)
                    let identities = content.components(separatedBy: "\n").filter { $0.hasPrefix(DreamPendingWork.identityPrefix) }
                    for line in identities {
                        guard line.hasSuffix(" -->"),
                              let id = UUID(uuidString: String(line.dropFirst(DreamPendingWork.identityPrefix.count).dropLast(4))),
                              journalIDs.contains(id) else {
                            throw PersistenceCoreError.ioFailure("diary section's work journal is missing or unreadable")
                        }
                    }
                } catch {
                    progress.errors.append((nil, "\(file.url.path) saved work unavailable: \(error)"))
                }
            }
        } catch {
            progress.publicationUnavailable = true
            progress.errors.append((nil, "dream diary discovery failed: \(error)"))
        }
        return records
    }

    private func retryDreamLessonsAndReflection(_ pending: DreamPendingWork, file: URL, delivery: DreamEffectSink?,
                                                progress: DreamRetryProgress) async throws -> DreamPendingWork {
        var work = pending
        let offered = work.lessons.count
        var saved = 0
        for index in work.lessons.indices.reversed() {
            try Task.checkCancellation()
            let lesson = work.lessons[index]
            do {
                try await commitLesson(lesson, dateKey: work.date, sourcePeerIds: work.sourcePeerIds)
                saved += 1
                progress.lessonsSaved += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = (error as? ToolFailureError) ?? (error as? MemoryStorageError)?.failure
                guard let failure, failure.status == .refused, failure.effects == .none, failure.recovery == .terminal else {
                    work.note("lessons", error: error)
                    progress.errors.append((file, "\(file.path) lesson \(lesson.from): \(error)"))
                    continue
                }
                let input = JSONValue.array([.string(lesson.lesson), .string(lesson.from), .string(lesson.kind)])
                work.finish("lesson:" + (try input.serialize(pretty: false)), result: "refused: \(failure.message)")
                progress.errors.append((file, "\(file.path) lesson \(lesson.from) refused: \(failure.message)"))
            }
            work.lessons.remove(at: index)
            if work.lessons.isEmpty { work.finish("lessons") }
            try work.save(in: dataRoot)
        }
        if offered > 0 { try work.save(in: dataRoot) }
        if offered > 0 {
            do {
                try await receiptSink("dream.lessons", .object([
                    "date": .string(work.date), "dreamId": .string(work.id.uuidString),
                    "offered": .int(Int64(offered)), "saved": .int(Int64(saved)),
                    "failed": .int(Int64(offered - saved))]))
            } catch is CancellationError {
                throw CancellationError()
            } catch { progress.errors.append((file, "\(file.path) lesson receipt failed: \(error)")) }
        }
        // Failure notes cannot block another attempt; only Stop or shared-journal failure prevents sibling steps.
        if let material = work.reflection {
            try Task.checkCancellation()
            do {
                guard !material.isEmpty else { throw PersistenceCoreError.ioFailure("captured dream reflection material is empty") }
                let result = try await deliver(.reflectionJudgment(material), work: work, sink: delivery)
                switch result {
                case .reflection(let receipt):
                    guard receipt.request.reason == "dream:\(work.id.uuidString)", receipt.judgment != nil else {
                        throw PersistenceCoreError.ioFailure("reflection returned a receipt for another dream or no judgment")
                    }
                    work.reflectionReceipt = receipt
                    work.finish("reflection.judgment")
                case .skipped(let reason):
                    work.finish("reflection.judgment", result: "skipped: " + reason)
                    work.finish("reflection.integration", result: "skipped: " + reason)
                case .done:
                    throw PersistenceCoreError.ioFailure("reflection judgment returned without a receipt")
                }
                work.reflection = nil
            } catch let held as DreamBusy {
                // Busy keeps the judgment owed for the next run without failing this one.
                work.note("reflection.judgment", error: held)
                progress.busy.append("reflection for \(work.date): \(held.words)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                work.note("reflection.judgment", error: error)
                progress.errors.append((file, "\(file.path) reflection judgment owed: \(error)"))
            }
            // Checkpoint judgment before integration so no effect precedes its durable cause.
            try work.save(in: dataRoot)
        }
        if let receipt = work.reflectionReceipt {
            try Task.checkCancellation()
            do {
                let result = try await deliver(.reflectionIntegration(receipt), work: work, sink: delivery)
                try finishDelivery(result, step: "reflection.integration", work: &work)
                work.reflectionAcknowledgment = receipt.id
                work.reflectionReceipt = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                work.note("reflection.integration", error: error)
                progress.errors.append((file, "\(file.path) reflection integration owed: \(error)"))
            }
            try work.save(in: dataRoot)
        }
        if let id = work.reflectionAcknowledgment {
            try Task.checkCancellation()
            do {
                let result = try await deliver(.reflectionAcknowledgment(id), work: work, sink: delivery)
                try finishDelivery(result, step: "reflection.acknowledgment", work: &work)
                work.reflectionAcknowledgment = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                work.note("reflection.acknowledgment", error: error)
                progress.errors.append((file, "\(file.path) reflection acknowledgment owed: \(error)"))
            }
            try work.save(in: dataRoot)
        }
        return work
    }

    private func retryRemainingDreamEffects(_ pending: DreamPendingWork, file: URL, delivery: DreamEffectSink?,
                                            progress: DreamRetryProgress) async throws -> DreamPendingWork {
        var work = pending
        if let care = work.care {
            try Task.checkCancellation()
            do {
                let result = try await deliver(.care(care.night), work: work, sink: delivery)
                try finishDelivery(result, step: "care", work: &work)
                work.care = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                work.note("care", error: error)
                progress.errors.append((file, "\(file.path) care delivery owed: \(error)"))
            }
            try work.save(in: dataRoot)
        }
        if let affect = work.affect {
            try Task.checkCancellation()
            do {
                let skipped = try await integrateMood(affect: affect, dateKey: work.date, dreamId: work.id)
                work.affect = nil
                work.finish("mood", result: skipped.map { "skipped: " + $0 } ?? "done")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                work.note("mood", error: error)
                progress.errors.append((file, "\(file.path) mood delivery owed: \(error)"))
            }
            try work.save(in: dataRoot)
        }
        if !work.studioEntries.isEmpty {
            try Task.checkCancellation()
            do {
                try await receiptSink(Self.studioCitationReceiptKind, .object([
                    "date": .string(work.date), "dreamId": .string(work.id.uuidString), "trigger": .string(work.trigger.rawValue),
                    "entries": .array(work.studioEntries.map(JSONValue.string))]))
                work.studioEntries = []
                work.finish("studio.citations")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                work.note("studio.citations", error: error)
                progress.errors.append((file, "\(file.path) studio citation owed: \(error)"))
            }
            try work.save(in: dataRoot)
        }
        if let completion = work.completion, work.completedSteps?["dreamCompleted"] == nil {
            try Task.checkCancellation()
            do {
                let result = try await deliver(.completion(occurredAt: completion.occurredAt,
                    feltSummary: completion.feltSummary, droppedOptionalItems: completion.droppedOptionalItems),
                    work: work, sink: delivery)
                try finishDelivery(result, step: "dreamCompleted", work: &work)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                work.note("dreamCompleted", error: error)
                progress.errors.append((file, "\(file.path) dream completion owed: \(error)"))
            }
            try work.save(in: dataRoot)
        }
        return work
    }

    private func deliver(_ effect: DreamEffect, work: DreamPendingWork, sink: DreamEffectSink?) async throws -> DreamEffectResult {
        guard let sink else { throw PersistenceCoreError.ioFailure("dream effect delivery is unavailable") }
        return try await sink(DreamDelivery(id: work.id, date: work.date, trigger: work.trigger,
            force: work.force, sessionsProcessed: work.sessionsProcessed, effect: effect))
    }

    private func finishDelivery(_ result: DreamEffectResult, step: String, work: inout DreamPendingWork) throws {
        switch result {
        case .done: work.finish(step)
        case .skipped(let reason): work.finish(step, result: "skipped: " + reason)
        case .reflection: throw PersistenceCoreError.ioFailure("\(step) returned a judgment instead of effect acknowledgment")
        }
    }

    /// Use immutable diary identity to reconcile publication after interruption under the run reservation.
    func publishPendingDream(_ work: inout DreamPendingWork) throws {
        guard let publication = work.publication else { return }
        let path = dataRoot.appendingPathComponent("dream_diary/\(work.date).md")
        let current: Data?
        do { current = try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = nil }
        let text: String?
        if let current {
            guard let decoded = String(data: current, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            text = decoded
        } else { text = nil }
        if text?.components(separatedBy: "\n").contains(work.identityMarker) != true {
            guard current == publication.previousDiary else {
                throw PersistenceCoreError.ioFailure("dream diary changed before its captured publication landed; preserved for repair: \(path.path)")
            }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(publication.entry, to: path)
        }
        try advanceDreamMark(to: publication.consumedThrough, materialThrough: publication.materialThrough)
        work.publication = nil
        work.finish("publication")
        try work.save(in: dataRoot)
    }
}
