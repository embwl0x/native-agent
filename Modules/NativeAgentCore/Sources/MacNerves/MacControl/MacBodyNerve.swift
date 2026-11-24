import Dispatch
import AppKit
import ApplicationServices
import CoreFoundation
import CoreGraphics
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Synchronization

// Blueprint: | `MacBodyNerve.swift` | Act-held motor attribution and intervention receipts; shared workspace, console and foreground AX edges |

package final class MacBodyNerve: Sendable {
    package static let shared = MacBodyNerve()
    /// The somatic joint's microphone: CoreAudio says whether the default input is running anywhere.
    package let microphone = BodyFieldMicrophone()
    /// The one foreground read every Activity and body reader takes.
    package var frontmostApplication: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    package enum Edge: NotificationCenter.AsyncMessage {
        package typealias Subject = MacBodyNerve

        package static func makeNotification(_ message: Self) -> Notification {
            Notification(name: name, object: nil, userInfo: ["edge": message])
        }

        package static func makeMessage(_ notification: Notification) -> Self? {
            notification.userInfo?["edge"] as? Self
        }

        case activated(pid_t?, bundle: String?, name: String?, agentDriven: Bool)
        case terminated(pid_t?, bundle: String?, agentDriven: Bool)
        case launched(pid_t, name: String?, regular: Bool, agentDriven: Bool)
        case workspace(agentDriven: Bool)
        case sleep, wake, sessionInactive, sessionActive, locked, unlocked
        case focus(pid_t, kind: String, agentDriven: Bool)
        case raised(pid_t, uptime: TimeInterval)
        case personInterrupted
        case changed(agentDriven: Bool)
        case sheet(pid_t, String)
    }

    package enum Focus: Sendable {
        case ready(unsupported: [String])
        case unavailable(String)
        case ended
    }

    private let events = NotificationCenter()
    package func listen(_ receive: @escaping @Sendable (Edge) -> Void) -> NSObjectProtocol {
        events.observeSynchronously(for: Edge.self, using: receive)
    }
    package func remove(_ token: NSObjectProtocol) { events.removeObserver(token) }
    func onTermination(of pid: pid_t, _ receive: @escaping @Sendable () -> Void) -> NotificationCenter.ObservationToken {
        events.addObserver(for: Edge.self) { edge in
            if case .terminated(let ended, _, _) = edge, ended == pid { receive() }
        }
    }
    private func send(_ edge: Edge) { events.post(edge) }
    func windowRaised(pid: pid_t) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            send(.raised(pid, uptime: ProcessInfo.processInfo.systemUptime))
        }
    }
    private struct State {
        var bodyPID: pid_t?
        var activityPID: pid_t?
        var worker: JointObserver?
        var failures: [pid_t: String] = [:]
        var reading: [String: JSONValue] = [:]
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
        var stopped = false

        mutating func retire() {
            worker?.stop()
            worker = nil
            reading = [:]
            finishWaiters()
        }

        mutating func finishWaiters() {
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.finish() }
        }
    }

    private let state = Mutex(State())
    private let threads = DispatchGroup()
    private let tokens = Mutex([HeldHandle<(NotificationCenter, NSObjectProtocol)>]())
    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                let activation = name == NSWorkspace.didActivateApplicationNotification
                let agentDriven = self?.workspaceAct(pid: pid, bundleURL: app?.bundleURL, activation: activation) == true
                switch name {
                case NSWorkspace.didActivateApplicationNotification:
                    if let pid { self?.osEdge(pid) }
                    self?.send(.activated(pid, bundle: app?.bundleIdentifier, name: app?.localizedName, agentDriven: agentDriven))
                case NSWorkspace.didTerminateApplicationNotification:
                    if let pid { self?.osEdge(pid) }
                    self?.send(.terminated(pid, bundle: app?.bundleIdentifier, agentDriven: agentDriven))
                case NSWorkspace.didLaunchApplicationNotification:
                    if let pid { self?.send(.launched(pid, name: app?.localizedName, regular: app?.activationPolicy == .regular, agentDriven: agentDriven)) }
                case NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification: self?.send(.sleep)
                case NSWorkspace.screensDidWakeNotification: self?.send(.wake)
                case NSWorkspace.sessionDidResignActiveNotification: self?.send(.sessionInactive)
                case NSWorkspace.sessionDidBecomeActiveNotification: self?.send(.sessionActive)
                default: self?.send(.workspace(agentDriven: agentDriven))
                }
            }
            let held = HeldHandle((workspace as NotificationCenter, token))
            tokens.withLock { $0.append(held) }
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            let token = distributed.addObserver(forName: .init(name), object: nil, queue: nil) { [weak self] _ in
                self?.observe(nil)
                self?.send(name == "com.apple.screenIsLocked" ? .locked : .unlocked)
            }
            let held = HeldHandle((distributed as NotificationCenter, token))
            tokens.withLock { $0.append(held) }
        }
    }

    private func osEdge(_ pid: pid_t) {
        state.withLock { state in
            state.failures[pid] = nil
            if state.worker?.pid == pid || state.worker?.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
                state.bodyPID = nil
                state.activityPID = nil
                state.retire()
            }
        }
    }

    package func explicit(_ pid: pid_t) async {
        let fields = observe(pid, retry: true)
        guard fields["status"] == .string("reading") else { return }
        let id = UUID(), pair = AsyncStream<Void>.makeStream()
        state.withLock { state in
            if state.worker?.pid == pid, state.reading["status"] == .string("reading") { state.waiters[id] = pair.continuation }
            else { pair.continuation.finish() }
        }
        for await _ in pair.stream {}
        state.withLock { state in _ = state.waiters.removeValue(forKey: id) }
    }

    @discardableResult
    package func observe(_ pid: pid_t?, retry: Bool = false, agentDriven: Bool = false) -> [String: JSONValue] {
        state.withLock { state in
            if let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return [:] }
            let previous = state.bodyPID
            state.bodyPID = pid
            if let pid, state.worker?.pid != pid { state.activityPID = nil; state.retire() }
            guard !state.stopped, let pid else {
                if state.activityPID == nil { state.retire() }
                else if previous != nil { state.reading = [:]; state.finishWaiters(); state.worker?.bodyChanged() }
                return [:]
            }
            let failed = state.failures[pid]
            if let cause = failed {
                guard retry else { return ["status": .string("unavailable"), "cause": .string(cause)] }
                state.failures[pid] = nil
                if state.worker?.focusUnavailable == true { state.retire() }
            }
            if state.worker == nil || previous != pid || failed != nil {
                let source = ensureWorker(&state, pid: pid, agentDriven: agentDriven)
                state.reading = ["status": .string("reading")]
                source.bodyChanged()
            }
            return state.reading
        }
    }

    private func ensureWorker(_ state: inout State, pid: pid_t, agentDriven: Bool = false) -> JointObserver {
        if let worker = state.worker, worker.pid == pid { return worker }
        state.retire()
        let next = JointObserver(pid: pid, owner: self, agentDriven: agentDriven || isActing(pid: pid))
        state.worker = next
        threads.enter()
        Thread.detachNewThread { [threads] in
            defer { threads.leave() }
            next.run()
        }
        return next
    }

    package func captureFocus(_ pid: pid_t) async -> Focus {
        let source: JointObserver? = state.withLock { state in
            guard !Task.isCancelled, !state.stopped, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            if let worker = state.worker, worker.pid == pid, worker.focusUnavailable { state.retire() }
            state.activityPID = pid
            if state.bodyPID != pid { state.bodyPID = nil }
            return ensureWorker(&state, pid: pid)
        }
        guard let source else { return .ended }
        let focus = await source.awaitFocus()
        return state.withLock { !Task.isCancelled && $0.worker === source && $0.activityPID == pid ? focus : .ended }
    }

    package func releaseFocus(_ pid: pid_t) {
        state.withLock { state in
            guard state.activityPID == pid else { return }
            state.activityPID = nil
            if state.bodyPID == nil { state.retire() }
        }
    }

    fileprivate func wantsBody(_ source: JointObserver) -> Bool {
        state.withLock { state in state.worker === source && state.bodyPID == source.pid && state.failures[source.pid] == nil }
    }

    fileprivate func focus(_ kind: String, source: JointObserver, agentDriven: Bool) {
        if state.withLock({ $0.worker === source && $0.activityPID == source.pid }) {
            send(.focus(source.pid, kind: kind, agentDriven: agentDriven))
        }
    }

    fileprivate func published(_ value: [String: JSONValue], by source: JointObserver, agentDriven: Bool, creationFailed: Bool = false) {
        state.withLock { state in
            guard source === state.worker else { return }
            if creationFailed { state.failures[source.pid] = value["cause"]?.stringValue }
            guard state.bodyPID == source.pid, state.reading != value else { return }
            state.reading = value
            state.finishWaiters()
            state.failures[source.pid] = value["cause"]?.stringValue
            send(.changed(agentDriven: agentDriven))
        }
    }

    package func stop() async {
        microphone.stop()
        state.withLock { state in
            state.stopped = true
            state.retire()
        }
        tokens.withLock { tokens in
            for held in tokens { held.value.0.removeObserver(held.value.1) }
            tokens.removeAll()
        }
        await withCheckedContinuation { done in threads.notify(queue: .global()) { done.resume() } }
    }

    package enum ExpectationKind: Sendable {
        case sheet, dismiss, activateOrRaise, elementOrSurface, hidInput
    }

    private enum Restoration { case requesting, requested }

    private struct Act {
        let id: String
        let window: MacAXNativeElementIdentity?
        var pid: pid_t?
        let bundleURL: URL?
        let number: Int?
        let background: Bool
        let expect: ExpectationKind
        var restoration: Restoration?
        var intervened: String?
        var sheetAppeared = false

        var holdsForeground: Bool { !background && intervened == nil }
        var suppresses: Bool { intervened == nil && (restoration != nil || !sheetAppeared || expect == .sheet) }

        var receipt: [String: JSONValue] {
            var fields: [String: JSONValue] = [:]
            fields["intervened"] = intervened.map(JSONValue.string)
            if sheetAppeared {
                fields["sheet_appeared"] = .bool(true)
                fields["modal_appeared"] = .bool(true)
                fields["modal"] = .object(["role": .string(kAXSheetRole)])
            }
            return fields
        }
    }
    private let acts = Mutex([UUID: Act]())

    package func isActing(pid: pid_t?, foregroundOnly: Bool = false) -> Bool {
        guard let pid else { return false }
        return acts.withLock { $0.values.contains { $0.pid == pid && $0.suppresses && (!foregroundOnly || !$0.background) } }
    }

    package var hasActiveForegroundScope: Bool {
        acts.withLock { $0.values.contains(where: \.holdsForeground) }
    }

    func notePersonInput() {
        let interrupted = acts.withLock { acts in
            var interrupted = false
            for (id, act) in acts where act.holdsForeground {
                // A requested put-back is hers only until the person moves.
                if act.restoration == .requested { acts[id] = nil }
                else { acts[id]?.intervened = "human_input" }
                interrupted = true
            }
            return interrupted
        }
        if interrupted { send(.personInterrupted) }
    }

    private func workspaceAct(pid: pid_t?, bundleURL: URL?, activation: Bool) -> Bool {
        guard let pid else { return false }
        return acts.withLock { acts in
            var restored = false
            var foreignActivation = false
            for (id, act) in acts {
                if activation, act.pid == pid, let restoration = act.restoration, act.intervened == nil {
                    restored = true
                    if restoration == .requested { acts[id] = nil }
                    else { acts[id]?.restoration = nil }
                } else if act.pid == nil, let target = act.bundleURL, target == bundleURL?.standardizedFileURL {
                    acts[id]?.pid = pid
                } else if activation, !act.background, act.expect != .activateOrRaise,
                          let target = act.pid, target != pid {
                    foreignActivation = true
                    if act.intervened == nil { acts[id]?.intervened = "focus_stolen" }
                }
            }
            return restored || !foreignActivation && acts.values.contains { $0.pid == pid && $0.suppresses && (!activation || !$0.background) }
        }
    }

    private struct EfferenceActLease: ~Copyable, Sendable {
        var key: UUID?
        consuming func release(restoring requested: Bool) -> [String: JSONValue] {
            let id = key.take()!
            return MacBodyNerve.shared.acts.withLock { acts in
                if requested, let act = acts[id], act.restoration == .requesting, act.intervened == nil {
                    acts[id]?.restoration = .requested
                    return act.receipt
                }
                return acts.removeValue(forKey: id)?.receipt ?? [:]
            }
        }
        deinit {
            guard let id = key else { return }
            _ = MacBodyNerve.shared.acts.withLock { $0.removeValue(forKey: id) }
        }
    }

    package static func holding<T, Failure: Error>(_ window: MacAXWindowIdentity? = nil, pid: pid_t? = nil, bundleURL: URL? = nil,
                           turn: Turn? = nil, context: MacOperationContext, background: Bool = false,
                           expect: ExpectationKind, isolation: isolated (any Actor)? = #isolation,
                           restorationRequested: ((T) -> Bool)? = nil,
                           observed: ([String: JSONValue]) -> Void = { _ in }, work: () async throws(Failure) -> T) async throws(Failure) -> (value: T, receipt: [String: JSONValue]) {
        let pid = window?.pid ?? pid ?? (bundleURL == nil ? context.requiredFrontPid : nil)
        guard pid != nil || bundleURL != nil || expect == .hidInput else { return (try await work(), [:]) }
        let key = UUID()
        let act = Act(id: (turn.map { $0.id + ":" } ?? "") + key.uuidString, window: window?.nativeWindow,
                      pid: pid, bundleURL: bundleURL?.standardizedFileURL, number: context.requiredFrontWindow,
                      background: background, expect: expect, restoration: restorationRequested == nil ? nil : .requesting)
        let nerve = shared
        nerve.acts.withLock { $0[key] = act }
        return try await withSettledScope(EfferenceActLease(key: key), isolation: isolation,
            work: { (_: borrowing EfferenceActLease) async throws(Failure) -> T in try await work() },
            disposition: { value in value.map { restorationRequested?($0) == true } ?? false },
            release: { (lease: consuming EfferenceActLease, requested: Bool) in lease.release(restoring: requested) }, observed: observed)
    }

    fileprivate func sheet(on window: AXUIElement, number: Int?, source: JointObserver) {
        guard state.withLock({ $0.worker === source }) else { return }
        recordSheet(on: window, number: number, pid: source.pid)
    }

    func sheetCreated(_ element: AXUIElement) {
        var process: pid_t = 0
        guard AXUIElementGetPid(element, &process) == .success else { return }
        let pid = process
        recordSheet(on: element, number: nil, pid: pid)
        guard acts.withLock({ $0.values.contains { $0.pid == pid && !$0.sheetAppeared && $0.window != nil } }) else { return }
        var parent: CFTypeRef?
        guard AXUIElementSetMessagingTimeout(element, 0.25) == .success else { return }
        defer { _ = AXUIElementSetMessagingTimeout(element, 0) }
        guard unsafe AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
              let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return }
        recordSheet(on: parent as! AXUIElement, number: nil, pid: pid)
    }

    private func recordSheet(on window: AXUIElement, number: Int?, pid: pid_t) {
        let parent = MacAXNativeElementIdentity(element: window)
        let matched = acts.withLock { acts in
            var ids: [String] = []
            for (id, act) in acts where act.pid == pid && !act.sheetAppeared {
                if let native = act.window {
                    guard native == parent else { continue }
                } else if let required = act.number {
                    guard number == required else { continue }
                }
                acts[id]?.sheetAppeared = true
                ids.append(act.id)
            }
            return ids
        }
        for id in matched { send(.sheet(pid, id)) }
    }
}

