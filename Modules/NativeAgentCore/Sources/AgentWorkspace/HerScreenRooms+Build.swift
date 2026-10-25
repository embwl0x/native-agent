import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
// Blueprint: | `HerScreenRooms+Build.swift` | `HerScreen`: `buildRoom`, `buildTarget`, `buildRecordRoom` |

/// Her-screen rooms for files and code (2026-09-24). Each opens by name
/// (`files`, `code`) as a short text room, and its rows and verbs act by name
/// (`files.3`, `code.diff`). Only local, cheap reads: the workspace folder's
/// newest files, one `git status` and `git log` on the source checkout, and
/// the builder's own audit receipts. No network; nothing on home.
enum AgentWorkspaceBuild {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "code", title: "Code", summary: "The source checkout: branch, changes, commits and recent builder runs.",
              tool: nil, tools: ["git_diff", "git_log", "shell", "swift_build"]),
    ]

    /// Reads these rooms' names open; each is the owner's ordinary tool.
    static let readTools: Set<String> = ["git_diff", "git_log", "clipboard_read"]
}

extension HerScreen {
    static func buildRoom(_ location: AgentWorkspaceLocation, dataRoot: URL, now: Date) async -> String? {
        switch location {
        case .area("files"): return filesRoom(dataRoot: dataRoot, now: now)
        case .area("code"): return await codeRoom(dataRoot: dataRoot, now: now)
        default: return nil
        }
    }

    /// A name from these rooms to its action, or nil.
    static func buildTarget(_ name: String, dataRoot: URL) -> Target? {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 2, ["files", "code", "clipboard"].contains(parts[0]) else { return nil }
        func read(_ tool: String, _ input: [String: JSONValue], _ title: String, text: String? = nil) -> Target {
            .action(.perform(tool: tool, input: input, title: title, textField: text, isEffect: false))
        }
        func effect(_ tool: String, _ input: [String: JSONValue], _ title: String, text: String? = nil) -> Target {
            .action(.perform(tool: tool, input: input, title: title, textField: text, isEffect: true))
        }
        switch (parts[0], parts[1], parts.count) {
        case ("files", "new", 2): return .action(.configure(tool: "write_file", input: [:], title: "New file"))
        case ("files", "find", 2): return read("artifact_find", [:], "Find a document", text: "query")
        case ("clipboard", "read", 2): return read("clipboard_read", [:], "Clipboard")
        case ("clipboard", "copy", 2): return effect("clipboard_write", [:], "Copy to the clipboard", text: "text")
        case ("code", "diff", 2): return read("git_diff", [:], "Uncommitted changes")
        case ("code", "log", 2): return read("git_log", ["limit": .int(10)], "Recent commits")
        case ("code", "run", 2): return effect("shell", [:], "Run in the source checkout", text: "cmd")
        default: break
        }
        guard let n = Int(parts[1]), parts.count <= 3 else { return nil }
        let verb = parts.count == 3 ? parts[2] : nil
        if parts[0] == "files", let path = withNames(dataRoot, { $0.id("file", n) }) {
            let file: [String: JSONValue] = ["path": .string(path)]
            switch verb {
            case nil: return read("read_file", file, URL(fileURLWithPath: path).lastPathComponent)
            case "append": return effect("write_file", file.merging(["append": .bool(true)]) { a, _ in a }, "Add to " + name, text: "content")
            default: return nil
            }
        }
        return nil
    }

    // MARK: Reads as rooms

