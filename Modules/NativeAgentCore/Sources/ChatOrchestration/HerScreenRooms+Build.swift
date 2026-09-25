import Foundation
import NativeAgentCore
import PersistenceCore

/// Her-screen rooms for files, code and GitHub (2026-09-24). Each opens by
/// name (`files`, `code`, `github`) as a short text room, and its rows and
/// verbs act by name (`files.3`, `github.2.files`, `code.diff`). Only local,
/// cheap reads: the workspace folder's newest files, one `git status` and
/// `git log` on the source checkout, the builder's own audit receipts, and
/// the GitHub tracker's last saved snapshot. No network; nothing on home.
enum AgentWorkspaceBuild {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "code", title: "Code", summary: "The source checkout: branch, changes, commits and recent builder runs.",
              tool: nil, tools: ["git_diff", "git_log", "shell", "swift_build"]),
        .init(id: "github", title: "GitHub", summary: "Tracked repositories and their open pull requests and issues.",
              tool: nil, tools: ["github_read_repository_content", "github_get_pull_request", "github_project_digest"]),
    ]

    /// Reads these rooms' names open; each is the owner's ordinary tool.
    static let readTools: Set<String> = ["git_diff", "git_log", "clipboard_read", "github_get_pull_request", "github_get_issue",
                                         "github_pull_request_files", "github_pull_request_activity", "github_read_repository_content", "github_search"]
}

extension HerScreen {
    static func buildRoom(_ location: AgentWorkspaceLocation, dataRoot: URL, now: Date) async -> String? {
        switch location {
        case .area("files"): return filesRoom(dataRoot: dataRoot, now: now)
        case .area("code"): return await codeRoom(dataRoot: dataRoot, now: now)
        case .area("github"): return githubRoom(dataRoot: dataRoot, now: now)
        default: return nil
        }
    }

    /// A name from these rooms to its action, or nil.
    static func buildTarget(_ name: String, dataRoot: URL) -> Target? {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 2, ["files", "code", "github", "clipboard"].contains(parts[0]) else { return nil }
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
        case ("github", "read", 2): return read("github_read_repository_content", [:], "Read from GitHub", text: "repo")
        case ("github", "search", 2): return read("github_search", ["sort": .string("created"), "order": .string("desc")], "Search GitHub", text: "query")
        case ("github", "refresh", 2): return effect("github_project_digest", ["refresh": .bool(true)], "Refresh GitHub")
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
        // Tracker keys read "owner/name#pr#12" or "owner/name#issue#12".
        if parts[0] == "github", let key = withNames(dataRoot, { $0.id("github", n) }) {
            let bits = key.split(separator: "#").map(String.init)
            guard bits.count == 3, let number = Int(bits[2]) else { return nil }
            let target: [String: JSONValue] = ["repo": .string(bits[0]), "number": .int(Int64(number))]
            let pr = bits[1] == "pr"
            switch verb {
            case nil: return read(pr ? "github_get_pull_request" : "github_get_issue", target, "\(bits[0])#\(number)")
            case "files" where pr: return read("github_pull_request_files", target, "Files of \(bits[0])#\(number)")
            case "activity" where pr: return read("github_pull_request_activity", target, "Activity on \(bits[0])#\(number)")
            default: return nil
            }
        }
        return nil
    }

    // MARK: Reads as rooms

