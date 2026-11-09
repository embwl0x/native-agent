import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
import TrustCenter
import CoreGraphics
import UserNotifications
import Senses
import Experiences
import CryptoKit
import os
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `SystemMacAXElementSource.swift` | Scoped locked AX, snapshot focus and renderer-safe continuation; per-node gaps and complete secret evidence |
#if canImport(ApplicationServices) && os(macOS)
/// Reads emit no input; only active attribute reads prepare renderer modes. Scope live tables to dispatch and retained continuations, locking every AX
/// reference access under unchecked Sendable.
public final class SystemMacAXElementSource: MacAXElementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int: AXUIElement] = [:]
    private var nextID = 0
    private var messagingTimeouts: [Int32: Float] = [:]
    public init() {}
    /// AX timeouts belong to object instances, not process identities.
    func setMessagingTimeout(pid: Int32, seconds: Float) {
        MacAXExecutionLane.sync {
            guard !PersonOnlyWindows.isOwnProcess(pid) else { return }
            lock.lock()
            defer { lock.unlock() }
            messagingTimeouts[pid] = seconds == 0 ? nil : seconds
            for element in table.values {
                var owner: pid_t = 0
                if AXUIElementGetPid(element, &owner) == .success, owner == pid {
                    _ = AXUIElementSetMessagingTimeout(element, seconds)
                }
            }
        }
    }
    /// Temporary caption, parent and scrollbar references need the same timeout coverage.
    func prepareForRead(_ element: AXUIElement) -> AXUIElement {
        lock.lock()
        defer { lock.unlock() }
        guard !messagingTimeouts.isEmpty else { return element }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           let seconds = messagingTimeouts[pid] {
            _ = AXUIElementSetMessagingTimeout(element, seconds)
        }
        return element
    }
    private struct ContinuationAnchor: @unchecked Sendable {
        let launch: Date
        let window: AXUIElement
        let focus: AXUIElement
    }
    @concurrent func captureContinuation(pid: Int32?, taskReference: String, context: MacOperationContext) async -> MacWorkContinuation {
        guard isTrusted() else {
            return .unsupported("accessibility_permission_missing", taskReference: taskReference)
        }
        guard let pid, !PersonOnlyWindows.isOwnProcess(pid) else {
            return .unsupported("previous_app_unavailable", taskReference: taskReference)
        }
        do {
            // Capture app, window and focus before cold settling without preparing a renderer during identity reads.
            let anchor = try MacAXExecutionLane.sync {
                Result { try MacAccessibilityReader.withReadBudget(context: context) { context in
                    try context.holding(\.preparingRenderer, true) { context in
                        guard isTrusted(), let app = NSRunningApplication(processIdentifier: pid),
                              !app.isTerminated, let launch = app.launchDate else {
                            throw MacAccessibilityReader.NativeReadFailure(detail: "Previous app identity is unavailable.")
                        }
                        let application = AXUIElementCreateApplication(pid)
                        guard let window = MacAXAttributeRead.copyElement(application, kAXFocusedWindowAttribute, context: context),
                              let focus = MacAXAttributeRead.copyElement(application, kAXFocusedUIElementAttribute, context: context) else {
                            throw MacAccessibilityReader.NativeReadFailure(detail: "Previous window or focus identity is unavailable.")
                        }
                        return ContinuationAnchor(launch: launch, window: window, focus: focus)
                    }
                } }
            }.get()
            try await Self.prepareRenderer(pid: pid, context: context)
            return try MacAXExecutionLane.sync {
                Result { try MacAccessibilityReader.withReadBudget(context: context) { context in
                    capturePreparedContinuation(pid: pid, anchor: anchor, taskReference: taskReference, context: context)
                } }
            }.get()
        } catch {
            return .unsupported("continuation_capture_unavailable: \(error.localizedDescription)", taskReference: taskReference)
        }
    }
    private func retainReferences(_ refs: [MacAXElementRef]) {
        lock.lock(); defer { lock.unlock() }
        let ids = Set(refs.map(\.id))
        table = table.filter { ids.contains($0.key) }
    }
    private func capturePreparedContinuation(pid: Int32, anchor: ContinuationAnchor, taskReference: String,
        context: MacOperationContext) -> MacWorkContinuation {
        func unsupported(_ reason: String) -> MacWorkContinuation {
            .unsupported(reason, taskReference: taskReference)
        }
        guard isTrusted() else { return unsupported("accessibility_permission_missing") }
        guard !PersonOnlyWindows.isOwnProcess(pid), let app = appInfo(pid: pid) else {
            return unsupported("previous_app_unavailable")
        }
        // Saver or lock cover cannot anchor a continuation to an app the user was working in.
        guard app.bundleIdentifier != MacWakeGuard.loginWindowBundleID else {
            return unsupported("screen_covered")
        }
        guard let launchDate = NSRunningApplication(processIdentifier: pid)?.launchDate, launchDate == anchor.launch else {
            return unsupported("app_identity_unsupported")
        }
        let application = AXUIElementCreateApplication(pid)
        guard let rawWindow = MacAXAttributeRead.copyElement(application, kAXFocusedWindowAttribute, context: context), CFEqual(rawWindow, anchor.window),
              Self.isWindow(rawWindow, context: context) else { return unsupported("focused_window_unavailable") }
        let root = mint(rawWindow)
        let snapshot = MacAccessibilityReader.walk(source: self, root: root, limits: .deepPage, context: context)
        guard let attributes = snapshot.nodes.first?.attributes,
              let path = focusedElementPath(in: snapshot, relativeTo: root, context: context),
              let rawFocus = MacAXAttributeRead.copyElement(application, kAXFocusedUIElementAttribute, context: context), CFEqual(rawFocus, anchor.focus) else {
            return unsupported("focused_element_unavailable")
        }
        let capturedTitle = attributes.title
        guard app.name.count <= 256, (app.bundleIdentifier?.count ?? 0) <= 256,
              (capturedTitle?.count ?? 0) <= 1024 else { return unsupported("identity_over_budget") }
        let focused = mint(rawFocus)
        guard let range = MacAXAttributeRead.copyTextRange(rawFocus, context: context) else {
            return unsupported("selection_range_unsupported")
        }
        let document = MacAXAttributeRead.copyString(rawWindow, kAXDocumentAttribute, context: context)
        guard document == nil || document!.count <= 1024 else { return unsupported("document_identity_over_budget") }
        let percept = MacPerceptionCompiler.compile(snapshot: snapshot,
            secretContext: MacScreenViewTextRedaction.nodeSecretContext(snapshot.nodes), app: app,
            windowTitle: attributes.title, focusPath: path)
        guard let focus = percept.focus else { return unsupported("focused_element_outside_capture") }
        let identity = MacAXWindowIdentity(pid: pid, index: nil, role: attributes.role,
            subrole: attributes.subrole, title: attributes.title, frame: attributes.frame,
            attributeGaps: attributes.attributeGaps)
        let capturedAt = Date()
        let evidence: JSONValue = .object([
            "status": .string("captured"), "task_reference": .string(taskReference),
            "captured_at": .string(NativeTimestampFormat.plainZulu(capturedAt)),
            "app": app.toJSON(), "window": .object([
                "role": .string(identity.role),
                "title": identity.title.map { MacScreenViewTextRedaction.redactedLegendString($0, valueChars: 256) } ?? .null,
                "frame": identity.frame?.toJSON() ?? .null,
                "document": document.map { MacScreenViewTextRedaction.redactedLegendString($0, valueChars: 1024) } ?? .null,
            ]), "focus": focus.toJSON(), "selection_range": .object([
                "location": .int(Int64(range.location)), "length": .int(Int64(range.length)),
                "unit": .string("utf16"),
            ]),
        ])
        retainReferences([root, focused])
        return MacWorkContinuation(app: app, window: identity, focusPath: path,
            selectionRange: range, evidence: evidence, check: { [self] context in
                do {
                    return try MacAccessibilityReader.withReadBudget(context: context) { context in
                        MacAXExecutionLane.sync {
                            defer { retainReferences([root, focused]) }
                            guard Date().timeIntervalSince(capturedAt) <= MacLookFrameStore.ttlSeconds else { return "stale_capture" }
                            guard isTrusted(), appInfo(pid: pid) == app,
                                  NSRunningApplication(processIdentifier: pid)?.launchDate == launchDate else { return "stale_app" }
                            let application = AXUIElementCreateApplication(pid)
                            guard let liveWindow = MacAXAttributeRead.copyElement(application, kAXFocusedWindowAttribute, context: context),
                                  let originalWindow = element(root), CFEqual(liveWindow, originalWindow),
                                  MacAXAttributeRead.copyString(liveWindow, kAXDocumentAttribute, context: context) == document,
                                  MacAXAttributeRead.copyString(liveWindow, kAXTitleAttribute,
                                      context: context) == capturedTitle else { return "stale_window_or_document" }
                            guard let liveFocus = MacAXAttributeRead.copyElement(application, kAXFocusedUIElementAttribute, context: context),
                                  let originalFocus = element(focused), CFEqual(liveFocus, originalFocus),
                                  focusedElementPath(relativeTo: root, context: context) == path else { return "stale_focused_element" }
                            guard MacAXAttributeRead.copyTextRange(liveFocus, context: context) == range else { return "stale_selection_range" }
                            return nil
                        }
                    }
                } catch { return "continuation_validation_unavailable: \(error.localizedDescription)" }
            })
    }
    func mint(_ element: AXUIElement) -> MacAXElementRef {
        let element = prepareForRead(element)
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        table[nextID] = element
        return MacAXElementRef(id: nextID)
    }
    package func element(_ ref: MacAXElementRef) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return table[ref.id]
    }
    /// Accept actual window-like surfaces, including sheets and menus; application and menu-bar roots would spend the budget on menus.
    static func isWindow(_ element: AXUIElement, context: MacOperationContext) -> Bool {
        ["AXWindow", "AXSheet", "AXDrawer", "AXPopover", "AXDialog", "AXSystemDialog", "AXMenu"]
            .contains(MacAXAttributeRead.copyString(element, kAXRoleAttribute, context: context) ?? "")
    }
    public func elementHash(_ ref: MacAXElementRef) -> Int? {
        element(ref).map { Int(bitPattern: UInt(CFHash($0))) }
    }
    public func sameElement(_ lhs: MacAXElementRef, _ rhs: MacAXElementRef) -> Bool {
        guard let left = element(lhs), let right = element(rhs) else { return false }
        return CFEqual(left, right)
    }
    public func isTrusted() -> Bool {
        // Read trust without prompting; only the user may initiate the TCC grant.
        AXIsProcessTrusted()
    }
    package func nativeApplication(pid: Int32, context: MacOperationContext) -> AXUIElement? {
        guard !PersonOnlyWindows.isOwnProcess(pid), isTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard (try? Self.ensureRenderer(app, refresh: true, context: context)) != nil else { return nil }
        return app
    }
    /// Exact native inventory: a failed AXWindows read is never zero windows.
    package func nativeWindows(pid: Int32, context: MacOperationContext) throws -> [AXUIElement] {
        try MacAccessibilityReader.withReadBudget(context: context) { context in
            try Task.checkCancellation()
            let windows = nativeApplication(pid: pid, context: context).flatMap {
                MacAXAttributeRead.copyRaw($0, kAXWindowsAttribute, context: context) as? [AXUIElement]
            }
            try Task.checkCancellation()
            guard let windows else {
                throw MacAccessibilityReader.NativeReadFailure(
                    detail: "The app's AXWindows inventory could not be read. Check NativeAgent Accessibility access before continuing.")
            }
            return windows
        }
    }
    public func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32,
        context: MacOperationContext) -> Bool {
        guard frontmostApp()?.processIdentifier == pid,
              let current = frontmostWindowRoot(context: context), let currentElement = element(current),
              let original = element(window), CFEqual(currentElement, original),
              let target = element(container), attributes(of: container, context: context)?.frame == frame else { return false }
        // System-wide hits share the AX thread so cross-process reads never occupy the window's thread.
        var hit: AXUIElement? = MacAXExecutionLane.sync {
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(frame.x + frame.w / 2),
                Float(frame.y + frame.h / 2), &element
            ) == .success else { return nil }
            return element
        }
        guard hit != nil else { return false }
        // Same-pid sheets, popups and sibling regions still differ from the observed document.
        for _ in 0..<64 {
            guard let node = hit else { return false }
            _ = prepareForRead(node)
            if CFEqual(node, target) { return true }
            hit = MacAXAttributeRead.copyElement(node, kAXParentAttribute, context: context)
        }
        return false
    }
    public func frontmostApp() -> MacAXAppInfo? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return MacAXAppInfo(
            name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            isDockApp: app.activationPolicy == .regular
        )
        #else
        return nil
        #endif
    }
    public func frontmostWindowRoot(context: MacOperationContext) -> MacAXElementRef? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return windowRoot(pid: app.processIdentifier, context: context)
        #else
        return nil
        #endif
    }
    /// Accessory apps remain running after their last window closes; Dock membership is presentation metadata.
    public func runningApps() -> [MacAXAppInfo] {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && ($0.activationPolicy == .regular || $0.activationPolicy == .accessory) }
            .map { app in
                MacAXAppInfo(
                    name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    processIdentifier: app.processIdentifier,
                    isDockApp: app.activationPolicy == .regular
                )
            }
        #else
        return []
        #endif
    }
    /// Read the menu bar root only; MacMenuBar owns bounded descent.
    public func menuBarRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef? {
        #if canImport(AppKit)
        guard !PersonOnlyWindows.isOwnProcess(pid), isTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = MacAXAttributeRead.copyElement(app, kAXMenuBarAttribute, context: context) else { return nil }
        return mint(bar)
        #else
        return nil
        #endif
    }
    public func transientMenuRoots(pid: Int32, context: MacOperationContext) -> [MacAXElementRef] {
        guard !PersonOnlyWindows.isOwnProcess(pid), isTrusted(), frontmostApp()?.processIdentifier == pid else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var menus: [AXUIElement] = []
        func appendMenu(_ element: AXUIElement) {
            guard menus.count < MacTransientMenus.maxMenus,
                  MacAXAttributeRead.copyString(element, kAXRoleAttribute, context: context) == "AXMenu",
                  MacAXAttributeRead.copyBool(element, "AXHidden", context: context) != true,
                  let frame = MacAXAttributeRead.copyFrame(element, context: context), MacTransientMenus.validFrame(frame),
                  !menus.contains(where: { CFEqual($0, element) }) else { return }
            menus.append(element)
        }
        // Chromium may leave focus on the page while context menus sit beside ancestor groups, outside page-first descent.
        let nearby = MacTransientMenus.nearFocus(
            MacAXAttributeRead.copyElement(app, kAXFocusedUIElementAttribute, context: context),
            parent: { MacAXAttributeRead.copyElement($0, kAXParentAttribute, context: context) },
            children: { element, limit in
                guard MacAXAttributeRead.copyString(element, kAXRoleAttribute, context: context) != "AXMenuBar" else { return [] }
                return MacAXAttributeRead.copyElementArray(element, kAXChildrenAttribute, limit: limit, context: context)
            },
            isMenu: { MacAXAttributeRead.copyString($0, kAXRoleAttribute, context: context) == "AXMenu" },
            equal: { CFEqual($0, $1) }
        )
        for menu in nearby {
            appendMenu(menu)
        }
        // Application-level context menus need ranged reads so the whole app tree is not materialized.
        for attribute in [kAXChildrenAttribute, kAXWindowsAttribute] {
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(app, attribute as CFString, 0, 64, &values) == .success,
                  let children = values as? [AnyObject] else { continue }
            for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                appendMenu(child as! AXUIElement)
            }
        }
        return menus.map { mint($0) }
    }
    public func windowRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef? {
        #if canImport(AppKit)
        // Direct callers cannot read person-only UI.
        guard !PersonOnlyWindows.isOwnProcess(pid) else { return nil }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        let appElement = prepareForRead(AXUIElementCreateApplication(pid))
        // Require a window root; a non-window root can spend the walk budget on the menu bar.
        if let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute, context: context).map(prepareForRead),
           Self.isWindow(focused, context: context) {
            return mint(focused)
        }
        if let main = MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute, context: context).map(prepareForRead),
           Self.isWindow(main, context: context) {
            return mint(main)
        }
        if let first = MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute, context: context)
            .map(prepareForRead)
            .first(where: { Self.isWindow($0, context: context) }) {
            return mint(first)
        }
        return nil
        #else
        return nil
        #endif
    }
    /// Use AXWindows order, then union CF-equal focused/main references so omitted Finder sheets retain their identity without duplicates.
    public func windowRoots(pid: Int32, context: MacOperationContext) -> [MacAXWindowHandle] {
        #if canImport(AppKit)
        // Every window shares the process's person-only boundary.
        guard !PersonOnlyWindows.isOwnProcess(pid) else { return [] }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        let windows = MacAXWindowInventory.union(
            listed: MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute, context: context),
            focused: MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute, context: context),
            main: MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute, context: context),
            equal: { CFEqual($0, $1) }
        ).filter { Self.isWindow($0, context: context) }
        do {
            return try windows.enumerated().map { index, window in
                MacAXWindowHandle(ref: mint(window),
                    identity: try MacAXAttributeRead.copyWindowIdentity(window, pid: pid, index: index, context: context))
            }
        } catch { MacAXAttributeRead.failed(error, context: context); return [] }
        #else
        return []
        #endif
    }
    /// Named-process metadata must describe the root's pid, even when another app is frontmost.
    public func appInfo(pid: Int32) -> MacAXAppInfo? {
        #if canImport(AppKit)
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return MacAXAppInfo(
            name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: pid,
            isDockApp: app.activationPolicy == .regular
        )
        #else
        return nil
        #endif
    }
    /// Standalone callers use the same bounded observed topology as other reads.
    public func focusedElementPath(context: MacOperationContext) -> [Int]? {
        focusedElementPath(relativeTo: nil, context: context)
    }
    /// Focus paths belong to the already-walked root; a focus move to another window means no focus, not an old-tree path. Use the AX execution lane because
    /// live reads may re-enter the target app.
    public func focusedElementPath(relativeTo rootRef: MacAXElementRef?, context: MacOperationContext) -> [Int]? {
        MacAXExecutionLane.sync {
            do {
                return try MacAccessibilityReader.withReadBudget(context: context) { context in
                    guard let root = rootRef ?? frontmostWindowRoot(context: context) else { return nil }
                    let snapshot = MacAccessibilityReader.walk(source: self, root: root, limits: .deepPage,
                        read: { ref, context in try self.checkedTopologyAttributes(of: ref, context: context) }, context: context)
                    return focusedElementPath(in: snapshot, relativeTo: root, context: context)
                }
            } catch { MacAXAttributeRead.failed(error, context: context); return nil }
        }
    }
    public func focusedElementPath(in snapshot: MacAXTreeSnapshot, relativeTo rootRef: MacAXElementRef, context: MacOperationContext) -> [Int]? {
        MacAXExecutionLane.sync {
        #if canImport(AppKit)
        guard let root = element(rootRef) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(root, &pid) == .success else { return nil }
        guard !PersonOnlyWindows.isOwnProcess(pid) else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        guard let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedUIElementAttribute, context: context) else { return nil }
        return snapshot.nodes.first { node in
            node.element.flatMap { element($0) }.map { CFEqual($0, focused) } == true
        }?.path
        #else
        return nil
        #endif
        }
    }
    public func settableAttributes(of ref: MacAXElementRef, context: MacOperationContext) -> [String] {
        guard let element = element(ref) else { return [] }
        return [kAXValueAttribute, kAXFocusedAttribute, kAXSelectedAttribute].filter { attribute in
            guard MacAXAttributeRead.prepare(element, context: context) else { return false }
            defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
                && settable.boolValue
        }
    }
    public func attributes(of ref: MacAXElementRef, context: MacOperationContext) -> MacAXAttributes? {
        do { return try checkedAttributes(of: ref, context: context) }
        catch { MacAXAttributeRead.failed(error, context: context); return nil }
    }
    public func checkedAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        try MacAXAttributeRead.checked(context: context) { context in
            do { return try readAttributes(of: ref, context: context) }
            catch { MacAXAttributeRead.failed(error, context: context); throw error }
        }
    }
    private func readAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        guard let element = element(ref) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility element reference is unavailable.")
        }
        let role = try MacAXAttributeRead.checkedText(element, kAXRoleAttribute, context: context)
        guard !role.isEmpty else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "The element exposes no AXRole (unsupported or no value).")
        }
        return try MacAXAttributeRead.collectingAttributeGaps(context: context) { gaps, context in
            let actions = try MacAXAttributeRead.observationActions(element, context: context)
            let isHiddenMenuItem = hiddenMenuItem(element, role: role, context: context)
            let menuCommandKey: String? = role == "AXMenuItem" ? {
                let identifier = MacAXAttributeRead.copyString(element, kAXIdentifierAttribute, context: context) ?? ""
                let key = MacAXAttributeRead.copyString(element, kAXMenuItemCmdCharAttribute, context: context) ?? ""
                return identifier.isEmpty && key.isEmpty ? nil : identifier + "|" + key
            }() : nil
            let names = MacAXAttributeRead.copyLabel(element, role: role, context: context, prepare: prepareForRead)
            let rawValue = MacAXAttributeRead.copyRaw(element, kAXValueAttribute, context: context)
            let textValue = (rawValue as? String).flatMap { $0.isEmpty ? nil : $0 }
            let state = MacAXAttributeRead.valueState(rawValue, role: role)
            return MacAXAttributes(
                role: role,
                subrole: names.subrole,
                // Use the same separate-label naming rule as act-side drift checks.
                title: names.identity,
                // AXHeading numeric values are levels, not document text; preserve genuine strings only.
                value: role == "AXHeading" ? textValue : state == nil ? rawValue.flatMap(Self.stringifiedValue) : nil,
                enabled: MacAXAttributeRead.copyEnabled(element, context: context),
                selected: MacAXAttributeRead.copyBool(element, kAXSelectedAttribute, context: context),
                frame: names.frame,
                actions: actions.names,
                actionsUnreadable: actions.unreadable,
                placeholder: MacAXAttributeRead.placeholderRoles.contains(role)
                    ? names.placeholder : nil,
                selectionRange: MacAXAttributeRead.placeholderRoles.contains(role)
                    ? MacAXAttributeRead.copyTextRange(element, context: context) : nil,
                state: state,
                liveRegion: (role == "AXGroup" && (MacAXAttributeRead.copyString(element, "AXARIALive", context: context)
                    .map { $0 != "off" } ?? false))
                    || ["AXApplicationStatus", "AXApplicationAlert"].contains(
                        names.subrole ?? role),
                valueIsHelp: textValue.map { $0 == names.help } ?? false,
                titleIsHelp: names.identity != names.display,
                displayTitle: names.display,
                listSummary: MacAXAttributeRead.listSummary(element, role: role, context: context),
                isHiddenMenuItem: isHiddenMenuItem,
                menuCommandKey: menuCommandKey,
                attributeGaps: gaps.values,
                labelUnreadable: names.unreadable
            )
        }
    }
    /// Navigation reads traversal metadata without field values; hidden modifier alternates have one owner.
    package func topologyAttributes(of ref: MacAXElementRef, context: MacOperationContext) -> MacAXAttributes? {
        try? checkedTopologyAttributes(of: ref, context: context)
    }
    package func checkedTopologyAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        try MacAXAttributeRead.node(context: context) { context in try readTopologyAttributes(of: ref, context: context) }
    }
    private func readTopologyAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        guard let element = element(ref) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "The native AX element reference is unavailable.")
        }
        let role = try MacAXAttributeRead.checkedText(element, kAXRoleAttribute, context: context)
        guard !role.isEmpty else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "The element exposes no AXRole (unsupported or no value).")
        }
        return MacAXAttributes(role: role, subrole: MacAXAttributeRead.copyString(element, kAXSubroleAttribute, context: context),
            isHiddenMenuItem: hiddenMenuItem(element, role: role, context: context))
    }
    private func hiddenMenuItem(_ element: AXUIElement, role: String, context: MacOperationContext) -> Bool {
        guard role == "AXMenuItem" || role == "AXMenuBarItem" else { return false }
        // Modifier-only alternates bind to the corresponding unmodified item.
        let primary = role == "AXMenuItem"
            ? MacAXAttributeRead.copyElement(element, kAXMenuItemPrimaryUIElementAttribute, context: context) : nil
        return MacAXAttributeRead.copyBool(element, kAXHiddenAttribute, context: context) == true
            || primary.map { !CFEqual($0, element) } == true
    }
    public func maskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) -> MacAXAttributes? {
        do { return try checkedMaskingAttributes(of: ref, context: context) }
        catch { MacAXAttributeRead.failed(error, context: context); return nil }
    }
    public func checkedMaskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        try MacAXAttributeRead.checked(context: context) { context in
            do { return try readMaskingAttributes(of: ref, context: context) }
            catch {
                let failure = MacAccessibilityReader.NativeReadFailure(
                    detail: "Secret masking element \(ref.id): \(error.localizedDescription)")
                MacAXAttributeRead.failed(failure, context: context)
                throw failure
            }
        }
    }
    private func readMaskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        guard let element = element(ref) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility masking element reference is unavailable.")
        }
        let role = try MacAXAttributeRead.checkedText(element, kAXRoleAttribute, context: context)
        guard !role.isEmpty else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "The element exposes no AXRole (unsupported or no value).")
        }
        return try MacAXAttributeRead.collectingAttributeGaps(context: context) { gaps, context in
            let actions = try MacAXAttributeRead.observationActions(element, context: context)
            let names = MacAXAttributeRead.copyLabel(element, role: role, context: context, prepare: prepareForRead)
            // The shared value reader suppresses unknown text subroles; every other value failure still makes coverage incomplete.
            let rawValue = MacAXAttributeRead.copyRaw(element, kAXValueAttribute, context: context)
            // Failed caption or geometry reads leave secrecy unproven and must withhold pixels even when looks can report a gap.
            if let gap = gaps.entries.first(where: { $0.attribute != kAXSubroleAttribute }) {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Required secret-masking read failed: \(gap.detail)")
            }
            return MacAXAttributes(
                role: role,
                subrole: names.subrole,
                title: names.identity,
                // Apply the same typed-value rule as attributes(of:).
                value: role == "AXHeading" ? (rawValue as? String).flatMap { $0.isEmpty ? nil : $0 }
                    : MacAXAttributeRead.valueState(rawValue, role: role) == nil ? rawValue.flatMap(Self.stringifiedValue) : nil,
                enabled: MacAXAttributeRead.copyEnabled(element, context: context),
                frame: names.frame,
                actions: actions.names,
                actionsUnreadable: actions.unreadable,
                attributeGaps: gaps.values
            )
        }
    }
    public func children(of ref: MacAXElementRef, context: MacOperationContext) -> [MacAXElementRef] {
        guard let element = element(ref) else { return [] }
        return MacAXAttributeRead.copyElementArray(element, kAXChildrenAttribute, context: context).map { mint($0) }
    }
    public func childCount(of ref: MacAXElementRef, context: MacOperationContext) -> Int? {
        guard let element = element(ref) else { return nil }
        let attribute: String
        do { attribute = try MacAXAttributeRead.childAttribute(element, context: context) }
        catch { MacAXAttributeRead.failed(error, context: context); return nil }
        guard MacAXAttributeRead.prepare(element, context: context) else { return nil }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var count: CFIndex = 0
        let status = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
        switch status {
        case .success: return max(0, Int(count))
        case .attributeUnsupported, .noValue: return 0
        default:
            MacAXAttributeRead.failed(MacAccessibilityReader.NativeReadFailure(
                detail: "Accessibility \(attribute) count read failed (AX error \(status.rawValue))."), context: context)
            return nil
        }
    }
    public func checkedChildCount(of ref: MacAXElementRef, context: MacOperationContext) throws -> Int {
        try MacAXAttributeRead.checked(context: context) { context in
            guard let count = childCount(of: ref, context: context) else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child count is unavailable.")
            }
            return count
        }
    }
    public func liesWhollyOutside(_ ref: MacAXElementRef, bounds: MacAXFrame, context: MacOperationContext) -> Bool {
        guard let element = element(ref) else { return false }
        // Only a plain container can hold visible children beyond its own frame. An unreadable role or frame is no proof: the ordinary read reports it.
        return (try? MacAXAttributeRead.node(context: context) { context in
            let role = try MacAXAttributeRead.checkedText(element, kAXRoleAttribute, context: context)
            // A table's columns list the same cells its rows do, thousands of them in a long list; its rows already answer for them.
            if role == "AXColumn", let table = try MacAXAttributeRead.checkedRaw(element, kAXParentAttribute, context: context),
               CFGetTypeID(table) == AXUIElementGetTypeID() {
                var rows: CFIndex = 0
                if AXUIElementGetAttributeValueCount(table as! AXUIElement, kAXRowsAttribute as CFString, &rows) == .success, rows > 0 { return true }
            }
            guard !role.isEmpty, !Self.containerRoles.contains(role),
                  let frame = try MacAXAttributeRead.checkedFrame(element, context: context), frame.w > 0, frame.h > 0 else { return false }
            return frame.y + frame.h <= bounds.y || frame.y >= bounds.y + bounds.h || frame.x + frame.w <= bounds.x || frame.x >= bounds.x + bounds.w
        }) ?? false
    }
    private static let containerRoles: Set<String> = ["AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXTabGroup", "AXLayoutArea", "AXLayoutItem",
        "AXWebArea", "AXList", "AXTable", "AXOutline", "AXColumn", "AXSheet", "AXDrawer", "AXPopover", "AXUnknown"]
    public func checkedChildren(of ref: MacAXElementRef, limit: Int, context: MacOperationContext) throws -> [MacAXElementRef] {
        try MacAXAttributeRead.checked(context: context) { context in children(of: ref, limit: limit, context: context) }
    }
    public func children(of ref: MacAXElementRef, limit: Int, context: MacOperationContext) -> [MacAXElementRef] {
        guard limit > 0, let element = element(ref) else { return [] }
        return MacAXAttributeRead.copyElementArray(element, kAXChildrenAttribute, limit: limit, context: context).map { mint($0) }
    }
    /// Do not invent display text for unsupported AX value types.
    static func stringifiedValue(_ raw: CFTypeRef) -> String? {
        let typeID = CFGetTypeID(raw)
        if typeID == CFStringGetTypeID() {
            let string = raw as! CFString as String
            return string.isEmpty ? nil : string
        }
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean)) ? "true" : "false"
        }
        if typeID == CFNumberGetTypeID() {
            var double = 0.0
            guard CFNumberGetValue((raw as! CFNumber), .doubleType, &double) else { return nil }
            if double == double.rounded(), abs(double) < 1e15 {
                return String(Int64(double))
            }
            return String(double)
        }
        if typeID == AXValueGetTypeID() {
            let axValue = raw as! AXValue
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var point = CGPoint.zero
                guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
                return "(\(point.x), \(point.y))"
            case .cgSize:
                var size = CGSize.zero
                guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
                return "\(size.width)x\(size.height)"
            default:
                return nil
            }
        }
        return nil
    }
}
#endif
