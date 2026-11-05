import Foundation
import Senses
import NativeAgentCore
import PersistenceCore

#if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
import ApplicationServices
import AppKit
// Blueprint: | `MacAppSourceEvents.swift` | Event-backed AX coverage retains gaps; complete traversal prunes; bounded content-stall signals |
#endif

/// Subscribe to descendants because most AX changes do not propagate to application observers. Partial coverage retains working subscriptions and names gaps;
/// notifications request reads, never prove exhaustive coverage. Coalesce bursts on the main run loop without clock-driven renewal.
public final class MacAppSourceEvents: @unchecked Sendable {
    public let stream: AsyncThrowingStream<Void, Error>
    private let context: MacOperationContext
    private let continuation: AsyncThrowingStream<Void, Error>.Continuation

    #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
    private let pid: Int32
    private var observer: AXObserver?
    private var subscriptions: [CFHashCode: [Subscription]] = [:]
    private var coveragePartial = false
    private var coverageGaps: [String] = []
    private var coverageGapCount = 0
    private var coverageVisited = 0
    private var workspaceToken: NSObjectProtocol?
    private var stopped = false
    private var deliveryScheduled = false
    private var treeChanged = false
    private var focusChanged = false
    private var stallTimer: DispatchSourceTimer?
    private var stallSeconds: TimeInterval?
    private var readDeadline: Date?
    private var stallDeadline: DispatchTime?

    private struct Subscription {
        let element: AXUIElement
        let kinds: [String]
        let needsRenewal: Bool
    }

    private static let structuralKinds: Set<String> = [
        kAXWindowCreatedNotification, kAXCreatedNotification,
        kAXUIElementDestroyedNotification, kAXLayoutChangedNotification,
        kAXSelectedChildrenChangedNotification, kAXRowCountChangedNotification,
        kAXSheetCreatedNotification, kAXDrawerCreatedNotification,
        kAXElementBusyChangedNotification,
        "AXChildrenChanged", "AXLayoutComplete", "AXLoadComplete"
    ]
    private static let kinds: [String] = [
        kAXValueChangedNotification, kAXFocusedUIElementChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXTitleChangedNotification, kAXSelectedTextChangedNotification,
        kAXSelectedChildrenChangedNotification, kAXRowCountChangedNotification,
        kAXWindowCreatedNotification, kAXCreatedNotification,
        kAXUIElementDestroyedNotification, kAXLayoutChangedNotification,
        kAXSheetCreatedNotification, kAXDrawerCreatedNotification,
        kAXElementBusyChangedNotification,
        "AXChildrenChanged", "AXLayoutComplete", "AXLoadComplete"
    ]
    #endif

