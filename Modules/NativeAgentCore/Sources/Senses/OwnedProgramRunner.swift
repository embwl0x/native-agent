import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore

/// One helper implementation, with isolated contexts. Sense subscriptions keep
/// a process through their adapter; tools, skills and scripts discard it after
/// answering. No VM, compiler, turn authority or publication lives in this door.
public struct OwnedProgramRunner: OwnedProgramRunning {
    public static let sourceLimit = 8 * 1024
    public static let actionLimit = 50
    public static let readLimit = 100
    public static let wallSeconds = 60.0
    public static let returnLimit = 16 * 1024
    public static let logLimit = 2 * 1024
    public static let inputLimit = 16 * 1024
    public static let stepLimit = 50

    public typealias SandboxProfile = @Sendable (URL) throws -> String
    private let helperURL: URL
    private let dataRoot: URL
    private let sandboxProfile: SandboxProfile

    public init(helperURL: URL = SenseHostLocator.helperURL, dataRoot: URL, sandboxProfile: @escaping SandboxProfile) {
        self.helperURL = helperURL; self.dataRoot = dataRoot; self.sandboxProfile = sandboxProfile
    }

    /// The host is serviced in this task's context. Cancellation claims pending
    /// replies before killing the helper, so a noncooperative late host result
    /// cannot resume JS or issue another effect. Effect owners retain their gates.
    public func run(_ program: OwnedProgram, input: JSONValue? = nil, preview: Bool = false,
                    replay: Replay? = nil, host: any OwnedProgramHostProfile) async -> JSONValue {
        let actions = ActionTasks()
        let journal = Journal(source: program.source, preview: preview, kind: program.kind,
                              replay: replay, host: host, actionsInFlight: actions)
        do {
            try program.validate()
            guard program.kind != .sense else {
                throw SenseFailure(code: "bad_input", message: "Persistent senses require their source-bound runner adapter.")
            }
            if let input {
                let limit = program.kind == .tool ? program.returnLimit : Self.inputLimit
                guard case .object = input, try input.serializedData(pretty: false).count <= limit else {
                    throw SenseFailure(code: "invalid_input", message: "A program's input must be a JSON object of at most \(limit) bytes.")
                }
            }
            try Task.checkCancellation()
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("program-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let process: OwnedProgramProcess
            do {
                process = try OwnedProgramProcess(helper: helperURL, profile: sandboxProfile(scratch), scratch: scratch,
                                                  onFailure: { _ in actions.cancel() })
            }
            catch { try? FileManager.default.removeItem(at: scratch); throw error }
            defer { process.end(1); process.stop(); actions.cancel() }
            return await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    var message: [String: JSONValue] = [
                        "id": .int(1), "type": .string("run"), "program": try .fromEncodable(program),
                        "actionIDs": .array(host.actionIDs.map(JSONValue.string)),
                    ]
                    if program.kind == .tool { message["workspace"] = .string(try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot).path) }
                    if let input { message["input"] = input }
                    process.begin(id: 1, kind: program.kind, seconds: program.seconds)
                    try process.send(.object(message))
                    var lastCallID: Int64 = 0
                    for await event in process.events {
                        try Task.checkCancellation()
                        switch event {
                        case .ended(let detail): throw SenseFailure(code: "crashed", message: detail)
                        case .line(let bytes):
                            guard case .object(let fields) = try JSONValue.parse(bytes), fields["id"] == .int(1),
                                  case .string(let type)? = fields["type"] else {
                                throw SenseFailure(code: "bad_output", message: "Program helper sent an invalid message.")
                            }
                            if type == "failed" {
                                let failure = try JSONDecoder().decode(SenseFailure.self, from: JSONEncoder().encode(fields["failure"] ?? .null))
                                // A reported failure explains the helper's exit;
                                // a latched supervision failure still wins.
                                let terminal = process.failure
                                journal.fail(terminal?.code == "crashed" ? failure : terminal ?? failure)
                                return journal.receipt()
                            }
                            if type == "program_done" {
                                try process.claimCompletion(1)
                                journal.complete(fields)
                                return journal.receipt()
                            }
                            guard case .int(let callID)? = fields["callID"], callID > lastCallID else {
                                throw SenseFailure(code: "bad_output", message: "Program host calls require increasing callIDs.")
                            }
                            lastCallID = callID
                            if type == "script_log", case .string(let text)? = fields["text"] {
                                journal.say(text); continue
                            }
                            let started = try process.suspend(1)
                            var reply: JSONValue
                            if type == "app_call", case .string(let kind)? = fields["kind"],
                               case .string(let id)? = fields["action"], case .string(let args)? = fields["args"],
                               case .int(let line)? = fields["line"] {
                                guard kind != "primitive" || program.kind == .tool else {
                                    throw SenseFailure(code: "bad_output", message: "Only a tool host can serve declared primitives.")
                                }
                                reply = .string(await journal.call(kind: kind, id: id, args: args, line: Int(line)))
                            } else { throw SenseFailure(code: "bad_output", message: "Program called an API outside its host profile.") }
                            try Task.checkCancellation()
                            try process.resume(1, since: started)
                            try process.send(.object(["type": .string("host_reply"), "id": .int(1),
                                                      "callID": .int(callID), "value": reply]))
                        }
                    }
                    throw SenseFailure(code: "crashed", message: "Program helper ended before answering.")
                } catch {
                    journal.fail(process.failure ?? (error is CancellationError
                        ? SenseFailure(code: "cancelled", message: "Program cancelled.")
                        : (error as? SenseFailure) ?? SenseFailure(code: "crashed", message: error.localizedDescription)))
                    return journal.receipt()
                }
            } onCancel: { actions.cancel(); process.stop() }
        } catch {
            journal.fail((error as? SenseFailure) ?? SenseFailure(code: "crashed", message: error.localizedDescription))
            return journal.receipt()
        }
    }

    private final class ActionTasks: @unchecked Sendable {
        private let lock = NSLock()
        private var active: (task: Task<Void, Never>, reply: CheckedContinuation<JSONValue, Never>)?
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        private static let cancellation = JSONValue.object([
            "status": .string("failed"), "reason": .string("cancelled"), "not_run_status": .string("cancelled"),
            "detail": .string("The turn was stopped while this call was running."),
        ])

        func perform(_ input: [String: JSONValue], host: any OwnedProgramHostProfile) async -> JSONValue {
            await call { await host.perform(input) }
        }

        func primitive(_ operation: String, arguments: JSONValue, preview: Bool, host: any OwnedProgramHostProfile) async -> JSONValue {
            await call {
                do { return try await host.primitive(operation, arguments: arguments, preview: preview) }
                catch {
                    let failure = (error as? SenseFailure) ?? SenseFailure(code: "failed", message: error.localizedDescription)
                    return .object(["status": .string("failed"), "reason": .string(failure.code),
                                    "detail": .string(failure.message), "effects": .string("unknown")])
                }
            }
        }

        private func call(_ operation: @escaping @Sendable () async -> JSONValue) async -> JSONValue {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    guard !cancelled, !Task.isCancelled else { continuation.resume(returning: Self.cancellation); return }
                    let task = Task {
                        guard !Task.isCancelled else { return }
                        let result = await operation()
                        let reply = self.lock.withLock { () -> CheckedContinuation<JSONValue, Never>? in
                            defer { self.active = nil }
                            return self.active?.reply
                        }
                        reply?.resume(returning: result)
                    }
                    active = (task, continuation)
                }
            }
        }

        func cancel() {
            let action = lock.withLock {
                cancelled = true
                defer { active = nil }
                return active
            }
            action?.task.cancel(); action?.reply.resume(returning: Self.cancellation)
        }
    }

    // MARK: - Classifying one call's receipt

    /// `unclear`: a strict run's receipt that is not a clear success
    /// (`strictFault`); a write's effects are then unknown.
    enum Outcome { case ok, preview, failed, stop, unclear }

    /// `strict` (a skill's run) is exact, by `strictFault`'s one rule.
    static func classify(_ receipt: JSONValue, strict: Bool = false, write: Bool = false,
                         host: any OwnedProgramHostProfile)
        -> (outcome: Outcome, reason: String, detail: String) {
        guard case .object(let fields) = receipt else {
            guard strict, write else { return (.ok, "", "") }
            return (.unclear, "not_a_receipt", "It answered with no receipt, so whether it took effect can't be told.")
        }
        let inner: [String: JSONValue] = if case .object(let result)? = fields["result"] { result } else { [:] }
        func text(_ key: String) -> String {
            [fields[key], inner[key]].lazy.compactMap { word($0) }
                .first { !$0.isEmpty } ?? ""
        }
        let detail = String(text("detail").prefix(400))
        let waiting = text("not_run_status")
        if !waiting.isEmpty || host.evidence(receipt).waiting
            || host.evidence(fields["result"] ?? .null).waiting {
            return (.stop, waiting.isEmpty ? "waiting_on_user" : waiting, detail)
        }
        // A preview that would refuse classifies as that refusal would.
        if fields["status"] == .string("preview") {
            let refused = text("would_refuse")
            if fields["owner"] == .string("his") { return (.stop, refused.isEmpty ? "owners_call" : refused, detail) }
            if fields["would_card"] == .bool(true) { return (.stop, "would_card", detail) }
            return refused.isEmpty ? (.preview, "", detail) : (.failed, refused, detail)
        }
        if fields["status"] == .string("did_not_stick") { return (.failed, "did_not_stick", detail) }
        // A card only User can answer, on the glass: nothing was answered.
        if fields["status"] == .string("needs_glass") { return (.stop, "needs_glass", String(text("reason").prefix(400))) }
        if host.evidence(receipt).successful {
            guard strict, let fault = strictFault(fields, write: write, host: host) else { return (.ok, "", detail) }
            return (.unclear, fault, detail.isEmpty ? "Its receipt is not a clear success (\(fault))." : detail)
        }
        let reason = [text("reason"), text("failure_code")].first { !$0.isEmpty && !$0.contains(" ") } ?? "failed"
        return (host.floorReasons.contains(reason) ? .stop : .failed, reason, detail)
    }

    /// A strict run's one rule, all the way down a receipt's `result`s. A
    /// write is a success only when its receipt says terminal success, and
    /// nothing under it says otherwise. A read may return any data, but no
    /// failure, status that is not final, dry run, or unknown or partial
    /// effects. Nil when it passes.
    static func strictFault(_ fields: [String: JSONValue], write: Bool, host: any OwnedProgramHostProfile) -> String? {
        for (depth, at) in resultChain(fields).enumerated() {
            let evidence = host.evidence(.object(at))
            let outcome = evidence.resultClass
            let status = text(at["status"]).lowercased()
            let reason = text(at["reason"])
            let effects = text(at["effects"])
            if ["failed", "refused", "timeout", "cancelled"].contains(outcome) {
                return reason.isEmpty || reason.contains(" ") ? "failed" : reason
            }
            if evidence.pending { return "status_\(status)" }
            if at["dry_run"] == .bool(true) || at["dryRun"] == .bool(true) { return "dry_run" }
            if ["unknown", "partial"].contains(effects) { return "effects_\(effects)" }
            if evidence.effectUnconfirmed {
                return "effect_unconfirmed"
            }
            guard write, outcome != "succeeded", depth == 0 || !status.isEmpty else { continue }
            return status.isEmpty ? "no_success_said" : "status_\(status)"
        }
        return nil
    }

    /// A receipt and every `result` inside it, outermost first.
    static func resultChain(_ fields: [String: JSONValue]) -> [[String: JSONValue]] {
        var chain = [fields]
        while case .object(let inner)? = chain.last?["result"] { chain.append(inner) }
        return chain
    }

    /// A call's effects from its whole receipt: unknown, then partial, then
    /// occurred outranks what an outer level said.
    static func effects(_ fields: [String: JSONValue]) -> JSONValue? {
        let said = resultChain(fields).map { text($0["effects"]) }.filter { !$0.isEmpty }
        return (["unknown", "partial", "occurred"].first(where: said.contains) ?? said.first).map(JSONValue.string)
    }

    /// The real ids a call's receipt returned, whatever its size: the first
    /// of each name, down through objects (never lists, never its own input).
    static func returnedIDs(_ receipt: JSONValue) -> [String: JSONValue] {
        let names = ["approval_id", "message_id", "run_id", "request_id", "id", "version", "page_version"]
        var found: [String: JSONValue] = [:]
        var level: [[String: JSONValue]] = if case .object(let fields) = receipt { [fields] } else { [] }
        while !level.isEmpty {
            for fields in level {
                for name in names where found[name] == nil {
                    switch fields[name] {
                    case .string(let id)? where !id.isEmpty: found[name] = .string(id)
                    case .int(let id)?: found[name] = .int(id)
                    default: break
                    }
                }
            }
            level = level.flatMap { fields in
                fields.filter { !["underlying_call", "side_effects", "args"].contains($0.key) }.sorted { $0.key < $1.key }
                    .compactMap { if case .object(let inner) = $0.value { inner } else { nil } }
            }
        }
        return found
    }

    public struct ScriptError: Error {
        public let reason: String
        public let detail: String
        public init(reason: String, detail: String) { self.reason = reason; self.detail = detail }
    }

    /// A stopped skill run, resumed: the script runs again from the top, and
    /// each call the stopped run made is answered from `journal`, in order,
    /// without running again; the one it stopped at (its decide, or the step
    /// it handed back) returns `answer`. A call that differs from the
    /// journal's stops the run there, before it runs.
    public struct Replay: Sendable {
        public let journal: [JSONValue]
        public let answer: JSONValue
        public let recheckReads: Bool
        public init(journal: [JSONValue], answer: JSONValue, recheckReads: Bool = true) {
            self.journal = journal; self.answer = answer; self.recheckReads = recheckReads
        }
    }

    /// A read's answer without its place in the run (n, line).
    static func readValue(_ out: String) -> JSONValue {
        guard case .object(var fields)? = try? JSONValue.parse(Data(out.utf8)) else { return .string(out) }
        for key in ["n", "line"] { fields.removeValue(forKey: key) }
        return fields["value"] ?? .object(fields)
    }

    /// Result owners declare their volatile envelope here while a read runs.
    /// The journal keeps the digest and projections for later argument comparisons;
    /// the script still receives the whole result.
    public final class ReadContent: @unchecked Sendable {
        @TaskLocal public static var current: ReadContent?
        private let lock = NSLock()
        private var declarations: [(value: JSONValue, content: JSONValue)] = []
        private var dependencies: [JSONValue] = []

        public func record(_ value: JSONValue, content: JSONValue) {
            guard value != content else { return }
            lock.withLock { declarations.append((value, content)) }
        }

        public func depend(on content: JSONValue) {
            lock.withLock { dependencies.append(content) }
        }

        var projections: JSONValue {
            lock.withLock {
                .array(declarations.map { .object(["value": $0.value, "content": $0.content]) })
            }
        }

        func include(_ projections: JSONValue) {
            guard case .array(let entries) = projections else { return }
            for entry in entries {
                if case .object(let fields) = entry, let value = fields["value"], let content = fields["content"] {
                    record(value, content: content)
                }
            }
        }

        /// One owner-declared projection for read content and replay arguments.
        func normalize(_ value: JSONValue) -> JSONValue {
            lock.withLock {
                func project(_ value: JSONValue) -> JSONValue {
                    switch value {
                    case .object(var fields):
                        for declaration in declarations {
                            if case .object(let envelope) = declaration.value, case .object(let content) = declaration.content,
                               envelope.allSatisfy({ fields[$0.key] == $0.value }) {
                                for key in envelope.keys { fields[key] = content[key] }
                            }
                        }
                        return .object(fields.mapValues(project))
                    case .array(let items): return .array(items.map(project))
                    case .string(var text):
                        for declaration in declarations {
                            if case .string(let token) = declaration.value, case .string(let content) = declaration.content {
                                text = text.replacingOccurrences(of: token, with: content)
                            }
                        }
                        return .string(text)
                    default: return value
                    }
                }
                return project(value)
            }
        }

        func digest(_ value: JSONValue) -> String {
            let dependencies = lock.withLock { self.dependencies }
            let content: JSONValue = if case .object(let fields) = value, let version = fields["version"] {
                .object(["version": version])
            } else { normalize(value) }
            return JSONValue.array([content, .array(dependencies.map(normalize))]).digest
        }
    }

    /// The versions a strict run's own calls returned, in order, from its
    /// journal: each read's version and each write's page_version.
    public static func ownVersions(_ journal: [JSONValue]) -> [String] {
        journal.compactMap { entry -> String? in
            guard case .object(let fields) = entry, case .array(let call)? = fields["call"], let kind = call.first,
                  case .string(let out)? = fields["out"], case .object(let value) = readValue(out) else { return nil }
            return word(kind == .string("read") ? value["version"] : value["page_version"])
        }
    }

    /// What a journaled call reads or writes: its page, and the item it names.
    static func target(_ entry: JSONValue, host: any OwnedProgramHostProfile) -> (page: String, item: String?, write: Bool)? {
        guard case .object(let fields) = entry, case .array(let call)? = fields["call"], call.count > 2,
              case .string(let kind) = call[0], case .string(let id) = call[1], case .string(let raw) = call[2] else { return nil }
        let given: [JSONValue] = if case .array(let list)? = try? JSONValue.parse(Data(raw.utf8)) { list } else { [] }
        func lower(_ value: JSONValue?) -> String? { word(value)?.lowercased() }
        if kind == "read", let page = lower(given.first) { return (page, given.count > 1 ? lower(given[1]) : nil, false) }
        guard ["action", "primitive"].contains(kind),
              let action = kind == "primitive" ? host.primitiveAction(id) : host.action(id) else { return nil }
        let args: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
        guard let page = action.page == "*" ? lower(args["page"]) : action.page.lowercased() else { return nil }
        return (page, lower(args["handle"]) ?? lower(args["id"]) ?? lower(args["item"]), !action.readOnly(args))
    }

    /// A version's page or page/item.
    public static func versionScope(_ version: String) -> String {
        version.split(separator: "@", maxSplits: 1).first.map(String.init) ?? version
    }

    /// A read's answer, short: its version when it has one.
    static func brief(_ out: String) -> JSONValue {
        let value = readValue(out)
        if case .object(let fields) = value, let version = fields["version"] { return version }
        return .string(String(((try? value.serialize(pretty: false)) ?? out).prefix(300)))
    }

    private final class Journal {
        let lines: [Substring]
        let preview: Bool
        let strict: Bool
        let tool: Bool
        let journalsCalls: Bool
        let replay: [JSONValue]
        let answer: JSONValue
        let recheckReads: Bool
        let host: any OwnedProgramHostProfile
        let actionsInFlight: ActionTasks

        // Only the requesting task mutates this journal.
        var ledger: [JSONValue] = []
        var ledgerBytes = 0
        var log: [String] = []
        var logBytes = 0
        var actions = 0
        var reads = 0
        var stopped: [String: JSONValue]?
        var refusedAfterStop = 0
        var returned: JSONValue = .null
        var returnedNote: String?
        var error: [String: JSONValue]?
        var timedOut = false
        /// A strict run's step labels and guidance, as `app.step` declared them.
        var steps: [(label: String, guidance: String)] = []
        /// The failure code the next call is declared to fail with
        /// (`app.expect_fail`), and whether that call has run.
        var expectFail: String?
        var expectFailSeen = false
        var expectFailMatched = false
        /// The step count `app.step(label, guidance, {of: n})` declared.
        var stepTotal: Int?
        /// What `app.decide` handed back beside its question.
        var decideData: JSONValue = .null
        /// A strict run's calls, each with what it answered and its ledger
        /// row, for a resume to replay; and how many it has replayed.
        var journal: [JSONValue] = []
        var replayed = 0
        var readContent: JSONValue = .null
        var readProjections: JSONValue = .array([])
        let replayContent = ReadContent()
        /// Where the stopped run's own writes landed, by journal position: a
        /// read it made before one of them on the same page or item replays as
        /// saved, since its own write explains the difference.
        let ownWrites: [(at: Int, page: String, item: String?)]

        var isCancelled: Bool { Task.isCancelled }

        init(source: String, preview: Bool, kind: OwnedProgram.Kind, replay: Replay?,
             host: any OwnedProgramHostProfile, actionsInFlight: ActionTasks) {
            self.lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            self.preview = preview; self.strict = kind == .skill; self.tool = kind == .tool
            self.journalsCalls = kind == .skill || kind == .tool
            self.replay = replay?.journal ?? []; self.answer = replay?.answer ?? .null
            self.recheckReads = replay?.recheckReads ?? true
            self.host = host; self.actionsInFlight = actionsInFlight
            self.ownWrites = (replay?.journal ?? []).enumerated().compactMap { at, entry in
                guard let target = OwnedProgramRunner.target(entry, host: host), target.write, case .object(let fields) = entry,
                      Self.status(fields["row"] ?? .null) == "ok" else { return nil }
                return (at, target.page, target.item)
            }
        }

        func complete(_ fields: [String: JSONValue]) {
            if case .object(var report)? = fields["exception"], stopped == nil {
                if tool { report["origin"] = .string("javascript") }
                let message = word(report["message"]) ?? "error"
                if report["name"] == .string("SyntaxError") {
                    report["reason"] = .string("script_syntax")
                    report["rule"] = .string("javascript_function_body")
                    report["instruction"] = .string("Fix the JavaScript syntax reported in message at line. "
                        + "Top-level await is not supported: app.* calls return synchronously. Use const result = app.read(\"inbox\"); return result; without await.")
                }
                if let name = message.range(of: #"(?<=Can't find variable: )\w+"#, options: .regularExpression).map({ String(message[$0]) }),
                   host.actionIDs.contains(where: { $0.hasPrefix(name + ".") }) {
                    report["reason"] = .string("script_name")
                    report["instruction"] = .string("Inside a script, actions live under app: use app.\(name).… (for example app.\(name).\(host.actionIDs.first { $0.hasPrefix(name + ".") }.map { String($0.dropFirst(name.count + 1)) } ?? "…")()).")
                }
                report.removeValue(forKey: "name")
                if case .int(let line)? = report["line"], line > 0 { report["source"] = sourceLine(Int(line)) }
                if case .int(let n)? = report["n"], ledger.indices.contains(Int(n) - 1),
                   case .object(let row) = ledger[Int(n) - 1] {
                    report["call"] = row["call"] ?? .null
                    for key in ["nearest", "remedy", "argument_path"] { report[key] = row[key] }
                }
                error = report
            }
            if stopped == nil, case .string(let detail)? = fields["unreadableReturn"] {
                if strict { stopped = ["reason": .string("unreadable_return"), "detail": .string(detail)] }
                else { error = ["reason": .string("unreadable_return"), "message": .string(detail)] }
            }
            returned = fields["returned"] ?? .null
            returnedNote = word(fields["returnedNote"])
            if strict, stopped == nil, !timedOut, let code = expectFail {
                stopped = ["reason": .string("expected_failure_not_seen"),
                           "detail": .string("app.expect_fail(\"\(code)\") was never closed, so nothing failed as declared.")]
            }
        }

        func fail(_ failure: SenseFailure) {
            if failure.code != "cancelled", stopped?["reason"] == .string("cancelled") { stopped = nil }
            if failure.code == "timeout" { timedOut = true }
            else if failure.code == "cancelled" {
                stopped = ["reason": .string("cancelled"), "detail": .string("The turn was stopped, so the script was ended.")]
            } else if stopped == nil {
                error = ["reason": .string(failure.code), "message": .string(String(failure.message.prefix(400)))]
                if tool { error?["origin"] = .string("runtime") }
            }
        }

        func say(_ text: String) {
            guard logBytes < OwnedProgramRunner.logLimit else { return }
            let kept = String(text.prefix(OwnedProgramRunner.logLimit - logBytes))
            logBytes += kept.utf8.count; log.append(kept)
        }

        func sourceLine(_ line: Int) -> JSONValue {
            guard line >= 1, !lines.isEmpty else { return .null }
            let text = lines[min(line, lines.count) - 1].trimmingCharacters(in: .whitespaces)
            // A line that names an action taking a key is never echoed back.
            if host.secretLine(text) {
                return .string("[redacted: this line names an action that takes a key or token]")
            }
            return .string(String(text.prefix(160)))
        }

        /// One `app.*` call, on the script's thread. A strict run journals each
        /// call that can land or stop, and a resumed one answers them from
        /// its journal (`Replay`).
        func call(kind: String, id: String, args: String, line: Int) async -> String {
            let id = kind == "action" ? (host.canonicalAction(id)) : id
            guard strict, ["action", "primitive", "read", "find", "decide"].contains(kind), stopped == nil else {
                return await dispatch(kind: kind, id: id, args: args, line: line)
            }
            let signature = JSONValue.array([.string(kind), .string(id), .string(args), .int(Int64(line))])
            guard replayed < replay.count else {
                let rows = ledger.count
                let out = await dispatch(kind: kind, id: id, args: args, line: line)
                journal.append(.object(["call": signature, "out": .string(out),
                                        "row": ledger.count > rows ? ledger[ledger.count - 1] : .null,
                                        "read_content": readContent, "read_projections": readProjections]))
                return out
            }
            let n = ledger.count + 1
            guard case .object(let entry) = replay[replayed], sameCall(entry["call"], signature),
                  case .string(var out)? = entry["out"] else {
                let detail = "This resumed run took another path than the one that stopped, at call \(replayed + 1) of "
                    + "\(replay.count), so nothing more ran. Run the skill again from the start."
                stopped = ["line": .int(Int64(line)), "source": sourceLine(line), "reason": .string("diverged"),
                           "detail": .string(detail)]
                return encode(["ok": .bool(false), "reason": .string("diverged"), "detail": .string(detail),
                               "stopped": .bool(true)], line: line, n: n)
            }
            replayed += 1
            var row = entry["row"] ?? .null
            let read: Bool
            if case .object(let fields) = row, let declared = fields["read_only"] {
                read = declared == .bool(true)
            } else if kind == "primitive" {
                let given: [JSONValue] = if case .array(let list)? = try? JSONValue.parse(Data(args.utf8)) { list } else { [] }
                let named: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
                read = host.primitiveAction(id)?.readOnly(named) == true
            } else {
                read = host.action(id)?.read == true
            }
            if replayed == replay.count {
                // Where it stopped: her answer, never the call, a read included.
                out = encode(["ok": .bool(true), "value": answer], line: line, n: n)
                if case .object(var fields) = row {
                    for key in ["reason", "detail", "result"] { fields.removeValue(forKey: key) }
                    fields["status"] = .string("answered")
                    row = .object(fields)
                }
            } else if recheckReads, Self.status(row) != "answered",
                      kind == "read" || kind == "find" || (["action", "primitive"].contains(kind) && read),
                      kind != "action" || host.action(id)?.advisory != true,
                      !writtenLater(replay[replayed - 1], at: replayed - 1) {
                // Authoritative reads must still match; advisory answers replay as saved.
                // (A read the run itself later wrote over replays as saved, below.)
                let now = await dispatch(kind: kind, id: id, args: args, line: line)
                // Refusals before dispatch have no read content; the refusal itself must match.
                guard stopped == nil, let content = entry["read_content"], readContent == content,
                      content != .null || replayContent.normalize(OwnedProgramRunner.readValue(now))
                          == replayContent.normalize(OwnedProgramRunner.readValue(out)) else {
                    let name = kind == "action" ? id : ledger.last.flatMap { if case .object(let row) = $0 { word(row["call"]) } else { nil } } ?? kind
                    let detail = "\(name) reads differently than when this run stopped, so nothing more ran: what it "
                        + "went on from has changed. Run the skill again from the start if it still fits."
                    stopped = ["line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                               "reason": .string("state_changed"), "detail": .string(detail),
                               "was": OwnedProgramRunner.brief(out), "now": OwnedProgramRunner.brief(now)]
                    return encode(["ok": .bool(false), "reason": .string("state_changed"), "detail": .string(detail),
                                   "stopped": .bool(true)], line: line, n: n)
                }
                // Both saved and fresh bindings share the result owner's content contract.
                replayContent.include(entry["read_projections"] ?? .null)
                replayContent.include(readProjections)
                // Passing reads return fresh bindings for the resumed run's later actions.
                journal.append(.object(["call": signature, "out": .string(now), "row": ledger.last ?? .null,
                                        "read_content": readContent, "read_projections": readProjections]))
                return now
            }
            if case .object(let fields) = row {
                append(row)
                if kind == "action" || kind == "primitive" { actions += 1 } else { reads += 1 }
                if expectFail != nil {
                    expectFailSeen = true
                    if fields["expected"] == .bool(true) { expectFailMatched = true }
                }
            }
            replayContent.include(entry["read_projections"] ?? .null)
            journal.append(.object(["call": signature, "out": .string(out), "row": row,
                                    "read_content": entry["read_content"] ?? .null,
                                    "read_projections": entry["read_projections"] ?? .array([])]))
            return out
        }

        func sameCall(_ saved: JSONValue?, _ current: JSONValue) -> Bool {
            guard case .array(var was)? = saved, case .array(var now) = current,
                  was.count == 4, now.count == 4,
                  case .string(let oldArgs) = was[2], case .string(let newArgs) = now[2],
                  let oldValue = try? JSONValue.parse(Data(oldArgs.utf8)),
                  let newValue = try? JSONValue.parse(Data(newArgs.utf8)) else { return saved == current }
            was[2] = replayContent.normalize(oldValue)
            now[2] = replayContent.normalize(newValue)
            return was == now
        }

        /// Whether the stopped run itself wrote, after this read, the page or
        /// item it read (a landed write, exempt or versioned).
        func writtenLater(_ entry: JSONValue, at index: Int) -> Bool {
            guard let read = OwnedProgramRunner.target(entry, host: host), !read.write else { return false }
            return ownWrites.contains { $0.at > index && $0.page == read.page
                && (read.item == nil || $0.item == nil || $0.item == read.item) }
        }

        /// A ledger row's status; an answered one replays as saved, never run again.
        static func status(_ row: JSONValue) -> String {
            if case .object(let fields) = row { word(fields["status"]) ?? "" } else { "" }
        }

        func encode(_ fields: [String: JSONValue], line: Int, n: Int) -> String {
            var fields = fields
            fields["line"] = .int(Int64(line))
            fields["n"] = .int(Int64(n))
            return (try? JSONValue.object(fields).serialize(pretty: false)) ?? #"{"ok":false,"reason":"internal","detail":"unreadable"}"#
        }

        func append(_ row: JSONValue) {
            if tool { ledgerBytes += (try? row.serializedData(pretty: false).count) ?? 0 }
            ledger.append(row)
        }

        /// One call, run: checks the latch and the limits, hands the call to
        /// the caller's task, waits, and records it.
        func dispatch(kind: String, id: String, args: String, line: Int) async -> String {
            readContent = .null
            readProjections = .array([])
            if tool, ledgerBytes >= 4 * 1024 * 1024 {
                stopped = ["reason": .string("output_limit"), "detail": .string("The tool's receipt ledger reached 4 MiB; no further call ran.")]
                return encode(["ok": .bool(false), "reason": .string("output_limit"),
                               "detail": stopped?["detail"] ?? .null, "stopped": .bool(true)], line: line, n: ledger.count + 1)
            }
            let n = ledger.count + 1
            var row: [String: JSONValue] = ["n": .int(Int64(n)), "line": .int(Int64(line))]
            if strict, !steps.isEmpty { row["step"] = .int(Int64(steps.count)) }
            let given: [JSONValue] = if case .array(let list)? = try? JSONValue.parse(Data(args.utf8)) { list } else { [] }
            let named: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
            let write = kind == "primitive" ? host.primitiveAction(id)?.readOnly(named) != true
                : kind == "action" && host.action(id)?.readOnly(named) != true
            func answer(_ fields: [String: JSONValue]) -> String { encode(fields, line: line, n: n) }
            func refuse(_ reason: String, _ detail: String, stop: Bool) -> String {
                answer(["ok": .bool(false), "reason": .string(reason), "detail": .string(detail), "stopped": .bool(stop)])
            }
            /// A strict run's own stop, at a line rather than a call.
            func mark(_ reason: String, _ detail: String) -> String {
                stopped = ["line": .int(Int64(line)), "source": sourceLine(line), "reason": .string(reason), "detail": .string(detail)]
                return refuse(reason, detail, stop: true)
            }
            // Closes an expect_fail even after a stop, so the script rethrows
            // what its call threw.
            if strict, kind == "expect_fail_end" {
                defer { expectFail = nil }
                guard stopped == nil, let code = expectFail else { return answer(["ok": .bool(true), "value": .null]) }
                if given.first == .bool(true) {
                    return mark("expect_fail_async", "app.expect_fail(\"\(code)\") was given an async function; it takes one plain call.")
                }
                guard expectFailMatched else {
                    return mark("expected_failure_not_seen", "app.expect_fail(\"\(code)\") saw no call fail with \(code).")
                }
                return answer(["ok": .bool(true), "value": .null])
            }
            if let stopped {
                refusedAfterStop += 1
                let at = stopped["line"].flatMap(word) ?? "?"
                return refuse("stopped", "The script stopped at line \(at); no app call runs after that.", stop: true)
            }
            func halt(_ reason: String, _ detail: String, call name: String) -> String {
                row["call"] = .string(name)
                row["status"] = .string("not_run")
                row["reason"] = .string(reason)
                append(.object(row))
                stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                           "reason": .string(reason), "detail": .string(detail)]
                return refuse(reason, detail, stop: true)
            }
            if strict, ["step", "expect", "expect_fail", "decide"].contains(kind) {
                func text(_ i: Int) -> String { given.indices.contains(i) ? word(given[i]) ?? "" : "" }
                switch kind {
                case "step":
                    guard steps.count < OwnedProgramRunner.stepLimit else {
                        return mark("step_limit", "A run declares at most \(OwnedProgramRunner.stepLimit) steps.")
                    }
                    steps.append((String(text(0).prefix(160)), String(text(1).prefix(400))))
                    if given.count > 2, case .object(let options) = given[2], case .int(let of)? = options["of"], of > 0 {
                        stepTotal = Int(of)
                    }
                case "expect" where given.first != .bool(true):
                    return mark("expect_failed", "Expected: \(text(1).prefix(400)). It was not so.")
                case "expect_fail":
                    guard expectFail == nil else {
                        return mark("expect_fail_nested", "app.expect_fail can't be nested; each one wraps one call.")
                    }
                    expectFail = text(0); expectFailSeen = false; expectFailMatched = false
                case "decide":
                    let data = given.count > 1 ? given[1] : .null
                    do {
                        if let value = try await host.decide(text(0), data: data) {
                            row["call"] = .string("app.decide")
                            row["status"] = .string("answered")
                            row["effects"] = .string("none")
                            append(.object(row))
                            return answer(["ok": .bool(true), "value": value])
                        }
                    } catch { return mark("fixture_mismatch", error.localizedDescription) }
                    let bytes = (try? data.serialize(pretty: false)) ?? ""
                    decideData = bytes.utf8.count <= OwnedProgramRunner.logLimit ? data : .string(String(bytes.prefix(OwnedProgramRunner.logLimit)))
                    return mark("decide", String(text(0).prefix(400)))
                default: break
                }
                return answer(["ok": .bool(true), "value": .null])
            }
            // The one call an expect_fail declared: its failure with that
            // code, having changed nothing (effects none), does not stop a
            // strict run; anything else does. A second call inside it does not run.
            if expectFail != nil, expectFailSeen {
                return halt("expect_fail_one_call", "app.expect_fail wraps one app call; this second one did not run.",
                            call: kind == "action" ? id : kind)
            }
            let expected = expectFail
            if expected != nil { expectFailSeen = true }
            /// Strict: a failure stops the run, unless it is the declared one.
            func latch(_ reason: String, _ detail: String, call name: String, receipt: JSONValue? = nil) -> String? {
                guard strict, !(reason == expected && row["effects"] == .string("none")) else { return nil }
                return stopCall(reason, detail, call: name, receipt: receipt)
            }
            func stopCall(_ reason: String, _ detail: String, call name: String, receipt: JSONValue?) -> String {
                stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                           "reason": .string(reason), "detail": .string(detail)]
                if case .object(let fields)? = receipt {
                    for key in ["nearest", "remedy", "argument_path"] { stopped?[key] = fields[key] }
                }
                var fields: [String: JSONValue] = ["ok": .bool(false), "reason": .string(reason), "detail": .string(detail),
                                                   "stopped": .bool(true)]
                if let receipt { fields["receipt"] = receipt }
                return answer(fields)
            }

            if isCancelled {
                return halt("cancelled", "The turn was stopped, so no app call runs from here.", call: kind == "action" ? id : kind)
            }
            var input: [String: JSONValue]
            let name: String
            switch kind {
            case "primitive":
                name = id
                guard let primitive = host.primitiveAction(id), given.count == 1 else {
                    return halt("unsupported", "This host does not admit primitive \(id) with these arguments.", call: name)
                }
                guard tool || actions < OwnedProgramRunner.actionLimit else {
                    return halt("action_limit", "A script does at most \(OwnedProgramRunner.actionLimit) actions.", call: name)
                }
                actions += 1
                row["read_only"] = .bool(primitive.readOnly(named))
                input = [:]
            case "action":
                name = id
                guard tool || actions < OwnedProgramRunner.actionLimit else {
                    return halt("action_limit", "A script does at most \(OwnedProgramRunner.actionLimit) actions.", call: name)
                }
                switch host.doorInput(id: id, given: given) {
                case .success(let built): input = built
                case .failure(let problem):
                    row["call"] = .string(name)
                    row["status"] = .string("failed")
                    row["reason"] = .string(problem.reason)
                    row["detail"] = .string(problem.detail)
                    // Refused before it ran: nothing changed.
                    if strict { row["effects"] = .string("none") }
                    if problem.reason == expected { row["expected"] = .bool(true); expectFailMatched = true }
                    append(.object(row))
                    return latch(problem.reason, problem.detail, call: name) ?? refuse(problem.reason, problem.detail, stop: false)
                }
                actions += 1
                if preview { input["preview"] = .bool(true) }
            default:
                row["read_only"] = .bool(true)
                row["effects"] = .string("none")
                let words = given.compactMap(word)
                name = kind == "find" ? "find " + (words.first ?? "") : "read " + words.joined(separator: "/")
                if kind == "read", given.count > 2 {
                    let detail = "app.read takes page and optional item, not extra arguments. Use app.<action>({args}) to select a target. Nothing was read."
                    row["call"] = .string(name)
                    row["status"] = .string("failed")
                    row["reason"] = .string("invalid_args")
                    row["detail"] = .string(detail)
                    row["argument_path"] = .string("app.read.arguments[2]")
                    row["effects"] = .string("none")
                    if expected == "invalid_args" { row["expected"] = .bool(true); expectFailMatched = true }
                    append(.object(row))
                    return latch("invalid_args", detail, call: name) ?? refuse("invalid_args", detail, stop: false)
                }
                guard tool || reads < OwnedProgramRunner.readLimit else {
                    return halt("read_limit", "A script does at most \(OwnedProgramRunner.readLimit) reads.", call: name)
                }
                reads += 1
                input = kind == "find" ? ["find": given.first ?? .null] : ["page": given.first ?? .null]
                if kind == "read", given.count > 1, given[1] != .null { input["item"] = given[1] }
                // A name on home can send or change something (claude.say,
                // desk.4.done): a script reads home, never opens one of its
                // items. The door's own reading decides, and checks the page again.
                input[host.scriptKey] = .bool(true)
                if host.opensHomeItem(input) {
                    let detail = "A home item can send or change something, so a script never opens one. Read home with "
                        + "app.read(\"home\") and open the item yourself."
                    row["call"] = .string(name)
                    row["status"] = .string("failed")
                    row["reason"] = .string("not_scriptable")
                    row["detail"] = .string(detail)
                    if strict { row["effects"] = .string("none") }
                    if expected == "not_scriptable" { row["expected"] = .bool(true); expectFailMatched = true }
                    append(.object(row))
                    return latch("not_scriptable", detail, call: name) ?? refuse("not_scriptable", detail, stop: false)
                }
            }
            row["call"] = .string(name)

            let readContent = ReadContent()
            let receipt: JSONValue = await ReadContent.$current.withValue(readContent) {
                if kind == "primitive" {
                    if preview, write {
                        return .object(["status": .string("preview"), "effects": .string("none"), "result": .null])
                    } else {
                        return await actionsInFlight.primitive(id, arguments: given[0], preview: preview, host: host)
                    }
                } else { return await actionsInFlight.perform(input, host: host) }
            }
            if kind == "primitive" {
                row["effects"] = write ? .string("unknown") : .string("none")
            }
            if strict, !write {
                self.readContent = .string(readContent.digest(receipt))
                readProjections = readContent.projections
            }
            guard !isCancelled, !actionsInFlight.isCancelled else {
                row["status"] = .string("cancelled")
                if write { row["effects"] = .string("unknown") }
                append(.object(row))
                return stopCall("cancelled", "The turn was stopped while this call was running.", call: name, receipt: receipt)
            }

            let receipted = if case .object(let fields) = receipt {
                word(fields["status"]) != nil && ["none", "occurred", "partial", "unknown"].contains(text(fields["effects"]))
                    && (!host.evidence(receipt).successful || fields["result"] != nil)
            } else { false }
            let (outcome, reason, detail): (Outcome, String, String)
            if kind == "primitive", !receipted {
                (outcome, reason, detail) = (.unclear, "not_a_receipt", "The primitive returned no terminal status, effects or result.")
            } else {
                (outcome, reason, detail) = OwnedProgramRunner.classify(receipt, strict: strict || kind == "primitive", write: write, host: host)
            }
            if kind == "action" || kind == "primitive" { record(receipt, into: &row) } else if case .object(let read) = receipt {
                if let version = read["version"] { row["version"] = version }
            }
            switch outcome {
            case .ok, .preview:
                row["status"] = .string(row["captured"] == .bool(true) ? "captured" : outcome == .ok ? "ok" : "preview")
                append(.object(row))
                if outcome == .ok, let code = expected {
                    return stopCall("expected_failure_succeeded",
                        "This call was declared to fail with \(code) (app.expect_fail), but it succeeded. It took effect; the run stopped.",
                        call: name, receipt: receipt)
                }
                return answer(["ok": .bool(true), "value": receipt])
            case .failed:
                row["status"] = .string("failed")
                row["reason"] = .string(reason)
                if !detail.isEmpty { row["detail"] = .string(detail) }
                // A strict run reads what the failure changed before it
                // matches it: a preview changed nothing.
                if strict, case .object(let fields) = receipt {
                    let effects = fields["status"] == .string("preview") ? .string("none") : OwnedProgramRunner.effects(fields)
                    if let effects { row["effects"] = effects }
                }
                if reason == expected, row["effects"] == .string("none") { row["expected"] = .bool(true); expectFailMatched = true }
                append(.object(row))
                if let latched = latch(reason, detail.isEmpty ? reason : detail, call: name, receipt: receipt) { return latched }
                return answer(["ok": .bool(false), "reason": .string(reason), "detail": .string(detail),
                               "stopped": .bool(false), "receipt": receipt])
            case .unclear:
                // Not a clear success is never the failure an expect_fail
                // declared; a write's effects are unknown.
                row["status"] = .string("failed")
                row["reason"] = .string(reason)
                row["detail"] = .string(detail)
                if write { row["effects"] = .string("unknown") }
                append(.object(row))
                return stopCall(reason, detail, call: name, receipt: receipt)
            case .stop:
                let previewed = if case .object(let fields) = receipt { fields["status"] == .string("preview") } else { false }
                row["status"] = .string(reason == "cancelled" ? "not_run" : previewed ? "preview" : "refused")
                row["reason"] = .string(reason)
                if !detail.isEmpty { row["detail"] = .string(detail) }
                append(.object(row))
                stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                           "reason": .string(reason), "detail": .string(detail)]
                if case .object(let fields) = receipt {
                    for key in ["approvalId", "not_run_status", "remedy"] { stopped?[key] = fields[key] }
                }
                return refuse(reason, detail.isEmpty ? reason : detail, stop: true)
            }
        }

        /// What the call changed and what else the app did, kept short; the
        /// script itself got the whole receipt.
        func record(_ receipt: JSONValue, into row: inout [String: JSONValue]) {
            guard case .object(let fields) = receipt else { return }
            for key in ["nearest", "remedy", "argument_path", "irreversible", "effect", "execution", "captured"] { row[key] = fields[key] }
            // Primitive metadata already declared this call's read policy.
            if row["read_only"] == nil { row["read_only"] = fields["read_only"] }
            if let changed = fields["changed"] { row["changed"] = changed }
            // A strict run keeps each call's effects and real ids, however
            // long its result.
            if strict {
                if let effects = OwnedProgramRunner.effects(fields) { row["effects"] = effects }
                let ids = OwnedProgramRunner.returnedIDs(receipt)
                if !ids.isEmpty { row["ids"] = .object(ids) }
            } else {
                // Ordinary scripts need the same small returned facts for
                // later history, even when the result body is too large.
                if let effects = OwnedProgramRunner.effects(fields) { row["effects"] = effects }
                var ids: [String: JSONValue] = [:]
                for key in ["approval_id", "message_id", "run_id", "request_id", "id", "version", "page_version"] {
                    guard let value = host.receiptField(key, in: receipt) else { continue }
                    switch value {
                    case .string(let id) where !id.isEmpty: ids[key] = value
                    case .int: ids[key] = value
                    default: break
                    }
                }
                if !ids.isEmpty { row["ids"] = .object(ids) }
            }
            // Why she did it rides her ledger as it rides a single action's receipt.
            if let given = fields["reason_given"] { row["reason_given"] = given }
            // A preview's word on whether it would card or hand back.
            for key in ["would_card", "approver", "would_hand_back"] where fields[key] != nil { row[key] = fields[key] }
            // A folded tool's answer is its own result, with no door receipt around it.
            if let result = fields["action"] == nil ? receipt : fields["result"] {
                var shown = result
                if case .object(var body) = result {
                    for key in ["status", "trust_mode", "decided_by", "effects", "remedy", "failure_code", "message",
                                "argument_path", "accepted"] { body.removeValue(forKey: key) }
                    shown = .object(body)
                }
                let bytes = (try? shown.serializedData(pretty: false).count) ?? 0
                if bytes <= 600 { row["result"] = shown } else { row["result_bytes"] = .int(Int64(bytes)) }
            }
            if case .object(let effects)? = fields["side_effects"] {
                var seen: [String: JSONValue] = [:]
                if let raised = effects["notes_raised"], raised != .array([]) { seen["notes_raised"] = raised }
                if let knocks = effects["knocks_delivered"], knocks != .int(0) { seen["knocks_delivered"] = knocks }
                if !seen.isEmpty { row["side_effects"] = .object(seen) }
            }
        }

        func receipt() -> JSONValue {
            /// A strict run's call whose effects occurred, failed or not.
            func took(_ fields: [String: JSONValue]) -> Bool {
                journalsCalls && ["occurred", "partial"].contains(text(fields["effects"]))
            }
            /// The action calls whose ledger status is `status`, as "#n line l call";
            /// `changing` leaves out the actions that only read.
            func calls(_ status: String, changing: Bool = false) -> [JSONValue] {
                ledger.compactMap { row -> JSONValue? in
                    guard case .object(let fields) = row,
                          fields["status"] == .string(status) && !(changing && journalsCalls && fields["effects"] == .string("none"))
                              || changing && took(fields),
                          let call = fields["call"].flatMap(word),
                          !(changing && (fields["read_only"] ?? .bool(host.action(call)?.read == true)) == .bool(true)),
                          case .int(let n)? = fields["n"], case .int(let line)? = fields["line"]
                    else { return nil }
                    return .string("#\(n) line \(line) \(call)")
                }
            }
            let landed = calls("ok")
            // Only a landed call that changes something is an effect.
            let changed = calls("ok", changing: true)
            // A call that got no answer may still have landed.
            let unknown = calls("outcome_unknown").compactMap(word)
            // An admitted call whose reply was lost may still have landed.
            let unsure = ledger.compactMap { row -> String? in
                guard case .object(let fields) = row, fields["effects"] == .string("unknown"), case .int(let n)? = fields["n"],
                      case .int(let line)? = fields["line"], let call = fields["call"].flatMap(word)
                else { return nil }
                return "#\(n) line \(line) \(call)"
            }
            let status = stopped != nil ? "stopped" : timedOut ? "timed_out" : error != nil ? "error" : "ok"
            var out: [String: JSONValue] = [
                "status": .string(status),
                "returned": returned,
                "calls": .array(ledger),
                "landed": .array(landed),
                "side_effects_not_observed": .string("Continuations a card wakes, and anything the app does after a call returns."),
            ]
            if preview {
                out["preview"] = .bool(true)
                let card = ledger.contains { if case .object(let fields) = $0 { fields["would_card"] == .bool(true) } else { false } }
                out["would_card"] = .bool(card)
                out["approver"] = card ? .string("owner") : .null
                out["preview_scope"] = .string("calls_reached")
            }
            if let returnedNote { out["returned_note"] = .string(returnedNote) }
            if !log.isEmpty { out["log"] = .array(log.map(JSONValue.string)) }
            if var stopped {
                if refusedAfterStop > 0 { stopped["refused_after"] = .int(Int64(refusedAfterStop)) }
                out["stopped"] = .object(stopped)
            }
            if timedOut {
                out["detail"] = .string("The script ran past \(Int(OwnedProgramRunner.wallSeconds)) seconds and was stopped; "
                    + "the calls listed before that point ran.")
            }
            if let error { out["error"] = .object(error) }
            let partial = journalsCalls && ledger.contains { if case .object(let fields) = $0 { fields["effects"] == .string("partial") } else { false } }
            out["effects"] = .string(!unknown.isEmpty || !unsure.isEmpty ? "unknown" : partial ? "partial"
                : changed.isEmpty ? "none" : "occurred")
            if !changed.isEmpty { out["changed"] = .array(changed) }
            if strict { out["journal"] = .array(journal) }
            if strict {
                out["steps"] = .array(steps.indices.map { i in
                    .object(["label": .string(steps[i].label), "status": .string(i == steps.count - 1 ? status : "ok")])
                })
            }
            if status != "ok" {
                // A stop that is User's is not fixed by trying again: that
                // line is his to do, and the rest may still be hers.
                let stopReason = stopped.flatMap { word($0["reason"]) } ?? ""
                // The code that ended it on the receipt itself (not_scriptable,
                // owners_screen), so failure_code is that code, not tool_failed.
                let code = stopReason.isEmpty ? error.flatMap { word($0["reason"]) } ?? "" : stopReason
                if !code.isEmpty { out["reason"] = .string(code) }
                let users = host.floorReasons.contains(stopReason) || stopReason == "needs_glass"
                let alone = code == "not_scriptable"
                let cardPreview = preview && code == "would_card"
                let cardInstruction = "Preview stopped at a call that would raise the owner's approval card; no card was filed. "
                    + "Run the action outside preview when you want to request their approval."
                let asked = strict && stopReason == "decide"
                let ask = "It stopped to ask you hand_back.question: decide, then do only what is left."
                // The call by its number and what it asked, not its line: a
                // one-line script has every call on line 1.
                let at = stopped ?? error
                let n = at?["n"].flatMap(word)
                let which = n.map { "Call \($0)" + (at?["call"].flatMap(word).map { " (\($0))" } ?? "") }
                    ?? "Line \(at?["line"].flatMap(word) ?? "?")"
                let drop = "\(which) is the owner's (\(stopReason)): drop that call and run the rest if you still want it."
                let own = "\(which) can't run in a script: run it as its own app call, outside the script, "
                    + "and the rest without it."
                let check = (unknown + unsure).joined(separator: ", ")
                    + (unknown.isEmpty ? " ended with its effects unknown" : " got no answer") + ", so whether it took effect is unknown: "
                    + "read the page to check before running it again, then do only what is left."
                // Reads that landed changed nothing.
                let nothing = landed.isEmpty ? "Nothing landed. " : "Nothing changed. "
                out["remedy"] = .object([
                    "kind": .string(users ? "drop_owners_line" : alone ? "run_alone" : asked ? "decide"
                        : cardPreview ? "request_approval" : "read_ledger"),
                    "instruction": .string(changed.isEmpty
                        ? (!unknown.isEmpty || !unsure.isEmpty ? check
                            : users ? nothing + drop : alone ? nothing + own : asked ? nothing + ask
                            : cardPreview ? cardInstruction : nothing + (at?["instruction"].flatMap(word)
                                ?? "Fix what stopped it, then run it again."))
                        : "The calls in \(strict ? "changed" : "landed") took effect; don't run them again. "
                            + (!unknown.isEmpty || !unsure.isEmpty ? check : users ? drop : alone ? own : asked ? ask
                                : "Read the page, then do only what is left.")),
                    "next_call": .null,
                ])
                if code == "unknown_action", let recovery = at?["remedy"] {
                    out["remedy"] = recovery
                    out["nearest"] = at?["nearest"]
                }
                // A strict run hands back: its step, what landed by real id,
                // and the one question when it asked one.
                if strict {
                    let handed = ledger.compactMap { row -> JSONValue? in
                        guard case .object(let fields) = row, fields["status"] == .string("ok") || took(fields),
                              let call = fields["call"].flatMap(word),
                              !call.hasPrefix("read "), !call.hasPrefix("find ") else { return nil }
                        var item: [String: JSONValue] = ["n": fields["n"] ?? .null, "call": .string(call)]
                        if case .object(let ids)? = fields["ids"] { item.merge(ids) { own, _ in own } }
                        return .object(item)
                    }
                    var back: [String: JSONValue] = ["reason": .string(code.isEmpty ? status : code), "landed": .array(handed)]
                    if let step = steps.last {
                        let total = stepTotal.flatMap { $0 >= steps.count ? $0 : nil }
                        back["step"] = .string(total.map { "\(steps.count) of \($0)" } ?? "step \(steps.count)")
                        back["label"] = .string(step.label)
                        if !step.guidance.isEmpty { back["guidance"] = .string(step.guidance) }
                    }
                    if asked {
                        back["question"] = stopped?["detail"] ?? .null
                        if decideData != .null { back["data"] = decideData }
                    }
                    out["hand_back"] = .object(back)
                }
            }
            return .object(out)
        }
    }

    /// The `app` object the script sees. Its only native calls are `__call`
    /// and `__log`, captured here and then removed from the global object.
    /// A strict run's adds `expect`, `expect_fail`, `decide` and `step`, and
    /// an unknown action name reaches the door, so it fails as unknown_action.
    /// With `input`, the frozen `input` is parsed from its native binding.
    public static func prelude(ids: String, strict: Bool = false, input: Bool = false, primitives: Bool = false) -> String {
        let marks = !strict ? "" : """
            ,
                expect: function (ok, what) { invoke("expect", "", [!!ok, String(what)]); },
                expect_fail: function (code, act) {
                  invoke("expect_fail", "", [String(code)]);
                  var caught = null, promised = false;
                  try { var back = act(); promised = !!back && typeof back.then === "function"; } catch (e) { caught = e; }
                  invoke("expect_fail_end", "", [promised]);
                  if (caught && (caught.name !== "AppError" || caught.reason !== code || caught.stopped)) throw caught;
                  return caught;
                },
                decide: function (question, data) { return invoke("decide", "", [String(question), data === undefined ? null : data]); },
                step: function (label, guidance, options) {
                  invoke("step", "", [String(label), guidance === undefined ? "" : String(guidance), options === undefined ? null : options]);
                }
            """
        let unknown = """

              function named(space, base) {
                return new Proxy(base, { get: function (t, key) {
                  if (typeof key !== "string" || key in t) return t[key];
                  if (key in api) return api[key];
                  return function () { return invoke("action", space + "." + key, Array.prototype.slice.call(arguments)); };
                } });
              }
              Object.keys(api).forEach(function (key) { if (typeof api[key] === "object") api[key] = named(key, api[key]); });
              return new Proxy(Object.freeze(api), { get: function (t, key) {
                if (typeof key !== "string" || key in t) return t[key];
                if (key.indexOf(".") >= 0) return function () { return invoke("action", key, Array.prototype.slice.call(arguments)); };
                return named(key, Object.freeze({}));
              } });
            """
        let frozen = !input ? "" : """

            Object.defineProperty(this, "input", { value: (function freeze(v) {
              if (v && typeof v === "object") { Object.keys(v).forEach(function (k) { freeze(v[k]); }); Object.freeze(v); }
              return v;
            })(JSON.parse(__input)), writable: false, configurable: false, enumerable: true });
            Object.defineProperty(this, "args", { value: input, writable: false, configurable: false, enumerable: true });
            """
        let host = !primitives ? "" : """
          function primitive(operation, args) {
            return invoke("primitive", operation, [args === undefined ? null : args]).result;
          }
          function primitives(space) {
            return Object.freeze(new Proxy({}, {get: function (_, operation) {
              if (typeof operation !== "string") return undefined;
              return function (args) { return primitive(space + "." + operation, args); };
            }}));
          }
          Object.defineProperty(globalThis, "host", {value: Object.freeze({call: primitive,
            paths: Object.freeze({home: __home, workspace: __workspace}),
            files: primitives("files"), network: primitives("network"), apps: primitives("apps")}), writable: false, configurable: false});
        """
        return """
        var app = (function (ids, call, say) {
          function where() {
            var m = (new Error().stack || "").match(/app-script\\.js:(\\d+):\\d+/);
            return m ? +m[1] : 0;
          }
          function invoke(kind, id, args) {
            var reply = JSON.parse(call("app_call", JSON.stringify({kind: kind, action: id, args: JSON.stringify(args), line: where()})));
            if (reply.failure) { var fault = new Error(reply.failure.message); fault.reason = reply.failure.code; throw fault; }
            var out = JSON.parse(reply.value);
            if (out.ok) return out.value;
            var e = new Error(out.detail);
            e.name = "AppError"; e.reason = out.reason; e.action = id; e.stopped = out.stopped;
            e.scriptLine = out.line; e.callNumber = out.n; e.receipt = out.receipt;
            throw e;
          }
          \(host)
          var api = {
            call: function (id) { return invoke("action", id, Array.prototype.slice.call(arguments, 1)); },
            read: function () { return invoke("read", "", Array.prototype.slice.call(arguments)); },
            find: function (words) { return invoke("find", "", [words]); },
            log: function () {
              say(Array.prototype.map.call(arguments, function (a) {
                return typeof a === "string" ? a : JSON.stringify(a);
              }).join(" "));
            }\(marks)
          };
          ids.forEach(function (id) {
            var dot = id.indexOf("."), space = id.slice(0, dot);
            api[space] = api[space] || {};
            api[id] = api[space][id.slice(dot + 1)] = function () {
              return invoke("action", id, Array.prototype.slice.call(arguments));
            };
          });
          Object.keys(api).forEach(function (key) { Object.freeze(api[key]); });\(unknown)
          return Object.freeze(api);
        })(\(ids), __call, __log);\(frozen)
        """
    }
}

