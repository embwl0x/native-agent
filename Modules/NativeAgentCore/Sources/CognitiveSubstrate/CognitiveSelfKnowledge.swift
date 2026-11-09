import Foundation
import CryptoKit
import Darwin
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSelfKnowledge.swift` | Evidence-linked nightly self reading; cached, epoch-checked atomic mind/self.json |

/// The agent's reading of its own care stories, never a second persona or fact store.
public struct CognitiveSelfKnowledge: Codable, Sendable, Equatable {
    public struct Trait: Codable, Sendable, Equatable {
        public var when: String
        public var iTendTo: String
        public var shownBy: [String]
        enum CodingKeys: String, CodingKey { case when; case iTendTo = "i_tend_to"; case shownBy = "shown_by" }
        public var line: String { "When \(when), I tend to \(iTendTo)" }
        public init?(_ value: JSONValue) {
            guard let fields = value.objectValue,
                  let when = CognitiveSelfKnowledge.words(fields["when"], limit: 120),
                  let tendency = CognitiveSelfKnowledge.words(fields["i_tend_to"], limit: 160),
                  let refs = CognitiveSelfKnowledge.references(fields["shown_by"]) else { return nil }
            self.when = when; self.iTendTo = tendency; self.shownBy = refs
        }
    }
    public struct Story: Codable, Sendable, Equatable {
        public var line: String
        public var shownBy: [String]
        enum CodingKeys: String, CodingKey { case line; case shownBy = "shown_by" }
        public init?(_ value: JSONValue) {
            guard let fields = value.objectValue,
                  let line = CognitiveSelfKnowledge.words(fields["line"], limit: 400),
                  let refs = CognitiveSelfKnowledge.references(fields["shown_by"]) else { return nil }
            self.line = line; self.shownBy = refs
        }
    }
    public struct Person: Codable, Sendable, Equatable {
        public var person: String
        public var line: String
        public init?(_ value: JSONValue) {
            guard let fields = value.objectValue,
                  let person = CognitiveSelfKnowledge.words(fields["person"], limit: 120),
                  let line = CognitiveSelfKnowledge.words(fields["line"], limit: 280) else { return nil }
            self.person = person; self.line = line
        }
    }

    public static let maximumPeople = 128
    public var version = 1
    public var mindEpoch: UInt64
    public var night: String
    public var writtenAt: Date
    public var traits: [Trait]
    public var story: [Story]
    public var people: [Person]
    /// Capture order belongs to the reading, never its later save; nil provides no ordering evidence.
    public var readAt: Date? = nil
    /// Accepted stance progress belongs to each care; delayed evidence on another care remains unread.
    public var stanceReadAt: [String: Date]? = nil

    public static func path(_ root: URL) -> URL { root.appendingPathComponent("mind/self.json") }

    static func words(_ value: JSONValue?, limit: Int) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= limit, !text.contains(where: \.isNewline) else { return nil }
        return text
    }

    static func references(_ value: JSONValue?) -> [String]? {
        guard let raw = value?.arrayValue, !raw.isEmpty, raw.count <= 8 else { return nil }
        let refs = raw.compactMap { words($0, limit: 160) }
        return refs.count == raw.count && Set(refs).count == refs.count ? refs : nil
    }

    /// A story reference survives insertion/reordering and identifies the exact captured entry, including its source and change, rather than an array index.
    static func reference(_ moment: CognitiveCare.Moment, in care: UUID) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(moment) else { return nil }
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        return care.uuidString + "/" + digest
    }

    static func careID(for reference: String) -> UUID? {
        UUID(uuidString: String(reference.split(separator: "/").first ?? ""))
    }

    /// History is unioned at merge, so its exact entry digest stays the same; only the care that holds that evidence changes, through every merge.
    static func survivorReference(_ reference: String, among cares: [UUID: CognitiveCare]) -> String? {
        guard let id = careID(for: reference), let survivor = CognitiveCare.survivorID(for: id, among: cares) else { return nil }
        let suffix = reference.firstIndex(of: "/").map { String(reference[$0...]) } ?? ""
        return survivor.uuidString + suffix
    }

    static func load(_ root: URL) throws -> Self? {
        let path = path(root)
        let fd = Darwin.open(path.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 256_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, 256_001 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 256_000 else { throw CocoaError(.fileReadCorruptFile) }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, !value.night.isEmpty, value.night.count <= 160,
              (value.stanceReadAt ?? [:]).allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.timeIntervalSince1970.isFinite }),
              value.traits.count <= 5, value.story.count <= 5, value.people.count <= maximumPeople,
              value.traits.allSatisfy({ trait in
                  words(.string(trait.when), limit: 120) != nil && words(.string(trait.iTendTo), limit: 160) != nil
                      && references(.array(trait.shownBy.map(JSONValue.string))) != nil
                      && trait.shownBy.allSatisfy { careID(for: $0) != nil }
              }),
              value.story.allSatisfy({ entry in
                  words(.string(entry.line), limit: 400) != nil
                      && references(.array(entry.shownBy.map(JSONValue.string))) != nil
                      && entry.shownBy.allSatisfy { $0.contains("/") && careID(for: $0) != nil }
              }),
              value.people.allSatisfy({ words(.string($0.person), limit: 120) != nil && words(.string($0.line), limit: 280) != nil }),
              Set(value.people.map(\.person)).count == value.people.count else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    func save(_ root: URL) throws {
        let path = Self.path(root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 256_000 else { throw CocoaError(.fileWriteUnknown) }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
    }
}

/// A turn's own signature and relationship, outside competition for a felt cue.
public struct CognitiveTurnSelf: Sendable, Equatable {
    public var trait: String?
    public var withPerson: String?
    public var unavailable: String?
}

extension CognitiveSubstrate {
    /// The capsule supplies its admitted reachable cares; this read needs no message match, file access or presentation ledger.
    public func turnSelf(for speaker: String?, from read: CognitiveFrozenRead, among reachable: [CognitiveCare]) -> CognitiveTurnSelf {
        guard read.configuration.enabled else { return CognitiveTurnSelf(unavailable: "Inner life is off.") }
        guard read.mindEpoch == mindEpoch, !forgettingInFlight else {
            return CognitiveTurnSelf(unavailable: "The self reading is outside this turn's mind epoch.")
        }
        if let failure = selfKnowledgeReadFailure { return CognitiveTurnSelf(unavailable: failure) }
        let inventory = Dictionary(read.cares.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reachableIDs = Set(reachable.map(\.id))
        let trait = read.selfTraits.first { trait in
            !trait.shownBy.isEmpty && trait.shownBy.allSatisfy { reference in
                guard let surviving = CognitiveSelfKnowledge.survivorReference(reference, among: inventory),
                      let id = CognitiveSelfKnowledge.careID(for: surviving) else { return false }
                return reachableIDs.contains(id)
            }
        }
        let person = speaker.map { CognitiveCareProvenance.personKey($0, aliases: read.carePersonAliases) }
            .flatMap { read.carePeopleAvailable || CognitiveCareProvenance.independentPersonKey($0) ? $0 : nil }
        return CognitiveTurnSelf(trait: trait?.line, withPerson: person.flatMap { read.personLines[$0] })
    }

    /// Care stories retain the accepted position before this save, so a refold can finish it without another interpretation.
    func settleLivedSelf(_ ids: [UUID], at now: Date) async throws {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.persistenceEnabled, !forgettingInFlight else { throw CognitiveWriteDiscarded() }
        guard !ids.isEmpty else { return }
        var progress: [String: Date] = [:]
        for (key, at) in selfKnowledge?.stanceReadAt ?? [:] {
            guard let id = UUID(uuidString: key), let survivor = CognitiveCare.survivorID(for: id, among: cares) else { continue }
            let key = survivor.uuidString
            progress[key] = progress[key].map { max($0, at) } ?? at
        }
        var changes: [(UUID, CognitiveCare.Moment)] = []
        for care in ids.compactMap({ cares[$0] }) {
            let readAt: Date? = progress[care.id.uuidString]
            for moment in care.story where moment.stanceChange != nil {
                if let readAt, moment.at <= readAt { continue }
                changes.append((care.id, moment))
            }
        }
        changes.sort { left, right in
            left.1.at != right.1.at ? left.1.at < right.1.at : left.0.uuidString < right.0.uuidString
        }
        guard !changes.isEmpty || unsavedStages.contains("mind.self") else { return }
        if let failure = selfKnowledgeReadFailure {
            throw CognitiveCareNotSaved(detail: "mind/self.json is unreadable; preserved for repair: \(failure)")
        }
        var reading = selfKnowledge
        for (id, moment) in changes {
            guard let stance = moment.stanceChange,
                  let reference = CognitiveSelfKnowledge.reference(moment, in: id),
                  let entry = CognitiveSelfKnowledge.Story(.object([
                    "line": .string(stance.text.split(whereSeparator: { (c: Character) in c.isNewline }).joined(separator: " ")), "shown_by": .array([.string(reference)]),
                  ])) else {
                throw CognitiveCareNotSaved(detail: "The accepted care stance has no encodable self-story evidence.")
            }
            progress[id.uuidString] = moment.at
            if reading?.story.contains(where: { $0.shownBy.contains(reference) }) == true {
                reading?.stanceReadAt = progress
                continue
            }
            var story = reading?.story ?? []
            story.insert(entry, at: 0)
            reading = CognitiveSelfKnowledge(mindEpoch: mindEpoch, night: moment.source, writtenAt: now,
                traits: reading?.traits ?? [], story: Array(story.prefix(5)), people: reading?.people ?? [],
                readAt: reading?.readAt.map { max($0, moment.at) } ?? moment.at, stanceReadAt: progress)
        }
        guard let value = reading, value != selfKnowledge || unsavedStages.contains("mind.self") else { return }
        try await checkingPersistence("mind.self") {
            guard value.mindEpoch == mindEpoch, !forgettingInFlight else { throw CognitiveWriteDiscarded() }
            guard !persistenceHealth.writesBlocked else {
                throw CognitivePersistenceError.writesBlocked(status: persistenceHealth.status, detail: persistenceHealth.failureDetail)
            }
            selfKnowledge = value
            cacheSelfPeople()
            try value.save(conversationDataRoot)
        }
        await recordReceipt(kind: "cares.self", payload: .object([
            "source": .string(value.night), "story": .int(Int64(value.story.count)),
        ]))
    }

    /// Called on restore and address-book invalidation, never from a turn.
    public func refreshCarePeople() async {
        await waitForMaintenanceTransition()
        do {
            let aliases = try dependencies.carePersonAliases()
            carePersonAliases = aliases
            carePeopleReadFailure = nil
            for (id, var care) in cares {
                care.with = Array(Set(care.with.map { CognitiveCareProvenance.personKey($0, aliases: aliases) })).sorted()
                for index in care.story.indices {
                    care.story[index].who = care.story[index].who.map { CognitiveCareProvenance.personKey($0, aliases: aliases) }
                }
                cares[id] = care
            }
            cacheSelfPeople()
        } catch {
            carePersonAliases = [:]
            carePeopleReadFailure = String(describing: error)
            cacheSelfPeople()
            await recordReceipt(kind: "cares.people_unavailable", payload: .object(["error": .string(String(describing: error))]))
        }
    }

    func restoreSelfKnowledge() async {
        await notingPersistenceRead("mind.self.read") {
            do {
                guard let value = try CognitiveSelfKnowledge.load(conversationDataRoot) else {
                    if selfKnowledgeReadFailure != nil {
                        throw CognitiveCareNotSaved(detail: "mind/self.json is absent; no repaired self-knowledge was read")
                    }
                    selfKnowledge = nil
                    cacheSelfPeople()
                    return false
                }
                selfKnowledge = value.mindEpoch == mindEpoch ? value : nil
                cacheSelfPeople()
                selfKnowledgeReadFailure = nil
                return true
            } catch {
                selfKnowledgeReadFailure = String(describing: error)
                throw error
            }
        }
        if selfKnowledgeReadFailure == nil, configuration.enabled, configuration.persistenceEnabled, !persistenceHealth.writesBlocked {
            do { try await settleLivedSelf(Array(cares.keys), at: dependencies.now()) }
            catch {
                await recordReceipt(kind: "cares.self_unavailable", payload: .object(["error": .string(String(describing: error))]))
            }
        }
    }

    func settleSelfKnowledge(_ night: CognitiveCareNight, at now: Date) async throws {
        await waitForMaintenanceTransition()
        if selfKnowledgeReadFailure != nil { await restoreSelfKnowledge() }
        guard configuration.enabled else { throw CognitiveCareNotSaved(detail: "the inner life is off") }
        guard configuration.persistenceEnabled else { throw CognitiveCareNotSaved(detail: "self night requires saved inner life") }
        guard !night.source.isEmpty else { throw CognitiveCareNotSaved(detail: "the night has no committed source") }
        guard let epoch = night.mindEpoch, epoch == mindEpoch else { throw CognitiveWriteDiscarded() }
        let careRefs = Set(night.keys.values.map { $0.id.uuidString })
        let validRefs = careRefs.union(night.selfStoryRefs)
        func surviving(_ refs: [String]) -> [String]? {
            let mapped = refs.compactMap { CognitiveSelfKnowledge.survivorReference($0, among: cares) }
            guard mapped.count == refs.count else { return nil }
            var seen = Set<String>()
            return mapped.filter { seen.insert($0).inserted }
        }
        let traits = night.traits.compactMap { trait -> CognitiveSelfKnowledge.Trait? in
            guard trait.shownBy.allSatisfy(validRefs.contains), let refs = surviving(trait.shownBy) else { return nil }
            var trait = trait; trait.shownBy = refs; return trait
        }
        let story = night.story.compactMap { entry -> CognitiveSelfKnowledge.Story? in
            guard entry.shownBy.allSatisfy(night.selfChangeRefs.contains), let refs = surviving(entry.shownBy) else { return nil }
            var entry = entry; entry.shownBy = refs; return entry
        }
        var seen = Set<String>()
        let people = night.people.filter { night.selfPeople.contains($0.person) && seen.insert($0.person).inserted }
        var progress = selfKnowledge?.stanceReadAt ?? [:]
        for care in night.keys.values {
            if let at = care.story.last(where: { $0.stanceChange != nil })?.at {
                progress[care.id.uuidString] = progress[care.id.uuidString].map { max($0, at) } ?? at
            }
        }
        let value = CognitiveSelfKnowledge(mindEpoch: mindEpoch, night: night.source, writtenAt: now,
            traits: Array(traits.prefix(5)), story: Array(story.prefix(5)),
            people: Array(people.prefix(CognitiveSelfKnowledge.maximumPeople)), readAt: night.readAt, stanceReadAt: progress)
        try await checkingPersistence("mind.self") {
            guard value.mindEpoch == mindEpoch, !forgettingInFlight else { throw CognitiveWriteDiscarded() }
            guard !persistenceHealth.writesBlocked else {
                throw CognitivePersistenceError.writesBlocked(status: persistenceHealth.status, detail: persistenceHealth.failureDetail)
            }
            if let failure = selfKnowledgeReadFailure {
                throw CognitiveCareNotSaved(detail: "mind/self.json is unreadable; preserved for repair: \(failure)")
            }
            let saving: CognitiveSelfKnowledge
            if let current = selfKnowledge {
                if let readAt = current.readAt {
                    saving = readAt >= night.readAt ? current : value
                } else if current.night > night.source {
                    saving = current
                } else if current.night < night.source || current.writtenAt < night.readAt {
                    saving = value
                } else {
                    throw CognitiveCareNotSaved(detail: "retained self reading has no capture order for this night; preserved until a provably newer reading")
                }
            } else {
                saving = value
            }
            // Save the current owner before acknowledging an obsolete delivery: a read cannot retire write debt.
            try saving.save(conversationDataRoot)
            selfKnowledge = saving
            cacheSelfPeople()
        }
    }

    func cacheSelfPeople() {
        selfPersonLines = Dictionary((selfKnowledge?.people ?? []).filter {
            carePeopleReadFailure == nil || CognitiveCareProvenance.independentPersonKey($0.person)
        }.map {
            (CognitiveCareProvenance.personKey($0.person, aliases: carePersonAliases), $0.line)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Extends the care block of the existing dream, never a second model pass. The bounded window is explicit; old folded movements have no person attribution
    /// and must not be presented as measured relationship evidence.
    func selfNightMaterial(keys: inout [String: CognitiveCare], live: [CognitiveCare])
        -> (lines: [String], storyRefs: Set<String>, changeRefs: Set<String>, people: Set<String>) {
        var lines: [String] = [], storyRefs = Set<String>(), changeRefs = Set<String>(), people = Set<String>()
        var remaining = 16_000
        func append(_ line: String) -> Bool {
            guard line.count <= remaining else { return false }
            lines.append(line); remaining -= line.count + 1
            return true
        }
        func include(_ care: CognitiveCare) {
            if !keys.values.contains(where: { $0.id == care.id }) { keys["c\(keys.count + 1)"] = care }
        }
        _ = append("--- PEOPLE IN YOUR CARES (retained, attributed movements only; counts are not a judgment about anyone) ---")
        let grouped = Dictionary(grouping: live.flatMap { care in care.with.filter {
            carePeopleReadFailure == nil || CognitiveCareProvenance.independentPersonKey($0)
        }.map { ($0, care) } }, by: { $0.0 })
        for person in grouped.keys.sorted().prefix(CognitiveSelfKnowledge.maximumPeople) {
            let held = (grouped[person] ?? []).map { $0.1 }.sorted {
                $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString
            }
            let movements = held.flatMap(\.story).filter { $0.by == .them && $0.who == person && $0.moved != 0 }
            let toward = movements.filter { $0.moved > 0 }.count
            let away = movements.count - toward
            let predictability = movements.isEmpty ? "unknown (no attributed movements)"
                : String(format: "%.3f", Double(max(toward, away)) / Double(movements.count))
            let name = person == CognitiveCare.ownerKey ? (checkedUserName() ?? "saved name unavailable") : person
            let shown = Array(held.prefix(8))
            let line = """
                Person \(person) (\(name)): \(movements.count) movements: toward \(toward), away \(away); predictability (dominant direction share): \
                \(predictability). Newest \(shown.count) of \(held.count) cares held with them:\n
                """
                + shown.map { "\($0.id.uuidString): \(Self.careLineText($0))" }.joined(separator: "\n")
            guard append(line) else { continue }
            people.insert(person)
            shown.forEach(include)
        }
        lines.append("""
            You may return \"people\": [{\"person\": \"<exact shown person key>\", \"line\": \"<one line in your own words, at most 280 characters, about who \
            they are to you>\"}]. Only the person you are with will be on your mind in a turn. Predictability describes direction, not goodness or authority. \
            No evidence is unknown, not distrust.
            """)
        remaining += 16_000

        // Include recent changes even when that care was quiet today. They are actual prior depth/stance entries, never predictions of tonight's pass.
        let changed = cares.values.filter { $0.story.contains { $0.depthChange != nil || $0.stanceChange != nil || $0.felt == "changed my mind" } }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
        var candidates = Array(keys.values)
        for care in changed.prefix(10) where !candidates.contains(where: { $0.id == care.id }) { candidates.append(care) }
        candidates.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
        _ = append("--- YOUR CARE STORIES (a bounded retained window; read your if-then signature from what really happened) ---")
        for care in candidates.prefix(48) {
            let changes = care.story.filter { $0.depthChange != nil || $0.stanceChange != nil || $0.felt == "changed my mind" }.suffix(5)
            let recent = care.story.filter { $0.moved != 0 }.suffix(3)
            var rows: [(reference: String, line: String, change: Bool)] = []
            for moment in Array(recent) + Array(changes) {
                guard let ref = CognitiveSelfKnowledge.reference(moment, in: care.id) else { continue }
                let change = moment.depthChange != nil || moment.stanceChange != nil || moment.felt == "changed my mind"
                let depth = moment.depthChange.map { " | depth: \($0.from.rawValue) → \($0.to.rawValue)" } ?? ""
                rows.append((ref, """
                    \(ref): \(NativeTimestampFormat.calendarDay(moment.at)) | \(moment.by.rawValue)\(moment.who.map { " (\($0))" } ?? "") | moved \
                    \(moment.moved) | \(moment.felt): \(moment.note)\(depth)
                    """, change))
            }
            guard !rows.isEmpty, append("\(care.id.uuidString): \(Self.careLineText(care))\n" + rows.map(\.line).joined(separator: "\n")) else { continue }
            include(care)
            storyRefs.formUnion(rows.map(\.reference))
            changeRefs.formUnion(rows.filter(\.change).map(\.reference))
        }
        // Instructions remain outside the material budget so a full window cannot remove the schema or imply that omitted evidence was shown.
        lines.append("""
            You may return \"traits\": at most 5 {\"when\": \"<condition, at most 120 characters>\", \"i_tend_to\": \"<your tendency, at most 160 \
            characters>\", \"shown_by\": [\"<shown care UUID or exact story reference>\"]}. Read them afresh tonight: a trait the shown stories no longer \
            support drops. Never invent adjectives or evidence. You may also return \"story\": at most 5 {\"line\": \"<one line in your voice, at most 400 \
            characters, telling how you changed>\", \"shown_by\": [\"<exact change story reference>\"]}. Each shown_by has 1–8 references to depth changes, \
            changed-my-mind or accepted-stance entries. These optional fields replace your previous night's reading; omit or use [] when unsupported.
            """)
        return (lines, storyRefs, changeRefs, people)
    }
}
