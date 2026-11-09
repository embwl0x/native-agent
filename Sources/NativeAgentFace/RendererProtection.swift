import AppKit
import Foundation
import NativeAgentShared
import Observation
// Blueprint: | `RendererProtection.swift` | Whole-renderer protected windows, lifecycle notifications and ordered acknowledged publication |

@MainActor
@Observable
final class RendererProtection {
    static let shared = RendererProtection()

    private final class HeldWindow {
        weak var window: NSWindow?
        var permanent: Bool
        var entries: Set<UUID> = []
        init(_ window: NSWindow, permanent: Bool = true) { self.window = window; self.permanent = permanent }
    }

    private weak var client: PipeFaceClient?
    private weak var shotgun: NSWindow?
    private var held: [ObjectIdentifier: HeldWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var submitted: ProtectedWindowsReport?
    private var publication: Task<Void, Error>?
    private var jobs: [UUID: Task<Void, Error>] = [:]
    private var connected = false
    var isConnected: Bool { connected }
    private var pointerPasses: Set<UUID> = []
    private var passing = false
    private var keyboardWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    private func keyboardHeld() throws -> Bool {
        guard connected else { throw FaceWireError.disconnected }
        if NSApp.keyWindow?.isKeyWindow == true { return true }
        return try snapshot().windows.contains(where: \.keyHeld)
    }

    func waitForKeyboard() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard try keyboardHeld() else { return }
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                else { keyboardWaiters[id] = waiter }
            }
        } onCancel: { Task { @MainActor in self.keyboardWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) } }
    }

    private func settleKeyboard() {
        guard !keyboardWaiters.isEmpty else { return }
        let result: Result<Void, Error>
        do {
            guard try !keyboardHeld() else { return }
            result = .success(())
        } catch { result = .failure(error) }
        let waiters = keyboardWaiters
        keyboardWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(with: result) }
    }

    /// Read live AppKit geometry, including hosts whose report is still crossing the pipe.
    func preparePointer(operation: UUID, at point: CGPoint) throws {
        guard connected else { throw FaceWireError.disconnected }
        guard pointerPasses.insert(operation).inserted else { throw FaceWireError.invalidFeedOrder }
        guard point.x.isFinite, point.y.isFinite else { throw FaceWireError.invalidFeedOrder }
        let report = try snapshot()
        if let primary = NSScreen.screens.first {
            for window in NSApp.windows where window.isVisible && !window.isMiniaturized && !window.ignoresMouseEvents && window !== shotgun {
                let frame = window.frame
                if CGRect(x: frame.minX, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height).contains(point) {
                    throw WireFailure(code: "person_window_at_pointer", message: "A NativeAgent window covers the agent's pointer target.",
                        cause: "Move that window aside, or enable Shotgun before continuing Mac input.", effects: .none)
                }
            }
        }
        for window in report.windows where CGRect(x: window.frame.x, y: window.frame.y,
            width: window.frame.width, height: window.frame.height).contains(point) {
            guard window.number == shotgun?.windowNumber, held.values.allSatisfy({ $0.window?.windowNumber != window.number }) else {
                throw WireFailure(code: "protected_entry_at_pointer", message: "Protected entry covers the agent's pointer target.",
                    cause: "Finish or close protected entry before continuing Mac input.", effects: .none)
            }
            passing = true
        }
        shotgun?.ignoresMouseEvents = passing
    }

    func restorePointer(operation: UUID) throws {
        guard connected else { throw FaceWireError.disconnected }
        guard pointerPasses.remove(operation) != nil else { throw FaceWireError.invalidFeedOrder }
        if pointerPasses.isEmpty { passing = false }
        shotgun?.ignoresMouseEvents = passing
    }

    func connect(client: PipeFaceClient) {
        guard self.client == nil else { return }
        self.client = client
        connected = true
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            let closing = name == NSWindow.willCloseNotification
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                guard let window = notice.object as? NSWindow else { return }
                let id = ObjectIdentifier(window)
                Task { @MainActor [weak self] in self?.changed(id, closing: closing) }
            }
            observers.append(token)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.publish() }
            })
        }
    }

    /// The empty native host is protected and acknowledged before its credential view mounts.
    func hold(window: NSWindow) async throws {
        try Task.checkCancellation()
        guard connected else { throw FaceWireError.disconnected }
        let id = ObjectIdentifier(window)
        if held[id] == nil { held[id] = HeldWindow(window) }
        held[id]?.permanent = true
        try await publishAndWait()
        try Task.checkCancellation()
        guard held[id]?.window === window else { throw CancellationError() }
    }

    func holdEntry(window: NSWindow, id entry: UUID) async throws {
        try Task.checkCancellation()
        guard connected else { throw FaceWireError.disconnected }
        let id = ObjectIdentifier(window)
        if held[id] == nil { held[id] = HeldWindow(window, permanent: false) }
        held[id]?.entries.insert(entry)
        do {
            try await publishAndWait()
            try Task.checkCancellation()
            guard held[id]?.window === window, held[id]?.entries.contains(entry) == true else { throw CancellationError() }
        } catch { releaseEntry(entry); throw error }
    }

    func releaseEntry(_ entry: UUID) {
        for (id, window) in held where window.entries.remove(entry) != nil {
            if window.entries.isEmpty, !window.permanent { held[id] = nil }
        }
        publish()
    }

    func release(window: NSWindow) {
        guard held.removeValue(forKey: ObjectIdentifier(window)) != nil else { return }
        publish()
    }

    func publishShotgun(window: NSWindow?) {
        shotgun = window
        window?.ignoresMouseEvents = passing
        publish()
    }

    func publishAndWait() async throws {
        let task = try enqueue(snapshot())
        try await task.value
        try Task.checkCancellation()
    }

    func disconnect() {
        connected = false
        let waiters = keyboardWaiters
        keyboardWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: FaceWireError.disconnected) }
        shotgun?.ignoresMouseEvents = false
        pointerPasses.removeAll()
        passing = false
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        publication = nil
        submitted = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        held.removeAll()
        shotgun = nil
        client = nil
    }

    private func changed(_ id: ObjectIdentifier, closing: Bool) {
        settleKeyboard()
        let isShotgun = shotgun.map { ObjectIdentifier($0) == id } == true
        guard held[id] != nil || isShotgun else { return }
        if closing {
            held.removeValue(forKey: id)
            if isShotgun { shotgun = nil }
        }
        publish()
    }

    private func publish() {
        settleKeyboard()
        guard connected, client?.connectionID != nil else { return }
        do {
            _ = try enqueue(snapshot())
        } catch { ApplicationLifetime.shared.appModel?.setFailureStatus(error, action: "protect this window") }
    }

    private func snapshot() throws -> ProtectedWindowsReport {
        guard connected, let connection = client?.connectionID else { throw FaceWireError.disconnected }
        var windows: [ObjectIdentifier: NSWindow] = [:]
        for (id, entry) in held {
            if let window = entry.window { windows[id] = window }
        }
        if let shotgun { windows[ObjectIdentifier(shotgun)] = shotgun }
        guard !windows.isEmpty else { return .init(connection: connection, windows: []) }
        guard let primary = NSScreen.screens.first else {
            throw WireFailure(code: "window_screen_unavailable", message: "The display geometry for this protected window is unavailable.",
                cause: "Reconnect a display before opening protected entry.", effects: .none)
        }
        var report: [ProtectedWindow] = []
        for window in windows.values {
            let number = window.windowNumber
            guard number > 0 else {
                throw WireFailure(code: "protected_window_unallocated", message: "The native host has no window-server identity.",
                    cause: "Create the empty host before opening protected entry.", effects: .none)
            }
            let frame = window.frame
            guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite else {
                throw WireFailure(code: "protected_window_geometry_invalid", message: "The protected window has invalid display geometry.",
                    cause: nil, effects: .none)
            }
            report.append(.init(number: number,
                frame: .init(x: frame.minX, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height),
                keyHeld: held[ObjectIdentifier(window)] != nil || window.isKeyWindow))
        }
        return .init(connection: connection, windows: report.sorted { $0.number < $1.number })
    }

    /// Each new geometry waits for the preceding write to settle; an unchanged failed write remains failed.
    private func enqueue(_ report: ProtectedWindowsReport) throws -> Task<Void, Error> {
        guard connected, let client else { throw FaceWireError.disconnected }
        if submitted == report, let publication { return publication }
        let preceding = publication
        let id = UUID()
        let task = Task { @MainActor [weak self, weak client] in
            defer { self?.jobs.removeValue(forKey: id) }
            if let preceding { _ = await preceding.result }
            try Task.checkCancellation()
            guard let self, let client, self.connected, self.client === client, client.connectionID == report.connection else {
                throw FaceWireError.disconnected
            }
            do {
                switch try await client.act(.reportProtectedWindows(report)) {
                case .acknowledged: return
                case .failed(let failure), .refused(let failure): throw failure
                default:
                    throw WireFailure(code: "window_protection_unconfirmed", message: "I did not acknowledge this window's protection.",
                        cause: "Keep protected entry closed until its registration is acknowledged.", effects: .unknown)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                ApplicationLifetime.shared.appModel?.setFailureStatus(error, action: "protect this window")
                throw error
            }
        }
        jobs[id] = task
        submitted = report
        publication = task
        return task
    }
}
