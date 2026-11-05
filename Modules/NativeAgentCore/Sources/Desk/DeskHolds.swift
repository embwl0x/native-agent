import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskHolds.swift` | Durable Desk hold ownership under the existing feed lock |
/// Flock-protected leases prevent two conversations working one item at once without mutating Desk history.
/// Stopped runs retain holds only while their resume step is open, bounded by runHoldLimit.
public struct DeskHold: Codable, Sendable, Equatable {
    public var by: String
    public var session: String
    public var at: Date
}
extension SwiftNativeDeskStore {
    public static let holdLease: TimeInterval = 30 * 60
    public static let runHoldLimit: TimeInterval = 7 * 24 * 3600
    var holdsPath: URL { deskDir.appendingPathComponent("holds.json") }
    /// A run hold requires an open resume step and retained checkpoint, bounded by runHoldLimit.
    /// holdLease allows time to file the step; a closed or absent step releases its checkpoint too.
    func isLive(_ hold: DeskHold, now: Date, state: DeskState) throws -> Bool {
        guard hold.by.hasPrefix("run ") else { return now.timeIntervalSince(hold.at) < Self.holdLease }
        let run = String(hold.by.dropFirst(4))
        let age = now.timeIntervalSince(hold.at)
        // A resumed run keeps its ID, so only steps queued after this hold can sustain it.
        let steps = state.items.filter { item in
            item.project == MyQueue.project && (DeskClock.parseISO(item.openedAt).map { $0 >= hold.at.addingTimeInterval(-0.001) } ?? false)
                && item.refs.contains { if case .step(let step) = $0.kind { MyQueue.skillRun(in: step.words) == run } else { false } }
        }
        let bound = steps.isEmpty ? age < Self.holdLease : steps.contains { !$0.status.isTerminal }
        guard try PartRunStore.exists(run, root: dataRoot), age < Self.runHoldLimit, bound else {
            try PartRunStore.discard(run, root: dataRoot)
            return false
        }
        return true
    }
    public func hold(_ ref: String, session: String, now: Date = Date()) async throws -> String? {
        try await hold([ref], session: session, now: now)
    }
    public func heldBy(_ ref: String, session: String, now: Date = Date()) async throws -> String? {
        try await editHolds(now: now) { holds, state in
            guard let item = Self.holdItem(ref, state), let held = holds[item.handle],
                  try isLive(held, now: now, state: state), held.session != session else { return nil }
            return held.by
        }
    }
    /// Acquire the group atomically so no partial acquisition strands work.
    public func hold(_ refs: [String], session: String, now: Date = Date()) async throws -> String? {
        try await editHolds(now: now) { holds, state in
            let items = refs.compactMap { Self.holdItem($0, state) }
            for item in items {
                if let held = holds[item.handle], try isLive(held, now: now, state: state), held.session != session {
                    return held.by
                }
            }
            for item in items {
                if let held = holds[item.handle], try isLive(held, now: now, state: state), held.by.hasPrefix("run ") { continue }
                holds[item.handle] = DeskHold(by: "conversation " + session, session: session, at: now)
            }
            return nil
        }
    }
    /// Keep each item’s existing conversation owner when stopped runs overlap.
    public func hold(_ refs: [String], run: String, session: String, now: Date = Date()) async throws -> [String] {
        try await editHolds(now: now) { holds, state in
            var names: [String] = []
            for ref in refs {
                guard let item = Self.holdItem(ref, state), !names.contains("desk." + item.alias) else { continue }
                if let held = holds[item.handle], try isLive(held, now: now, state: state), held.session != session { continue }
                holds[item.handle] = DeskHold(by: "run " + run, session: session, at: now)
                names.append("desk." + item.alias)
            }
            return names
        }
    }
    @discardableResult
    public func passHolds(run: String, to session: String, now: Date = Date()) async throws -> [String: DeskHold] {
        try await editHolds(now: now) { holds, _ in
            var passed: [String: DeskHold] = [:]
            for (handle, held) in holds where held.by == "run " + run {
                passed[handle] = held
                holds[handle] = DeskHold(by: "conversation " + session, session: session, at: now)
            }
            return passed
        }
    }
    /// Return only unchanged transferred holds so a failed resume cannot steal later ownership.
    public func returnHolds(_ passed: [String: DeskHold], from session: String, now: Date = Date()) async throws {
        try await editHolds(now: now) { holds, _ in
            for (handle, held) in passed where holds[handle]?.by == "conversation " + session { holds[handle] = held }
        }
    }
    static func holdItem(_ ref: String, _ state: DeskState) -> DeskItem? {
        var key = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("desk.") { key = String(key.dropFirst(5)) }
        return state.items.first { !$0.status.isTerminal && ($0.handle == key || $0.alias == key) }
    }
    /// Compare-and-set under the ops flock so expired holds cannot compete with a new owner.
    private func editHolds<T: Sendable>(now: Date, _ edit: @Sendable (inout [String: DeskHold], DeskState) throws -> T) async throws -> T {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            var holds: [String: DeskHold]
            do {
                let data = try Data(contentsOf: holdsPath)
                holds = try JSONDecoder().decode([String: DeskHold].self, from: data)
            } catch CocoaError.fileReadNoSuchFile {
                holds = [:]
            } catch {
                throw PersistenceCoreError.ioFailure(
                    "Desk holds at \(holdsPath.path) are unavailable: \(error.localizedDescription). Existing bytes were preserved.")
            }
            let before = holds
            let result = try edit(&holds, state)
            let open = Set(state.items.filter { !$0.status.isTerminal }.map(\.handle))
            holds = try holds.filter { try open.contains($0.key) && isLive($0.value, now: now, state: state) }
            if holds != before {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(holds), to: holdsPath)
            }
            return result
        }
    }
}
