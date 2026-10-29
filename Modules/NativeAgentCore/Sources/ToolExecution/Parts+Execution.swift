import AuthoredCapabilities
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import Senses
import TrustCenter
import ToolRegistry
import CryptoKit
import PersonaEngine
// Blueprint: | `Parts+Execution.swift` | Parts pinned typed calls and pure faces, held runs and settlement; exact admission and dependency checks on every run |

extension Parts {
    static func revisionFailure(_ code: String, _ detail: String, id: String, version: String? = nil) -> SenseFailure {
        SenseFailure(code: code, message: detail, remedy: Repair.remedy(
            owner: "ability \(id)" + (version.map { " version \($0)" } ?? ""), nextCall: readCall(id), tap: nil,
            instruction: "Read \(id) and its retained versions; revise the rejected code or declaration with ability.save, then keep the reviewed version with ability.enable. Do not replay observed effects."))
    }

    /// A native caller may narrow a part's admitted reach for this operation. This never grants an action or capability the selected part
    /// lacks.
    public struct CallReach: Sendable {
        public let actions: Set<String>
        public let capabilities: Set<String>
        public init(actions: Set<String>, capabilities: Set<String>) {
            self.actions = actions; self.capabilities = capabilities
        }
    }

    /// Bounded immutable JSON in; a version-pinned decision out. Native callers supply their originating gated host through
    /// OwnedProgramInvocation. The domain commits a successful value in its own transaction after this returns, never while holding that
    /// transaction's lock across JavaScript.
    public func call<Value: Codable & Sendable>(id: String, input: JSONValue, preview: Bool = false,
        within reach: CallReach? = nil, as type: Value.Type = Value.self) async -> PartCallResult<Value> {
        await callValue(id: id, input: input, projection: false, preview: preview, reach: reach, as: type)
    }

