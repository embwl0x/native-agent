#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Darwin
import Foundation

// User Mode Eval is intentionally black-box: it inspects the installed app,
// visible UI, and live app-owned state for user-observable contradictions.

struct Options {
    var repo: URL
    var artifacts: URL?
    var skipUI = false
    var strictUI = false
    /// Narrow deterministic subprocess seam for the script's own AX gate.
    /// It only ever forces the safe failure posture and is not part of the
    /// user-facing evaluator contract.
    var uiGateOnly = false
    var forceAXUntrustedForTesting = false
    var visibilityContractOnly = false
    var processContractOnly = false
}

struct Finding: Codable {
    let severity: String
    let id: String
    let title: String
    let detail: String
}

struct ScenarioResult: Codable {
    let id: String
    let status: String
    let detail: String
}

struct UISnapshot: Codable {
    let path: String
    let role: String
    let title: String
    let value: String
    let description: String
    let enabled: Bool?
    let actions: [String]
    let childCount: Int
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
}

struct Report: Codable {
    let runAt: String
    let repo: String
    let appPath: String
    let bundleIdentifier: String
    let artifactDir: String
    let summary: [String: Int]
    let scenarios: [ScenarioResult]
    let findings: [Finding]
}

struct UIRoute {
    let id: String
    let steps: [UIRouteStep]
    let displayName: String
    let expectedDetailText: [String]
    /// Unlike `expectedDetailText` (an any-of route landing cue), every entry
    /// here must be visible. Use this for mounted setup inventories where
    /// section chrome alone would otherwise hide a failed or empty read.
    let requiredDetailText: [String]

    init(
        id: String,
        steps: [UIRouteStep],
        displayName: String,
        expectedDetailText: [String],
        requiredDetailText: [String] = []
    ) {
        self.id = id
        self.steps = steps
        self.displayName = displayName
        self.expectedDetailText = expectedDetailText
        self.requiredDetailText = requiredDetailText
    }
}

struct UIRouteStep {
    let labels: [String]
    let commandKey: String?
    let modifiersScript: String?
    let paletteQuery: String?
    let sidebarOnly: Bool
}

func userModeRoutes(includeNativeExperience: Bool) -> [UIRoute] {
    var routes = [
        UIRoute(id: "chat", steps: [commandStep("1", labels: ["Chat"])], displayName: "Chat", expectedDetailText: ["Sessions", "System Health"]),
        UIRoute(id: "activity", steps: [commandStep("2", labels: ["Activity"])], displayName: "Activity", expectedDetailText: ["Needs your eyes", "Approvals"]),
        UIRoute(id: "activity-approvals", steps: [commandShiftStep("a", labels: ["Approvals"])], displayName: "Activity > Approvals", expectedDetailText: ["Approvals include tool calls"]),
        UIRoute(id: "activity-inbox", steps: [commandShiftStep("i", labels: ["Inbox"])], displayName: "Activity > Inbox", expectedDetailText: ["All"]),
        UIRoute(id: "activity-memory-proposals", steps: [commandStep("2", labels: ["Activity"]), axStep(["Memory Proposals"])], displayName: "Activity > Memory Proposals", expectedDetailText: ["Memory proposal", "Memory Proposals"]),
        UIRoute(id: "activity-self-improvement", steps: [commandStep("2", labels: ["Activity"]), axStep(["Self-Improvement"])], displayName: "Activity > Self-Improvement", expectedDetailText: ["Harness", "Self-Improvement"]),
        UIRoute(id: "memories", steps: [commandStep("3", labels: ["Memories", "Memory"])], displayName: "Memories", expectedDetailText: ["Memory", "last hygiene"]),
        UIRoute(id: "desk", steps: [commandStep("4", labels: ["Desk"])], displayName: "Desk", expectedDetailText: ["'s Desk", "In progress"]),
        UIRoute(id: "workshop-schedule", steps: [commandStep("4", labels: ["Workshop"]), axStep(["Schedule", "Scheduler"])], displayName: "Workshop > Schedule", expectedDetailText: ["Add Nightly Reflection", "Scheduler"]),
        UIRoute(id: "workshop-research", steps: [commandStep("4", labels: ["Workshop"]), axStep(["Research"])], displayName: "Workshop > Research", expectedDetailText: ["Research"]),
        UIRoute(id: "skills", steps: [appRouteStep("s", labels: ["Skills"])], displayName: "Skills & Tools > Skills", expectedDetailText: ["Skills & Tools", "Skills"]),
        UIRoute(id: "providers", steps: [axStep(["Providers"], sidebarOnly: true)], displayName: "Providers", expectedDetailText: ["Providers", "Choose which LLM provider"]),
        UIRoute(id: "mac-integration", steps: [appRouteStep("m", labels: ["Mac Integration"])], displayName: "Mac Integration", expectedDetailText: ["Mac Integration", "System Permissions"]),
        UIRoute(id: "settings", steps: [commandStep("9", labels: ["Settings"])], displayName: "Settings", expectedDetailText: ["Settings"]),
        UIRoute(id: "personality", steps: [axStep(["Personality"], sidebarOnly: true)], displayName: "Personality", expectedDetailText: ["Personality", "Custom mode"]),
        UIRoute(id: "connectors", steps: [appRouteStep("c", labels: ["Connectors"])], displayName: "Connectors", expectedDetailText: ["Connectors"]),
        UIRoute(id: "trust", steps: [axStep(["Trust"], sidebarOnly: true)], displayName: "Trust", expectedDetailText: ["Trust", "Full Mac"]),
        // Mounted on Trust > Mac Control. This is intentionally read-only:
        // the walk proves the live inventory and must never apply a preset or
        // trigger macOS permission prompts on the user's installed app.
        UIRoute(id: "mac-assistant-watch-setup", steps: [axStep(["Trust"], sidebarOnly: true)], displayName: "Trust > Assistant Watch Setup", expectedDetailText: ["Assistant Watch Setup"], requiredDetailText: ["Mac Control Bridge", "Gmail unread digest"]),
        UIRoute(id: "capabilities", steps: [appRouteStep("p", labels: ["Capabilities"])], displayName: "Capabilities", expectedDetailText: ["Capabilities", "Next-gen"]),
        UIRoute(id: "knowledge", steps: [axStep(["Knowledge Graph"], sidebarOnly: true)], displayName: "Knowledge Graph", expectedDetailText: ["Knowledge Graph", "entities"]),
        UIRoute(id: "dreams", steps: [appRouteStep("d", labels: ["Dreams"])], displayName: "Dreams", expectedDetailText: ["Dreams", "Run Dream"]),
        UIRoute(id: "diagnostics", steps: [appRouteStep("x", labels: ["Doctor", "Diagnostics"])], displayName: "Diagnostics", expectedDetailText: ["Doctor", "Run Doctor"]),
        UIRoute(id: "diagnostics-status", steps: [appRouteStep("x", labels: ["Doctor", "Diagnostics"]), axStep(["Status"])], displayName: "Diagnostics > Status", expectedDetailText: ["Runtime", "Watchdog"]),
        UIRoute(id: "diagnostics-cognition", steps: [appRouteStep("x", labels: ["Doctor", "Diagnostics"]), axStep(["Cognition"])], displayName: "Diagnostics > Cognition", expectedDetailText: ["Cognition Observatory"]),
        UIRoute(id: "diagnostics-inspector", steps: [appRouteStep("x", labels: ["Doctor", "Diagnostics"]), axStep(["Inspector"])], displayName: "Diagnostics > Inspector", expectedDetailText: ["Turn Inspector", "Live readout"]),
        UIRoute(id: "inbox-policy", steps: [appRouteStep("i", labels: ["Inbox Policy"])], displayName: "Inbox Policy", expectedDetailText: ["Inbox Policy", "When enabled"]),
        UIRoute(id: "tools", steps: [appRouteStep("t", labels: ["Tools"])], displayName: "Skills & Tools > Tools", expectedDetailText: ["Skills & Tools", "Tools", "Chat Tool Catalog"]),
        UIRoute(id: "mcp", steps: [appRouteStep("e", labels: ["MCP"])], displayName: "MCP Hub", expectedDetailText: ["MCP Hub", "Servers"]),
        UIRoute(id: "telegram", steps: [commandPaletteStep("telegram", labels: ["Command Palette", "Telegram"])], displayName: "Telegram", expectedDetailText: ["Telegram Status", "Bot token"])
    ]
    if includeNativeExperience {
        let experienceRoot = [
            commandStep("2", labels: ["Activity"]),
            axStep(["Native Experience"])
        ]
        routes.append(contentsOf: [
            UIRoute(id: "native-experience", steps: experienceRoot, displayName: "Native Experience", expectedDetailText: ["Learning Journey", "Recent evidence"]),
            UIRoute(id: "native-experience-context", steps: experienceRoot + [axStep(["Context"])], displayName: "Native Experience > Context", expectedDetailText: ["Context Economics", "Fluid Context"]),
            UIRoute(id: "native-experience-projects", steps: experienceRoot + [axStep(["Projects & Sessions"])], displayName: "Native Experience > Projects & Sessions", expectedDetailText: ["Project Spaces", "Conversation lineage"]),
            UIRoute(id: "native-experience-automations", steps: experienceRoot + [axStep(["Automations"])], displayName: "Native Experience > Automations", expectedDetailText: ["Automation Blueprints", "Compile"]),
            UIRoute(id: "native-experience-capabilities", steps: experienceRoot + [axStep(["Capabilities"])], displayName: "Native Experience > Capabilities", expectedDetailText: ["Capability Readiness", "Capability Kits"]),
            UIRoute(id: "native-experience-workbench", steps: experienceRoot + [axStep(["Workbench"])], displayName: "Native Experience > Workbench", expectedDetailText: ["Choose a saved project", "Pane"]),
            UIRoute(id: "native-experience-skills", steps: experienceRoot + [axStep(["Skill Evolution"])], displayName: "Native Experience > Skill Evolution", expectedDetailText: ["Current version", "Version history"]),
            UIRoute(id: "native-experience-remote-nodes", steps: experienceRoot + [axStep(["Remote Nodes"])], displayName: "Native Experience > Remote Nodes", expectedDetailText: ["Trusted Remote Node", "Effect boundary"])
        ])
    }
    return routes
}

func userModeAdvancedRouteIDs() -> Set<String> {
    [
        "personality", "connectors", "trust",
        "capabilities", "knowledge", "dreams", "diagnostics",
        "inbox-policy", "mcp"
    ]
}