/// Pipe callbacks own framing only. The request's task owns interpretation and
/// door execution; no Trust context is borrowed from a previous live read.
final class OwnedProgramProcess: @unchecked Sendable {
    enum Event: Sendable { case line(Data), ended(String) }
    let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "nativeagent.program.stdin")
    private var writeSource: DispatchSourceWrite?
    private var writeBuffer = Data()
    private var writeOffset = 0
    private var writerAwake = false
    private var writerClosed = false
    private var buffered = Data()
    private var stderr = Data()
    private var stopping = false
    private var tree: ProcessTreeSnapshot?
    private let scratch: URL
    private let onFailure: @Sendable (SenseFailure) -> Void
    private var terminalFailure: SenseFailure?
    private var execution: (id: Int, kind: OwnedProgram.Kind, seconds: Double, last: ContinuousClock.Instant)?
    private var deadlineTask: Task<Void, Never>?
    private var resources: Task<Void, Never>?
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var failure: SenseFailure? { lock.withLock { terminalFailure } }

    func processIdentities() -> [ProcessTreeIdentity] {
        lock.lock(); defer { lock.unlock() }
        let snapshot = ProcessTreeReaper.snapshot(rootPID: pid, retaining: tree)
        tree = snapshot
        return snapshot.descendants + (snapshot.rootIdentity.map { [$0] } ?? [])
    }

    init(helper: URL, profile: String, scratch: URL, memoryBytes: UInt64? = nil,
         onFailure: @escaping @Sendable (SenseFailure) -> Void = { _ in }) throws {
        self.scratch = scratch; self.onFailure = onFailure
        (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(128))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, helper.path, "--scratch", scratch.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": scratch.path, "TMPDIR": scratch.path]
        process.currentDirectoryURL = scratch
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            lock.lock(); stderr.append(data); stderr = Data(stderr.suffix(4_096)); lock.unlock()
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        // Keep the transport alive until the child is reaped, even if its
        // runner has already retired the slot. Break the retain on real exit.
        process.terminationHandler = { [self] process in
            process.terminationHandler = nil
            lock.lock()
            let tail = String(decoding: stderr, as: UTF8.self)
            if !stopping {
                let failure = SenseFailure(code: "crashed", message: "Program helper exited (\(process.terminationStatus)): \(tail)")
                terminalFailure = failure; onFailure(failure)
                stopping = true; execution = nil
            }
            if let tree {
                _ = ProcessTreeReaper.quiesceAndKill(ProcessTreeReaper.snapshot(rootPID: pid, retaining: tree))
            }
            lock.unlock()
            sink.yield(.ended("Sense helper at \(helper.path) exited (\(process.terminationStatus)): \(tail) Repair the app installation or sense source, then switch the sense on to retry."))
            sink.finish()
            lock.withLock { deadlineTask?.cancel(); resources?.cancel() }
            writeQueue.sync { closeWriter() }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        do {
            let fd = input.fileHandleForWriting.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                throw SenseFailure(code: "spawn_failed", message: "Sense helper stdin could not be made nonblocking.")
            }
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: writeQueue)
            source.setEventHandler { [weak self] in self?.drainWrites() }
            source.setCancelHandler { [input] in try? input.fileHandleForWriting.close() }
            writeSource = source
            try process.run()
            ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(pid)
            lock.lock(); tree = ProcessTreeReaper.snapshot(rootPID: pid); lock.unlock()
            if let memoryBytes { resources = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    var memory: UInt64 = 0
                    var accounted = false
                    for identity in self.processIdentities() {
                        var info = proc_taskinfo()
                        let size = Int32(MemoryLayout<proc_taskinfo>.size)
                        guard proc_pidinfo(identity.pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
                        memory += info.pti_resident_size; accounted = true
                    }
                    if !accounted {
                        if self.isRunning { self.fail(SenseFailure(code: "resource_limit", message: "Sense helper resource accounting is unavailable.")) }
                        return
                    }
                    if memory > memoryBytes {
                        self.fail(SenseFailure(code: "resource_limit", message: "Sense helper exceeded its memory cap.")); return
                    }
                }
            } }
        }
        catch {
            process.terminationHandler = nil
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            writeQueue.sync { closeWriter() }
            sink.finish()
            throw SenseFailure(code: "spawn_failed", message: "Sense helper at \(helper.path) could not launch: \(error.localizedDescription) Repair the app installation or macOS execution permissions, then switch the sense on to retry.")
        }
    }

    func send(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        guard data.count <= 24 * 1_024 * 1_024 else { throw SenseFailure(code: "input_limit", message: "Sense material exceeds the helper input limit.") }
        data.append(0x0a)
        try writeQueue.sync {
            guard !writerClosed else { throw SenseFailure(code: "crashed", message: "Sense helper stdin is closed.") }
            guard writeBuffer.count - writeOffset + data.count <= 24 * 1_024 * 1_024 + 1 else {
                throw SenseFailure(code: "input_limit", message: "Sense helper exceeded its input queue limit.")
            }
            if writeOffset > 0 { writeBuffer.removeFirst(writeOffset); writeOffset = 0 }
            writeBuffer.append(data)
            if !writerAwake { writerAwake = true; writeSource?.resume() }
        }
    }

    private func drainWrites() {
        guard !writerClosed else { return }
        while writeOffset < writeBuffer.count {
            let count = writeBuffer.withUnsafeBytes { bytes in
                Darwin.write(input.fileHandleForWriting.fileDescriptor,
                    bytes.baseAddress!.advanced(by: writeOffset), bytes.count - writeOffset)
            }
            if count > 0 { writeOffset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            onFailure(SenseFailure(code: "crashed", message: "Sense helper stdin write failed."))
            sink.yield(.ended("Sense helper stdin write failed.")); sink.finish()
            closeWriter(); return
        }
        writeBuffer.removeAll(keepingCapacity: true); writeOffset = 0
        writerAwake = false; writeSource?.suspend()
    }

    private func closeWriter() {
        guard !writerClosed else { return }
        writerClosed = true
        if !writerAwake { writeSource?.resume(); writerAwake = true }
        writeSource?.cancel(); writeSource = nil
        writeBuffer.removeAll()
    }

    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.isEmpty { output.fileHandleForReading.readabilityHandler = nil; return }
        buffered.append(data)
        while let newline = buffered.firstIndex(of: 0x0a) {
            let line = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
            if line.count > 24 * 1_024 * 1_024 {
                failLocked(SenseFailure(code: "output_limit", message: "Sense helper exceeded its output line limit.")); return
            }
            if case .dropped = sink.yield(.line(line)) {
                failLocked(SenseFailure(code: "output_limit", message: "Program helper exceeded its pending message limit.")); return
            }
        }
        if buffered.count > 24 * 1_024 * 1_024 {
            failLocked(SenseFailure(code: "output_limit", message: "Sense helper exceeded its output line limit."))
        }
    }

    func begin(id: Int, kind: OwnedProgram.Kind, seconds: Double) {
        lock.withLock {
            execution = (id, kind, seconds, .now)
            armDeadlineLocked()
        }
    }

    func renewProgress(_ id: Int) throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard !stopping, execution?.id == id, execution?.kind == .sense else { throw CancellationError() }
            execution?.last = .now
        }
    }

    func suspend(_ id: Int) throws -> ContinuousClock.Instant {
        try lock.withLock {
            guard !stopping, execution?.id == id else { throw CancellationError() }
            if execution?.kind != .tool { deadlineTask?.cancel() }
            return .now
        }
    }

    func resume(_ id: Int, since started: ContinuousClock.Instant) throws {
        try lock.withLock {
            guard !stopping, var current = execution, current.id == id else { throw CancellationError() }
            if current.kind != .tool {
                current.last = current.last.advanced(by: max(current.last, started).duration(to: .now))
                execution = current
                armDeadlineLocked()
            }
        }
    }

    func end(_ id: Int) {
        lock.withLock {
            guard execution?.id == id else { return }
            execution = nil; deadlineTask?.cancel(); deadlineTask = nil
        }
    }

    func claimCompletion(_ id: Int) throws {
        try lock.withLock {
            if let terminalFailure { throw terminalFailure }
            guard !stopping, execution?.id == id else { throw CancellationError() }
            execution = nil; deadlineTask?.cancel(); deadlineTask = nil
        }
    }

    private func armDeadlineLocked() {
        deadlineTask?.cancel()
        guard let id = execution?.id else { return }
        deadlineTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let deadline = self?.lock.withLock({ () -> ContinuousClock.Instant? in
                    guard let current = self?.execution, current.id == id, self?.stopping == false else { return nil }
                    return current.last.advanced(by: .seconds(current.seconds))
                }) else { return }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard !Task.isCancelled else { return }
                self?.lock.withLock {
                    guard !Task.isCancelled, let current = self?.execution, current.id == id,
                          ContinuousClock.now >= current.last.advanced(by: .seconds(current.seconds)) else { return }
                    self?.failLocked(SenseFailure(code: "timeout", message: current.kind == .sense
                        ? "Sense helper stalled without progress." : "Owned program exceeded its execution window."))
                }
            }
        }
    }

    private func fail(_ failure: SenseFailure) {
        lock.withLock { failLocked(failure) }
    }

    private func failLocked(_ failure: SenseFailure) {
        guard !stopping else { return }
        terminalFailure = failure
        onFailure(failure)
        if let id = execution?.id,
           let data = try? JSONEncoder().encode(JSONValue.object([
                "id": .int(Int64(id)), "type": .string("failed"),
                "failure": (try? JSONValue.fromEncodable(failure)) ?? .null])) {
            sink.yield(.line(data))
        }
        stopLocked()
    }

    func stop() { lock.lock(); defer { lock.unlock() }; stopLocked() }

    private func stopLocked() {
        guard !stopping else { return }
        stopping = true
        deadlineTask?.cancel(); resources?.cancel(); execution = nil
        sink.finish()
        // Swift senses may have a compiler/runtime child. Freeze and kill the
        // identity-checked tree, including observed descendants after a crash.
        let snapshot = ProcessTreeReaper.snapshot(rootPID: pid, retaining: tree)
        tree = ProcessTreeReaper.quiesceAndKill(snapshot)
        writeQueue.sync { closeWriter() }
    }
}

private func word(_ raw: JSONValue?) -> String? {
    switch raw {
    case .string(let value): return value
    case .int(let value): return String(value)
    case .double(let value): return String(value)
    case .bool(let value): return value ? "true" : "false"
    default: return nil
    }
}

private func text(_ value: JSONValue?) -> String {
    word(value)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

