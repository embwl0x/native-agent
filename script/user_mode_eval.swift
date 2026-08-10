#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

// User Mode Eval is intentionally black-box: it inspects the installed app,
// visible UI, and live app-owned state for user-observable contradictions.

struct Options {
    var repo: URL
    var artifacts: URL?
    var skipUI = false
    var strictUI = false
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
        UIRoute(id: "workshop", steps: [commandStep("4", labels: ["Workshop"])], displayName: "Workshop", expectedDetailText: ["The Workshop", "The bench is clear"]),
        UIRoute(id: "workshop-schedule", steps: [commandStep("4", labels: ["Workshop"]), axStep(["Schedule", "Scheduler"])], displayName: "Workshop > Schedule", expectedDetailText: ["Add Nightly Reflection", "Scheduler"]),
        UIRoute(id: "workshop-research", steps: [commandStep("4", labels: ["Workshop"]), axStep(["Research"])], displayName: "Workshop > Research", expectedDetailText: ["Research"]),
        UIRoute(id: "skills", steps: [appRouteStep("s", labels: ["Skills"])], displayName: "Skills & Tools > Skills", expectedDetailText: ["Skills & Tools", "Skills"]),
        UIRoute(id: "providers", steps: [commandStep("7", labels: ["Providers"])], displayName: "Providers", expectedDetailText: ["Providers", "Choose which LLM provider"]),
        UIRoute(id: "mac-integration", steps: [appRouteStep("m", labels: ["Mac Integration"])], displayName: "Mac Integration", expectedDetailText: ["Mac Integration", "System Permissions"]),
        UIRoute(id: "settings", steps: [commandStep("9", labels: ["Settings"])], displayName: "Settings", expectedDetailText: ["Settings"]),
        UIRoute(id: "personality", steps: [commandStep("5", labels: ["Personality"])], displayName: "Personality", expectedDetailText: ["Personality", "Custom mode"]),
        UIRoute(id: "connectors", steps: [appRouteStep("c", labels: ["Connectors"])], displayName: "Connectors", expectedDetailText: ["Connectors"]),
        UIRoute(id: "trust", steps: [commandStep("6", labels: ["Trust"])], displayName: "Trust", expectedDetailText: ["Trust", "Full Mac"]),
        UIRoute(id: "capabilities", steps: [appRouteStep("p", labels: ["Capabilities"])], displayName: "Capabilities", expectedDetailText: ["Capabilities", "Next-gen"]),
        UIRoute(id: "knowledge", steps: [commandStep("8", labels: ["Knowledge Graph"])], displayName: "Knowledge Graph", expectedDetailText: ["Knowledge Graph", "entities"]),
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
        "telegram", "tools"
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

func axStep(_ labels: [String]) -> UIRouteStep {
    UIRouteStep(labels: labels, commandKey: nil, modifiersScript: nil, paletteQuery: nil, sidebarOnly: false)
}

func sidebarStep(_ labels: [String]) -> UIRouteStep {
    UIRouteStep(labels: labels, commandKey: nil, modifiersScript: nil, paletteQuery: nil, sidebarOnly: true)
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
    return Options(repo: repo, artifacts: artifacts, skipUI: skipUI, strictUI: strictUI)
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

func appendOpenApprovalsProbeCard(inboxURL: URL, id: String) throws -> Data? {
    let original = try? Data(contentsOf: inboxURL)
    var text = original.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    if !text.isEmpty && !text.hasSuffix("\n") {
        text += "\n"
    }
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
    text += try jsonLine(row)
    text += "\n"
    try fm.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: inboxURL, atomically: true, encoding: .utf8)
    return original
}

func restoreFile(_ url: URL, original: Data?) {
    if let original {
        try? original.write(to: url, options: .atomic)
    } else {
        try? fm.removeItem(at: url)
    }
}

func string(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return ""
}

func int(_ value: Any?) -> Int? {
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String { return Int(s) }
    return nil
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
    do {
        try proc.run()
    } catch {
        return (-1, error.localizedDescription)
    }
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if proc.isRunning {
        proc.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if proc.isRunning { proc.interrupt() }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
    return windows
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
        collectAX(window, path: "window\(idx)", depth: 0, maxDepth: 9, budget: &budget, out: &out)
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
            if label == needle || label.contains(needle) {
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
    maxDepth: Int = 10,
    budget: inout Int,
    region: ((CGRect?) -> Bool)? = nil
) -> AXUIElement? {
    guard depth <= maxDepth, budget > 0 else { return nil }
    budget -= 1
    let role = axString(root, kAXRoleAttribute)
    let actions = axActions(root)
    let canSelect = selectableActions.contains(where: { actions.contains($0) })
    var matchBudget = 80
    if (actionableRoles.contains(role) || canSelect)
        && (region?(axFrame(root)) ?? true)
        && elementMatches(root, labels: labels, budget: &matchBudget) {
        return root
    }
    for child in axChildren(root) {
        if let found = findActionable(child, labels: labels, depth: depth + 1, maxDepth: maxDepth, budget: &budget, region: region) {
            return found
        }
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
    maxDepth: Int = 10,
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
    guard depth <= maxDepth, budget > 0 else { return nil }
    budget -= 1
    if axString(root, kAXRoleAttribute) == expectedRole {
        return root
    }
    for child in axChildren(root) {
        if let found = findFirstElement(
            child,
            role: expectedRole,
            depth: depth + 1,
            maxDepth: maxDepth,
            budget: &budget
        ) {
            return found
        }
    }
    return nil
}

func pressFirst(appElement: AXUIElement, labels: [String], sidebarOnly: Bool = false) -> Bool {
    var budget = 2_000
    let region: ((CGRect?) -> Bool)? = sidebarOnly ? sidebarRegion(appElement: appElement) : nil
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
    let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if err == .success { return true }
    if let frame = axFrame(element), isVisibleFrame(frame) {
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

func isVisibleSnapshot(_ snapshot: UISnapshot) -> Bool {
    guard let width = snapshot.width, let height = snapshot.height else { return false }
    return width > 1 && height > 1
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
        .filter { $0.path.hasPrefix(childPrefix) && isVisibleSnapshot($0) }
        .flatMap(visibleSnapshotTextParts)
        .first ?? ""
}

func allVisibleText(_ snapshots: [UISnapshot]) -> String {
    snapshots
        .filter(isVisibleSnapshot)
        .flatMap(visibleSnapshotTextParts)
        .joined(separator: "\n")
}

func detailVisibleText(_ snapshots: [UISnapshot]) -> String {
    let windowMinX = snapshots.first(where: { $0.path.hasPrefix("window") && !$0.path.contains(".") })?.x ?? 0
    let detailMinX = windowMinX + 265
    return snapshots
        .filter(isVisibleSnapshot)
        .filter { ($0.x ?? 0) >= detailMinX }
        .flatMap(visibleSnapshotTextParts)
        .joined(separator: "\n")
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
    guard let sheet = findFirstElement(appElement, role: kAXSheetRole, budget: &sheetBudget) else {
        return nil
    }
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

func checkRuntimeProcesses(recorder: Recorder) {
    let result = runProcess("/bin/ps", ["-axo", "pid,command"], timeout: 5)
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
    case "workshop": "workshop"
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

func runUIEval(app: NSRunningApplication, dataRoot: URL, artifactDir: URL, options: Options, routes: [UIRoute], recorder: Recorder) {
    if options.skipUI {
        recorder.warn("ui.skipped", "UI eval skipped", "--no-ui was passed.")
        return
    }
    guard AXIsProcessTrusted() else {
        let detail = "Accessibility permission is not available to this runner, so User Mode could not inventory or click the installed app."
        if options.strictUI {
            recorder.fail("ui.accessibility.trusted", "Accessibility permission missing", detail)
        } else {
            recorder.warn("ui.accessibility.trusted", "Accessibility permission missing", detail)
        }
        return
    }
    let uiEvalStartedAt = Date()
    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 1.0)
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let initialScreenshot = artifactDir.appendingPathComponent("initial.png")
    screenshot(to: initialScreenshot)
    let initial = collectAppSnapshot(appElement: appElement)
    do {
        try writeJSON(initial, to: artifactDir.appendingPathComponent("ui-inventory-initial.json"))
    } catch {
        recorder.warn("ui.inventory.write", "Could not write UI inventory", error.localizedDescription)
    }
    let windowCount = initial.filter { $0.path.hasPrefix("window") && $0.path.split(separator: ".").count == 1 }.count
    let actionable = initial.filter {
        isVisibleSnapshot($0)
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
        recorder.warn(
            "ui.action_inventory.labels",
            "Some actionable controls have no accessible label",
            "Found \(unlabeled.count) unlabeled actionable control(s); first paths: \(unlabeled.prefix(8).map(\.path).joined(separator: ", "))"
        )
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
        let snap = collectAppSnapshot(appElement: appElement)
        let path = artifactDir.appendingPathComponent("ui-inventory-\(route.id).json")
        try? writeJSON(snap, to: path)
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
        checkVisibleTextContradictions(text, context: "route.\(route.id)", recorder: recorder)
    }

    let inboxURL = dataRoot
        .appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    let probeID = "user-mode-open-approvals-\(UUID().uuidString)"
    var originalInboxData: Data?
    var didInstallProbe = false
    do {
        originalInboxData = try appendOpenApprovalsProbeCard(inboxURL: inboxURL, id: probeID)
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
        restoreFile(inboxURL, original: originalInboxData)
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
