import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
#if canImport(Darwin)
import Darwin
#endif
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
// Blueprint: | `MacChromiumAccessibility.swift` | Renderer identity and activation; descendant events wake async content judging; synchronous reads never sleep |
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
public final class MacChromiumAccessibilityState: Sendable {
    public static let shared = MacChromiumAccessibilityState()
    struct ProcessState: Sendable {
        let launch: Date
        var prepared = false
        var manualRequested = false
        var settling = false
        var settleAdmitted = false
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
            // Only the kernel's explicit no-process result retires another process's metadata.
            states = states.filter { kill($0.key, 0) == 0 || errno != ESRCH }
            states[pid] = state
        }
    }
    func evidence(pid: Int32) -> [String: JSONValue] {
        do {
            let launch = try macProcessStart(pid)
            return state(pid: pid, launch: launch).evidence
        } catch {
            return ["status": .string("unavailable"), "message": .string(error.localizedDescription)]
        }
    }
}
#if canImport(ApplicationServices) && os(macOS)
/// A process's identity across relaunches. Launch Services gives some apps no launchDate, so this reads the kernel's start time, which every process has.
private func macProcessStart(_ pid: Int32) throws -> Date {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else {
        let failure = errno
        throw MacAccessibilityReader.NativeReadFailure(detail:
            "Cannot read renderer process \(pid)'s kernel identity (errno \(failure): \(String(cString: strerror(failure)))). "
            + "Check that the app is running and restore process-table access before reading it again.")
    }
    guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
        throw MacAccessibilityReader.NativeReadFailure(detail:
            "Renderer process \(pid)'s kernel identity is missing or incomplete (\(size) bytes). Read the running app again before continuing.")
    }
    let start = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
}

/// Every descendant notification wakes the content judge; notifications themselves never establish readiness.
private final class MacRendererEvents: MacAXEffectObserverSource, MacAXEffectObservation, Sendable {
    private struct State: Sendable {
        var first: MacAXEffectNotification?
        var failure: Error?
        var notify: (@Sendable (MacAXEffectNotification) -> Void)?
        var stopped = false
    }
    private let state: OSAllocatedUnfairLock<State>
    private let source: MacAppSourceEvents?
    private let channel: Task<Void, Never>?
    private let pid: Int32
    let launch: Date
    let subscriptionFailure: String?
    var failure: Error? { state.withLock { $0.failure } }

    init(pid: Int32, context: MacOperationContext) throws {
        let launch = try macProcessStart(pid)
        self.pid = pid
        self.launch = launch
        let state = OSAllocatedUnfairLock(initialState: State())
        self.state = state
        let source: MacAppSourceEvents
        do {
            source = try MacAppSourceEvents(pid: pid, context: context) { kind in
                let notification = MacAXEffectNotification(kind: kind, at: Date())
                let notify: (@Sendable (MacAXEffectNotification) -> Void)? = state.withLock { state in
                    guard !state.stopped else { return nil }
                    if state.first == nil { state.first = notification }
                    return state.notify
                }
                notify?(notification)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // Activation may be what makes notifications available. Keep this settle's missing observation explicit.
            subscriptionFailure = (error as? SenseFailure)?.message ?? error.localizedDescription
            self.source = nil
            channel = nil
            return
        }
        subscriptionFailure = nil
        self.source = source
        channel = Task {
            do {
                // Descendant callbacks carry every wake before coalescing; this task handles channel closure, not readiness.
                for try await _ in source.stream { try Task.checkCancellation() }
                try Task.checkCancellation()
                throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer observation closed before preparation settled.")
            } catch {
                let notify: (@Sendable (MacAXEffectNotification) -> Void)? = state.withLock { state in
                    guard !state.stopped else { return nil }
                    state.failure = error
                    return state.notify
                }
                // Channel closure is a wake to inspect the failure, never an AX readiness event.
                notify?(.init(kind: "renderer_channel_closed", at: Date()))
            }
        }
    }

    func install(pid: Int32, kinds _: [String],
                 onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void) -> (any MacAXEffectObservation)? {
        guard pid == self.pid, source != nil else { return nil }
        let pending = state.withLock { state -> MacAXEffectNotification? in
            state.notify = onNotification
            if state.failure != nil { return MacAXEffectNotification(kind: "renderer_channel_closed", at: Date()) }
            return state.first
        }
        if let pending { onNotification(pending) }
        return self
    }

    func stop() {
        let stop = state.withLock { state in
            guard !state.stopped else { return false }
            state.stopped = true
            state.notify = nil
            return true
        }
        guard stop else { return }
        channel?.cancel()
        source?.cancel()
    }

    deinit { stop() }
}

extension SystemMacAXElementSource {

