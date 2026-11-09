import Foundation
import CoreFoundation
import Synchronization
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
import Carbon
import NativeAgentShared
#endif
// Blueprint: | `SystemMacAXActSource.swift` | Dedicated AX thread and run loop; CF-equal identity, scoped gaps and target-pid Write/driver gates |
/// AX IPC and observer delivery share one serial thread, independently of the app's windows.
/// Synchronous clients enter only from non-main execution; async surface entries must suspend their actor before calling.
enum MacAXExecutionLane {
    /// The lane thread's run loop, published once; CFRunLoop perform/wake calls are thread-safe.
    private final class Loop: @unchecked Sendable {
        var loop: CFRunLoop?
    }

    nonisolated(unsafe) private static let lane: CFRunLoop = {
        let ready = DispatchSemaphore(value: 0)
        let published = Loop()
        let thread = Thread {
            published.loop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive even with no AX observers installed.
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            withExtendedLifetime(port) { CFRunLoopRun() }
        }
        thread.name = "com.nativeagent.mac-ax"
        thread.qualityOfService = .userInitiated
        thread.start()
        // The thread publishes its loop before signaling.
        ready.wait()
        return published.loop!
    }()

    /// One crossing of the lane: the borrowed closure in, the result out. The block clears the closure before it signals, so nothing
    /// holds the borrowed closure once the caller resumes, however long the run loop keeps the block itself.
    private final class Crossing<T>: @unchecked Sendable {
        var work: (() -> T)?
        var value: T?
    }

