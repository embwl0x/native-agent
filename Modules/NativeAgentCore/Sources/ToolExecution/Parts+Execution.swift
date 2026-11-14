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
import TriggerScheduler
// Blueprint: | `Parts+Execution.swift` | pinned calls and pure faces; exact run admission |

extension Parts {
    private static let faceInputs = NativeAgentSecretRedactor.FaceInputs()

    static func revisionFailure(_ code: String, _ detail: String, id: String, version: String? = nil) -> SenseFailure {
        SenseFailure(code: code, message: detail, remedy: Repair.remedy(
            owner: "ability \(id)" + (version.map { " version \($0)" } ?? ""), nextCall: readCall(id), tap: nil,
            instruction: """
                Read \(id) and its retained versions; revise the rejected code or declaration with ability.save, then keep the reviewed version with \
                ability.enable. Do not replay observed effects.
                """))
    }

    /// A native caller may narrow a part's admitted reach for this operation. This never grants an action or capability the selected part lacks.
    public struct CallReach: Sendable {
        public let actions: Set<String>
        public let capabilities: Set<String>
        public init(actions: Set<String>, capabilities: Set<String>) {
            self.actions = actions; self.capabilities = capabilities
        }
    }

    /// Pin immutable input/version before execution; domain commits happen afterward so no transaction lock spans JavaScript.
    public func call<Value: Codable & Sendable>(id: String, input: JSONValue, preview: Bool = false,
        within reach: CallReach? = nil, invocation: Invocation, as type: Value.Type = Value.self) async -> PartCallResult<Value> {
        await callValue(id: id, input: input, projection: false, preview: preview, reach: reach, invocation: invocation, as: type)
    }

    /// Faces run from frozen input outside rendering and have no host effects or notebook access.
    @concurrent public func face(id: String, input: JSONValue, version: String, invocation: Invocation,
                                 documentRead: Bool = false) async -> PartCallResult<PartFace> {
        do {
            let prepared = try await prepareFace(id: id, input: input)
            return await face(id: id, input: prepared, version: version, invocation: invocation, documentRead: documentRead)
        } catch { return .failure(.init(code: error is CancellationError ? "cancelled" : "input_limit", message: error.localizedDescription)) }
    }

    /// A native door may prepare frozen input before acquiring its action gate. All callers use this same content-keyed masking owner.
    public func prepareFace(id: String, input: JSONValue) async throws -> NativeAgentSecretRedactor.FaceInput {
        try await Self.faceInputs.prepare(id: root.standardizedFileURL.path + "\u{0}" + id, input: input)
    }

