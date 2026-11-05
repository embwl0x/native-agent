import CryptoKit
import Experiences
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityAccounting.swift` | Locked terminal evidence and learned-use accounting |
extension AbilityStore {
    /// Terminal accounting survives caller cancellation with its causal act. A run owns this once; projections do not manufacture run evidence.
    public func settleRun(id: String, version: String, receipt: JSONValue, input: JSONValue?, dependencySnapshot: JSONValue? = nil,
        turn: Turn?) async -> JSONValue {
        return await settle {
            var fields = receipt.objectValue ?? [:]
            do {
                try Self.withLock {
                    let recorded = try accounting(id: id, turn: turn) {
                        // Observed contracts are evidence of this invocation, not a replacement for the candidate's sealed inputs.
                        if let snapshot = dependencySnapshot?.objectValue, try readFile(id: id, slot: .current) != nil,
                           let file = try [Slot.current, .previous].compactMap({ try readFile(id: id, slot: $0) }).first(where: { identity(
                               $0) == version }) {
                            let selected = version + "@" + String(file.metadata["version"]?.integer ?? 1)
                            let evidence = try readState()[id]?.objectValue?["runs"]?.objectValue?["versions"]?.objectValue?[selected]?.objectValue
                            let before = evidence?["dependencySnapshot"]?.objectValue ?? [:]
                            let sealed = file.metadata["candidate"]?.objectValue?["dependencyShapes"]?.objectValue ?? [:]
                            let changed = snapshot.keys.sorted().filter { action in
                                guard snapshot[action] != .null else { return false }
                                let prior = before[action].flatMap { $0 == .null ? nil : $0 } ?? sealed[action]
                                // No observation is not evidence that a schema changed.
                                return prior != nil && prior != .null && prior != snapshot[action]
                            }
                            fields["dependencySnapshot"] = .object(snapshot)
                            if !changed.isEmpty {
                                fields["refreshed"] = .array(changed.map { .string("""
                                    refreshed: \($0) schema changed; this ability's statically readable calls still fit; computed arguments are checked \
                                    at the door
                                    """) })
                            }
                        }
                        let recorded = try recordRunEvidence(id: id, version: version, receipt: .object(fields), input: input, nativeSense: nil, turn: turn)
                        return (recorded.written, recorded)
                    }
                    if !recorded.written {
                        fields.removeValue(forKey: "refreshed"); fields.removeValue(forKey: "dependencySnapshot")
                    }
                    if let upgrade = recorded.upgrade {
                        fields["upgrade"] = .string(upgrade)
                    }
                }
            } catch {
                fields.removeValue(forKey: "refreshed"); fields.removeValue(forKey: "dependencySnapshot")
                fields["accounting_error"] = .string(error.localizedDescription)
            }
            return .object(fields)
        }
    }
    /// The stem alone records terminal evidence, including peer-steered runs; repeated world stops signal reason@step once per upgrade.
    @discardableResult
    public func recordRun(id: String, version: String, receipt: JSONValue, input: JSONValue? = nil, nativeSense: JSONValue? = nil,
        turn: Turn?) throws -> String? {
        try accounting(id: id, turn: turn) {
            let recorded = try recordRunEvidence(id: id, version: version, receipt: receipt, input: input, nativeSense: nativeSense, turn: turn)
            return (recorded.written, recorded.upgrade)
        }
    }
    /// Retain per-turn model rounds beside run totals so learned.use reflects actual cost.
    public func recordRounds(id: String, rounds: Int, turn: Turn?) throws {
        try accounting(id: id, turn: turn) {
            try Self.withLock {
                guard try readFile(id: id, slot: .current) != nil else { return (false, ()) }
                var state = try readState(), row = state[id]?.objectValue ?? [:], runs = row["runs"]?.objectValue ?? [:]
                runs["rounds"] = .array(Array(((runs["rounds"]?.arrayValue ?? []) + [.int(Int64(rounds))]).suffix(CapabilityLifecycle.inputLimit)))
                row["runs"] = .object(runs); state[id] = .object(row)
                try writeState(state)
                return (true, ())
            }
        }
    }
    func accounting<T>(id: String, turn: Turn?, _ write: () throws -> (written: Bool, value: T)) throws -> T {
        let recorded: (written: Bool, value: T)
        do { recorded = try write() }
        catch {
            // Ledger failure owes the file repair without replacing the act's own outcome or remedy.
            let failure = error as? ToolFailureError
                ?? repairFailure(source: root.appendingPathComponent("state.json"), detail: error.localizedDescription)
            RepairOwed.owe(dataRoot, id: "abilities-accounting:" + UUID().uuidString.lowercased(), kind: .run,
                           cause: turn?.act.map { [$0] } ?? [], operation: "abilities.accounting",
                           owner: failure.owner ?? root.appendingPathComponent("state.json").path,
                           words: failure.message, nextCall: failure.nextCall)
            throw failure
        }
        // Only a ledger write that happened proves the ledger works again.
        if recorded.written { RepairOwed.settle(dataRoot, operation: "abilities.accounting", evidence: .init(source: "abilities/state.json", id: id)) }
        return recorded.value
    }
    /// Not written when the run's part or version is gone.
    private func recordRunEvidence(id: String, version: String, receipt: JSONValue, input: JSONValue?, nativeSense: JSONValue?, turn: Turn?) throws -> (
        written: Bool,
        upgrade: String?) {
        try Self.withLock {
            // Native/bundled reads have a registry record but no executable file.
            guard let current = try readFile(id: id, slot: .current) ?? nativeSense.map({
                try File(id: id, kind: .sense, metadata: ["record": $0, "version": $0.objectValue?["version"] ?? .int(1)], body: "", pathExtension: "js")
            }) else { return (false, nil) }
            let previous = try readFile(id: id, slot: .previous)
            let currentIdentity = identity(current), previousIdentity = previous.flatMap(identity)
            let file: File
            if currentIdentity == version { file = current }
            else if previousIdentity == version, let previous { file = previous }
            else { return (false, nil) }
            var state = try readState(), row = state[id]?.objectValue ?? [:]
            var runs = row["runs"]?.objectValue ?? [:], versions = runs["versions"]?.objectValue ?? [:]
            let currentKey = (currentIdentity ?? current.bodyDigest) + "@" + String(current.metadata["version"]?.integer ?? 1)
            let previousKey = previous.map { (previousIdentity ?? $0.bodyDigest) + "@" + String($0.metadata["version"]?.integer ?? 1) }
            let selected = version + "@" + String(file.metadata["version"]?.integer ?? 1), now = Date()
            let at = NativeTimestampFormat.plainZulu(now)
            var evidence = versions[selected]?.objectValue ?? [:]
            let outcome = Self.runOutcome(receipt)
            let field = "state.\(id).runs.versions.\(selected)"
            // Existing evidence was checked by readState; only a new version starts at zero.
            let priorCount = evidence["count"] ?? .int(0)
            let count = try Self.increment(priorCount, field: field + ".count")
            evidence["count"] = .int(count)
            evidence["last"] = .object(["outcome": .string(outcome), "at": .string(at)])
            evidence[outcome] = .int(try Self.increment(evidence[outcome], field: field + "." + outcome))
            let fields = Self.redactedEvidence(receipt).objectValue ?? [:]
            if let snapshot = fields["dependencySnapshot"] { evidence["dependencySnapshot"] = snapshot }
            if file.kind == .sense, outcome == "ok", fields["read"] == .bool(true) {
                evidence["reads"] = .int(try Self.increment(evidence["reads"], field: field + ".reads"))
            }
            // Only the runner supplies input: fixtures, previews and admission refusals earn no competence.
            if let input {
                let calls = (fields["calls"]?.arrayValue ?? []).map {
                    JSONValue.object(($0.objectValue ?? [:]).filter { ["call", "line", "status", "effects"].contains($0.key) })
                }
                let scope: JSONValue = .object([
                    "input_digest": .string(SHA256.hash(data: try input.serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()),
                    "calls": .array(calls),
                ])
                let digest = SHA256.hash(data: try scope.serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()
                var operations = evidence["operations"]?.objectValue ?? [:], operation = operations[digest]?.objectValue ?? [:]
                operation["scope"] = scope
                operation["input_preview"] = .string(String(try Self.inputDescription(input).serialize(pretty: false).prefix(1024)))
                let result = outcome == "ok" ? "completed" : outcome
                operation[result] = .int(try Self.increment(operation[result], field: field + ".operations.\(digest)." + result))
                operation["at"] = .string(at); operation["last_run"] = .int(count)
                operations[digest] = .object(operation)
                // Retain recent scopes, not every distinct input. Version totals above never expire.
                if operations.count > CapabilityLifecycle.inputLimit {
                    operations = Dictionary(uniqueKeysWithValues: operations.sorted {
                        let lhs = $0.value.objectValue?["last_run"]?.integer ?? 0, rhs = $1.value.objectValue?["last_run"]?.integer ?? 0
                        let leftAt = $0.value.objectValue?["at"]?.stringValue ?? "", rightAt = $1.value.objectValue?["at"]?.stringValue ?? ""
                        return (lhs, leftAt, $0.key) < (rhs, rightAt, $1.key)
                    }.suffix(CapabilityLifecycle.inputLimit))
                }
                evidence["operations"] = .object(operations)
            }
            versions[selected] = .object(evidence)
            versions = versions.filter { $0.key == currentKey || $0.key == previousKey }
            runs["versions"] = .object(versions)
            // Repeated world stops at one place owe one upgrade signal.
            var upgrade: String?
            if input != nil {
                let back = fields["hand_back"]?.objectValue ?? [:]
                let place = back["step"]?.stringValue ?? (fields["stopped"]?.objectValue?["line"]?.integer).map { "line \($0)" } ?? ""
                let stops = Array(((runs["stops"]?.arrayValue ?? []) + [.string((fields["reason"]?.stringValue ?? outcome) + "@" + place)]).suffix(3))
                runs["stops"] = .array(stops)
                if let repeated = CapabilityLifecycle.repeatedStop(stops.compactMap(\.stringValue)), runs["noted"] != .string(repeated) {
                    runs["noted"] = .string(repeated); upgrade = repeated
                }
            }
            row["runs"] = .object(runs)
            row["useCount"] = .int(try Self.increment(row["useCount"], field: "state.\(id).useCount"))
            if file == current, file.kind == .sense, outcome == "ok", fields["read"] == .bool(true) {
                row["uses"] = .int(try Self.increment(row["uses"], field: "state.\(id).uses"))
            }
            row["lastUsedAt"] = file.kind == .sense ? .double(now.timeIntervalSinceReferenceDate) : .string(at)
            row["lastRunVersion"] = .string(version)
            row["lastRun"] = .object(fields.filter { ["status", "effects", "version", "calls", "error", "stopped", "refreshed"].contains($0.key) }
                .merging(evidence["last"]?.objectValue ?? [:]) { _, new in new })
            if outcome == "ok" { row["lastCleanVersion"] = .string(version) }
            state[id] = .object(row); try writeState(state)
            // Rehearsals have no input here and cannot earn or settle repair.
            if let input {
                let operation = "part." + id
                let run = "part-run:" + UUID().uuidString.lowercased()
                let remedy = fields["stopped"]?.objectValue?["remedy"] ?? fields["remedy"]
                // runOutcome classifies the cause; ledger advice does not exempt a source fault.
                if outcome == "error", !["repair", "person_decides", "correct_arguments", "inspect"].contains(remedy?.objectValue?["kind"]?.stringValue ?? "") {
                    let source = try path(id: id, slot: file == current ? .current : .previous, pathExtension: file.pathExtension).path
                    let fault = fields["error"]?.objectValue ?? fields["stopped"]?.objectValue ?? fields
                    let detail = fault["message"]?.stringValue ?? fault["detail"]?.stringValue ?? fault["reason"]?.stringValue ?? "Ability execution failed."
                    RepairOwed.owe(dataRoot, id: run, kind: .run,
                        cause: turn?.act.map { [$0] } ?? [], operation: operation,
                        owner: source + " > " + version,
                        words: TurnSecretRedactor.redactText(detail) + (file.kind == .turn
                            ? " Tell the person: NativeAgent's turn part failed; preserve its versions and reconcile prior effects."
                            : " Revise code/source in next_call through " + (file.kind == .sense ? "sense.make" : "ability.save")
                                + ", keep that version, reconcile any prior effects, then perform the failed operation again."),
                        lever: file.kind == .sense ? "sense.make" : file.kind == .part ? "ability.enable" : nil,
                        nextCall: try repairCall(file), tap: file.kind == .turn ? """
                            Report NativeAgent's turn-part execution defect at \(source), version \(version), to the person; preserve every retained version \
                            and prior effect.
                            """ : nil)
                } else if outcome == "ok" {
                    RepairOwed.settle(dataRoot, operation: operation, evidence: .init(source: "abilities/state.json", id: id + ":" + selected + ":" + String(
                        count)))
                }
            }
            return (true, upgrade)
        }
    }
    public static func runOutcome(_ receipt: JSONValue) -> String {
        let fields = receipt.objectValue ?? [:]
        if fields["status"] == .string("ok") { return "ok" }
        if fields["status"] == .string("timed_out") { return "cut" }
        let fault = fields["error"]?.objectValue ?? fields["stopped"]?.objectValue ?? fields
        let reason = fault["reason"]?.stringValue ?? fields["reason"]?.stringValue ?? ""
        if ["timeout", "resource_limit", "cancelled"].contains(reason) { return "cut" }
        if ["network", "http", "connection_failed", "connection_closed", "transport", "network_error", "http_error", "transport_error"].contains(
            reason) { return "network" }
        if ["javascript", "script_syntax", "script_name", "bad_output", "output_limit", "unreadable_return",
            "expect_failed", "expected_failure_not_seen", "expected_failure_succeeded", "validation_failed",
            "expect_fail_async", "expect_fail_nested", "expect_fail_one_call", "diverged", "script_error",
            "not_declared", "denied_in_skill", "unknown_action", "unknown_arg", "invalid_args", "missing_arg",
            "not_own_version"].contains(reason) { return "error" }
        let calls = fields["calls"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let failedCall = fault["n"]?.integer.flatMap { n in n > 0 && n <= Int64(calls.count) ? calls[Int(n) - 1] : nil }
            ?? (fields["error"] == nil ? calls.last : nil)
        if let call = failedCall, ![JSONValue.string("ok"), .string("preview"), .string("answered")].contains(call["status"] ?? .null) {
            return runOutcome(.object(call.merging(["calls": .array([])]) { _, new in new }))
        }
        if fault["origin"] == .string("javascript") || fields["status"] == .string("error") && reason.isEmpty { return "error" }
        return "refused"
    }
    /// Cache accounting only by its exact checked file identity.
    public func states() throws -> [String: JSONValue] {
        try Self.withLock { return try readState() }
    }
    public func saveState(id: String, fields: [String: JSONValue]) throws {
        try updateState(id: id) { $0 = fields }
    }
    /// Accounting mutations require the store lock.
    public func updateState(id: String, _ change: (inout [String: JSONValue]) -> Void) throws {
        try Self.withLock {
            var stats = try readState(), fields = stats[id]?.objectValue ?? [:]
            let before = stats[id]
            change(&fields); stats[id] = .object(fields)
            if stats[id] != before { try writeState(stats) }
        }
    }
}