// Its observation thread owns the AX observer, elements and CF run-loop sources.
private final class JointObserver: @unchecked Sendable {
    let pid: pid_t
    private weak var owner: MacBodyNerve?
    private struct State {
        var focus: MacBodyNerve.Focus?
        var loop: HeldHandle<CFRunLoop>?
        var stopping: Bool {
            if case .ended? = focus { return true }
            return false
        }
    }
    private let state = Mutex(State())
    private let focusReady = ScopedWaiter()
    private var focusInstalled: Set<String> = []
    private var bodyEnabled = false
    private static let focusKinds = [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXTitleChangedNotification]
    private var observer: AXObserver?
    private var bindings: [(AXUIElement, String)] = []
    private var registered: [(AXUIElement, String)] = []
    private var scheduled = false
    private var agentDriven = false
    private var focusedWindow: AXUIElement?
    private var windowNumber: Int?
    private var sheet: AXUIElement?
    private var sheetWindow: AXUIElement?
    private let app: AXUIElement

    init(pid: pid_t, owner: MacBodyNerve, agentDriven: Bool) {
        self.pid = pid
        self.owner = owner
        self.agentDriven = agentDriven
        app = AXUIElementCreateApplication(pid)
    }

    var focusUnavailable: Bool {
        state.withLock {
            if case .unavailable? = $0.focus { return true }
            return false
        }
    }