    static func sync<T>(_ body: () -> T) -> T {
        let loop = lane
        if CFEqual(CFRunLoopGetCurrent(), loop) { return body() }
        return withoutActuallyEscaping(body) { operation in
            let completed = DispatchSemaphore(value: 0)
            let crossing = Crossing<T>()
            crossing.work = operation
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
                autoreleasepool { crossing.value = crossing.work?() }
                crossing.work = nil
                completed.signal()
            }
            CFRunLoopWakeUp(loop)
            completed.wait()
            return crossing.value!
        }
    }

    /// Enqueue even on the lane so a burst of observer callbacks coalesces before its next tree read.
    static func async(_ body: @escaping @Sendable () -> Void) {
        let loop = lane
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { autoreleasepool(invoking: body) }
        CFRunLoopWakeUp(loop)
    }
}
#if canImport(ApplicationServices) && os(macOS)
package enum MacNativeActionFailure: Error, LocalizedError {
    case driver(String), selfTarget, renderer(String), evidence(String), appPermission(MacAppActRefusal)
    package var errorDescription: String? {
        switch self {
        case .driver(let detail): detail
        case .selfTarget: "NativeAgent does not act on its own app through Accessibility."
        case .renderer(let detail): detail
        case .evidence(let detail): detail
        case .appPermission(let refusal): refusal.message
        }
    }
}
/// Keep mutation handles scoped to dispatch or its retained sight, separately from the read owner.
public final class SystemMacAXActSource: MacAXActSource, @unchecked Sendable {
    let lock = NSLock()
    private var table: [Int: AXUIElement] = [:]
    private var nextID = 0
    /// The handle lock also guards this state.
    var lastRaiseDiagnostic: String?
    public init() {}
    /// Reuse CF-equal references so inventory and focus reads agree on window identity without growing duplicate handles.
    private func mint(_ element: AXUIElement) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let existing = table.first(where: { CFEqual($0.value, element) })?.key {
            return existing
        }
        nextID += 1
        table[nextID] = element
        return nextID
    }
    func element(_ handle: Int) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return table[handle]
    }
    public func isTrusted() -> Bool {
        MacAXExecutionLane.sync { AXIsProcessTrusted() }
    }
    public func resolve(path: [Int], inAppPid pid: Int32, context: MacOperationContext) -> MacAXPidResolution {
        MacAXExecutionLane.sync {
            do { return try MacAXAttributeRead.checked(context: context) { context in resolveOnExecutionLane(path: path, pid: pid, context: context) } }
            catch { return .unavailable(error.localizedDescription) }
        }
    }
    public func resolve(menuPath: [Int], inAppPid pid: Int32, titlePath: [String]?, context: MacOperationContext) -> MacAXPidResolution {
        MacAXExecutionLane.sync {
            do { return try MacAXAttributeRead.checked(context: context) { context in resolveMenuOnExecutionLane(path: menuPath, pid: pid, titlePath: titlePath,
                context: context) } }
            catch { return .unavailable(error.localizedDescription) }
        }
    }
    private func resolveMenuOnExecutionLane(path: [Int], pid: Int32, titlePath: [String]?, context: MacOperationContext) -> MacAXPidResolution {
        #if canImport(AppKit)
        // Person-only UI cannot supply an AX action target.
        guard !PersonOnlyWindows.isOwnProcess(pid) else { return .appGone }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return .appGone }
        let appElement = AXUIElementCreateApplication(pid)
        guard let current = MacAXAttributeRead.copyElement(appElement, kAXMenuBarAttribute, context: context) else { return .appGone }
        return resolveDescendant(path: path, from: current, titlePath: titlePath, context: context)
        #else
        return .appGone
        #endif
    }
    private func resolveOnExecutionLane(path: [Int], pid: Int32, context: MacOperationContext) -> MacAXPidResolution {
        #if canImport(AppKit)
        // Her body and window share the person-only boundary.
        guard !PersonOnlyWindows.isOwnProcess(pid) else { return .appGone }
        // Probe process existence directly: AX can construct dead-pid references whose failed reads cannot establish window absence.
        guard NSRunningApplication(processIdentifier: pid) != nil else { return .appGone }
        let appElement = AXUIElementCreateApplication(pid)
        guard let current = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute, context: context)
        else { return .appGone }
        return resolveDescendant(path: path, from: current, context: context)
        #else
        return .appGone
        #endif
    }
    /// Inventory every window so the caller can identify the observed one rather than whichever is focused.
    public func windows(pid: Int32, context: MacOperationContext) throws -> [MacAXWindowRef] {
        try MacAXExecutionLane.sync {
            Result { try MacAXAttributeRead.checked(context: context) { context in try windowsOnExecutionLane(pid: pid, context: context) } }
        }.get()
    }
    public func windowPresence(_ window: MacAXWindowRef, context: MacOperationContext) -> Bool? {
        MacAXExecutionLane.sync {
            let pid = window.identity.pid
            guard !PersonOnlyWindows.isOwnProcess(pid), let target = element(window.handle) else { return nil }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            let appElement = AXUIElementCreateApplication(pid)
            // Require a successful typed AXWindows read because an empty-on-error helper cannot prove absence.
            guard let raw = MacAXAttributeRead.copyRaw(appElement, kAXWindowsAttribute, context: context),
                  CFGetTypeID(raw) == CFArrayGetTypeID() else { return nil }
            let elements = raw as! CFArray as [AnyObject]
            guard elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            let listed = elements.map { $0 as! AXUIElement }
            let windows = MacAXWindowInventory.union(
                listed: listed,
                focused: MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute, context: context),
                main: MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute, context: context),
                equal: { CFEqual($0, $1) }
            )
            return windows.contains { CFEqual($0, target) }
        }
    }
    private func windowsOnExecutionLane(pid: Int32, context: MacOperationContext) throws -> [MacAXWindowRef] {
        #if canImport(AppKit)
        // Apply the same self-process fence as path resolution.
        guard !PersonOnlyWindows.isOwnProcess(pid) else { return [] }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        let windows = MacAXWindowInventory.union(
            listed: MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute, context: context),
            focused: MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute, context: context),
            main: MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute, context: context),
            equal: { CFEqual($0, $1) }
        )
        return try windows.enumerated().map { index, window in
            MacAXWindowRef(
                handle: mint(window),
                identity: try MacAXAttributeRead.copyWindowIdentity(window, pid: pid, index: index, context: context)
            )
        }
        #else
        return []
        #endif
    }
    public func focusedWindow(pid: Int32, context: MacOperationContext) -> MacAXWindowRef? {
        MacAXExecutionLane.sync {
            do { return try MacAXAttributeRead.checked(context: context) { context in try focusedWindowOnExecutionLane(pid: pid, context: context) } }
            catch { MacAXAttributeRead.failed(error, context: context); return nil }
        }
    }
    /// Focus and inventory must mint the same composite identity so callers compare complete window evidence rather than titles.
    private func focusedWindowOnExecutionLane(pid: Int32, context: MacOperationContext) throws -> MacAXWindowRef? {
        #if canImport(AppKit)
        // Apply the same self-process fence as path resolution.
        guard !PersonOnlyWindows.isOwnProcess(pid) else { return nil }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        guard let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute, context: context) else { return nil }
        // Use canonical inventory indices; Finder may omit focused sheets from AXWindows, and a guessed zero could identify their parent.
        let windows = MacAXWindowInventory.union(
            listed: MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute, context: context),
            focused: focused,
            main: MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute, context: context),
            equal: { CFEqual($0, $1) }
        )
        let index = windows.firstIndex(where: { CFEqual($0, focused) }) ?? 0
        return MacAXWindowRef(
            handle: mint(focused),
            identity: try MacAXAttributeRead.copyWindowIdentity(focused, pid: pid, index: index, context: context)
        )
        #else
        return nil
        #endif
    }
    public func resolve(path: [Int], inWindow window: MacAXWindowRef, context: MacOperationContext) -> MacAXPidResolution {
        MacAXExecutionLane.sync { resolveOnExecutionLane(path: path, inWindow: window, context: context) }
    }
    public func uniqueTarget(role: String, label: String, labelSource: String, inWindow window: MacAXWindowRef,
        context: MacOperationContext) throws -> MacAXActTarget? {
        // Read-only search uses ranged fetches and the caller's read deadline across the whole app.
        return try MacAccessibilityReader.withReadBudget(context: context) { context in
            guard !PersonOnlyWindows.isOwnProcess(window.identity.pid),
                  NSRunningApplication(processIdentifier: window.identity.pid) != nil,
                  let root = element(window.handle),
                  ["title", "value", "descendant_text"].contains(labelSource) else { return nil }
            // Match perception’s two-level, three-descendant caption bound for rows named only through children.
            func descendantText(_ node: AXUIElement) throws -> String? {
                var budget = 3
                func walk(_ node: AXUIElement, depth: Int) throws -> String? {
                    guard depth < 2 else { return nil }
                    for child in try MacAccessibilityReader.childElements(in: node, searching: "the marked control's caption", context: context) {
                        guard budget > 0 else { return nil }
                        budget -= 1
                        let childRole = MacAXAttributeRead.copyString(child, kAXRoleAttribute, context: context) ?? ""
                        let names = MacAXAttributeRead.copyLabel(child, role: childRole, context: context)
                        guard !names.unreadable else { return nil }
                        if let text = names.identity
                            ?? MacAXAttributeRead.copyRaw(child, kAXValueAttribute, context: context)
                                .flatMap(SystemMacAXElementSource.stringifiedValue) {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { return trimmed }
                        }
                        if let deeper = try walk(child, depth: depth + 1) { return deeper }
                    }
                    return nil
                }
                return try walk(node, depth: 0)
            }
            func search(_ root: AXUIElement) throws -> AXUIElement? {
                var match: AXUIElement?
                for current in try MacAccessibilityReader.elements(in: root, searching: "a unique marked control", context: context) {
                    try Task.checkCancellation()
                    guard MacAXAttributeRead.prepare(current, context: context),
                          let currentRole = MacAXAttributeRead.copyString(current, kAXRoleAttribute, context: context) else { return nil }
                    if currentRole == role {
                        let currentLabel: String?
                        if labelSource == "title" {
                            currentLabel = MacAXAttributeRead.copyLabel(current, role: currentRole, context: context).identity
                        } else if labelSource == "descendant_text" {
                            // Child captions name only controls without their own names, matching perception.
                            let names = MacAXAttributeRead.copyLabel(current, role: currentRole, context: context)
                            let own = names.identity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if !names.unreadable, own.isEmpty { currentLabel = try descendantText(current) }
                            else { currentLabel = nil }
                        } else {
                            currentLabel = MacAXAttributeRead.copyRaw(current, kAXValueAttribute, context: context)
                                .flatMap(SystemMacAXElementSource.stringifiedValue)?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if currentLabel == label {
                            guard match == nil else { return nil }
                            match = current
                        }
                    }
                }
                try Task.checkCancellation()
                guard context.readDeadline.map({ Date() < $0 }) == true else {
                    throw MacAccessibilityReader.NativeReadFailure(
                        detail: """
                            Accessibility search for a unique marked control exhausted the shared reader time budget. Read this control again before \
                            acting.
                            """)
                }
                return match
            }
            return try search(root).flatMap { describe($0, context: context) }
        }
    }
    private func resolveOnExecutionLane(path: [Int], inWindow window: MacAXWindowRef, context: MacOperationContext) -> MacAXPidResolution {
        #if canImport(AppKit)
        // A retained handle cannot bypass the person-only boundary.
        guard !PersonOnlyWindows.isOwnProcess(window.identity.pid) else { return .appGone }
        guard NSRunningApplication(processIdentifier: window.identity.pid) != nil else { return .appGone }
        // Retain the identity-matched window root; substituting focused or first windows would redirect the act.
        guard let current = element(window.handle) else { return .windowGone }
        return resolveDescendant(path: path, from: current, context: context)
        #else
        return .appGone
        #endif
    }
    // The caller validates the root on the AX lane; the shared walk cannot substitute another window or menu.
    private func resolveDescendant(path: [Int], from root: AXUIElement, titlePath: [String]? = nil, context: MacOperationContext) -> MacAXPidResolution {
        do { return try MacAXAttributeRead.checked(context: context) { context in resolveCheckedDescendant(path: path, from: root, titlePath: titlePath,
            context: context) } }
        catch { return .unavailable(error.localizedDescription) }
    }
    private func resolveCheckedDescendant(path: [Int], from root: AXUIElement, titlePath: [String]?, context: MacOperationContext) -> MacAXPidResolution {
        var current = root
        var titles: [String] = []
        var validAncestry = true
        for index in path {
            let children = MacAXAttributeRead.copyElementArray(current, kAXChildrenAttribute, context: context)
            guard index >= 0, index < children.count else { return .pathNotFound }
            current = children[index]
            if titlePath != nil {
                guard let hit = describe(current, context: context) else { validAncestry = false; continue }
                if ["AXMenuBarItem", "AXMenuItem"].contains(hit.role),
                   let title = MacMenuBar.cleanTitle(hit.title ?? hit.value) { titles.append(title) }
                else if hit.role != "AXMenu" { validAncestry = false }
            }
        }
        if let titlePath, !validAncestry || titles != titlePath { return .menuPathDrifted }
        guard let described = describe(current, context: context) else { return .pathNotFound }
        return .resolved(described)
    }
    public func perform(_ target: MacAXActTarget, action: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        MacAXExecutionLane.sync { performOnExecutionLane(target, action: action, turn: turn, context: context) }
    }
    /// Consume takeover continuation only after accepted AX writes; error status must retain protection.
    private func recordMutationStatus(_ status: AXError, turn: Turn) -> AXError {
        if status == .success { turn.macContinuation?.actionStarted() }
        return status
    }
    /// Exact-element clients share mutation ownership and driver authority, retaining the real AX status.
    package func performNative(_ element: AXUIElement, action: String, turn: Turn, context: MacOperationContext) -> Result<AXError, MacNativeActionFailure> {
        MacAXExecutionLane.sync {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
                return .failure(.evidence("The AX action target's process identity is unavailable; no action was attempted."))
            }
            guard !PersonOnlyWindows.isOwnProcess(pid) else { return .failure(.selfTarget) }
            // Scroll and raise actions support read/open intent rather than write admission.
            if !["AXScrollUpByPage", "AXScrollDownByPage", "AXScrollLeftByPage", "AXScrollRightByPage", "AXScrollToVisible", kAXRaiseAction].contains(action),
               let refusal = MacAppActGate.elementRefusal(element, context: context) {
                MacAppActGate.admit(refusal, context: context)
                return .failure(.appPermission(refusal))
            }
            guard context.driver?.allowsAction(context: context) == true else { return .failure(.driver(MacAttentionSessionStore.driverRefusal(
                context: context))) }
            do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true, context: context) }
            catch { return .failure(.renderer(error.localizedDescription)) }
            do {
                guard try MacAXAttributeRead.checkedEnabled(element, context: context) else {
                    return .failure(.evidence("The target is disabled. Read the app again before performing \(action)."))
                }
                guard try MacAXAttributeRead.copyActions(element, context: context).contains(action) else {
                    return .failure(.evidence("The target does not advertise \(action). Inspect this app's supported actions before continuing."))
                }
            } catch { return .failure(.evidence(error.localizedDescription)) }
            guard context.driver?.allowsAction(context: context) == true else { return .failure(.driver(MacAttentionSessionStore.driverRefusal(
                context: context))) }
            NativeAgentMotorEpoch.noteAgentMotorEvent()
            return .success(recordMutationStatus(AXUIElementPerformAction(element, action as CFString), turn: turn))
        }
    }
    package func setNativeAttribute(_ element: AXUIElement, attribute: String, value: CFTypeRef, turn: Turn, context: MacOperationContext) -> Result<AXError,
        MacNativeActionFailure> {
        MacAXExecutionLane.sync {
            if let refusal = MacAppActGate.elementRefusal(element, context: context) {
                MacAppActGate.admit(refusal, context: context)
                return .failure(.appPermission(refusal))
            }
            guard context.driver?.allowsAction(context: context) == true else { return .failure(.driver(MacAttentionSessionStore.driverRefusal(
                context: context))) }
            do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true, context: context) }
            catch { return .failure(.renderer(error.localizedDescription)) }
            guard context.driver?.allowsAction(context: context) == true else { return .failure(.driver(MacAttentionSessionStore.driverRefusal(
                context: context))) }
            NativeAgentMotorEpoch.noteAgentMotorEvent()
            return .success(recordMutationStatus(AXUIElementSetAttributeValue(element, attribute as CFString, value), turn: turn))
        }
    }
    private func actionOutcome(_ result: Result<AXError, MacNativeActionFailure>) -> MacAXActOutcome {
        switch result {
        case .success(.success): return .performed
        case .success(let status):
            return MacAXActOutcome(status: .failed, emissionAttempted: true,
                cause: "The native AX mutation returned \(status.rawValue); its effect is unknown.",
                nativeCode: Int(status.rawValue))
        case .failure(let failure):
            let remedy: JSONValue?
            if case .appPermission(let refusal) = failure { remedy = refusal.fields["remedy"] }
            else { remedy = nil }
            return MacAXActOutcome(status: .failed, emissionAttempted: false,
                cause: failure.localizedDescription, remedy: remedy)
        }
    }
    private func settableOutcome(_ element: AXUIElement, attribute: String, context: MacOperationContext) -> MacAXActOutcome? {
        guard context.driver?.allowsAction(context: context) == true else {
            return actionOutcome(.failure(.driver(MacAttentionSessionStore.driverRefusal(context: context))))
        }
        do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true, context: context) }
        catch { return actionOutcome(.failure(.renderer(error.localizedDescription))) }
        guard context.driver?.allowsAction(context: context) == true,
              MacAXAttributeRead.prepareMessage(element, context: context) else {
            return actionOutcome(.failure(.evidence("The AX settable probe was stopped or exhausted its read budget.")))
        }
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard status == .success else {
            return MacAXActOutcome(status: status == .attributeUnsupported ? .unsupported : .failed,
                emissionAttempted: false, cause: "Reading AX settable state for \(attribute) returned \(status.rawValue).",
                nativeCode: Int(status.rawValue))
        }
        return settable.boolValue ? nil : MacAXActOutcome(status: .unsupported, emissionAttempted: false,
            cause: "The target does not permit writing \(attribute).")
    }
    private func performOnExecutionLane(_ target: MacAXActTarget, action: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        guard let element = element(target.handle) else { return .invalidTarget }
        return actionOutcome(performNative(element, action: action, turn: turn, context: context))
    }
    public func setValue(_ target: MacAXActTarget, value: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        MacAXExecutionLane.sync { setValueOnExecutionLane(target, value: value, turn: turn, context: context) }
    }
    private func setValueOnExecutionLane(_ target: MacAXActTarget, value: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        guard let element = element(target.handle) else { return .invalidTarget }
        if let refusal = settableOutcome(element, attribute: kAXValueAttribute, context: context) { return refusal }
        return actionOutcome(setNativeAttribute(element, attribute: kAXValueAttribute, value: value as CFTypeRef, turn: turn, context: context))
    }
    public func setFocused(_ target: MacAXActTarget, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        MacAXExecutionLane.sync { setFocusedOnExecutionLane(target, turn: turn, context: context) }
    }
    public func menuShortcut(_ target: MacAXActTarget, context: MacOperationContext) -> (glyphs: String, chord: String)? {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle),
                  let char = MacAXAttributeRead.copyString(element, kAXMenuItemCmdCharAttribute, context: context)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  char.count == 1 else { return nil }
            var raw: CFTypeRef?
            var mods = 0
            if AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &raw) == .success,
               let number = raw as? NSNumber { mods = number.intValue }
            // AX menu modifier bits differ from ordinary event flags: Shift 1, Option 2, Control 4, no Command 8.
            var glyphs = "", chord: [String] = []
            if mods & 4 != 0 { glyphs += "⌃"; chord.append("ctrl") }
            if mods & 2 != 0 { glyphs += "⌥"; chord.append("option") }
            if mods & 1 != 0 { glyphs += "⇧"; chord.append("shift") }
            if mods & 8 == 0 { glyphs += "⌘"; chord.insert("cmd", at: 0) }
            guard !chord.isEmpty else { return nil }
            return (glyphs + char.uppercased(), (chord + [char.lowercased()]).joined(separator: "+"))
        }
    }
    public func isFocusedElement(_ target: MacAXActTarget, pid: Int32, context: MacOperationContext) -> Bool {
        MacAXExecutionLane.sync {
            guard !PersonOnlyWindows.isOwnProcess(pid), let element = element(target.handle) else { return false }
            guard let focused = MacAXAttributeRead.copyElement(
                AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute
            , context: context) else { return false }
            // Focus may sit on an inner input child, so bounded parent traversal can establish field ownership.
            var node = focused
            for _ in 0..<5 {
                if CFEqual(node, element) { return true }
                guard let parent = MacAXAttributeRead.copyElement(node, kAXParentAttribute, context: context) else { return false }
                node = parent
            }
            return false
        }
    }
    public func matchesTextInputTarget(_ focused: MacAXActTarget, target: MacAXActTarget, context: MacOperationContext) -> Bool {
        MacAXExecutionLane.sync {
            guard let focusedElement = element(focused.handle),
                  let targetElement = element(target.handle) else { return false }
            func isDescendant(_ child: AXUIElement, of ancestor: AXUIElement) -> Bool {
                var node = child
                // Match isFocusedElement's five-node bound, including the starting node.
                for _ in 1..<5 {
                    guard let parent = MacAXAttributeRead.copyElement(node, kAXParentAttribute, context: context) else { return false }
                    if CFEqual(parent, ancestor) { return true }
                    node = parent
                }
                return false
            }
            return CFEqual(focusedElement, targetElement)
                || isDescendant(focusedElement, of: targetElement)
                || isDescendant(targetElement, of: focusedElement)
        }
    }
    public func elementAtPosition(x: Double, y: Double, pid: Int32, context: MacOperationContext) -> MacAXActTarget? {
        MacAXExecutionLane.sync {
            guard pid > 0, !PersonOnlyWindows.isOwnProcess(pid), x.isFinite, y.isFinite else { return nil }
            guard (try? SystemMacAXElementSource.ensureRenderer(AXUIElementCreateApplication(pid), refresh: true, context: context)) != nil else { return nil }
            var target: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateApplication(pid), Float(x), Float(y), &target
            ) == .success, let target else { return nil }
            return describe(target, context: context)
        }
    }
    public func focusedElement(pid: Int32, context: MacOperationContext) -> MacAXActTarget? {
        MacAXExecutionLane.sync {
            guard !PersonOnlyWindows.isOwnProcess(pid),
                  let focused = MacAXAttributeRead.copyElement(
                    AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute
                  , context: context) else { return nil }
            return describe(focused, context: context)
        }
    }
    public func acceptsTextInput(_ target: MacAXActTarget, context: MacOperationContext) -> Bool {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle), let current = describe(element, reusing: target.handle, context: context),
                  current.enabled, !MacActClosedLoop.isSecureField(role: current.role) else { return false }
            if MacActClosedLoop.canType(role: current.role)
                || MacAXAttributeRead.copyBool(element, "AXEditable", context: context) == true { return true }
            // Canvas editors may expose a caret without exposing their text.
            if let raw = MacAXAttributeRead.copyRaw(element, kAXSelectedTextRangeAttribute, context: context),
               CFGetTypeID(raw) == AXValueGetTypeID() {
                let value = raw as! AXValue
                var range = CFRange()
                if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
                   range.location >= 0, range.length >= 0 { return true }
            }
            var settable: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
                && settable.boolValue
        }
    }
    public func textInput(_ target: MacAXActTarget, context: MacOperationContext) -> MacAXTextInput? {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle), let current = describe(element, reusing: target.handle, context: context),
                  current.enabled,
                  let rawValue = MacAXAttributeRead.copyRaw(element, kAXValueAttribute, context: context),
                  CFGetTypeID(rawValue) == CFStringGetTypeID(),
                  let raw = MacAXAttributeRead.copyRaw(element, kAXSelectedTextRangeAttribute, context: context),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            // Insertion readback needs exact empty values even though display projection omits empty strings.
            let value = rawValue as! CFString as String
            let axRange = raw as! AXValue
            var range = CFRange()
            guard AXValueGetType(axRange) == .cfRange,
                  AXValueGetValue(axRange, .cfRange, &range),
                  range.location >= 0, range.length >= 0,
                  range.location <= value.utf16.count,
                  range.length <= value.utf16.count - range.location else { return nil }
            return MacAXTextInput(target: current, value: value, selection: NSRange(location: range.location, length: range.length))
        }
    }
    public func url(of target: MacAXActTarget, context: MacOperationContext) throws -> URL? {
        try MacAXExecutionLane.sync {
            Result<URL?, Error> {
            guard let element = element(target.handle) else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "The directory control no longer resolves.")
            }
            guard let raw = try MacAXAttributeRead.checkedRaw(element, kAXURLAttribute, context: context) else { return nil }
            if CFGetTypeID(raw) == CFURLGetTypeID() {
                let url = raw as! CFURL as URL
                guard url.isFileURL else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "The directory control's AXURL is not a file URL.")
                }
                return url
            }
            if CFGetTypeID(raw) == CFStringGetTypeID(), let url = URL(string: raw as! CFString as String), url.isFileURL { return url }
            throw MacAccessibilityReader.NativeReadFailure(detail: "The directory control's AXURL is not a file URL.")
            }
        }.get()
    }
    public func setSelectedTextRange(_ target: MacAXActTarget, range: NSRange, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle) else { return .invalidTarget }
            if let refusal = settableOutcome(element, attribute: kAXSelectedTextRangeAttribute, context: context) { return refusal }
            var selection = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &selection) else {
                return MacAXActOutcome(status: .failed, emissionAttempted: false,
                    cause: "Could not construct the AX selection range.")
            }
            return actionOutcome(setNativeAttribute(element, attribute: kAXSelectedTextRangeAttribute, value: value, turn: turn, context: context))
        }
    }
    public func setSelectedText(_ target: MacAXActTarget, text: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle) else { return .invalidTarget }
            if let refusal = settableOutcome(element, attribute: kAXSelectedTextAttribute, context: context) { return refusal }
            return actionOutcome(setNativeAttribute(element, attribute: kAXSelectedTextAttribute, value: text as CFTypeRef, turn: turn, context: context))
        }
    }
    private func setFocusedOnExecutionLane(_ target: MacAXActTarget, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        guard let element = element(target.handle) else { return .invalidTarget }
        if let refusal = settableOutcome(element, attribute: kAXFocusedAttribute, context: context) { return refusal }
        return actionOutcome(setNativeAttribute(element, attribute: kAXFocusedAttribute, value: kCFBooleanTrue, turn: turn, context: context))
    }
    public func reread(_ target: MacAXActTarget, context: MacOperationContext) -> MacAXActTarget? {
        MacAXExecutionLane.sync { rereadOnExecutionLane(target, context: context) }
    }
    private func rereadOnExecutionLane(_ target: MacAXActTarget, context: MacOperationContext) -> MacAXActTarget? {
        guard let element = element(target.handle) else { return nil }
        return describe(element, reusing: target.handle, context: context)
    }
    // MARK: raw AX reads used to describe the target (nil-tolerant)
    private func describe(_ element: AXUIElement, reusing handle: Int? = nil, context: MacOperationContext) -> MacAXActTarget? {
        do { return try MacAXAttributeRead.checked(context: context) { context in describeChecked(element, reusing: handle, context: context) } }
        catch { MacAXAttributeRead.failed(error, context: context); return nil }
    }
    private func describeChecked(_ element: AXUIElement, reusing handle: Int?, context: MacOperationContext) -> MacAXActTarget? {
        do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true, context: context) }
        catch { nativeLog("AX target renderer preparation refused: %@", error.localizedDescription); return nil }
        let role: String, enabled: Bool, actions: [String]
        do {
            role = try MacAXAttributeRead.checkedText(element, kAXRoleAttribute, context: context)
            let observedEnabled = try MacAXAttributeRead.checkedEnabled(element, context: context)
            guard !role.isEmpty else {
                MacAXAttributeRead.failed(MacAccessibilityReader.NativeReadFailure(
                    detail: "AX target evidence unavailable: the role is missing. Read this control again before acting."), context: context)
                return nil
            }
            enabled = observedEnabled
            actions = try MacAXAttributeRead.copyActions(element, context: context)
        } catch { MacAXAttributeRead.failed(error, context: context); return nil }
        // Unreadable optional names, values or frames belong to this element’s gap, not a refusal of an otherwise validated act.
        return MacAXAttributeRead.collectingAttributeGaps(context: context) { _, context in MacAXActTarget(
            handle: handle ?? mint(element),
            role: role,
            // Share perception’s caption-name rule so separately labeled fields do not falsely drift.
            title: MacAXAttributeRead.copyLabel(element, role: role, context: context).identity,
            value: MacAXAttributeRead.copyRaw(element, kAXValueAttribute, context: context).flatMap {
                // Preserve complete AXValue, including empty editors, even when display projection omits it.
                if CFGetTypeID($0) == CFStringGetTypeID() { return $0 as! CFString as String }
                return SystemMacAXElementSource.stringifiedValue($0)
            },
            enabled: enabled,
            frame: MacAXAttributeRead.copyFrame(element, context: context),
            actions: actions
        ) }
    }
}
#endif