    /// Arm before activation; wait outside the AX lane so descendants can announce their first content.
    @concurrent package static func prepareRenderer(pid: Int32, context: MacOperationContext) async throws {
        guard context.observationMode != .passive else { return }
        try await context.holding(\.readDeadline, context.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds)) { context in
            var events: MacRendererEvents?
            defer { events?.stop() }
            let waiting = try rendererPreparation(pid: pid, refresh: true, context: context) {
                if events == nil { events = try MacRendererEvents(pid: pid, context: context.with(\.preparingRenderer, true)) }
            }
            guard waiting else { return }
            guard let events else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer preparation did not establish its observation state.")
            }
            let signals = MacWaitSignals(effects: events, activation: defaultMacAppActivationObserverSource(), pid: pid)
            defer { signals.stop() }
            var readFailure: Error?
            var contentReady = false
            let patience = min(2, min(context.readDeadline?.timeIntervalSinceNow ?? 2, context.wallDate?.timeIntervalSinceNow ?? 2))
            let end = await macSettle("renderer", signals: signals, patience: max(0, patience)) {
                if events.failure != nil { return true }
                do {
                    contentReady = try rendererContent(pid: pid, launch: events.launch, context: context)
                    return contentReady
                } catch {
                    readFailure = error
                    return true
                }
            }
            try Task.checkCancellation()
            if case .stopped = end { throw context.cancellationError }
            if let error = events.failure { throw error }
            if let readFailure { throw readFailure }
            let result: Result<Void, Error> = MacAXExecutionLane.sync {
                Result {
                    guard try macProcessStart(pid) == events.launch else {
                        throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer process changed during accessibility preparation.")
                    }
                    let owner = MacChromiumAccessibilityState.shared
                    var state = owner.state(pid: pid, launch: events.launch)
                    state.settling = false
                    state.settleAdmitted = true
                    state.prepared = true
                    let reason = contentReady ? "content" : "patience"
                    state.evidence["settle_ended_by"] = .string(reason)
                    if let failure = events.subscriptionFailure {
                        state.evidence["settle_observation"] = .object([
                            "status": .string("unavailable"), "message": .string(failure),
                            "waiting_for": .string("content_or_patience"),
                        ])
                    } else {
                        state.evidence["settle_observation"] = .object(["status": .string("installed")])
                    }
                    let observed = state.evidence["enhanced_readback"] == .bool(true) ? "enabled" : "tree_observed"
                    state.evidence["status"] = .string(reason == "patience" ? "settle_unobserved" : observed)
                    owner.store(pid: pid, state: state)
                }
            }
            try result.get()
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
            if try rendererPreparation(pid: pid, refresh: refresh, context: context) {
                throw MacAccessibilityReader.NativeReadFailure(detail: """
                    Renderer accessibility is still settling; no AX action was attempted. Prepare the app at its async entry before continuing.
                    """)
            }
        }
    }
    private static func rendererContent(pid: Int32, launch: Date, context: MacOperationContext) throws -> Bool {
        let result: Result<Bool, Error> = MacAXExecutionLane.sync {
            Result {
                guard try macProcessStart(pid) == launch else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer process changed during accessibility preparation.")
                }
                guard let deadline = context.readDeadline, Date() < deadline else { return false }
                return try rendererTopology(app: AXUIElementCreateApplication(pid), deadline: deadline).hasContent
            }
        }
        return try result.get()
    }
    private static func rendererPreparation(pid: Int32, refresh: Bool, context: MacOperationContext,
                                            beforeActivation: (() throws -> Void)? = nil) throws -> Bool {
        let result: Result<Bool, Error> = MacAXExecutionLane.sync {
            Result { try context.holding(\.preparingRenderer, true) { context in
                try Task.checkCancellation()
                guard !PersonOnlyWindows.isOwnProcess(pid), pid > 0 else { return false }
                guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer accessibility needs a live pid.")
                }
                // Built-in AT and system UI live under /System; non-regular helpers (including third-party background AT) are excluded.
                let executable = running.executableURL
                let systemNames: Set<String> = ["WindowServer", "loginwindow", "SystemUIServer", "Dock", "ControlCenter"]
                guard running.activationPolicy == .regular,
                      !systemNames.contains(executable?.lastPathComponent ?? ""),
                      running.bundleIdentifier?.hasPrefix("com.apple.VoiceOver") != true,
                      running.bundleIdentifier?.hasPrefix("com.apple.Accessibility") != true else { return false }
                guard let bundleURL = running.bundleURL else {
                    throw MacAccessibilityReader.NativeReadFailure(
                        detail: "Renderer accessibility needs the app's bundle location; system-app classification is unknown."
                    )
                }
                guard !bundleURL.standardizedFileURL.path.hasPrefix("/System/") else { return false }
                // System apps left above; a renderer app keys its state by its process start.
                let launch = try macProcessStart(pid)
                let owner = MacChromiumAccessibilityState.shared
                var state = owner.state(pid: pid, launch: launch)
                let deadline = context.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds)
                guard Date() < deadline else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Renderer accessibility preparation exhausted the reader time budget.")
                }
                if state.prepared && !refresh { return false }
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
                    guard try macProcessStart(pid) == launch else {
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
                    guard let raw, CFGetTypeID(raw) == CFBooleanGetTypeID(), let value = raw as? Bool else { return nil }
                    return value
                }
                let manual = try settable(.manualAccessibility)
                let enhanced = try settable(.enhancedUserInterface)
                if !manual && !enhanced {
                    state.prepared = true
                    state.evidence = ["status": .string("unsupported")]
                    owner.store(pid: pid, state: state)
                    return false
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
                var activated = false
                if manual, probe.empty == true, !state.manualRequested {
                    try beforeActivation?()
                    if try boolean(.manualAccessibility) != true {
                        _ = try enable(.manualAccessibility)
                        activated = true
                    }
                    state.manualRequested = true
                    state.settleAdmitted = false
                    state.settling = true
                }
                if enhanced, enhancedBefore == false || (probe.webArea && enhancedBefore != true) {
                    try beforeActivation?()
                    _ = try enable(.enhancedUserInterface)
                    activated = true
                    state.evidence["enhanced_readback"] = .bool(true)
                    state.settleAdmitted = false
                    state.settling = true
                }
                let after = activated ? try rendererTopology(app: app, deadline: deadline) : probe
                state.evidence["after"] = after.json
                if after.hasContent {
                    state.settleAdmitted = true
                    state.settling = false
                    state.evidence["settle_ended_by"] = .string("content")
                } else if !state.settleAdmitted {
                    try beforeActivation?()
                    state.settling = true
                }
                let observed = state.evidence["enhanced_readback"] == .bool(true) ? "enabled" : "tree_observed"
                let unobserved = !after.hasContent && state.evidence["settle_ended_by"] == .string("patience")
                state.evidence["status"] = .string(state.settling ? "settling" : unobserved ? "settle_unobserved" : observed)
                try checkIdentity()
                state.prepared = !state.settling
                owner.store(pid: pid, state: state)
                return state.settling
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
        var hasContent: Bool { webArea ? webContent : content }
        var empty: Bool? { complete ? !hasContent : nil }
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