    /// A read opened from a room (a file, a Mac look, a memory, a skill, a
    /// saved reply, commits, a pull request, app activity, the app's
    /// settings), laid out like the other rooms: header, its text or rows
    /// with an honest count, and the owner's own verbs under the name it was
    /// listed as (`files.3.add`, `replies.2.follow`). Nil leaves the old view.
    static func buildRecordRoom(_ location: AgentWorkspaceLocation, value: JSONValue?, dataRoot: URL, issue: String?) -> String? {
        guard case .record(let tool, let input, let title) = location, let value, let room = family(tool, input: input, dataRoot: dataRoot) else { return nil }
        var projection = AgentWorkspaceProjection.project(location: location, result: value)
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
        case "app_settings_list":
            // One line per page: its settings' names, so the change form needs no lookup.
            let settings = rowsOf(object["settings"])
            var order: [String] = [], byPage: [String: [String]] = [:]
            for setting in settings {
                guard var id = text(setting["id"]) else { continue }
                // A helper's rows go by its label ("Sideways schedule"), which the
                // change form also takes, never its raw UUID id (walk 4).
                if id.split(separator: ".").contains(where: { UUID(uuidString: String($0)) != nil }), let label = text(setting["label"]) {
                    id = label
                }
                let page = text(setting["page"]) ?? "other"
                if byPage[page] == nil { order.append(page) }
                byPage[page, default: []].append(id)
            }
            rows = order.flatMap { wrap(pad($0, 12) + byPage[$0, default: []].joined(separator: ", ")) }
            header = ["SETTINGS", "\(settings.count) settings", "\(order.count) pages"] + (text(object["trust_mode"]).map { [$0] } ?? [])
            label = "PAGES"
            projection.actions.append(.init(label: "Change a setting", action: .configure(tool: "app_setting_set", input: [:], title: "Change a setting")))
        case "git_log":
            let commits = rowsOf(object["commits"])
            rows = commits.map { pad(text($0["hash"]) ?? "", 11) + pad(String((text($0["date"]) ?? "").prefix(16)), 18) + clip(text($0["subject"]) ?? "", 80) }
            header = ["COMMITS", "\(commits.count) newest"]; label = "LOG"
        case "github_get_pull_request", "github_get_issue":
            let item: [String: JSONValue] = if case .object(let row)? = object["pullRequest"] ?? object["issue"] { row } else { [:] }
            func sub(_ key: String, _ field: String) -> String? { if case .object(let row)? = item[key] { text(row[field]) } else { nil } }
            let facts: [String?] = [
                text(item["state"]).map { "state     " + $0 + (item["merged"] == .bool(true) ? " (merged)" : "") },
                sub("user", "login").map { "author    " + $0 },
                sub("head", "ref").map { "branch    " + $0 + (sub("base", "ref").map { " → " + $0 } ?? "") },
                text(object["reviewState"]).map { "reviews   " + $0 },
                text(item["changed_files"]).map { "changes   " + $0 + " files, +" + (text(item["additions"]) ?? "0") + " −" + (text(item["deletions"]) ?? "0") },
                text(item["updated_at"]).map { "updated   " + $0 },
                text(item["html_url"]).map { "link      " + $0 },
            ]
            rows = facts.compactMap { $0 }
            if let words = text(item["body"]), !words.isEmpty { rows += [""] + words.split(separator: "\n").prefix(12).flatMap { wrap(String($0)) } }
            header = [clip(text(item["title"]) ?? title, 60), room]; label = "ITEM"; body = nil
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
        case "telegram_status":
            // The link's health in words (walk 3: this was raw JSON).
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
        case "tool_catalog":
            // Found tools as calls, what each does under it; calling one loads it (walk 3: raw JSON).
            let matches = rowsOf(object["matches"])
            rows = matches.prefix(8).flatMap { match -> [String] in
                [clip(text(match["call"]) ?? text(match["name"]) ?? "", 110)]
                    + (text(match["description"]).map { ["    " + clip(sentence($0), 100)] } ?? [])
            }
            // The count is what is shown; weaker matches left off the shortlist
            // are said as such (walk 4: "3 matches" over one row).
            let shown = min(matches.count, 8), total = max(Int(text(object["match_count"]) ?? "") ?? 0, matches.count)
            if total > shown { rows.append("+\(total - shown) weaker, not shown · tools.find with other words") }
            if !matches.isEmpty { rows.append("Call one by its name with those arguments; calling loads it.") }
            header = ["TOOLS", text(input["query"]).map { "found for \"" + clip($0, 40) + "\"" } ?? "found",
                      "\(shown) match\(shown == 1 ? "" : "es")"]
            label = "FOUND"; body = nil
        default:
            guard let body, issue == nil else { break }
            // Whole lines, wrapped, never clipped: the cap is on source lines.
            let cap = tool == "screen" ? 60 : 40
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            rows = lines.prefix(cap).flatMap { wrap($0) }
            if lines.count > cap {
                rows.append("+\(lines.count - cap) more lines" + (tool == "read_file" ? " · read_file with offset reads on" : ""))
            }
            if tool != "screen" { header.append("\(lines.count) line\(lines.count == 1 ? "" : "s")") }
            if object["has_more"] == .bool(true) { header.append("partial") }
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
    /// it was listed as (`files.3`, `skills.5`, `github.1`), or the bare
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
        case "read_skill": return listed("item.skills", "skills", sameRead)
        case "shelf_entry": return listed("item.replies", "replies", sameRead)
        case "recall_memory": return input["memory_id"] == nil ? "memory" : listed("item.memory", "memory", sameRead)
        case "github_get_pull_request", "github_get_issue":
            let repo: String = if case .string(let text)? = input["repo"] { text.lowercased() } else { "" }
            let number: String = switch input["number"] { case .int(let n)?: String(n); case .string(let s)?: s; default: "" }
            let kind = tool == "github_get_pull_request" ? "pr" : "issue"
            return listed("github", "github") { $0 == "\(repo)#\(kind)#\(number)" }
        case "git_log": return "code"
        case "screen": return "mac"
        case "app_settings_list": return "app"
        case "activity_query": return "activity"
        case "telegram_status": return "status"
        case "tool_catalog": return "tools"
        default: return nil
        }
    }

    /// A line cut into pieces of at most `width` at spaces, each defused.
    private static func wrap(_ line: String, width: Int = 110) -> [String] {
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
        if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walk {
                visited += 1
                if visited > 20_000 { seen = max(seen, 4000); break }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true { if walk.level >= 3 { walk.skipDescendants() }; continue }
                guard values.isRegularFile == true else { continue }
                seen += 1
                files.append((url.standardizedFileURL.path, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
                if seen >= 4000 { break }
            }
        }
        // Real files first; stubs under 256 bytes (test fixtures) get one short line.
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
        return screen(["FILES", clip(root.path, 60), seen >= 4000 ? "4000+ files" : "\(seen) file\(seen == 1 ? "" : "s")"],
            [section("RECENT", rows.isEmpty ? ["nothing in the workspace yet · files.new writes one"] : rows), section("TINY", stubs)],
            verbs: [("files.N", "read it"), ("files.N.append", "add to its end (text)"), ("files.new", "write a new file (form)"),
                    ("files.find", "find a document by what it was for (text)"), ("clipboard.read", "what is on the clipboard"),
                    ("clipboard.copy", "put text on the clipboard (text)"), ("list_dir · grep", "any other folder, or inside files")])
    }

    private static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : bytes < 1_048_576 ? "\(bytes / 1024) KB" : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    // MARK: Code

    /// The source checkout as git sees it, and the builder's latest runs.
    private static func codeRoom(dataRoot: URL, now: Date) async -> String {
        guard let repo = SwiftToolDispatcher.builderSourceRepoRoot(dataRoot: dataRoot) else {
            return screen(["CODE", "no source checkout on this Mac"], [section("RUNS", runs(dataRoot: dataRoot, now: now))],
                verbs: [("code.run", "run a shell command in the workspace (text)")])
        }
        let (status, log) = await Task.detached {
            (git(["status", "--porcelain=v1", "-b"], in: repo), git(["log", "-3", "--format=%h%x09%ct%x09%s"], in: repo))
        }.value
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
                    ("code.run", "run a shell command in the checkout (text)"), ("swift_build · run_tests", "build or test")])
    }

    private static func git(_ args: [String], in repo: URL) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        return process.terminationStatus == 0 ? String(decoding: data.prefix(65_536), as: UTF8.self) : nil
    }

    /// The builder's newest receipts (data/builder_audit), one line each.
    private static func runs(dataRoot: URL, now: Date) -> [String] {
        let dir = dataRoot.appendingPathComponent("builder_audit", isDirectory: true)
        let builder: Set<String> = ["shell", "bash", "git", "apply_patch", "run_tests", "swift_build", "swift_test", "install_app", "restart_app"]
        let newest = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.prefix(12)
        let rows = newest.compactMap { url, at -> String? in
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tool = row["toolName"] as? String, builder.contains(tool) else { return nil }
            let exit = row["exitCode"] as? Int ?? row["processExitCode"] as? Int
            let mark = row["timedOut"] as? Bool == true ? "✗ timed out" : exit == 0 ? "✓" : "✗ exit \(exit.map(String.init) ?? "?")"
            let what = row["sourcePayload"] as? String ?? (row["args"] as? [String])?.joined(separator: " ") ?? ""
            return pad(age(now.timeIntervalSince(at)), 6) + pad(mark, 4) + pad(tool, 8) + clip(what, 60)
        }
        return rows.isEmpty ? ["no builder runs yet"] : Array(rows.prefix(4))
    }

    // MARK: GitHub

    /// The tracker's saved view (connectors/github): repos and open items.
    private static func githubRoom(dataRoot: URL, now: Date) -> String {
        func object(_ path: String) -> [String: Any] {
            (try? Data(contentsOf: dataRoot.appendingPathComponent(path)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let config = object("connectors/github/tracking.json"), snapshot = object("connectors/github/tracking_snapshot.json")
        let repos = (config["repositories"] as? [[String: Any]] ?? []).compactMap { $0["fullName"] as? String }
        let open = (snapshot["entities"] as? [[String: Any]] ?? []).filter { ($0["state"] as? String ?? "open") == "open" && $0["key"] is String }
        let ordered = open.sorted {
            let a = ($0["needsUser"] as? Bool == true || $0["blocked"] as? Bool == true ? 1 : 0, $0["updatedAt"] as? String ?? "")
            let b = ($1["needsUser"] as? Bool == true || $1["blocked"] as? Bool == true ? 1 : 0, $1["updatedAt"] as? String ?? "")
            return a > b
        }
        let person = names(dataRoot).person
        let rows: [String] = withNames(dataRoot) { book in
            ordered.prefix(8).map { item in
                let n = book.number("github", id: item["key"] as? String ?? "") { Set(open.compactMap { $0["key"] as? String }) }
                let repo = (item["repository"] as? String ?? "").split(separator: "/").last.map(String.init) ?? ""
                var state = [item["kind"] as? String == "pull_request" ? "PR" : "issue"]
                if item["needsUser"] as? Bool == true { state.append("needs " + person) }
                if item["blocked"] as? Bool == true { state.append("blocked") }
                if let at = (item["updatedAt"] as? String).flatMap(date) { state.append(age(now.timeIntervalSince(at))) }
                return pad("github.\(n)", 11) + clip("\(repo)#\(item["number"] as? Int ?? 0) \(item["title"] as? String ?? "")", 56)
                    + " · " + state.joined(separator: " · ")
            }
        }
        // Each repo with its open count, busiest first: "only one on X" reads here.
        var counts: [String: Int] = [:]
        for item in open { counts[(item["repository"] as? String ?? "").lowercased(), default: 0] += 1 }
        let short = repos.sorted { counts[$0.lowercased(), default: 0] > counts[$1.lowercased(), default: 0] }.map { repo in
            (repo.split(separator: "/").last.map(String.init) ?? repo) + " \(counts[repo.lowercased(), default: 0])"
        }
        // The tracker keeps pull requests (and issues their bodies link); say so.
        let prsOnly = !open.contains { $0["kind"] as? String != "pull_request" }
        let refreshed = (snapshot["refreshedAt"] as? String).flatMap { text in
            date(text) ?? date(text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
        }
        var header = ["GITHUB"]
        if repos.isEmpty && open.isEmpty { header.append("nothing tracked yet · github.refresh") }
        else { header += ["\(repos.count) repo\(repos.count == 1 ? "" : "s")", "\(open.count) open" + (prsOnly ? " PRs · issues not tracked" : "")] }
        if let refreshed { header.append("saved " + age(now.timeIntervalSince(refreshed)) + " ago") }
        return screen(header,
            [section("OPEN", rows.isEmpty ? ["no open pull requests or issues saved"] : rows + (open.count > 8 ? ["+\(open.count - 8) more · github.search finds any"] : [])),
             section("OPEN BY REPO", short.isEmpty ? [] : [clip(short.prefix(10).joined(separator: " · ") + (short.count > 10 ? " · +\(short.count - 10) with none" : ""), 110)])],
            verbs: [("github.N", "open it: state, reviews, checks"), ("github.N.files", "a PR's changed files"),
                    ("github.N.activity", "a PR's comments and reviews"), ("github.read", "a repo file or folder (text: owner/name or link)"),
                    ("github.search", "issues or PRs live (text: repo:owner/name is:issue is:open)"),
                    ("github.refresh", "re-read the saved list from GitHub and update the Desk")])
    }
}
