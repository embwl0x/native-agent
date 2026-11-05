import Foundation
import PersistenceCore
import NativeAgentCore

// Blueprint: | `CognitiveSubstrate+CaresSettlement.swift` | Shared care answers, stance and complete-link merge transformations |

public struct CognitiveCareMerge: Sendable, Equatable {
    public var keep: UUID?
    public var intoIt: [UUID]
    public var why: String

    public init(keep: UUID?, intoIt: [UUID], why: String) {
        self.keep = keep; self.intoIt = intoIt; self.why = why
    }
}

public struct CognitiveCareStanceChange: Sendable, Equatable {
    public var care: UUID
    /// One-based indices into the captured care's pressure entries.
    public var pressure: [Int]
    public var stance: CognitiveCare.Stance

    public init(care: UUID, pressure: [Int], stance: CognitiveCare.Stance) {
        self.care = care; self.pressure = pressure; self.stance = stance
    }
}

extension CognitiveSubstrate {
    /// Both directions must stand out against the whole live inventory, with self excluded. Complete-link clusters cannot join unrelated endpoints through a
    /// chain of intermediate cares. Stable order, six by six at most.
    static func careMergeClusters(among inventory: [CognitiveCare], vectors: [UUID: [Float]]) -> [[CognitiveCare]] {
        guard inventory.allSatisfy({ vectors[$0.id] != nil }) else { return [] }
        let ordered = inventory.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
        var standing: [UUID: [UUID: Double]] = [:]
        for care in ordered {
            let others = ordered.filter { $0.id != care.id }
            let scores = Dictionary(uniqueKeysWithValues: others.map {
                ($0.id, VectorMath.cosine(vectors[care.id], vectors[$0.id]))
            })
            standing[care.id] = Dictionary(uniqueKeysWithValues: Self.careMeaningStanding(scores, among: others)
                .filter { Set($0.care.with) == Set(care.with) }.map { ($0.care.id, $0.deviation) })
        }
        func strength(_ a: Int, _ b: Int) -> Double? {
            guard let forward = standing[ordered[a].id]?[ordered[b].id],
                  let backward = standing[ordered[b].id]?[ordered[a].id] else { return nil }
            return min(forward, backward)
        }
        var pairs: [(left: Int, right: Int, strength: Double)] = []
        for left in ordered.indices {
            for right in ordered.indices where right > left {
                if let value = strength(left, right) { pairs.append((left, right, value)) }
            }
        }
        pairs.sort {
            if $0.strength != $1.strength { return $0.strength > $1.strength }
            return $0.left != $1.left ? $0.left < $1.left : $0.right < $1.right
        }
        var used = Set<Int>()
        var clusters: [[CognitiveCare]] = []
        for pair in pairs where !used.contains(pair.left) && !used.contains(pair.right) {
            var cluster = [pair.left, pair.right]
            while cluster.count < 6 {
                let candidates = ordered.indices.compactMap { index -> (index: Int, strength: Double)? in
                    guard !used.contains(index), !cluster.contains(index) else { return nil }
                    let values = cluster.compactMap { strength(index, $0) }
                    guard values.count == cluster.count, let weakest = values.min() else { return nil }
                    return (index, weakest)
                }.sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.index < $1.index }
                guard let next = candidates.first else { break }
                cluster.append(next.index)
            }
            clusters.append(cluster.map { ordered[$0] })
            used.formUnion(cluster)
            if clusters.count == 6 { break }
        }
        return clusters
    }

    static func careStancePressure(_ care: CognitiveCare) -> [CognitiveCare.Moment] {
        let lastChange = care.story.lastIndex { $0.felt == "changed my mind" }
        return care.story.enumerated().compactMap { index, entry in
            guard entry.stancePressure != nil, lastChange.map({ index > $0 }) ?? true else { return nil }
            return entry
        }
    }

    static func careStanceHasDays(_ entries: [CognitiveCare.Moment], depth: CognitiveCare.Depth) -> Bool {
        let calendar = Calendar.current
        let days = Set(entries.map { calendar.startOfDay(for: $0.at) }).sorted()
        guard days.count >= (depth == .life ? 3 : 2) else { return false }
        guard depth == .life else { return true }
        return (calendar.dateComponents([.day], from: days[0], to: days[days.count - 1]).day ?? 0) >= 14
    }

    static func applyCareAnswers(_ night: CognitiveCareNight, at now: Date, cares: inout [UUID: CognitiveCare],
                                 changed: inout [UUID], settled: inout Int, letGo: inout Int) -> [JSONValue] {
        night.answers.map { line in
            guard let answer = Self.careNightAnswer(line), let shown = night.keys[answer.key],
                  let open = shown.open, var care = cares[shown.id], care.fadedAt == nil else {
                return .object(["answer": .string(line), "outcome": .string("skipped: invalid answer, missing open care or faded care")])
            }
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
            return .object(["answer": .string(line), "care": .string(care.id.uuidString),
                            "outcome": .string(current ? (answer.how == nil ? "let it go" : "settled") : "dreamed: care changed; question stays open")])
        }
    }

    static func applyCareStances(_ night: CognitiveCareNight, original: [UUID: CognitiveCare], at now: Date,
                                cares: inout [UUID: CognitiveCare], changed: inout [UUID], outcomes: inout [JSONValue]) -> Int {
        let shown = Dictionary(night.keys.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var count = 0
        var decided = Set<UUID>()
        for answer in night.stanceChanges {
            func outcome(_ result: String) {
                outcomes.append(.object(["care": .string(answer.care.uuidString),
                    "pressure": .array(answer.pressure.map { .int(Int64($0)) }),
                    "stance": .object(["text": .string(answer.stance.text), "because": .string(answer.stance.because),
                                       "unless": .string(answer.stance.wouldChangeMind)]), "outcome": .string(result)]))
            }
            guard !decided.contains(answer.care), let captured = shown[answer.care],
                  original[answer.care] == captured, var care = cares[answer.care],
                  care.fadedAt == nil, let old = care.stance, old != answer.stance else {
                outcome("skipped: repeated, changed, missing, faded or unchanged stance"); continue
            }
            let evidence = Self.careStancePressure(captured)
            let indices = Set(answer.pressure)
            guard !indices.isEmpty, indices.allSatisfy({ $0 > 0 && $0 <= evidence.count }),
                  Self.careStanceHasDays(indices.sorted().map { evidence[$0 - 1] }, depth: care.depth) else {
                outcome("skipped: invalid pressure or insufficient distinct days"); continue
            }
            outcome("changed stance")
            care.record(.init(at: now, moved: 0, by: .her, felt: "changed my mind",
                              note: "used to think: \(old.text)", source: night.source))
            care.stance = answer.stance
            cares[care.id] = care
            changed.append(care.id)
            decided.insert(care.id)
            count += 1
        }
        return count
    }

    static func applyCareMerges(_ night: CognitiveCareNight, original: [UUID: CognitiveCare], at now: Date,
                               cares: inout [UUID: CognitiveCare], changed: inout [UUID], outcomes: inout [JSONValue]) -> Int {
        let shown = Dictionary(night.keys.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var consumed = Set<UUID>()
        var count = 0
        for answer in night.merges {
            let ids = Set(answer.intoIt + [answer.keep].compactMap { $0 })
            func outcome(_ result: String, kept: UUID? = nil) {
                let named = ids.compactMap { (shown[$0] ?? cares[$0]).map { String($0.about.prefix(60)) } }.sorted()
                outcomes.append(.object(["cares": .array(named.map { .string($0) }),
                                         "ids": .array(ids.map(\.uuidString).sorted().map(JSONValue.string)),
                                         "into_it": .array(answer.intoIt.map { .string($0.uuidString) }),
                                         "keep": answer.keep.map { .string($0.uuidString) } ?? .null,
                                         "resolvedKeep": kept.map { .string($0.uuidString) } ?? .null,
                                         "outcome": .string(result),
                                         "why": .string(answer.why)]))
            }
            guard (2...6).contains(ids.count) else { outcome("skipped: \(ids.count) cares, a merge takes 2 to 6"); continue }
            guard consumed.isDisjoint(with: ids) else { outcome("skipped: overlaps an earlier merge tonight"); continue }
            guard night.clusters.contains(where: { ids.isSubset(of: Set($0)) }) else { outcome("skipped: not all in one shown cluster"); continue }
            guard ids.allSatisfy({ id in shown[id] != nil && original[id] == shown[id] && cares[id]?.fadedAt == nil }) else {
                outcome("skipped: a care changed, faded or was not shown"); continue
            }
            let members = ids.compactMap { cares[$0] }.sorted {
                $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
            }
            guard let keep = answer.keep ?? members.first?.id, var kept = cares[keep],
                  members.allSatisfy({ Set($0.with) == Set(kept.with) }) else { outcome(
                      "skipped: the kept care is missing or held with different people"); continue }
            outcome("merged into \(String(kept.about.prefix(60)))", kept: keep)
            if kept.open == nil {
                kept.open = members.filter { $0.open != nil }.max {
                    let left = original[$0.id]?.updatedAt ?? $0.updatedAt
                    let right = original[$1.id]?.updatedAt ?? $1.updatedAt
                    return left != right ? left < right : $0.id.uuidString < $1.id.uuidString
                }?.open
            }
            // Record before union so its normal bounds cannot fold the history just collected from the other cares in this same night.
            kept.record(.init(at: now, moved: 0, by: .her, felt: "came together", note: answer.why, source: night.source))
            for var other in members where other.id != keep {
                kept.absorbHistory(of: other)
                other.record(.init(at: now, moved: 0, by: .her, felt: "came together",
                                   note: "became part of \(kept.about)", source: night.source))
                other.fadedAt = now
                other.mergedInto = keep
                cares[other.id] = other
                changed.append(other.id)
                count += 1
            }
            cares[keep] = kept
            changed.append(keep)
            consumed.formUnion(ids)
        }
        return count
    }
}
