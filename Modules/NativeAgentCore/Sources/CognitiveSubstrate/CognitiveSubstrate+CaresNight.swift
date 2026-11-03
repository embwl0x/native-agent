import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+CaresNight.swift` | `CognitiveSubstrate` cares at night: bounded meaning clusters and stance/self/person evidence; checked resident care and self saves before acknowledgment, fade/deepen and life approval; previewCaresNight runs the same ordered answer/stance/merge transformations on a current owner copy without save or receipt, refusing unavailable state and changed epochs |

// The night deepens what keeps moving her and lets go of what never does after the
// dream commits. The only model in it is the dream she already has, which is
// shown what moved her today and what has stayed open, and may answer that an
// open care is settled or that she lets it go.

/// The night's cares: the block the dream is shown, the keys it names, and,
/// once the dream committed, the lines it answered.
public struct CognitiveCareNight: Sendable, Equatable {
    public var block: String
    /// When the owner captured this reading, independent of delayed delivery.
    public var readAt: Date
    /// The exact care revision shown at each key, including its open gap.
    public var keys: [String: CognitiveCare]
    public var answers: [String]
    public var clusters: [[UUID]]
    public var merges: [CognitiveCareMerge]
    public var mergesMalformed: Int
    public var stanceChanges: [CognitiveCareStanceChange]
    public var mindEpoch: UInt64?
    public var selfStoryRefs: Set<String>
    public var selfChangeRefs: Set<String>
    public var selfPeople: Set<String>
    public var traits: [CognitiveSelfKnowledge.Trait]
    public var story: [CognitiveSelfKnowledge.Story]
    public var people: [CognitiveSelfKnowledge.Person]
    /// `dream_diary/<date>.md`: the entry the pass follows, the source of its moments.
    public var source: String

    public init(block: String, readAt: Date, keys: [String: CognitiveCare], answers: [String] = [], source: String = "",
                clusters: [[UUID]] = [], merges: [CognitiveCareMerge] = [], mergesMalformed: Int = 0, stanceChanges: [CognitiveCareStanceChange] = [],
                mindEpoch: UInt64? = nil, selfStoryRefs: Set<String> = [], selfChangeRefs: Set<String> = [],
                selfPeople: Set<String> = [], traits: [CognitiveSelfKnowledge.Trait] = [],
                story: [CognitiveSelfKnowledge.Story] = [], people: [CognitiveSelfKnowledge.Person] = []) {
        self.block = block
        self.readAt = readAt
        self.keys = keys
        self.answers = answers
        self.source = source
        self.clusters = clusters
        self.merges = merges
        self.mergesMalformed = mergesMalformed
        self.stanceChanges = stanceChanges
        self.mindEpoch = mindEpoch
        self.selfStoryRefs = selfStoryRefs
        self.selfChangeRefs = selfChangeRefs
        self.selfPeople = selfPeople
        self.traits = traits
        self.story = story
        self.people = people
    }
}

extension CognitiveSubstrate {
    public func carePreviewRefusal() -> String? {
        guard persistenceRestored, !restoreInFlight, !forgettingInFlight, !maintenanceRunInFlight else {
            return "Her saved mind is unavailable or in a transition; preview cannot judge it yet."
        }
        guard configuration.enabled else { return "Inner life is off." }
        return nil
    }

    /// The owner-review card that takes a season care to life depth.
    public static let careLifeApprovalAction = "care.life"
    /// An open care unmoved this long, at lately or deeper, is stuck.
    static let careStuckAfter: TimeInterval = 7 * 86_400
    static let dreamMovedCares = 8
    static let dreamOpenCares = 5
    static let dreamMomentsPerCare = 3
    static let maximumCareStoryLines = 24

    /// How long a care keeps without moving her before the night fades it.
    static func careFadeHorizon(_ depth: CognitiveCare.Depth) -> TimeInterval? {
        switch depth {
        case .now: return 2 * 86_400
        case .lately: return 14 * 86_400
        case .season: return 90 * 86_400
        case .life: return nil
        }
    }

    // MARK: - What the dream is shown

    /// The cares that moved her in the last day, with their felt words and
    /// notes, and her stuck open cares. nil when the inner life is off.
    public func careNightMaterial() async throws -> CognitiveCareNight? {
        guard configuration.enabled else { return nil }
        await waitForMaintenanceTransition()
        guard persistenceRestored, configuration.persistenceEnabled, !persistenceHealth.writesBlocked else {
            throw CognitiveCareNotSaved(detail: "cognition/cognition.sqlite care evidence is unavailable: \(String(describing: persistenceHealth.failureDetail))")
        }
        if selfKnowledgeReadFailure != nil { await restoreSelfKnowledge() }
        if carePeopleReadFailure != nil { await refreshCarePeople() }
        let generation = caringAppraisalGeneration
        let candidates = cares.values.filter { $0.fadedAt == nil }
        // The same warm embedder and exact-text cache as careTouched; never load
        // a second model for night. Cold or unreadable evidence stays owed.
        let vectors: [UUID: [Float]]
        do {
            if let first = candidates.first {
                // Use this lookup's one epoch, never another lookup's cache
                // publication after suspension. Cold is an unavailable reading.
                guard let lookup = try await careVectorLookup(queries: [first.about], among: candidates) else {
                    throw CognitiveCareNotSaved(detail: "the embedder is cold; care night evidence remains owed")
                }
                vectors = lookup.cares
            } else { vectors = [:] }
        } catch { oweCareEmbedding(error); throw error }
        guard configuration.enabled, generation == caringAppraisalGeneration else { throw CognitiveWriteDiscarded() }
        if let failure = selfKnowledgeReadFailure {
            throw CognitiveCareNotSaved(detail: "mind/self.json night evidence is unavailable: \(failure)")
        }
        if let failure = carePeopleReadFailure {
            throw CognitiveCareNotSaved(detail: "care people evidence is unavailable: \(failure)")
        }
        let now = dependencies.now()
        let live = cares.values.filter { $0.fadedAt == nil }
        let currentVectors = vectors.filter { id, _ in
            candidates.first { $0.id == id }.map { captured in
                cares[id].map { Self.careEmbeddingText($0) == Self.careEmbeddingText(captured) } == true
            } == true
        }
        let clusters = Self.careMergeClusters(among: Array(live), vectors: currentVectors)
        let moved = live.compactMap { care -> (care: CognitiveCare, today: [CognitiveCare.Moment], magnitude: Double)? in
            let today = care.story.filter { $0.moved != 0 && now.timeIntervalSince($0.at) < 86_400 }
            return today.isEmpty ? nil : (care, today, today.reduce(0) { $0 + abs($1.moved) })
        }
        .sorted { $0.magnitude > $1.magnitude }
        .prefix(Self.dreamMovedCares)
        let movedIDs = Set(moved.map(\.care.id))
        let stuck = live.compactMap { care -> (care: CognitiveCare, lastMoved: Date)? in
            guard care.open != nil, care.depth != .now, !movedIDs.contains(care.id) else { return nil }
            let lastMoved = Self.careLastMoved(care)
            return now.timeIntervalSince(lastMoved) >= Self.careStuckAfter ? (care, lastMoved) : nil
        }
        .sorted { $0.lastMoved < $1.lastMoved }
        .prefix(Self.dreamOpenCares)
        .map(\.care)
        var keys: [String: CognitiveCare] = [:]
        func key(_ care: CognitiveCare) -> String {
            if let existing = keys.first(where: { $0.value.id == care.id })?.key { return existing }
            let key = "c\(keys.count + 1)"
            keys[key] = care
            return key
        }
        var lines: [String] = []
        if !moved.isEmpty {
            lines.append("--- WHAT MOVED YOU TODAY (your cares; dream about what actually mattered) ---")
            for (care, today, _) in moved {
                let felt = today.suffix(Self.dreamMomentsPerCare).map { "\($0.felt) (\($0.note))" }
                lines.append("\(key(care)). \(care.about): " + felt.joined(separator: "; ")
                    + (care.open.map { " | open: \($0)" } ?? ""))
            }
        }
        if !stuck.isEmpty {
            lines.append("--- STILL OPEN (cares you have carried a while; nothing has moved them in a week) ---")
            for care in stuck { lines.append("\(key(care)). \(care.about): \(care.open ?? "")") }
        }
        if moved.contains(where: { $0.care.open != nil }) || !stuck.isEmpty {
            lines.append("If tonight shows you that one of these open cares is settled, or that you are ready to "
                + "let it go, add one more key to the JSON, \"cares\": an array of lines, each "
                + "\"settled: <key>: <how, in a few words>\" or \"let go: <key>\". Leave it out otherwise.")
        }
        if !clusters.isEmpty {
            lines.append("--- MAY BE ONE CARE (meaning nominations, not decisions) ---")
            // 10-31: told "only what is truly the same thing", she kept eight chess
            // cares apart as facets. A care is the thing; its sides are its story.
            lines.append("A care is one thing you care about; the sides of it live in its story. Merging keeps every story entry, "
                + "movement and phrasing of the merged cares and lets the thing deepen as one. Merge cares that are one thing "
                + "seen from different sides; keep apart cares that are about different things.")
            for (index, cluster) in clusters.enumerated() {
                lines.append("Cluster \(index + 1):")
                for care in cluster {
                    _ = key(care)
                    lines.append("\(care.id.uuidString): \(Self.careLineText(care))")
                }
            }
            lines.append("You may add \"merge\": [{\"keep\": \"<care UUID>\", \"into_it\": [\"<other UUID>\"], \"why\": \"your reason\"}]. Use only members of one shown cluster. Omit keep to retain its oldest care. Leave merge out when they are different things.")
        }
        let pressured = live.filter { Self.careStancePressure($0).count >= 2 }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
        for care in pressured where Self.careStanceHasDays(Self.careStancePressure(care), depth: care.depth) {
            _ = key(care)
            lines.append("--- STANCE PRESSURE: \(care.id.uuidString): \(care.about) | held: \(care.stance?.text ?? "") ---")
            for (index, entry) in Self.careStancePressure(care).enumerated() {
                guard let stance = entry.stancePressure else { continue }
                lines.append("\(index + 1). \(NativeTimestampFormat.calendarDay(entry.at)): \(stance.text) | because: \(stance.because) | unless: \(stance.wouldChangeMind)")
            }
            lines.append("If entries point the same way and you confirm changing this stance, add \"stance_changes\": [{\"care\": \"<UUID>\", \"pressure\": [<entry numbers pointing the same way>], \"stance\": {\"text\": \"...\", \"because\": \"...\", \"unless\": \"...\"}}]. Evidence needs 2 distinct days, or for life 3 days spanning 14 days. Otherwise hold your stance. Leave the key out when nothing changes.")
        }
        let selfMaterial = selfNightMaterial(keys: &keys, live: Array(live))
        lines += selfMaterial.lines
        return CognitiveCareNight(block: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n", readAt: now, keys: keys,
            clusters: clusters.map { $0.map(\.id) }, mindEpoch: mindEpoch,
            selfStoryRefs: selfMaterial.storyRefs, selfChangeRefs: selfMaterial.changeRefs, selfPeople: selfMaterial.people)
    }

    // MARK: - The night's pass

    /// After the dream committed: its settle and let-go lines, then every live
    /// care that is not life depth fades past its horizon or deepens by the
    /// distinct local days it moved her. Returns the season cares ready for
    /// life depth, which only the owner-review card grants.
    @discardableResult
    public func passCaresNight(_ night: CognitiveCareNight) async throws -> [CognitiveCare] {
        await waitForMaintenanceTransition()
        guard configuration.enabled else { throw CognitiveCareNotSaved(detail: "the inner life is off") }
        guard configuration.persistenceEnabled else { throw CognitiveCareNotSaved(detail: "care night requires saved inner life") }
        guard let epoch = night.mindEpoch, epoch == mindEpoch else { throw CognitiveWriteDiscarded() }
        let now = dependencies.now()
        let calendar = Calendar.current
        var changed: [UUID] = []
        var settled = 0, letGo = 0, faded = 0, deepened = 0
        // Every dream judgment checks the same pre-pass revision. This night's
        // own gap/stance settlements do not make its other judgments stale.
        let original = cares
        _ = Self.applyCareAnswers(night, at: now, cares: &cares, changed: &changed, settled: &settled, letGo: &letGo)
        var stanceOutcomes: [JSONValue] = []
        let stances = Self.applyCareStances(night, original: original, at: now, cares: &cares, changed: &changed, outcomes: &stanceOutcomes)
        var mergeOutcomes: [JSONValue] = []
        let merged = Self.applyCareMerges(night, original: original, at: now, cares: &cares, changed: &changed, outcomes: &mergeOutcomes)
        var ready: [CognitiveCare] = []
        for var care in Array(cares.values) where care.fadedAt == nil && care.depth != .life && care.origin != .seed {
            if let horizon = Self.careFadeHorizon(care.depth), now.timeIntervalSince(Self.careLastMoved(care)) > horizon {
                care.fadedAt = now
                cares[care.id] = care
                changed.append(care.id)
                faded += 1
                continue
            }
            var deeper = false
            // Depth notes leave these local-day witnesses unchanged for every threshold.
            let dates = (care.folded?.movedDays ?? []) + care.story.filter { $0.moved != 0 }.map(\.at)
            let moved = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
            let span = calendar.dateComponents([.day], from: moved.first ?? now, to: moved.last ?? now).day ?? 0
            while let next = Self.careEarnedDepth(care.depth, days: moved.count, span: span) {
                care.record(CognitiveCare.Moment(
                    at: now, moved: 0, by: .her, felt: "deepened", note: "now part of my \(next.rawValue)",
                    source: night.source, depthChange: .init(from: care.depth, to: next)))
                care.depth = next
                deeper = true
                deepened += 1
            }
            if deeper {
                cares[care.id] = care
                changed.append(care.id)
            }
            if care.depth == .season, moved.count >= 8, span >= 60 {
                ready.append(care)
            }
        }
        if !changed.isEmpty { markDirty(at: now) }
        // Revision checks can make a retry's judgments inert even though their
        // resident revisions still owe a write. Save the owner's actual snapshot,
        // including merged/faded rows, before acknowledging this night.
        if case .failure(let error) = await saveCares(Array(cares.keys), at: now) {
            await recordReceipt(kind: "cares.night_unsaved", payload: .object([
                "source": .string(night.source), "error": .string(error.description),
            ]))
            throw error
        }
        // Her reading refers to the exact stories shown before this pass;
        // tonight's new depth/stance entries become material for her next night.
        try await settleSelfKnowledge(night, at: now)
        await recordReceipt(kind: "cares.night", payload: .object([
            "source": .string(night.source),
            "settled": .int(Int64(settled)), "letGo": .int(Int64(letGo)),
            "faded": .int(Int64(faded)), "deepened": .int(Int64(deepened)),
            "merged": .int(Int64(merged)), "stancesChanged": .int(Int64(stances)),
            "readyForLife": .array(ready.map { .string($0.id.uuidString) }),
            // What the night was shown and what it chose, so a cluster left
            // apart is visibly her choice, not an unshown one.
            "clustersShown": .array(night.clusters.map { ids in
                .array(ids.map { id in .string(original[id].map { String($0.about.prefix(80)) } ?? id.uuidString) })
            }),
            "mergesChosen": .int(Int64(night.merges.count)),
            // Each merge she proposed and what became of it, with her why.
            "merges": .array(mergeOutcomes), "mergesMalformed": .int(Int64(night.mergesMalformed)),
            "stancesProposed": .int(Int64(night.stanceChanges.count)),
            "stances": .array(stanceOutcomes),
        ]))
        return ready
    }

    /// The same ordered judgments as the committed night, on a value copy of
    /// the current owner. No save, receipt, epoch change or self settlement.
    public func previewCaresNight(_ night: CognitiveCareNight) -> JSONValue {
        if let why = carePreviewRefusal() {
            return .object(["outcome": .string("unavailable"), "why": .string(why)])
        }
        guard night.mindEpoch.map({ $0 == mindEpoch }) ?? true else {
            return .object(["outcome": .string("unavailable"), "why": .string("Her mind changed epoch during generation; these judgments cannot apply.")])
        }
        let original = cares, at = dependencies.now()
        var projected = original
        var changed: [UUID] = [], merges: [JSONValue] = [], stances: [JSONValue] = []
        var settled = 0, letGo = 0
        let answers = Self.applyCareAnswers(night, at: at, cares: &projected, changed: &changed, settled: &settled, letGo: &letGo)
        let stanceCount = Self.applyCareStances(night, original: original, at: at, cares: &projected, changed: &changed, outcomes: &stances)
        let mergeCount = Self.applyCareMerges(night, original: original, at: at, cares: &projected, changed: &changed, outcomes: &merges)
        return .object(["outcome": .string("evaluated_on_copy"), "answers": .array(answers),
            "stances": .array(stances), "merges": .array(merges), "mergesMalformed": .int(Int64(night.mergesMalformed)),
            "wouldMerge": .int(Int64(mergeCount)), "wouldChangeStances": .int(Int64(stanceCount)),
            "wouldSettle": .int(Int64(settled)), "wouldLetGo": .int(Int64(letGo))])
    }

    /// The life card was approved: the care becomes part of who she is. True
    /// when life depth is saved, including on a retry; false when absent or unsaved.
    public func deepenCareToLife(_ id: UUID, source: String) async -> Bool {
        await waitForMaintenanceTransition()
        guard configuration.enabled, var care = cares[id] else { return false }
        let now = dependencies.now()
        if care.depth == .life {
            return (try? await saveCares([id], at: now).get()) != nil
        }
        care.record(CognitiveCare.Moment(
            at: now, moved: 0, by: .her, felt: "deepened", note: "now part of my life",
            source: source, depthChange: .init(from: care.depth, to: .life)))
        care.depth = .life
        care.fadedAt = nil
        cares[id] = care
        markDirty(at: now)
        return (try? await saveCares([id], at: now).get()) != nil
    }

    // MARK: - Her story

    /// Her depth changes and what her nights settled or let go, newest first.
    func careStoryLines() -> [String] {
        var lines: [(at: Date, text: String)] = []
        for care in cares.values {
            for moment in care.story where moment.by == .her {
                let date = NativeTimestampFormat.calendarDay(moment.at)
                if let change = moment.depthChange {
                    lines.append((moment.at, "\(date): \(care.about) became part of my \(change.to.rawValue)"))
                } else if moment.source.hasPrefix("dream_diary/"), moment.felt == "settled" {
                    lines.append((moment.at, "\(date): settled: \(care.about), \(moment.note)"))
                } else if moment.source.hasPrefix("dream_diary/"), moment.felt == "let it go" {
                    lines.append((moment.at, "\(date): let go: \(care.about)"))
                }
            }
        }
        return lines.sorted { $0.at > $1.at }.prefix(Self.maximumCareStoryLines).map(\.text)
    }

    // MARK: - Reading a story

    static func careLastMoved(_ care: CognitiveCare) -> Date {
        max(care.story.last(where: { $0.moved != 0 })?.at ?? care.createdAt,
            care.folded?.movedDays?.last ?? care.createdAt)
    }

    /// The next depth its story has earned. Life is never earned here.
    static func careEarnedDepth(_ depth: CognitiveCare.Depth, days: Int, span: Int) -> CognitiveCare.Depth? {
        switch depth {
        case .now where days >= 2 && span >= 0: return .lately
        case .lately where days >= 4 && span >= 14: return .season
        default: return nil
        }
    }

    /// `settled: <key>: <how>` or `let go: <key>`; nil for anything else.
    static func careNightAnswer(_ line: String) -> (key: String, how: String?)? {
        func clean(_ text: Substring) -> String {
            text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]")))
        }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("let go:") {
            let key = clean(text.dropFirst(7)).lowercased()
            return key.isEmpty ? nil : (key, nil)
        }
        guard lower.hasPrefix("settled:") else { return nil }
        let parts = text.dropFirst(8).split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let key = clean(parts[0]).lowercased()
        let how = clean(parts[1])
        return key.isEmpty || how.isEmpty ? nil : (key, how)
    }

}
