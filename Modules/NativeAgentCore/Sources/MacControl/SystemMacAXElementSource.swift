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
// Blueprint: | `SystemMacAXElementSource.swift` | Native read-only AX source with instance-locked references |
#if canImport(ApplicationServices) && os(macOS)
/// Live `AXUIElement` reader.
///
/// READ-ONLY BY CONSTRUCTION: only `AXUIElementCopyAttributeValue` /
/// `AXUIElementCopyActionNames` / `AXUIElementCreateApplication` are called.
/// No `AXUIElementPerformAction`, no `AXUIElementSetAttributeValue`.
///
/// Each instance is one snapshot session; its locked table owns the native handles.
/// The lock serializes every AXUIElement reference access under @unchecked Sendable.
public final class SystemMacAXElementSource: MacAXElementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int: AXUIElement] = [:]
    private var nextID = 0
    private var messagingTimeouts: [Int32: Float] = [:]
    public init() {}
    /// AX timeouts belong to object instances, not process identities.
    func setMessagingTimeout(pid: Int32, seconds: Float) {
        MacAXExecutionLane.sync {
            guard pid != getpid() else { return }
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
    /// Also covers temporary captions, parents and scrollbar objects.
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
    func captureContinuation(pid: Int32?, taskReference: String) -> MacWorkContinuation {
        func unsupported(_ reason: String) -> MacWorkContinuation {
            .unsupported(reason, taskReference: taskReference)
        }
        guard isTrusted() else { return unsupported("accessibility_permission_missing") }
        guard let pid, pid != getpid(), let app = appInfo(pid: pid) else {
            return unsupported("previous_app_unavailable")
        }
        // The session's cover (screensaver, lock) is not an app he works in:
        // a continuation captured there would anchor every later look to it.
        guard app.bundleIdentifier != MacWakeGuard.loginWindowBundleID else {
            return unsupported("screen_covered")
        }
        guard let launchDate = NSRunningApplication(processIdentifier: pid)?.launchDate else {
            return unsupported("app_identity_unsupported")
        }
        let application = AXUIElementCreateApplication(pid)
        guard let rawWindow = MacAXAttributeRead.copyElement(application, kAXFocusedWindowAttribute),
              Self.isWindow(rawWindow) else { return unsupported("focused_window_unavailable") }
        let root = mint(rawWindow)
        guard let attributes = attributes(of: root),
              let path = focusedElementPathOnExecutionLane(relativeTo: root, siblingLimit: MacAXLimits.hardMaxNodes),
              let rawFocus = MacAXAttributeRead.copyElement(application, kAXFocusedUIElementAttribute) else {
            return unsupported("focused_element_unavailable")
        }
        let capturedTitle = attributes.title
        guard app.name.count <= 256, (app.bundleIdentifier?.count ?? 0) <= 256,
              (capturedTitle?.count ?? 0) <= 1024 else { return unsupported("identity_over_budget") }
        let focused = mint(rawFocus)
        guard let range = MacAXAttributeRead.copyTextRange(rawFocus) else {
            return unsupported("selection_range_unsupported")
        }
        let document = MacAXAttributeRead.copyString(rawWindow, kAXDocumentAttribute)
        guard document == nil || document!.count <= 1024 else { return unsupported("document_identity_over_budget") }
        let snapshot = MacAccessibilityReader.walk(source: self, root: root, limits: MacAXLimits())
        let percept = MacPerceptionCompiler.compile(snapshot: snapshot,
            secretContext: MacScreenViewTextRedaction.nodeSecretContext(snapshot.nodes), app: app,
            windowTitle: attributes.title, focusPath: path)
        guard let focus = percept.focus else { return unsupported("focused_element_outside_capture") }
        let identity = MacAXWindowIdentity(pid: pid, index: nil, role: attributes.role,
            subrole: attributes.subrole, title: attributes.title, frame: attributes.frame)
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
        return MacWorkContinuation(app: app, window: identity, focusPath: path,
            selectionRange: range, evidence: evidence, check: { [self] in
                MacAXExecutionLane.sync {
                    guard Date().timeIntervalSince(capturedAt) <= MacLookFrameStore.ttlSeconds else { return "stale_capture" }
                    guard isTrusted(), appInfo(pid: pid) == app,
                          NSRunningApplication(processIdentifier: pid)?.launchDate == launchDate else { return "stale_app" }
                    let application = AXUIElementCreateApplication(pid)
                    guard let liveWindow = MacAXAttributeRead.copyElement(application, kAXFocusedWindowAttribute),
                          let originalWindow = element(root), CFEqual(liveWindow, originalWindow),
                          MacAXAttributeRead.copyString(liveWindow, kAXDocumentAttribute) == document,
                          MacAXAttributeRead.copyString(liveWindow, kAXTitleAttribute) == capturedTitle else { return "stale_window_or_document" }
                    guard let liveFocus = MacAXAttributeRead.copyElement(application, kAXFocusedUIElementAttribute),
                          let originalFocus = element(focused), CFEqual(liveFocus, originalFocus),
                          focusedElementPathOnExecutionLane(relativeTo: root, siblingLimit: MacAXLimits.hardMaxNodes) == path else { return "stale_focused_element" }
                    guard MacAXAttributeRead.copyTextRange(liveFocus) == range else { return "stale_selection_range" }
                    return nil
                }
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
    /// Roles an app's window slot may legitimately answer with: windows (incl.
    /// dialog / system-dialog subroles), sheets, drawers, popovers, dialogs,
    /// and an open menu that is the app's only surface. Never the menu bar or
    /// the application element — walking those spent the whole budget on menus.
    static func isWindow(_ element: AXUIElement) -> Bool {
        ["AXWindow", "AXSheet", "AXDrawer", "AXPopover", "AXDialog", "AXSystemDialog", "AXMenu"]
            .contains(MacAXAttributeRead.copyString(element, kAXRoleAttribute) ?? "")
    }
    public func elementHash(_ ref: MacAXElementRef) -> Int? {
        element(ref).map { Int(bitPattern: UInt(CFHash($0))) }
    }
    public func sameElement(_ lhs: MacAXElementRef, _ rhs: MacAXElementRef) -> Bool {
        guard let left = element(lhs), let right = element(rhs) else { return false }
        return CFEqual(left, right)
    }
    public func isTrusted() -> Bool {
        // Read-only probe. Deliberately NOT AXIsProcessTrustedWithOptions(
        // kAXTrustedCheckOptionPrompt: true) — the TCC grant is User's click in
        // System Settings; code never nags or toggles it.
        AXIsProcessTrusted()
    }
    package func nativeApplication(pid: Int32) -> AXUIElement? {
        guard pid != getpid(), isTrusted() else { return nil }
        return AXUIElementCreateApplication(pid)
    }
    /// Exact native inventory: a failed AXWindows read is never zero windows.
    package func nativeWindows(pid: Int32) throws -> [AXUIElement] {
        try MacAccessibilityReader.withReadBudget {
            try Task.checkCancellation()
            let windows = nativeApplication(pid: pid).flatMap {
                MacAXAttributeRead.copyRaw($0, kAXWindowsAttribute) as? [AXUIElement]
            }
            try Task.checkCancellation()
            guard let windows else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "The app's AXWindows inventory could not be read. Check NativeAgent Accessibility access before continuing.")
            }
            return windows
        }
    }
    public func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32) -> Bool {
        guard frontmostApp()?.processIdentifier == pid,
              let current = frontmostWindowRoot(), let currentElement = element(current),
              let original = element(window), CFEqual(currentElement, original),
              let target = element(container), attributes(of: container)?.frame == frame else { return false }
        // System-wide hits can land in this process: AX main lane (see MacScreenViewCapture.hitPID).
        var hit: AXUIElement? = MacAXExecutionLane.sync {
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(frame.x + frame.w / 2),
                Float(frame.y + frame.h / 2), &element
            ) == .success else { return nil }
            return element
        }
        guard hit != nil else { return false }
        // A sheet, popup, overlapping window, or sibling scroll area is not
        // the document, even when the foreground PID has not changed.
        for _ in 0..<64 {
            guard let node = hit else { return false }
            _ = prepareForRead(node)
            if CFEqual(node, target) { return true }
            hit = MacAXAttributeRead.copyElement(node, kAXParentAttribute)
        }
        return false
    }
    public func frontmostApp() -> MacAXAppInfo? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return MacAXAppInfo(
            name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier
        )
        #else
        return nil
        #endif
    }
    public func frontmostWindowRoot() -> MacAXElementRef? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return windowRoot(pid: app.processIdentifier)
        #else
        return nil
        #endif
    }
    /// List `.regular` UI apps only; background-only processes cannot answer a window request.
    public func runningApps() -> [MacAXAppInfo] {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { app in
                MacAXAppInfo(
                    name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    processIdentifier: app.processIdentifier
                )
            }
        #else
        return []
        #endif
    }
    /// One attribute read on the application element; no walk
    /// happens here — `MacMenuBar.read` owns the bounded descent.
    public func menuBarRoot(pid: Int32) -> MacAXElementRef? {
        #if canImport(AppKit)
        guard pid != getpid(), isTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = MacAXAttributeRead.copyElement(app, kAXMenuBarAttribute) else { return nil }
        return mint(bar)
        #else
        return nil
        #endif
    }
    public func transientMenuRoots(pid: Int32) -> [MacAXElementRef] {
        guard pid != getpid(), isTrusted(), frontmostApp()?.processIdentifier == pid else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var menus: [AXUIElement] = []
        func appendMenu(_ element: AXUIElement) {
            guard menus.count < MacTransientMenus.maxMenus,
                  MacAXAttributeRead.copyString(element, kAXRoleAttribute) == "AXMenu",
                  MacAXAttributeRead.copyBool(element, "AXHidden") != true,
                  let frame = MacAXAttributeRead.copyFrame(element), MacTransientMenus.validFrame(frame),
                  !menus.contains(where: { CFEqual($0, element) }) else { return }
            menus.append(element)
        }
        // Chrome keeps focus on AXWebArea while its context menu is a sibling
        // of an ancestor group. The ordinary page-first walk excludes it.
        let nearby = MacTransientMenus.nearFocus(
            MacAXAttributeRead.copyElement(app, kAXFocusedUIElementAttribute),
            parent: { MacAXAttributeRead.copyElement($0, kAXParentAttribute) },
            children: { element, limit in
                guard MacAXAttributeRead.copyString(element, kAXRoleAttribute) != "AXMenuBar" else { return [] }
                return MacAXAttributeRead.copyElementArray(element, kAXChildrenAttribute, limit: limit)
            },
            isMenu: { MacAXAttributeRead.copyString($0, kAXRoleAttribute) == "AXMenu" },
            equal: { CFEqual($0, $1) }
        )
        for menu in nearby {
            appendMenu(menu)
        }
        // Chromium context menus commonly live directly under the application.
        // Use ranged reads so a large application tree is not materialized.
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
    public func windowRoot(pid: Int32) -> MacAXElementRef? {
        #if canImport(AppKit)
        // Refuse self-process elements even for direct callers: AppKit re-entry can deadlock the main thread.
        guard pid != getpid() else { return nil }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        let appElement = prepareForRead(AXUIElementCreateApplication(pid))
        // Require a window root; a non-window root can spend the walk budget on the menu bar.
        if let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute).map(prepareForRead),
           Self.isWindow(focused) {
            return mint(focused)
        }
        if let main = MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute).map(prepareForRead),
           Self.isWindow(main) {
            return mint(main)
        }
        if let first = MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute)
            .map(prepareForRead)
            .first(where: Self.isWindow) {
            return mint(first)
        }
        return nil
        #else
        return nil
        #endif
    }
    /// Every window of the process, in `AXWindows` order, each with
    /// the composite identity — read-only, one attribute pass per window.
    ///
    /// `AXWindows` supplies the primary order, but Finder can omit a focused
    /// `AXSheet`. Union focused and main after it, deduped by `CFEqual`, so the
    /// snapshot can preserve the sheet's own identity without making an
    /// ordinary focused/main window appear twice.
    public func windowRoots(pid: Int32) -> [MacAXWindowHandle] {
        #if canImport(AppKit)
        // Same self-process fence as `windowRoot(pid:)` — see the deadlock
        // note there.
        guard pid != getpid() else { return [] }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        let windows = MacAXWindowInventory.union(
            listed: MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute),
            focused: MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute),
            main: MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute),
            equal: { CFEqual($0, $1) }
        ).filter(Self.isWindow)
        return windows.enumerated().map { index, window in
            MacAXWindowHandle(
                ref: mint(window),
                identity: MacAXAttributeRead.copyWindowIdentity(window, pid: pid, index: index)
            )
        }
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
            processIdentifier: pid
        )
        #else
        return nil
        #endif
    }
    /// Walk UP from the app's focused element to the window root, recording the
    /// index of each element in its parent's children. Cheap and exact: one
    /// `AXParent` chain, no second tree walk — and still read-only.
    ///
    /// nil when there is no focused element, when the chain does not reach the
    /// same root `frontmostWindowRoot()` returned (a focused element in another
    /// window), or when any hop is unreadable. Absence over a wrong answer.
    public func focusedElementPath() -> [Int]? {
        focusedElementPath(relativeTo: nil)
    }
    /// Same walk, anchored to the ROOT THE CALLER ALREADY WALKED when one is
    /// given: the path is only meaningful inside that snapshot, and a focus
    /// that moved to another window between the walk and this call must read
    /// as "no focus", never as "the node at that path in the old tree".
    /// Runs on the AX execution lane like every other live call that can
    /// re-enter the target app.
    public func focusedElementPath(relativeTo rootRef: MacAXElementRef?) -> [Int]? {
        MacAXExecutionLane.sync { focusedElementPathOnExecutionLane(relativeTo: rootRef) }
    }
    private func focusedElementPathOnExecutionLane(relativeTo rootRef: MacAXElementRef?, siblingLimit: Int = MacAXLimits.hardMaxNodes) -> [Int]? {
        #if canImport(AppKit)
        let pid: pid_t
        if let rootRef, let root = element(rootRef) {
            var owner: pid_t = 0
            guard AXUIElementGetPid(root, &owner) == .success else { return nil }
            pid = owner
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            pid = app.processIdentifier
        }
        // Same self-process fence as `windowRoot(pid:)` — a focused element in
        // our own window must never be walked over AX.
        guard pid != getpid() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        guard let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedUIElementAttribute) else { return nil }
        let root: AXUIElement
        if let rootRef {
            // The walked root, by handle — not whatever window is focused NOW.
            guard let anchored = element(rootRef) else { return nil }
            root = anchored
        } else {
            guard let live = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute)
                ?? MacAXAttributeRead.copyElement(appElement, kAXMainWindowAttribute)
                ?? MacAXAttributeRead.copyElementArray(appElement, kAXWindowsAttribute).first
            else { return nil }
            root = live
        }
        var path: [Int] = []
        var current = focused
        // Bounded by the reader's own depth ceiling: a cycle or a pathological
        // chain cannot spin here.
        for _ in 0..<MacAXLimits.hardMaxDepth {
            if CFEqual(current, root) { return path.reversed() }
            guard let parent = MacAXAttributeRead.copyElement(current, kAXParentAttribute) else { return nil }
            let siblings = MacAXAttributeRead.copyElementArray(parent, kAXChildrenAttribute,
                limit: siblingLimit, preservingIndices: true)
            guard let index = siblings.firstIndex(where: { CFEqual($0, current) }) else { return nil }
            path.append(index)
            current = parent
        }
        return nil
        #else
        return nil
        #endif
    }
    public func settableAttributes(of ref: MacAXElementRef) -> [String] {
        guard let element = element(ref) else { return [] }
        return [kAXValueAttribute, kAXFocusedAttribute, kAXSelectedAttribute].filter { attribute in
            guard MacAXAttributeRead.prepare(element) else { return false }
            defer { if MacAXLimits.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
                && settable.boolValue
        }
    }
    public func attributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        guard let element = element(ref) else { return nil }
        guard let role = MacAXAttributeRead.copyString(element, kAXRoleAttribute) else { return nil }
        let isHiddenMenuItem = hiddenMenuItem(element, role: role)
        let menuCommandKey: String? = role == "AXMenuItem" ? {
            let identifier = MacAXAttributeRead.copyString(element, kAXIdentifierAttribute) ?? ""
            let key = MacAXAttributeRead.copyString(element, kAXMenuItemCmdCharAttribute) ?? ""
            return identifier.isEmpty && key.isEmpty ? nil : identifier + "|" + key
        }() : nil
        let names = MacAXAttributeRead.copyLabel(element, role: role, prepare: prepareForRead)
        let rawValue = MacAXAttributeRead.copyRaw(element, kAXValueAttribute)
        let textValue = (rawValue as? String).flatMap { $0.isEmpty ? nil : $0 }
        let state = MacAXAttributeRead.valueState(rawValue, role: role)
        return MacAXAttributes(
            role: role,
            subrole: names.subrole,
            // A field or popup named by a separate label ("Save As:") takes
            // that label's text — the same rule the act-side drift check reads.
            title: names.identity,
            // AXHeading's numeric value is a heading level. Preserve a genuine
            // string value, but never stringify its level as document text.
            value: role == "AXHeading" ? textValue : state == nil ? rawValue.flatMap(Self.stringifiedValue) : nil,
            enabled: MacAXAttributeRead.copyBool(element, kAXEnabledAttribute) ?? true,
            selected: MacAXAttributeRead.copyBool(element, kAXSelectedAttribute),
            frame: names.frame,
            actions: MacAXAttributeRead.copyActions(element),
            placeholder: MacAXAttributeRead.placeholderRoles.contains(role)
                ? names.placeholder : nil,
            selectionRange: MacAXAttributeRead.placeholderRoles.contains(role)
                ? MacAXAttributeRead.copyTextRange(element) : nil,
            state: state,
            liveRegion: (role == "AXGroup" && (MacAXAttributeRead.copyString(element, "AXARIALive")
                .map { $0 != "off" } ?? false))
                || ["AXApplicationStatus", "AXApplicationAlert"].contains(
                    names.subrole ?? role),
            valueIsHelp: textValue.map { $0 == names.help } ?? false,
            titleIsHelp: names.identity != names.display,
            displayTitle: names.display,
            listSummary: MacAXAttributeRead.listSummary(element, role: role),
            isHiddenMenuItem: isHiddenMenuItem,
            menuCommandKey: menuCommandKey
        )
    }
    /// Native navigation needs the same traversal metadata, without fetching
    /// any field value. Hidden modifier alternates have one owner here.
    package func topologyAttributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        guard let element = element(ref),
              let role = MacAXAttributeRead.copyString(element, kAXRoleAttribute) else { return nil }
        return MacAXAttributes(role: role, subrole: MacAXAttributeRead.copyString(element, kAXSubroleAttribute),
            isHiddenMenuItem: hiddenMenuItem(element, role: role))
    }
    private func hiddenMenuItem(_ element: AXUIElement, role: String) -> Bool {
        guard role == "AXMenuItem" || role == "AXMenuBarItem" else { return false }
        // Modifier-only alternates point to the item shown without modifiers.
        let primary = role == "AXMenuItem"
            ? MacAXAttributeRead.copyElement(element, kAXMenuItemPrimaryUIElementAttribute) : nil
        return MacAXAttributeRead.copyBool(element, kAXHiddenAttribute) == true
            || primary.map { !CFEqual($0, element) } == true
    }
    public func maskingAttributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        guard let element = element(ref) else { return nil }
        guard let role = MacAXAttributeRead.copyString(element, kAXRoleAttribute) else { return nil }
        let names = MacAXAttributeRead.copyLabel(element, role: role, prepare: prepareForRead)
        let rawValue = MacAXAttributeRead.copyRaw(element, kAXValueAttribute)
        return MacAXAttributes(
            role: role,
            subrole: names.subrole,
            title: names.identity,
            // The same value rule as `attributes(of:)`.
            value: role == "AXHeading" ? (rawValue as? String).flatMap { $0.isEmpty ? nil : $0 }
                : MacAXAttributeRead.valueState(rawValue, role: role) == nil ? rawValue.flatMap(Self.stringifiedValue) : nil,
            frame: names.frame,
            actions: MacAXAttributeRead.copyActions(element)
        )
    }
    public func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        guard let element = element(ref) else { return [] }
        return MacAXAttributeRead.copyElementArray(element, kAXChildrenAttribute).map { mint($0) }
    }
    public func childCount(of ref: MacAXElementRef) -> Int? {
        guard let element = element(ref) else { return nil }
        let attribute = MacAXAttributeRead.childAttribute(element)
        guard MacAXAttributeRead.prepare(element) else { return nil }
        defer { if MacAXLimits.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var count: CFIndex = 0
        switch AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) {
        case .success: return max(0, Int(count))
        case .attributeUnsupported, .noValue: return 0
        default: return nil
        }
    }
    public func children(of ref: MacAXElementRef, limit: Int) -> [MacAXElementRef] {
        guard limit > 0, let element = element(ref) else { return [] }
        return MacAXAttributeRead.copyElementArray(element, kAXChildrenAttribute, limit: limit).map { mint($0) }
    }
    /// Render string, number, boolean, point and size values; other values stay absent.
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
