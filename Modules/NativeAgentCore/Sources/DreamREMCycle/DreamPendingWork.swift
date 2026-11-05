import Foundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate

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
    }

    var isSettled: Bool {
        publication == nil && lessons.isEmpty && reflection == nil && reflectionReceipt == nil && reflectionAcknowledgment == nil
            && care == nil && affect == nil && studioEntries.isEmpty && completion == nil
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

extension DreamCycleRunner {
    /// Keep item payloads owed on failure while independent items and nights proceed through the same section journal.
    func retryPendingWork(delivery: DreamEffectSink?) async
        -> (settled: Int, lessonsSaved: Int, errors: [String], pendingPaths: Set<String>, discoveryUnavailable: Bool, busy: [String]) {
        guard !Task.isCancelled else { return (0, 0, ["dream delivery remains pending after Stop"], [], false, []) }
        let directory = DreamPendingWork.directory(dataRoot)
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            files = []
        } catch {
            return (0, 0, ["dream work discovery failed: \(error)"], [], true, [])
        }
        var errors: [String] = []
        var busy: [String] = []
        var pendingPaths: Set<String> = []
        var settled = 0, lessonsSaved = 0
        var publicationUnavailable = false
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
                errors.append("\(file.path) settlement unavailable: \(error)")
                // An unreadable journal may still owe publication.
                publicationUnavailable = true
            }
        }
        // Resolve work by actual diary identity; missing retained input owes repair and cannot be reconstructed from prose.
        let journalIDs = Set(records.map { $0.1.id })
        do {
            let diary = FileBackedDreamDiary(dataRoot: dataRoot)
            for file in try diary.discover(in: .includingArchives, matching: .dated) {
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
                    pendingPaths.insert(dataRoot.appendingPathComponent("dream_diary/\(file.day ?? file.stem).md").path)
                    errors.append("\(file.url.path) saved work unavailable: \(error)")
                }
            }
        } catch {
            publicationUnavailable = true
            errors.append("dream diary discovery failed: \(error)")
        }
        for (file, saved) in records.sorted(by: {
            $0.1.date == $1.1.date ? $0.0.path < $1.0.path : $0.1.date < $1.1.date
        }) {
            if Task.isCancelled { errors.append("dream delivery remains pending after Stop"); break }
            var work = saved
            guard !work.isSettled else { continue }
            let path = dataRoot.appendingPathComponent("dream_diary/\(work.date).md")
            do {
                do { try publishPendingDream(&work) }
                catch { publicationUnavailable = true; throw error }
                let offered = work.lessons.count
                for index in work.lessons.indices.reversed() {
                    try Task.checkCancellation()
                    do { try await commitLesson(work.lessons[index], dateKey: work.date, sourcePeerIds: work.sourcePeerIds) }
                    catch {
                        work.note("lessons", error: error)
                        errors.append("\(file.path) lesson \(work.lessons[index].from): \(error)")
                        continue
                    }
                    work.lessons.remove(at: index)
                    if work.lessons.isEmpty { work.finish("lessons") }
                    try work.save(in: dataRoot)
                }
                if offered > 0 { try work.save(in: dataRoot) }
                lessonsSaved += offered - work.lessons.count
                if offered > 0 {
                    do {
                        try await receiptSink("dream.lessons", .object([
                            "date": .string(work.date), "dreamId": .string(work.id.uuidString),
                            "offered": .int(Int64(offered)), "saved": .int(Int64(offered - work.lessons.count)),
                            "failed": .int(Int64(work.lessons.count))]))
                    } catch { errors.append("\(file.path) lesson receipt failed: \(error)") }
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
                        busy.append("reflection for \(work.date): \(held.words)")
                    } catch {
                        work.note("reflection.judgment", error: error)
                        errors.append("\(file.path) reflection judgment owed: \(error)")
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
                    } catch {
                        work.note("reflection.integration", error: error)
                        errors.append("\(file.path) reflection integration owed: \(error)")
                    }
                    try work.save(in: dataRoot)
                }
                if let id = work.reflectionAcknowledgment {
                    try Task.checkCancellation()
                    do {
                        let result = try await deliver(.reflectionAcknowledgment(id), work: work, sink: delivery)
                        try finishDelivery(result, step: "reflection.acknowledgment", work: &work)
                        work.reflectionAcknowledgment = nil
                    } catch {
                        work.note("reflection.acknowledgment", error: error)
                        errors.append("\(file.path) reflection acknowledgment owed: \(error)")
                    }
                    try work.save(in: dataRoot)
                }
                if let care = work.care {
                    try Task.checkCancellation()
                    do {
                        let result = try await deliver(.care(care.night), work: work, sink: delivery)
                        try finishDelivery(result, step: "care", work: &work)
                        work.care = nil
                    } catch {
                        work.note("care", error: error)
                        errors.append("\(file.path) care delivery owed: \(error)")
                    }
                    try work.save(in: dataRoot)
                }
                if let affect = work.affect {
                    try Task.checkCancellation()
                    do {
                        let skipped = try await integrateMood(affect: affect,
                            in: dataRoot.appendingPathComponent("dream_diary", isDirectory: true), dateKey: work.date)
                        work.affect = nil
                        work.finish("mood", result: skipped.map { "skipped: " + $0 } ?? "done")
                    } catch {
                        work.note("mood", error: error)
                        errors.append("\(file.path) mood delivery owed: \(error)")
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
                    } catch {
                        work.note("studio.citations", error: error)
                        errors.append("\(file.path) studio citation owed: \(error)")
                    }
                    try work.save(in: dataRoot)
                }
                if let completion = work.completion {
                    try Task.checkCancellation()
                    do {
                        let result = try await deliver(.completion(occurredAt: completion.occurredAt,
                            feltSummary: completion.feltSummary), work: work, sink: delivery)
                        try finishDelivery(result, step: "dreamCompleted", work: &work)
                        work.completion = nil
                    } catch {
                        work.note("dreamCompleted", error: error)
                        errors.append("\(file.path) dream completion owed: \(error)")
                    }
                    try work.save(in: dataRoot)
                }
                if work.isSettled { settled += 1 }
                else { pendingPaths.insert(path.path) }
            } catch {
                pendingPaths.insert(path.path)
                errors.append("\(file.path) settlement unavailable: \(error)")
            }
        }
        return (settled, lessonsSaved, errors, pendingPaths, publicationUnavailable, busy)
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
        try advanceDreamMark(to: publication.consumedThrough)
        work.publication = nil
        work.finish("publication")
        try work.save(in: dataRoot)
    }
}