func userModeExpectedAdditionalRouteIDs(includeNativeExperience: Bool) -> Set<String> {
    var routeIDs: Set<String> = [
        "activity-approvals", "activity-inbox", "activity-memory-proposals",
        "activity-self-improvement", "workshop-schedule", "workshop-research",
        "diagnostics-status", "diagnostics-cognition", "diagnostics-inspector",
        "mac-assistant-watch-setup", "telegram", "tools"
    ]
    if includeNativeExperience {
        routeIDs.formUnion([
            "native-experience", "native-experience-context",
            "native-experience-projects", "native-experience-automations",
            "native-experience-capabilities", "native-experience-workbench",
            "native-experience-skills", "native-experience-remote-nodes"
        ])
    }
    return routeIDs
}

func axStep(_ labels: [String], sidebarOnly: Bool = false) -> UIRouteStep {
    UIRouteStep(labels: labels, commandKey: nil, modifiersScript: nil, paletteQuery: nil, sidebarOnly: sidebarOnly)
}

func commandStep(_ key: String, labels: [String]) -> UIRouteStep {
    UIRouteStep(labels: labels, commandKey: key, modifiersScript: "command down", paletteQuery: nil, sidebarOnly: false)
}

func appRouteStep(_ key: String, labels: [String]) -> UIRouteStep {
    let query = labels.first?.lowercased() ?? key
    return commandPaletteStep(query, labels: labels)
}

func commandShiftStep(_ key: String, labels: [String]) -> UIRouteStep {
    UIRouteStep(labels: labels, commandKey: key, modifiersScript: "{command down, shift down}", paletteQuery: nil, sidebarOnly: false)
}

func commandPaletteStep(_ query: String, labels: [String]) -> UIRouteStep {
    UIRouteStep(labels: labels, commandKey: nil, modifiersScript: nil, paletteQuery: query, sidebarOnly: false)
}

final class Recorder {
    private(set) var findings: [Finding] = []
    private(set) var scenarios: [ScenarioResult] = []

    func pass(_ id: String, _ detail: String) {
        scenarios.append(ScenarioResult(id: id, status: "pass", detail: detail))
    }

    func warn(_ id: String, _ title: String, _ detail: String) {
        findings.append(Finding(severity: "warn", id: id, title: title, detail: detail))
        scenarios.append(ScenarioResult(id: id, status: "warn", detail: detail))
    }

    func fail(_ id: String, _ title: String, _ detail: String) {
        findings.append(Finding(severity: "fail", id: id, title: title, detail: detail))
        scenarios.append(ScenarioResult(id: id, status: "fail", detail: detail))
    }
}

let fm = FileManager.default

func parseOptions() -> Options {
    var repo = URL(fileURLWithPath: fm.currentDirectoryPath)
    var artifacts: URL?
    var skipUI = false
    var strictUI = false
    var uiGateOnly = false
    var forceAXUntrustedForTesting = false
    var visibilityContractOnly = false
    var processContractOnly = false
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--repo":
            guard !args.isEmpty else { fatalError("--repo requires a path") }
            repo = URL(fileURLWithPath: args.removeFirst())
        case "--artifacts":
            guard !args.isEmpty else { fatalError("--artifacts requires a path") }
            artifacts = URL(fileURLWithPath: args.removeFirst())
        case "--no-ui":
            skipUI = true
        case "--strict-ui":
            strictUI = true
        case "--test-ui-gate-only":
            uiGateOnly = true
        case "--test-force-ax-untrusted":
            forceAXUntrustedForTesting = true
        case "--test-visibility-contract":
            visibilityContractOnly = true
        case "--test-process-contract":
            processContractOnly = true
        case "--help", "-h":
            print("""
            User Mode Eval

            Usage:
              script/user_mode_eval.sh [--no-ui] [--strict-ui] [--artifacts PATH]

            Notes:
              --no-ui skips Accessibility UI inventory/click navigation.
              --strict-ui fails when Accessibility is unavailable.
            """)
            exit(0)
        default:
            fatalError("unknown argument: \(arg)")
        }
    }
    return Options(repo: repo, artifacts: artifacts, skipUI: skipUI, strictUI: strictUI,
                   uiGateOnly: uiGateOnly, forceAXUntrustedForTesting: forceAXUntrustedForTesting,
                   visibilityContractOnly: visibilityContractOnly, processContractOnly: processContractOnly)
}

func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00")
}

func safeStamp() -> String {
    isoNow()
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: ".", with: "-")
        .replacingOccurrences(of: "+", with: "Z")
}

func systemLogDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

func jsonObject(at url: URL) -> Any? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

func jsonArray(at url: URL) -> [[String: Any]] {
    jsonObject(at: url) as? [[String: Any]] ?? []
}

func jsonDictionary(at url: URL) -> [String: Any] {
    jsonObject(at: url) as? [String: Any] ?? [:]
}

