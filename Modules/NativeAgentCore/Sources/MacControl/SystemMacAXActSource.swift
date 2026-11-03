import Foundation
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
// Blueprint: | `SystemMacAXActSource.swift` | Native AX execution lane and CF-equal handles; unique marked-target reads propagate evidence failures; performNative/setNativeAttribute read the actual element pid's integration Write switch before mutation; looking, driver authority and typed admission failures retain their identities |
/// AX mutations can synchronously invoke action handlers inside the target
/// application. SwiftUI/AppKit handlers are main-thread isolated, so issuing
/// `AXUIElementPerformAction` from a model/tool executor can crash the target
/// in `_dispatch_assert_queue_fail`. Keep the complete AX resolve/mutate/read
/// transaction on the host main lane.
enum MacAXExecutionLane {
    static func sync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        let binding = MacDriverContext.binding
        let background = MacDriverContext.background
        let continuation = MacWorkContinuation.current
        let readDeadline = MacAXLimits.readDeadline
        let observationMode = MacObservationMode.current
        let consentRoot = MacAppActGate.dataRoot
        let looking = MacAppActGate.looking
        let fullMacAdmitted = MacAppActGate.fullMacAdmitted
        #if canImport(ApplicationServices) && os(macOS)
        let evidence = MacAXAttributeRead.evidence
        #endif
        return withoutActuallyEscaping(body) { operation in
            // GCD sync completes this nonescaping operation before returning.
            nonisolated(unsafe) let synchronousOperation = operation
            return DispatchQueue.main.sync {
                MacDriverContext.$binding.withValue(binding) {
                    MacDriverContext.$background.withValue(background) {
                        MacWorkContinuation.$current.withValue(continuation) {
                            MacAXLimits.$readDeadline.withValue(readDeadline) {
                                MacObservationMode.$current.withValue(observationMode) {
                                    MacAppActGate.$dataRoot.withValue(consentRoot) {
                                        MacAppActGate.$fullMacAdmitted.withValue(fullMacAdmitted) {
                                            MacAppActGate.$looking.withValue(looking) {
                                                #if canImport(ApplicationServices) && os(macOS)
                                                MacAXAttributeRead.$evidence.withValue(evidence) { synchronousOperation() }
                                                #else
                                                synchronousOperation()
                                                #endif
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
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
/// Live AX resolution and mutation use a locked table owned by the dispatch or
/// its retained sight binding, separate from the read organ.
public final class SystemMacAXActSource: MacAXActSource, @unchecked Sendable {
    let lock = NSLock()
    private var table: [Int: AXUIElement] = [:]
    private var nextID = 0
    /// Guarded by `lock`, like the handle table.
    var lastRaiseDiagnostic: String?
    public init() {}
    /// Reuse a handle for CF-equal elements. Window inventory and focused-window
    /// reads can return separate AX references to the same window; their handles
    /// must compare equal, and repeated reads must not allocate duplicate entries.
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
    public func resolve(path: [Int], inAppPid pid: Int32) -> MacAXPidResolution {
        MacAXExecutionLane.sync {
            do { return try MacAXAttributeRead.checked { resolveOnExecutionLane(path: path, pid: pid) } }
            catch { return .unavailable(error.localizedDescription) }
        }
    }
    public func resolve(menuPath: [Int], inAppPid pid: Int32, titlePath: [String]?) -> MacAXPidResolution {
        MacAXExecutionLane.sync {
            do { return try MacAXAttributeRead.checked { resolveMenuOnExecutionLane(path: menuPath, pid: pid, titlePath: titlePath) } }
            catch { return .unavailable(error.localizedDescription) }
        }
    }
    private func resolveMenuOnExecutionLane(path: [Int], pid: Int32, titlePath: [String]?) -> MacAXPidResolution {
        #if canImport(AppKit)
        // The same self-process gate as every other resolve: an AX read of our
        // own tree re-enters AppKit in-process and can deadlock.
        guard pid != getpid() else { return .appGone }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return .appGone }
        let appElement = AXUIElementCreateApplication(pid)
        guard let current = MacAXAttributeRead.copyElement(appElement, kAXMenuBarAttribute) else { return .appGone }
        return resolveDescendant(path: path, from: current, titlePath: titlePath)
        #else
        return .appGone
        #endif
    }
    private func resolveOnExecutionLane(path: [Int], pid: Int32) -> MacAXPidResolution {
        #if canImport(AppKit)
        // Never resolve our own AX tree: synchronous in-process AppKit reads can deadlock the main lane.
        guard pid != getpid() else { return .appGone }
        // The process itself first: an AXUIElement for a dead pid is a perfectly
        // constructible object whose every read fails, so "the app is gone" has
        // to be asked directly rather than inferred from an empty window list.
        guard NSRunningApplication(processIdentifier: pid) != nil else { return .appGone }
        let appElement = AXUIElementCreateApplication(pid)
        guard let current = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute)
        else { return .appGone }
        return resolveDescendant(path: path, from: current)
        #else
        return .appGone
        #endif
    }
    /// Inventory every window so the caller can identify the observed one rather than whichever is focused.
    public func windows(pid: Int32) throws -> [MacAXWindowRef] {
        try MacAXExecutionLane.sync {
            Result { try MacAXAttributeRead.checked { try windowsOnExecutionLane(pid: pid) } }
        }.get()
    }
    public func windowPresence(_ window: MacAXWindowRef) -> Bool? {
        MacAXExecutionLane.sync {
            let pid = window.identity.pid
            guard pid != getpid(), let target = element(window.handle) else { return nil }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            let appElement = AXUIElementCreateApplication(pid)
            // copyElementArray intentionally collapses read failures to [].
            // Absence is proof here, so require a successful, typed AXWindows read.
            guard let raw = MacAXAttributeRead.copyRaw(appElement, kAXWindowsAttribute),
                  CFGetTypeID(raw) == CFArrayGetTypeID() else { return nil }
            let elements = raw as! CFArray as [AnyObject]
            guard elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            let listed = elements.map { $0 as! AXUIElement }
            let windows = MacAXWindowInventory.union(
                listed: listed,
                focused: MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute),
                main: MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute),
                equal: { CFEqual($0, $1) }
            )
            return windows.contains { CFEqual($0, target) }
        }
    }
    private func windowsOnExecutionLane(pid: Int32) throws -> [MacAXWindowRef] {
        #if canImport(AppKit)
        // Same self-process fence as `resolveOnExecutionLane(path:pid:)`.
        guard pid != getpid() else { return [] }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        let windows = MacAXWindowInventory.union(
            listed: MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute),
            focused: MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute),
            main: MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute),
            equal: { CFEqual($0, $1) }
        )
        return try windows.enumerated().map { index, window in
            MacAXWindowRef(
                handle: mint(window),
                identity: try MacAXAttributeRead.copyWindowIdentity(window, pid: pid, index: index)
            )
        }
        #else
        return []
        #endif
    }
    public func focusedWindow(pid: Int32) -> MacAXWindowRef? {
        MacAXExecutionLane.sync {
            do { return try MacAXAttributeRead.checked { try focusedWindowOnExecutionLane(pid: pid) } }
            catch { MacAXAttributeRead.failed(error); return nil }
        }
    }
    /// `AXFocusedWindow` of that app, carrying the SAME composite identity
    /// `windows(pid:)` mints, so the caller can compare it against the frame's
    /// recorded window with the ordinary matcher rather than by title alone.
    private func focusedWindowOnExecutionLane(pid: Int32) throws -> MacAXWindowRef? {
        #if canImport(AppKit)
        // Same self-process fence as `resolveOnExecutionLane(path:pid:)`.
        guard pid != getpid() else { return nil }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        guard let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute) else { return nil }
        // The INDEX must be the one this window carries in the same canonical
        // inventory as `windows(pid:)`. Finder can omit a focused AXSheet from
        // AXWindows; using the raw array would fabricate index 0 and can make
        // the sheet's identity drift into its document-window parent.
        let windows = MacAXWindowInventory.union(
            listed: MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute),
            focused: focused,
            main: MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute),
            equal: { CFEqual($0, $1) }
        )
        let index = windows.firstIndex(where: { CFEqual($0, focused) }) ?? 0
        return MacAXWindowRef(
            handle: mint(focused),
            identity: try MacAXAttributeRead.copyWindowIdentity(focused, pid: pid, index: index)
        )
        #else
        return nil
        #endif
    }
    public func resolve(path: [Int], inWindow window: MacAXWindowRef) -> MacAXPidResolution {
        MacAXExecutionLane.sync { resolveOnExecutionLane(path: path, inWindow: window) }
    }
    public func uniqueTarget(role: String, label: String, labelSource: String, inWindow window: MacAXWindowRef) throws -> MacAXActTarget? {
        // This is read-only resolution. Do not hold the main lane across an
        // app-wide search; use the common reader's ranged fetches and deadline.
        return try MacAccessibilityReader.withReadBudget {
            guard window.identity.pid != getpid(),
                  NSRunningApplication(processIdentifier: window.identity.pid) != nil,
                  let root = element(window.handle),
                  ["title", "value", "descendant_text"].contains(labelSource) else { return nil }
            // A source-list row names itself only through a child
            // (AXRow > AXCell > AXStaticText "Wi‑Fi"): the same two levels /
            // three descendants the view builder read to name the mark.
            func descendantText(_ node: AXUIElement) throws -> String? {
                var budget = 3
                func walk(_ node: AXUIElement, depth: Int) throws -> String? {
                    guard depth < 2 else { return nil }
                    for child in try MacAccessibilityReader.childElements(in: node, searching: "the marked control's caption") {
                        guard budget > 0 else { return nil }
                        budget -= 1
                        let childRole = MacAXAttributeRead.copyString(child, kAXRoleAttribute) ?? ""
                        let names = MacAXAttributeRead.copyLabel(child, role: childRole)
                        guard !names.unreadable else { return nil }
                        if let text = names.identity
                            ?? MacAXAttributeRead.copyRaw(child, kAXValueAttribute)
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
                for current in try MacAccessibilityReader.elements(in: root, searching: "a unique marked control") {
                    try Task.checkCancellation()
                    guard MacAXAttributeRead.prepare(current),
                          let currentRole = MacAXAttributeRead.copyString(current, kAXRoleAttribute) else { return nil }
                    if currentRole == role {
                        let currentLabel: String?
                        if labelSource == "title" {
                            currentLabel = MacAXAttributeRead.copyLabel(current, role: currentRole).identity
                        } else if labelSource == "descendant_text" {
                            // Only an element with no name of its own is named
                            // by its child, as the view builder did.
                            let names = MacAXAttributeRead.copyLabel(current, role: currentRole)
                            let own = names.identity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if !names.unreadable, own.isEmpty { currentLabel = try descendantText(current) }
                            else { currentLabel = nil }
                        } else {
                            currentLabel = MacAXAttributeRead.copyRaw(current, kAXValueAttribute)
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
                guard MacAXLimits.readDeadline.map({ Date() < $0 }) == true else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility search for a unique marked control exhausted the shared reader time budget. Read this control again before acting.")
                }
                return match
            }
            return try search(root).flatMap { describe($0) }
        }
    }
    private func resolveOnExecutionLane(path: [Int], inWindow window: MacAXWindowRef) -> MacAXPidResolution {
        #if canImport(AppKit)
        // Same self-process fence as `resolveOnExecutionLane(path:pid:)` — a
        // stale self window handle already minted in the table must not be
        // walkable either.
        guard window.identity.pid != getpid() else { return .appGone }
        guard NSRunningApplication(processIdentifier: window.identity.pid) != nil else { return .appGone }
        // The window element handle the identity match already picked. No
        // focused/main/first fallback here on purpose: falling back would put
        // the act back in whichever window is focused now, which is the bug.
        guard let current = element(window.handle) else { return .windowGone }
        return resolveDescendant(path: path, from: current)
        #else
        return .appGone
        #endif
    }
    // The caller selects and validates the root on the AX execution lane.
    // This shared walk never substitutes a different window or menu root.
    private func resolveDescendant(path: [Int], from root: AXUIElement, titlePath: [String]? = nil) -> MacAXPidResolution {
        do { return try MacAXAttributeRead.checked { resolveCheckedDescendant(path: path, from: root, titlePath: titlePath) } }
        catch { return .unavailable(error.localizedDescription) }
    }
    private func resolveCheckedDescendant(path: [Int], from root: AXUIElement, titlePath: [String]?) -> MacAXPidResolution {
        var current = root
        var titles: [String] = []
        var validAncestry = true
        for index in path {
            let children = MacAXAttributeRead.copyElementArray(current, kAXChildrenAttribute)
            guard index >= 0, index < children.count else { return .pathNotFound }
            current = children[index]
            if titlePath != nil {
                guard let hit = describe(current) else { validAncestry = false; continue }
                if ["AXMenuBarItem", "AXMenuItem"].contains(hit.role),
                   let title = MacMenuBar.cleanTitle(hit.title ?? hit.value) { titles.append(title) }
                else if hit.role != "AXMenu" { validAncestry = false }
            }
        }
        if let titlePath, !validAncestry || titles != titlePath { return .menuPathDrifted }
        guard let described = describe(current) else { return .pathNotFound }
        return .resolved(described)
    }
    public func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        MacAXExecutionLane.sync { performOnExecutionLane(target, action: action) }
    }
    /// Only a write the target accepted consumes a takeover continuation; an
    /// AX error leaves its protection in place (the posted-event sink is the
    /// one other consumer).
    private func recordMutationStatus(_ status: AXError) -> AXError {
        if status == .success { MacWorkContinuation.current?.actionStarted() }
        return status
    }
    /// Native clients already holding an exact element use the same mutation
    /// owner and driver authority as resolved actions, retaining the AX status.
    package func performNative(_ element: AXUIElement, action: String) -> Result<AXError, MacNativeActionFailure> {
        MacAXExecutionLane.sync {
            // Scroll actions and AXRaise support reading/opening an app.
            if !["AXScrollUpByPage", "AXScrollDownByPage", "AXScrollLeftByPage", "AXScrollRightByPage", "AXScrollToVisible", kAXRaiseAction].contains(action),
               let refusal = MacAppActGate.elementRefusal(element) {
                MacAppActGate.admit(refusal)
                return .failure(.appPermission(refusal))
            }
            guard MacDriverContext.binding?.allowsAction == true else { return .failure(.driver(MacAttentionSessionStore.driverRefusal)) }
            do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true) }
            catch { return .failure(.renderer(error.localizedDescription)) }
            do {
                guard try MacAXAttributeRead.checkedBool(element, kAXEnabledAttribute) == true else {
                    return .failure(.evidence("The target is disabled or has no readable AXEnabled state. Read the app again before performing \(action)."))
                }
                guard try MacAXAttributeRead.copyActions(element).contains(action) else {
                    return .failure(.evidence("The target does not advertise \(action). Inspect this app's supported actions before continuing."))
                }
            } catch { return .failure(.evidence(error.localizedDescription)) }
            guard MacDriverContext.binding?.allowsAction == true else { return .failure(.driver(MacAttentionSessionStore.driverRefusal)) }
            NativeAgentMotorEpoch.noteAgentMotorEvent()
            return .success(recordMutationStatus(AXUIElementPerformAction(element, action as CFString)))
        }
    }
    package func setNativeAttribute(_ element: AXUIElement, attribute: String, value: CFTypeRef) -> Result<AXError, MacNativeActionFailure> {
        MacAXExecutionLane.sync {
            if let refusal = MacAppActGate.elementRefusal(element) {
                MacAppActGate.admit(refusal)
                return .failure(.appPermission(refusal))
            }
            guard MacDriverContext.binding?.allowsAction == true else { return .failure(.driver(MacAttentionSessionStore.driverRefusal)) }
            do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true) }
            catch { return .failure(.renderer(error.localizedDescription)) }
            guard MacDriverContext.binding?.allowsAction == true else { return .failure(.driver(MacAttentionSessionStore.driverRefusal)) }
            NativeAgentMotorEpoch.noteAgentMotorEvent()
            return .success(recordMutationStatus(AXUIElementSetAttributeValue(element, attribute as CFString, value)))
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
    private func settableOutcome(_ element: AXUIElement, attribute: String) -> MacAXActOutcome? {
        guard MacDriverContext.binding?.allowsAction == true else {
            return actionOutcome(.failure(.driver(MacAttentionSessionStore.driverRefusal)))
        }
        do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true) }
        catch { return actionOutcome(.failure(.renderer(error.localizedDescription))) }
        guard MacDriverContext.binding?.allowsAction == true,
              MacAXAttributeRead.prepareMessage(element) else {
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
    private func performOnExecutionLane(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        guard let element = element(target.handle) else { return .invalidTarget }
        return actionOutcome(performNative(element, action: action))
    }
    public func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome {
        MacAXExecutionLane.sync { setValueOnExecutionLane(target, value: value) }
    }
    private func setValueOnExecutionLane(_ target: MacAXActTarget, value: String) -> MacAXActOutcome {
        guard let element = element(target.handle) else { return .invalidTarget }
        if let refusal = settableOutcome(element, attribute: kAXValueAttribute) { return refusal }
        return actionOutcome(setNativeAttribute(element, attribute: kAXValueAttribute, value: value as CFTypeRef))
    }
    public func setFocused(_ target: MacAXActTarget) -> MacAXActOutcome {
        MacAXExecutionLane.sync { setFocusedOnExecutionLane(target) }
    }
    public func menuShortcut(_ target: MacAXActTarget) -> (glyphs: String, chord: String)? {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle),
                  let char = MacAXAttributeRead.copyString(element, kAXMenuItemCmdCharAttribute)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  char.count == 1 else { return nil }
            var raw: CFTypeRef?
            var mods = 0
            if AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &raw) == .success,
               let number = raw as? NSNumber { mods = number.intValue }
            // kAXMenuItemModifier*: shift 1, option 2, control 4, no-command 8.
            var glyphs = "", chord: [String] = []
            if mods & 4 != 0 { glyphs += "⌃"; chord.append("ctrl") }
            if mods & 2 != 0 { glyphs += "⌥"; chord.append("option") }
            if mods & 1 != 0 { glyphs += "⇧"; chord.append("shift") }
            if mods & 8 == 0 { glyphs += "⌘"; chord.insert("cmd", at: 0) }
            guard !chord.isEmpty else { return nil }
            return (glyphs + char.uppercased(), (chord + [char.lowercased()]).joined(separator: "+"))
        }
    }
    public func isFocusedElement(_ target: MacAXActTarget, pid: Int32) -> Bool {
        MacAXExecutionLane.sync {
            guard pid != getpid(), let element = element(target.handle) else { return false }
            guard let focused = MacAXAttributeRead.copyElement(
                AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute
            ) else { return false }
            // A field's focus can sit on a child (a web combo's inner input):
            // a few parents up is still the field.
            var node = focused
            for _ in 0..<5 {
                if CFEqual(node, element) { return true }
                guard let parent = MacAXAttributeRead.copyElement(node, kAXParentAttribute) else { return false }
                node = parent
            }
            return false
        }
    }
    public func matchesTextInputTarget(_ focused: MacAXActTarget, target: MacAXActTarget) -> Bool {
        MacAXExecutionLane.sync {
            guard let focusedElement = element(focused.handle),
                  let targetElement = element(target.handle) else { return false }
            func isDescendant(_ child: AXUIElement, of ancestor: AXUIElement) -> Bool {
                var node = child
                // Match isFocusedElement's five-node bound, including the starting node.
                for _ in 1..<5 {
                    guard let parent = MacAXAttributeRead.copyElement(node, kAXParentAttribute) else { return false }
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
    public func elementAtPosition(x: Double, y: Double, pid: Int32) -> MacAXActTarget? {
        MacAXExecutionLane.sync {
            guard pid > 0, pid != getpid(), x.isFinite, y.isFinite else { return nil }
            guard (try? SystemMacAXElementSource.ensureRenderer(AXUIElementCreateApplication(pid), refresh: true)) != nil else { return nil }
            var target: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateApplication(pid), Float(x), Float(y), &target
            ) == .success, let target else { return nil }
            return describe(target)
        }
    }
    public func focusedElement(pid: Int32) -> MacAXActTarget? {
        MacAXExecutionLane.sync {
            guard pid != getpid(),
                  let focused = MacAXAttributeRead.copyElement(
                    AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute
                  ) else { return nil }
            return describe(focused)
        }
    }
    public func acceptsTextInput(_ target: MacAXActTarget) -> Bool {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle), let current = describe(element, reusing: target.handle),
                  current.enabled, !MacActClosedLoop.isSecureField(role: current.role) else { return false }
            if MacActClosedLoop.canType(role: current.role)
                || MacAXAttributeRead.copyBool(element, "AXEditable") == true { return true }
            // Canvas editors may expose a caret without exposing their text.
            if let raw = MacAXAttributeRead.copyRaw(element, kAXSelectedTextRangeAttribute),
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
    public func textInput(_ target: MacAXActTarget) -> MacAXTextInput? {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle), let current = describe(element, reusing: target.handle),
                  current.enabled,
                  let rawValue = MacAXAttributeRead.copyRaw(element, kAXValueAttribute),
                  CFGetTypeID(rawValue) == CFStringGetTypeID(),
                  let raw = MacAXAttributeRead.copyRaw(element, kAXSelectedTextRangeAttribute),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            // The display projection drops empty strings; an empty editor is
            // still ready and must keep its exact value for insertion readback.
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
    public func url(of target: MacAXActTarget) throws -> URL? {
        try MacAXExecutionLane.sync {
            Result<URL?, Error> {
            guard let element = element(target.handle) else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "The directory control no longer resolves.")
            }
            guard let raw = try MacAXAttributeRead.checkedRaw(element, kAXURLAttribute) else { return nil }
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
    public func setSelectedTextRange(_ target: MacAXActTarget, range: NSRange) -> MacAXActOutcome {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle) else { return .invalidTarget }
            if let refusal = settableOutcome(element, attribute: kAXSelectedTextRangeAttribute) { return refusal }
            var selection = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &selection) else {
                return MacAXActOutcome(status: .failed, emissionAttempted: false,
                    cause: "Could not construct the AX selection range.")
            }
            return actionOutcome(setNativeAttribute(element, attribute: kAXSelectedTextRangeAttribute, value: value))
        }
    }
    public func setSelectedText(_ target: MacAXActTarget, text: String) -> MacAXActOutcome {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle) else { return .invalidTarget }
            if let refusal = settableOutcome(element, attribute: kAXSelectedTextAttribute) { return refusal }
            return actionOutcome(setNativeAttribute(element, attribute: kAXSelectedTextAttribute, value: text as CFTypeRef))
        }
    }
    public func setSelected(_ target: MacAXActTarget) -> MacAXActOutcome {
        MacAXExecutionLane.sync {
            guard let element = element(target.handle) else { return .invalidTarget }
            if let refusal = settableOutcome(element, attribute: "AXSelected") { return refusal }
            return actionOutcome(setNativeAttribute(element, attribute: "AXSelected", value: kCFBooleanTrue))
        }
    }
    private func setFocusedOnExecutionLane(_ target: MacAXActTarget) -> MacAXActOutcome {
        guard let element = element(target.handle) else { return .invalidTarget }
        if let refusal = settableOutcome(element, attribute: kAXFocusedAttribute) { return refusal }
        return actionOutcome(setNativeAttribute(element, attribute: kAXFocusedAttribute, value: kCFBooleanTrue))
    }
    public func reread(_ target: MacAXActTarget) -> MacAXActTarget? {
        MacAXExecutionLane.sync { rereadOnExecutionLane(target) }
    }
    private func rereadOnExecutionLane(_ target: MacAXActTarget) -> MacAXActTarget? {
        guard let element = element(target.handle) else { return nil }
        return describe(element, reusing: target.handle)
    }
    // MARK: raw AX reads used to describe the target (nil-tolerant)
    private func describe(_ element: AXUIElement, reusing handle: Int? = nil) -> MacAXActTarget? {
        do { return try MacAXAttributeRead.checked { describeChecked(element, reusing: handle) } }
        catch { MacAXAttributeRead.failed(error); return nil }
    }
    private func describeChecked(_ element: AXUIElement, reusing handle: Int?) -> MacAXActTarget? {
        do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true) }
        catch { nativeLog("AX target renderer preparation refused: %@", error.localizedDescription); return nil }
        let role: String, enabled: Bool, actions: [String]
        do {
            role = try MacAXAttributeRead.checkedText(element, kAXRoleAttribute)
            guard !role.isEmpty, let observedEnabled = try MacAXAttributeRead.checkedBool(element, kAXEnabledAttribute) else {
                MacAXAttributeRead.failed(MacAccessibilityReader.NativeReadFailure(detail: "AX target evidence unavailable: role or AXEnabled is missing. Read this control again before acting."))
                return nil
            }
            enabled = observedEnabled
            actions = try MacAXAttributeRead.copyActions(element)
        } catch { MacAXAttributeRead.failed(error); return nil }
        // Optional name, value and frame are this element's own: one that
        // will not read is its gap, never a refusal of an act whose identity,
        // enabled state and actions did read.
        return MacAXAttributeRead.collectingAttributeGaps { _ in MacAXActTarget(
            handle: handle ?? mint(element),
            role: role,
            // Same name rule as perception, or a caption-named field ("Save
            // As") fails the drift guard as `handle_drifted` on every act.
            title: MacAXAttributeRead.copyLabel(element, role: role).identity,
            value: MacAXAttributeRead.copyRaw(element, kAXValueAttribute).flatMap {
                // Action readback preserves the complete AXValue, including an
                // empty string; the display projection may omit empty values.
                if CFGetTypeID($0) == CFStringGetTypeID() { return $0 as! CFString as String }
                return SystemMacAXElementSource.stringifiedValue($0)
            },
            enabled: enabled,
            frame: MacAXAttributeRead.copyFrame(element),
            actions: actions
        ) }
    }
}
#endif
