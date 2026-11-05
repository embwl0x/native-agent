import Foundation
import Desk
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CarriedHabits.swift` | `CarriedHabits`: bounded trials; daily offers never bind |
// Retain at most eight handling trials and measured costs; the shared Expectation law permits only one offer per day.

/// The agent's handling, as lived in carried wake turns. This is evidence for a choice in the carried line, never another runner or an automatic binding.
package actor CarriedHabits {
    package static let shared = CarriedHabits()
    private struct Trial: Codable {
        var turn: String
        var handling: [String]
        var modelCalls: Int
        var at: Date
    }
    private struct Step: Codable {
        var trials: [Trial] = []
        var offered: Date?
    }
    private struct Ledger: Codable { var steps: [String: Step] = [:] }
    private static func path(_ root: URL) -> URL { root.appendingPathComponent("mind/habits.json") }
    private static func read(_ url: URL) throws -> Ledger {
        do { return try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Ledger() }
    }
    private static func write(_ ledger: Ledger, to url: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(ledger), to: url)
    }

    package func record(handle: String, turn: String, handling: [String], modelCalls: Int, at: Date, dataRoot: URL) async {
        let url = Self.path(dataRoot)
        do {
            try await SwiftNativePersistenceCore.withFileLock(url) {
                var ledger = try Self.read(url), step = ledger.steps[handle] ?? Step()
                guard !step.trials.contains(where: { $0.turn == turn }) else { return }
                // An overlong handling is unknown, never a truncated sequence that could earn standing as though it were the whole turn.
                step.trials.append(Trial(turn: turn, handling: handling.count <= 64 ? handling : [], modelCalls: modelCalls, at: at))
                step.trials = Array(step.trials.suffix(8))
                ledger.steps[handle] = step
                if ledger.steps.count > 256 {
                    let oldest = ledger.steps.keys.sorted {
                        (ledger.steps[$0]?.trials.last?.at ?? .distantPast) < (ledger.steps[$1]?.trials.last?.at ?? .distantPast)
                    }
                    for id in oldest.prefix(ledger.steps.count - 256) { ledger.steps[id] = nil }
                }
                try Self.write(ledger, to: url)
            }
        } catch { nativeLog("carried handling not kept for %@: %@", handle, error.localizedDescription) }
    }

    package func suggestion(for item: DeskItem, dataRoot: URL, at: Date) async -> String? {
        guard let step = item.step, step.action == nil else { return nil }
        let url = Self.path(dataRoot)
        do {
            return try await SwiftNativePersistenceCore.withFileLock(url) {
                var ledger = try Self.read(url)
                guard var record = ledger.steps[item.handle],
                      record.offered.map({ Calendar.current.isDate($0, inSameDayAs: at) }) != true else { return nil }
                let groups = Dictionary(grouping: record.trials.filter { !$0.handling.isEmpty }, by: \.handling)
                guard let hits = groups.values.sorted(by: {
                    $0.count == $1.count ? ($0.last?.at ?? .distantPast) > ($1.last?.at ?? .distantPast) : $0.count > $1.count
                }).first, let handling = hits.first?.handling else { return nil }
                let cHit = Double(hits.reduce(0) { $0 + $1.modelCalls }) / Double(hits.count)
                // Include wake cost with fruitless runs so a missed habit has an honest cost.
                let cMiss = 1 + Double(record.trials.reduce(0) { $0 + $1.modelCalls }) / Double(record.trials.count)
                guard Expectation.stands(hits: hits.count, tries: record.trials.count, cHit: cHit, cMiss: cMiss, among: nil).stands else { return nil }
                record.offered = at; ledger.steps[item.handle] = record
                try Self.write(ledger, to: url)
                let authored = handling.first.flatMap { $0.hasPrefix("authored.") ? $0 : nil }
                let keep = authored == nil ? " Keep that handling as an ability first." : ""
                let id = try JSONValue.string("desk." + item.alias).serialize(pretty: false)
                let action = try JSONValue.string(authored ?? "<authored id>").serialize(pretty: false)
                return "You have handled it the same way \(hits.count) times (\(handling.joined(separator: ", ")))." + keep
                    + " To let it run on its own and wake you only when it needs you: queue.update {id:\(id), action:{action:\(action)}}."
            }
        } catch { nativeLog("carried habit suggestion unavailable for %@: %@", item.handle, error.localizedDescription); return nil }
    }
}
