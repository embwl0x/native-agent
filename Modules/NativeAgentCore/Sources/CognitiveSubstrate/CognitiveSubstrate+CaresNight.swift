import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+CaresNight.swift` | `CognitiveSubstrate` cares at night: the dream's material (moved today, still open), its settle and let-go lines, fade past the depth's horizon, deepen by distinct days moved, the cares ready for the life card and its approval, their story lines |

// The night deepens what keeps moving her and lets go of what never does after the
// dream commits. The only model in it is the dream she already has, which is
// shown what moved her today and what has stayed open, and may answer that an
// open care is settled or that she lets it go.

/// The night's cares: the block the dream is shown, the keys it names, and,
/// once the dream committed, the lines it answered.
public struct CognitiveCareNight: Sendable, Equatable {
    public var block: String
    /// The exact care revision shown at each key, including its open gap.
    public var keys: [String: CognitiveCare]
    public var answers: [String]
    /// `dream_diary/<date>.md`: the entry the pass follows, the source of its moments.
    public var source: String

    public init(block: String, keys: [String: CognitiveCare], answers: [String] = [], source: String = "") {
        self.block = block
        self.keys = keys
        self.answers = answers
        self.source = source
    }
}

extension CognitiveSubstrate {
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
    public func careNightMaterial() -> CognitiveCareNight? {
        guard configuration.enabled else { return nil }
        let now = dependencies.now()
        let live = cares.values.filter { $0.fadedAt == nil }
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
        return CognitiveCareNight(block: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n", keys: keys)
    }

    // MARK: - The night's pass

    /// After the dream committed: its settle and let-go lines, then every live
    /// care that is not life depth fades past its horizon or deepens by the
    /// distinct local days it moved her. Returns the season cares ready for
    /// life depth, which only the owner-review card grants.
    @discardableResult
    public func passCaresNight(_ night: CognitiveCareNight) async -> [CognitiveCare] {
        await waitForMaintenanceTransition()
        guard configuration.enabled else { return [] }
        let now = dependencies.now()
        let calendar = Calendar.current
        var changed: [UUID] = []
        var settled = 0, letGo = 0, faded = 0, deepened = 0
        for line in night.answers {
            guard let answer = Self.careNightAnswer(line), let shown = night.keys[answer.key],
                  let open = shown.open, var care = cares[shown.id], care.fadedAt == nil else { continue }
            // A revision is the captured value, not just a timestamp: two
            // changes can share a clock instant. A changed care keeps the
            // dream as history without closing a question it never saw.
            let current = care == shown
            if current { care.open = nil }
            care.record(CognitiveCare.Moment(
                at: now, moved: 0, by: .her, felt: current ? (answer.how == nil ? "let it go" : "settled") : "dreamed",
                note: current ? (answer.how ?? "let go: \(open)")
                    : "dream about \(open): \(answer.how ?? "let go")", source: night.source))
            cares[care.id] = care
            changed.append(care.id)
            if current {
                if answer.how == nil { letGo += 1 } else { settled += 1 }
            }
        }
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
        if !changed.isEmpty {
            markDirty(at: now)
            _ = await saveCares(Array(Set(changed)), at: now)
        }
        await recordReceipt(kind: "cares.night", payload: .object([
            "source": .string(night.source),
            "settled": .int(Int64(settled)), "letGo": .int(Int64(letGo)),
            "faded": .int(Int64(faded)), "deepened": .int(Int64(deepened)),
            "readyForLife": .array(ready.map { .string($0.id.uuidString) }),
        ]))
        return ready
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