    /// Called by source owners, never by a view's render. Faces have no host effects or notebook access; all their sources arrive in frozen
    /// input.
    public func face(id: String, input: JSONValue, version: String) async -> PartCallResult<PartFace> {
        let result: PartCallResult<JSONValue> = await callValue(id: id, input: input, projection: true, pinned: version)
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let value):
            do { return .success(try PartFace.decode(value)) }
            catch { return .failure(.init(code: "bad_face", message: error.localizedDescription)) }
        }
    }

    private func callValue<Value: Codable & Sendable>(id: String, input: JSONValue, projection: Bool,
        pinned: String? = nil, preview: Bool = false, reach: CallReach? = nil,
        as type: Value.Type = Value.self) async -> PartCallResult<Value> {
        do {
            try Task.checkCancellation()
            guard case .object = input, try input.serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
                throw SenseFailure(code: "input_limit", message: "part.call input is a JSON object of at most 4 MiB.")
            }
            if let path = NativeAgentSecretRedactor.secretPath(input) {
                throw SenseFailure(code: "secret_in_input", message: "\(path) carries a credential; credentials never enter a part.")
            }
            // Selection precedes the first suspension; a replacement can stop this call, but can never splice its own code into this
            // invocation.
            let version = try AbilityStore.withLock {
                guard let row = try row(id), let version = Self.string(row, "codeFingerprint") else { throw Self.missing(id) }
                if let reach {
                    let selected = try store.load(id: id, digest: version).program
                    guard Set(selected.dependencies).isSubset(of: reach.actions),
                          Set(selected.permissions).isSubset(of: reach.capabilities) else {
                        throw SenseFailure(code: "caller_reach", message: "The selected part exceeds this caller's action or capability reach; the part did not run.")
                    }
                }
                return version
            }
            guard pinned == nil || pinned == version else {
                throw Self.revisionFailure("state_changed", "Ability \(id) selected \(version) before projection; the requested version was \(pinned ?? "none").", id: id, version: pinned)
            }
            let receipt = try await OwnedProgramRunner.$wake.withValue(nil) {
                if projection {
                    return try await runSelected(id: id, input: input, pinned: version,
                        preview: false, replay: nil, projection: true)
                }
                return try await run(id: id, input: input, requiredFingerprint: version, preview: preview)
            }
            try Task.checkCancellation()
            return Self.callResult(receipt, as: type)
        } catch {
            return .failure((error as? PartCallError) ?? .init(
                code: error is CancellationError ? "cancelled" : (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "failed",
                message: error.localizedDescription))
        }
    }

    /// Value calls retain the runner envelope even when a face action normally presents its business payload directly. JS and Swift decode
    /// it here.
    static func callResult<Value: Codable & Sendable>(_ raw: JSONValue, as type: Value.Type) -> PartCallResult<Value> {
        let outer = Self.fields(raw)
        let receipt: [String: JSONValue]
        if outer["action"] != nil, let result = outer["result"]?.objectValue { receipt = result }
        else { receipt = outer }
        do {
            guard receipt["status"] == .string("ok"), receipt["returned_note"] == nil,
                  receipt["accounting_error"] == nil else {
                let terminal = Self.fields(receipt["error"] ?? receipt["stopped"] ?? .null)
                throw PartCallError(code: Self.string(receipt, "reason") ?? Self.string(terminal, "reason") ?? "failed",
                    message: Self.string(receipt, "detail") ?? Self.string(receipt, "returned_note")
                        ?? Self.string(receipt, "accounting_error") ?? Self.string(terminal, "message") ?? "The part did not return a complete decision.")
            }
            let value = receipt["returned"] ?? .null
            return .success(try JSONDecoder().decode(type, from: value.serializedData(pretty: false)))
        } catch {
            return .failure((error as? PartCallError) ?? .init(
                code: error is CancellationError ? "cancelled" : (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "failed",
                message: error.localizedDescription))
        }
    }

    /// Whether `authored.<id>` runs it: on, JavaScript, a version selected. Guidance (a Markdown ability) is read, never run.
    static func runs(_ row: [String: JSONValue]) -> Bool {
        row["status"] == .string("active") && row["language"] == .string("javascript") && string(row, "codeFingerprint") != nil
    }

    /// What arrived for her in the conversation turn this run serves: a message, or that turn's Stop. Handed in where the call is
    /// dispatched, only while a turn the person can Stop is in flight; nil otherwise, so a part that is not done hands back instead of
    /// going on.
    @TaskLocal public static var arrived: (@Sendable () -> Arrival?)?
    public enum Arrival: Sendable { case message, stop }

    /// `authored.<id>`: its selected version under its signed admission, re-verified now, with its declared reach and nothing else.
    /// `preview` dispatches no write; `replay` resumes a run that stopped. A part that is not done answers `{again: <input>, ...}` and
    /// carries itself: each run its own run, through the same admission and gates, on the version the first one ran, until it answers
    /// without `again`, a run fails or is refused, Stop, something arrives for her, or a run repeats the one before (same input, same
    /// answer). Its caller gets the last answer and `runs`, with what all its runs did; one handed back early keeps `again` and says why.
    public func run(id: String, input: JSONValue, requiredFingerprint: String? = nil, preview: Bool = false,
                    replay: OwnedProgramRunner.Replay? = nil) async throws -> JSONValue {
        var input = input, pinned = requiredFingerprint, runs: Int64 = 0
        var before: (input: JSONValue, answer: JSONValue)?
        // What every run did, so the one receipt never denies an earlier run's writes.
        var calls: [JSONValue] = [], changed: [JSONValue] = [], effects: [String] = [], ledgerBytes = 0
        while true {
            let receipt: JSONValue
            do {
                receipt = try await OwnedProgramInvocation.$valueCall.withValue(nil) {
                    try await runSelected(id: id, input: input, pinned: pinned, preview: preview, replay: replay)
                }
            }
            catch {
                var terminal = ToolHost.failure(error, effects: "none", execution: "not_run")
                if !preview, let version = try? pinned ?? row(id).flatMap({ Self.string($0, "codeFingerprint") }) {
                    terminal = await abilities.settleRun(id: id, version: version, receipt: terminal, input: nil)
                    if runs == 0, let failed = terminal.objectValue?["accounting_error"]?.stringValue { throw PartError.invalid(failed) }
                }
                // A later run that could not start is that run's refusal in the one receipt, beside what the runs before it did; nothing is
                // replayed.
                guard runs > 0 else { throw error }
                receipt = terminal
            }
            runs += 1
            var result = Self.fields(receipt)
            let answer = result["returned"] ?? .null, again = Self.fields(answer)["again"] ?? .null
            let carrying = !preview && replay == nil && result["status"] == .string("ok") && result["accounting_error"] == nil && again != .null
            guard carrying || runs > 1 else { return receipt }
            if case .array(let rows)? = result["calls"] {
                calls += rows.map { var row = Self.fields($0); row["run"] = .int(runs); return .object(row) }
                ledgerBytes += (try? JSONValue.array(rows).serializedData(pretty: false).count) ?? 0
            }
            if case .array(let rows)? = result["changed"] {
                changed += rows.map { if case .string(let call) = $0 { .string("run \(runs) " + call) } else { $0 } }
            }
            effects.append(Self.string(result, "effects") ?? "unknown")
            if runs > 1 {
                // The input its last run ran on, which a stop kept to resume seals.
                result["ran_on"] = input
                result["calls"] = .array(calls)
                result["changed"] = changed.isEmpty ? nil : .array(changed)
                result["effects"] = .string(["unknown", "partial", "occurred"].first(where: effects.contains) ?? effects.last ?? "unknown")
            }
            result["runs"] = .int(runs)
            guard carrying else { return .object(result) }
            let goOn = "call it again with again as its input to go on."
            let handBack: String? = if before.map({ $0.input == input && $0.answer == answer }) == true {
                "Its last run had the same input and answer as the one before, so it made no progress and handed back; " + goOn
            } else if ledgerBytes >= 4 * 1024 * 1024 {
                "Its runs' receipt ledger reached 4 MiB, so it handed back; " + goOn
            } else if let arrived = Self.arrived {
                switch arrived() {
                case .message?: "A message arrived for you while it worked, so it handed back; " + goOn
                case .stop?: "Stop was pressed while it worked, so it handed back; " + goOn
                case nil: nil
                }
            } else { "It goes on by itself only in a conversation turn, so it handed back; " + goOn }
            if let handBack { result["handed_back"] = .string(handBack) }
            if handBack != nil || Task.isCancelled { return .object(result) }
            // A run that carried it forward is progress: its call's ceiling starts again.
            TurnDeadline.progressed()
            before = (input, answer); input = again; pinned = Self.string(result, "version")
        }
    }

    private func runSelected(id: String, input: JSONValue, pinned: String?, preview: Bool, replay: OwnedProgramRunner.Replay?, projection: Bool = false) async throws -> JSONValue {
        guard let host = OwnedProgramInvocation.host else { throw PartError.invalid("An ability needs the gated app door of a conversation or wake run.") }
        let catalogRevision = try abilities.revision()
        guard let row = try row(id), Self.string(row, "id") == id else { throw Self.missing(id) }
        guard row["status"] == .string("active") else {
            throw Self.revisionFailure("not_active", "\(id) is \(Self.string(row, "status") ?? "off"); read it before requesting ability.enable for its exact version. An owner's off-switch remains the owner's decision.", id: id)
        }
        guard let digest = Self.string(row, "codeFingerprint"), pinned == nil || pinned == digest else {
            throw Self.revisionFailure("state_changed", "Ability \(id) no longer selects admitted version \(pinned ?? "(unavailable)").", id: id, version: pinned)
        }
        let candidate: OwnedProgramStore.Candidate
        do { candidate = try store.load(id: id, digest: digest) }
        catch { throw Self.revisionFailure("integrity", "Ability \(id) version \(digest) is unreadable: \(error.localizedDescription)", id: id, version: digest) }
        if let why = OwnedProgram.asyncRefusal(candidate.program.source) {
            throw SenseFailure(code: "async_code", message: why + " ability.save it so. Nothing ran.")
        }
        let revision = try catalogRevision + host.dependencyRevision(candidate.program.dependencies)
        try await checkAdmission(candidate, row: row)
        try checkDependencies(candidate)
        let binding = OwnedProgramRunner.Binding(revision: revision)
        // A wake's run is given none of its input, so its params never refuse it.
        if !projection, OwnedProgramRunner.wake == nil, let problem = input.schemaProblem(schema: candidate.program.schema) {
            throw SenseFailure(code: "bad_input", message: "Its input \(problem.path) must be \(problem.expected).", remedy: .object([
                "kind": .string("correct_arguments"), "instruction": .string("Correct input \(problem.path) to match \(problem.expected); ability.read shows \(id)'s params."),
                "next_call": Self.readCall(id)]))
        }
        if !projection, !preview, replay == nil, let refused = await host.admitTool(id, input: Self.fields(input)) {
            try abilities.recordRun(id: id, version: digest, receipt: refused)
            return refused
        }
        // A resident ability holds what it starts and opens across its runs, a resumed one included (a resume never replays a primitive
        // call).
        let program: OwnedProgram
        if projection {
            guard Self.fields(Self.fields(candidate.manifest)["face"] ?? .null)["projection"] == .bool(true) else {
                throw SenseFailure(code: "no_face", message: "This part does not declare face.projection.")
            }
            let owned = candidate.owned
            program = OwnedProgram(kind: owned.kind, id: id, version: owned.version, source: owned.source, entry: .face,
                dependencies: owned.dependencies, permissions: owned.permissions, seconds: owned.seconds)
        } else { program = candidate.owned }
        let dataRoot = root
        let broker = program.isResident && !preview
            ? try await OwnedProgramRunner.holding(program, dataRoot: dataRoot,
                make: { ToolPrimitiveBroker(permissions: Set(program.permissions), abilityID: id, held: AbilityStore(dataRoot: dataRoot)) },
                end: { _ = await $0.close() })
            : ToolPrimitiveBroker(permissions: Set(program.permissions), abilityID: id)
        let profile = ToolHost(base: host, candidate: candidate, broker: broker, dataRoot: root, projection: projection, preview: preview,
            admission: {
                try await binding.check(self.abilities.revision() + host.dependencyRevision(candidate.program.dependencies)) {
                    try await self.checkSelected(candidate, pinned: digest)
                }
            })
        await broker.begin()
        var result = Self.fields(await OwnedProgramRunner(dataRoot: root).run(program, input: input, preview: preview, replay: replay, host: profile))
        // A watch leaves one receipt for all its frames, however it ended.
        let watched = await settle { await broker.finish() }
        if !watched.isEmpty { result["watch"] = watched.count == 1 ? watched[0] : .array(watched) }
        result["ability"] = .string(id); result["version"] = .string(candidate.digest)
        if result["status"] == .string("stopped"), !candidate.program.isStrict {
            let stopped = Self.fields(result["stopped"] ?? .null)
            result["status"] = .string(stopped["not_run_status"] == .string("approval_filed") ? "waiting_approval"
                : stopped["reason"] == .string("cancelled") ? "cancelled" : "refused")
            result["reason"] = stopped["reason"]; result["detail"] = stopped["detail"]
            for key in ["approvalId", "not_run_status", "remedy"] { result[key] = stopped[key] }
        }
        // What ended the run reads the same at the top, however deep: the call its terminal error names (a caught or expected failure
        // before it never does), else that error's own words.
        if result["status"] != .string("ok"), result["detail"] == nil {
            let terminal = Self.fields(result["stopped"] ?? result["error"] ?? .null)
            let rows: [JSONValue] = if case .array(let rows)? = result["calls"] { rows } else { [] }
            let named = terminal["n"].flatMap { n in rows.first { Self.fields($0)["n"] == n } }.flatMap { Self.string(Self.fields($0), "detail") }
            if let words = [named, Self.string(terminal, "message"), Self.string(terminal, "detail")].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                result["detail"] = .string(words)
            }
        }
        return .object(result)
    }

    func checkSelected(_ candidate: OwnedProgramStore.Candidate, pinned: String) async throws {
        guard let row = try row(candidate.id), row["status"] == .string("active"), row["codeFingerprint"] == .string(pinned) else {
            throw Self.revisionFailure("state_changed", "Ability \(candidate.id) version \(pinned) was stopped or replaced; no further calls were admitted.", id: candidate.id, version: pinned)
        }
        try await checkAdmission(candidate, row: row)
        try checkDependencies(candidate)
    }

    /// The one admission, re-verified each run: signed for this exact version and its sealed proof, and the record still selecting it.
    public func checkAdmission(_ candidate: OwnedProgramStore.Candidate, row: [String: JSONValue]) async throws {
        guard row["codeFingerprint"] == .string(candidate.digest), row["inputSchema"] == candidate.program.schema,
              row["actions"] == .array(candidate.program.dependencies.map(JSONValue.string)),
              row["activePath"] == .string(try store.fileURL(id: candidate.id, digest: candidate.digest).path),
              case .object(let admission)? = row["admission"] else {
            throw Self.revisionFailure("integrity", "Ability \(candidate.id) version \(candidate.digest) no longer matches its admission or selected record.", id: candidate.id, version: candidate.digest)
        }
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let errors = try await signer.verify(admission)
        guard errors.isEmpty, admission["candidate"] == .string(candidate.digest) else {
            throw Self.revisionFailure("integrity", "Ability \(candidate.id) version \(candidate.digest): " + (errors.isEmpty ? "the admission names another version." : errors.joined(separator: "; ")), id: candidate.id, version: candidate.digest)
        }
        guard admission["proof"] == (try store.proof(candidate, key: try await signer.loadOrCreateSigningKey())) else {
            throw Self.revisionFailure("integrity", "Ability \(candidate.id) version \(candidate.digest) no longer matches its admitted proof.", id: candidate.id, version: candidate.digest)
        }
    }

    func dependencyShapes(_ actions: [String]) throws -> JSONValue {
        var shapes: [String: JSONValue] = [:]
        for action in actions {
            guard let shape = OwnedProgramInvocation.host?.dependencyShape(action) else {
                throw ToolFailureError("Dependency \(action) is unavailable in this app door.", argumentPath: "actions", accepted: "current app action ids", effects: .none,
                    nextCall: ToolFailureError.call("app", ["find": .string(action)]), code: "unknown_dependency", status: .refused,
                    instruction: "Find the current action, then correct this ability's call or actions declaration with ability.save.", recovery: .correctArguments)
            }
            shapes[action] = shape
        }
        return .object(shapes)
    }

    func checkDependencies(_ candidate: OwnedProgramStore.Candidate) throws {
        if let action = Self.string(Self.fields(Self.fields(candidate.manifest)["face"] ?? .null), "action"),
           let owner = OwnedProgramInvocation.host?.action(action), owner.partID != candidate.id {
            throw Self.revisionFailure("face_action_collision", "Ability \(candidate.id) cannot own face.action \(action); it belongs to \(owner.partID ?? "the app"). Remove it or choose an unused action id.", id: candidate.id, version: candidate.digest)
        }
        // No door in this turn is not a changed dependency: say which it is.
        guard let host = OwnedProgramInvocation.host else {
            throw SenseFailure(code: "door_unavailable", message: "This run has no gated app door, so its app-action dependencies could not be checked. Use the app door of a conversation or wake run.")
        }
        for action in candidate.program.dependencies where !host.dependencyMatches(action, Self.fields(candidate.dependencyShapes)[action]) {
            let before = Self.fields(candidate.dependencyShapes)[action] ?? .null
            let after = host.dependencyShape(action) ?? .null
            let fields = JSONValue.differences(before, after).map { $0.isEmpty ? "contract" : $0 }.joined(separator: ", ")
            let file = try AbilityStore.File(id: candidate.id, kind: .part, metadata: ["record": candidate.manifest],
                body: candidate.program.source, pathExtension: "js")
            throw ToolFailureError("Dependency \(action) changed at \(fields). Saved: \(try before.serialize(pretty: false)); current: \(try after.serialize(pretty: false)). Revise \(candidate.id) version \(candidate.digest) with ability.save against this contract, keep it, then repeat the failed operation.",
                effects: .none, owner: "ability \(candidate.id) version \(candidate.digest) > candidate.dependencyShapes.\(action) > \(fields)",
                nextCall: try abilities.repairCall(file), code: "stale_dependency", status: .refused,
                instruction: "Revise this ability against the reported current dependency contract, then keep the reviewed version. Do not replay observed effects.")
        }
    }
}
