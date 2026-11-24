import CoreFoundation
import Foundation
import Synchronization
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApplicationServices
import AppKit
import DeskCore
import CoreGraphics
import UserNotifications
import SenseCore
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `SystemMacAXElementSource.swift` | Scoped locked AX, snapshot focus and renderer-safe continuation; per-node gaps and complete secret evidence |
public final class SystemMacAXElementSource: MacAXElementSource {
    private struct State {
        var messagingTimeouts: [Int32: Float] = [:]
        var table: [Int: MacAXNativeElementIdentity] = [:]
        var nextID = 0
    }
    private let state = Mutex(State())
    public init() {}
    /// AX timeouts belong to object instances, not process identities.
    func setMessagingTimeout(pid: Int32, seconds: Float) {
        MacAXExecutionLane.sync {
            guard !PersonOnlyWindows.isOwnProcess(pid) else { return }
            state.withLock { state in
                state.messagingTimeouts[pid] = seconds == 0 ? nil : seconds
                for reference in state.table.values {
                    let element = reference.element
                    var owner: pid_t = 0
                    if AXUIElementGetPid(element, &owner) == .success, owner == pid {
                        _ = AXUIElementSetMessagingTimeout(element, seconds)
                    }
                }
            }
        }
    }
    /// Temporary caption, parent and scrollbar references need the same timeout coverage.
    func prepareForRead(_ element: AXUIElement) -> AXUIElement {
        state.withLock { state in
            guard !state.messagingTimeouts.isEmpty else { return }
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success,
               let seconds = state.messagingTimeouts[pid] {
                _ = AXUIElementSetMessagingTimeout(element, seconds)
            }
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
        state.withLock { state in
            let ids = Set(refs.map(\.id))
            state.table = state.table.filter { ids.contains($0.key) }
        }
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
        return state.withLock { state in
            state.nextID += 1
            state.table[state.nextID] = MacAXNativeElementIdentity(element: element)
            return MacAXElementRef(id: state.nextID)
        }
    }
    package func element(_ ref: MacAXElementRef) -> AXUIElement? {
        state.withLock { $0.table[ref.id] }?.element
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
            guard unsafe AXUIElementCopyElementAtPosition(
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
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return MacAXAppInfo(
            name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            isDockApp: app.activationPolicy == .regular
        )
    }
    public func frontmostWindowRoot(context: MacOperationContext) -> MacAXElementRef? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return windowRoot(pid: app.processIdentifier, context: context)
    }
    /// Accessory apps remain running after their last window closes; Dock membership is presentation metadata.
    public func runningApps() -> [MacAXAppInfo] {
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
    }
    /// Read the menu bar root only; MacMenuBar owns bounded descent.
    public func menuBarRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef? {
        guard !PersonOnlyWindows.isOwnProcess(pid), isTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = MacAXAttributeRead.copyElement(app, kAXMenuBarAttribute, context: context) else { return nil }
        return mint(bar)
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
            guard unsafe AXUIElementCopyAttributeValues(app, attribute as CFString, 0, 64, &values) == .success,
                  let children = values as? [AnyObject] else { continue }
            for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                appendMenu(child as! AXUIElement)
            }
        }
        return menus.map { mint($0) }
    }
    public func windowRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef? {
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
    }
    /// Use AXWindows order, then union CF-equal focused/main references so omitted Finder sheets retain their identity without duplicates.
    public func windowRoots(pid: Int32, context: MacOperationContext) -> [MacAXWindowHandle] {
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
    }
    /// Named-process metadata must describe the root's pid, even when another app is frontmost.
    public func appInfo(pid: Int32) -> MacAXAppInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return MacAXAppInfo(
            name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: pid,
            isDockApp: app.activationPolicy == .regular
        )
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
        guard let root = element(rootRef) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(root, &pid) == .success else { return nil }
        guard !PersonOnlyWindows.isOwnProcess(pid) else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        guard let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedUIElementAttribute, context: context) else { return nil }
        return snapshot.nodes.first { node in
            node.element.flatMap { element($0) }.map { CFEqual($0, focused) } == true
        }?.path
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
    private func readAttributes(of ref: MacAXElementRef, masking: Bool = false, context: MacOperationContext) throws -> MacAXAttributes {
        guard let element = element(ref) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility element reference is unavailable.")
        }
        return try MacAXAttributeRead.collectingAttributeGaps(context: context) { gaps, context in
            // One message carries everything the element's own read needs; a slot is only judged (and only records a gap) when read below.
            let keys = [kAXRoleAttribute, kAXEnabledAttribute] + MacAXAttributeRead.labelAttributes
                + [kAXValueAttribute] + (masking ? [] : [kAXSelectedAttribute, kAXSelectedTextRangeAttribute, "AXARIALive",
                    kAXIdentifierAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXHiddenAttribute, kAXMenuItemPrimaryUIElementAttribute])
            let metadata = try MacAXAttributeRead.checkedBatch(element, keys, context: context, gaps: gaps)
            guard let role = try MacAXAttributeRead.string(metadata[kAXRoleAttribute], attribute: kAXRoleAttribute) else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "The element exposes no AXRole (unsupported or no value).")
            }
            let names = try MacAXAttributeRead.readLabel(element, role: role, values: metadata, context: context, prepare: prepareForRead)
            let needsRange = !masking && MacAXAttributeRead.placeholderRoles.contains(role)
            // A text value whose subrole went unread is never used: it could be a secure field's.
            let rawValue = try MacAXAttributeRead.valueReadable(role: role, context: context) ? metadata[kAXValueAttribute] : nil
            let content = metadata
            let liveSetting = try !masking && role == "AXGroup" ? MacAXAttributeRead.string(metadata["AXARIALive"], attribute: "AXARIALive") : nil
            let textValue = (rawValue as? String).flatMap { $0.isEmpty ? nil : $0 }
            let state = MacAXAttributeRead.valueState(rawValue, role: role)
            let value = role == "AXHeading" ? textValue : state == nil ? rawValue.flatMap(Self.stringifiedValue) : nil
            let enabled = try MacAXAttributeRead.boolean(metadata[kAXEnabledAttribute], attribute: kAXEnabledAttribute)
            let actions = try MacAXAttributeRead.observationActions(element, context: context)
            if masking {
                return MacAXAttributes(role: role, subrole: names.subrole, title: names.identity, value: value, enabled: enabled, frame: names.frame,
                                       actions: actions.names, actionsUnreadable: actions.unreadable, attributeGaps: gaps.values)
            }
            let isHiddenMenuItem = try hiddenMenuItem(element, role: role, metadata: metadata)
            let menuCommandKey: String? = try role == "AXMenuItem" ? {
                let identifier = try MacAXAttributeRead.string(metadata[kAXIdentifierAttribute], attribute: kAXIdentifierAttribute) ?? ""
                let key = try MacAXAttributeRead.string(metadata[kAXMenuItemCmdCharAttribute], attribute: kAXMenuItemCmdCharAttribute) ?? ""
                if key.isEmpty { return identifier.isEmpty ? nil : identifier }
                guard let modifiers = try metadata[kAXMenuItemCmdModifiersAttribute] as? NSNumber else {
                    return nil
                }
                return identifier + "|" + key + "|" + modifiers.stringValue
            }() : nil
            let list = MacAXAttributeRead.listReading(element, role: role, context: context)
            var attributes = MacAXAttributes(
                role: role,
                subrole: names.subrole,
                // Use the same separate-label naming rule as act-side drift checks.
                title: names.identity,
                // AXHeading numeric values are levels, not document text; preserve genuine strings only.
                value: value,
                enabled: enabled,
                selected: try MacAXAttributeRead.boolean(metadata[kAXSelectedAttribute], attribute: kAXSelectedAttribute),
                frame: names.frame,
                actions: actions.names,
                actionsUnreadable: actions.unreadable,
                placeholder: MacAXAttributeRead.placeholderRoles.contains(role)
                    ? names.placeholder : nil,
                selectionRange: try needsRange ? MacAXAttributeRead.textRange(content[kAXSelectedTextRangeAttribute]) : nil,
                state: state,
                liveRegion: (liveSetting.map { $0 != "off" } ?? false)
                    || ["AXApplicationStatus", "AXApplicationAlert"].contains(
                        names.subrole ?? role),
                valueIsHelp: textValue.map { $0 == names.help } ?? false,
                titleIsHelp: names.identity != names.display,
                displayTitle: names.display,
                listSummary: list.summary,
                isHiddenMenuItem: isHiddenMenuItem,
                menuCommandKey: menuCommandKey,
                attributeGaps: gaps.values,
                labelUnreadable: names.unreadable
            )
            attributes.listRead = list.children
            return attributes
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
        let metadata = try MacAXAttributeRead.checkedBatch(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXHiddenAttribute, kAXMenuItemPrimaryUIElementAttribute], context: context)
        guard let role = try MacAXAttributeRead.string(metadata[kAXRoleAttribute], attribute: kAXRoleAttribute) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "The element exposes no AXRole (unsupported or no value).")
        }
        return MacAXAttributes(role: role, subrole: try MacAXAttributeRead.string(metadata[kAXSubroleAttribute], attribute: kAXSubroleAttribute),
            isHiddenMenuItem: try hiddenMenuItem(element, role: role, metadata: metadata))
    }
    private func hiddenMenuItem(_ element: AXUIElement, role: String, metadata: MacAXAttributeRead.Values) throws -> Bool {
        guard role == "AXMenuItem" || role == "AXMenuBarItem" else { return false }
        let primary = try role == "AXMenuItem" ? metadata[kAXMenuItemPrimaryUIElementAttribute] : nil
        if let primary, CFGetTypeID(primary) != AXUIElementGetTypeID() {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(kAXMenuItemPrimaryUIElementAttribute) returned a non-element value.")
        }
        return try MacAXAttributeRead.boolean(metadata[kAXHiddenAttribute], attribute: kAXHiddenAttribute) == true
            || primary.map { !CFEqual($0, element) } == true
    }
    public func checkedMaskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        try MacAXAttributeRead.checked(context: context) { context in
            do { return try readAttributes(of: ref, masking: true, context: context) }
            catch {
                let failure = MacAccessibilityReader.NativeReadFailure(
                    detail: "Secret masking element \(ref.id): \(error.localizedDescription)")
                MacAXAttributeRead.failed(failure, context: context)
                throw failure
            }
        }
    }
    public func children(of ref: MacAXElementRef, context: MacOperationContext) -> [MacAXElementRef] {
        guard let element = element(ref) else { return [] }
        return MacAXAttributeRead.copyElementArray(element, kAXChildrenAttribute, context: context).map { mint($0) }
    }
    public func checkedChildList(of ref: MacAXElementRef, role: String?, context: MacOperationContext) throws -> (attribute: String, count: Int) {
        guard let element = element(ref) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child count is unavailable.")
        }
        let list = try MacAXAttributeRead.childList(element, role: role, context: context)
        if let count = list.count { return (list.attribute, count) }
        do { return (list.attribute, try MacAXAttributeRead.arrayCount(element, list.attribute, context: context) ?? 0) }
        catch let error as MacAXAttributeRead.ElementAttributeFailure where error.status == .noValue { return (list.attribute, 0) }
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
    public func checkedChildren(of ref: MacAXElementRef, list: (attribute: String, count: Int), limit: Int,
                                context: MacOperationContext) throws -> [MacAXElementRef] {
        guard limit > 0 else { return [] }
        guard let element = element(ref) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child array is unavailable.")
        }
        return try MacAXAttributeRead.checkedElementArray(element, list.attribute, count: list.count, limit: limit, context: context).map { mint($0) }
    }
    /// Plain containers answer in one message: the children that fit and, past the limit, proof there are more. Lists keep their visible-rows reading.
    public func checkedChildren(of ref: MacAXElementRef, role: String?, limit: Int,
                                context: MacOperationContext) throws -> (children: [MacAXElementRef], total: Int) {
        guard let role, !role.isEmpty, !MacAXAttributeRead.listRoles.contains(role) else {
            let list = try checkedChildList(of: ref, role: role, context: context)
            return (try checkedChildren(of: ref, list: list, limit: min(list.count, max(0, limit)), context: context), list.count)
        }
        guard let element = element(ref) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child array is unavailable.")
        }
        try context.evidence?.check()
        try Task.checkCancellation()
        try Self.ensureRenderer(element, context: context)
        guard MacAXAttributeRead.prepareMessage(element, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child read exhausted the reader time budget.")
        }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        let wanted = max(0, limit)
        var raw: CFArray?
        let status = unsafe AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, CFIndex(wanted + 1), &raw)
        try Task.checkCancellation()
        switch status {
        case .success: break
        // Index 0 outside the array's range (AXUIElement.h, kAXErrorIllegalArgument) is an element with no children.
        case .attributeUnsupported, .noValue, .illegalArgument: return ([], 0)
        default: throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility AXChildren read failed (AX error \(status.rawValue)).")
        }
        let array = (raw as [AnyObject]?) ?? []
        let elements: [AXUIElement] = array.compactMap { candidate in
            CFGetTypeID(candidate) == AXUIElementGetTypeID() ? (candidate as! AXUIElement) : nil
        }
        guard elements.count == array.count else {
            throw MacAccessibilityReader.NativeReadFailure(
                detail: "Accessibility AXChildren returned a non-element array member; child addresses are unavailable.")
        }
        return (elements.prefix(wanted).map { mint($0) }, elements.count)
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
                guard unsafe AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
                return "(\(point.x), \(point.y))"
            case .cgSize:
                var size = CGSize.zero
                guard unsafe AXValueGetValue(axValue, .cgSize, &size) else { return nil }
                return "\(size.width)x\(size.height)"
            default:
                return nil
            }
        }
        return nil
    }
}