    func awaitFocus() async -> MacBodyNerve.Focus {
        await focusReady.park()
        return state.withLock { $0.focus ?? .ended }
    }

    private func finishFocus(_ status: MacBodyNerve.Focus) {
        state.withLock { state in
            if !state.stopping { state.focus = status }
        }
        focusReady.resume()
    }

    func bodyChanged() {
        state.withLock { state in
            guard !state.stopping, let loop = state.loop?.value else { return }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in updateBody() }
            CFRunLoopWakeUp(loop)
        }
    }

    func stop() {
        state.withLock { state in
            state.focus = .ended
            if let loop = state.loop?.value {
                CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
                CFRunLoopWakeUp(loop)
            }
        }
        focusReady.resume()
    }

    private struct Failure: LocalizedError {
        let operation: String
        let code: AXError
        var errorDescription: String? { "\(operation) returned AX error \(code.rawValue)." }
    }

    private func bounded<Value>(_ el: AXUIElement, _ operation: String, _ call: () throws -> Value) throws -> Value {
        if state.withLock({ $0.stopping }) { throw CancellationError() }
        let bound = AXUIElementSetMessagingTimeout(el, 0.25)
        guard bound == .success else { throw Failure(operation: operation, code: bound) }
        defer { _ = AXUIElementSetMessagingTimeout(el, 0) }
        return try call()
    }

    private func value(_ el: AXUIElement?, _ key: String) throws -> CFTypeRef? {
        guard let el else { return nil }
        var result: CFTypeRef?
        switch try bounded(el, key, { unsafe AXUIElementCopyAttributeValue(el, key as CFString, &result) }) {
        case .success: return result
        case .attributeUnsupported, .noValue: return nil
        case let code: throw Failure(operation: key, code: code)
        }
    }

    private func element(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    func run() {
        let current = HeldHandle(CFRunLoopGetCurrent()!)
        guard state.withLock({ state in
            guard !state.stopping else { return false }
            state.loop = current
            return true
        }) else { return }
        defer { state.withLock { $0.loop = nil } }
        do {
            var created: AXObserver?
            let status = unsafe AXObserverCreate(pid, { _, element, name, ref in
                if let ref { unsafe Unmanaged<JointObserver>.fromOpaque(ref).takeUnretainedValue().edge(element, name as String) }
            }, &created)
            guard status == .success, let created else { throw Failure(operation: "AXObserverCreate", code: status) }
            observer = created
            let source = AXObserverGetRunLoopSource(created)
            CFRunLoopAddSource(current.value, source, .defaultMode)
            defer {
                CFRunLoopRemoveSource(current.value, source, .defaultMode)
                registered.removeAll()
                bindings.removeAll()
                observer = nil
            }
            var unsupported: [String] = []
            do {
                for name in Self.focusKinds {
                    let code = try bounded(app, name) {
                        unsafe AXObserverAddNotification(created, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                    }
                    switch code {
                    case .success, .notificationAlreadyRegistered: focusInstalled.insert(name)
                    case .notificationUnsupported, .notImplemented: unsupported.append(name)
                    default: throw Failure(operation: name, code: code)
                    }
                }
                finishFocus(focusInstalled.isEmpty ? .unavailable("No focus notification is supported.") : .ready(unsupported: unsupported))
            } catch { finishFocus(.unavailable(error.localizedDescription)) }
            updateBody()
            if !state.withLock({ $0.stopping }) { CFRunLoopRun() }
        } catch {
            owner?.published(["status": .string("unavailable"), "cause": .string(error.localizedDescription)],
                             by: self, agentDriven: agentDriven, creationFailed: true)
            finishFocus(.unavailable(error.localizedDescription))
        }
    }

    private func releaseBody() {
        bodyEnabled = false
        if let observer {
            for (el, name) in registered { AXObserverRemoveNotification(observer, el, name as CFString) }
        }
        registered.removeAll()
        bindings.removeAll()
        focusedWindow = nil
        sheet = nil
        sheetWindow = nil
    }

    private func updateBody() {
        guard owner?.wantsBody(self) == true else { releaseBody(); return }
        do {
            if !bodyEnabled { try enableBody() }
            try autoreleasepool { try refresh() }
        } catch { failed(error) }
    }

    private func enableBody() throws {
        let flag = MacChromiumAccessibility.Flag.manualAccessibility.rawValue
        var writable = DarwinBoolean(false)
        let probe = try bounded(app, flag) { AXUIElementIsAttributeSettable(app, flag as CFString, &writable) }
        guard [.success, .attributeUnsupported, .noValue, .notImplemented].contains(probe) else {
            throw Failure(operation: flag, code: probe)
        }
        if probe == .success, writable.boolValue {
            let code = try bounded(app, flag) { AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanTrue) }
            guard [.success, .attributeUnsupported].contains(code) else { throw Failure(operation: flag, code: code) }
        }
        bodyEnabled = true
    }

    private func failed(_ error: Error) {
        guard !(error is CancellationError) else { return }
        releaseBody()
        owner?.published(["status": .string("unavailable"), "cause": .string(error.localizedDescription)], by: self, agentDriven: agentDriven)
    }

    private func edge(_ target: AXUIElement, _ kind: String) {
        guard !state.withLock({ $0.stopping }) else { return }
        var own = owner?.isActing(pid: pid) == true
        if Self.focusKinds.contains(kind) { owner?.focus(kind, source: self, agentDriven: own) }
        guard owner?.wantsBody(self) == true else { return }
        do {
            if kind == kAXUIElementDestroyedNotification {
                registered.removeAll { CFEqual($0.0, target) }
                bindings.removeAll { CFEqual($0.0, target) }
            }
            if kind == kAXSheetCreatedNotification, try value(target, kAXRoleAttribute) as? String == kAXSheetRole,
               let parent = element(try value(target, kAXParentAttribute)) {
                sheet = target
                sheetWindow = parent
                let number = focusedWindow.flatMap { CFEqual($0, parent) ? windowNumber : nil }
                owner?.sheet(on: parent, number: number, source: self)
                own = own && owner?.isActing(pid: pid) == true
            }
            if kind == kAXUIElementDestroyedNotification, let observed = sheet, CFEqual(observed, target) {
                sheet = nil
                sheetWindow = nil
            }
        } catch { failed(error); return }
        agentDriven = scheduled ? agentDriven && own : own
        guard !scheduled else { return }
        scheduled = true
        CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) { [self] in
            scheduled = false
            guard owner?.wantsBody(self) == true else { return }
            do { try autoreleasepool { try refresh() } } catch { failed(error) }
        }
    }

    private func subscribe(window: AXUIElement?, focus: AXUIElement?) throws {
        guard let observer else { return }
        let appKinds = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                        kAXFocusedUIElementChangedNotification, kAXSheetCreatedNotification, kAXDrawerCreatedNotification]
        var wanted = appKinds.filter { !focusInstalled.contains($0) }.map { (app, $0) }
        if let window { wanted += [kAXTitleChangedNotification, kAXUIElementDestroyedNotification,
                                    kAXSheetCreatedNotification, kAXDrawerCreatedNotification].map { (window, $0) } }
        if let focus { wanted.append((focus, kAXSelectedTextChangedNotification)) }
        if let sheet { wanted.append((sheet, kAXUIElementDestroyedNotification)) }
        func contains(_ rows: [(AXUIElement, String)], _ row: (AXUIElement, String)) -> Bool {
            rows.contains { CFEqual($0.0, row.0) && $0.1 == row.1 }
        }
        for (el, name) in registered where !contains(wanted, (el, name)) {
            let code = try bounded(el, name) { AXObserverRemoveNotification(observer, el, name as CFString) }
            guard [.success, .invalidUIElement, .notificationNotRegistered, .notificationUnsupported].contains(code)
            else { throw Failure(operation: name, code: code) }
        }
        registered.removeAll { !contains(wanted, $0) }
        for (el, name) in wanted where !contains(bindings, (el, name)) {
            let code = try bounded(el, name) {
                unsafe AXObserverAddNotification(observer, el, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            switch code {
            case .success, .notificationAlreadyRegistered: registered.append((el, name))
            case .notificationUnsupported, .notImplemented: break
            default: throw Failure(operation: name, code: code)
            }
        }
        guard !focusInstalled.isEmpty || !registered.isEmpty else { throw Failure(operation: "Window observation", code: .notificationUnsupported) }
        bindings = wanted
    }

    private func refresh() throws {
        func values(_ element: AXUIElement?, _ keys: [String]) throws -> MacAXAttributeRead.Values {
            guard let element else { return MacAXAttributeRead.Values() }
            return try bounded(element, keys.joined(separator: ", ")) { try MacAXAttributeRead.batch(element, keys) }
        }
        let application = try values(app, [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute])
        let window = try element(application[kAXFocusedWindowAttribute])
        let focus = try element(application[kAXFocusedUIElementAttribute])
        focusedWindow = window
        windowNumber = nil
        try subscribe(window: window, focus: focus)
        let windowValues = try values(window, [kAXTitleAttribute, kAXDocumentAttribute, "AXSheets", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute])
        let focusValues = try values(focus, [kAXRoleAttribute, kAXSelectedTextRangeAttribute])
        var fields: [String: JSONValue] = ["status": .string("available")]
        fields["title"] = (try windowValues[kAXTitleAttribute] as? String).map(JSONValue.string)
        fields["document"] = (try windowValues[kAXDocumentAttribute] as? String).map(JSONValue.string)
        fields["focused_role"] = (try focusValues[kAXRoleAttribute] as? String).map(JSONValue.string)
        if let sheets = try windowValues["AXSheets"] as? [AXUIElement] { fields["has_sheet"] = .bool(!sheets.isEmpty) }
        if try windowValues[kAXRoleAttribute] as? String == kAXSheetRole { fields["has_sheet"] = .bool(true) }
        if let window, let sheetWindow, CFEqual(window, sheetWindow) { fields["has_sheet"] = .bool(true) }
        if let selected = try focusValues[kAXSelectedTextRangeAttribute], CFGetTypeID(selected) == AXValueGetTypeID() {
            var range = CFRange()
            if unsafe AXValueGetValue(selected as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 {
                fields["selection_length"] = .int(Int64(range.length))
                fields["has_selection"] = .bool(range.length > 0)
            }
        }
        if let position = try windowValues[kAXPositionAttribute], CFGetTypeID(position) == AXValueGetTypeID() {
            let size: CFTypeRef?
            do { size = try windowValues[kAXSizeAttribute] }
            catch {
                fields["attribute_gaps"] = .array([.string(error.localizedDescription)])
                size = nil
            }
            var point = CGPoint.zero, extent = CGSize.zero
            if let size, CFGetTypeID(size) == AXValueGetTypeID(),
               unsafe AXValueGetValue(position as! AXValue, .cgPoint, &point), unsafe AXValueGetValue(size as! AXValue, .cgSize, &extent) {
                let frame = MacAXFrame(x: point.x, y: point.y, w: extent.width, h: extent.height)
                let matches = SystemMacVisualObstructionProbe.windows().filter { $0.ownerPID == pid && MacAXWindowIdentity.rectsMatch($0.frame, frame) }
                if matches.count == 1 {
                    windowNumber = matches[0].number
                    fields["window_id"] = .int(Int64(matches[0].number))
                }
            }
        }
        owner?.published(fields, by: self, agentDriven: agentDriven)
    }
}
