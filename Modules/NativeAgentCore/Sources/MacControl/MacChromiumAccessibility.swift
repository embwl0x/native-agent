import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
import os
import CoreGraphics
import UserNotifications
import Senses
import Experiences
import CryptoKit
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacChromiumAccessibility.swift` | Bundle-based renderer identity; shared bounded AX activation retains failures and passive authority |
/// Classification serves page presentation, never activation admission.
public enum MacChromiumAccessibility {
    /// An INACTIVITY window. Observed renderer nodes/text growth renews it without any total duration ceiling; AX notifications only trigger another read.
    static let rendererStallSeconds: TimeInterval = 6
    public enum Flag: String, CaseIterable, Sendable {
        case enhancedUserInterface = "AXEnhancedUserInterface"
        case manualAccessibility = "AXManualAccessibility"
    }
    /// Classify from the running bundle; a thin native tree alone cannot establish a renderer.
    public static func looksChromium(bundleId: String?, pid: Int32? = nil, snapshot: MacAXTreeSnapshot?) throws -> Bool {
        // Browser identity is available before Chromium builds any AXWebArea. Do not make renderer activation depend on the tree it activates or on browser
        // helper layout (which changes between distributions).
        if let bundleId, chromiumBrowserBundles.contains(bundleId) { return true }
        guard let pid else { return false }
        return try shipsChromium(pid: pid)
    }
    private static let chromiumBrowserBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.operasoftware.Opera", "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
    ]
    private static let shipsChromiumCache = OSAllocatedUnfairLock(initialState: [String: Bool]())
    /// The running process's own bundle carries a Chromium renderer helper: Electron and CEF apps beside their framework, Chrome-style apps inside it. Read
    /// from the process (two installs can share a bundle id) and scanned once per bundle path per launch.
    static func shipsChromium(pid: Int32) throws -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
            throw MacAccessibilityReader.NativeReadFailure(
                detail: "Renderer classification needs the running process's bundle identity. Read the app again before continuing."
            )
        }
        if let known = shipsChromiumCache.withLock({ $0[app.path] }) { return known }
        let files = FileManager.default
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        func children(_ directory: URL) throws -> [String] {
            do { return try files.contentsOfDirectory(atPath: directory.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
            catch {
                throw MacAccessibilityReader.NativeReadFailure(detail: """
                    Renderer bundle inspection failed at \(directory.path): \(error.localizedDescription). Restore read access to this app bundle and read it \
                    again.
                    """)
            }
        }
        let entries = try children(frameworks)
        let isRenderer = { (name: String) in name.hasSuffix("Renderer).app") }
        var found = false
        for name in entries {
            if name == "Electron Framework.framework" || name == "Chromium Embedded Framework.framework" || isRenderer(name) {
                found = true
                break
            }
            if name.hasSuffix(".framework") {
                let helpers = try children(frameworks.appendingPathComponent("\(name)/Versions/Current/Helpers"))
                if helpers.contains(where: isRenderer) { found = true; break }
            }
        }
        let detected = found
        shipsChromiumCache.withLock { $0[app.path] = detected }
        return detected
    }
    public static func hasWebArea(_ snapshot: MacAXTreeSnapshot?) -> Bool {
        snapshot?.nodes.contains { $0.attributes.role == "AXWebArea" } ?? false
    }
}
/// One process-state owner for source preparation, shared by readers and acts. Flags are never cleared on a target change: another AT may rely on them.
public final class MacChromiumAccessibilityState: @unchecked Sendable {
    public static let shared = MacChromiumAccessibilityState()
    struct ProcessState: Sendable {
        let launch: Date
        var prepared = false
        var manualRequested = false
        var settleUntil: Date?
        var enhancedSettled = false
        var evidence: [String: JSONValue] = [:]
    }
    private let processes = OSAllocatedUnfairLock(initialState: [Int32: ProcessState]())
    public init() {}
    func state(pid: Int32, launch: Date) -> ProcessState {
        processes.withLock { states in
            return states[pid].flatMap { $0.launch == launch ? $0 : nil } ?? ProcessState(launch: launch)
        }
    }
    func store(pid: Int32, state: ProcessState) {
        processes.withLock { states in
            // Metadata cleanup must not mutate a target app.
            states = states.filter { NSRunningApplication(processIdentifier: $0.key)?.launchDate == $0.value.launch }
            states[pid] = state
        }
    }
    func evidence(pid: Int32) -> [String: JSONValue] {
        guard let launch = NSRunningApplication(processIdentifier: pid)?.launchDate else { return [:] }
        return state(pid: pid, launch: launch).evidence
    }
}
#if canImport(ApplicationServices) && os(macOS)
extension SystemMacAXElementSource {

    /// Suspend cold preparation at async entries so the main execution lane stays free; synchronous clients retain bounded admission.
    package static func prepareRenderer(pid: Int32, context: MacOperationContext) async throws {
        guard context.observationMode != .passive else { return }
        try await context.holding(\.readDeadline, context.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds)) { context in
            while let until = try rendererPreparation(pid: pid, refresh: true, context: context) {
                try Task.checkCancellation()
                let remaining = until.timeIntervalSinceNow
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
        }
    }
    static func ensureRenderer(_ element: AXUIElement, refresh: Bool = false, context: MacOperationContext) throws {
        guard !context.preparingRenderer, context.observationMode != .passive else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer accessibility process identity is unreadable.")
        }
        // System-wide focus probes have pid 0 and no app mode to activate.
        guard pid > 0 else { return }
        try MacAccessibilityReader.withReadBudget(context: context) { context in
            while let until = try rendererPreparation(pid: pid, refresh: refresh, context: context) {
                try Task.checkCancellation()
                let remaining = until.timeIntervalSinceNow
                // No notification wait, no repeated provider or input workload. The fixed cold settle is charged to the caller's read deadline.
                if remaining > 0 {
                    guard !Thread.isMainThread else {
                        throw MacAccessibilityReader.NativeReadFailure(detail: """
                            Renderer accessibility is still settling. Read the app again after two seconds; no AX action was attempted. The main lane was not \
                            blocked.
                            """)
                    }
                    Thread.sleep(forTimeInterval: min(0.05, remaining))
                }
            }
        }
    }
    private static func rendererPreparation(pid: Int32, refresh: Bool, context: MacOperationContext) throws -> Date? {
        let result: Result<Date?, Error> = MacAXExecutionLane.sync {
            Result { try context.holding(\.preparingRenderer, true) { context in
                try Task.checkCancellation()
                guard pid != getpid(), pid > 0 else { return nil }
                guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer accessibility needs a live pid.")
                }
                // Built-in AT and system UI live under /System; non-regular helpers (including third-party background AT) are excluded.
                let executable = running.executableURL
                let systemNames: Set<String> = ["WindowServer", "loginwindow", "SystemUIServer", "Dock", "ControlCenter"]
                guard running.activationPolicy == .regular,
                      !systemNames.contains(executable?.lastPathComponent ?? ""),
                      running.bundleIdentifier?.hasPrefix("com.apple.VoiceOver") != true,
                      running.bundleIdentifier?.hasPrefix("com.apple.Accessibility") != true else { return nil }
                guard let bundleURL = running.bundleURL else {
                    throw MacAccessibilityReader.NativeReadFailure(
                        detail: "Renderer accessibility needs the app's bundle location; system-app classification is unknown."
                    )
                }
                guard !bundleURL.standardizedFileURL.path.hasPrefix("/System/") else { return nil }
                // System apps (Finder has no launch date) left above; a renderer app keys its state by launch.
                guard let launch = running.launchDate else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer accessibility needs the app's launch identity.")
                }
                let owner = MacChromiumAccessibilityState.shared
                var state = owner.state(pid: pid, launch: launch)
                let deadline = context.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds)
                guard Date() < deadline else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer accessibility preparation exhausted the reader time budget.")
                }
                if let until = state.settleUntil {
                    guard until < deadline else {
                        throw MacAccessibilityReader.NativeReadFailure(
                            detail: "Renderer accessibility is still settling; no AX action was attempted. Read again with a fresh budget."
                        )
                    }
                    if Date() < until { return until }
                    state.settleUntil = nil
                    state.enhancedSettled = true
                    state.prepared = false // verify Enhanced again after the debounce
                }
                if state.prepared && !refresh { return nil }
                let app = AXUIElementCreateApplication(pid)
                _ = AXUIElementSetMessagingTimeout(app, Float(min(0.25, deadline.timeIntervalSinceNow)))
                defer { _ = AXUIElementSetMessagingTimeout(app, 0) }
                func fail(_ detail: String) -> MacAccessibilityReader.NativeReadFailure {
                    state.prepared = false
                    state.evidence["status"] = .string("unconfirmed")
                    state.evidence["message"] = .string(detail)
                    owner.store(pid: pid, state: state)
                    nativeLog("Renderer AX preparation pid %d: %@", pid, detail)
                    return .init(detail: detail)
                }
                func checkIdentity() throws {
                    guard NSRunningApplication(processIdentifier: pid)?.launchDate == launch else {
                        throw fail("Renderer process changed during accessibility preparation; read the new process before acting.")
                    }
                    guard !Task.isCancelled, Date() < deadline else {
                        throw fail("Renderer accessibility preparation was interrupted or exhausted its reader time budget.")
                    }
                }
                func settable(_ flag: MacChromiumAccessibility.Flag) throws -> Bool {
                    try checkIdentity()
                    var value = DarwinBoolean(false)
                    let status = AXUIElementIsAttributeSettable(app, flag.rawValue as CFString, &value)
                    switch status {
                    case .success: return value.boolValue
                    case .attributeUnsupported, .noValue, .notImplemented: return false
                    default: throw fail("Renderer capability probe for \(flag.rawValue) is unreadable (AX error \(status.rawValue)).")
                    }
                }
                func boolean(_ flag: MacChromiumAccessibility.Flag) throws -> Bool? {
                    try checkIdentity()
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app, flag.rawValue as CFString, &raw)
                    guard status == .success else {
                        if status == .attributeUnsupported || status == .noValue { return nil }
                        throw fail("Renderer readback of \(flag.rawValue) is unreadable (AX error \(status.rawValue)).")
                    }
                    guard let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
                    return CFBooleanGetValue(raw as! CFBoolean)
                }
                let manual = try settable(.manualAccessibility)
                let enhanced = try settable(.enhancedUserInterface)
                if !manual && !enhanced {
                    state.prepared = true
                    state.evidence = ["status": .string("unsupported")]
                    owner.store(pid: pid, state: state)
                    return nil
                }
                // Probe topology only, not names, app families or field values. An unreadable/capped search is unknown, never empty.
                let probe = try rendererTopology(app: app, deadline: deadline)
                if state.evidence["before"] == nil { state.evidence["before"] = probe.json }
                state.evidence["after"] = probe.json
                state.evidence["pid"] = .int(Int64(pid))
                state.evidence["launch"] = .double(launch.timeIntervalSince1970)
                let enhancedBefore = enhanced ? try boolean(.enhancedUserInterface) : nil
                state.evidence["enhanced_readback"] = enhancedBefore.map(JSONValue.bool) ?? .null
                func enable(_ flag: MacChromiumAccessibility.Flag) throws -> Bool? {
                    try checkIdentity()
                    state.evidence["before"] = probe.json
                    let status = AXUIElementSetAttributeValue(app, flag.rawValue as CFString, kCFBooleanTrue)
                    let readback = try boolean(flag)
                    state.evidence[flag.rawValue] = .object([
                        "setter_ax_error": .int(Int64(status.rawValue)),
                        "readback": readback.map(JSONValue.bool) ?? .null,
                    ])
                    guard readback == true else {
                        // Electron Manual can apply yet read false. Report the contradiction and judge only the subsequent tree.
                        if flag == .manualAccessibility, status == .success {
                            state.evidence["manual_note"] = .string(
                                "Manual write accepted; Boolean readback is unconfirmed. Only the exposed tree proves content."
                            )
                            return readback
                        }
                        throw fail("""
                            \(flag.rawValue) activation is unconfirmed: setter AX error \(status.rawValue), readback \
                            \(readback.map(String.init) ?? "missing").
                            """)
                    }
                    return readback
                }
                if manual, probe.empty == true, !state.manualRequested {
                    if try boolean(.manualAccessibility) != true { _ = try enable(.manualAccessibility) }
                    state.manualRequested = true
                }
                if enhanced, enhancedBefore == false || (probe.webArea && enhancedBefore != true) {
                    // Reject too little budget BEFORE the write.
                    guard deadline.timeIntervalSinceNow > 2.1 else {
                        throw fail("""
                            Enhanced accessibility needs two seconds to settle; the remaining reader budget is too small. No Enhanced write was attempted.
                            """)
                    }
                    _ = try enable(.enhancedUserInterface)
                    state.evidence["enhanced_readback"] = .bool(true)
                    state.settleUntil = Date().addingTimeInterval(2)
                    state.evidence["status"] = .string("settling")
                    state.evidence["settle_seconds"] = .int(2)
                } else if enhancedBefore == true, !state.enhancedSettled {
                    guard deadline.timeIntervalSinceNow > 2.1 else {
                        throw fail("Enhanced accessibility was already on, but its settle could not fit in the remaining reader budget.")
                    }
                    state.settleUntil = Date().addingTimeInterval(2)
                    state.evidence["status"] = .string("settling")
                    state.evidence["settle_seconds"] = .int(2)
                } else {
                    state.evidence["status"] = .string(enhancedBefore == true ? "enabled" : "tree_observed")
                }
                try checkIdentity()
                state.prepared = true
                owner.store(pid: pid, state: state)
                return state.settleUntil
            } }
        }
        return try result.get()
    }
    private struct RendererTopology {
        var nodes = 0
        var roles: Set<String> = []
        var webArea = false
        var complete = true
        var content = false
        var webContent = false
        var empty: Bool? { complete ? !(webArea ? webContent : content) : nil }
        var json: JSONValue { .object([
            "elements": .int(Int64(nodes)), "roles": .array(roles.sorted().map(JSONValue.string)),
            "empty": empty.map(JSONValue.bool) ?? .null,
            "complete": .bool(complete),
        ]) }
    }
    private static func rendererTopology(app: AXUIElement, deadline: Date) throws -> RendererTopology {
        var result = RendererTopology(), queue: [(element: AXUIElement, inWeb: Bool)] = [(app, false)], visited: [AXUIElement] = []
        var at = 0
        while at < queue.count {
            guard !Task.isCancelled, Date() < deadline, at < 160 else { result.complete = false; break }
            let item = queue[at], element = item.element; at += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            _ = AXUIElementSetMessagingTimeout(element, Float(min(0.25, max(0.001, deadline.timeIntervalSinceNow))))
            defer { _ = AXUIElementSetMessagingTimeout(element, 0) }
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success,
                  let role = raw as? String else { result.complete = false; continue }
            result.nodes += 1; result.roles.insert(role)
            if role == "AXWebArea" { result.webArea = true }
            if !["AXApplication", "AXWindow", "AXGroup", "AXWebArea", "AXScrollArea", "AXMenuBar"].contains(role) {
                var subrole: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                if !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(subrole as? String ?? "") {
                    result.content = true
                    if item.inWeb { result.webContent = true }
                }
            }
            if role == "AXMenuBar" { continue }
            var count: CFIndex = 0
            let counted = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
            if counted == .attributeUnsupported || counted == .noValue { continue }
            guard counted == .success else { result.complete = false; continue }
            if count == 0 { continue }
            let limit = min(count, CFIndex(max(0, 160 - queue.count)))
            guard limit > 0 else { result.complete = false; continue }
            var children: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, limit, &children) == .success,
                  let children = children as? [AXUIElement], children.count == limit else { result.complete = false; continue }
            if count > limit { result.complete = false }
            queue.append(contentsOf: children.map { ($0, item.inWeb || role == "AXWebArea") })
        }
        return result
    }
}
#endif
