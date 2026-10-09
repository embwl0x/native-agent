import ChatOrchestration
import Foundation
import JavaScriptCore
import MacControl
import PersistenceCore
import Privacy
import TrustCenter

/// `app {script}` (one-door step 2): JavaScript against an `app.*` API
/// generated from the registry, `app.<page>.<action>(args)` for every action
/// id, plus `app.read`, `app.find` and `app.log`. The context is fresh per
/// script and has no network, file system, process or timers; its one way out
/// is `__call`, and every call goes back through the door's own path
/// (`perform`, which re-enters the whole gate chain as `app`), so a script can
/// do nothing a single action could not.
///
/// A call that is User's, refused by a gate or posture, or that files a card
/// stops the script: the error it throws can be caught, but every later call
/// is refused (the latch). Ordinary failures throw an `AppError` the script
/// may catch and carry on from. Every call is one ledger row.
///
/// A strict run (a skill's) stops on any failure the script did not declare
/// with `app.expect_fail`, on a false `app.expect` and at `app.decide`, and
/// hands back with its step, what landed by real id, and the one question.
enum AppScriptRunner {
    static let sourceLimit = 8 * 1024
    static let actionLimit = 50
    static let readLimit = 100
    static let wallSeconds = 60.0
    static let returnLimit = 16 * 1024
    static let logLimit = 2 * 1024
    static let inputLimit = 16 * 1024
    static let stepLimit = 50

    /// JSC's own watchdog, the only thing that stops a `while(true){}`. It is
    /// SPI, so it is found by name when first needed: a macOS without it
    /// refuses scripts, and the app still launches. It counts only time spent
    /// running JavaScript, so it fires every quarter second of that and asks
    /// `pastDeadline`, which ends the script once the wall clock is spent.
    /// JSC asks once: answering false disarms it, so the callback re-arms
    /// itself first or a `while(true){}` runs on forever.
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private static let pastDeadline: ShouldTerminate = { context, deadline in
        guard let deadline, let context, let setTimeLimit = AppScriptRunner.setTimeLimit,
              let group = JSContextGetGroup(JSContextGetGlobalContext(context)) else { return true }
        if Date().timeIntervalSinceReferenceDate >= deadline.load(as: Double.self) { return true }
        setTimeLimit(group, 0.25, AppScriptRunner.pastDeadline, deadline)
        return false
    }
    private static let setTimeLimit: SetTimeLimit? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit")
            .map { unsafeBitCast($0, to: SetTimeLimit.self) }

    private static let scriptURL = URL(string: "app-script.js")
    private static let preludeURL = URL(string: "app-prelude.js")

    typealias Perform = @Sendable ([String: JSONValue]) async -> JSONValue

    /// One call the script made, carried to the caller's task and answered.
    private struct Job: Sendable {
        let input: [String: JSONValue]
        let reply: Reply
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var value: JSONValue?
        let done = DispatchSemaphore(value: 0)
        func put(_ result: JSONValue) {
            let stored = lock.withLock {
                guard value == nil else { return false }
                value = result
                return true
            }
            if stored { done.signal() }
        }
        func take() -> JSONValue? { lock.withLock { value } }
        func cancel() {
            put(.object([
                "status": .string("failed"), "reason": .string("cancelled"),
                "not_run_status": .string("cancelled"),
                "detail": .string("The turn was stopped while this call was running."),
            ]))
        }
    }

    private final class ActionTasks: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [UUID: (task: Task<Void, Never>, reply: Reply)] = [:]
        private var cancelled = false

        func start(_ job: Job, perform: @escaping Perform) {
            lock.withLock {
                guard !cancelled else { job.reply.cancel(); return }
                let id = UUID()
                let task = Task {
                    defer { _ = self.lock.withLock { self.tasks.removeValue(forKey: id) } }
                    guard !Task.isCancelled else { job.reply.cancel(); return }
                    job.reply.put(await perform(job.input))
                }
                tasks[id] = (task, job.reply)
            }
        }