func jsonlRows(at url: URL) -> [[String: Any]] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { raw in
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

func jsonLine(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

func withCanonicalFileLock<T>(_ targetURL: URL, body: () throws -> T) throws -> T {
    let lockPath = targetURL.path + ".lock"
    try fm.createDirectory(
        at: URL(fileURLWithPath: lockPath).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let deadline = Date().addingTimeInterval(5)
    var inodeAttempts = 0
    while true {
        inodeAttempts += 1
        let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else {
            throw NSError(
                domain: "UserModeEvalFileLock",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "open lock failed: \(String(cString: strerror(errno)))"]
            )
        }
        var acquired = false
        defer {
            if acquired { _ = flock(fd, LOCK_UN) }
            Darwin.close(fd)
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EINTR else {
                throw NSError(
                    domain: "UserModeEvalFileLock",
                    code: Int(lockError),
                    userInfo: [NSLocalizedDescriptionKey: "flock failed: \(String(cString: strerror(lockError)))"]
                )
            }
            guard Date() < deadline else {
                throw NSError(
                    domain: "UserModeEvalFileLock",
                    code: Int(ETIMEDOUT),
                    userInfo: [NSLocalizedDescriptionKey: "timed out locking \(targetURL.path)"]
                )
            }
            usleep(20_000)
        }
        acquired = true

        // Match PersistenceCore's acquire-then-validate discipline: orphan
        // cleanup may unlink a sidecar while this process is opening it.
        var held = stat()
        var atPath = stat()
        let sameInode = fstat(fd, &held) == 0
            && stat(lockPath, &atPath) == 0
            && held.st_dev == atPath.st_dev
            && held.st_ino == atPath.st_ino
        if sameInode {
            return try body()
        }
        guard inodeAttempts < 8, Date() < deadline else {
            throw NSError(
                domain: "UserModeEvalFileLock",
                code: Int(EAGAIN),
                userInfo: [NSLocalizedDescriptionKey: "lock file was replaced repeatedly: \(lockPath)"]
            )
        }
    }
}

func installOpenApprovalsProbeCard(inboxURL: URL, id: String) throws -> Bool {
    let row: [String: Any] = [
        "actions": [],
        "created_at": isoNow(),
        "detail": "User Mode probe.\n\nSuggested action: approvals.triage.\n\nThis row is temporary and restored after the eval.",
        "id": id,
        "read_at": NSNull(),
        "related_approval_id": NSNull(),
        "related_groups": [],
        "related_mission_id": NSNull(),
        "related_paths": [],
        "severity": "actionable",
        "source": "proactive_autonomy:approval_backlog:user-mode-open-approvals",
        "status": "unread",
        "summary": "Temporary User Mode probe for the Inbox Open Approvals action.",
        "title": "User Mode Open Approvals Probe"
    ]
    let probe = Data((try jsonLine(row) + "\n").utf8)
    return try withCanonicalFileLock(inboxURL) {
        let existed = fm.fileExists(atPath: inboxURL.path)
        let original = existed ? try Data(contentsOf: inboxURL) : Data()
        var updated = probe
        updated.append(original)
        try updated.write(to: inboxURL, options: .atomic)
        return existed
    }
}

func removeJSONLRow(url: URL, id: String, fileExistedBeforeProbe: Bool) throws {
    try withCanonicalFileLock(url) {
        guard let current = try? Data(contentsOf: url) else { return }
        var retained = Data()
        var lineStart = current.startIndex
        while lineStart < current.endIndex {
            let newline = current[lineStart...].firstIndex(of: 0x0A)
            let lineEnd = newline ?? current.endIndex
            var payloadEnd = lineEnd
            if payloadEnd > lineStart, current[current.index(before: payloadEnd)] == 0x0D {
                payloadEnd = current.index(before: payloadEnd)
            }
            let payload = current[lineStart..<payloadEnd]
            let object = (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any]
            let matchesProbe = object?["id"] as? String == id
            let segmentEnd = newline.map { current.index(after: $0) } ?? current.endIndex
            if !matchesProbe {
                retained.append(current[lineStart..<segmentEnd])
            }
            lineStart = segmentEnd
        }
        if retained.isEmpty, !fileExistedBeforeProbe {
            try? fm.removeItem(at: url)
        } else {
            try retained.write(to: url, options: .atomic)
        }
    }
}

func string(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return ""
}

func bool(_ value: Any?) -> Bool? {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    if let s = value as? String {
        return ["1", "true", "yes", "y"].contains(s.lowercased())
    }
    return nil
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func runProcess(_ executable: String, _ args: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    defer { pipe.fileHandleForReading.closeFile() }
    let fd = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        return (-1, "Could not configure nonblocking process output")
    }
    do {
        try proc.run()
    } catch {
        return (-1, error.localizedDescription)
    }
    pipe.fileHandleForWriting.closeFile()
    var data = Data()
    var eof = false
    var readFailed = false
    var buffer = [UInt8](repeating: 0, count: 65_536)
    func drainAvailable() {
        // Bound each drain too: an always-writing child cannot starve the
        // timeout check. Never block waiting for EOF held by a descendant.
        for _ in 0..<64 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { eof = true; return }
            else if errno == EINTR { continue }
            else {
                if errno != EAGAIN && errno != EWOULDBLOCK { readFailed = true }
                return
            }
        }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
    var timedOut = false
    while proc.isRunning {
        drainAvailable()
        if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if proc.isRunning {
        proc.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.2
        while proc.isRunning && ProcessInfo.processInfo.systemUptime < grace {
            drainAvailable()
            Thread.sleep(forTimeInterval: 0.01)
        }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }
    proc.waitUntilExit() // Reap this exact child before reading its status.
    let drainDeadline = ProcessInfo.processInfo.systemUptime + 0.2
    repeat {
        drainAvailable()
        if eof || readFailed { break }
        Thread.sleep(forTimeInterval: 0.01)
    } while ProcessInfo.processInfo.systemUptime < drainDeadline
    var output = String(decoding: data, as: UTF8.self)
    if readFailed && !timedOut { return (-1, output + "\n[evaluator] process output read failed\n") }
    if timedOut || !eof {
        output += timedOut ? "\n[evaluator] process timed out\n" : "\n[evaluator] output pipe remained open after child exit\n"
        return (124, output)
    }
    return (proc.terminationStatus, output)
}

func runProcessContract(recorder: Recorder) {
    func require(_ condition: Bool, _ id: String, _ detail: String) {
        if condition { recorder.pass(id, detail) }
        else { recorder.fail(id, "Process execution contract failed", detail) }
    }
    let large = runProcess("/usr/bin/printf", ["%200000s", "x"], timeout: 3)
    require(large.status == 0 && large.output.utf8.count == 200_000 && large.output.hasSuffix("x"),
            "process.output.large", "status=\(large.status), captured=\(large.output.utf8.count) of 200000 bytes")

    let failure = runProcess("/bin/sh", ["-c", "printf 'before\\n'; printf 'failure\\n' >&2; exit 7"])
    require(failure.status == 7 && failure.output.contains("before\n") && failure.output.contains("failure\n"),
            "process.output.failure", "Nonzero exit retains both output streams and the child status")

    let started = ProcessInfo.processInfo.systemUptime
    let timeout = runProcess("/bin/sh", ["-c", "trap '' TERM; echo $$; exec /bin/sleep 30"], timeout: 0.1)
    let childPID = timeout.output.split(separator: "\n").first.flatMap { Int32($0) }
    let reaped = childPID.map { kill($0, 0) == -1 && errno == ESRCH } ?? false
    require(timeout.status == 124 && reaped && ProcessInfo.processInfo.systemUptime - started < 2,
            "process.timeout.reaped", "Timeout kills and reaps the exact TERM-resistant child; status=\(timeout.status), reaped=\(reaped)")

    let inheritedStarted = ProcessInfo.processInfo.systemUptime
    let inherited = runProcess("/bin/sh", ["-c", "/bin/sleep 5 & echo $!"], timeout: 1)
    // This deliberately inherited descriptor belongs to our short-lived
    // fixture descendant only; release it even if the assertion fails.
    if let pid = inherited.output.split(separator: "\n").first.flatMap({ Int32($0) }) {
        kill(pid, SIGTERM)
    }
    require(inherited.status == 124 && ProcessInfo.processInfo.systemUptime - inheritedStarted < 2
                && inherited.output.contains("output pipe remained open"),
            "process.output.inherited_pipe", "An inherited pipe cannot make post-exit draining unbounded")

    let failedListing = Recorder()
    checkRuntimeProcesses(recorder: failedListing, processResult: failure)
    require(failedListing.findings.contains { $0.id == "runtime.process_list.readable" && $0.severity == "fail" }
                && !failedListing.scenarios.contains { $0.status == "pass" },
            "process.list.failure_truth", "A failed process listing cannot certify daemon absence")
    let cleanListing = Recorder()
    checkRuntimeProcesses(recorder: cleanListing, processResult: large)
    require(cleanListing.scenarios.contains { $0.id == "runtime.no_retired_python_daemon" && $0.status == "pass" },
            "process.list.success", "A successful complete process listing still certifies daemon absence")
}

func installedAppURL(repo: URL) -> URL {
    let preferred = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Applications", isDirectory: true)
        .appendingPathComponent("NativeAgent.app", isDirectory: true)
    if fm.fileExists(atPath: preferred.path) { return preferred }
    return repo.appendingPathComponent("dist", isDirectory: true)
        .appendingPathComponent("NativeAgent.app", isDirectory: true)
}

func bundleIdentifier(appURL: URL) -> String {
    Bundle(url: appURL)?.bundleIdentifier ?? "io.github.embwl0x.nativeagent.mac"
}

func runningApp(bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}

func launchOrActivate(appURL: URL, bundleID: String, recorder: Recorder) -> NSRunningApplication? {
    if let app = runningApp(bundleID: bundleID) {
        app.activate(options: [.activateAllWindows])
        recorder.pass("installed_app.running", "NativeAgent is already running, pid \(app.processIdentifier).")
        return app
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    let sem = DispatchSemaphore(value: 0)
    var launched: NSRunningApplication?
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
        if let error {
            recorder.fail("installed_app.launch", "Installed app failed to launch", error.localizedDescription)
        }
        launched = app
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 12)
    for _ in 0..<40 {
        if let app = launched ?? runningApp(bundleID: bundleID) {
            recorder.pass("installed_app.launch", "NativeAgent launched, pid \(app.processIdentifier).")
            return app
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    recorder.fail("installed_app.launch", "Installed app did not launch", "No running application found for \(bundleID).")
    return nil
}

func copyAX(_ element: AXUIElement, _ attr: String) -> AnyObject? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
    guard err == .success else { return nil }
    return value
}

func axString(_ element: AXUIElement, _ attr: String) -> String {
    guard let value = copyAX(element, attr) else { return "" }
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return ""
}

func axBool(_ element: AXUIElement, _ attr: String) -> Bool? {
    guard let value = copyAX(element, attr) else { return nil }
    return value as? Bool
}

func axPoint(_ element: AXUIElement, _ attr: String) -> CGPoint? {
    guard let value = copyAX(element, attr) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
}

func axSize(_ element: AXUIElement, _ attr: String) -> CGSize? {
    guard let value = copyAX(element, attr) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let point = axPoint(element, kAXPositionAttribute),
          let size = axSize(element, kAXSizeAttribute) else { return nil }
    return CGRect(origin: point, size: size)
}

func jsonSafeDouble(_ value: CGFloat) -> Double? {
    let double = Double(value)
    return double.isFinite ? double : nil
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let children = copyAX(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
    return children
}

func axWindows(_ element: AXUIElement) -> [AXUIElement] {
    guard let windows = copyAX(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
    // During launch AX can briefly return the application proxy itself here.
    // Do not recurse through that proxy as though it were a mounted window.
    return windows.filter { axString($0, kAXRoleAttribute) == kAXWindowRole }
}

func axActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let err = AXUIElementCopyActionNames(element, &names)
    guard err == .success, let names else { return [] }
    return (names as NSArray).compactMap { $0 as? String }
}

func labelFor(_ element: AXUIElement) -> String {
    let title = axString(element, kAXTitleAttribute)
    if !title.isEmpty { return title }
    let desc = axString(element, kAXDescriptionAttribute)
    if !desc.isEmpty { return desc }
    return axString(element, kAXValueAttribute)
}

func collectAX(_ element: AXUIElement, path: String, depth: Int, maxDepth: Int, budget: inout Int, out: inout [UISnapshot]) {
    guard depth <= maxDepth, budget > 0 else { return }
    budget -= 1
    let children = axChildren(element)
    let frame = axFrame(element)
    out.append(UISnapshot(
        path: path,
        role: axString(element, kAXRoleAttribute),
        title: axString(element, kAXTitleAttribute),
        value: axString(element, kAXValueAttribute),
        description: axString(element, kAXDescriptionAttribute),
        enabled: axBool(element, kAXEnabledAttribute),
        actions: axActions(element),
        childCount: children.count,
        x: frame.flatMap { jsonSafeDouble($0.minX) },
        y: frame.flatMap { jsonSafeDouble($0.minY) },
        width: frame.flatMap { jsonSafeDouble($0.width) },
        height: frame.flatMap { jsonSafeDouble($0.height) }
    ))
    for (idx, child) in children.enumerated() {
        collectAX(child, path: "\(path).\(idx)", depth: depth + 1, maxDepth: maxDepth, budget: &budget, out: &out)
    }
}

func collectAppSnapshot(appElement: AXUIElement) -> [UISnapshot] {
    var out: [UISnapshot] = []
    var budget = 2_000
    let windows = axWindows(appElement)
    for (idx, window) in windows.enumerated() {
        // Nested SwiftUI Lists expose their row labels below depth nine.
        // Keep the node budget bounded, but include those actual controls.
        collectAX(window, path: "window\(idx)", depth: 0, maxDepth: 18, budget: &budget, out: &out)
    }
    return out
}

let actionableRoles: Set<String> = [
    kAXButtonRole,
    kAXCheckBoxRole,
    kAXRadioButtonRole,
    kAXPopUpButtonRole,
    kAXMenuButtonRole,
    kAXDisclosureTriangleRole,
    "AXLink",
    kAXTabGroupRole,
    kAXRowRole,
    kAXCellRole
]

let selectableActions: [String] = [
    kAXPressAction,
    kAXShowDefaultUIAction,
    kAXShowAlternateUIAction
]

func elementMatches(_ element: AXUIElement, labels: [String], depth: Int = 0, maxDepth: Int = 3, budget: inout Int) -> Bool {
    guard depth <= maxDepth, budget > 0 else { return false }
    budget -= 1
    let label = labelFor(element).lowercased()
    if !label.isEmpty {
        for candidate in labels {
            let needle = candidate.lowercased()
            // AX combines a link title and its subtitle with a comma. Match
            // that title, not an incidental word in another row's subtitle.
            if label == needle || label.hasPrefix(needle + ",")
                || label.hasPrefix(needle + " (")
                || (needle.hasSuffix("(" ) && label.hasPrefix(needle)) {
                return true
            }
        }
    }
    for child in axChildren(element) {
        if elementMatches(child, labels: labels, depth: depth + 1, maxDepth: maxDepth, budget: &budget) {
            return true
        }
    }
    return false
}

func firstWindowFrame(appElement: AXUIElement) -> CGRect? {
    axWindows(appElement).compactMap(axFrame).first
}

func isVisibleFrame(_ frame: CGRect?) -> Bool {
    guard let frame else { return false }
    return frame.width > 1 && frame.height > 1
}

func sidebarRegion(appElement: AXUIElement) -> ((CGRect?) -> Bool) {
    let window = firstWindowFrame(appElement: appElement)
    let maxX = (window?.minX ?? 0) + 265
    return { frame in
        guard let frame else { return false }
        return frame.minX <= maxX && frame.width > 1 && frame.height > 1
    }
}

func findActionable(
    _ root: AXUIElement,
    labels: [String],
    depth: Int = 0,
    maxDepth: Int = 18,
    budget: inout Int,
    region: ((CGRect?) -> Bool)? = nil
) -> AXUIElement? {
    guard depth <= maxDepth, budget > 0 else { return nil }
    budget -= 1
    let role = axString(root, kAXRoleAttribute)
    let actions = axActions(root)
    let canSelect = selectableActions.contains(where: { actions.contains($0) })
    // Prefer the actual control over an enclosing AXRow/AXCell. SwiftUI can
    // accept ShowDefaultUI on that wrapper without activating its link.
    for child in axChildren(root) {
        if let found = findActionable(child, labels: labels, depth: depth + 1, maxDepth: maxDepth, budget: &budget, region: region) {
            return found
        }
    }
    var matchBudget = 80
    if (actionableRoles.contains(role) || canSelect)
        && (region?(axFrame(root)) ?? true)
        && elementMatches(root, labels: labels, budget: &matchBudget) {
        return root
    }
    return nil
}

func directLabelMatches(_ element: AXUIElement, labels: [String]) -> Bool {
    let label = labelFor(element).lowercased()
    guard !label.isEmpty else { return false }
    return labels.contains { candidate in
        let needle = candidate.lowercased()
        return label == needle || label.contains(needle)
    }
}

func findExactButton(
    _ root: AXUIElement,
    labels: [String],
    depth: Int = 0,
    maxDepth: Int = 18,
    budget: inout Int
) -> AXUIElement? {
    guard depth <= maxDepth, budget > 0 else { return nil }
    budget -= 1
    let role = axString(root, kAXRoleAttribute)
    let actions = axActions(root)
    if role == kAXButtonRole
        && actions.contains(kAXPressAction)
        && directLabelMatches(root, labels: labels) {
        return root
    }
    for child in axChildren(root) {
        if let found = findExactButton(child, labels: labels, depth: depth + 1, maxDepth: maxDepth, budget: &budget) {
            return found
        }
    }
    return nil
}

func findFirstElement(
    _ root: AXUIElement,
    role expectedRole: String,
    depth: Int = 0,
    maxDepth: Int = 12,
    budget: inout Int
) -> AXUIElement? {
    // Search shallow siblings first: a large list must not consume the budget
    // before we inspect a sheet attached to the same window.
    var queue: [(AXUIElement, Int)] = [(root, depth)]
    var index = 0
    while index < queue.count && budget > 0 {
        let (element, currentDepth) = queue[index]
        index += 1
        guard currentDepth <= maxDepth else { continue }
        budget -= 1
        if axString(element, kAXRoleAttribute) == expectedRole { return element }
        if currentDepth < maxDepth {
            let available = max(0, budget - (queue.count - index))
            queue.append(contentsOf: axChildren(element).prefix(available).map { ($0, currentDepth + 1) })
        }
    }
    return nil
}

func pressFirst(appElement: AXUIElement, labels: [String], sidebarOnly: Bool = false) -> Bool {
    var budget = 2_000
    let window = firstWindowFrame(appElement: appElement)
    let region: ((CGRect?) -> Bool)? = sidebarOnly ? sidebarRegion(appElement: appElement) : { frame in
        guard let frame, let window else { return false }
        // Child-page actions belong to the detail, never a same-named global
        // sidebar item (for example Native Experience > Capabilities).
        return frame.minX >= window.minX + 265 && frameIsFullyVisible(frame, within: window)
    }
    guard let element = findActionable(appElement, labels: labels, budget: &budget, region: region) else { return false }
    let frame = axFrame(element)
    if sidebarOnly, let frame, isVisibleFrame(frame) {
        return mouseClick(frame: frame)
    }
    // SwiftUI NavigationLink rows are currently exposed as AXUnknown with an
    // AXPress action. AppKit can report that action as successful without
    // activating the row, producing a false route pass. A real center click is
    // the user-observable interaction and reliably exercises those rows.
    if axString(element, kAXRoleAttribute) == kAXUnknownRole,
       let frame,
       isVisibleFrame(frame) {
        return mouseClick(frame: frame)
    }
    let actions = axActions(element)
    for action in selectableActions where actions.contains(action) {
        let err = AXUIElementPerformAction(element, action as CFString)
        if err == .success { return true }
    }
    if let frame, isVisibleFrame(frame) {
        return mouseClick(frame: frame)
    }
    return false
}

func pressExactButton(appElement: AXUIElement, labels: [String]) -> Bool {
    var budget = 2_000
    guard let element = findExactButton(appElement, labels: labels, budget: &budget) else { return false }
    guard let frame = axFrame(element),
          let window = firstWindowFrame(appElement: appElement),
          frameIsFullyVisible(frame, within: window) else { return false }
    let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if err == .success { return true }
    if isVisibleFrame(frame) {
        return mouseClick(frame: frame)
    }
    return false
}

func visibleTextContains(appElement: AXUIElement, labels: [String]) -> Bool {
    let text = allVisibleText(collectAppSnapshot(appElement: appElement)).lowercased()
    return labels.contains { text.contains($0.lowercased()) }
}

func ensureAdvancedExpanded(appElement: AXUIElement) {
    if visibleTextContains(appElement: appElement, labels: ["Dreams", "Diagnostics"]) { return }
    if pressFirst(appElement: appElement, labels: ["Advanced"], sidebarOnly: true) {
        Thread.sleep(forTimeInterval: 0.4)
    }
}

func trimmedText(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func snapshotFrame(_ snapshot: UISnapshot) -> CGRect? {
    guard let x = snapshot.x, let y = snapshot.y,
          let width = snapshot.width, let height = snapshot.height,
          x.isFinite, y.isFinite, width.isFinite, height.isFinite,
          width > 1, height > 1 else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
}

func containingWindowFrame(for snapshot: UISnapshot, in snapshots: [UISnapshot]) -> CGRect? {
    let windowPath = snapshot.path.split(separator: ".", maxSplits: 1).first.map(String.init) ?? snapshot.path
    return snapshots.first { $0.path == windowPath }.flatMap(snapshotFrame)
}

func frameIsFullyVisible(_ frame: CGRect, within window: CGRect) -> Bool {
    let tolerance: CGFloat = 0.5
    return frame.minX >= window.minX - tolerance
        && frame.minY >= window.minY - tolerance
        && frame.maxX <= window.maxX + tolerance
        && frame.maxY <= window.maxY + tolerance
}

func isVisibleSnapshot(_ snapshot: UISnapshot, in snapshots: [UISnapshot]) -> Bool {
    guard let frame = snapshotFrame(snapshot),
          let window = containingWindowFrame(for: snapshot, in: snapshots) else { return false }
    return snapshot.path == snapshot.path.split(separator: ".", maxSplits: 1).first.map(String.init)
        || frameIsFullyVisible(frame, within: window)
}

func isHiddenHarnessText(_ text: String) -> Bool {
    let trimmed = trimmedText(text)
    return trimmed.hasPrefix("Jump: ") || trimmed.hasPrefix("User Mode: ")
}

func rawSnapshotTextParts(_ snapshot: UISnapshot) -> [String] {
    [snapshot.title, snapshot.value, snapshot.description]
        .map(trimmedText)
        .filter { !$0.isEmpty }
}

func visibleSnapshotTextParts(_ snapshot: UISnapshot) -> [String] {
    rawSnapshotTextParts(snapshot)
        .filter { !isHiddenHarnessText($0) }
}

func isHiddenHarnessSnapshot(_ snapshot: UISnapshot) -> Bool {
    rawSnapshotTextParts(snapshot).contains(where: isHiddenHarnessText)
}

func isDescendantOfRole(_ snapshot: UISnapshot, role: String, in snapshots: [UISnapshot]) -> Bool {
    snapshots.contains { ancestor in
        ancestor.role == role && snapshot.path.hasPrefix("\(ancestor.path).")
    }
}

func isStandardWindowChrome(_ snapshot: UISnapshot) -> Bool {
    snapshot.role == kAXButtonRole
        && snapshot.path.split(separator: ".").count == 2
        && (snapshot.width ?? 0) <= 24
        && (snapshot.height ?? 0) <= 24
}

func effectiveVisibleLabel(_ snapshot: UISnapshot, in snapshots: [UISnapshot]) -> String {
    if let own = visibleSnapshotTextParts(snapshot).first {
        return own
    }
    let childPrefix = "\(snapshot.path)."
    return snapshots
        .filter { $0.path.hasPrefix(childPrefix) && isVisibleSnapshot($0, in: snapshots) }
        .flatMap(visibleSnapshotTextParts)
        .first ?? ""
}

func allVisibleText(_ snapshots: [UISnapshot]) -> String {
    snapshots
        .filter { isVisibleSnapshot($0, in: snapshots) }
        .flatMap(visibleSnapshotTextParts)
        .joined(separator: "\n")
}

func detailVisibleText(_ snapshots: [UISnapshot]) -> String {
    let windowMinX = snapshots.first(where: { $0.path.hasPrefix("window") && !$0.path.contains(".") })?.x ?? 0
    let detailMinX = windowMinX + 265
    return snapshots
        .filter { isVisibleSnapshot($0, in: snapshots) }
        .filter { ($0.x ?? 0) >= detailMinX }
        .flatMap(visibleSnapshotTextParts)
        .joined(separator: "\n")
}

// Read-only navigation of long setup panels. Hidden AX text is never proof:
// scroll its owning area until the actual label enters the window.
func revealDetailText(_ label: String, appElement: AXUIElement) -> Bool {
    for _ in 0..<12 {
        let snapshots = collectAppSnapshot(appElement: appElement)
        if detailVisibleText(snapshots).localizedCaseInsensitiveContains(label) { return true }
        guard let target = snapshots.first(where: {
            rawSnapshotTextParts($0).contains { $0.localizedCaseInsensitiveContains(label) }
        }), let frame = snapshotFrame(target),
        let window = containingWindowFrame(for: target, in: snapshots),
        let ancestor = snapshots.last(where: {
            $0.role == kAXScrollAreaRole && target.path.hasPrefix($0.path + ".")
        }) else { return false }
        let components = ancestor.path.split(separator: ".")
        guard let first = components.first,
              let index = Int(first.dropFirst("window".count)) else { return false }
        let windows = axWindows(appElement)
        guard windows.indices.contains(index) else { return false }
        var element = windows[index]
        for component in components.dropFirst() {
            let children = axChildren(element)
            guard let childIndex = Int(component), children.indices.contains(childIndex) else { return false }
            element = children[childIndex]
        }
        // AppKit reports successful page actions on this SwiftUI ScrollView
        // without moving it. Use the same bounded wheel gesture as a person.
        guard let area = axFrame(element) else { return false }
        let visibleArea = area.intersection(window)
        guard !visibleArea.isNull, visibleArea.width > 20, visibleArea.height > 20 else { return false }
        let point = CGPoint(x: visibleArea.maxX - 20, y: visibleArea.midY)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 1, wheel1: frame.minY < window.minY ? 500 : -500,
                                   wheel2: 0, wheel3: 0) else { return false }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        scroll.location = point
        scroll.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.2)
    }
    return detailVisibleText(collectAppSnapshot(appElement: appElement)).localizedCaseInsensitiveContains(label)
}

func visibilityFixtureSnapshot(
    path: String,
    role: String = kAXButtonRole,
    x: Double,
    y: Double,
    width: Double,
    height: Double
) -> UISnapshot {
    UISnapshot(
        path: path,
        role: role,
        title: path,
        value: "",
        description: "",
        enabled: true,
        actions: [kAXPressAction],
        childCount: 0,
        x: x,
        y: y,
        width: width,
        height: height
    )
}

func runVisibilityContract(artifactDir: URL, recorder: Recorder) {
    let snapshots = [
        visibilityFixtureSnapshot(path: "window0", role: kAXWindowRole, x: 100, y: 100, width: 900, height: 700),
        visibilityFixtureSnapshot(path: "window0.0", x: 150, y: 180, width: 120, height: 30),
        visibilityFixtureSnapshot(path: "window0.1", x: 150, y: 1_600, width: 120, height: 30),
        visibilityFixtureSnapshot(path: "window0.2", x: 150, y: 790, width: 120, height: 30),
        visibilityFixtureSnapshot(path: "window0.3", x: 150, y: 220, width: 0, height: 30),
    ]
    let observed = snapshots.map { isVisibleSnapshot($0, in: snapshots) }
    if observed == [true, true, false, false, false] {
        recorder.pass("ui.visibility.geometry", "Only positive-size controls fully contained by their app window count as visible.")
    } else {
        recorder.fail(
            "ui.visibility.geometry",
            "Window-clipped controls passed the visibility contract",
            "Expected [true, true, false, false, false], observed \(observed)."
        )
    }

    let semanticRoutes = userModeRoutes(includeNativeExperience: false).filter {
        ["providers", "trust", "personality", "knowledge", "mac-assistant-watch-setup"].contains($0.id)
    }
    if semanticRoutes.count == 5 && semanticRoutes.allSatisfy({
        $0.steps.count == 1 && $0.steps[0].sidebarOnly && $0.steps[0].commandKey == nil
    }) {
        recorder.pass("ui.routes.semantic_sidebar", "Reordered and Advanced pages use their visible sidebar labels, not stale numbered shortcuts.")
    } else {
        recorder.fail("ui.routes.semantic_sidebar", "Sidebar routes regressed to positional shortcuts", "Expected five named sidebar routes.")
    }

    let inboxURL = artifactDir.appendingPathComponent("visibility-contract-inbox.jsonl")
    let historical = Data("{\"id\":\"older-a\"}\n{\"id\":\"older-b\"}\n".utf8)
    do {
        try historical.write(to: inboxURL, options: .atomic)
        let existed = try installOpenApprovalsProbeCard(inboxURL: inboxURL, id: "front-probe")
        let installed = try Data(contentsOf: inboxURL)
        let firstID = jsonlRows(at: inboxURL).first?["id"] as? String
        let retainedHistory = installed.suffix(historical.count).elementsEqual(historical)
        let concurrent = Data("{\"id\":\"arrived-during-eval\"}\n".utf8)
        var withConcurrentArrival = installed
        withConcurrentArrival.append(concurrent)
        try withConcurrentArrival.write(to: inboxURL, options: .atomic)
        try removeJSONLRow(url: inboxURL, id: "front-probe", fileExistedBeforeProbe: existed)
        let cleaned = try Data(contentsOf: inboxURL)
        var expected = historical
        expected.append(concurrent)
        if firstID == "front-probe", retainedHistory, cleaned == expected {
            recorder.pass("ui.flow.inbox_open_approvals.fixture_order", "The locked Open Approvals probe is mounted first and cleanup preserves concurrent arrivals.")
        } else {
            recorder.fail(
                "ui.flow.inbox_open_approvals.fixture_order",
                "The Open Approvals probe did not own the first visible row",
                "firstID=\(firstID ?? "nil"), retainedHistory=\(retainedHistory), preservedConcurrentArrival=\(cleaned == expected)"
            )
        }
    } catch {
        recorder.fail("ui.flow.inbox_open_approvals.fixture_order", "Could not exercise the probe fixture contract", error.localizedDescription)
    }
}

func screenshot(to url: URL) {
    _ = runProcess("/usr/sbin/screencapture", ["-x", url.path], timeout: 5)
}

func mouseClick(frame: CGRect) -> Bool {
    let point = CGPoint(x: frame.midX, y: frame.midY)
    guard let down = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: point,
        mouseButton: .left
    ),
    let up = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        return false
    }
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    up.post(tap: .cghidEventTap)
    return true
}

func sendShortcut(_ key: String, modifiersScript: String) -> Bool {
    let script = "tell application \"System Events\" to keystroke \"\(key)\" using \(modifiersScript)"
    let result = runProcess("/usr/bin/osascript", ["-e", script], timeout: 5)
    return result.status == 0
}

func commandPaletteField(appElement: AXUIElement) -> AXUIElement? {
    var sheetBudget = 2_000
    guard let sheet = findFirstElement(appElement, role: kAXSheetRole, budget: &sheetBudget) else { return nil }
    var fieldBudget = 500
    return findFirstElement(sheet, role: kAXTextFieldRole, maxDepth: 6, budget: &fieldBudget)
}

func selectCommandPaletteItem(
    app: NSRunningApplication,
    appElement: AXUIElement,
    query: String
) -> Bool {
    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.2)
    guard sendShortcut("k", modifiersScript: "command down") else { return false }

    let openDeadline = Date().addingTimeInterval(2)
    var field: AXUIElement?
    while field == nil && Date() < openDeadline {
        field = commandPaletteField(appElement: appElement)
        if field == nil { Thread.sleep(forTimeInterval: 0.05) }
    }
    guard let field else { return false }
    guard AXUIElementSetAttributeValue(
        field,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    ) == .success else {
        return false
    }

    let escapedQuery = query
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "System Events"
        keystroke "\(escapedQuery)"
        delay 0.1
        key code 36
    end tell
    """
    let result = runProcess("/usr/bin/osascript", ["-e", script], timeout: 5)
    guard result.status == 0 else { return false }

    let closeDeadline = Date().addingTimeInterval(2)
    while Date() < closeDeadline {
        if commandPaletteField(appElement: appElement) == nil { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}

func checkDoctor(repo: URL, recorder: Recorder) {
    let path = repo.appendingPathComponent("data/doctor/latest.json")
    let root = jsonDictionary(at: path)
    guard let checks = root["checks"] as? [[String: Any]], !checks.isEmpty else {
        recorder.warn("doctor.latest.present", "Doctor latest report missing", "No data/doctor/latest.json checks found.")
        return
    }
    let failures = checks.filter { string($0["status"]).lowercased() == "error" || string($0["status"]).lowercased() == "fail" }
    let warnings = checks.filter { string($0["status"]).lowercased() == "warn" }
    if !failures.isEmpty {
        let names = failures.map { "\(string($0["title"])) (\(string($0["id"])))" }.joined(separator: ", ")
        recorder.fail("doctor.latest.no_errors", "Doctor has failing rows", names)
    } else if !warnings.isEmpty {
        let names = warnings.map { "\(string($0["title"])) (\(string($0["id"])))" }.joined(separator: ", ")
        recorder.warn("doctor.latest.no_warnings", "Doctor has warning rows", names)
    } else {
        recorder.pass("doctor.latest.clean", "Doctor latest has \(checks.count) ok row(s).")
    }
    let bridgeMissing = checks.filter {
        string($0["id"]) == "icloud_bridge_state"
            && string($0["detail"]).localizedCaseInsensitiveContains("missing")
    }
    if bridgeMissing.isEmpty {
        recorder.pass("doctor.icloud_bridge.not_missing", "iCloud bridge Doctor row does not report missing paths.")
    } else {
        recorder.fail("doctor.icloud_bridge.not_missing", "iCloud bridge reports missing paths", bridgeMissing.map { string($0["detail"]) }.joined(separator: "; "))
    }
}

func checkInbox(repo: URL, recorder: Recorder) {
    let path = repo.appendingPathComponent("data/notifications/inbox.jsonl")
    let rows = jsonlRows(at: path)
    guard !rows.isEmpty else {
        recorder.warn("inbox.visible.present", "Visible Inbox is empty", "data/notifications/inbox.jsonl has no rows.")
        return
    }
    let activeStatuses: Set<String> = ["", "unread", "read"]
    let placeholderRows = rows.filter { row in
        string(row["source"]) == "scheduled_proactive_scan"
            && activeStatuses.contains(string(row["status"]).lowercased())
            && string(row["title"]) == "Scheduled proactive scan"
            && string(row["summary"]).hasPrefix("Reason: scheduled_proactive_scan")
    }
    if placeholderRows.isEmpty {
        recorder.pass("inbox.no_placeholder_proactive_scan", "No active placeholder scheduled_proactive_scan rows.")
    } else {
        recorder.fail(
            "inbox.no_placeholder_proactive_scan",
            "Proactive scan placeholder rows are visible",
            "Found \(placeholderRows.count) active placeholder row(s): \(placeholderRows.prefix(5).map { string($0["id"]) }.joined(separator: ", "))"
        )
    }
    let malformed = rows.filter {
        string($0["id"]).isEmpty || string($0["title"]).isEmpty || string($0["status"]).isEmpty
    }
    if malformed.isEmpty {
        recorder.pass("inbox.rows.well_formed", "Visible Inbox rows have ids, titles, and statuses.")
    } else {
        recorder.fail("inbox.rows.well_formed", "Visible Inbox has malformed rows", "Found \(malformed.count) row(s) missing id/title/status.")
    }
}

func checkMemoryHygiene(repo: URL, recorder: Recorder) {
    let path = repo.appendingPathComponent("data/memory/hygiene_last_run.json")
    let report = jsonDictionary(at: path)
    guard !report.isEmpty else {
        recorder.warn("memory.hygiene.receipt_present", "Memory hygiene has no last-run receipt", "Expected data/memory/hygiene_last_run.json after manual hygiene runs.")
        return
    }
    let createdAt = string(report["createdAt"])
    let status = string(report["status"]).lowercased()
    let hasCounts = report["beforeCount"] != nil && report["afterCount"] != nil
    if createdAt.isEmpty || status.isEmpty || !hasCounts {
        recorder.fail("memory.hygiene.receipt_shape", "Memory hygiene receipt is incomplete", "createdAt=\(createdAt), status=\(status), hasCounts=\(hasCounts)")
    } else {
        recorder.pass("memory.hygiene.receipt_shape", "Last hygiene receipt exists at \(createdAt) with status \(status).")
    }
}

func checkScheduler(repo: URL, recorder: Recorder) {
    let jobs = jsonArray(at: repo.appendingPathComponent("data/scheduler/jobs.json"))
    guard !jobs.isEmpty else {
        recorder.fail("scheduler.jobs.present", "Scheduler jobs missing", "data/scheduler/jobs.json is empty or unreadable.")
        return
    }
    if let proactive = jobs.first(where: { string($0["kind"]) == "proactive_scan" }) {
        let nextRun = string(proactive["nextRunAtISO"])
        let enabled = bool(proactive["enabled"]) ?? false
        if enabled && nextRun.isEmpty {
            recorder.fail("scheduler.proactive.next_run", "Enabled proactive scan has no next run", "Job \(string(proactive["id"])) is enabled with no nextRunAtISO.")
        } else {
            recorder.pass("scheduler.proactive.next_run", "Proactive scan next run: \(nextRun.isEmpty ? "not enabled" : nextRun).")
        }
        let detail = string(proactive["lastRunDetail"]).lowercased()
        if string(proactive["lastRunStatus"]).lowercased() == "completed"
            && detail == "proactive scan surfaced in inbox" {
            recorder.warn(
                "scheduler.proactive.legacy_detail",
                "Proactive scan still has legacy last-run detail",
                "This is allowed only before the first post-fix scheduled run. Next run should say surfaced N opportunity cards or skipped/no new opportunities."
            )
        }
    } else {
        recorder.warn("scheduler.proactive.present", "No proactive_scan job found", "User Mode cannot check scheduled proactive scan behavior.")
    }
    if let dream = jobs.first(where: { string($0["id"]) == "nativeagent-nightly-dream" || string($0["kind"]) == "dream" }) {
        let payload = dream["payload"] as? [String: Any] ?? [:]
        if payload["maxSessions"] != nil || payload["max_sessions"] != nil {
            recorder.fail(
                "scheduler.dream.retired_batch_field",
                "Nightly dream still carries a retired batch-size field",
                "Dream owns one bounded cycle per invocation; remove maxSessions/max_sessions from the scheduled payload."
            )
        } else {
            recorder.pass("scheduler.dream.default_bounded", "Nightly dream uses one bounded cycle per invocation.")
        }
    } else {
        recorder.warn("scheduler.dream.present", "No nightly dream job found", "User Mode cannot check dream overproduction regression.")
    }
}

func checkRuntimeProcesses(recorder: Recorder, processResult: (status: Int32, output: String)? = nil) {
    let result = processResult ?? runProcess("/bin/ps", ["-axo", "pid,command"], timeout: 5)
    guard result.status == 0 else {
        recorder.fail("runtime.process_list.readable", "Could not inspect running processes", result.output)
        return
    }
    if result.output.contains("native_agentd.py") {
        recorder.fail("runtime.no_retired_python_daemon", "Retired external runtime is running", "ps output still includes native_agentd.py.")
    } else {
        recorder.pass("runtime.no_retired_python_daemon", "No native_agentd.py process is running.")
    }
}

func extractSidebarItemCases(from text: String, staticVarName: String) -> [String] {
    guard let declaration = text.range(of: "static var \(staticVarName): [SidebarItem]") else {
        return []
    }
    let tail = text[declaration.upperBound...]
    guard let start = tail.firstIndex(of: "[") else { return [] }
    var depth = 0
    var end: String.Index?
    var index = start
    while index < tail.endIndex {
        let ch = tail[index]
        if ch == "[" {
            depth += 1
        } else if ch == "]" {
            depth -= 1
            if depth == 0 {
                end = index
                break
            }
        }
        index = tail.index(after: index)
    }
    guard let end else { return [] }
    let body = String(tail[start...end])
    let regex = try? NSRegularExpression(pattern: #"\.([A-Za-z][A-Za-z0-9_]*)"#)
    let ns = body as NSString
    return regex?.matches(in: body, range: NSRange(location: 0, length: ns.length)).compactMap { match in
        guard match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    } ?? []
}

func readSidebarModelText(repo: URL) -> (text: String, sources: [String])? {
    let appSources = repo
        .appendingPathComponent("Sources", isDirectory: true)
        .appendingPathComponent("NativeAgentApp", isDirectory: true)
    let legacyModels = appSources.appendingPathComponent("Models.swift")
    let splitModelsDir = appSources.appendingPathComponent("Models", isDirectory: true)

    var candidates = [legacyModels]
    if let splitFiles = try? fm.contentsOfDirectory(
        at: splitModelsDir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) {
        candidates.append(contentsOf: splitFiles
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    var parts: [String] = []
    var sources: [String] = []
    for candidate in candidates {
        guard let text = try? String(contentsOf: candidate, encoding: .utf8) else {
            continue
        }
        parts.append(text)
        sources.append(candidate.path)
    }

    guard !parts.isEmpty else { return nil }
    return (parts.joined(separator: "\n\n"), sources)
}

func userModeRouteID(forSidebarCase name: String) -> String? {
    switch name {
    case "chat": "chat"
    case "activity": "activity"
    case "memories": "memories"
    case "skills": "skills"
    case "desk": "desk"
    case "personality": "personality"
    case "connectors": "connectors"
    case "trust": "trust"
    case "providers": "providers"
    case "macIntegration": "mac-integration"
    case "settings": "settings"
    case "command": "command-center"
    case "capabilities": "capabilities"
    case "knowledge": "knowledge"
    case "dreams": "dreams"
    case "diagnostics": "diagnostics"
    case "inboxPolicy": "inbox-policy"
    case "tools": "tools"
    case "mcp": "mcp"
    case "inspector": "inspector"
    case "cognition": "cognition"
    default: nil
    }
}

func checkUserModeRouteCoverage(
    repo: URL,
    routes: [UIRoute],
    includeNativeExperience: Bool,
    recorder: Recorder
) {
    guard let sidebarModel = readSidebarModelText(repo: repo) else {
        let expectedRoot = repo
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("NativeAgentApp", isDirectory: true)
        recorder.fail("user_mode.route_coverage.models_readable", "Could not read sidebar model files", expectedRoot.path)
        return
    }
    let sidebarCases = Set(
        extractSidebarItemCases(from: sidebarModel.text, staticVarName: "primaryItems")
            + extractSidebarItemCases(from: sidebarModel.text, staticVarName: "advancedItems")
    )
    guard !sidebarCases.isEmpty else {
        recorder.fail(
            "user_mode.route_coverage.sidebar_items",
            "No primary/Advanced sidebar items found",
            "Could not parse SidebarItem.primaryItems/advancedItems from \(sidebarModel.sources.joined(separator: ", "))."
        )
        return
    }
    let unmapped = sidebarCases.filter { userModeRouteID(forSidebarCase: $0) == nil }.sorted()
    if !unmapped.isEmpty {
        recorder.fail(
            "user_mode.route_coverage.unmapped_sidebar_items",
            "Sidebar item has no User Mode route mapping",
            "Missing mapping for: \(unmapped.joined(separator: ", "))"
        )
        return
    }
    let sidebarRouteIDs = Set(sidebarCases.compactMap(userModeRouteID(forSidebarCase:)))
    let expectedRouteIDs = sidebarRouteIDs.union(
        userModeExpectedAdditionalRouteIDs(includeNativeExperience: includeNativeExperience)
    )
    let routeIDCounts = Dictionary(grouping: routes.map(\.id), by: { $0 }).mapValues(\.count)
    let duplicates = routeIDCounts.filter { $0.value > 1 }.map(\.key).sorted()
    let actualRouteIDs = Set(routeIDCounts.keys)
    let missing = expectedRouteIDs.subtracting(actualRouteIDs).sorted()
    let unexpected = actualRouteIDs.subtracting(expectedRouteIDs).sorted()
    if missing.isEmpty && unexpected.isEmpty && duplicates.isEmpty {
        recorder.pass("user_mode.route_coverage.current_sidebar", "User Mode route IDs exactly match \(expectedRouteIDs.count) current sidebar and routed-child surface(s).")
    } else {
        var detail: [String] = []
        if !missing.isEmpty {
            detail.append("Missing current route id(s): \(missing.joined(separator: ", "))")
        }
        if !unexpected.isEmpty {
            detail.append("Unexpected or obsolete route id(s): \(unexpected.joined(separator: ", "))")
        }
        if !duplicates.isEmpty {
            detail.append("Duplicate route id(s): \(duplicates.joined(separator: ", "))")
        }
        recorder.fail(
            "user_mode.route_coverage.current_sidebar",
            "User Mode route list does not match current surfaces",
            detail.joined(separator: ". ")
        )
    }
}

func checkVisibleTextContradictions(_ text: String, context: String, recorder: Recorder) {
    let lines = text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let lower = text.lowercased()
    let statusStopKeywords = [
        "watchdog",
        "runtime",
        "swift lifecycle",
        "background loop",
        "background loops",
        "workshop",
        "execution",
        "improvement",
        "improvements"
    ]
    let healthyStatusLine = lines.first { line in
        let lowerLine = line.lowercased()
        return lowerLine.contains("healthy") && line.count <= 180
    }
    let stoppedStatusLine = lines.first { line in
        let lowerLine = line.lowercased()
        return lowerLine.contains("stopped")
            && statusStopKeywords.contains { lowerLine.contains($0) }
            && line.count <= 240
    }
    let sameStatusLine = lines.first { line in
        let lowerLine = line.lowercased()
        return lowerLine.contains("healthy")
            && lowerLine.contains("stopped")
            && line.count <= 240
    }
    if let sameStatusLine {
        recorder.fail(
            "ui.\(context).healthy_stopped_contradiction",
            "Visible UI says healthy and stopped together",
            "Visible status text for \(context) contains both Healthy and stopped: \(sameStatusLine)"
        )
    } else if let healthyStatusLine, let stoppedStatusLine {
        recorder.fail(
            "ui.\(context).healthy_stopped_contradiction",
            "Visible UI says healthy and stopped together",
            "Visible status text for \(context) contains Healthy (\(healthyStatusLine)) and stopped (\(stoppedStatusLine))."
        )
    }
    if lower.contains("scheduled proactive scan") && lower.contains("reason: scheduled_proactive_scan") {
        recorder.fail(
            "ui.\(context).placeholder_proactive_scan_visible",
            "Visible UI shows placeholder proactive scan receipt",
            "Scheduled proactive scan placeholder text is visible in \(context)."
        )
    }
    if lower.contains("hygiene scheduled") && !lower.contains("last hygiene") {
        recorder.fail(
            "ui.\(context).hygiene_missing_timestamp",
            "Memory UI shows hygiene scheduled without last-run timestamp",
            "Visible text for \(context) contains hygiene scheduled but no last hygiene timestamp."
        )
    }
}

func checkUIRuntimeIssues(
    since startedAt: Date,
    processName: String,
    artifactDir: URL,
    strict: Bool,
    recorder: Recorder
) {
    let predicate = "process == \"\(processName)\" AND "
        + "(subsystem == \"com.apple.SwiftUI\" OR "
        + "subsystem == \"com.apple.runtime-issues\" OR "
        + "subsystem == \"com.apple.AppKit\")"
    let result = runProcess(
        "/usr/bin/log",
        ["show", "--style", "compact", "--start", systemLogDate(startedAt), "--predicate", predicate],
        timeout: 20
    )
    guard result.status == 0 else {
        recorder.warn(
            "ui.runtime_log.readable",
            "Could not inspect NativeAgent UI runtime diagnostics",
            result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return
    }

    try? result.output.write(
        to: artifactDir.appendingPathComponent("ui-runtime-issues.log"),
        atomically: true,
        encoding: .utf8
    )
    let lines = result.output.split(separator: "\n").map(String.init)
    let invalidConfiguration = lines.filter {
        $0.contains("No symbol named") || $0.contains("Invalid Configuration")
    }
    let undeclaredTypes = lines.filter {
        $0.contains("expected to be declared and exported")
    }
    let mainThreadWork = lines.filter {
        $0.contains("Performance Diagnostics") && $0.contains("main thread")
    }
    let layoutRecursion = lines.filter {
        $0.contains("layoutSubtreeIfNeeded") && $0.contains("already being laid out")
    }

    func compact(_ rows: [String]) -> String {
        rows.prefix(4).joined(separator: "\n")
    }

    if invalidConfiguration.isEmpty {
        recorder.pass("ui.runtime.invalid_configuration", "No SwiftUI invalid-configuration faults were logged during route evaluation.")
    } else {
        recorder.fail(
            "ui.runtime.invalid_configuration",
            "SwiftUI logged invalid UI configuration",
            compact(invalidConfiguration)
        )
    }
    if undeclaredTypes.isEmpty {
        recorder.pass("ui.runtime.exported_types", "No undeclared exported-type faults were logged during route evaluation.")
    } else {
        recorder.fail(
            "ui.runtime.exported_types",
            "App bundle is missing an exported type declaration",
            compact(undeclaredTypes)
        )
    }
    if mainThreadWork.isEmpty {
        recorder.pass("ui.runtime.main_thread", "No runtime main-thread responsiveness faults were logged during route evaluation.")
    } else if strict {
        recorder.fail(
            "ui.runtime.main_thread",
            "UI route performed blocking work on the main thread",
            compact(mainThreadWork)
        )
    } else {
        recorder.warn(
            "ui.runtime.main_thread",
            "UI route performed blocking work on the main thread",
            compact(mainThreadWork)
        )
    }
    if layoutRecursion.isEmpty {
        recorder.pass("ui.runtime.layout_recursion", "No AppKit layout-recursion warnings were logged during route evaluation.")
    } else {
        recorder.warn(
            "ui.runtime.layout_recursion",
            "AppKit reported layout recursion during route evaluation",
            compact(layoutRecursion)
        )
    }
}

@discardableResult
func requireUIAvailability(options: Options, accessibilityTrusted: Bool, recorder: Recorder) -> Bool {
    if options.skipUI {
        recorder.warn("ui.skipped", "UI eval skipped", "--no-ui was passed.")
        return false
    }
    guard accessibilityTrusted else {
        let detail = "Accessibility permission is not available to this runner, so User Mode could not inventory or click the installed app."
        // The UI walk is a proof step, not an advisory best effort.  `--no-ui`
        // is the one explicit opt-out; without it, an unavailable Accessibility
        // bridge must make the command fail so a skipped 36-route walk cannot
        // be mistaken for a successful UI gate.
        recorder.fail("ui.accessibility.trusted", "Accessibility permission missing", detail)
        return false
    }
    return true
}

func runUIEval(app: NSRunningApplication, dataRoot: URL, artifactDir: URL, options: Options, routes: [UIRoute], recorder: Recorder) {
    let accessibilityTrusted = options.forceAXUntrustedForTesting ? false : AXIsProcessTrusted()
    guard requireUIAvailability(options: options, accessibilityTrusted: accessibilityTrusted, recorder: recorder) else { return }
    let uiEvalStartedAt = Date()
    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 1.0)
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let initialScreenshot = artifactDir.appendingPathComponent("initial.png")
    screenshot(to: initialScreenshot)
    var initial = collectAppSnapshot(appElement: appElement)
    let accessibilityDeadline = Date().addingTimeInterval(5)
    while initial.isEmpty && Date() < accessibilityDeadline {
        Thread.sleep(forTimeInterval: 0.25)
        initial = collectAppSnapshot(appElement: appElement)
    }
    do {
        try writeJSON(initial, to: artifactDir.appendingPathComponent("ui-inventory-initial.json"))
    } catch {
        recorder.warn("ui.inventory.write", "Could not write UI inventory", error.localizedDescription)
    }
    let windowCount = initial.filter { $0.path.hasPrefix("window") && $0.path.split(separator: ".").count == 1 }.count
    let actionable = initial.filter {
        isVisibleSnapshot($0, in: initial)
            && !isHiddenHarnessSnapshot($0)
            && !isDescendantOfRole($0, role: "AXScrollBar", in: initial)
            && !isStandardWindowChrome($0)
            && (actionableRoles.contains($0.role) || $0.actions.contains(kAXPressAction))
    }
    if windowCount == 0 {
        recorder.fail("ui.windows.present", "No visible app windows found", "Accessibility inventory returned no NativeAgent windows.")
    } else {
        recorder.pass("ui.windows.present", "Accessibility inventory found \(windowCount) window(s).")
    }
    if actionable.isEmpty {
        recorder.fail("ui.action_inventory.non_empty", "No actionable UI controls found", "Accessibility inventory found zero buttons/toggles/links.")
    } else {
        recorder.pass("ui.action_inventory.non_empty", "Accessibility inventory found \(actionable.count) actionable control(s).")
    }
    let unlabeled = actionable.filter { effectiveVisibleLabel($0, in: initial).isEmpty }
    if !unlabeled.isEmpty {
        let detail = "Found \(unlabeled.count) unlabeled actionable control(s); first paths: \(unlabeled.prefix(8).map(\.path).joined(separator: ", "))"
        if options.strictUI {
            recorder.fail("ui.action_inventory.labels", "Some actionable controls have no accessible label", detail)
        } else {
            recorder.warn("ui.action_inventory.labels", "Some actionable controls have no accessible label", detail)
        }
    } else {
        recorder.pass("ui.action_inventory.labels", "All actionable controls in the current inventory have accessible labels.")
    }
    checkVisibleTextContradictions(allVisibleText(initial), context: "initial", recorder: recorder)

    let advancedRouteIDs = userModeAdvancedRouteIDs()
    for route in routes {
        // Global shortcuts belong to whichever app is frontmost. Reassert the
        // installed NativeAgent process for every independent route so an
        // unrelated app activation cannot turn a navigation proof into a
        // false pass or false failure (for example, Chrome consuming Cmd+4).
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.15)
        if advancedRouteIDs.contains(route.id) {
            ensureAdvancedExpanded(appElement: appElement)
        }
        var reachable = true
        for step in route.steps {
            let didRoute: Bool
            if let paletteQuery = step.paletteQuery {
                didRoute = selectCommandPaletteItem(app: app, appElement: appElement, query: paletteQuery)
            } else if let commandKey = step.commandKey {
                app.activate(options: [.activateAllWindows])
                Thread.sleep(forTimeInterval: 0.1)
                didRoute = sendShortcut(commandKey, modifiersScript: step.modifiersScript ?? "command down")
            } else {
                didRoute = pressFirst(appElement: appElement, labels: step.labels, sidebarOnly: step.sidebarOnly)
            }
            if didRoute {
                Thread.sleep(forTimeInterval: 0.7)
            } else {
                recorder.fail("ui.route.\(route.id).reachable", "Route step not found", "Could not route through \(step.labels.joined(separator: "/")) while routing to \(route.displayName).")
                reachable = false
                break
            }
        }
        guard reachable else { continue }
        Thread.sleep(forTimeInterval: 0.9)
        if route.id == "mac-assistant-watch-setup" {
            _ = revealDetailText("Assistant Watch Setup", appElement: appElement)
        }
        let snap = collectAppSnapshot(appElement: appElement)
        let path = artifactDir.appendingPathComponent("ui-inventory-\(route.id).json")
        try? writeJSON(snap, to: path)
        let routeActionable = snap.filter {
            isVisibleSnapshot($0, in: snap)
                && !isHiddenHarnessSnapshot($0)
                && !isDescendantOfRole($0, role: "AXScrollBar", in: snap)
                && !isStandardWindowChrome($0)
                && (actionableRoles.contains($0.role) || $0.actions.contains(kAXPressAction))
        }
        let routeUnlabeled = routeActionable.filter { effectiveVisibleLabel($0, in: snap).isEmpty }
        if routeUnlabeled.isEmpty {
            recorder.pass("ui.route.\(route.id).action_labels", "All \(routeActionable.count) actionable controls on \(route.displayName) have accessible labels.")
        } else {
            let detail = "\(route.displayName) has \(routeUnlabeled.count) unlabeled actionable control(s): \(routeUnlabeled.prefix(8).map(\.path).joined(separator: ", "))"
            if options.strictUI {
                recorder.fail("ui.route.\(route.id).action_labels", "Route has unlabeled actionable controls", detail)
            } else {
                recorder.warn("ui.route.\(route.id).action_labels", "Route has unlabeled actionable controls", detail)
            }
        }
        screenshot(to: artifactDir.appendingPathComponent("route-\(route.id).png"))
        let text = allVisibleText(snap)
        let detailText = detailVisibleText(snap)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recorder.fail("ui.route.\(route.id).non_empty", "Route rendered empty", "\(route.displayName) produced no accessible text.")
        } else {
            recorder.pass("ui.route.\(route.id).non_empty", "\(route.displayName) rendered \(text.count) accessible text characters.")
        }
        if detailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recorder.fail("ui.route.\(route.id).detail_non_empty", "Route detail rendered empty", "\(route.displayName) produced no visible detail text outside the sidebar.")
        } else {
            recorder.pass("ui.route.\(route.id).detail_non_empty", "\(route.displayName) rendered \(detailText.count) detail text characters.")
        }
        if !route.expectedDetailText.isEmpty {
            let lowerDetail = detailText.lowercased()
            let matched = route.expectedDetailText.contains { lowerDetail.contains($0.lowercased()) }
            if matched {
                recorder.pass("ui.route.\(route.id).expected_text", "\(route.displayName) detail matched expected text.")
            } else {
                recorder.fail(
                    "ui.route.\(route.id).expected_text",
                    "Route did not land on expected surface",
                    "\(route.displayName) detail did not contain any expected text: \(route.expectedDetailText.joined(separator: ", "))."
                )
            }
        }
        if !route.requiredDetailText.isEmpty {
            var missing: [String] = []
            for (index, required) in route.requiredDetailText.enumerated() {
                if revealDetailText(required, appElement: appElement) {
                    let evidence = collectAppSnapshot(appElement: appElement)
                    try? writeJSON(evidence, to: artifactDir.appendingPathComponent("ui-inventory-\(route.id)-required-\(index).json"))
                    screenshot(to: artifactDir.appendingPathComponent("route-\(route.id)-required-\(index).png"))
                } else {
                    missing.append(required)
                }
            }
            if missing.isEmpty {
                recorder.pass(
                    "ui.route.\(route.id).required_text",
                    "\(route.displayName) rendered every required setup detail."
                )
            } else {
                recorder.fail(
                    "ui.route.\(route.id).required_text",
                    "Route rendered incomplete setup inventory",
                    "\(route.displayName) is missing required visible detail: \(missing.joined(separator: ", "))."
                )
            }
        }
        checkVisibleTextContradictions(text, context: "route.\(route.id)", recorder: recorder)
    }

    let inboxURL = dataRoot
        .appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    let probeID = "user-mode-open-approvals-\(UUID().uuidString)"
    var didInstallProbe = false
    var inboxExistedBeforeProbe = false
    do {
        inboxExistedBeforeProbe = try installOpenApprovalsProbeCard(inboxURL: inboxURL, id: probeID)
        didInstallProbe = true
    } catch {
        recorder.fail(
            "ui.flow.inbox_open_approvals.fixture",
            "Could not install temporary Open Approvals probe",
            error.localizedDescription
        )
    }

    let openedInboxForApprovalAction = didInstallProbe
        && sendShortcut("i", modifiersScript: "{command down, shift down}")
    if openedInboxForApprovalAction {
        Thread.sleep(forTimeInterval: 1.0)
        // Approval-backlog notices live in the System lane, not the default
        // For you lane. Refresh through the real UI after adding our fixture.
        _ = pressExactButton(appElement: appElement, labels: ["Refresh inbox"])
        Thread.sleep(forTimeInterval: 0.4)
        _ = pressFirst(appElement: appElement, labels: ["System ("])
        Thread.sleep(forTimeInterval: 0.4)
        let inboxSnapshot = collectAppSnapshot(appElement: appElement)
        try? writeJSON(inboxSnapshot, to: artifactDir.appendingPathComponent("ui-inventory-flow-inbox-open-approvals-before.json"))
        if pressExactButton(appElement: appElement, labels: ["Open Approvals"]) {
            Thread.sleep(forTimeInterval: 1.2)
            let approvalsSnapshot = collectAppSnapshot(appElement: appElement)
            try? writeJSON(approvalsSnapshot, to: artifactDir.appendingPathComponent("ui-inventory-flow-inbox-open-approvals-after.json"))
            screenshot(to: artifactDir.appendingPathComponent("flow-inbox-open-approvals-after.png"))
            let approvalsDetail = detailVisibleText(approvalsSnapshot).lowercased()
            if approvalsDetail.contains("approvals include tool calls") {
                recorder.pass("ui.flow.inbox_open_approvals", "Inbox Open Approvals action landed on the Approvals detail view.")
            } else {
                recorder.fail(
                    "ui.flow.inbox_open_approvals",
                    "Inbox Open Approvals action did not navigate",
                    "Clicked Open Approvals from Inbox, but the detail did not show the Approvals page text."
                )
            }
        } else {
            recorder.fail(
                "ui.flow.inbox_open_approvals.clickable",
                "Inbox Open Approvals probe was not clickable",
                "User Mode installed a temporary approval-backlog Inbox card, but Accessibility could not press its Open Approvals control."
            )
        }
    } else {
        recorder.fail(
            "ui.flow.inbox_open_approvals.route",
            "Could not route to Inbox for Open Approvals flow",
            "User Mode could not open Activity > Inbox before testing the Open Approvals action."
        )
    }
    if didInstallProbe {
        do {
            try removeJSONLRow(
                url: inboxURL,
                id: probeID,
                fileExistedBeforeProbe: inboxExistedBeforeProbe
            )
        } catch {
            recorder.fail(
                "ui.flow.inbox_open_approvals.fixture_cleanup",
                "Could not remove temporary Open Approvals probe",
                error.localizedDescription
            )
        }
    }
    checkUIRuntimeIssues(
        since: uiEvalStartedAt,
        processName: app.localizedName ?? "NativeAgentApp",
        artifactDir: artifactDir,
        strict: options.strictUI,
        recorder: recorder
    )
}

let options = parseOptions()
let repo = options.repo.standardizedFileURL
let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
let artifactDir = (options.artifacts ?? repo
    .appendingPathComponent(".runtime", isDirectory: true)
    .appendingPathComponent("user-mode-eval", isDirectory: true)
    .appendingPathComponent(safeStamp(), isDirectory: true))
try fm.createDirectory(at: artifactDir, withIntermediateDirectories: true)

let recorder = Recorder()
let appURL = installedAppURL(repo: repo)
let bundleID = bundleIdentifier(appURL: appURL)
let includeNativeExperience = UserDefaults(suiteName: bundleID)?
    .bool(forKey: "nativeagent.experience.enabled") == true
let routes = userModeRoutes(includeNativeExperience: includeNativeExperience)

if options.processContractOnly {
    runProcessContract(recorder: recorder)
} else if options.visibilityContractOnly {
    runVisibilityContract(artifactDir: artifactDir, recorder: recorder)
} else if options.uiGateOnly {
    // Test this exact policy in a subprocess without launching an app or
    // touching its state. The normal path below still samples AX directly.
    let accessibilityTrusted = options.forceAXUntrustedForTesting ? false : AXIsProcessTrusted()
    _ = requireUIAvailability(options: options, accessibilityTrusted: accessibilityTrusted, recorder: recorder)
} else {
    if !fm.fileExists(atPath: appURL.path) {
        recorder.fail("installed_app.exists", "Installed app missing", "Expected app at \(appURL.path). Run ./script/install_app.sh first.")
    } else {
        recorder.pass("installed_app.exists", "Installed app found at \(appURL.path).")
    }

    checkRuntimeProcesses(recorder: recorder)
    checkDoctor(repo: repo, recorder: recorder)
    checkInbox(repo: repo, recorder: recorder)
    checkMemoryHygiene(repo: repo, recorder: recorder)
    checkScheduler(repo: repo, recorder: recorder)
    checkUserModeRouteCoverage(
        repo: repo,
        routes: routes,
        includeNativeExperience: includeNativeExperience,
        recorder: recorder
    )

    if fm.fileExists(atPath: appURL.path), let app = launchOrActivate(appURL: appURL, bundleID: bundleID, recorder: recorder) {
        runUIEval(app: app, dataRoot: dataRoot, artifactDir: artifactDir, options: options, routes: routes, recorder: recorder)
    }
}

let failCount = recorder.findings.filter { $0.severity == "fail" }.count
let warnCount = recorder.findings.filter { $0.severity == "warn" }.count
let passCount = recorder.scenarios.filter { $0.status == "pass" }.count
let report = Report(
    runAt: isoNow(),
    repo: repo.path,
    appPath: appURL.path,
    bundleIdentifier: bundleID,
    artifactDir: artifactDir.path,
    summary: ["pass": passCount, "warn": warnCount, "fail": failCount],
    scenarios: recorder.scenarios,
    findings: recorder.findings
)
try writeJSON(report, to: artifactDir.appendingPathComponent("report.json"))

var md = "# User Mode Eval\n\n"
md += "- Run: \(report.runAt)\n"
md += "- App: \(appURL.path)\n"
md += "- Artifacts: \(artifactDir.path)\n"
md += "- Summary: \(passCount) pass, \(warnCount) warn, \(failCount) fail\n\n"
if recorder.findings.isEmpty {
    md += "No findings.\n"
} else {
    for finding in recorder.findings {
        md += "## \(finding.severity.uppercased()) \(finding.id)\n\n"
        md += "\(finding.title)\n\n\(finding.detail)\n\n"
    }
}
try md.write(to: artifactDir.appendingPathComponent("findings.md"), atomically: true, encoding: .utf8)

print("User Mode Eval: \(passCount) pass, \(warnCount) warn, \(failCount) fail")
print("Artifacts: \(artifactDir.path)")
if !recorder.findings.isEmpty {
    for finding in recorder.findings {
        print("[\(finding.severity.uppercased())] \(finding.id): \(finding.title)")
    }
}

exit(failCount == 0 ? 0 : 1)
