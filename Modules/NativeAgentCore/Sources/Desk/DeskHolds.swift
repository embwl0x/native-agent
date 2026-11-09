import NativeAgentShared
import Foundation
import PersistenceCore
import NativeAgentCore
// Blueprint: | `DeskHolds.swift` | Stopped-run reservations backed by retained checkpoints under the Desk feed lock |

public struct DeskHold: Codable, Sendable, Equatable {
    public var by: String
    public var session: String?
    public var at: Date
}

/// Only a stopped run with a retained checkpoint can refuse another caller.
public struct DeskHoldConflict: Sendable {
    public let holder: DeskHold

    public func refusal(_ subject: String) -> JSONValue {
        let since = NativeTimestampFormat.fractionalUTCOffset(holder.at)
        let next: JSONValue = .object(["tool": .string("app"), "input": .object([
            "action": .string("ability.resume"), "preview": .bool(true),
            "args": .object(["run_id": .string(String(holder.by.dropFirst(4)))])])])
        var fields: [String: JSONValue] = [
            "status": .string("refused"), "reason": .string("held_by"), "effects": .string("none"),
            "held_by": .string(holder.by), "held_since": .string(since), "held_until": .string("resumed or released"),
            "detail": .string("\(subject) is held by \(holder.by), since \(since), until resumed or released. This call changed no Desk work."),
            "remedy": .object(["kind": .string("inspect"), "owner": .string(holder.by), "next_call": next,
                "instruction": .string("Read the stopped run's question and resume it with your answer, or release its queued step.")]),
        ]
        if let session = holder.session { fields["holder_session"] = .string(session) }
        return .object(fields)
    }
}

extension SwiftNativeDeskStore {
    var holdsPath: URL { deskDir.appendingPathComponent("holds.json") }

    private func retainedRun(_ hold: DeskHold) throws -> Bool {
        try hold.by.hasPrefix("run ") && PartRunStore.exists(String(hold.by.dropFirst(4)), root: dataRoot)
    }

    @concurrent public func runHold(_ ref: String) async throws -> DeskHoldConflict? {
        try await runHold([ref])
    }

    /// Check reservations without acquiring ownership for the caller.
    @concurrent public func runHold(_ refs: [String]) async throws -> DeskHoldConflict? {
        try await editHolds { holds, state in
            for ref in refs {
                if let item = Self.holdItem(ref, state), let held = holds[item.handle] { return DeskHoldConflict(holder: held) }
            }
            return nil
        }
    }

    /// A stopped run reserves its journaled items through its retained checkpoint.
    @concurrent public func hold(_ refs: [String], run: String, session: String?) async throws -> [String] {
        try await editHolds { holds, state in
            var names: [String] = []
            for ref in refs {
                guard let item = Self.holdItem(ref, state), !names.contains("desk." + item.alias) else { continue }
                if let held = holds[item.handle], held.by != "run " + run { continue }
                holds[item.handle] = DeskHold(by: "run " + run, session: session, at: Date())
                names.append("desk." + item.alias)
            }
            return names
        }
    }

    /// Taking up a stopped run releases its reservations, without consuming its checkpoint.
    @concurrent public func passHolds(run: String) async throws -> [String: DeskHold] {
        try await editHolds { holds, _ in
            let passed = holds.filter { $0.value.by == "run " + run }
            for handle in passed.keys { holds.removeValue(forKey: handle) }
            return passed
        }
    }

    /// A refused resume restores its reservations without stealing another stopped run's items.
    @concurrent public func returnHolds(_ passed: [String: DeskHold]) async throws {
        guard !passed.isEmpty else { return }
        try await editHolds { holds, state in
            let open = Set(state.items.filter { !$0.status.isTerminal }.map(\.handle))
            for (handle, held) in passed {
                guard open.contains(handle), holds[handle] == nil, try retainedRun(held) else { continue }
                holds[handle] = held
            }
        }
    }

    static func holdItem(_ ref: String, _ state: DeskState) -> DeskItem? {
        var key = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("desk.") { key = String(key.dropFirst(5)) }
        return state.items.first { !$0.status.isTerminal && ($0.handle == key || $0.alias == key) }
    }

    /// The sole editor drops non-run markers and reservations without an open item or retained checkpoint.
    @concurrent private func editHolds<T: Sendable>(_ edit: @Sendable (inout [String: DeskHold], DeskState) throws -> T) async throws -> T {
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
            let open = Set(state.items.filter { !$0.status.isTerminal }.map(\.handle))
            holds = try holds.filter { try open.contains($0.key) && retainedRun($0.value) }
            let result = try edit(&holds, state)
            if holds != before {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(holds), to: holdsPath)
            }
            return result
        }
    }
}
