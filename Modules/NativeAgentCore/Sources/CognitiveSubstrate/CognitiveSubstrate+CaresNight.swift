import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+CaresNight.swift` | `CognitiveSubstrate` cares at night: the dream's material (moved today, still open), its settle and let-go lines, fade past the depth's horizon, deepen by distinct days moved, the cares ready for the life card and its approval, their story lines |

// CARES AT NIGHT (personality lane 3, 2026-10-25). Law 4: the night deepens
// what keeps moving her and lets go of what never does. One CPU pass after the
// dream commits. The only model in it is the dream she already has, which is
// shown what moved her today and what has stayed open, and may answer that an
// open care is settled or that she lets it go.

/// The night's cares: the block the dream is shown, the keys it names, and,
/// once the dream committed, the lines it answered.
public struct CognitiveCareNight: Sendable, Equatable {
    public var block: String
    public var keys: [String: UUID]
    public var answers: [String]
    /// `dream_diary/<date>.md`: the entry the pass follows, the source of its moments.
    public var source: String

    public init(block: String, keys: [String: UUID], answers: [String] = [], source: String = "") {
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
        let moved = live.compactMap { care -> (care: CognitiveCare, today: [CognitiveCare.Moment])? in
            let today = care.story.filter { $0.moved != 0 && now.timeIntervalSince($0.at) < 86_400 }
            return today.isEmpty ? nil : (care, today)
        }
        .sorted { $0.today.reduce(0) { $0 + abs($1.moved) } > $1.today.reduce(0) { $0 + abs($1.moved) } }
        .prefix(Self.dreamMovedCares)
        let movedIDs = Set(moved.map(\.care.id))
        let stuck = live.filter {
            $0.open != nil && $0.depth != .now && !movedIDs.contains($0.id)
                && now.timeIntervalSince(Self.careLastMoved($0)) >= Self.careStuckAfter
        }
        .sorted { Self.careLastMoved($0) < Self.careLastMoved($1) }
        .prefix(Self.dreamOpenCares)
        var keys: [String: UUID] = [:]
        func key(_ care: CognitiveCare) -> String {
            let key = "c\(keys.count + 1)"
            keys[key] = care.id
            return key
        }
        var lines: [String] = []
        if !moved.isEmpty {
            lines.append("--- WHAT MOVED YOU TODAY (your cares; dream about what actually mattered) ---")
            for (care, today) in moved {
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
            guard let answer = Self.careNightAnswer(line), let id = night.keys[answer.key],
                  var care = cares[id], care.fadedAt == nil, let open = care.open else { continue }
            care.open = nil
            care.record(CognitiveCare.Moment(
                at: now, moved: 0, by: .her, felt: answer.how == nil ? "let it go" : "settled",
                note: answer.how ?? "let go: \(open)", source: night.source))
            cares[id] = care
            changed.append(id)
            if answer.how == nil { letGo += 1 } else { settled += 1 }
        }
        var ready: [CognitiveCare] = []
        for var care in cares.values where care.fadedAt == nil && care.depth != .life && care.origin != .seed {
            if let horizon = Self.careFadeHorizon(care.depth), now.timeIntervalSince(Self.careLastMoved(care)) > horizon {
                care.fadedAt = now
                cares[care.id] = care
                changed.append(care.id)
                faded += 1
                continue
            }
            var deeper = false
            while let next = Self.careEarnedDepth(care, calendar: calendar) {
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
            if care.depth == .season, Self.careMovedSpan(care, calendar: calendar, days: 8, span: 60) {
                ready.append(care)
            }
        }
        if !changed.isEmpty {
            markDirty(at: now)
            for id in Set(changed) { await persistCare(id, at: now) }
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
    /// when it is at life depth now; false when no such care is left.
    public func deepenCareToLife(_ id: UUID, source: String) async -> Bool {
        await waitForMaintenanceTransition()
        guard configuration.enabled, var care = cares[id] else { return false }
        guard care.depth != .life else { return true }
        let now = dependencies.now()
        care.record(CognitiveCare.Moment(
            at: now, moved: 0, by: .her, felt: "deepened", note: "now part of my life",
            source: source, depthChange: .init(from: care.depth, to: .life)))
        care.depth = .life
        care.fadedAt = nil
        cares[id] = care
        markDirty(at: now)
        await persistCare(id, at: now)
        return true
    }

    // MARK: - Her story

    /// Her depth changes and what her nights settled or let go, newest first.
    func careStoryLines() -> [String] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        var lines: [(at: Date, text: String)] = []
        for care in cares.values {
            for moment in care.story where moment.by == .her {
                let date = day.string(from: moment.at)
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
        care.story.last(where: { $0.moved != 0 })?.at ?? care.createdAt
    }

    /// Moved on at least `days` distinct local days, spanning at least `span` days.
    static func careMovedSpan(_ care: CognitiveCare, calendar: Calendar, days: Int, span: Int) -> Bool {
        let moved = Set(care.story.filter { $0.moved != 0 }.map { calendar.startOfDay(for: $0.at) }).sorted()
        guard moved.count >= days, let first = moved.first, let last = moved.last else { return false }
        return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) >= span
    }

    /// The next depth its story has earned. Life is never earned here.
    static func careEarnedDepth(_ care: CognitiveCare, calendar: Calendar) -> CognitiveCare.Depth? {
        switch care.depth {
        case .now where careMovedSpan(care, calendar: calendar, days: 2, span: 0): return .lately
        case .lately where careMovedSpan(care, calendar: calendar, days: 4, span: 14): return .season
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

    func persistCare(_ id: UUID, at now: Date) async {
        guard let care = cares[id] else { return }
        do {
            await persistArtifact(kind: "care", id: id, status: care.fadedAt == nil ? "live" : "faded",
                                  score: min(1, abs(care.charge(at: now))), payload: try Self.careJSON(care))
        } catch {
            nativeLog("cares: care %@ was not saved, it could not be encoded: %@", id.uuidString,
                      String(describing: error))
        }
    }
}