    public func face(id: String, input: NativeAgentSecretRedactor.FaceInput, version: String,
                     invocation: Invocation, documentRead: Bool = false) async -> PartCallResult<PartFace> {
        let result: PartCallResult<JSONValue> = await callValue(id: id, input: input.value, projection: true, pinned: version,
            invocation: invocation)
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let value):
            do { return .success(try PartFace.decode(value, documentRead: documentRead)) }
            catch { return .failure(.init(code: "bad_face", message: error.localizedDescription)) }
        }
    }

    private func callValue<Value: Codable & Sendable>(id: String, input: JSONValue, projection: Bool,
        pinned: String? = nil, preview: Bool = false, reach: CallReach? = nil,
        invocation: Invocation, as type: Value.Type = Value.self) async -> PartCallResult<Value> {
        do {
            try Task.checkCancellation()
            if !projection {
                guard let host = invocation.host, let turn = invocation.execution.turn else {
                    throw PartError.invalid("An ability needs its originating app door and turn.")
                }
                var execution = invocation.execution
                execution.wake = nil
                let selected: (id: String, version: String)
                do {
                    guard let row = try row(id), let selectedID = Self.string(row, "id") else { throw Self.missing(id) }
                    guard let version = Self.string(row, "codeFingerprint") else {
                        throw Self.revisionFailure("state_changed", "Ability \(selectedID) has no selected code fingerprint; its body did not run.",
                            id: selectedID)
                    }
                    selected = (selectedID, version)
                } catch {
                    var refusal = Self.fields(ToolHost.failure(error, effects: "none", execution: "not_run"))
                    refusal["checker"] = .string("part_selection")
                    // No version was selected. The receipt must not attribute this attempt to a version discovered after this failure.
                    refusal["accounting_error"] = .string(error.localizedDescription)
                    let receipt = await host.recordRefusal(.object(refusal),
                        input: ["action": .string("authored." + Self.referenceID(id)), "args": input, "preview": .bool(preview)],
                        turn: turn, surface: execution.surface)
                    return Self.callResult(receipt, as: type)
                }
                execution.valueReach = reach.map { .init(id: selected.id, actions: $0.actions, capabilities: $0.capabilities) }
                // Value calls retain the runner envelope even for a verb whose face presents its business payload.
                execution.valueIdentity = selected
                let receipt = await host.perform(["action": .string("authored." + selected.id), "args": input, "preview": .bool(preview)],
                    execution: execution)
                try Task.checkCancellation()
                return Self.callResult(receipt, as: type)
            }
            // Selection precedes the first suspension; a replacement can stop this call, but can never splice its own code into this invocation.
            let version = try AbilityStore.withLock {
                guard let row = try row(id), let version = Self.string(row, "codeFingerprint") else { throw Self.missing(id) }
                return version
            }
            guard pinned == nil || pinned == version else {
                throw Self.revisionFailure("state_changed",
                    "Ability \(id) selected \(version) before projection; the requested version was \(pinned ?? "none").", id: id, version: pinned)
            }
            var invocation = invocation
            invocation.execution.wake = nil
            let receipt = try await runSelected(id: id, input: input, pinned: version,
                preview: false, replay: nil, projection: true, invocation: invocation)
            try Task.checkCancellation()
            return Self.callResult(receipt, as: type)
        } catch {
            return .failure((error as? PartCallError) ?? .init(
                code: error is CancellationError ? "cancelled" : (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "failed",
                message: error.localizedDescription))
        }
    }

    /// Value calls retain the runner envelope even when a face action normally presents its business payload directly. JS and Swift decode it here.
    static func callResult<Value: Codable & Sendable>(_ raw: JSONValue, as type: Value.Type) -> PartCallResult<Value> {
        let outer = Self.fields(raw)
        let receipt: [String: JSONValue]
        if outer["action"] != nil, let result = outer["result"]?.objectValue { receipt = result }
        else { receipt = outer }
        do {
            guard receipt["status"] == .string("ok"),
                  receipt["accounting_error"] == nil else {
                let terminal = Self.fields(receipt["error"] ?? receipt["stopped"] ?? .null)
                throw PartCallError(code: Self.string(receipt, "reason") ?? Self.string(terminal, "reason") ?? "failed",
                    message: Self.string(receipt, "detail") ?? Self.string(receipt, "accounting_error")
                        ?? Self.string(terminal, "message") ?? "The part did not return a complete decision.")
            }
            let value = receipt["returned"] ?? .null
            return .success(try JSONDecoder().decode(type, from: value.serializedData(pretty: false)))
        } catch {
            return .failure((error as? PartCallError) ?? .init(
                code: error is CancellationError ? "cancelled" : (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "failed",
                message: error.localizedDescription))
        }
    }

    /// Only enabled selected JavaScript runs; Markdown guidance is read, never executed, and a page (`AbilityStore.answersCalls`) is drawn, never called.
    static func runs(_ row: [String: JSONValue]) -> Bool {
        row["status"] == .string("active") && row["language"] == .string("javascript") && string(row, "codeFingerprint") != nil
            && row["callable"] == .bool(true)
    }

    public enum Arrival: Sendable { case message, stop }

    /// Every continuation reruns admission and gates on the original version. Stop, new input, refusal, failure or repeated input/output ends the loop;
    /// early handback retains again and its reason.
    public func run(id: String, input: JSONValue, requiredFingerprint: String? = nil, preview: Bool = false,
                    replay: OwnedProgramRunner.Replay? = nil, invocation: Invocation) async throws -> JSONValue {
        var invocation = invocation
        invocation.execution.valueIdentity = nil
        var input = input, pinned = requiredFingerprint, runs: Int64 = 0
        var before: (input: JSONValue, answer: JSONValue)?
        // What every run did, so the one receipt never denies an earlier run's writes.
        var calls: [JSONValue] = [], changed: [JSONValue] = [], effects: [String] = [], ledgerBytes = 0
        while true {
            let startedAt = Date()
            let receipt: JSONValue
            do {
                receipt = try await runSelected(id: id, input: input, pinned: pinned, preview: preview, replay: replay, invocation: invocation)
            }
            catch {
                var terminal = ToolHost.failure(error, effects: "none", execution: "not_run")
                var fields = Self.fields(terminal)
                fields["checker"] = .string("part_admission")
                terminal = .object(fields)
                if !preview {
                    do {
                        if let version = try pinned ?? row(id).flatMap({ Self.string($0, "codeFingerprint") }) {
                            terminal = await abilities.settleRun(id: id, version: version, receipt: terminal, input: nil,
                                turn: invocation.execution.turn, at: startedAt)
                        }
                    } catch {
                        fields["accounting_error"] = .string(error.localizedDescription)
                        terminal = .object(fields)
                    }
                }
                // A later run that could not start is that run's refusal in the one receipt, beside what the runs before it did; nothing is replayed.
                receipt = terminal
            }
            runs += 1
            var result = Self.fields(receipt)
            let answer = result["returned"] ?? .null, again = Self.fields(answer)["again"] ?? .null
            let carrying = !preview && replay == nil && result["status"] == .string("ok") && result["accounting_error"] == nil && again != .null
            guard carrying || runs > 1 else { return receipt }
            if case .array(let rows)? = result["calls"] {
                calls += rows.map { var row = Self.fields($0); row["run"] = .int(runs); return .object(row) }
                do { ledgerBytes += try JSONValue.array(rows).serializedData(pretty: false).count }
                catch {
                    throw ToolFailureError("""
                        Ability \(id)'s completed run returned a call ledger that could not be encoded: \(error.localizedDescription). The run already \
                        happened; no continuation was started. Inspect its reached actions before repeating the ability.
                        """,
                        effects: .unknown, owner: "authored.\(id)", code: "call_ledger_encoding_failed",
                        instruction: """
                            Inspect the completed run and its reached actions before repeating any change; repair the value that the ledger could not \
                            encode.
                            """, recovery: .reconcile)
                }
            }
            if case .array(let rows)? = result["changed"] {
                changed += rows.map { if case .string(let call) = $0 { .string("run \(runs) " + call) } else { $0 } }
            }
            effects.append(Self.string(result, "effects") ?? "unknown")
            if runs > 1 {
                // Seal the actual last input so resumed work matches stopped work.
                result["ran_on"] = input
                result["calls"] = .array(calls)
                result["changed"] = changed.isEmpty ? nil : .array(changed)
                result["effects"] = .string(["unknown", "partial", "occurred"].first(where: effects.contains) ?? effects.last ?? "unknown")
                // A later run's pre-entry refusal cannot say the whole ability never ran: an earlier completed run carried it this far.
                result["execution"] = .string(result["status"] == .string("ok") ? "executed" : "attempted")
            }
            result["runs"] = .int(runs)
            guard carrying else { return .object(result) }
            let goOn = "call it again with again as its input to go on."
            let handBack: String? = if before.map({ $0.input == input && $0.answer == answer }) == true {
                "Its last run had the same input and answer as the one before, so it made no progress and handed back; " + goOn
            } else if ledgerBytes >= 4 * 1024 * 1024 {
                "Its runs' receipt ledger reached 4 MiB, so it handed back; " + goOn
            } else if let arrived = invocation.arrived {
                switch arrived() {
                case .message?: "A message arrived for you while it worked, so it handed back; " + goOn
                case .stop?: "The turn stopped while it worked, so it handed back; " + goOn
                case nil: nil
                }
            } else { "It goes on by itself only in a conversation turn, so it handed back; " + goOn }
            if let handBack { result["handed_back"] = .string(handBack) }
            if handBack != nil || Task.isCancelled { return .object(result) }
            // A run that carried it forward is progress: its call's ceiling starts again.
            invocation.progressed?()
            before = (input, answer); input = again; pinned = Self.string(result, "version")
        }
    }

    private func runSelected(id: String, input: JSONValue, pinned: String?, preview: Bool, replay: OwnedProgramRunner.Replay?,
        projection: Bool = false, invocation: Invocation) async throws -> JSONValue {
        var invocation = invocation
        if !projection {
            guard case .object = input, try input.serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
                throw SenseFailure(code: "input_limit", message: "part.call input is a JSON object of at most 4 MiB.", remedy: .object([
                    "kind": .string("correct_arguments"), "instruction": .string("Pass a JSON object of at most 4 MiB; read the ability's params."),
                    "next_call": Self.readCall(id)]))
            }
            if let path = NativeAgentSecretRedactor.secretPath(input) {
                throw SenseFailure(code: "secret_in_input", message: "\(path) carries a credential; credentials never enter a part.", remedy: .object([
                    "kind": .string("correct_arguments"), "instruction": .string("Remove credentials from the part's input; use its gated actions.")]))
            }
        }
        guard let host = invocation.host else { throw PartError.invalid("An ability needs the gated app door of a conversation or wake run.") }
        let catalogRevision = try abilities.revision()
        guard let row = try row(id), Self.string(row, "id") == id else { throw Self.missing(id) }
        guard row["status"] == .string("active") else {
            throw Self.revisionFailure("not_active", """
                \(id) is \(Self.string(row, "status") ?? "off"); read it before requesting ability.enable for its exact version. An owner's off-switch \
                remains the owner's decision.
                """, id: id)
        }
        guard let digest = Self.string(row, "codeFingerprint"), pinned == nil || pinned == digest else {
            throw Self.revisionFailure("state_changed", "Ability \(id) no longer selects admitted version \(pinned ?? "(unavailable)").", id: id,
                version: pinned)
        }
        let candidate: OwnedProgramStore.Candidate
        do { candidate = try store.load(id: id, digest: digest) }
        catch { throw Self.revisionFailure("integrity", "Ability \(id) version \(digest) is unreadable: \(error.localizedDescription)", id: id,
            version: digest) }
        if let reach = invocation.execution.valueReach, reach.id == id {
            guard Set(candidate.program.dependencies).isSubset(of: reach.actions),
                  Set(candidate.program.permissions).isSubset(of: reach.capabilities) else {
                throw SenseFailure(code: "caller_reach",
                    message: "The selected part exceeds this caller's action or capability reach; the part did not run.",
                    remedy: Repair.remedy(owner: "the native caller's reach", nextCall: Self.readCall(id), tap: nil,
                        instruction: "Read the part and revise its declared actions and capabilities to fit this caller's reach before calling it."))
            }
        }
        invocation.execution.valueReach = nil
        let revision = try catalogRevision + host.dependencyRevision(candidate.program.dependencies)
        try await checkAdmission(candidate, row: row)
        let dependencySnapshot = try await checkDependencies(candidate, invocation: invocation)
        // Wake runs receive no input, so parameter requirements cannot refuse them.
        if !projection, invocation.execution.wake == nil, let problem = input.schemaProblem(schema: candidate.program.schema) {
            throw SenseFailure(code: "bad_input", message: "Its input: \(problem.words).", remedy: .object([
                "kind": .string("correct_arguments"), "instruction": .string(
                    "Correct the input to match \(problem.expected); ability.read shows \(id)'s params."),
                "next_call": Self.readCall(id)]))
        }
        let admittedInvocation = invocation
        let perform: @Sendable () async throws -> JSONValue = {
            try await self.runAdmitted(candidate, input: input, revision: revision, dependencySnapshot: dependencySnapshot,
                preview: preview, replay: replay, projection: projection, host: host, invocation: admittedInvocation)
        }
        if !projection, !preview {
            guard let result = await host.admitTool(id, input: Self.fields(input), execution: invocation.execution, effect: perform) else {
                throw SenseFailure(code: "door_unavailable", message: "The ability's gate returned no execution receipt.")
            }
            return result
        }
        return try await perform()
    }

    private func runAdmitted(_ candidate: OwnedProgramStore.Candidate, input suppliedInput: JSONValue,
        revision: [String], dependencySnapshot selectedSnapshot: JSONValue,
        preview: Bool, replay: OwnedProgramRunner.Replay?, projection: Bool, host: any OwnedProgramToolHost,
        invocation: Invocation) async throws -> JSONValue {
        let id = candidate.id, digest = candidate.digest
        let startedAt = Date()
        let dependencySnapshot = if projection { selectedSnapshot } else {
            try await checkSelected(candidate, pinned: digest, invocation: invocation)
        }
        let input: JSONValue
        if !projection, id == "native-morning-brief", Self.fields(suppliedInput)["operation"] == .string("brief") {
            let worklog = root.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
                ? InstallPaths.current.claudeWorklog : nil
            input = try await MorningBriefSources(root: root, now: Date(), worklogPath: worklog).packet()
        } else { input = suppliedInput }
        let binding = OwnedProgramRunner.Binding(revision: revision)
        // A resident ability holds what it starts and opens across its runs, a resumed one included (a resume never replays a primitive call).
        let program: OwnedProgram
        if projection {
            guard Self.fields(Self.fields(candidate.manifest)["face"] ?? .null)["projection"] == .bool(true) else {
                throw SenseFailure(code: "no_face", message: "This part does not declare face.projection.")
            }
            let owned = candidate.owned
            program = OwnedProgram(kind: owned.kind, id: id, version: owned.version, source: owned.source, entry: .face,
                dependencies: owned.dependencies, permissions: owned.permissions, seconds: owned.seconds)
        } else {
            // A page answers no call: catalog publication leaves it out by the same reading, so a call that reaches it anyway is refused here.
            guard AbilityStore.answersCalls(candidate.program.source, header: Self.fields(candidate.manifest)) else {
                throw SenseFailure(code: "page_not_call", message: """
                    \(id) is a page, drawn by face(input); it defines no run(input), so it is never called. Read it with ability.read, or add run(input) \
                    with ability.save to make it callable.
                    """)
            }
            program = candidate.owned
        }
        let dataRoot = root
        let broker = program.isResident && !preview
            ? try await OwnedProgramRunner.holding(program, dataRoot: dataRoot,
                make: { ToolPrimitiveBroker(permissions: Set(program.permissions), abilityID: id, dataRoot: dataRoot, held: AbilityStore(dataRoot: dataRoot)) },
                end: { _ = await $0.close() })
            : ToolPrimitiveBroker(permissions: Set(program.permissions), abilityID: id, dataRoot: dataRoot)
        // A verb the part answers as a read runs read-confined; the declaration is enforced here, not trusted.
        let answered = Self.fields(Self.fields(Self.fields(candidate.manifest)["answers"] ?? .null)[Self.string(Self.fields(input), "verb") ?? ""] ?? .null)
        let profile = ToolHost(base: host, candidate: candidate, broker: broker, dataRoot: root, openScreenWatch: invocation.openScreenWatch,
            projection: projection, preview: preview, readOnly: answered["class"] == .string("read"),
            admission: {
                try await binding.check(self.abilities.revision() + host.dependencyRevision(candidate.program.dependencies)) {
                    _ = try await self.checkSelected(candidate, pinned: digest, invocation: invocation)
                }
            })
        await broker.begin()
        var execution = invocation.execution
        execution.dependencySnapshot = projection ? nil : (id: id, version: digest, shapes: dependencySnapshot)
        var result = Self.fields(await OwnedProgramRunner(dataRoot: root).run(program, input: input, preview: preview, replay: replay,
            host: profile, execution: execution))
        // A watch leaves one receipt for all its frames, however it ended.
        let watched = await settle { await broker.finish() }
        if !watched.isEmpty { result["watch"] = watched.count == 1 ? watched[0] : .array(watched) }
        result["ability"] = .string(id); result["version"] = .string(candidate.digest)
        // Completing JavaScript does not make its explicit decline a successful run. Effects and calls remain the runner's evidence.
        if result["status"] == .string("ok"), let returned = result["returned"]?.objectValue,
           returned["status"] == .string("refused") {
            result["status"] = .string("refused")
            for key in ["reason", "reasons", "gate_reason", "not_run_status", "detail", "message", "checker", "remedy"] {
                result[key] = returned[key]
            }
        }
        if result["status"] == .string("stopped"), !candidate.program.isStrict {
            let stopped = Self.fields(result["stopped"] ?? .null)
            result["status"] = .string(stopped["not_run_status"] == .string("approval_filed") ? "waiting_approval"
                : stopped["reason"] == .string("cancelled") ? "cancelled" : "refused")
            result["reason"] = stopped["reason"]; result["detail"] = stopped["detail"]
            for key in ["approvalId", "not_run_status", "remedy"] { result[key] = stopped[key] }
        }
        // Only the terminal error names what ended the run; caught/expected failures cannot override it.
        if result["status"] != .string("ok"), result["detail"] == nil {
            let terminal = Self.fields(result["stopped"] ?? result["error"] ?? .null)
            let rows: [JSONValue] = if case .array(let rows)? = result["calls"] { rows } else { [] }
            let named = terminal["n"].flatMap { n in rows.first { Self.fields($0)["n"] == n } }.flatMap { Self.string(Self.fields($0), "detail") }
            if let words = [named, Self.string(terminal, "message"), Self.string(terminal, "detail")].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                result["detail"] = .string(words)
            }
        }
        if !projection, !preview {
            if result["status"] != .string("ok"), result["checker"] == nil { result["checker"] = .string("part") }
            return await abilities.settleRun(id: id, version: digest, receipt: .object(result), input: replay == nil ? input : nil,
                dependencySnapshot: dependencySnapshot, turn: invocation.execution.turn, at: startedAt)
        }
        return .object(result)
    }

    @discardableResult
    func checkSelected(_ candidate: OwnedProgramStore.Candidate, pinned: String, invocation: Invocation) async throws -> JSONValue {
        guard let row = try row(candidate.id), row["status"] == .string("active"), row["codeFingerprint"] == .string(pinned) else {
            throw Self.revisionFailure("state_changed",
                "Ability \(candidate.id) version \(pinned) was stopped or replaced; no further calls were admitted.", id: candidate.id, version: pinned)
        }
        try await checkAdmission(candidate, row: row)
        return try await checkDependencies(candidate, invocation: invocation)
    }

    /// The one admission, re-verified each run: signed for this exact version and its sealed proof, and the record still selecting it.
    public func checkAdmission(_ candidate: OwnedProgramStore.Candidate, row: [String: JSONValue]) async throws {
        guard row["codeFingerprint"] == .string(candidate.digest), row["inputSchema"] == candidate.program.schema,
              row["actions"] == .array(candidate.program.dependencies.map(JSONValue.string)),
              row["activePath"] == .string(try store.fileURL(id: candidate.id, digest: candidate.digest).path),
              case .object(let admission)? = row["admission"] else {
            throw Self.revisionFailure("integrity",
                "Ability \(candidate.id) version \(candidate.digest) no longer matches its admission or selected record.", id: candidate.id,
                    version: candidate.digest)
        }
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let errors = try await signer.verify(admission)
        guard errors.isEmpty, admission["candidate"] == .string(candidate.digest) else {
            throw Self.revisionFailure("integrity", "Ability \(candidate.id) version \(candidate.digest): " + (errors.isEmpty
                ? "the admission names another version." : errors.joined(separator: "; ")), id: candidate.id, version: candidate.digest)
        }
        guard admission["proof"] == (try store.proof(candidate, key: try await signer.loadOrCreateSigningKey())) else {
            throw Self.revisionFailure("integrity", "Ability \(candidate.id) version \(candidate.digest) no longer matches its admitted proof.",
                id: candidate.id, version: candidate.digest)
        }
    }

    func dependencyShapes(_ actions: [String], invocation: Invocation) throws -> JSONValue {
        var shapes: [String: JSONValue] = [:]
        for action in actions {
            guard let shape = try invocation.host?.dependencyShape(action) else {
                throw ToolFailureError("Dependency \(action) is unavailable in this app door.", argumentPath: "actions", accepted: "current app action ids",
                    effects: .none,
                    nextCall: ToolFailureError.call("app", ["find": .string(action)]), code: "unknown_dependency", status: .refused,
                    instruction: "Find the current action, then correct this ability's call or actions declaration with ability.save.", recovery:
                        .correctArguments)
            }
            shapes[action] = shape
        }
        return .object(shapes)
    }

    @discardableResult
    public func checkDependencies(_ candidate: OwnedProgramStore.Candidate, invocation: Invocation) async throws -> JSONValue {
        if let action = Self.string(Self.fields(Self.fields(candidate.manifest)["face"] ?? .null), "action"),
           let owner = try invocation.host?.action(action), owner.partID != candidate.id {
            throw Self.revisionFailure("face_action_collision", """
                Ability \(candidate.id) cannot own face.action \(action); it belongs to \(owner.partID ?? "the app"). Remove it or choose an unused \
                action id.
                """, id: candidate.id, version: candidate.digest)
        }
        // No door in this turn is not a changed dependency: say which it is.
        guard let host = invocation.host else {
            throw SenseFailure(code: "door_unavailable",
                message: "This run has no gated app door, so its app-action dependencies could not be checked. Use the app door of a conversation or wake run.")
        }
        let calls = OwnedProgram.calls(candidate.program.source)
        let primitives = ToolPrimitiveBroker.operations.union(["apps.call", "part.call"])
        for call in calls.literal where !(call.primitive && primitives.contains(call.spelling)) {
            // No current evidence is unavailability, not evidence of removal or an incompatible schema. The actual call still owns its remedy.
            guard let given = call.given, let problem = try host.callProblem(call.id, given: given,
                schema: call.id == "authored." + candidate.id ? candidate.program.schema : nil) else { continue }
            let file = try AbilityStore.File(id: candidate.id, kind: .part, metadata: ["record": candidate.manifest], body: candidate.program.source,
                pathExtension: "js")
            let next = try JSONValue.parse(Data(abilities.repairCall(file).utf8))
            throw SenseFailure(code: "stale_dependency",
                message: "Call \(call.id) at line \(call.line): \(problem). Revise \(candidate.id) with ability.save, then keep the reviewed version.",
                remedy: .object(["kind": .string("correct_arguments"),
                    "owner": .string("ability \(candidate.id) version \(candidate.digest) > line \(call.line) > \(problem)"),
                    "next_call": next, "try_instead": try await host.callAdvice(call.id, given: given),
                    "instruction": .string("Correct the named call and field, then keep the reviewed version. Do not replay observed effects.")]))
        }
        var shapes: [String: JSONValue] = [:]
        for action in candidate.program.dependencies { shapes[action] = try host.dependencyShape(action) ?? .null }
        return .object(shapes)
    }
}