    public convenience init(bundleID: String, context: MacOperationContext) throws {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        let pid = MacAXExecutionLane.sync {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated })?.processIdentifier
        }
        guard bundleID != "*", let pid else {
            throw SenseFailure(code: "source_unavailable", message: "App observation needs a concrete already-running app.")
        }
        try self.init(pid: pid, context: context)
        #else
        throw SenseFailure(code: "source_unavailable", message: "App accessibility observation requires macOS.")
        #endif
    }

    public init(pid: Int32, context: MacOperationContext) throws {
        self.context = context
        let pair = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        self.pid = pid
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        do {
            try MacAXExecutionLane.sync { Result { try self.install() } }.get()
        } catch {
            cancel()
            throw error
        }
        #else
        throw SenseFailure(code: "source_unavailable", message: "App accessibility observation requires macOS.")
        #endif
    }

    public func cancel() {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        MacAXExecutionLane.sync { self.stop(error: nil) }
        #else
        continuation.finish()
        #endif
    }

    deinit { cancel() }

    /// Read the subscription owner, never a caller's mirror of its health.
    public var coverage: JSONValue {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        return MacAXExecutionLane.sync {
            .object(["partial": .bool(coveragePartial), "visited": .int(Int64(coverageVisited)),
                     "gap_count": .int(Int64(coverageGapCount)),
                     "gaps": .array(coverageGaps.map(JSONValue.string))])
        }
        #else
        return .object(["unavailable": .bool(true)])
        #endif
    }

    /// Notifications only trigger reads. The reader renews this one-shot deadline when it observes renderer content growth, never on a callback. Expiry
    /// triggers a final read rather than closing the stream: content arriving at the boundary must still be able to renew the wait.
    func watchContentStall(seconds: TimeInterval, context: MacOperationContext) {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        MacAXExecutionLane.sync {
            guard !stopped, stallTimer == nil else { return }
            stallSeconds = seconds
            readDeadline = context.readDeadline
            let timer = DispatchSource.makeTimerSource(queue: .main)
            stallTimer = timer
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped, let deadline = self.stallDeadline else { return }
                // Content growth may have reset the deadline after the old timer fired but before its handler reached the AX execution lane.
                guard DispatchTime.now() >= deadline else {
                    self.stallTimer?.schedule(deadline: deadline)
                    return
                }
                self.continuation.yield(())
            }
            resetStallDeadline()
            timer.resume()
        }
        #endif
    }

    func noteContentGrowth() {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        MacAXExecutionLane.sync {
            guard !stopped else { return }
            resetStallDeadline()
        }
        #endif
    }

    var contentStalled: Bool {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        return MacAXExecutionLane.sync {
            guard let stallDeadline else { return false }
            return DispatchTime.now() >= stallDeadline
        }
        #else
        return false
        #endif
    }

    #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
    /// All mutable state and every AX transaction belong to MacAXExecutionLane.
    private func install() throws {
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw SenseFailure(code: "source_unavailable", message: "The app is no longer running or cannot observe itself.")
        }
        guard AXIsProcessTrusted() else {
            throw SenseFailure(code: "source_denied", message: "App observation requires macOS Accessibility permission.")
        }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let source = Unmanaged<MacAppSourceEvents>.fromOpaque(refcon).takeUnretainedValue()
            MacAXExecutionLane.sync { source.received(notification as String) }
        }
        let status = AXObserverCreate(pid, callback, &created)
        if [.notImplemented, .notificationUnsupported].contains(status) { throw noNotifications() }
        guard status == .success, let created else {
            throw failure("create", status)
        }
        observer = created
        try withSubscriptionBudget(context: context) { context in try reconcileTree(context: context) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let ended = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ended.processIdentifier == self.pid else { return }
            MacAXExecutionLane.sync {
                self.stop(error: SenseFailure(code: "source_unavailable", message: "The observed app stopped running."))
            }
        }
        // Close the install race once after registration; later reads are events.
        guard !app.isTerminated else {
            throw SenseFailure(code: "source_unavailable", message: "The observed app stopped during subscription.")
        }
        continuation.yield(())
    }

    private func received(_ kind: String) {
        guard !stopped else { return }
        treeChanged = treeChanged || Self.structuralKinds.contains(kind)
        focusChanged = focusChanged || kind == kAXFocusedUIElementChangedNotification
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            let renew = { (context: MacOperationContext) throws -> Void in
                self.deliveryScheduled = false
                if self.treeChanged {
                    self.treeChanged = false
                    self.focusChanged = false
                    try self.reconcileTree(context: context)
                } else if self.focusChanged {
                    self.focusChanged = false
                    let app = AXUIElementCreateApplication(self.pid)
                    do {
                        let focus = try MacAXAttributeRead.node(context: context) { context in
                            MacAXAttributeRead.copyElement(app, kAXFocusedUIElementAttribute, context: context)
                        }
                        if let focus { _ = try self.addSubtree(focus, context: context) }
                    } catch is CancellationError { throw CancellationError() }
                    catch let failure as SenseFailure { throw failure }
                    catch {
                        self.gap(app, kAXFocusedUIElementAttribute, error.localizedDescription)
                    }
                }
            }
            MacAXExecutionLane.sync {
                do {
                    // This notification owns a new bounded read, independent of the request that installed it.
                    try self.withSubscriptionBudget(context: self.context.settling(), renew)
                    self.continuation.yield(())
                } catch { self.stop(error: error) }
            }
        }
    }

    /// A GCD renewal cannot inherit the construction task's lifetime or budget.
    private func withSubscriptionBudget<Value>(context: MacOperationContext, _ operation: (MacOperationContext) throws -> Value) throws -> Value {
        let deadline = Date().addingTimeInterval(MacAXLimits.readSeconds)
        return try context.holding(\.readDeadline, min(context.readDeadline ?? deadline, deadline)) { context in
            guard AXIsProcessTrusted() else {
                throw SenseFailure(code: "source_denied", message: "App observation lost macOS Accessibility permission.")
            }
            return try operation(context)
        }
    }

    private func gap(_ element: AXUIElement, _ operation: String, _ cause: String) {
        coveragePartial = true
        coverageGapCount += 1
        let detail = "element \(CFHash(element)) \(operation): \(cause)"
        if coverageGaps.count < 20 { coverageGaps.append(detail) }
        if coverageGapCount <= 20 { nativeLog("AX watch gap pid=%d %@", pid, detail) }
    }

    private func reconcileTree(context: MacOperationContext) throws {
        let previous = subscriptions
        subscriptions = [:]
        coveragePartial = false
        coverageGaps = []
        coverageGapCount = 0
        coverageVisited = 0
        do {
            var complete = false
            defer {
                // An unread subtree proves nothing about its descendants. Keep prior handles on incomplete traversal (including throws) until a complete read
                // can prove which elements are gone.
                if !complete {
                    for (hash, rows) in previous {
                        for row in rows where !(subscriptions[hash] ?? []).contains(where: { CFEqual($0.element, row.element) }) {
                            subscriptions[hash, default: []].append(row)
                        }
                    }
                }
            }
            complete = try addSubtree(AXUIElementCreateApplication(pid), reusing: previous, context: context)
        }
        guard subscriptions.values.contains(where: { $0.contains(where: { !$0.kinds.isEmpty }) }) else {
            // With no installed notification there is no working channel. Partial traversal cannot prove that the app supports none.
            if coveragePartial {
                throw SenseFailure(code: "source_unavailable",
                    message: "No app accessibility notification could be installed; coverage is incomplete: \(coverageGaps.joined(separator: "; ")).")
            }
            throw noNotifications()
        }
        nativeLog("AX watch coverage pid=%d partial=%d visited=%d gaps=%d", pid, coveragePartial ? 1 : 0, coverageVisited, coverageGapCount)
        guard !coveragePartial else { return }
        guard let observer else { return }
        for (hash, rows) in previous {
            for row in rows where !(subscriptions[hash] ?? []).contains(where: { CFEqual($0.element, row.element) }) {
                for kind in row.kinds { AXObserverRemoveNotification(observer, row.element, kind as CFString) }
            }
        }
    }

    private func addSubtree(_ root: AXUIElement, reusing previous: [CFHashCode: [Subscription]] = [:], context: MacOperationContext) throws -> Bool {
        guard let observer else { throw SenseFailure(code: "source_unavailable", message: "The app accessibility observer is unavailable.") }
        var pending = [root]
        var examined = 0
        var complete = true
        while let element = pending.popLast() {
            try Task.checkCancellation()
            if examined >= MacAXLimits.deepPageMaxNodes || context.readDeadline.map({ Date() >= $0 }) == true {
                gap(element, "subscription coverage", "AX node/time budget reached; unvisited descendants are unknown")
                return false
            }
            let hash = CFHash(element)
            guard !(subscriptions[hash] ?? []).contains(where: { CFEqual($0.element, element) }) else { continue }
            defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
            if let existing = previous[hash]?.first(where: { CFEqual($0.element, element) && !$0.needsRenewal }) {
                subscriptions[hash, default: []].append(existing)
            } else {
                // Retrying this same subscription transaction keeps every kind that already registered, even if this renewal hits its bound.
                var kinds = previous[hash]?.first(where: { CFEqual($0.element, element) })?.kinds ?? []
                var needsRenewal = false
                subscribeElement: for kind in Self.kinds {
                    try Task.checkCancellation()
                    guard MacAXAttributeRead.prepareMessage(element, context: context) else {
                        gap(element, "subscribe to \(kind)", "AX time budget reached")
                        complete = false
                        needsRenewal = true
                        break
                    }
                    let status = AXObserverAddNotification(observer, element, kind as CFString,
                        Unmanaged.passUnretained(self).toOpaque())
                    switch status {
                    case .success, .notificationAlreadyRegistered:
                        if !kinds.contains(kind) { kinds.append(kind) }
                    case .notificationUnsupported, .notImplemented: break
                    case .apiDisabled, .invalidUIElementObserver: throw failure("use the accessibility observer", status)
                    case .invalidUIElement:
                        gap(element, "subscribe to \(kind)", "AX \(status.rawValue); element removed during traversal")
                        complete = false
                        needsRenewal = true
                        break subscribeElement
                    default:
                        // Another notification or element can still support observation. Keep the cause if none succeeds.
                        gap(element, "subscribe to \(kind)", "AX \(status.rawValue)")
                        complete = false
                        needsRenewal = true
                    }
                }
                subscriptions[hash, default: []].append(Subscription(element: element, kinds: kinds, needsRenewal: needsRenewal))
            }
            examined += 1
            coverageVisited += 1
            let isApplication = CFEqual(element, AXUIElementCreateApplication(pid))
            var attributes: [String] = []
            do {
                let children = try MacAXAttributeRead.node(context: context) { context in
                    try MacAXAttributeRead.childAttribute(element, role: isApplication ? kAXApplicationRole : nil, context: context)
                }
                attributes = children == kAXChildrenAttribute ? [children, kAXWindowsAttribute, kAXContentsAttribute] : [children]
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                gap(element, "child attribute", error.localizedDescription)
                complete = false
            }
            if isApplication {
                // These roots remain reachable even when AXChildren or AXContents is unreadable (including Electron apps).
                attributes = [kAXFocusedWindowAttribute, kAXMainWindowAttribute, kAXFocusedUIElementAttribute] + attributes
            }
            for attribute in attributes {
                try Task.checkCancellation()
                guard MacAXAttributeRead.prepareMessage(element, context: context) else {
                    gap(element, "read \(attribute)", "AX time budget reached; remaining descendants are unknown")
                    return false
                }
                let arrayAttribute = ![kAXFocusedWindowAttribute, kAXMainWindowAttribute, kAXFocusedUIElementAttribute].contains(attribute)
                var count: CFIndex = 0
                if arrayAttribute {
                    let status = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
                    switch status {
                    case .success:
                        if count == 0 { continue }
                        let remaining = max(0, MacAXLimits.deepPageMaxNodes - examined - pending.count)
                        if count > remaining {
                            gap(element, attribute, "\(count - remaining) children beyond the AX node budget are unknown")
                            complete = false
                            count = remaining
                        }
                        if count == 0 { continue }
                    case .attributeUnsupported, .noValue: continue
                    case .invalidUIElement:
                        gap(element, "count \(attribute)", "AX \(status.rawValue); element removed during traversal")
                        complete = false
                        continue
                    default:
                        if status == .apiDisabled { throw failure("count \(attribute)", status) }
                        gap(element, "count \(attribute)", "AX \(status.rawValue)")
                        complete = false
                        continue
                    }
                }
                var value: CFTypeRef?
                let status: AXError
                if arrayAttribute {
                    var array: CFArray?
                    status = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, count, &array)
                    value = array
                } else {
                    status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                }
                switch status {
                case .success:
                    if let value, CFGetTypeID(value) == CFArrayGetTypeID() {
                        let values = value as! CFArray as [AnyObject]
                        if values.count != count { gap(element, attribute, "short child array"); complete = false }
                        for candidate in values {
                            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else {
                                gap(element, attribute, "non-element child"); complete = false; continue
                            }
                            // Keep focused/window roots ahead of a large child array; breadth-first descent bounds one branch's cost.
                            pending.insert(candidate as! AXUIElement, at: 0)
                        }
                    } else if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                        pending.append(value as! AXUIElement)
                    } else {
                        gap(element, attribute, "unreadable element value")
                        complete = false
                    }
                case .attributeUnsupported, .noValue: break
                case .invalidUIElement:
                    gap(element, "read \(attribute)", "AX \(status.rawValue); element removed during traversal")
                    complete = false
                default:
                    if status == .apiDisabled { throw failure("read \(attribute)", status) }
                    gap(element, "read \(attribute)", "AX \(status.rawValue)")
                    complete = false
                }
            }
        }
        return complete
    }

    private func failure(_ operation: String, _ status: AXError) -> SenseFailure {
        SenseFailure(code: "source_unavailable", message: "App accessibility observation could not \(operation) (AX \(status.rawValue)).")
    }

    private func noNotifications() -> SenseFailure {
        SenseFailure(code: "source_unsupported", message: "The running app supports no accessibility change notifications.")
    }

    private func resetStallDeadline() {
        guard let stallSeconds, let stallTimer else { return }
        let deadline = DispatchTime.now() + max(0, min(stallSeconds, readDeadline?.timeIntervalSinceNow ?? stallSeconds))
        stallDeadline = deadline
        stallTimer.schedule(deadline: deadline)
    }

    private func stop(error: Error?) {
        guard !stopped else { return }
        stopped = true
        stallTimer?.cancel()
        stallTimer = nil
        stallDeadline = nil
        if let workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)
            self.workspaceToken = nil
        }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for rows in subscriptions.values {
                for row in rows {
                    for kind in row.kinds where MacAXAttributeRead.prepareMessage(row.element, context: context) {
                        AXObserverRemoveNotification(observer, row.element, kind as CFString)
                    }
                }
            }
        }
        subscriptions.removeAll()
        observer = nil
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
    #endif
}
