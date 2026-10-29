import AuthoredCapabilities
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramJournal.swift` | Request-owned mutable replay, receipt and read-freshness journal |
extension OwnedProgramRunner {
    final class Journal {
        let lines: [Substring]
        let preview: Bool
        let strict: Bool
        /// One of her parts: bounded by its progress and
        /// its receipt ledger, never by a count of calls.
        let part: Bool
        let programEntry: OwnedProgram.Entry
        let partVersion: String
        let replay: [JSONValue]
        let answer: JSONValue
        let recheckReads: Bool
        let host: any OwnedProgramHostProfile
        let actionsInFlight: ActionTasks
        var notebookRoot: URL
        let partID: String
        // Only the requesting task mutates this journal.
        var ledger: [JSONValue] = []
        var ledgerBytes = 0
        var log: [String] = []
        var logBytes = 0
        var actions = 0
        var reads = 0
        var stopped: [String: JSONValue]?
        var refusedAfterStop = 0
        /// The call in flight leaves no ledger row (OwnedProgramAction.journaled).
        var unjournaled = false
        var returned: JSONValue = .null
        var returnedNote: String?
        var error: [String: JSONValue]?
        var timedOut = false
        /// A strict run's step labels and guidance, as `app.step` declared them.
        var steps: [(label: String, guidance: String)] = []
        /// The failure code the next call is declared to fail with
        /// (`app.expect_fail`), whether that call has run, and how it failed.
        var expectFail: String?
        var expectFailSeen = false
        var expectFailMatched = false
        var expectFailOther: String?
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
        /// A strict run's own versions: each page's newest, from its own reads
        /// and its writes' page_version. A write goes on its page's; one it
        /// passes itself must be one the run read; never a fresh read.
        var newest: [String: String] = [:]
        var seen: Set<String> = []
        /// The last write whose own version no longer read: target, was, now.
        var stale: [String: JSONValue]?
        /// Where the stopped run's own writes landed, by journal position, and
        /// the page_version each left: a read it made before one of them on the
        /// same page or item replays as saved, since its own write explains the
        /// difference, once what its last such write left still reads the same.
        let ownWrites: [(at: Int, page: String, item: String?, version: String?)]
        var isCancelled: Bool { Task.isCancelled }
        init(source: String, preview: Bool, program: OwnedProgram, replay: Replay?,
             host: any OwnedProgramHostProfile, actionsInFlight: ActionTasks, notebookRoot: URL, partID: String) {
            self.lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            self.preview = preview; self.strict = program.isStrict
            self.part = program.isPart
            self.programEntry = program.entry
            self.partVersion = program.version
            self.replay = replay?.journal ?? []; self.answer = replay?.answer ?? .null
            self.recheckReads = replay?.recheckReads ?? true
            self.host = host; self.actionsInFlight = actionsInFlight
            self.notebookRoot = notebookRoot; self.partID = partID
            self.ownWrites = (replay?.journal ?? []).enumerated().compactMap { at, entry in
                // A write that landed, or may have: a failure caught after it changed something counts too.
                guard let target = OwnedProgramRunner.target(entry, host: host), target.write, case .object(let fields) = entry,
                      case .object(let row)? = fields["row"],
                      ["ok", "unconfirmed"].contains(row["status"]?.scalarText ?? "")
                          || ["occurred", "partial", "unknown"].contains(row["effects"]?.scalarText ?? "") else { return nil }
                let out = fields["out"]?.scalarText.map(OwnedProgramRunner.readValue)
                let version: String? = if case .object(let value)? = out { value["page_version"]?.scalarText } else { nil }
                return (at, target.page, target.item, version)
            }
            for version in OwnedProgramRunner.ownVersions(replay?.journal ?? []) { own(version) }
        }
        func own(_ version: String) {
            newest[String(OwnedProgramRunner.versionScope(version).split(separator: "/").first ?? "")] = version
            seen.insert(version)
        }
        func complete(_ fields: [String: JSONValue]) {
            if case .object(var report)? = fields["exception"], stopped == nil {
                report["origin"] = .string("javascript")
                let message = report["message"]?.scalarText ?? "error"
                if report["name"] == .string("SyntaxError") {
                    report["reason"] = .string("script_syntax")
                    report["rule"] = .string("javascript_function_body")
                    report["instruction"] = .string("Fix the JavaScript syntax reported in message at line. "
                        + "Top-level await is not supported: app.* calls return synchronously. Use const result = app.read(\"inbox\"); return result; without await.")
                }
                if let name = message.range(of: #"(?<=Can't find variable: )\w+"#, options: .regularExpression).map({ String(message[$0]) }) {
                    if host.actionIDs.contains(where: { $0.hasPrefix(name + ".") }) {
                        report["reason"] = .string("script_name")
                        report["instruction"] = .string("Inside a script, actions live under app: use app.\(name).… (for example app.\(name).\(host.actionIDs.first { $0.hasPrefix(name + ".") }.map { String($0.dropFirst(name.count + 1)) } ?? "…")()).")
                    } else if name == "host" {
                        // Drive wave 10-28: `host` is an ability's door, not a script's.
                        report["reason"] = .string("script_name")
                        report["instruction"] = .string("`host` exists only inside a saved ability (ability.save): an ad-hoc app script has app.* and nothing else. Use app.<page>.<action>() here, or save the code as an ability and run authored.<id>.")
                    }
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
            returnedNote = fields["returnedNote"]?.scalarText
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
            // host.call(id, args) is app.<id>(args) unless id is one of the host's own primitives.
            let kind = kind == "primitive" && host.primitiveAction(id) == nil ? "action" : kind
            let id = kind == "action" ? (host.canonicalAction(id)) : id
            guard strict, ["action", "primitive", "read", "find", "decide", "state"].contains(kind), stopped == nil else {
                return await dispatch(kind: kind, id: id, args: args, line: line)
            }
            let signature = JSONValue.array([.string(kind), .string(id), .string(args), .int(Int64(line))])
            guard replayed < replay.count else {
                let rows = ledger.count
                let out = await dispatch(kind: kind, id: id, args: args, line: line)
                retain(.object(["call": signature, "out": .string(out),
                                        "row": ledger.count > rows ? ledger[ledger.count - 1] : .null,
                                        "read_content": readContent, "read_projections": readProjections]))
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
                let given: [JSONValue] = if case .array(let list)? = try? JSONValue.parse(Data(args.utf8)) { list } else { [] }
                let named: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
                read = host.primitiveAction(id)?.readOnly(named) == true
            } else {
                read = host.action(id)?.read == true
            }
            let reread = recheckReads && Self.status(row) != "answered"
                && (kind == "read" || kind == "find" || (["action", "primitive"].contains(kind) && read))
                && (kind != "action" || host.action(id)?.advisory != true)
            /// What it went on from reads differently now: nothing more runs.
            func changed(_ name: String, was: JSONValue, now: JSONValue) -> String {
                let detail = "\(name) reads differently than when this run stopped, so nothing more ran: what it "
                    + "went on from has changed. Read the recorded effects before deciding what remains."
                stopped = ["line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                           "reason": .string("state_changed"), "detail": .string(detail), "was": was, "now": now]
                return encode(["ok": .bool(false), "reason": .string("state_changed"), "detail": .string(detail),
                               "stopped": .bool(true)], line: line, n: n)
            }
            if replayed == replay.count {
                // Where it stopped: her answer, never the call, a read included.
                out = encode(["ok": .bool(true), "value": answer], line: line, n: n)
                if case .object(var fields) = row {
                    for key in ["reason", "detail", "result"] { fields.removeValue(forKey: key) }
                    fields["status"] = .string("answered")
                    row = .object(fields)
                }
            } else if reread, let mine = writtenLater(replay[replayed - 1], at: replayed - 1) {
                // A read the run itself later wrote over replays as saved, below, once what
                // its last such write left reads the same now: a change since is another's.
                if let left = mine.version, let now = await currentVersion(left), now != left {
                    return changed("read " + OwnedProgramRunner.versionScope(left), was: .string(left), now: .string(now))
                }
            } else if reread {
                // Authoritative reads must still match; advisory answers replay as saved.
                let now = await dispatch(kind: kind, id: id, args: args, line: line)
                // Refusals before dispatch have no read content; the refusal itself must match.
                guard stopped == nil, let content = entry["read_content"], readContent == content,
                      content != .null || replayContent.normalize(OwnedProgramRunner.readValue(now))
                          == replayContent.normalize(OwnedProgramRunner.readValue(out)) else {
                    let name = kind == "action" ? id : ledger.last.flatMap { if case .object(let row) = $0 { row["call"]?.scalarText } else { nil } } ?? kind
                    return changed(name, was: OwnedProgramRunner.brief(out), now: OwnedProgramRunner.brief(now))
                }
                // Both saved and fresh bindings share the result owner's content contract.
                replayContent.include(entry["read_projections"] ?? .null)
                replayContent.include(readProjections)
                // Passing reads return fresh bindings for the resumed run's later actions.
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
            retain(.object(["call": signature, "out": .string(out), "row": row,
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
        /// Where the stopped run itself wrote, after this read, the page or
        /// item it read (a landed write, exempt or versioned): the last such.
        func writtenLater(_ entry: JSONValue, at index: Int) -> (at: Int, page: String, item: String?, version: String?)? {
            guard let read = OwnedProgramRunner.target(entry, host: host), !read.write else { return nil }
            return ownWrites.last { $0.at > index && $0.page == read.page
                && (read.item == nil || $0.item == nil || $0.item == read.item) }
        }
        /// The version a read of `version`'s page or item returns now; nil when
        /// it returns none of that scope, so nothing can be told. One that no
        /// longer reads at all (the page or item gone) reads as "": changed.
        func currentVersion(_ version: String) async -> String? {
            let scope = OwnedProgramRunner.versionScope(version)
            let parts = scope.split(separator: "/", maxSplits: 1).map { JSONValue.string(String($0)) }
            guard let page = parts.first else { return nil }
            var input: [String: JSONValue] = ["page": page, host.scriptKey: .bool(true)]
            if parts.count > 1 { input["item"] = parts[1] }
            guard case .object(let read) = await actionsInFlight.perform(input, host: host) else { return nil }
            guard let now = read["version"]?.scalarText else {
                return read["status"] == .string("failed") || read["ok"] == .bool(false) ? "" : nil
            }
            return OwnedProgramRunner.versionScope(now) == scope ? now : nil
        }
        /// A ledger row's status; an answered one replays as saved, never run again.
        static func status(_ row: JSONValue) -> String {
            if case .object(let fields) = row { fields["status"]?.scalarText ?? "" } else { "" }
        }
        func encode(_ fields: [String: JSONValue], line: Int, n: Int) -> String {
            var fields = fields
            fields["line"] = .int(Int64(line))
            fields["n"] = .int(Int64(n))
            return (try? JSONValue.object(fields).serialize(pretty: false)) ?? #"{"ok":false,"reason":"internal","detail":"unreadable"}"#
        }
        func append(_ row: JSONValue) {
            guard !unjournaled else { return }
            if part { ledgerBytes += (try? row.serializedData(pretty: false).count) ?? 0 }
            ledger.append(row)
        }
        /// A strict run's replay entry: its full reply, args and projections
        /// are kept too, so they count against the same budget as the ledger.
        func retain(_ entry: JSONValue) {
            if part { ledgerBytes += (try? entry.serializedData(pretty: false).count) ?? 0 }
            journal.append(entry)
        }
        /// One call, run: checks the stop and the limits, hands the call to
        /// the caller's task, waits, and records it.
        func dispatch(kind: String, id: String, args: String, line: Int) async -> String {
            readContent = .null
            readProjections = .array([])
            unjournaled = kind == "primitive" && host.primitiveAction(id)?.journaled == false
            if part, ledgerBytes >= 4 * 1024 * 1024 {
                stopped = ["reason": .string("output_limit"), "detail": .string("The run's receipt ledger reached 4 MiB; no further call ran.")]
                return encode(["ok": .bool(false), "reason": .string("output_limit"),
                               "detail": stopped?["detail"] ?? .null, "stopped": .bool(true)], line: line, n: ledger.count + 1)
            }
            let n = ledger.count + 1
            var row: [String: JSONValue] = ["n": .int(Int64(n)), "line": .int(Int64(line))]
            if strict, !steps.isEmpty { row["step"] = .int(Int64(steps.count)) }
            let given: [JSONValue] = if case .array(let list)? = try? JSONValue.parse(Data(args.utf8)) { list } else { [] }
            let named: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
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
                    return mark("expected_failure_not_seen", "app.expect_fail(\"\(code)\") saw no call fail with \(code)"
                        + (expectFailOther.map { "; it failed with \($0)." } ?? "."))
                }
                return answer(["ok": .bool(true), "value": .null])
            }
            if let stopped {
                refusedAfterStop += 1
                let at = stopped["line"]?.scalarText ?? "?"
                return refuse("stopped", "The script stopped at line \(at); no app call runs after that.", stop: true)
            }
            if kind == "state" {
                if programEntry == .face { return refuse("projection_only", "A face reads only its frozen sources, never a notebook.", stop: true) }
                guard case .array(let values)? = try? JSONValue.parse(Data(args.utf8)),
                      id == "get" && values.isEmpty || id == "set" && values.count == 1 else {
                    return refuse("bad_state", "Use host.state.get() or host.state.set(value).", stop: false)
                }
                do {
                    let value = try AbilityStore.notebook(dataRoot: notebookRoot, id: partID,
                        setting: id == "set", value: values.first ?? .null, failure: { SenseFailure(code: $0, message: $1) })
                    return answer(["ok": .bool(true), "value": value])
                } catch { return refuse("bad_state", error.localizedDescription, stop: false) }
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
                func text(_ i: Int) -> String { given.indices.contains(i) ? given[i].scalarText ?? "" : "" }
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
                    expectFail = text(0); expectFailSeen = false; expectFailMatched = false; expectFailOther = nil
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
            // An expect_fail wraps one call; a second call inside it does not run.
            if expectFail != nil, expectFailSeen {
                return halt("expect_fail_one_call", "app.expect_fail wraps one app call; this second one did not run.",
                            call: kind == "action" ? id : kind)
            }
            let expected = expectFail
            if expected != nil { expectFailSeen = true }
            /// A call's failure is the script's to read: it throws there as
            /// an AppError the script may catch, and the run goes on. Only the
            /// script's own throw, a stop of its own (expect, decide) or the
            /// turn's cancel ends a run; the ledger keeps every call's effects.
            func failed(_ reason: String) {
                guard expected != nil else { return }
                if reason == expected { row["expected"] = .bool(true); expectFailMatched = true } else { expectFailOther = reason }
            }
            /// Refused before it ran: nothing changed.
            func refused(_ reason: String, _ detail: String, call name: String) -> String {
                row["call"] = .string(name)
                row["status"] = .string("failed")
                row["reason"] = .string(reason)
                row["detail"] = .string(detail)
                row["effects"] = .string("none")
                failed(reason)
                append(.object(row))
                return answer(["ok": .bool(false), "reason": .string(reason), "detail": .string(detail), "stopped": .bool(false),
                               "effects": .string("none"), "call": .string(name)])
            }
            func stopCall(_ reason: String, _ detail: String, call name: String, receipt: JSONValue?) -> String {
                stopped = ["n": .int(Int64(n)), "line": .int(Int64(line)), "source": sourceLine(line), "call": .string(name),
                           "reason": .string(reason), "detail": .string(detail)]
                if case .object(let fields)? = receipt {
                    for key in ["nearest", "remedy", "argument_path"] { stopped?[key] = fields[key] }
                }
                var fields: [String: JSONValue] = ["ok": .bool(false), "reason": .string(reason), "detail": .string(detail),
                                                   "stopped": .bool(true), "call": .string(name), "effects": row["effects"] ?? .string("none")]
                if let receipt { fields["receipt"] = receipt }
                return answer(fields)
            }
            /// The call an expect_fail declared did not fail: her assertion stops the run.
            func unexpected(_ code: String, _ receipt: JSONValue) -> String {
                stopCall("expected_failure_succeeded", "This call was declared to fail with \(code) (app.expect_fail), "
                    + "but it answered without failing; the run stopped.", call: row["call"]?.scalarText ?? kind, receipt: receipt)
            }
            if isCancelled {
                return halt("cancelled", "The turn was stopped, so no app call runs from here.", call: kind == "action" ? id : kind)
            }
            var input: [String: JSONValue]
            let name: String
            switch kind {
            case "primitive":
                name = id
                guard given.count <= 1 else {
                    return refused("invalid_args", "\(id) takes one named-argument object; nothing ran.", call: name)
                }
                guard part || actions < OwnedProgramRunner.actionLimit else {
                    return halt("action_limit", "A script does at most \(OwnedProgramRunner.actionLimit) actions.", call: name)
                }
                actions += 1
                input = [:]
            case "action":
                name = id
                guard part || actions < OwnedProgramRunner.actionLimit else {
                    return halt("action_limit", "A script does at most \(OwnedProgramRunner.actionLimit) actions.", call: name)
                }
                switch host.doorInput(id: id, given: given) {
                case .success(let built):
                    input = built
                    // A program is calling, as on its reads.
                    if !host.scriptKey.isEmpty { input[host.scriptKey] = .bool(true) }
                case .failure(let problem): return refused(problem.reason, problem.detail, call: name)
                }
                // A strict run's write goes on the version of the page it read.
                let callArgs: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
                if strict, let action = host.action(id), action.versioned, !action.readOnly(callArgs) {
                    if case .string(let given)? = input["expected_version"], !given.isEmpty {
                        guard seen.contains(given) else {
                            return refused("not_own_version", "\(id) passed a version this run never read; an ability's write goes on its own read's version. It was not run.", call: name)
                        }
                    } else if let version = newest[action.page] { input["expected_version"] = .string(version) }
                }
                actions += 1
                if preview { input["preview"] = .bool(true) }
            default:
                row["read_only"] = .bool(true)
                row["effects"] = .string("none")
                let words = given.compactMap(\.scalarText)
                name = kind == "find" ? "find " + (words.first ?? "") : "read " + words.joined(separator: "/")
                if kind == "read", given.count > 2 {
                    row["argument_path"] = .string("app.read.arguments[2]")
                    return refused("invalid_args", "app.read takes page and optional item, not extra arguments. Use app.<action>({args}) "
                        + "to select a target. Nothing was read.", call: name)
                }
                guard part || reads < OwnedProgramRunner.readLimit else {
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
                    return refused("action_required", "A home item can send or change something, so a script never opens one. "
                        + "Read home with app.read(\"home\") and open the item yourself.", call: name)
                }
            }
            row["call"] = .string(name)
            let arguments = if case .object(let args)? = input["args"] { args } else { named }
            let write = kind == "primitive" ? host.primitiveAction(id)?.readOnly(named) != true
                : kind == "action" && host.action(id)?.readOnly(arguments) != true
            // read_only is the call's class (what it may do, what a resume re-runs); effects is what it did.
            row["read_only"] = .bool(!write)
            let readContent = ReadContent()
            let receipt: JSONValue = await ReadContent.$current.withValue(readContent) {
                if kind == "primitive", preview, write, host.primitiveAction(id)?.program != true {
                    return .object(["status": .string("preview"), "effects": .string("none"), "result": .null])
                }
                if kind == "primitive" { return await actionsInFlight.primitive(id, arguments: given.first ?? .null, preview: preview, host: host) }
                return await actionsInFlight.perform(input, host: host)
            }
            // The returned effects are authoritative, even for a statically read-only call.
            let envelope: JSONValue = if kind == "primitive", case .object(let fields) = receipt {
                .object(fields.filter { $0.key != "result" })
            } else { receipt }
            if case .object(let fields) = envelope { row["effects"] = OwnedProgramRunner.effects(fields) }
            if strict, !write {
                self.readContent = .string(readContent.digest(receipt))
                readProjections = readContent.projections
            }
            guard !isCancelled, !actionsInFlight.isCancelled else {
                row["status"] = .string("cancelled")
                if write, row["effects"] == nil { row["effects"] = .string("unknown") }
                append(.object(row))
                return stopCall("cancelled", "The turn was stopped while this call was running.", call: name, receipt: receipt)
            }
            // A primitive's result is data, never another receipt. All outcome
            // and effect classification reads only the broker's envelope.
            let receipted = if case .object(let fields) = receipt {
                fields["status"]?.scalarText != nil && ["none", "occurred", "partial", "unknown"].contains(text(fields["effects"]))
                    && (!host.evidence(envelope).successful || fields["result"] != nil)
            } else { false }
            let (outcome, reason, detail): (Outcome, String, String)
            if kind == "primitive", !receipted {
                (outcome, reason, detail) = (.unclear, "not_a_receipt", "The primitive returned no terminal status, effects or result.")
            } else {
                (outcome, reason, detail) = OwnedProgramRunner.classify(envelope, strict: strict || kind == "primitive", write: write, host: host)
            }
            /// What her code gets back from an action: the tool's own data, the
            /// call it made (an id she can pass back) and what it changed.
            func hand(_ receipt: JSONValue) -> JSONValue {
                guard kind == "action" || kind == "primitive", case .object(var fields) = host.answer(receipt) else { return receipt }
                if kind == "primitive" { return fields["result"] ?? .null }
                fields["call"] = .string(name)
                fields["effects"] = row["effects"] ?? .string(write ? "occurred" : "none")
                return .object(fields)
            }
            if kind == "action" || kind == "primitive" { record(receipt, envelope: envelope, into: &row) } else if case .object(let read) = receipt {
                if let version = read["version"] { row["version"] = version }
            }
            if strict, case .object(let fields) = receipt {
                if kind == "read", case .string(let version)? = fields["version"] { own(version) }
                if kind == "action", host.evidence(receipt).successful, case .string(let version)? = fields["page_version"] { own(version) }
                if kind == "action", fields["reason"]?.scalarText == "stale_version", let was = input["expected_version"]?.scalarText {
                    stale = ["target": .string(OwnedProgramRunner.versionScope(was)), "was": .string(was), "now": fields["current_version"] ?? .null]
                }
            }
            switch outcome {
            case .ok, .preview:
                row["status"] = .string(row["captured"] == .bool(true) ? "captured" : outcome == .ok ? "ok" : "preview")
                append(.object(row))
                if outcome == .ok, let code = expected { return unexpected(code, receipt) }
                return answer(["ok": .bool(true), "value": hand(receipt)])
            case .failed:
                row["status"] = .string("failed")
                row["reason"] = .string(reason)
                if !detail.isEmpty { row["detail"] = .string(detail) }
                // A strict run reads what the failure changed before it
                // matches it: a preview changed nothing.
                if strict, case .object(let fields) = envelope {
                    let effects = OwnedProgramRunner.effects(fields) ?? (fields["status"] == .string("preview") ? .string("none") : nil)
                    if let effects { row["effects"] = effects }
                }
                failed(reason)
                append(.object(row))
                return answer(["ok": .bool(false), "reason": .string(reason), "detail": .string(detail.isEmpty ? reason : detail),
                               "stopped": .bool(false), "receipt": receipt, "effects": row["effects"] ?? .string("unknown"),
                               "call": .string(name)])
            case .unclear:
                // It answered, but not a clear success (a press that ran
                // unverified): the script reads the receipt and decides; the
                // ledger keeps the doubt, and a write's effects are unknown.
                row["status"] = .string("unconfirmed")
                row["reason"] = .string(reason)
                row["detail"] = .string(detail)
                if write, row["effects"] == nil { row["effects"] = .string("unknown") }
                append(.object(row))
                if let code = expected { return unexpected(code, receipt) }
                return answer(["ok": .bool(true), "value": hand(receipt)])
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
                return answer(["ok": .bool(false), "reason": .string(reason), "detail": .string(detail.isEmpty ? reason : detail),
                               "stopped": .bool(true), "call": .string(name), "effects": row["effects"] ?? .string("none")])
            }
        }
        /// What the call changed and what else the app did, kept short; the
        /// script itself got the whole receipt.
        func record(_ receipt: JSONValue, envelope: JSONValue, into row: inout [String: JSONValue]) {
            guard case .object(let fields) = receipt else { return }
            for key in ["nearest", "remedy", "argument_path", "irreversible", "effect", "execution", "captured", "card_id"] { row[key] = fields[key] }
            // A receipt's read policy overrides the static fallback for an action.
            if let read = fields["read_only"] { row["read_only"] = read }
            if let changed = fields["changed"] { row["changed"] = changed }
            if case .object(let envelope) = envelope, let effects = OwnedProgramRunner.effects(envelope) { row["effects"] = effects }
            // A batch answers through its receipts: its row carries what they did.
            else if case .array(let children)? = fields["receipts"] {
                let said = children.compactMap { if case .object(let child) = $0 { OwnedProgramRunner.effects(child) } else { nil } }
                row["effects"] = [JSONValue.string("unknown"), .string("partial"), .string("occurred")].first(where: said.contains) ?? said.first
            }
            // A strict run keeps each call's effects and real ids, however
            // long its result.
            if strict {
                let ids = OwnedProgramRunner.returnedIDs(receipt)
                if !ids.isEmpty { row["ids"] = .object(ids) }
            } else {
                // Ordinary scripts need the same small returned facts for
                // later history, even when the result body is too large.
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
                // Where a write landed rides its row however long its result:
                // the file (a move's destination), or a shell call's directory.
                if fields["read_only"] != .bool(true), case .object(let body) = result {
                    let at = body.filter { key, value in
                        guard ["path", "destination", "cwd"].contains(key), case .string(let place) = value else { return false }
                        return place.hasPrefix("/")
                    }
                    if !at.isEmpty { row["at"] = .object(at) }
                }
                // So do the images a generation made: they go with her reply.
                if case .object(let body) = result, case .array(let images)? = body["images"] {
                    let made = images.compactMap { image -> JSONValue? in
                        guard case .object(let made) = image, let path = made["path"] else { return nil }
                        return .object(["path": path])
                    }
                    if !made.isEmpty { row["images"] = .array(made) }
                }
            }
            if case .object(let effects)? = fields["side_effects"] {
                var seen: [String: JSONValue] = [:]
                if let raised = effects["notes_raised"], raised != .array([]) { seen["notes_raised"] = raised }
                if let knocks = effects["knocks_delivered"], knocks != .int(0) { seen["knocks_delivered"] = knocks }
                if !seen.isEmpty { row["side_effects"] = .object(seen) }
            }
        }
        func receipt() -> JSONValue {
            // Aborted replay retains effects beyond the point where it stopped.
            let ledger = self.ledger + replay.dropFirst(journal.count).compactMap { $0.objectValue?["row"] }
            var landed: [JSONValue] = [], changed: [JSONValue] = [], handed: [JSONValue] = []
            var unknown: [String] = [], unsure: [String] = []
            var card = false, partial = false
            for row in ledger {
                guard case .object(let fields) = row else { continue }
                card = card || fields["would_card"] == .bool(true)
                partial = partial || fields["effects"] == .string("partial")
                guard let call = fields["call"]?.scalarText else { continue }
                let ok = fields["status"] == .string("ok")
                let took = ["occurred", "partial"].contains(text(fields["effects"]))
                // Hand-back IDs do not require the numbered source-line evidence.
                if strict, ok || took, !call.hasPrefix("read "), !call.hasPrefix("find ") {
                    var item: [String: JSONValue] = ["n": fields["n"] ?? .null, "call": .string(call)]
                    if case .object(let ids)? = fields["ids"] { item.merge(ids) { own, _ in own } }
                    handed.append(.object(item))
                }
                guard case .int(let n)? = fields["n"], case .int(let line)? = fields["line"] else { continue }
                let label = "#\(n) line \(line) \(call)"
                if ok { landed.append(.string(label)) }
                // Receipted effects win over static read policy and call status.
                if fields["effects"] != nil ? took : ok && (fields["read_only"] ?? .bool(host.action(call)?.read == true)) != .bool(true) {
                    changed.append(.string(label))
                }
                if fields["status"] == .string("outcome_unknown"), fields["effects"] == nil { unknown.append(label) }
                if fields["effects"] == .string("unknown") { unsure.append(label) }
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
            if timedOut, let detail = error?["message"]?.scalarText {
                out["detail"] = .string(detail + " Calls already recorded retain their reported effects.")
            }
            if let error { out["error"] = .object(error) }
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
                let stopReason = stopped.flatMap { $0["reason"]?.scalarText } ?? ""
                // Keep the receipt's own stop code as failure_code.
                let code = stopReason.isEmpty ? error.flatMap { $0["reason"]?.scalarText } ?? "" : stopReason
                if !code.isEmpty { out["reason"] = .string(code) }
                let users = host.floorReasons.contains(stopReason) || stopReason == "needs_glass"
                let cardPreview = preview && code == "would_card"
                let cardInstruction = "Preview stopped at a call that would raise the owner's approval card; no card was filed. "
                    + "Run the action outside preview when you want to request their approval."
                let asked = strict && stopReason == "decide"
                let ask = "It stopped to ask you hand_back.question: decide, then do only what is left."
                // The call by its number and what it asked, not its line: a
                // one-line script has every call on line 1.
                let at = stopped ?? error
                let n = at?["n"]?.scalarText
                let which = n.map { "Call \($0)" + (at?["call"]?.scalarText.map { " (\($0))" } ?? "") }
                    ?? "Line \(at?["line"]?.scalarText ?? "?")"
                let drop = "\(which) is the owner's (\(stopReason)): drop that call and run the rest if you still want it."
                let check = (unknown + unsure).joined(separator: ", ")
                    + (unknown.isEmpty ? " ended with its effects unknown" : " got no answer") + ", so whether it took effect is unknown: "
                    + "read the page to check before running it again, then do only what is left."
                // Reads that landed changed nothing.
                let nothing = landed.isEmpty ? "Nothing landed. " : "Nothing changed. "
                out["remedy"] = .object([
                    "kind": .string(users ? "drop_owners_line" : asked ? "decide"
                        : cardPreview ? "request_approval" : "read_ledger"),
                    "instruction": .string(changed.isEmpty
                        ? (!unknown.isEmpty || !unsure.isEmpty ? check
                            : users ? nothing + drop : asked ? nothing + ask
                            : cardPreview ? cardInstruction : nothing + (at?["instruction"]?.scalarText
                                ?? "Fix what stopped it, then run it again."))
                        : "The calls in changed took effect; don't run them again. "
                            + (!unknown.isEmpty || !unsure.isEmpty ? check : users ? drop : asked ? ask
                                : "Read the page, then do only what is left.")),
                    "next_call": .null,
                ])
                if let recovery = at?["remedy"], recovery != .null {
                    out["remedy"] = recovery
                    out["nearest"] = at?["nearest"]
                }
                if timedOut, part, at?["remedy"] == nil || at?["remedy"] == .null {
                    out["remedy"] = Repair.reconcile(
                        instruction: "Read ability \(partID) version \(partVersion) and its recorded effects. Revise the reported cause with ability.save, then keep the reviewed version; do not replay observed effects.",
                        nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("ability.read"), "args": .object(["id": .string(partID)])])]))
                }
                // A strict run hands back: its step, what landed by real id,
                // and the one question when it asked one.
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
}
