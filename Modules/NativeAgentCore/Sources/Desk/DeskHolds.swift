import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskHolds.swift` | Durable Desk hold ownership under the existing feed lock |
/// Who is working a Desk item, so two of her conversations never work one
/// item at once. Kept beside the feed in holds.json and changed
/// only under the ops flock, compare-and-set; not Desk state (no op, no
/// updatedAt, no notify). A conversation holds an item it works until
/// `holdLease` after its last touch. A stopped skill run holds what it touched
/// while its MY QUEUE resume step is open (and its checkpoint kept), at most
/// `runHoldLimit`; the conversation it ran in still works them.
public struct DeskHold: Codable, Sendable, Equatable {
    /// "conversation <session id>" or "run <run id>".
    public var by: String
    /// The conversation working it, or the one whose stopped run holds it.
    public var session: String
    public var at: Date
}
extension SwiftNativeDeskStore {
    public static let holdLease: TimeInterval = 30 * 60
    /// The backstop: no stopped run holds anything longer than this.
    public static let runHoldLimit: TimeInterval = 7 * 24 * 3600
    var holdsPath: URL { deskDir.appendingPathComponent("holds.json") }
    /// Whether a hold still binds. A run's binds while a resume step queued
    /// since the hold is open in MY QUEUE (or, before any is queued, for
    /// `holdLease` while the turn that stopped it queues one), its checkpoint
    /// kept and it younger than `runHoldLimit`. One whose step was closed or
    /// never came is void, and its checkpoint goes with it, here: no closing
    /// path has to remember the hold.
    func isLive(_ hold: DeskHold, now: Date, state: DeskState) -> Bool {
        guard hold.by.hasPrefix("run ") else { return now.timeIntervalSince(hold.at) < Self.holdLease }
        let run = String(hold.by.dropFirst(4))
        let age = now.timeIntervalSince(hold.at)
        // Only its steps queued since this hold count: a run resumed and stopped
        // again keeps its id, and the step its first stop queued is closed.
        let steps = state.items.filter { item in
            item.project == MyQueue.project && (DeskClock.parseISO(item.openedAt).map { $0 >= hold.at.addingTimeInterval(-0.001) } ?? false)
                && item.refs.contains { if case .step(let step) = $0.kind { MyQueue.skillRun(in: step.words) == run } else { false } }
        }
        let bound = steps.isEmpty ? age < Self.holdLease : steps.contains { !$0.status.isTerminal }
        guard PartRunStore.exists(run, root: dataRoot), age < Self.runHoldLimit, bound else {
            PartRunStore.discard(run, root: dataRoot)
            return false
        }
        return true
    }
    /// Conversation `session` takes `ref` (desk.N, N or a handle) to work it.
    /// Who holds it instead, or nil when it is free, this conversation's, or
    /// its own stopped run's. An item that is not open holds nothing.
    public func hold(_ ref: String, session: String, now: Date = Date()) async throws -> String? {
        try await hold([ref], session: session, now: now)
    }
    /// Read another conversation's hold without reserving this item's work.
    public func heldBy(_ ref: String, session: String, now: Date = Date()) async throws -> String? {
        try await editHolds(now: now) { holds, state in
            guard let item = Self.holdItem(ref, state), let held = holds[item.handle],
                  isLive(held, now: now, state: state), held.session != session else { return nil }
            return held.by
        }
    }
    /// Acquire the entire group only when none is held by another conversation.
    public func hold(_ refs: [String], session: String, now: Date = Date()) async throws -> String? {
        try await editHolds(now: now) { holds, state in
            let items = refs.compactMap { Self.holdItem($0, state) }
            for item in items {
                if let held = holds[item.handle], isLive(held, now: now, state: state), held.session != session {
                    return held.by
                }
            }
            for item in items {
                if let held = holds[item.handle], isLive(held, now: now, state: state), held.by.hasPrefix("run ") { continue }
                holds[item.handle] = DeskHold(by: "conversation " + session, session: session, at: now)
            }
            return nil
        }
    }
    /// A stopped run holds the items it touched, for the conversation it ran
    /// in: the ones it holds, by name. One another conversation holds stays theirs.
    public func hold(_ refs: [String], run: String, session: String, now: Date = Date()) async throws -> [String] {
        try await editHolds(now: now) { holds, state in
            var names: [String] = []
            for ref in refs {
                guard let item = Self.holdItem(ref, state), !names.contains("desk." + item.alias) else { continue }
                if let held = holds[item.handle], isLive(held, now: now, state: state), held.session != session { continue }
                holds[item.handle] = DeskHold(by: "run " + run, session: session, at: now)
                names.append("desk." + item.alias)
            }
            return names
        }
    }
    /// A resumed run's holds pass to the conversation resuming it.
    /// The holds passed, as the run held them.
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
    /// Holds a resume passed and could not use go back to their run, each one
    /// the conversation still holds as it was passed.
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
    /// One compare-and-set under the ops flock; what no longer binds (lapsed,
    /// or on an item closed or gone) is dropped as it is written.
    private func editHolds<T: Sendable>(now: Date, _ edit: @Sendable (inout [String: DeskHold], DeskState) -> T) async throws -> T {
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
                throw PersistenceCoreError.ioFailure("Desk holds at \(holdsPath.path) are unavailable: \(error.localizedDescription). Existing bytes were preserved.")
            }
            let before = holds
            let result = edit(&holds, state)
            let open = Set(state.items.filter { !$0.status.isTerminal }.map(\.handle))
            holds = holds.filter { open.contains($0.key) && isLive($0.value, now: now, state: state) }
            if holds != before {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(holds), to: holdsPath)
            }
            return result
        }
    }
}