        func cancel() {
            let active = lock.withLock {
                cancelled = true
                return Array(tasks.values)
            }
            for action in active { action.task.cancel(); action.reply.cancel() }
        }
    }

    /// Runs `source` and returns the combined receipt. Calls are performed in
    /// the caller's task context (its task-locals carry the gates' session and
    /// turn), one at a time, while the script's thread waits.
    /// `strict` and `input` are a skill run's: `input` is JSON the script
    /// reads as a frozen `input`, bound natively and never pasted into source.
    /// `replay` resumes a stopped one (`Replay`). A strict receipt carries its
    /// `journal`, the calls to replay, which the caller keeps and never shows.
    static func run(source: String, preview: Bool, strict: Bool = false, input: JSONValue? = nil,
                    replay: Replay? = nil, perform: @escaping Perform) async -> JSONValue {
        guard source.utf8.count <= sourceLimit else {
            return AppToolExecutor.doorRefusal("script_too_long",
                "The script is \(source.utf8.count) bytes; the limit is \(sourceLimit). Nothing ran.",
                remedy: "shorten", "Split it, or read first and act in a shorter script.")
        }
        guard let setTimeLimit else {
            return AppToolExecutor.doorRefusal("script_unavailable",
                "This macOS has no way to stop a runaway script, so scripts don't run here. Nothing ran.",
                remedy: "use_actions", "Do the same with single actions: app {action, args}.")
        }
        var inputJSON: String?
        if let input {
            guard case .object = input, let text = try? input.serialize(pretty: false), text.utf8.count <= inputLimit else {
                return AppToolExecutor.doorRefusal("invalid_input",
                    "A script's input is one JSON object of at most \(inputLimit) bytes. Nothing ran.",
                    remedy: "correct_arguments", "Pass the input as one smaller object.")
            }
            if let path = secretPath(input) {
                return AppToolExecutor.doorRefusal("secret_in_input",
                    "\(path) carries a key or token, and a script's input never does. Nothing ran.",
                    remedy: "use_actions", "Pass a key as a single app action, not in a script.")
            }
            inputJSON = text
        }
        let (jobs, feed) = AsyncStream<Job>.makeStream()
        let script = Script(source: source, preview: preview, strict: strict, inputJSON: inputJSON,
                            replay: replay, setTimeLimit: setTimeLimit) { input in
            let job = Job(input: input, reply: Reply())
            // The turn stopped and nothing serves calls any more: this one
            // never runs, and says so at once instead of waiting it out.
            if case .terminated = feed.yield(job) {
                job.reply.put(.object([
                    "status": .string("failed"), "reason": .string("cancelled"), "effects": .string("none"),
                    "not_run_status": .string("cancelled"),
                    "detail": .string("The turn was stopped, so this call did not run."),
                ]))
            }
            return job.reply
        }
        let thread = Thread {
            script.evaluate()
            feed.finish()
            script.markFinished()
        }
        thread.stackSize = 4 << 20
        let actions = ActionTasks()
        return await withTaskCancellationHandler {
            defer { actions.cancel() }
            thread.start()
            // Admitted actions keep their provider/turn budget. Stop cancels
            // the action and wakes the script's blocked reply wait.
            for await job in jobs {
                actions.start(job, perform: perform)
            }
            if Task.isCancelled { script.cancel() }
            await script.finished()
            return script.receipt()
        } onCancel: {
            actions.cancel()
            script.cancel()
            feed.finish()
        }
    }

    // MARK: - Classifying one call's receipt

    /// `unclear`: a strict run's receipt that is not a clear success
    /// (`strictFault`); a write's effects are then unknown.
    enum Outcome { case ok, preview, failed, stop, unclear }

    /// `strict` (a skill's run) is exact, by `strictFault`'s one rule.
    static func classify(_ receipt: JSONValue, strict: Bool = false, write: Bool = false)
        -> (outcome: Outcome, reason: String, detail: String) {
        guard case .object(let fields) = receipt else {
            guard strict, write else { return (.ok, "", "") }
            return (.unclear, "not_a_receipt", "It answered with no receipt, so whether it took effect can't be told.")
        }
        let inner: [String: JSONValue] = if case .object(let result)? = fields["result"] { result } else { [:] }
        func text(_ key: String) -> String {
            [fields[key], inner[key]].lazy.compactMap { AppToolExecutor.inputString($0) }
                .first { !$0.isEmpty } ?? ""
        }
        let detail = String(text("detail").prefix(400))
        let waiting = text("not_run_status")
        if !waiting.isEmpty || ChatToolOutcome.isWaitingOnPerson(receipt)
            || ChatToolOutcome.isWaitingOnPerson(fields["result"] ?? .null) {
            return (.stop, waiting.isEmpty ? "waiting_on_user" : waiting, detail)
        }
        // A preview that would refuse classifies as that refusal would.
        if fields["status"] == .string("preview") {
            let refused = text("would_refuse")
            if fields["owner"] == .string("his") { return (.stop, refused.isEmpty ? "users_call" : refused, detail) }
            if fields["would_card"] == .bool(true) { return (.stop, "would_card", detail) }
            return refused.isEmpty ? (.preview, "", detail) : (.failed, refused, detail)
        }
        if fields["status"] == .string("did_not_stick") { return (.failed, "did_not_stick", detail) }
        // A card only User can answer, on the glass: nothing was answered.
        if fields["status"] == .string("needs_glass") { return (.stop, "needs_glass", String(text("reason").prefix(400))) }
        if ChatToolOutcome.outputLooksSuccessful(receipt) {
            guard strict, let fault = strictFault(fields, write: write) else { return (.ok, "", detail) }
            return (.unclear, fault, detail.isEmpty ? "Its receipt is not a clear success (\(fault))." : detail)
        }
        let reason = [text("reason"), text("failure_code")].first { !$0.isEmpty && !$0.contains(" ") } ?? "failed"
        return (AppToolExecutor.doorFloorReasons.contains(reason) ? .stop : .failed, reason, detail)
    }

    /// A strict run's one rule, all the way down a receipt's `result`s. A
    /// write is a success only when its receipt says terminal success, and
    /// nothing under it says otherwise. A read may return any data, but no
    /// failure, status that is not final, dry run, or unknown or partial
    /// effects. Nil when it passes.
    static func strictFault(_ fields: [String: JSONValue], write: Bool) -> String? {
        for (depth, at) in resultChain(fields).enumerated() {
            let outcome = ChatToolOutcome.exactResultClass(.object(at))
            let status = AppToolExecutor.doorText(at["status"]).lowercased()
            let reason = AppToolExecutor.doorText(at["reason"])
            let effects = AppToolExecutor.doorText(at["effects"])
            if [.failed, .timeout, .cancelled].contains(outcome) {
                return reason.isEmpty || reason.contains(" ") ? "failed" : reason
            }
            if ChatToolOutcome.pendingStatuses.contains(status) { return "status_\(status)" }
            if at["dry_run"] == .bool(true) || at["dryRun"] == .bool(true) { return "dry_run" }
            if ["unknown", "partial"].contains(effects) { return "effects_\(effects)" }
            if let mac = MacControlReceiptOutcome.projecting(envelope: .object(at)), [.running, .effectUnconfirmed].contains(mac) {
                return "effect_unconfirmed"
            }
            guard write, outcome != .succeeded, depth == 0 || !status.isEmpty else { continue }
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
        let said = resultChain(fields).map { AppToolExecutor.doorText($0["effects"]) }.filter { !$0.isEmpty }
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

    /// The first place a script's input carries a key or token: a field
    /// named as one, or a value shaped like one.
    static func secretPath(_ value: JSONValue, at path: String = "input") -> String? {
        switch value {
        case .string(let text): return NativeAgentSecretRedactor.redactText(text) == text ? nil : path
        case .array(let list): return list.indices.lazy.compactMap { secretPath(list[$0], at: "\(path)[\($0)]") }.first
        case .object(let fields):
            return fields.keys.sorted().lazy.compactMap { key -> String? in
                if ["api_key", "apikey", "token", "access_token", "refresh_token", "password", "passphrase", "secret",
                    "client_secret", "private_key", "authorization", "cookie", "credential", "credentials", "bearer"]
                    .contains(key.lowercased()), fields[key] != .null { return "\(path).\(key)" }
                return secretPath(fields[key] ?? .null, at: "\(path).\(key)")
            }.first
        default: return nil
        }
    }

    /// Door args from a script call: one object is the args by name (a second
    /// object carries expected_version or preview); anything else is
    /// positional, in the order the action's line declares.
    static func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], ScriptError> {
        guard let action = AppActions.action(id) ?? AppActions.pagePrefixedAction(id) else {
            // Let the door return its exact nearest-action recovery; it executes no unknown action.
            return .success(["action": .string(id), "args": given.first ?? .object([:]),
                             AppToolExecutor.doorScriptKey: .bool(true)])
        }
        guard action.scriptable else {
            return .failure(ScriptError(reason: "not_scriptable",
                detail: "\(action.id) runs only as a single app action, not in a script; it was not run."))
        }
        var input: [String: JSONValue] = ["action": .string(action.id)]
        if case .object(let named)? = given.first {
            input["args"] = .object(named)
            if let refusal = secretRefusal(action, named) { return .failure(refusal) }
            if given.count > 1, case .object(let options) = given[1] {
                if let stray = options.keys.first(where: { !["expected_version", "preview"].contains($0) }) {
                    return .failure(ScriptError(reason: "unknown_option",
                        detail: "The second object takes expected_version or preview, not \(stray)."))
                }
                input.merge(options) { _, new in new }
            }
            return .success(input)
        }
        var positional = given
        while positional.last == .null { positional.removeLast() }
        let specs = action.argSpecs
        guard positional.count <= specs.count else {
            return .failure(ScriptError(reason: "invalid_args", detail: "\(action.id) takes \(specs.count) args: \(action.line)"))
        }
        var args: [String: JSONValue] = [:]
        for (value, spec) in zip(positional, specs) where value != .null {
            let isList = if case .array = value { true } else { false }
            args[spec.names.count > 1 ? (isList ? spec.names[0] : spec.names[spec.names.count - 1]) : spec.names[0]] = value
        }
        input["args"] = .object(args)
        if let refusal = secretRefusal(action, args) { return .failure(refusal) }
        return .success(input)
    }

    /// A key or token never rides a script: its source is kept, so the key
    /// goes in a single app action, whose args are redacted.
    private static func secretRefusal(_ action: AppAction, _ args: [String: JSONValue]) -> ScriptError? {
        guard action.secretArgs.contains(where: { args[$0].map { $0 != .null && $0 != .string("") } ?? false })
        else { return nil }
        return ScriptError(reason: "secret_in_script",
            detail: "Pass a key as a single app action, not in a script: \(action.id) was not run.")
    }

    struct ScriptError: Error {
        let reason: String
        let detail: String
    }

    /// A stopped skill run, resumed: the script runs again from the top, and
    /// each call the stopped run made is answered from `journal`, in order,
    /// without running again; the one it stopped at (its decide, or the step
    /// it handed back) returns `answer`. A call that differs from the
    /// journal's stops the run there, before it runs.
    struct Replay: Sendable {
        let journal: [JSONValue]
        let answer: JSONValue
    }

    /// A read's answer without its place in the run (n, line).
    static func readValue(_ out: String) -> JSONValue {
        guard case .object(var fields)? = try? JSONValue.parse(Data(out.utf8)) else { return .string(out) }
        for key in ["n", "line"] { fields.removeValue(forKey: key) }
        return fields["value"] ?? .object(fields)
    }

    /// The same read: by version when both carry one, else with fresh
    /// times left out (a key ending _at, and ago, age, now), all the way down.
    static func sameRead(_ a: String, _ b: String) -> Bool {
        let (was, now) = (readValue(a), readValue(b))
        if case .object(let x) = was, case .object(let y) = now, let v = x["version"], let w = y["version"] { return v == w }
        func stable(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let fields):
                return .object(fields.filter { !$0.key.hasSuffix("_at") && !["ago", "age", "now"].contains($0.key) }
                    .mapValues(stable))
            case .array(let items): return .array(items.map(stable))
            default: return value
            }
        }
        return stable(was) == stable(now)
    }

    /// The versions a strict run's own calls returned, in order, from its
    /// journal: each read's version and each write's page_version.
    static func ownVersions(_ journal: [JSONValue]) -> [String] {
        journal.compactMap { entry -> String? in
            guard case .object(let fields) = entry, case .array(let call)? = fields["call"], let kind = call.first,
                  case .string(let out)? = fields["out"], case .object(let value) = readValue(out) else { return nil }
            return AppToolExecutor.inputString(kind == .string("read") ? value["version"] : value["page_version"])
        }
    }

    /// What a journaled call reads or writes: its page, and the item it names.
    static func target(_ entry: JSONValue) -> (page: String, item: String?, write: Bool)? {
        guard case .object(let fields) = entry, case .array(let call)? = fields["call"], call.count > 2,
              case .string(let kind) = call[0], case .string(let id) = call[1], case .string(let raw) = call[2] else { return nil }
        let given: [JSONValue] = if case .array(let list)? = try? JSONValue.parse(Data(raw.utf8)) { list } else { [] }
        func word(_ value: JSONValue?) -> String? { AppToolExecutor.inputString(value)?.lowercased() }
        if kind == "read", let page = word(given.first) { return (page, given.count > 1 ? word(given[1]) : nil, false) }
        guard kind == "action", let action = AppActions.action(id) else { return nil }
        let args: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
        guard let page = action.page == "*" ? word(args["page"]) : action.page.lowercased() else { return nil }
        return (page, word(args["handle"]) ?? word(args["id"]) ?? word(args["item"]), !action.readOnly(args: args))
    }

    /// A version's page or page/item.
    static func versionScope(_ version: String) -> String {
        version.split(separator: "@", maxSplits: 1).first.map(String.init) ?? version
    }

    /// A read's answer, short: its version when it has one.
    static func brief(_ out: String) -> JSONValue {
        let value = readValue(out)
        if case .object(let fields) = value, let version = fields["version"] { return version }
        return .string(String(((try? value.serialize(pretty: false)) ?? out).prefix(300)))
    }

    // MARK: - One script

    private final class Script: @unchecked Sendable {
        let source: String
        let lines: [Substring]
        let preview: Bool
        let strict: Bool
        let inputJSON: String?
        let replay: [JSONValue]
        let answer: JSONValue
        let setTimeLimit: SetTimeLimit
        let post: @Sendable ([String: JSONValue]) -> Reply
        var deadline = Date().addingTimeInterval(AppScriptRunner.wallSeconds)
        /// The deadline where the watchdog's C callback can read it.
        let deadlineCell = UnsafeMutablePointer<Double>.allocate(capacity: 1)

        // Touched only on the script's thread until `receipt()`, which runs
        // after that thread has finished.
        var ledger: [JSONValue] = []
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
        /// Where the stopped run's own writes landed, by journal position: a
        /// read it made before one of them on the same page or item replays as
        /// saved, since its own write explains the difference.
        let ownWrites: [(at: Int, page: String, item: String?)]

        private let flags = NSLock()
        private var cancelled = false
        private var done = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var waitingReply: Reply?

        /// Also spends the deadline, so the watchdog ends running JavaScript
        /// within a quarter second.
        func cancel() {
            let reply = flags.withLock {
                cancelled = true
                deadlineCell.pointee = 0
                return waitingReply
            }
            reply?.cancel()
        }
        var isCancelled: Bool { flags.withLock { cancelled } }

        func markFinished() {
            let waiting = flags.withLock { () -> CheckedContinuation<Void, Never>? in
                done = true
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume()
        }

        func finished() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let already = flags.withLock { () -> Bool in
                    if !done { waiter = continuation }
                    return done
                }
                if already { continuation.resume() }
            }
        }

        init(source: String, preview: Bool, strict: Bool, inputJSON: String?, replay: Replay?, setTimeLimit: SetTimeLimit,
             post: @escaping @Sendable ([String: JSONValue]) -> Reply) {
            self.source = source
            self.lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            self.preview = preview
            self.strict = strict
            self.inputJSON = inputJSON
            self.replay = replay?.journal ?? []
            self.answer = replay?.answer ?? .null
            self.ownWrites = (replay?.journal ?? []).enumerated().compactMap { at, entry in
                guard let target = AppScriptRunner.target(entry), target.write, case .object(let fields) = entry,
                      Self.status(fields["row"] ?? .null) == "ok" else { return nil }
                return (at, target.page, target.item)
            }
            self.setTimeLimit = setTimeLimit
            self.post = post
            deadlineCell.initialize(to: deadline.timeIntervalSinceReferenceDate)
        }

        deinit { deadlineCell.deallocate() }

        func evaluate() {
            // An expect_fail the script never closed saw nothing fail as declared.
            defer {
                if strict, stopped == nil, !timedOut, let code = expectFail {
                    stopped = ["reason": .string("expected_failure_not_seen"),
                               "detail": .string("app.expect_fail(\"\(code)\") was never closed, so nothing failed as declared.")]
                }
            }
            guard let context = JSContext(virtualMachine: JSVirtualMachine()),
                  let group = JSContextGetGroup(context.jsGlobalContextRef) else {
                error = ["message": .string("The script engine did not start.")]
                return
            }
            setTimeLimit(group, 0.25, AppScriptRunner.pastDeadline, UnsafeMutableRawPointer(deadlineCell))
            var thrown: JSValue?
            context.exceptionHandler = { _, exception in thrown = exception }

            let call: @convention(block) (String, String, String, Int) -> String = { [unowned self] kind, id, args, line in
                self.call(kind: kind, id: id, args: args, line: line)
            }
            let say: @convention(block) (String) -> Void = { [unowned self] text in
                guard self.logBytes < AppScriptRunner.logLimit else { return }
                let kept = String(text.prefix(AppScriptRunner.logLimit - self.logBytes))
                self.logBytes += kept.utf8.count
                self.log.append(kept)
            }
            context.setObject(call, forKeyedSubscript: "__call" as NSString)
            context.setObject(say, forKeyedSubscript: "__log" as NSString)
            if let inputJSON { context.setObject(inputJSON, forKeyedSubscript: "__input" as NSString) }
            // Her own tools too (app.authored.<id>): a read-only one runs, the rest refuse not_scriptable.
            let ids = (try? JSONValue.array((AppActions.all + AppActions.authored()).map { .string($0.id) })
                .serialize(pretty: false)) ?? "[]"
            context.evaluateScript(AppScriptRunner.prelude(ids: ids, strict: strict, input: inputJSON != nil),
                                   withSourceURL: AppScriptRunner.preludeURL)
            context.globalObject.deleteProperty("__call")
            context.globalObject.deleteProperty("__log")
            if inputJSON != nil { context.globalObject.deleteProperty("__input") }
            if let thrown {
                error = ["message": .string("The script engine did not start: \(thrown)")]
                return
            }

            // Wrapped on the first line, so a line number in the stack is the
            // script's own line; `return` hands a value back.
            let body = context.evaluateScript("(function () {" + source + "\n})", withSourceURL: AppScriptRunner.scriptURL)
            let syntaxError = thrown?.objectForKeyedSubscript("name")?.toString() == "SyntaxError"
            let value = thrown == nil ? body?.call(withArguments: []) : nil
            if let thrown {
                let message = thrown.toString() ?? "error"
                if message.contains("execution terminated") {
                    if !isCancelled { timedOut = true } else if stopped == nil {
                        stopped = ["reason": .string("cancelled"),
                                   "detail": .string("The turn was stopped, so the script was ended.")]
                    }
                } else if stopped == nil {
                    var report: [String: JSONValue] = ["message": .string(String(message.prefix(400)))]
                    if syntaxError {
                        report["reason"] = .string("script_syntax")
                        report["rule"] = .string("javascript_function_body")
                        report["instruction"] = .string("Fix the JavaScript syntax reported in message at line. "
                            + "Top-level await is not supported: app.* calls return synchronously. Use const result = app.read(\"inbox\"); return result; without await.")
                    }
                    // A bare action family (time.now()) is app.time.now() inside a script.
                    if let name = message.range(of: #"(?<=Can't find variable: )\w+"#, options: .regularExpression).map({ String(message[$0]) }),
                       AppActions.all.contains(where: { $0.id.hasPrefix(name + ".") }) {
                        report["reason"] = .string("script_name")
                        report["instruction"] = .string("Inside a script, actions live under app: use app.\(name).… (for example app.\(name).\(AppActions.all.first { $0.id.hasPrefix(name + ".") }.map { String($0.id.dropFirst(name.count + 1)) } ?? "…")()).")
                    }
                    // An app call's refusal keeps its code (not_scriptable).
                    if let reason = thrown.objectForKeyedSubscript("reason"), reason.isString, let code = reason.toString() {
                        report["reason"] = .string(code)
                    }
                    let line = thrown.objectForKeyedSubscript("scriptLine").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
                        ?? thrown.objectForKeyedSubscript("line").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
                    if let line, line > 0 { report["line"] = .int(Int64(line)); report["source"] = sourceLine(line) }
                    // An app call's error names that call too, its source line
                    // redacted or not.
                    if let n = thrown.objectForKeyedSubscript("callNumber").flatMap({ $0.isNumber ? Int($0.toInt32()) : nil }),
                       ledger.indices.contains(n - 1), case .object(let row) = ledger[n - 1] {
                        report["n"] = .int(Int64(n))
                        report["call"] = row["call"] ?? .null
                        for key in ["nearest", "remedy", "argument_path"] { report[key] = row[key] }
                    }
                    error = report
                }
                return
            }
            guard let value, !value.isUndefined else { return }
            let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])
            // A strict run's returned value that is not plain data (a Promise,
            // a function, a toJSON that throws or runs out the clock) ends it there.
            if strict, stopped == nil {
                let promise = context.objectForKeyedSubscript("Promise").map { value.isInstance(of: $0) } ?? false
                let message = thrown?.toString() ?? ""
                if message.contains("execution terminated") {
                    if !isCancelled { timedOut = true } else {
                        stopped = ["reason": .string("cancelled"), "detail": .string("The turn was stopped, so the script was ended.")]
                    }
                    return
                }
                if thrown != nil || promise || json?.isString != true {
                    stopped = ["reason": .string("unreadable_return"), "detail": .string(promise
                        ? "The script returned a Promise; a run returns plain data."
                        : thrown != nil ? "The returned value could not be read: \(message.prefix(300))"
                        : "The returned value has no JSON form (a function or a symbol).")]
                    return
                }
            }
            guard let json, json.isString, let text = json.toString() else { return }
            if text.utf8.count > AppScriptRunner.returnLimit {
                returned = .string(String(text.prefix(AppScriptRunner.returnLimit)))
                returnedNote = "The returned value was \(text.utf8.count) bytes; this is its first \(AppScriptRunner.returnLimit), as text."
            } else {
                returned = (try? JSONValue.parse(Data(text.utf8))) ?? .string(text)
            }
        }

        func sourceLine(_ line: Int) -> JSONValue {
            guard line >= 1, !lines.isEmpty else { return .null }
            let text = lines[min(line, lines.count) - 1].trimmingCharacters(in: .whitespaces)
            // A line that names an action taking a key is never echoed back.
            if MacInjectionArgRedaction.namesAppDoorSecretAction(text) {
                return .string("[redacted: this line names an action that takes a key or token]")
            }
            return .string(String(text.prefix(160)))
        }

        /// One `app.*` call, on the script's thread. A strict run journals each
        /// call that can land or stop, and a resumed one answers them from
        /// its journal (`Replay`).
        func call(kind: String, id: String, args: String, line: Int) -> String {
            let id = kind == "action" ? (AppActions.pagePrefixedAction(id)?.id ?? id) : id
            guard strict, ["action", "read", "find", "decide"].contains(kind), stopped == nil else {
                return dispatch(kind: kind, id: id, args: args, line: line)
            }
            let signature = JSONValue.array([.string(kind), .string(id), .string(args), .int(Int64(line))])
            guard replayed < replay.count else {
                let rows = ledger.count
                let out = dispatch(kind: kind, id: id, args: args, line: line)
                journal.append(.object(["call": signature, "out": .string(out),
                                        "row": ledger.count > rows ? ledger[ledger.count - 1] : .null]))
                return out
            }
            let n = ledger.count + 1
            guard case .object(let entry) = replay[replayed], entry["call"] == signature,
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
            let read = if case .object(let fields) = row, let read = fields["read_only"] { read == .bool(true) }
                else { AppActions.action(id)?.read == true }
            if replayed == replay.count {
                // Where it stopped: her answer, never the call, a read included.
                out = encode(["ok": .bool(true), "value": answer], line: line, n: n)
                if case .object(var fields) = row {
                    for key in ["reason", "detail", "result"] { fields.removeValue(forKey: key) }
                    fields["status"] = .string("answered")
                    row = .object(fields)
                }
            } else if Self.status(row) != "answered",
                      kind == "read" || kind == "find" || (kind == "action" && read),
                      !writtenLater(replay[replayed - 1], at: replayed - 1) {
                // What it read is read again, live: a resume goes on only if it all reads the same.
                // (A read the run itself later wrote over replays as saved, below.)
                let now = dispatch(kind: kind, id: id, args: args, line: line)
                guard stopped == nil, AppScriptRunner.sameRead(now, out) else {
                    let name = kind == "action" ? id : ledger.last.flatMap { if case .object(let row) = $0 { AppToolExecutor.inputString(row["call"]) } else { nil } } ?? kind
                    let detail = "\(name) reads differently than when this run stopped, so nothing more ran: what it "
                        + "went on from has changed. Run the skill again from the start if it still fits."
                    stopped = ["line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                               "reason": .string("state_changed"), "detail": .string(detail),
                               "was": AppScriptRunner.brief(out), "now": AppScriptRunner.brief(now)]
                    return encode(["ok": .bool(false), "reason": .string("state_changed"), "detail": .string(detail),
                                   "stopped": .bool(true)], line: line, n: n)
                }
                journal.append(.object(["call": signature, "out": .string(now), "row": ledger.last ?? .null]))
                return now
            }
            if case .object(let fields) = row {
                ledger.append(row)
                if kind == "action" { actions += 1 } else { reads += 1 }
                if expectFail != nil {
                    expectFailSeen = true
                    if fields["expected"] == .bool(true) { expectFailMatched = true }
                }
            }
            journal.append(.object(["call": signature, "out": .string(out), "row": row]))
            return out
        }

        /// Whether the stopped run itself wrote, after this read, the page or
        /// item it read (a landed write, exempt or versioned).
        func writtenLater(_ entry: JSONValue, at index: Int) -> Bool {
            guard let read = AppScriptRunner.target(entry), !read.write else { return false }
            return ownWrites.contains { $0.at > index && $0.page == read.page
                && (read.item == nil || $0.item == nil || $0.item == read.item) }
        }

        /// A ledger row's status; an answered one replays as saved, never run again.
        static func status(_ row: JSONValue) -> String {
            if case .object(let fields) = row { AppToolExecutor.inputString(fields["status"]) ?? "" } else { "" }
        }

        func encode(_ fields: [String: JSONValue], line: Int, n: Int) -> String {
            var fields = fields
            fields["line"] = .int(Int64(line))
            fields["n"] = .int(Int64(n))
            return (try? JSONValue.object(fields).serialize(pretty: false)) ?? #"{"ok":false,"reason":"internal","detail":"unreadable"}"#
        }

        /// One call, run: checks the latch and the limits, hands the call to
        /// the caller's task, waits, and records it.
        func dispatch(kind: String, id: String, args: String, line: Int) -> String {
            let n = ledger.count + 1
            var row: [String: JSONValue] = ["n": .int(Int64(n)), "line": .int(Int64(line))]
            if strict, !steps.isEmpty { row["step"] = .int(Int64(steps.count)) }
            let given: [JSONValue] = if case .array(let list)? = try? JSONValue.parse(Data(args.utf8)) { list } else { [] }
            let named: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
            let write = kind == "action" && AppActions.action(id)?.readOnly(args: named) != true
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
                let at = stopped["line"].flatMap(AppToolExecutor.inputString) ?? "?"
                return refuse("stopped", "The script stopped at line \(at); no app call runs after that.", stop: true)
            }
            func halt(_ reason: String, _ detail: String, call name: String) -> String {
                row["call"] = .string(name)
                row["status"] = .string("not_run")
                row["reason"] = .string(reason)
                ledger.append(.object(row))
                stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                           "reason": .string(reason), "detail": .string(detail)]
                return refuse(reason, detail, stop: true)
            }
            if strict, ["step", "expect", "expect_fail", "decide"].contains(kind) {
                func text(_ i: Int) -> String { given.indices.contains(i) ? AppToolExecutor.inputString(given[i]) ?? "" : "" }
                switch kind {
                case "step":
                    guard steps.count < AppScriptRunner.stepLimit else {
                        return mark("step_limit", "A run declares at most \(AppScriptRunner.stepLimit) steps.")
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
                    let bytes = (try? data.serialize(pretty: false)) ?? ""
                    decideData = bytes.utf8.count <= AppScriptRunner.logLimit ? data : .string(String(bytes.prefix(AppScriptRunner.logLimit)))
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
            case "action":
                name = id
                guard actions < AppScriptRunner.actionLimit else {
                    return halt("action_limit", "A script does at most \(AppScriptRunner.actionLimit) actions.", call: name)
                }
                switch AppScriptRunner.doorInput(id: id, given: given) {
                case .success(let built): input = built
                case .failure(let problem):
                    row["call"] = .string(name)
                    row["status"] = .string("failed")
                    row["reason"] = .string(problem.reason)
                    row["detail"] = .string(problem.detail)
                    // Refused before it ran: nothing changed.
                    if strict { row["effects"] = .string("none") }
                    if problem.reason == expected { row["expected"] = .bool(true); expectFailMatched = true }
                    ledger.append(.object(row))
                    return latch(problem.reason, problem.detail, call: name) ?? refuse(problem.reason, problem.detail, stop: false)
                }
                actions += 1
                if preview { input["preview"] = .bool(true) }
            default:
                let words = given.compactMap(AppToolExecutor.inputString)
                name = kind == "find" ? "find " + (words.first ?? "") : "read " + words.joined(separator: "/")
                if kind == "read", given.count > 2 {
                    let detail = "app.read takes page and optional item, not extra arguments. Use app.<action>({args}) to select a target. Nothing was read."
                    row["call"] = .string(name)
                    row["status"] = .string("failed")
                    row["reason"] = .string("invalid_args")
                    row["detail"] = .string(detail)
                    row["argument_path"] = .string("app.read.arguments[2]")
                    row["effects"] = .string("none")
                    ledger.append(.object(row))
                    return latch("invalid_args", detail, call: name) ?? refuse("invalid_args", detail, stop: false)
                }
                guard reads < AppScriptRunner.readLimit else {
                    return halt("read_limit", "A script does at most \(AppScriptRunner.readLimit) reads.", call: name)
                }
                reads += 1
                input = kind == "find" ? ["find": given.first ?? .null] : ["page": given.first ?? .null]
                if kind == "read", given.count > 1, given[1] != .null { input["item"] = given[1] }
                // A name on home can send or change something (claude.say,
                // desk.4.done): a script reads home, never opens one of its
                // items. The door's own reading decides, and checks the page again.
                input[AppToolExecutor.doorScriptKey] = .bool(true)
                if AppToolExecutor.opensHomeItem(input) {
                    let detail = "A home item can send or change something, so a script never opens one. Read home with "
                        + "app.read(\"home\") and open the item yourself."
                    row["call"] = .string(name)
                    row["status"] = .string("failed")
                    row["reason"] = .string("not_scriptable")
                    row["detail"] = .string(detail)
                    if strict { row["effects"] = .string("none") }
                    if expected == "not_scriptable" { row["expected"] = .bool(true); expectFailMatched = true }
                    ledger.append(.object(row))
                    return latch("not_scriptable", detail, call: name) ?? refuse("not_scriptable", detail, stop: false)
                }
            }
            row["call"] = .string(name)

            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return halt("timed_out", "The script used its \(Int(AppScriptRunner.wallSeconds)) seconds.", call: name) }
            let waitingStarted = Date()
            flags.withLock { if !cancelled { deadlineCell.pointee = Double.greatestFiniteMagnitude } }
            let reply = post(input)
            // Stop must answer even a buffered job the action consumer never sees.
            let turnStopped = flags.withLock {
                waitingReply = reply
                return cancelled
            }
            if turnStopped { reply.cancel() }
            reply.done.wait()
            deadline = deadline.addingTimeInterval(Date().timeIntervalSince(waitingStarted))
            flags.withLock {
                waitingReply = nil
                if !cancelled { deadlineCell.pointee = deadline.timeIntervalSinceReferenceDate }
            }
            guard !isCancelled, let receipt = reply.take() else {
                row["status"] = .string("cancelled")
                if write { row["effects"] = .string("unknown") }
                ledger.append(.object(row))
                return stopCall("cancelled", "The turn was stopped while this call was running.", call: name, receipt: reply.take())
            }

            let (outcome, reason, detail) = AppScriptRunner.classify(receipt, strict: strict, write: write)
            if kind == "action" { record(receipt, into: &row) } else if case .object(let read) = receipt {
                if let version = read["version"] { row["version"] = version }
            }
            switch outcome {
            case .ok, .preview:
                row["status"] = .string(outcome == .ok ? "ok" : "preview")
                ledger.append(.object(row))
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
                    let effects = fields["status"] == .string("preview") ? .string("none") : AppScriptRunner.effects(fields)
                    if let effects { row["effects"] = effects }
                }
                if reason == expected, row["effects"] == .string("none") { row["expected"] = .bool(true); expectFailMatched = true }
                ledger.append(.object(row))
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
                ledger.append(.object(row))
                return stopCall(reason, detail, call: name, receipt: receipt)
            case .stop:
                let previewed = if case .object(let fields) = receipt { fields["status"] == .string("preview") } else { false }
                row["status"] = .string(reason == "cancelled" ? "not_run" : previewed ? "preview" : "refused")
                row["reason"] = .string(reason)
                if !detail.isEmpty { row["detail"] = .string(detail) }
                ledger.append(.object(row))
                stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                           "reason": .string(reason), "detail": .string(detail)]
                return refuse(reason, detail.isEmpty ? reason : detail, stop: true)
            }
        }

        /// What the call changed and what else the app did, kept short; the
        /// script itself got the whole receipt.
        func record(_ receipt: JSONValue, into row: inout [String: JSONValue]) {
            guard case .object(let fields) = receipt else { return }
            for key in ["nearest", "remedy", "argument_path", "read_only", "irreversible", "effect", "execution"] { row[key] = fields[key] }
            if let changed = fields["changed"] { row["changed"] = changed }
            // A strict run keeps each call's effects and real ids, however
            // long its result.
            if strict {
                let inner: [String: JSONValue] = if case .object(let result)? = fields["result"] { result } else { [:] }
                if let effects = AppScriptRunner.effects(fields) { row["effects"] = effects }
                let ids = AppScriptRunner.returnedIDs(receipt)
                if !ids.isEmpty { row["ids"] = .object(ids) }
            } else {
                // Ordinary scripts need the same small returned facts for
                // later history, even when the result body is too large.
                if let effects = AppScriptRunner.effects(fields) { row["effects"] = effects }
                var ids: [String: JSONValue] = [:]
                for key in ["approval_id", "message_id", "run_id", "request_id", "id", "version", "page_version"] {
                    guard let value = SessionHistoryPromptRenderer.receiptField(key, in: receipt) else { continue }
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
                strict && ["occurred", "partial"].contains(AppToolExecutor.doorText(fields["effects"]))
            }
            /// The action calls whose ledger status is `status`, as "#n line l call";
            /// `changing` leaves out the actions that only read.
            func calls(_ status: String, changing: Bool = false) -> [JSONValue] {
                ledger.compactMap { row -> JSONValue? in
                    guard case .object(let fields) = row,
                          fields["status"] == .string(status) && !(changing && strict && fields["effects"] == .string("none"))
                              || changing && took(fields),
                          let call = fields["call"].flatMap(AppToolExecutor.inputString), !call.hasPrefix("read "),
                          !call.hasPrefix("find "), !(changing && (fields["read_only"] ?? .bool(AppActions.action(call)?.read == true)) == .bool(true)),
                          case .int(let n)? = fields["n"], case .int(let line)? = fields["line"]
                    else { return nil }
                    return .string("#\(n) line \(line) \(call)")
                }
            }
            let landed = calls("ok")
            // Only a landed call that changes something is an effect.
            let changed = calls("ok", changing: true)
            // A call that got no answer may still have landed.
            let unknown = calls("outcome_unknown").compactMap(AppToolExecutor.inputString)
            // A strict run's call that said its effects are unknown.
            let unsure = !strict ? [] : ledger.compactMap { row -> String? in
                guard case .object(let fields) = row, fields["effects"] == .string("unknown"), case .int(let n)? = fields["n"],
                      case .int(let line)? = fields["line"], let call = fields["call"].flatMap(AppToolExecutor.inputString)
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
                out["detail"] = .string("The script ran past \(Int(AppScriptRunner.wallSeconds)) seconds and was stopped; "
                    + "the calls listed before that point ran.")
            }
            if let error { out["error"] = .object(error) }
            let partial = strict && ledger.contains { if case .object(let fields) = $0 { fields["effects"] == .string("partial") } else { false } }
            out["effects"] = .string(!unknown.isEmpty || !unsure.isEmpty ? "unknown" : partial ? "partial"
                : changed.isEmpty ? "none" : "occurred")
            if !changed.isEmpty { out["changed"] = .array(changed) }
            if strict {
                out["journal"] = .array(journal)
                out["steps"] = .array(steps.indices.map { i in
                    .object(["label": .string(steps[i].label), "status": .string(i == steps.count - 1 ? status : "ok")])
                })
            }
            if status != "ok" {
                // A stop that is User's is not fixed by trying again: that
                // line is his to do, and the rest may still be hers.
                let stopReason = stopped.flatMap { AppToolExecutor.inputString($0["reason"]) } ?? ""
                // The code that ended it on the receipt itself (not_scriptable,
                // users_screen), so failure_code is that code, not tool_failed.
                let code = stopReason.isEmpty ? error.flatMap { AppToolExecutor.inputString($0["reason"]) } ?? "" : stopReason
                if !code.isEmpty { out["reason"] = .string(code) }
                let users = AppToolExecutor.doorFloorReasons.contains(stopReason) || stopReason == "needs_glass"
                let alone = code == "not_scriptable"
                let cardPreview = preview && code == "would_card"
                let cardInstruction = "Preview stopped at a call that would raise User's approval card; no card was filed. "
                    + "Run the action outside preview when you want to request his approval."
                let asked = strict && stopReason == "decide"
                let ask = "It stopped to ask you hand_back.question: decide, then do only what is left."
                // The call by its number and what it asked, not its line: a
                // one-line script has every call on line 1.
                let at = stopped ?? error
                let n = at?["n"].flatMap(AppToolExecutor.inputString)
                let which = n.map { "Call \($0)" + (at?["call"].flatMap(AppToolExecutor.inputString).map { " (\($0))" } ?? "") }
                    ?? "Line \(at?["line"].flatMap(AppToolExecutor.inputString) ?? "?")"
                let drop = "\(which) is User's (\(stopReason)): drop that call and run the rest if you still want it."
                let own = "\(which) can't run in a script: run it as its own app call, outside the script, "
                    + "and the rest without it."
                let check = (unknown + unsure).joined(separator: ", ")
                    + (unknown.isEmpty ? " ended with its effects unknown" : " got no answer") + ", so whether it took effect is unknown: "
                    + "read the page to check before running it again, then do only what is left."
                // Reads that landed changed nothing.
                let nothing = landed.isEmpty ? "Nothing landed. " : "Nothing changed. "
                out["remedy"] = .object([
                    "kind": .string(users ? "drop_users_line" : alone ? "run_alone" : asked ? "decide"
                        : cardPreview ? "request_approval" : "read_ledger"),
                    "instruction": .string(changed.isEmpty
                        ? (!unknown.isEmpty || !unsure.isEmpty ? check
                            : users ? nothing + drop : alone ? nothing + own : asked ? nothing + ask
                            : cardPreview ? cardInstruction : nothing + (at?["instruction"].flatMap(AppToolExecutor.inputString)
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
                              let call = fields["call"].flatMap(AppToolExecutor.inputString),
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
    static func prelude(ids: String, strict: Bool = false, input: Bool = false) -> String {
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
        return """
        var app = (function (ids, call, say) {
          function where() {
            var m = (new Error().stack || "").match(/app-script\\.js:(\\d+):\\d+/);
            return m ? +m[1] : 0;
          }
          function invoke(kind, id, args) {
            var out = JSON.parse(call(kind, id, JSON.stringify(args), where()));
            if (out.ok) return out.value;
            var e = new Error(out.detail);
            e.name = "AppError"; e.reason = out.reason; e.action = id; e.stopped = out.stopped;
            e.scriptLine = out.line; e.callNumber = out.n; e.receipt = out.receipt;
            throw e;
          }
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