    /// A read opened from a room (a file, a Mac look, a memory, a
    /// saved reply, commits, app activity, the app's
    /// settings), laid out like the other rooms: header, its text or rows
    /// with an honest count, and the owner's own verbs under the name it was
    /// listed as (`files.3.add`, `replies.2.follow`). Nil leaves the old view.
    static func buildRecordRoom(_ location: AgentWorkspaceLocation, value: JSONValue?, dataRoot: URL, issue: String?) async -> String? {
        guard case .record(let tool, let input, let title) = location, let value, let room = family(tool, input: input, dataRoot: dataRoot) else { return nil }
        if let issue { return screen([room.uppercased(), "read incomplete"], [[issue]], verbs: []) }
        let projection = await AgentWorkspaceProjection.project(location: location, result: value, dataRoot: dataRoot)
        let object: [String: JSONValue] = if case .object(let row) = value { row } else { [:] }
        func text(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let text)?: return text
            case .int(let n)?: return String(n)
            case .double(let n)?: return String(Int(n))
            case .bool(let b)?: return b ? "yes" : "no"
            default: return nil
            }
        }
        func rowsOf(_ value: JSONValue?) -> [[String: JSONValue]] {
            guard case .array(let list)? = value else { return [] }
            return list.compactMap { if case .object(let row) = $0 { row } else { nil } }
        }
        var body: String?
        if case .string(let whole) = value { body = whole }
        for key in ["text", "content", "body", "answer"] where body == nil { body = text(object[key]) }
        var header = [clip(title, 48), room]
        var rows: [String] = [], label = "TEXT"
        switch tool {
        case "git_log":
            let commits = rowsOf(object["commits"])
            rows = commits.map { pad(text($0["hash"]) ?? "", 11) + pad(String((text($0["date"]) ?? "").prefix(16)), 18) + clip(text($0["subject"]) ?? "", 80) }
            header = ["COMMITS", "\(commits.count) newest"]; label = "LOG"
        case "activity_query":
            // Seconds per app over the range, busiest first.
            var seconds: [String: Double] = [:]
            for bucket in rowsOf(object["buckets"]) {
                if case .double(let s)? = bucket["seconds"], let app = text(bucket["app_name"]) { seconds[app, default: 0] += s }
            }
            let apps = seconds.sorted { $0.value > $1.value }
            rows = apps.prefix(10).map { pad(clip($0.key, 28), 30) + age($0.value) }
                + (apps.count > 10 ? ["+\(apps.count - 10) more apps"] : [])
            header = ["ACTIVITY", (text(input["range"]) ?? "today").replacingOccurrences(of: "_", with: " "), "\(apps.count) apps"]; label = "APPS"
        case "app" where input["item"] == .string("status"):
            // The link's health in words (walk 3: this was raw JSON).
            let object: [String: JSONValue] = if case .object(let row)? = object["item"] { row } else { [:] }
            let now = Date()
            func when(_ key: String) -> String? { text(object[key]).flatMap(date).map { friendly($0, now: now) } }
            let on = object["enabled"] == .bool(true), polling = object["poller_running"] == .bool(true)
            let broken = object["active_error"] == .bool(true)
            rows = [
                "link      " + (on ? "on" + (polling ? " · listening" : " · not listening") : "off"),
                "health    " + (broken ? "error now" + (text(object["last_error"]).map { ": " + clip($0, 80) } ?? "") : "ok"),
                when("last_reply_at").map { "replied   " + $0 },
                when("last_successful_poll_at").map { "polled    " + $0 },
                when("latest_error_at").map { "last error " + $0 + (broken ? "" : " (recovered)") },
                text(object["model"]).map { "model     " + $0 },
                object["token_configured"] == .bool(false) ? "token     not set" : nil,
            ].compactMap { $0 }
            header = ["TELEGRAM", on ? "on" : "off", broken ? "error now" : "ok"]; label = "LINK"; body = nil
        default:
            guard let body, issue == nil else { break }
            // Whole lines, wrapped, never clipped: the cap is on source lines.
            let cap = tool == "screen" ? 60 : tool == "read_page" ? 120 : 40
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            rows = lines.prefix(cap).flatMap { wrap($0) }
            // A web page read keeps its whole text in its source receipt.
            let saved: String? = if case .object(let receipt)? = object["source_receipt"] { text(receipt["path"]) } else { nil }
            if lines.count > cap {
                rows.append("+\(lines.count - cap) more lines" + (tool == "read_file" ? " · app files.read with offset reads on"
                    : saved.map { " · all of it: app files.read " + $0 } ?? ""))
            }
            if tool != "screen" { header.append("\(lines.count) line\(lines.count == 1 ? "" : "s")") }
            let coverage: [String: JSONValue] = if case .object(let row)? = object["coverage"] { row } else { [:] }
            if object["has_more"] == .bool(true) || coverage["complete"] == .bool(false) { header.append("partial") }
        }
        // A page read that failed or came back empty says why and what its
        // reader made of it, so the next reader can be chosen (Sol, walk 6).
        if tool == "read_page", issue != nil || rows.isEmpty {
            let coverage: [String: JSONValue] = if case .object(let row)? = object["coverage"] { row } else { [:] }
            rows += [text(object["reason"]).map { "reason    " + $0 },
                     text(coverage["extraction_status"]).map { "reader    " + $0 },
                     text(coverage["content_type"]).map { "type      " + $0 },
                     text(coverage["http_status"]).map { "http      " + $0 }].compactMap { $0 }.flatMap { wrap($0) }
            label = "SOURCE"
        }
        if tool == "recall_memory", let query = text(input["query"]) { header = ["MEMORY", clip(query, 48), "\(projection.items.count) found"] }
        var lines = textRoom(room, place: location, projection: projection, frame: .object(["status": .string(issue == nil ? "ok" : "failed")]),
                             dataRoot: dataRoot).components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        if issue == nil { lines[0] = (header + (lines[0].contains(numbersNote) ? [numbersNote] : [])).joined(separator: " · ") }
        let shown = section(label, rows)
        if let empty = lines.firstIndex(of: "nothing here"), !shown.isEmpty { lines.replaceSubrange(empty...empty, with: shown) }
        else if !shown.isEmpty, lines.count > 2 { lines.insert(contentsOf: shown + [String(repeating: "─", count: 61)], at: 2) }
        return lines.joined(separator: "\n")
    }

    /// The name a read shows under: the family's list name plus the number
    /// it was listed as (`files.3`, `replies.5`), or the bare
    /// family when it was reached some other way. Never mints a number.
    private static func family(_ tool: String, input: [String: JSONValue], dataRoot: URL) -> String? {
        // The newest number minted for this read is the one its list row
        // shows now (walk 5: replies.9 opened as `replies.1`, an older row
        // identity for the same reply). Numbers only grow, so the highest.
        func listed(_ kind: String, _ base: String, _ match: (String) -> Bool) -> String {
            withNames(dataRoot) { book in book.numbers[kind]?.filter { match($0.key) }.map(\.value).max().map { base + ".\($0)" } } ?? base
        }
        // A list row's identity is the read it opens; titles can be renamed, input cannot.
        func sameRead(_ key: String) -> Bool {
            guard case .object(let row)? = try? JSONValue.parse(Data(key.utf8)) else { return false }
            return row["tool"] == .string(tool) && row["input"] == .object(input)
        }
        let path: String? = if case .string(let text)? = input["path"] { text } else { nil }
        switch tool {
        case "read_file": return path.map { path in listed("file", "files") { $0 == path } } ?? "files"
        case "shelf_entry": return listed("item.replies", "replies", sameRead)
        case "recall_memory": return input["memory_id"] == nil ? "memory" : listed("item.memory", "memory", sameRead)
        case "git_log": return "code"
        case "screen": return "mac"
        case "activity_query": return "activity"
        case "app": return input["item"] == .string("status") ? "status" : nil
        // research.read: the page's text as a room, not the fetch receipt's JSON (walk 6).
        case "read_page": return "research"
        default: return nil
        }
    }

    /// A line cut into pieces of at most `width` at spaces, each defused.
    static func wrap(_ line: String, width: Int = 110) -> [String] {
        var out: [String] = [], rest = Substring(UntrustedText.neutralized(line))
        while rest.count > width {
            let window = rest.prefix(width)
            let cut = window.lastIndex(of: " ").map { rest.index(after: $0) } ?? window.endIndex
            out.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...]
        }
        out.append(String(rest))
        return out
    }

    // MARK: Files

    /// The workspace's newest files (three folders deep), each with a name.
    private static func filesRoom(dataRoot: URL, now: Date) -> String {
        let root = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot).standardizedFileURL
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        var files: [(path: String, at: Date, size: Int)] = [], seen = 0, visited = 0
        var scanNote = "up to 3 folders deep"
        if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walk {
                visited += 1
                if visited > 20_000 { scanNote += " · 20,000-entry limit reached"; break }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true { if walk.level >= 3 { walk.skipDescendants() }; continue }
                guard values.isRegularFile == true else { continue }
                seen += 1
                files.append((url.standardizedFileURL.path, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
                if seen >= 4000 { scanNote += " · 4,000-file limit reached"; break }
            }
        }
        // Size is evidence of size alone; small files are not necessarily stubs.
        let newest = files.sorted { $0.at > $1.at }
        let recent = newest.filter { $0.size >= 256 }.prefix(8), tiny = newest.filter { $0.size < 256 }
        func row(_ book: inout NameBook, _ file: (path: String, at: Date, size: Int)) -> (name: String, shown: String) {
            let n = book.number("file", id: file.path) { Set(files.map(\.path)) }
            return ("files.\(n)", file.path.hasPrefix(root.path + "/") ? String(file.path.dropFirst(root.path.count + 1)) : file.path)
        }
        let (rows, stubs): ([String], [String]) = withNames(dataRoot) { book in
            (recent.map { file in
                let (name, shown) = row(&book, file)
                return pad(name, 10) + pad(size(file.size), 8) + pad(age(now.timeIntervalSince(file.at)), 5) + clip(shown, 56)
            }, tiny.prefix(3).map { file in
                let (name, shown) = row(&book, file)
                return pad(name, 10) + pad(size(file.size), 8) + clip(shown, 60)
            } + (tiny.count > 3 ? ["+\(tiny.count - 3) more under 256 B"] : []))
        }
        return screen(["FILES", clip(root.path, 60), "\(seen) files found in scan"],
            [[scanNote], section("RECENT", rows.isEmpty ? ["no files of 256 B or more found in this scan"] : rows), section("TINY", stubs)],
            verbs: [("files.N", "read it"), ("files.N.append", "add to its end (text)"), ("files.new", "write a new file (form)"),
                    ("files.find", "find a document by what it was for (text)"), ("clipboard.read", "what is on the clipboard"),
                    ("clipboard.copy", "put text on the clipboard (text)"), ("app files.list · files.grep", "any other folder, or inside files")])
    }

    private static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : bytes < 1_048_576 ? "\(bytes / 1024) KB" : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    // MARK: Code

    /// The source checkout as git sees it, and the builder's latest runs.
    private static func codeRoom(dataRoot: URL, now: Date) async -> String {
        guard let repo = AgentWorkspacePorts.current.tools.builderSourceRepoRoot(dataRoot: dataRoot) else {
            return screen(["CODE", "no source checkout on this Mac"], [section("RUNS", runs(dataRoot: dataRoot, now: now))],
                verbs: [("code.run", "run a shell command in the workspace (text)")])
        }
        async let statusRead = git(["status", "--porcelain=v1", "-b"], in: repo)
        async let logRead = git(["log", "-3", "--format=%h%x09%ct%x09%s"], in: repo)
        let (status, log) = await (statusRead, logRead)
        var lines = (status ?? "").split(separator: "\n").map(String.init)
        let branch = lines.first.map { $0.hasPrefix("## ") ? String($0.dropFirst(3)) : "" } ?? ""
        if !lines.isEmpty { lines.removeFirst() }
        let changed = lines.prefix(6).map { clip($0, 90) } + (lines.count > 6 ? ["+\(lines.count - 6) more · code.diff"] : [])
        let commits = (log ?? "").split(separator: "\n").map { row -> String in
            let bits = row.split(separator: "\t", maxSplits: 2).map(String.init)
            guard bits.count == 3, let at = TimeInterval(bits[1]) else { return clip(String(row), 90) }
            return pad(bits[0], 10) + pad(age(now.timeIntervalSince1970 - at), 6) + clip(bits[2], 70)
        }
        return screen(["CODE", repo.lastPathComponent, clip(branch.isEmpty ? "unknown branch" : branch, 50),
                       status == nil ? "git unreadable" : lines.isEmpty ? "clean" : "\(lines.count) changed"],
            [section("CHANGED", changed), section("COMMITS", commits), section("RUNS", runs(dataRoot: dataRoot, now: now))],
            verbs: [("code.diff", "the uncommitted changes"), ("code.log", "the last 10 commits"),
                    ("code.run", "run a shell command in the checkout (text)"), ("app swift.build · swift.test", "build or test")])
    }

    private static func git(_ args: [String], in repo: URL) async -> String? {
        guard let result = try? await SystemProcessAdapter().run(executable: "/usr/bin/git", arguments: ["-C", repo.path] + args,
            currentDirectory: nil, environment: nil, standardInput: nil, timeoutSeconds: 3, outputByteLimit: 65_536),
              result.exitCode == 0, !result.timedOut else { return nil }
        return result.stdout
    }

    /// The builder's newest receipts (data/builder_audit), one line each.
    private static func runs(dataRoot: URL, now: Date) -> [String] {
        let dir = dataRoot.appendingPathComponent("builder_audit", isDirectory: true)
        let builder: Set<String> = ["shell", "bash", "git", "apply_patch", "swift_build", "swift_test", "install_app", "restart_app"]
        let newest = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.prefix(12)
        let rows = newest.compactMap { url, at -> String? in
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tool = row["toolName"] as? String, builder.contains(tool) else { return nil }
            let exit = row["exitCode"] as? Int ?? row["processExitCode"] as? Int
            if row["timedOut"] as? Bool == true || exit != 0 {
                var evidence = JSONValue(fromFoundation: row).objectValue ?? [:]
                if evidence["status"] == nil {
                    evidence["status"] = .string(row["reason"] as? String == "stopped" ? "cancelled" : row["timedOut"] as? Bool == true ? "timeout" : "failed")
                }
                if evidence["reason"] == nil { evidence["reason"] = .string(exit == nil ? "builder_exit_unrecorded" : "builder_exit_nonzero") }
                evidence["detail"] = .object(["exit_code": exit.map { .int(Int64($0)) } ?? .null,
                    "timed_out": evidence["timedOut"] ?? .null,
                    "stderr": evidence["stderr"] ?? .null, "stdout": evidence["stdout"] ?? .null])
                if evidence["effects"] == nil { evidence["effects"] = .string("unknown") }
                if evidence["remedy"] == nil {
                    evidence["remedy"] = Repair.reconcile(instruction: "Read the build receipt and fix its reported cause before another execution; effects are unverified.",
                        nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("files.read"), "args": .object(["path": .string(url.path)])])]))
                }
                return pad(age(now.timeIntervalSince(at)), 6) + pad(tool, 8) + failureFace(.object(evidence))
            }
            let mark = row["timedOut"] as? Bool == true ? "✗ timed out" : exit == 0 ? "✓" : "✗ exit \(exit.map(String.init) ?? "?")"
            let what = row["sourcePayload"] as? String ?? (row["args"] as? [String])?.joined(separator: " ") ?? ""
            return pad(age(now.timeIntervalSince(at)), 6) + pad(mark, 4) + pad(tool, 8) + clip(what, 60)
        }
        return rows.isEmpty ? ["no builder runs yet"] : Array(rows.prefix(4))
    }
}
