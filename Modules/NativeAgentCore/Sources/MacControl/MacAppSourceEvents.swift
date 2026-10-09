import Foundation
import Senses
import NativeAgentCore

#if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
import ApplicationServices
import AppKit
#endif

/// Event-only observation of one already-running app. AX subscriptions are
/// installed on descendants as well as the application: most element changes
/// do not propagate to a notification registered on the application element.
/// One main-run-loop turn coalesces a burst; no clock drives reads or renewal.
public final class MacAppSourceEvents: @unchecked Sendable {
    public let stream: AsyncThrowingStream<Void, Error>
    private let continuation: AsyncThrowingStream<Void, Error>.Continuation
    private static let activeWatches = ActiveWatches()

    /// Enhanced AX flags must remain enabled while any live source owns the
    /// app's tree. This query is safe from either the AX lane or a reader task.
    public static func isWatching(pid: Int32) -> Bool {
        activeWatches.contains(pid)
    }

    private final class ActiveWatches: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int32: Int] = [:]

        func contains(_ pid: Int32) -> Bool {
            lock.withLock { (counts[pid] ?? 0) > 0 }
        }

        func add(_ pid: Int32) {
            lock.withLock { counts[pid, default: 0] += 1 }
        }

        func remove(_ pid: Int32) {
            lock.withLock {
                guard let count = counts[pid] else { return }
                counts[pid] = count > 1 ? count - 1 : nil
            }
        }
    }

    #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
    private let pid: Int32
    private var observer: AXObserver?
    private var subscriptions: [CFHashCode: [Subscription]] = [:]
    private var workspaceToken: NSObjectProtocol?
    private var stopped = false
    private var deliveryScheduled = false
    private var treeChanged = false
    private var focusChanged = false
    private var countedWatch = false
    /// The install walked under a read's caps (node budget, per-message
    /// timeout); every renewal walks under the same caps.
    private var capped = false
    private var stallTimer: DispatchSourceTimer?
    private var stallSeconds: TimeInterval?
    private var readDeadline: Date?
    private var stallDeadline: DispatchTime?

    private struct Subscription {
        let element: AXUIElement
        let kinds: [String]
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

    public convenience init(bundleID: String) throws {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        let pid = MacAXExecutionLane.sync {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated })?.processIdentifier
        }
        guard bundleID != "*", let pid else {
            throw SenseFailure(code: "source_unavailable", message: "App observation needs a concrete already-running app.")
        }
        try self.init(pid: pid)
        #else
        throw SenseFailure(code: "source_unavailable", message: "App accessibility observation requires macOS.")
        #endif
    }

    public init(pid: Int32) throws {
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

    /// Notifications only trigger reads. The reader renews this one-shot
    /// deadline when it observes renderer content growth, never on a callback.
    /// Expiry triggers a final read rather than closing the stream: content
    /// arriving at the boundary must still be able to renew the wait.
    func watchContentStall(seconds: TimeInterval) {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        MacAXExecutionLane.sync {
            guard !stopped, stallTimer == nil else { return }
            stallSeconds = seconds
            readDeadline = MacAXLimits.readDeadline
            let timer = DispatchSource.makeTimerSource(queue: .main)
            stallTimer = timer
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped, let deadline = self.stallDeadline else { return }
                // Content growth may have reset the deadline after the old timer
                // fired but before its handler reached the AX execution lane.
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
        guard status == .success, let created else {
            throw failure("create", status)
        }
        observer = created
        capped = MacAXLimits.readDeadline != nil
        try reconcileTree()
        guard subscriptions.values.contains(where: { $0.contains(where: { !$0.kinds.isEmpty }) }) else {
            throw SenseFailure(code: "source_unavailable", message: "The running app supports no accessibility change notifications.")
        }
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
        Self.activeWatches.add(pid)
        countedWatch = true
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
            let renew = {
                self.deliveryScheduled = false
                do {
                    if self.treeChanged {
                        self.treeChanged = false
                        self.focusChanged = false
                        try self.reconcileTree()
                    } else if self.focusChanged {
                        self.focusChanged = false
                        let app = AXUIElementCreateApplication(self.pid)
                        if let focus = MacAXAttributeRead.copyElement(app, kAXFocusedUIElementAttribute) {
                            try self.addSubtree(focus)
                        }
                    }
                    self.continuation.yield(())
                } catch { self.stop(error: error) }
            }
            MacAXExecutionLane.sync {
                guard self.capped else { return renew() }
                MacAXLimits.$readDeadline.withValue(Date().addingTimeInterval(MacAXLimits.readSeconds), operation: renew)
            }
        }
    }

    private func reconcileTree() throws {
        let previous = subscriptions
        subscriptions = [:]
        do {
            try addSubtree(AXUIElementCreateApplication(pid), reusing: previous)
        } catch {
            // Preserve all installed handles so stop removes every registration.
            for (hash, rows) in previous {
                for row in rows where !(subscriptions[hash] ?? []).contains(where: { CFEqual($0.element, row.element) }) {
                    subscriptions[hash, default: []].append(row)
                }
            }
            throw error
        }
        guard let observer else { return }
        for (hash, rows) in previous {
            for row in rows where !(subscriptions[hash] ?? []).contains(where: { CFEqual($0.element, row.element) }) {
                for kind in row.kinds { AXObserverRemoveNotification(observer, row.element, kind as CFString) }
            }
        }
    }

    private func addSubtree(_ root: AXUIElement, reusing previous: [CFHashCode: [Subscription]] = [:]) throws {
        guard let observer else { return }
        var pending = [root]
        var examined = 0
        while let element = pending.popLast() {
            try Task.checkCancellation()
            if MacAXLimits.readDeadline != nil, examined >= MacAXLimits.deepPageMaxNodes {
                throw failure("subscribe within the AX node budget", .cannotComplete)
            }
            let hash = CFHash(element)
            guard !(subscriptions[hash] ?? []).contains(where: { CFEqual($0.element, element) }) else { continue }
            if let existing = previous[hash]?.first(where: { CFEqual($0.element, element) }) {
                subscriptions[hash, default: []].append(existing)
            } else {
                var kinds: [String] = []
                subscribeElement: for kind in Self.kinds {
                    try Task.checkCancellation()
                    guard MacAXAttributeRead.prepare(element) else {
                        throw failure("subscribe within the AX time budget", .cannotComplete)
                    }
                    let status = AXObserverAddNotification(observer, element, kind as CFString,
                        Unmanaged.passUnretained(self).toOpaque())
                    switch status {
                    case .success, .notificationAlreadyRegistered: kinds.append(kind)
                    case .notificationUnsupported, .notImplemented: break
                    case .invalidUIElement: break subscribeElement // Removed during traversal.
                    default:
                        subscriptions[hash, default: []].append(Subscription(element: element, kinds: kinds))
                        throw failure("subscribe to \(kind)", status)
                    }
                }
                subscriptions[hash, default: []].append(Subscription(element: element, kinds: kinds))
            }
            let children = MacAXAttributeRead.childAttribute(element)
            for attribute in children == kAXChildrenAttribute ? [children, kAXWindowsAttribute, kAXContentsAttribute] : [children] {
                try Task.checkCancellation()
                guard MacAXAttributeRead.prepare(element) else {
                    throw failure("read subscriptions within the AX time budget", .cannotComplete)
                }
                if MacAXLimits.readDeadline != nil {
                    var count: CFIndex = 0
                    let status = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
                    if [.attributeUnsupported, .noValue, .invalidUIElement].contains(status) { continue }
                    guard status == .success, count <= MacAXLimits.deepPageMaxNodes - examined - pending.count else {
                        throw failure("read subscriptions within the AX node budget", .cannotComplete)
                    }
                }
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                switch status {
                case .success:
                    if let value, CFGetTypeID(value) == CFArrayGetTypeID() {
                        for candidate in (value as! CFArray as [AnyObject]) where CFGetTypeID(candidate) == AXUIElementGetTypeID() {
                            pending.append(candidate as! AXUIElement)
                        }
                    } else if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                        pending.append(value as! AXUIElement)
                    }
                case .attributeUnsupported, .noValue, .invalidUIElement: break
                default: throw failure("read \(attribute) for subscriptions", status)
                }
            }
            examined += 1
            if MacAXLimits.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) }
        }
    }

    private func failure(_ operation: String, _ status: AXError) -> SenseFailure {
        SenseFailure(code: "source_unavailable", message: "App accessibility observation could not \(operation) (AX \(status.rawValue)).")
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
                    for kind in row.kinds where MacAXAttributeRead.prepare(row.element) {
                        AXObserverRemoveNotification(observer, row.element, kind as CFString)
                    }
                }
            }
        }
        subscriptions.removeAll()
        observer = nil
        if countedWatch {
            countedWatch = false
            Self.activeWatches.remove(pid)
        }
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
    #endif
}
