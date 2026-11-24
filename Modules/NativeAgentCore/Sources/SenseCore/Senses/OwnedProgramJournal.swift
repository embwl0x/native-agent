import Darwin
import Synchronization
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramJournal.swift` | Request-owned replay and read freshness; receipts show calls as metadata and name the private journal |
extension OwnedProgramRunner {
    final class Journal {
        let lines: [Substring]
        let preview: Bool
        var strict: Bool
        /// Progress and ledger size bound a part, never its number of calls.
        let part: Bool
        let programEntry: OwnedProgram.Entry
        let partVersion: String
        let replay: [JSONValue]
        let answer: JSONValue
        let recheckReads: Bool
        let host: any OwnedProgramHostProfile
        let execution: OwnedProgramExecution
        let actionsInFlight: ActionTasks
        var notebookRoot: URL
        let partID: String
        // Only the requesting task may mutate this journal.
        var ledger: [JSONValue] = []
        var ledgerBytes = 0
        var log: [String] = []
        var logBytes = 0
        var actions = 0
        var reads = 0
        /// Positive evidence from the notebook owner's committed-write boundary, including writes outside the call ledger.
        var notebookChanged = false
        var notebookChangeKnown = true
        private var notebookEffect: ToolFailureError.Effects = .none
        private var lastNotebookWrite: (at: Int, value: JSONValue?)?
        var stopped: [String: JSONValue]?
        /// An ordinary script's refused calls by number: each throws to the code, and becomes the stop only if the script ends on it uncaught.
        var refusals: [Int: [String: JSONValue]] = [:]
        var refusedAfterStop = 0
        /// In-flight unjournaled calls must not create ledger rows.
        var unjournaled = false
        var returned: JSONValue = .null
        var error: [String: JSONValue]?
        var timedOut = false
        var steps: [(label: String, guidance: String)] = []
        var expectFail: String?
        var expectFailSeen = false
        var expectFailMatched = false
        var expectFailOther: String?
        var stepTotal: Int?
        var decideData: JSONValue = .null
        /// Keep each call's answer and ledger row so resume can replay without executing it again.
        var journal: [JSONValue] = []
        var replayed = 0
        var readContent: JSONValue = .null
        var readProjections: JSONValue = .array([])
        let replayContent = ReadContent()
        /// Writes must use the newest version the run itself read or wrote, never an external fresh read.
        var newest: [String: String] = [:]
        var seen: Set<String> = []
        var stale: [String: JSONValue]?
        /// Replay superseded reads only while the later write's version still verifies the scope originally read.
        let ownWrites: [(at: Int, page: String, item: String?, version: String?)]
        var isCancelled: Bool { Task.isCancelled }
        init(source: String, preview: Bool, program: OwnedProgram, replay: Replay?,
             host: any OwnedProgramHostProfile, execution: OwnedProgramExecution, actionsInFlight: ActionTasks, notebookRoot: URL, partID: String) {
            self.lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            self.preview = preview; self.strict = program.isStrict
            self.part = program.isPart
            self.programEntry = program.entry
            self.partVersion = program.version
            self.replay = replay?.journal ?? []; self.answer = replay?.answer ?? .null
            self.recheckReads = replay?.recheckReads ?? true
            self.execution = execution; self.host = host; self.actionsInFlight = actionsInFlight
            self.notebookRoot = notebookRoot; self.partID = partID
            var resolutionFailure: Error?
            var ownWrites: [(at: Int, page: String, item: String?, version: String?)] = []
            do { ownWrites = try (replay?.journal ?? []).enumerated().compactMap { at, entry in
                // A caught failure still counts as a write if it landed or may have landed.
                guard let target = try OwnedProgramRunner.target(entry, host: host), target.write, case .object(let fields) = entry,
                      case .object(let row)? = fields["row"] else { return nil }
                let wrote = if let effects = row["effects"]?.stringValue { ["occurred", "partial", "unknown"].contains(effects) }
                    else { ["ok", "unconfirmed"].contains(row["status"]?.scalarText ?? "") }
                guard wrote else { return nil }
                let out = fields["out"]?.scalarText.map(OwnedProgramRunner.readValue)
                let version: String? = if case .object(let value)? = out { value["page_version"]?.scalarText } else { nil }
                return (at, target.page, target.item, version)
            } } catch { resolutionFailure = error }
            self.ownWrites = ownWrites
            for (at, entry) in self.replay.enumerated() {
                guard let fields = entry.objectValue, let call = fields["call"]?.arrayValue, call.count == 4,
                      call[0] == .string("state"), call[1] == .string("set"), let args = call[2].stringValue,
                      let values = (try? JSONValue.parse(Data(args.utf8)))?.arrayValue, values.count == 1,
                      let out = fields["out"]?.stringValue else { continue }
                // Older checkpoints know the acknowledged value of a set, but didn't record whether it changed disk.
                let effects = fields["notebook_effects"]?.stringValue ?? "unknown"
                if effects == "occurred" { notebookChanged = true }
                if effects == "unknown" { notebookChangeKnown = false }
                let reply = try? JSONValue.parse(Data(out.utf8))
                if reply?.objectValue?["ok"] == .bool(true) {
                    lastNotebookWrite = (at, values[0])
                } else if effects != "none" {
                    lastNotebookWrite = (at, nil)
                }
            }
            if let resolutionFailure {
                stopped = ["reason": .string("action_catalog_unavailable"), "detail": .string(resolutionFailure.localizedDescription)]
            }
            for version in OwnedProgramRunner.ownVersions(replay?.journal ?? []) { own(version) }
        }
        func own(_ version: String) {
            newest[String(OwnedProgramRunner.versionScope(version).split(separator: "/").first ?? "")] = version
            seen.insert(version)
        }
        func complete(_ fields: [String: JSONValue]) {
            // A refusal the code caught is handled; one the script ended on uncaught is where it stopped.
            if stopped == nil, case .object(let report)? = fields["exception"], case .int(let n)? = report["n"],
               let refused = refusals[Int(n)] {
                stopped = refused
            }
            if case .object(var report)? = fields["exception"], stopped == nil {
                report["origin"] = .string("javascript")
                let message = report["message"]?.scalarText ?? "error"
                if report.removeValue(forKey: "syntax") == .bool(true) {
                    report["reason"] = .string("script_syntax")
                    report["rule"] = .string(programEntry == .functionBody ? "javascript_function_body" : "javascript_entry")
                    report["instruction"] = .string(part ? "Fix the reported JavaScript syntax in \(partID) with ability.save."
                        : "Fix the JavaScript syntax reported in message at line. "
                        + """
                            Top-level await is not supported: app.* calls return synchronously. Use const result = app.read(\"inbox\"); return result; \
                            without await.
                            """)
                }
                if let name = message.range(of: #"(?<=Can't find variable: )\w+"#, options: .regularExpression).map({ String(message[$0]) }) {
                    do {
                    let actionIDs = try host.actionIDs
                    if actionIDs.contains(where: { $0.hasPrefix(name + ".") }) {
                        report["reason"] = .string("script_name")
                        report["instruction"] = .string("""
                            Inside a script, actions live under app: use app.\(name).… (for example \
                            app.\(name).\(actionIDs.first { $0.hasPrefix(name + ".") }.map { String($0.dropFirst(name.count + 1)) } ?? "…")()).
                            """)
                    } else if name == "host" {
                        // The host binding belongs to saved abilities; ad hoc scripts have only the app door.
                        report["reason"] = .string("script_name")
                        report["instruction"] = .string("""
                            `host` exists only inside a saved ability (ability.save): an ad-hoc app script has app.* and nothing else. Use \
                            app.<page>.<action>() here, or save the code as an ability and run authored.<id>.
                            """)
                    }
                    } catch { report["catalog_error"] = .string(error.localizedDescription) }
                }
                report.removeValue(forKey: "name")
                if case .int(let line)? = report["line"], line > 0 { report["source"] = sourceLine(Int(line)) }
                if case .int(let n)? = report["n"], ledger.indices.contains(Int(n) - 1),
                   case .object(let row) = ledger[Int(n) - 1] {
                    report["call"] = row["call"] ?? .null
                    for key in ["try_instead", "remedy", "argument_path"] { report[key] = row[key] }
                }
                if part {
                    report["ability"] = .string(partID)
                    report["version"] = .string(partVersion)
                    report["cause"] = .string(message)
                    let place = report["line"]?.scalarText.map { " at line " + $0 } ?? " (source line unavailable)"
                    report["message"] = .string("Ability \(partID)\(place): \(message)")
                    if report["reason"] == nil { report["reason"] = .string("javascript_exception") }
                    if report["remedy"] == nil {
                        report["remedy"] = Repair.remedy(owner: "ability " + partID + place,
                            nextCall: .object(["tool": .string("app"), "input": .object([
                                "action": .string("ability.read"), "args": .object(["id": .string(partID)])])]), tap: nil,
                            instruction: "Read the named ability and repair its expression with ability.save; inspect reached effects before running it again.")
                    }
                }
                error = report
            }
            if stopped == nil, case .string(let detail)? = fields["unreadableReturn"] {
                if strict { stopped = ["reason": .string("unreadable_return"), "detail": .string(detail)] }
                else { error = ["reason": .string("unreadable_return"), "message": .string(detail),
                                "origin": .string("javascript")] }
            }
            returned = fields["returned"] ?? .null
            if stopped == nil, error == nil, !timedOut, replayed < replay.count {
                stopped = ["reason": .string("diverged"), "detail": .string(
                    "This resumed run returned after matching \(replayed) of \(replay.count) saved calls. "
                    + "It did not use your answer. Read the recorded effects before deciding what remains.")]
                returned = .null
            }
            if strict, stopped == nil, !timedOut, let code = expectFail {
                stopped = ["reason": .string("expected_failure_not_seen"),
                           "detail": .string("app.expect_fail(\"\(code)\") was never closed, so nothing failed as declared.")]
            }
        }
        func fail(_ failure: SenseFailure) {
            if failure.code != "cancelled", stopped?["reason"] == .string("cancelled") { stopped = nil }
            if failure.code == "timeout" {
                timedOut = true
                error = ["reason": .string(failure.code), "message": .string(failure.message)]
                error?["remedy"] = failure.remedy
            }
            else if failure.code == "cancelled" {
                stopped = ["reason": .string("cancelled"), "detail": .string("The turn was stopped, so the script was ended.")]
            } else if stopped == nil {
                error = ["reason": .string(failure.code), "message": .string(String(failure.message.prefix(400)))]
                error?["remedy"] = failure.remedy
                if part { error?["origin"] = .string("runtime") }
            }
        }
        func say(_ text: String) {
            guard logBytes < OwnedProgramRunner.logLimit else { return }
            let kept = String(text.prefix(OwnedProgramRunner.logLimit - logBytes))
            logBytes += kept.utf8.count; log.append(kept)
        }
        func sourceLine(_ line: Int) -> JSONValue {
            guard line >= 1, line <= lines.count else { return .null }
            let text = lines[line - 1].trimmingCharacters(in: .whitespaces)
            // Never echo a line naming an action that takes a key.
            if host.secretLine(text) {
                return .string("[redacted: this line names an action that takes a key or token]")
            }
            return .string(String(text.prefix(160)))
        }
        /// Journal calls on the script's thread so resumed calls answer from Replay without executing effects again.
        func call(kind: String, id: String, args: Data, line: Int) async -> String {
            // Validate transport before replay classification or any host call.
            guard case .array(let given)? = try? JSONValue.parse(args) else {
                stopped = ["line": .int(Int64(line)), "reason": .string("invalid_args"),
                           "detail": .string("The helper call arguments are not a JSON array. Repair the helper protocol; no call ran.")]
                return encode(["ok": .bool(false), "reason": .string("invalid_args"),
                               "detail": stopped?["detail"] ?? .null, "stopped": .bool(true)], line: line, n: ledger.count + 1)
            }
            let kind = kind == "primitive" && host.primitiveAction(id) == nil ? "action" : kind
            do {
            let id = try kind == "action" ? (host.canonicalAction(id)) : id
            guard strict, ["action", "primitive", "read", "find", "decide", "state"].contains(kind), stopped == nil else {
                return await dispatch(kind: kind, id: id, given: given, line: line)
            }
            let evidence = try kind == "action" ? host.callArgumentsForEvidence(id, given: given) : given
            let signature = JSONValue.array([.string(kind), .string(id),
                .string(try JSONValue.array(evidence).serialize(pretty: false)), .int(Int64(line))])
            guard replayed < replay.count else {
                let rows = ledger.count
                let out = await dispatch(kind: kind, id: id, given: given, line: line)
                var entry: [String: JSONValue] = ["call": signature, "out": .string(out),
                    "row": ledger.count > rows ? ledger[ledger.count - 1] : .null,
                    "read_content": readContent, "read_projections": readProjections]
                if kind == "state", id == "set" { entry["notebook_effects"] = .string(notebookEffect.rawValue) }
                retain(.object(entry))
                return out
            }
            let n = ledger.count + 1
            guard case .object(let entry) = replay[replayed], sameCall(entry["call"], signature),
                  case .string(var out)? = entry["out"] else {
                let detail = "This resumed run took another path than the one that stopped, at call \(replayed + 1) of "
                    + "\(replay.count), so nothing more ran. Read the recorded effects before deciding what remains."
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
                let named: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
                read = host.primitiveAction(id)?.readOnly(named) == true
            } else {
                read = try host.action(id)?.read == true
            }
            let reread = try recheckReads && Self.status(row) != "answered"
                && (kind == "read" || kind == "find" || (["action", "primitive"].contains(kind) && read))
                && (kind != "action" || host.action(id)?.advisory != true)
            /// Changed authoritative read content must stop replay before more work runs.
            func changed(_ name: String, was: JSONValue, now: JSONValue) -> String {
                let detail = "\(name) reads differently than when this run stopped, so nothing more ran: what it "
                    + "went on from has changed. Read the recorded effects before deciding what remains."
                stopped = ["line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                           "reason": .string("state_changed"), "detail": .string(detail), "was": was, "now": now]
                return encode(["ok": .bool(false), "reason": .string("state_changed"), "detail": .string(detail),
                               "stopped": .bool(true)], line: line, n: n)
            }
            if replayed == replay.count {
                // At the stop point, return the supplied answer without repeating even a read.
                out = encode(["ok": .bool(true), "value": answer], line: line, n: n)
                if case .object(var fields) = row {
                    for key in ["reason", "detail", "result", "result_bytes", "result_digest"] { fields.removeValue(forKey: key) }
                    fields["status"] = .string("answered")
                    row = .object(fields)
                }
            } else if recheckReads, kind == "state", id == "get" {
                let now = await dispatch(kind: kind, id: id, given: given, line: line)
                let observed = (try? JSONValue.parse(Data(now.utf8)))?.objectValue?["value"]
                let expected: JSONValue?
                if let later = lastNotebookWrite, later.at >= replayed {
                    expected = later.value
                } else {
                    expected = (try? JSONValue.parse(Data(out.utf8)))?.objectValue?["value"]
                }
                guard stopped == nil, observed != nil, expected == observed else {
                    return changed("ability notebook",
                        was: expected.flatMap { try? CallLedger.measured($0) }.map(JSONValue.object) ?? .null,
                        now: observed.flatMap { try? CallLedger.measured($0) }.map(JSONValue.object) ?? .null)
                }
            } else if reread, let mine = try writtenLater(.object(entry), at: replayed - 1) {
                let readVersion = OwnedProgramRunner.readValue(out).objectValue?["version"]?.stringValue
                // An item's version cannot verify the siblings included in a whole-page read.
                let now: String? = if let readVersion, let left = mine.version,
                    OwnedProgramRunner.versionScope(readVersion) == OwnedProgramRunner.versionScope(left) {
                    await currentVersion(left)
                } else { nil }
                if mine.version == nil || now != mine.version {
                    return changed("read " + mine.page, was: mine.version.map(JSONValue.string) ?? .null, now: now.map(JSONValue.string) ?? .null)
                }
            } else if reread {
                // Authoritative reads must still match; advisory answers replay as saved.
                let now = await dispatch(kind: kind, id: id, given: given, line: line)
                // Pre-dispatch refusals have no read content, so compare the refusal itself.
                guard stopped == nil, let content = entry["read_content"], readContent == content,
                      content != .null || replayContent.normalize(OwnedProgramRunner.readValue(now))
                          == replayContent.normalize(OwnedProgramRunner.readValue(out)) else {
                    let name = kind == "action" ? id : ledger.last.flatMap { if case .object(let row) = $0 { row["call"]?.scalarText } else { nil } } ?? kind
                    return changed(name, was: OwnedProgramRunner.brief(out), now: OwnedProgramRunner.brief(now))
                }
                // Saved and fresh bindings must share the result owner's content contract.
                replayContent.include(entry["read_projections"] ?? .null)
                replayContent.include(readProjections)
                // Return fresh bindings after successful comparison so later resumed actions use current handles.
                retain(.object(["call": signature, "out": .string(now), "row": ledger.last ?? .null,
                                        "read_content": readContent, "read_projections": readProjections]))
                return now
            }
            if case .object(let fields) = row {
                append(row)
                if kind == "action" || kind == "primitive" { actions += 1 } else { reads += 1 }
                if expectFail != nil {
                    expectFailSeen = true
                    if fields["expected"] == .bool(true) { expectFailMatched = true }
                    else if fields["status"] == .string("failed") { expectFailOther = fields["reason"]?.scalarText }
                }
            }
            replayContent.include(entry["read_projections"] ?? .null)
            var recorded = entry
            recorded["call"] = signature
            recorded["out"] = .string(out)
            recorded["row"] = row
            retain(.object(recorded))
            return out
            } catch {
                let detail = """
                    The action catalog could not be read: \(error.localizedDescription). Repair its source before resuming; completed effects must not be \
                    repeated.
                    """
                stopped = ["line": .int(Int64(line)), "reason": .string("action_catalog_unavailable"), "detail": .string(detail)]
                return encode([
                    "ok": .bool(false), "reason": .string("action_catalog_unavailable"), "detail": .string(detail), "stopped": .bool(true)],
                    line: line,
                    n: ledger.count + 1
                )
            }
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
        /// Find the run's last landed write after this read to explain an own-write content difference.
        func writtenLater(_ entry: JSONValue, at index: Int) throws -> (at: Int, page: String, item: String?, version: String?)? {
            guard let read = try OwnedProgramRunner.target(entry, host: host), !read.write else { return nil }
            return ownWrites.last { $0.at > index && $0.page == read.page
                && (read.item == nil || $0.item == nil || $0.item == read.item) }
        }
        /// Nil means the read supplies no comparable scope; an absent page or item returns an empty version to mark it changed.
        func currentVersion(_ version: String) async -> String? {
            let scope = OwnedProgramRunner.versionScope(version)
            let parts = scope.split(separator: "/", maxSplits: 1).map { JSONValue.string(String($0)) }
            guard let page = parts.first else { return nil }
            var input: [String: JSONValue] = ["page": page, host.scriptKey: .bool(true)]
            if parts.count > 1 { input["item"] = parts[1] }
            if preview { input["preview"] = .bool(true) }
            guard case .object(let read) = await actionsInFlight.perform(input, host: host, execution: execution) else { return nil }
            guard let now = read["version"]?.scalarText else {
                return read["status"] == .string("failed") || read["status"] == .string("refused") || read["ok"] == .bool(false) ? "" : nil
            }
            return OwnedProgramRunner.versionScope(now) == scope ? now : nil
        }
        /// Answered ledger rows replay as saved and must never run again.
        static func status(_ row: JSONValue) -> String {
            if case .object(let fields) = row { fields["status"]?.scalarText ?? "" } else { "" }
        }
        func encode(_ fields: [String: JSONValue], line: Int, n: Int) -> String {
            var fields = fields
            // Every failure exposes advice at the same envelope field; a returned receipt owns its advice.
            if fields["ok"] == .bool(false) {
                let advice: JSONValue?
                if let receipt = fields["receipt"] { advice = receipt.objectValue?["try_instead"] }
                else { advice = fields["try_instead"] }
                fields["try_instead"] = advice ?? .null
            }
            fields["line"] = .int(Int64(line))
            fields["n"] = .int(Int64(n))
            return (try? JSONValue.object(fields).serialize(pretty: false)) ?? #"{"ok":false,"reason":"internal","detail":"unreadable","try_instead":null}"#
        }
        func append(_ row: JSONValue) {
            guard !unjournaled else { return }
            if part { account(row) }
            ledger.append(row)
        }
        /// Full replies, arguments and projections must count against the same budget as the ledger.
        func retain(_ entry: JSONValue) {
            if part { account(entry) }
            journal.append(entry)
        }
        private func account(_ value: JSONValue) {
            do { ledgerBytes += try value.serializedData(pretty: false).count }
            catch { unserializable(error) }
        }
        private func unserializable(_ error: Error) {
            stopped = ["reason": .string("serialization_failed"),
                       "detail": .string("""
                           The produced receipt could not be serialized: \(error.localizedDescription). Its effects remain recorded; repair the \
                           receipt before continuing.
                           """)]
        }
        func dispatch(kind: String, id: String, given: [JSONValue], line: Int) async -> String {
            readContent = .null
            readProjections = .array([])
            notebookEffect = .none
            unjournaled = !preview && kind == "primitive" && host.primitiveAction(id)?.journaled == false
            if part, ledgerBytes >= 4 * 1024 * 1024 {
                stopped = ["reason": .string("output_limit"), "detail": .string("The run's receipt ledger reached 4 MiB; no further call ran.")]
                return encode(["ok": .bool(false), "reason": .string("output_limit"),
                               "detail": stopped?["detail"] ?? .null, "stopped": .bool(true)], line: line, n: ledger.count + 1)
            }
            let n = ledger.count + 1
            var row: [String: JSONValue] = ["n": .int(Int64(n)), "line": .int(Int64(line))]
            if strict, !steps.isEmpty { row["step"] = .int(Int64(steps.count)) }
            let job = DispatchedCall(journal: self, kind: kind, id: id, line: line, n: n, given: given, row: row)
            // Close expect_fail after Stop too, so the script can rethrow its call's failure.
            if strict, kind == "expect_fail_end" { return closeExpectFail(job) }
            if let stopped {
                refusedAfterStop += 1
                let at = stopped["line"]?.scalarText ?? "?"
                return job.refuse("stopped", "The script stopped at line \(at); no app call runs after that.", stop: true)
            }
            let registeredAction: OwnedProgramAction?
            do { registeredAction = kind == "action" ? try host.action(id) : nil }
            catch { return job.mark("action_catalog_unavailable", """
                The action catalog could not be read: \(error.localizedDescription). Repair its source before running this call.
                """) }
            if kind == "state" { return notebook(job) }
            if strict, ["step", "expect", "expect_fail", "decide"].contains(kind) { return await strictVerb(job) }
            if let refusal = admitCall(job) { return refusal }
            if let refusal = prepareInput(job, registeredAction: registeredAction) { return refusal }
            return await perform(job, registeredAction: registeredAction)
        }

        /// One dispatched call: its number and line, its arguments, and the ledger row it grows; every answer is stamped with both.
        final class DispatchedCall {
            let journal: Journal
            let kind: String
            let id: String
            let line: Int
            let n: Int
            let given: [JSONValue]
            let named: [String: JSONValue]
            var row: [String: JSONValue]
            /// The failure code an open app.expect_fail declared, when this is its one call.
            var expected: String?
            var input: [String: JSONValue] = [:]
            var name = ""

            init(journal: Journal, kind: String, id: String, line: Int, n: Int, given: [JSONValue], row: [String: JSONValue]) {
                self.journal = journal
                self.kind = kind
                self.id = id
                self.line = line
                self.n = n
                self.given = given
                let named: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
                self.named = named
                self.row = row
            }

            func answer(_ fields: [String: JSONValue]) -> String { journal.encode(fields, line: line, n: n) }
            func refuse(_ reason: String, _ detail: String, stop: Bool) -> String {
                answer(["ok": .bool(false), "reason": .string(reason), "detail": .string(detail), "stopped": .bool(stop)])
            }
            func mark(_ reason: String, _ detail: String) -> String {
                journal.stopped = ["line": .int(Int64(line)), "source": journal.sourceLine(line), "reason": .string(reason), "detail": .string(detail)]
                return refuse(reason, detail, stop: true)
            }
            func halt(_ reason: String, _ detail: String, call name: String) -> String {
                row["call"] = .string(name)
                row["status"] = .string("not_run")
                row["reason"] = .string(reason)
                journal.append(.object(row))
                journal.stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": journal.sourceLine(line), "call": .string(name),
                           "reason": .string(reason), "detail": .string(detail)]
                return refuse(reason, detail, stop: true)
            }
            /// Action failures remain catchable AppErrors; only script failure, an explicit script stop or turn cancellation ends the run. Preserve every
            /// call's effects.
            func failed(_ reason: String) {
                guard expected != nil else { return }
                if reason == expected { row["expected"] = .bool(true); journal.expectFailMatched = true } else { journal.expectFailOther = reason }
            }
            /// Pre-dispatch refusal proves no effect occurred.
            func refused(_ reason: String, _ detail: String, call name: String, tryInstead: JSONValue? = nil) -> String {
                row["call"] = .string(name)
                row["status"] = .string("failed")
                row["reason"] = .string(reason)
                row["detail"] = .string(detail)
                row["effects"] = .string("none")
                row["try_instead"] = tryInstead
                failed(reason)
                journal.append(.object(row))
                var reply: [String: JSONValue] = ["ok": .bool(false), "reason": .string(reason), "detail": .string(detail),
                    "stopped": .bool(false), "effects": .string("none"), "call": .string(name)]
                reply["try_instead"] = tryInstead
                return answer(reply)
            }
            func stopCall(_ reason: String, _ detail: String, call name: String, receipt: JSONValue?) -> String {
                journal.stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": journal.sourceLine(line), "call": .string(name),
                           "reason": .string(reason), "detail": .string(detail)]
                if case .object(let fields)? = receipt {
                    for key in ["try_instead", "remedy", "argument_path"] { journal.stopped?[key] = fields[key] }
                }
                var fields: [String: JSONValue] = ["ok": .bool(false), "reason": .string(reason), "detail": .string(detail),
                                                   "stopped": .bool(true), "call": .string(name), "effects": row["effects"] ?? .string("none")]
                if let receipt { fields["receipt"] = receipt }
                return answer(fields)
            }
            /// An expect_fail assertion must stop the run when its call succeeds.
            func unexpected(_ code: String, _ receipt: JSONValue) -> String {
                stopCall("expected_failure_succeeded", "This call was declared to fail with \(code) (app.expect_fail), "
                    + "but it answered without failing; the run stopped.", call: row["call"]?.scalarText ?? kind, receipt: receipt)
            }
        }

        /// The end of an app.expect_fail block: its one call must have failed with the declared code.
        private func closeExpectFail(_ job: DispatchedCall) -> String {
            let given = job.given
            defer { expectFail = nil }
            guard stopped == nil, let code = expectFail else { return job.answer(["ok": .bool(true), "value": .null]) }
            if given.first == .bool(true) {
                return job.mark("expect_fail_async", "app.expect_fail(\"\(code)\") was given an async function; it takes one plain call.")
            }
            guard expectFailMatched else {
                return job.mark("expected_failure_not_seen", "app.expect_fail(\"\(code)\") saw no call fail with \(code)"
                    + (expectFailOther.map { "; it failed with \($0)." } ?? "."))
            }
            return job.answer(["ok": .bool(true), "value": .null])
        }

        /// host.state.get() and host.state.set(value): the part's own notebook, never a face's.
        private func notebook(_ job: DispatchedCall) -> String {
            let id = job.id
            if programEntry == .face { return job.refuse("projection_only", "A face reads only its frozen sources, never a notebook.", stop: true) }
            let values = job.given
            guard id == "get" && values.isEmpty || id == "set" && values.count == 1 else {
                return job.refuse("bad_state", "Use host.state.get() or host.state.set(value).", stop: false)
            }
            do {
                let value = try AbilityStore.notebook(dataRoot: notebookRoot, id: partID,
                    setting: id == "set", value: values.first ?? .null,
                    writing: { self.notebookChanged = true; self.notebookEffect = .occurred },
                    writeUncertain: { self.notebookChangeKnown = false; self.notebookEffect = .unknown },
                    failure: { SenseFailure(code: $0, message: $1) })
                return job.answer(["ok": .bool(true), "value": value])
            } catch {
                return job.refuse("bad_state", error.localizedDescription, stop: false)
            }
        }

        /// A strict run's own verbs: step, expect, expect_fail's opening and decide.
        private func strictVerb(_ job: DispatchedCall) async -> String {
            let kind = job.kind, given = job.given
            func text(_ i: Int) -> String { given.indices.contains(i) ? given[i].scalarText ?? "" : "" }
            switch kind {
            case "step":
                guard steps.count < OwnedProgramRunner.stepLimit else {
                    return job.mark("step_limit", "A run declares at most \(OwnedProgramRunner.stepLimit) steps.")
                }
                steps.append((String(text(0).prefix(160)), String(text(1).prefix(400))))
                if given.count > 2, case .object(let options) = given[2], case .int(let of)? = options["of"], of > 0 {
                    stepTotal = Int(of)
                }
            case "expect" where given.first != .bool(true):
                return job.mark("expect_failed", "Expected: \(text(1).prefix(400)). It was not so.")
            case "expect_fail":
                guard expectFail == nil else {
                    return job.mark("expect_fail_nested", "app.expect_fail can't be nested; each one wraps one call.")
                }
                expectFail = text(0); expectFailSeen = false; expectFailMatched = false; expectFailOther = nil
            case "decide":
                let data = given.count > 1 ? given[1] : .null
                do {
                    if let value = try await host.decide(text(0), data: data, execution: execution) {
                        job.row["call"] = .string("app.decide")
                        job.row["status"] = .string("answered")
                        job.row["effects"] = .string("none")
                        append(.object(job.row))
                        return job.answer(["ok": .bool(true), "value": value])
                    }
                } catch { return job.mark("fixture_mismatch", error.localizedDescription) }
                let bytes = (try? data.serialize(pretty: false)) ?? ""
                decideData = bytes.utf8.count <= OwnedProgramRunner.logLimit ? data : .string(String(bytes.prefix(OwnedProgramRunner.logLimit)))
                return job.mark("decide", String(text(0).prefix(400)))
            default: break
            }
            return job.answer(["ok": .bool(true), "value": .null])
        }

        /// An open expect_fail admits one call; a stopped turn admits none.
        private func admitCall(_ job: DispatchedCall) -> String? {
            let kind = job.kind, id = job.id
            // An expect_fail wraps exactly one call; a second call must not execute.
            if expectFail != nil, expectFailSeen {
                return job.halt("expect_fail_one_call", "app.expect_fail wraps one app call; this second one did not run.",
                            call: kind == "action" ? id : kind)
            }
            let expected = expectFail
            job.expected = expected
            if expected != nil { expectFailSeen = true }
            if isCancelled {
                return job.halt("cancelled", "The turn was stopped, so no app call runs from here.", call: kind == "action" ? id : kind)
            }
            return nil
        }

        /// The door input and call name: a primitive's, an action's (with its own read version on strict writes), or a read's.
        private func prepareInput(_ job: DispatchedCall, registeredAction: OwnedProgramAction?) -> String? {
            let kind = job.kind, id = job.id, given = job.given
            var input: [String: JSONValue]
            let name: String
            switch kind {
            case "primitive":
                name = id
                guard given.count <= 1 else {
                    return job.refused("invalid_args", "\(id) takes one named-argument object; nothing ran.", call: name)
                }
                guard part || actions < OwnedProgramRunner.actionLimit else {
                    return job.halt("action_limit", "A script does at most \(OwnedProgramRunner.actionLimit) actions.", call: name)
                }
                actions += 1
                input = [:]
            case "action":
                name = id
                guard part || actions < OwnedProgramRunner.actionLimit else {
                    return job.halt("action_limit", "A script does at most \(OwnedProgramRunner.actionLimit) actions.", call: name)
                }
                switch host.doorInput(id: id, given: given) {
                case .success(let built):
                    input = built
                    if !host.scriptKey.isEmpty { input[host.scriptKey] = .bool(true) }
                case .failure(let problem): return job.refused(problem.reason, problem.detail, call: name, tryInstead: problem.tryInstead)
                }
                // Strict writes must use the version of the page this run read.
                let callArgs: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
                if strict, let action = registeredAction, action.versioned, !action.readOnly(callArgs) {
                    if case .string(let given)? = input["expected_version"], !given.isEmpty {
                        guard seen.contains(given) else {
                            return job.refused("not_own_version", """
                                \(id) passed a version this run never read; an ability's write goes on its own read's version. It was not run.
                                """, call: name)
                        }
                    } else if let version = newest[action.page] { input["expected_version"] = .string(version) }
                }
                actions += 1
            default:
                job.row["read_only"] = .bool(true)
                job.row["effects"] = .string("none")
                let words = given.compactMap(\.scalarText)
                name = kind == "find" ? "find " + (words.first ?? "") : "read " + words.joined(separator: "/")
                if kind == "read", given.count > 2 {
                    job.row["argument_path"] = .string("app.read.arguments[2]")
                    return job.refused("invalid_args", "app.read takes page and optional item, not extra arguments. Use app.<action>({args}) "
                        + "to select a target. Nothing was read.", call: name)
                }
                guard part || reads < OwnedProgramRunner.readLimit else {
                    return job.halt("read_limit", "A script does at most \(OwnedProgramRunner.readLimit) reads.", call: name)
                }
                reads += 1
                input = kind == "find" ? ["find": given.first ?? .null] : ["page": given.first ?? .null]
                if kind == "read", given.count > 1, given[1] != .null { input["item"] = given[1] }
                // Home items can have effects, so scripts may read home but cannot open its items; the door rechecks page classification.
                input[host.scriptKey] = .bool(true)
                if host.opensHomeItem(input) {
                    return job.refused("action_required", "A home item can send or change something, so a script never opens one. "
                        + "Read home with app.read(\"home\") and open the item yourself.", call: name)
                }
            }
            if preview, kind != "primitive" { input["preview"] = .bool(true) }
            job.input = input
            job.name = name
            return nil
        }

        /// Runs the call once, classifies its receipt, journals its row and answers the script.
        private func perform(_ job: DispatchedCall, registeredAction: OwnedProgramAction?) async -> String {
            let kind = job.kind, id = job.id, line = job.line, n = job.n, given = job.given, named = job.named
            let input = job.input, name = job.name, expected = job.expected
            job.row["call"] = .string(name)
            let arguments = if case .object(let args)? = input["args"] { args } else { named }
            let write = kind == "primitive" ? host.primitiveAction(id)?.readOnly(named) != true
                : kind == "action" && registeredAction?.readOnly(arguments) != true
            // read_only classifies possible behavior and replay policy; effects records what actually happened.
            job.row["read_only"] = .bool(!write)
            let readContent = ReadContent()
            var callExecution = execution
            callExecution.readContent = readContent
            let receipt: JSONValue
            if kind == "primitive", preview, write, host.primitiveAction(id)?.program != true {
                receipt = .object(["status": .string("preview"), "execution": .string("preview"), "effects": .string("none"), "result": .null])
            } else if kind == "primitive" {
                receipt = await actionsInFlight.primitive(id, arguments: given.first ?? .null, preview: preview, host: host, execution: callExecution)
            } else {
                receipt = await actionsInFlight.perform(input, host: host, execution: callExecution)
            }
            // Returned effects are authoritative even for statically read-only calls.
            let envelope: JSONValue = if kind == "primitive", case .object(let fields) = receipt {
                .object(fields.filter { $0.key != "result" })
            } else { receipt }
            if case .object(let fields) = envelope { job.row["effects"] = OwnedProgramRunner.effects(fields) }
            var readIdentityFailure: String?
            if strict, !write {
                do {
                    self.readContent = .string(try readContent.digest(receipt))
                    readProjections = readContent.projections
                } catch {
                    let detail = """
                        The call returned data that cannot have a JSON identity: \(error.localizedDescription). Its returned effects are retained; repair \
                        the producing action before resuming.
                        """
                    readIdentityFailure = detail
                    stopped = ["line": .int(Int64(line)), "reason": .string("read_identity_unavailable"), "detail": .string(detail)]
                }
            }
            // Primitive result payloads are data; classify outcomes and effects only from the broker envelope.
            let receipted = if case .object(let fields) = receipt {
                fields["status"]?.scalarText != nil
                    && ["none", "occurred", "partial", "unknown"].contains(JSONValue.trimmedScalarTextOrEmpty(fields["effects"]))
                    && (!host.evidence(envelope).successful || fields["result"] != nil)
            } else { false }
            let (outcome, reason, detail): (Outcome, String, String)
            if let readIdentityFailure {
                (outcome, reason, detail) = (.unclear, "read_identity_unavailable", readIdentityFailure)
            } else if kind == "primitive", !receipted {
                (outcome, reason, detail) = (.unclear, "not_a_receipt", "The primitive returned no terminal status, effects or result.")
            } else {
                (outcome, reason, detail) = OwnedProgramRunner.classify(envelope, strict: strict || kind == "primitive", write: write, host: host)
            }
            func hand(_ receipt: JSONValue) -> JSONValue {
                guard kind == "action" || kind == "primitive", case .object(var fields) = host.answer(receipt) else { return receipt }
                if kind == "primitive" { return fields["result"] ?? .null }
                fields["call"] = .string(name)
                fields["effects"] = job.row["effects"] ?? .string(write ? "occurred" : "none")
                return .object(fields)
            }
            // The raw result stays in this call's private journal entry (`out`); its row keeps the result's measured identity only.
            do { job.row.merge(try CallLedger.measured(receipt)) { _, new in new } }
            catch {
                job.row["result_bytes"] = .null
                if part { unserializable(error) }
            }
            if kind == "action" || kind == "primitive" { record(receipt, envelope: envelope, into: &job.row) } else if case .object(let read) = receipt {
                if let version = read["version"] { job.row["version"] = version }
                if let execution = read["execution"] { job.row["execution"] = execution }
            }
            if preview, kind == "primitive", let turn = callExecution.turn, case .object(let fields) = envelope {
                if job.row["execution"] == nil, outcome == .ok {
                    job.row["execution"] = .string(host.primitiveAction(id)?.program == true ? "preview" : "executed")
                }
                if !write, let execution = job.row["execution"]?.stringValue {
                    await TurnTracePersistLane(dataRootOverride: turn.dataRoot).previewRead(id, execution: execution,
                        status: fields["status"], surface: callExecution.surface, turn: turn)
                }
            }
            if strict, case .object(let fields) = receipt {
                if kind == "read", case .string(let version)? = fields["version"] { own(version) }
                if kind == "action", host.evidence(receipt).successful, case .string(let version)? = fields["page_version"] { own(version) }
                if kind == "action", fields["reason"]?.scalarText == "stale_version", let was = input["expected_version"]?.scalarText {
                    stale = ["target": .string(OwnedProgramRunner.versionScope(was)), "was": .string(was), "now": fields["current_version"] ?? .null]
                }
            }
            if isCancelled || actionsInFlight.isCancelled {
                // Journal the completed call and replay answer before returning after Stop, so resume cannot repeat a landed write.
                stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": sourceLine(line),
                    "call": .string(name), "reason": .string("cancelled"),
                    "detail": .string("The turn was stopped; this call's actual result was kept.")]
            }
            switch outcome {
            case .ok, .preview:
                job.row["status"] = .string(job.row["captured"] == .bool(true) ? "captured" : outcome == .ok ? "ok" : "preview")
                append(.object(job.row))
                if outcome == .ok, let code = expected { return job.unexpected(code, receipt) }
                return job.answer(["ok": .bool(true), "value": hand(receipt)])
            case .failed:
                job.row["status"] = .string("failed")
                job.row["reason"] = .string(reason)
                if !detail.isEmpty { job.row["detail"] = .string(detail) }
                // Match failures against their actual changes; previews must have none.
                if strict, case .object(let fields) = envelope {
                    let effects = OwnedProgramRunner.effects(fields) ?? (fields["status"] == .string("preview") ? .string("none") : nil)
                    if let effects { job.row["effects"] = effects }
                }
                job.failed(reason)
                append(.object(job.row))
                return job.answer(["ok": .bool(false), "reason": .string(reason), "detail": .string(detail.isEmpty ? reason : detail),
                               "stopped": .bool(false), "receipt": receipt, "effects": job.row["effects"] ?? .string("unknown"),
                               "call": .string(name)])
            case .unclear:
                // Unverified completion keeps the receipt for script judgment and records unknown write effects.
                job.row["status"] = .string("unconfirmed")
                job.row["reason"] = .string(reason)
                job.row["detail"] = .string(detail)
                if write, job.row["effects"] == nil { job.row["effects"] = .string("unknown") }
                append(.object(job.row))
                if let readIdentityFailure {
                    return job.answer(["ok": .bool(false), "reason": .string("read_identity_unavailable"),
                        "detail": .string(readIdentityFailure), "stopped": .bool(true),
                        "receipt": receipt, "effects": job.row["effects"] ?? .string("unknown"), "call": .string(name)])
                }
                if let code = expected { return job.unexpected(code, receipt) }
                return job.answer(["ok": .bool(true), "value": hand(receipt)])
            case .stop:
                let previewed = if case .object(let fields) = receipt { fields["status"] == .string("preview") } else { false }
                job.row["status"] = .string(reason == "cancelled" ? "not_run" : previewed ? "preview" : "refused")
                job.row["reason"] = .string(reason)
                if !detail.isEmpty { job.row["detail"] = .string(detail) }
                append(.object(job.row))
                var stop: [String: JSONValue] = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                                                 "reason": .string(reason), "detail": .string(detail)]
                if case .object(let fields) = receipt {
                    for key in ["approvalId", "not_run_status", "remedy"] { stop[key] = fields[key] }
                }
                // An ordinary script's refused call, whatever refused it, throws to its code like any failure: caught, the script goes on and
                // ends with its own outcome; uncaught, it ends the script here (`complete`). A call a card or the screen still holds for the
                // person, a preview, Stop and strict runs stop the run at once.
                let said = receipt.objectValue ?? [:]
                let held = host.evidence(receipt).waiting || host.evidence(said["result"] ?? .null).waiting
                    || said["status"] == .string("needs_glass")
                let catchable = !strict && !preview && !previewed && !held && stopped == nil && reason != "cancelled"
                if catchable { refusals[n] = stop } else { stopped = stop }
                return job.answer(["ok": .bool(false), "reason": .string(reason), "detail": .string(detail.isEmpty ? reason : detail),
                               "stopped": .bool(!catchable), "receipt": receipt, "call": .string(name), "effects": job.row["effects"] ?? .string("none")])
            }
        }
        /// A nested call's row keeps its identity and outcome; its answer stays in the private journal entry, never in the row.
        func record(_ receipt: JSONValue, envelope: JSONValue, into row: inout [String: JSONValue]) {
            guard case .object(let fields) = receipt else { return }
            for key in ["try_instead", "remedy", "argument_path", "irreversible", "effect", "execution", "captured", "card_id",
                        "argument_form", "understood", "next_call"] { row[key] = fields[key] }
            // A receipt's declared read policy overrides static action classification.
            if let read = fields["read_only"] { row["read_only"] = read }
            if let changed = fields["changed"] { row["changed"] = changed }
            if case .object(let envelope) = envelope, let effects = OwnedProgramRunner.effects(envelope) { row["effects"] = effects }
            else if case .array(let children)? = fields["receipts"] {
                let said = children.compactMap { if case .object(let child) = $0 { OwnedProgramRunner.effects(child) } else { nil } }
                row["effects"] = [JSONValue.string("unknown"), .string("partial"), .string("occurred")].first(where: said.contains) ?? said.first
            }
            // Keep strict-call effects and real ids even when the result body exceeds the limit.
            if strict {
                let ids = OwnedProgramRunner.returnedIDs(receipt)
                if !ids.isEmpty { row["ids"] = .object(ids) }
            } else {
                // History still needs compact returned facts when an ordinary script's full result is too large.
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
            if let given = fields["reason_given"] { row["reason_given"] = given }
            for key in ["would_card", "approver", "would_hand_back"] where fields[key] != nil { row[key] = fields[key] }
            // Write destinations, shell directories and generated images travel with the receipt in one named field; the result itself does not.
            row["artifacts"] = CallLedger.artifacts(of: receipt)
            // The journal's own row also keeps `at` and `images` as before, so an older build replaying it keeps them; publication shows only
            // `artifacts`. Folded tools expose their own result without an enclosing door receipt.
            if let result = fields["action"] == nil ? receipt : fields["result"], case .object(let body) = result {
                let at = CallLedger.places(body)
                if fields["read_only"] != .bool(true), !at.isEmpty { row["at"] = .object(at) }
                row["images"] = CallLedger.images(body["images"])
            }
            if case .object(let effects)? = fields["side_effects"] {
                var seen: [String: JSONValue] = [:]
                if let raised = effects["notes_raised"], raised != .array([]) { seen["notes_raised"] = raised }
                if let knocks = effects["knocks_delivered"], knocks != .int(0) { seen["knocks_delivered"] = knocks }
                if !seen.isEmpty { row["side_effects"] = .object(seen) }
            }
        }
        func receipt() -> JSONValue {
            // Aborted replay must retain effects beyond its stopping point. The ledger is published here and only here, as metadata: a row
            // replayed from a journal written before that law still holds its raw result and is reduced on the way out. An image a call made
            // travels only when what the program returns names it.
            let said = CallLedger.texts(returned)
            let ledger = (self.ledger + replay.dropFirst(journal.count).compactMap { $0.objectValue?["row"] })
                .map { CallLedger.shown(CallLedger.published($0), naming: said) }
            var landed: [JSONValue] = [], changed: [JSONValue] = [], handed: [JSONValue] = []
            var unknown: [String] = [], unsure: [String] = []
            var card = false, partial = false
            for row in ledger {
                guard case .object(let fields) = row else { continue }
                card = card || fields["would_card"] == .bool(true)
                partial = partial || fields["effects"] == .string("partial")
                guard let call = fields["call"]?.scalarText else { continue }
                let ok = fields["status"] == .string("ok")
                let took = ["occurred", "partial"].contains(JSONValue.trimmedScalarTextOrEmpty(fields["effects"]))
                // Hand-back IDs do not require numbered source-line evidence.
                if strict, ok || took, !call.hasPrefix("read "), !call.hasPrefix("find ") {
                    var item: [String: JSONValue] = ["n": fields["n"] ?? .null, "call": .string(call)]
                    if case .object(let ids)? = fields["ids"] { item.merge(ids) { own, _ in own } }
                    handed.append(.object(item))
                }
                guard case .int(let n)? = fields["n"], case .int(let line)? = fields["line"] else { continue }
                let label = "#\(n) line \(line) \(call)"
                if ok { landed.append(.string(label)) }
                // Receipted effects take precedence over static read policy and call status.
                if fields["effects"] != nil ? took : ok && fields["read_only"] == .bool(false) {
                    changed.append(.string(label))
                }
                if fields["status"] == .string("outcome_unknown"), fields["effects"] == nil { unknown.append(label) }
                if fields["effects"] == .string("unknown") { unsure.append(label) }
            }
            // A previewed write hands the program nothing back. A program that then fails for want of it has reached the end of what a
            // preview can show; that is not a fault of the program or a verdict on the live run.
            let withheld = preview && stopped == nil && !timedOut && error?["origin"] == .string("javascript")
                && ledger.contains { $0.objectValue?["status"] == .string("preview") }
            let status = stopped != nil ? "stopped" : timedOut ? "timed_out" : error != nil && !withheld ? "error" : "ok"
            let liveNotebook = !preview && !(host is OwnedProgramFixtures)
            let notebookTook = liveNotebook && notebookChanged
            let notebookUnknown = liveNotebook && !notebookChangeKnown
            var out: [String: JSONValue] = [
                "status": .string(status),
                // A nested call's not_run verdict cannot erase work already performed by its containing program.
                "execution": .string(preview ? "preview" : status == "ok" ? "executed" : "attempted"),
                "returned": returned,
                "calls": .array(ledger),
                "notebook_changed": notebookChangeKnown ? .bool(notebookChanged) : .null,
                "landed": .array(landed),
                "side_effects_not_observed": .string("Continuations a card wakes, and anything the app does after a call returns."),
            ]
            if preview {
                out["preview"] = .bool(true)
                out["would_card"] = .bool(card)
                out["approver"] = card ? .string("owner") : .null
                out["preview_scope"] = .string("calls_reached")
            }
            if !log.isEmpty { out["log"] = .array(log.map(JSONValue.string)) }
            if var stopped {
                if refusedAfterStop > 0 { stopped["refused_after"] = .int(Int64(refusedAfterStop)) }
                out["stopped"] = .object(stopped)
                // The call it stopped on explains the stop, at the top where every reader looks first.
                if let why = stopped["detail"]?.scalarText, !why.isEmpty { out["detail"] = .string(why) }
            }
            if timedOut, let detail = error?["message"]?.scalarText {
                out["detail"] = .string(detail + " Calls already recorded retain their reported effects.")
            }
            if withheld {
                out["preview_scope"] = .string("ended_at_first_write")
                out["detail"] = .string("The preview ends at its first write: the program needs that call's result to go on. Nothing was done.")
            } else if let error {
                out["error"] = .object(error)
                if part, error["origin"] == .string("javascript") { out["detail"] = error["message"] }
            }
            out["effects"] = .string(notebookUnknown || !unknown.isEmpty || !unsure.isEmpty ? "unknown" : partial ? "partial"
                : notebookTook || !changed.isEmpty ? "occurred" : "none")
            if !changed.isEmpty { out["changed"] = .array(changed) }
            // A stopped strict run's journal is what its checkpoint or rehearsal replays; it stays private and the receipt names it.
            if strict, status == "stopped" { out["journal_ref"] = .string(OwnedProgramRunner.journals.keep(journal)) }
            if strict {
                out["steps"] = .array(steps.indices.map { i in
                    .object(["label": .string(steps[i].label), "status": .string(i == steps.count - 1 ? status : "ok")])
                })
            }
            if status != "ok" {
                // A stop belonging to the person requires their action, rather than another attempt by the agent.
                let stopReason = stopped.flatMap { $0["reason"]?.scalarText } ?? ""
                // Preserve the receipt's own stop code as failure_code.
                let code = stopReason.isEmpty ? error.flatMap { $0["reason"]?.scalarText } ?? "" : stopReason
                if !code.isEmpty { out["reason"] = .string(code) }
                let users = host.floorReasons.contains(stopReason) || stopReason == "needs_glass"
                let cardPreview = preview && code == "would_card"
                let cardInstruction = "Preview stopped at a call that would raise the owner's approval card; no card was filed. "
                    + "Run the action outside preview when you want to request their approval."
                let asked = strict && stopReason == "decide"
                let ask = "It stopped to ask you hand_back.question: decide, then do only what is left."
                // Identify calls by sequence and arguments because every call in a one-line script shares its source line.
                let at = stopped ?? error
                let n = at?["n"]?.scalarText
                let which = n.map { "Call \($0)" + (at?["call"]?.scalarText.map { " (\($0))" } ?? "") }
                    ?? "Line \(at?["line"]?.scalarText ?? "?")"
                let drop = "\(which) is the owner's (\(stopReason)): drop that call and run the rest if you still want it."
                let check = (unknown + unsure).joined(separator: ", ")
                    + (unknown.isEmpty ? " ended with its effects unknown" : " got no answer") + ", so whether it took effect is unknown: "
                    + "read the page to check before running it again, then do only what is left."
                let nothing = landed.isEmpty ? "Nothing landed. " : "Nothing changed. "
                out["remedy"] = .object([
                    "kind": .string(users ? "drop_owners_line" : asked ? "decide"
                        : cardPreview ? "request_approval" : "read_ledger"),
                    "instruction": .string(changed.isEmpty && !notebookTook && !notebookUnknown
                        ? (!unknown.isEmpty || !unsure.isEmpty ? check
                            : users ? nothing + drop : asked ? nothing + ask
                            : cardPreview ? cardInstruction : nothing + (at?["instruction"]?.scalarText
                                ?? "Fix what stopped it, then run it again."))
                        : (changed.isEmpty ? "" : "The calls in changed took effect; don't run them again. ")
                            + (!unknown.isEmpty || !unsure.isEmpty ? check : users ? drop : asked ? ask
                                : "Inspect the recorded effects, then do only what is left.")),
                    "next_call": .null,
                ])
                if let recovery = at?["remedy"], recovery != .null {
                    out["remedy"] = recovery
                }
                out["try_instead"] = at?["try_instead"]
                if timedOut, part, at?["remedy"] == nil || at?["remedy"] == .null {
                    out["remedy"] = Repair.reconcile(
                        instruction: """
                            Read ability \(partID) version \(partVersion) and its recorded effects. Revise the reported cause with ability.save, then keep \
                            the reviewed version; do not replay observed effects.
                            """,
                        nextCall: .object([
                            "tool": .string("app"),
                            "input": .object(["action": .string("ability.read"), "args": .object(["id": .string(partID)])])]))
                }
                if notebookUnknown || notebookTook, var remedy = out["remedy"]?.objectValue,
                   let instruction = remedy["instruction"]?.stringValue {
                    let evidence = notebookUnknown
                        ? "A notebook write has an unconfirmed result. Check the ability's notebook before repeating a write. "
                        : "The ability's notebook changed. Do not repeat its completed writes. "
                    remedy["instruction"] = .string(evidence + instruction)
                    out["remedy"] = .object(remedy)
                }
                if strict {
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
                    if code == "stale_version", let stale { back["difference"] = .object(stale) }
                    out["hand_back"] = .object(back)
                }
            }
            return .object(out)
        }
    }

    /// The one owner that settles a stopped strict run (its checkpoint, or a rehearsal's next pass) takes the run's replay journal by the receipt's
    /// `journal_ref`, once. Nothing else, no trace, transcript or experience included, ever holds the raw journal.
    public static func journal(_ reference: JSONValue?) -> [JSONValue]? { journals.take(reference?.stringValue) }
    static let journals = Journals()
    /// Private replay journals waiting for their settling owner, in process only. At most `held` wait; the oldest unclaimed one leaves first.
    final class Journals: Sendable {
        static let held = 16
        private let waiting = Mutex<[(id: String, journal: [JSONValue])]>([])
        func keep(_ journal: [JSONValue]) -> String {
            let id = "journal-" + UUID().uuidString.lowercased()
            waiting.withLock { waiting in
                waiting.append((id, journal))
                if waiting.count > Self.held { waiting.removeFirst(waiting.count - Self.held) }
            }
            return id
        }
        func take(_ id: String?) -> [JSONValue]? {
            guard let id else { return nil }
            return waiting.withLock { waiting in
                guard let at = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: at).journal
            }
        }
    }
}
