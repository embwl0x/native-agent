import Darwin
import AppKit
import Foundation
import CryptoKit
import NativeAgentChromeRelayCore
import PersistenceCore
import TrustCenter
import MacControl
import Transcripts
import NativeAgentCore

// No origin is a transport-level caller, never permission for a Chrome effect.
public enum ChromeControlInvocationContext {
    @TaskLocal public static var origin: SecurityOriginContext? = nil
    @TaskLocal public static var tool: String = "browser.chrome"
}

public enum ChromeControlRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case unavailable
    case disconnected
    case extensionNotLoaded
    case connectionUnavailable(String)
    case extensionReconnecting(startedAt: Date, retryAfter: Date)
    case handshakeRejected(String)
    case invalidResponse
    case requestTimedOut
    case extensionRejected(code: String, message: String)
    case outcomeUnknown(action: String, reason: String)
    case socketFailure(Int32)
    case socketPathTooLong
    case relayUnavailable
    case unsafeSocketPath
    case conversationContext(String)

    /// Transport-owned evidence. Dispatched mutations use outcomeUnknown;
    /// a missing connection cannot have read a page or emitted an action.
    public var failureEffects: ToolFailureError.Effects? {
        switch self {
        case .outcomeUnknown: .unknown
        case .disabled, .unavailable, .disconnected, .extensionNotLoaded,
             .connectionUnavailable, .extensionReconnecting, .handshakeRejected,
             .socketPathTooLong, .relayUnavailable, .unsafeSocketPath: .some(.none)
        case .invalidResponse, .requestTimedOut, .extensionRejected, .socketFailure, .conversationContext: nil
        }
    }

    public var recoverySuggestion: String? {
        guard case .extensionReconnecting(let startedAt, let retryAfter) = self else { return nil }
        return Self.reconnectInstruction(startedAt: startedAt, retryAfter: retryAfter)
    }

    static func reconnectInstruction(startedAt: Date, retryAfter: Date) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
        return "The extension reconnects about 30 s after NativeAgent starts (started \(clock.string(from: startedAt))); retry after \(clock.string(from: retryAfter))."
    }

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Chrome control is off in Trust Center."
        case .unavailable: return "Chrome control authority could not be verified."
        case .disconnected: return "The Chrome extension's connection to NativeAgent ended. raw view · Chrome native messaging transport; no page was read."
        case .extensionNotLoaded: return "No Chrome extension connection has been confirmed on this Mac. raw view · Chrome native messaging transport; extension installation is unverified."
        case .connectionUnavailable(let reason): return reason + " raw view · Chrome native messaging transport; no page was read."
        case .extensionReconnecting(let startedAt, let retryAfter):
            return Self.reconnectInstruction(startedAt: startedAt, retryAfter: retryAfter)
                + " raw view · Chrome native messaging reconnect alarm and app runtime start; no page was read."
        case .handshakeRejected(let reason): return "Chrome handshake rejected: \(reason)"
        case .invalidResponse: return "Chrome returned an invalid control response."
        case .requestTimedOut: return "Chrome did not answer before the control deadline."
        case .extensionRejected(let code, let message):
            // 09-24: the one next call, where there is one.
            let next: String = switch code {
            case "tab_not_owned": " browser.chrome_navigate{url} opens a new tab in the NativeAgent group."
            case "snapshot_stale", "node_stale": " The page changed since that read; nothing was done. Read the page again and act on its new rows."
            default: ""
            }
            return "Chrome refused the control request (\(code)): \(message)" + next
        case .outcomeUnknown(let action, let reason):
            return "Chrome did not confirm \(action) after dispatch. \(reason) The action may have completed; do not automatically repeat it. Observe the page before retrying."
        case .socketFailure(let code): return "Chrome control socket failed (errno \(code))."
        case .socketPathTooLong: return "Chrome control socket path is too long."
        case .relayUnavailable: return "The bundled NativeAgent Chrome relay is unavailable."
        case .unsafeSocketPath: return "Chrome control refused to replace a non-socket filesystem entry."
        case .conversationContext(let message): return message

        }
    }
}

public enum ChromeControlEffect: String, Sendable, CaseIterable {
    // Existing protocol greeting, used by the transport only; no new app action.
    case attach
    case reloadExtension = "extension.reload"
    case closeTab = "tab.close"
    case navigate
    case snapshot = "page.snapshot.read"
    case click = "page.element.click"
    case fill = "page.element.fill"
    case type = "page.element.type"
    case select = "page.element.select"
    case keypress = "page.element.keypress"
    case setChecked = "page.element.set_checked"
    case doubleClick = "page.element.double_click"
    case drag = "page.element.drag"
    case wait = "page.wait"
    case scroll = "page.scroll"
    case media = "page.media"

    var requiresEffectTimeAuthorization: Bool { self != .attach }

    var mayChangeExternalState: Bool {
        switch self {
        case .attach, .snapshot, .wait: false
        default: true
        }
    }

    var requiresDriver: Bool { mayChangeExternalState && self != .reloadExtension }

}

private final class ChromeSocketHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var shutDown = false
    /// 2026-09-06: frame writes run on a serial queue and can still be queued
    /// when the socket closes. They used to hold a FileHandle over THIS
    /// descriptor, so once it was closed and the number reused, a queued frame
    /// could land on an unrelated connection. The write side now has its own
    /// dup, handed out per write and closed by the write queue itself once
    /// every queued frame has run; a write that arrives after that is dropped
    /// rather than written to a descriptor number somebody else now owns.
    private var writeDescriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
        self.writeDescriptor = descriptor >= 0 ? Darwin.dup(descriptor) : -1
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0 && !shutDown
    }

    func fileHandle() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !shutDown else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }

    /// The write side's own descriptor. Nil once the write queue has closed it.
    func writeFileHandle() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard writeDescriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: false)
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !shutDown else { return }
        shutDown = true
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    /// The reader owns this descriptor until its last queued read returns.
    func closeReadSide() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Called only from the write queue, after the last queued frame.
    func closeWriteSide() {
        lock.lock()
        let fd = writeDescriptor
        writeDescriptor = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }
}

/// Cancellation and the write queue race for one dispatch decision. Once a
/// write starts, cancellation cannot establish whether Chrome applied it.
private final class ChromeRequestDispatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        started = true
        return true
    }

    /// Suppress an unstarted frame, returning whether dispatch already began.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        return started
    }
}

/// 2026-09-26: a blocking socket call (accept, recv) parks the thread it runs
/// on for as long as the peer stays quiet. On the Swift concurrency pool that
/// is a cooperative thread gone for good, and the pool is only ~CPU-count
/// wide. These calls run on a dedicated serial queue instead, which has its
/// own thread; the async loop around them is unchanged.
private func offPool<T: Sendable>(_ queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        queue.async { continuation.resume(returning: work()) }
    }
}

actor ChromeControlChannel {
    private struct Pending {
        let expectedAction: ChromeControlEffect
        let tabID: Int64?
        let targetReceipt: [String: JSONValue]
        let driver: MacDriverBinding?
        var continuation: CheckedContinuation<JSONValue, Error>?
        let timeout: Task<Void, Never>?
        let dispatch: ChromeRequestDispatch

        func unconfirmedFailure(_ error: Error) -> Error {
            let started = dispatch.cancel()
            guard started, expectedAction.mayChangeExternalState else { return error }
            return ChromeControlRuntimeError.outcomeUnknown(
                action: expectedAction.rawValue,
                reason: error.localizedDescription
            )
        }
    }

    private let socket: ChromeSocketHandle
    private let framer = NativeMessagingFramer()
    /// 2026-09-06: frame writes leave the actor. `FileHandle.write` on a
    /// blocking socket parks the whole actor when Chrome stops draining, and
    /// this request's own timeout and cancellation are actor-isolated — they
    /// could not run until the write that made them necessary returned. The
    /// queue is serial, so frames still reach the relay one whole frame at a
    /// time.
    private nonisolated let writeQueue = DispatchQueue(
        label: "com.nativeagent.chromecontrol.write"
    )
    let requestTimeout: Duration
    private let onReloadFailure: @Sendable (String, String) -> Void
    private var readTask: Task<Void, Never>?
    private var driverTask: Task<Void, Never>?
    private var actionDriver: MacDriverBinding?
    private var pending: [String: Pending] = [:]
    private var ownTabs: [Int64: [String: JSONValue]] = [:]
    private var pageSnapshots: [Int64: JSONValue] = [:]
    private var pageGenerations: [Int64: Int64] = [:]
    private let onCaptureFailure: @Sendable (Int64, String, Date) -> Void
    private struct PageObserver {
        let tabID: Int64
        let host: String
        let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    }
    private var pageObservers: [UUID: PageObserver] = [:]
    private var closed = false
    private let onDisconnect: @Sendable () -> Void

    init(descriptor: Int32, requestTimeout: Duration = .seconds(30),
         onReloadFailure: @escaping @Sendable (String, String) -> Void = { _, _ in },
         onCaptureFailure: @escaping @Sendable (Int64, String, Date) -> Void = { _, _, _ in },
         onDisconnect: @escaping @Sendable () -> Void = {}) {
        socket = ChromeSocketHandle(descriptor: descriptor)
        self.requestTimeout = requestTimeout
        self.onReloadFailure = onReloadFailure
        self.onCaptureFailure = onCaptureFailure
        self.onDisconnect = onDisconnect
    }

    func start() {
        guard !closed, readTask == nil, let handle = socket.fileHandle() else { return }
        driverTask = Task { [weak self] in
            let changes = await MacAttentionSessionStore.shared.driverChanges()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.yieldInvalidDriver()
            }
        }
        let framer = self.framer
        let socket = self.socket
        let readQueue = DispatchQueue(label: "com.nativeagent.chromecontrol.read", qos: .userInitiated)
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            defer { socket.closeReadSide() }
            do {
                while !Task.isCancelled, let data = try await offPool(readQueue, {
                    Result { try framer.readMessage(from: handle) }
                }).get() {
                    try framer.validateJSONObject(data)
                    await self?.receive(data)
                }
                await self?.connectionEnded(error: ChromeControlRuntimeError.disconnected)
            } catch {
                await self?.connectionEnded(error: error)
            }
        }
    }

    func request(action: ChromeControlEffect, payload: [String: JSONValue]) async throws -> JSONValue {
        // Her tab group moves none of his cursor, keys or screen: his input
        // never stops it; "let me take over" does, in every session (User, 10-04).
        if action.requiresDriver, MacDriverContext.binding?.allowsBackgroundEmission != true {
            return Self.driverTakeoverResult(action: action, payload: payload, dispatched: false)
        }
        yieldInvalidDriver()
        if action.requiresDriver { actionDriver = MacDriverContext.binding }
        guard !closed, socket.isOpen else {
            throw ChromeControlRuntimeError.disconnected
        }
        let id = UUID().uuidString.lowercased()
        let envelope = JSONValue.object([
            "version": .int(1),
            "type": .string("request"),
            "id": .string(id),
            "action": .string(action.rawValue),
            "payload": .object(payload),
        ])
        let data = try envelope.serializedData(pretty: false)
        let dispatch = ChromeRequestDispatch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self, requestTimeout] in
                    try? await Task.sleep(for: requestTimeout)
                    await self?.timeoutRequest(id)
                }
                pending[id] = Pending(
                    expectedAction: action,
                    tabID: { if case .int(let id)? = payload["tabId"] { id } else { nil } }(),
                    targetReceipt: payload.filter { ["snapshotId", "nodeId", "targetNodeId", "url", "tabId", "expectedUserSequence"].contains($0.key) },
                    driver: action.requiresDriver ? MacDriverContext.binding : nil,
                    continuation: continuation,
                    timeout: timeout,
                    dispatch: dispatch
                )
                enqueueWrite(data, dispatch: dispatch, driver: action.requiresDriver ? MacDriverContext.binding : nil) { [weak self] error in
                    Task { await self?.failWrite(id: id, error: error) }
                }
            }
        } onCancel: {
            // Invalidate synchronously: the actor may not service cancellation
            // before the serial socket queue reaches this frame.
            dispatch.cancel()
            Task { await self.cancelRequest(id) }
        }
    }

    func shutdown(error: Error = ChromeControlRuntimeError.disabled) {
        endPageObservers(error: error)
        guard !closed else { return }
        closed = true
        ownTabs.removeAll()
        closeSocket()
        readTask?.cancel(); readTask = nil
        driverTask?.cancel(); driverTask = nil
        failPending(error)
    }

    private func yieldInvalidDriver() {
        guard actionDriver?.handedBack == true else { return }
        actionDriver = nil
        for (id, row) in pending where row.driver?.handedBack == true {
            pending[id] = nil
            row.timeout?.cancel()
            if row.expectedAction.rawValue.hasPrefix("page.") { cancelPageAction(id) }
            row.continuation?.resume(returning: Self.driverTakeoverResult(
                action: row.expectedAction, payload: row.targetReceipt, dispatched: row.dispatch.cancel()))
        }
    }

    private static func driverTakeoverResult(
        action: ChromeControlEffect, payload: [String: JSONValue], dispatched: Bool
    ) -> JSONValue {
        .object(["result": .object(payload.merging([
            "status": .string("yielded_to_user"),
            "action": .string(action.rawValue),
            "tabId": payload["tabId"] ?? .null,
            "outcome": .string(dispatched && action.mayChangeExternalState ? "outcome_unknown" : "not_performed"),
            "message": .string(MacAttentionSessionStore.driverRefusal),
        ]) { _, new in new })])
    }

    func tabs() -> [Int64: [String: JSONValue]] { ownTabs }

    func existingPageAddress(host: String, tabID: Int64?) throws -> [String: JSONValue] {
        let matches = pageSnapshots.compactMap { id, snapshot -> (Int64, JSONValue)? in
            guard tabID == nil || tabID == id, ownTabs[id] != nil,
                  case .object(let fields) = snapshot, case .string(let url)? = fields["url"],
                  (host == "*" || URL(string: url)?.host?.lowercased() == host.lowercased()),
                  let sequence = fields["userSequence"] else { return nil }
            return (id, sequence)
        }
        guard matches.count == 1, let (id, sequence) = matches.first else {
            throw ChromeControlRuntimeError.conversationContext(matches.isEmpty
                ? "No Chrome snapshot of her tab is available for \(host)."
                : "More than one of her Chrome pages matches \(host); name the tab to read.")
        }
        return ["tab_id": .int(id), "expected_user_sequence": sequence]
    }

    func pageChanges(host: String, tabID: Int64) throws -> AsyncThrowingStream<JSONValue, Error> {
        guard ownTabs[tabID] != nil else {
            throw ChromeControlRuntimeError.conversationContext("The Chrome page observation needs one of her tabs.")
        }
        if host != "*" { _ = try existingPageAddress(host: host, tabID: tabID) }
        let id = UUID()
        let pair = AsyncThrowingStream<JSONValue, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pageObservers[id] = PageObserver(tabID: tabID, host: host.lowercased(), continuation: pair.continuation)
        if let snapshot = pageSnapshots[tabID] { pair.continuation.yield(snapshot) }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removePageObserver(id) } }
        return pair.stream
    }

    private func removePageObserver(_ id: UUID) { pageObservers.removeValue(forKey: id) }

    private func endPageObservers(tabID: Int64? = nil, error: Error) {
        for (id, observer) in pageObservers where tabID == nil || observer.tabID == tabID {
            observer.continuation.finish(throwing: error)
            pageObservers.removeValue(forKey: id)
        }
        if let tabID {
            pageSnapshots.removeValue(forKey: tabID); pageGenerations.removeValue(forKey: tabID)
        } else { pageSnapshots.removeAll(); pageGenerations.removeAll() }
    }

    private func receive(_ data: Data) {
        guard let value = try? JSONValue.parse(data),
              case .object(let object) = value,
              case .int(1)? = object["version"],
              case .string(let type)? = object["type"] else {
            connectionEnded(error: ChromeControlRuntimeError.invalidResponse)
            return
        }
        if type == "event" {
            applyEvent(object)
            return
        }
        guard type == "response", case .string(let id)? = object["id"],
              let row = pending[id] else { return }
        guard case .string(row.expectedAction.rawValue)? = object["action"],
              case .bool(let ok)? = object["ok"],
              (ok && object["result"] != nil && object["error"] == nil)
                || (!ok && object["result"] == nil && object["error"] != nil) else {
            // A response id alone is not proof that this is the effect we
            // dispatched. Close the channel so a mismatched/replayed envelope
            // cannot settle the wrong action or settle the wrong tab action.
            connectionEnded(error: ChromeControlRuntimeError.invalidResponse)
            return
        }
        pending.removeValue(forKey: id)
        row.timeout?.cancel()
        if !ok, row.driver?.handedBack == true {
            row.continuation?.resume(returning: Self.driverTakeoverResult(
                action: row.expectedAction, payload: row.targetReceipt, dispatched: true))
            yieldInvalidDriver()
            return
        }
        if ok {
            if row.driver?.handedBack == true {
                var receipt = row.targetReceipt
                if case .object(let result)? = object["result"] { receipt.merge(result) { _, new in new } }
                row.continuation?.resume(returning: Self.driverTakeoverResult(
                    action: row.expectedAction, payload: receipt, dispatched: true))
                yieldInvalidDriver()
                return
            }
            if case .object(let result)? = object["result"] {
                if row.expectedAction == .attach, case .array(let tabs)? = result["tabs"] {
                    ownTabs = Dictionary(tabs.compactMap { value -> (Int64, [String: JSONValue])? in
                        guard case .object(let tab) = value, case .int(let id)? = tab["tabId"] else { return nil }
                        return (id, tab)
                    }, uniquingKeysWith: { _, new in new })
                }
                if case .int(let tabID)? = result["tabId"] {
                    if row.expectedAction == .closeTab, result["tabClosed"] == .bool(true) {
                        ownTabs.removeValue(forKey: tabID)
                        endPageObservers(tabID: tabID, error: ChromeControlRuntimeError.conversationContext("The Chrome tab was closed."))
                    } else if (row.expectedAction == .navigate && result["outcome"] == .string("succeeded")) || ownTabs[tabID] != nil {
                        ownTabs[tabID] = (ownTabs[tabID] ?? [:]).merging(result) { _, new in new }
                        if row.expectedAction == .snapshot { pageSnapshots[tabID] = .object(result) }
                    }
                }
            }
            row.continuation?.resume(returning: value)
        } else {
            let code: String
            let message: String
            if case .object(let errorObject)? = object["error"],
               case .string(let detail)? = errorObject["message"] {
                message = detail
                if case .string(let value)? = errorObject["code"] {
                    code = value
                } else {
                    code = "extension_rejected"
                }
            } else {
                code = "extension_rejected"
                message = "Chrome control action failed."
            }
            if code == "tab_not_owned", let tabID = row.tabID {
                ownTabs.removeValue(forKey: tabID)
                endPageObservers(tabID: tabID, error: ChromeControlRuntimeError.extensionRejected(code: code, message: message))
                NotificationCenter.default.post(name: Notification.Name("NativeAgentChromeTabEnded"), object: nil,
                    userInfo: ["tabId": tabID, "closed": false])
            }
            if row.expectedAction == .snapshot, case .int(let tabID)? = row.targetReceipt["tabId"] {
                onCaptureFailure(tabID, "\(code): \(message)", Date())
            }
            row.continuation?.resume(throwing: ChromeControlRuntimeError.extensionRejected(
                code: code,
                message: message
            ))
        }
    }

    private func applyEvent(_ object: [String: JSONValue]) {
        if object["event"] == .string("extension.reload_failed"),
           case .object(let payload)? = object["payload"],
           case .string(let id)? = payload["reloadId"], id.utf8.count <= 128,
           case .string(let reason)? = payload["reason"], reason.utf8.count <= 4096 {
            onReloadFailure(id, reason)
            return
        }
        if object["event"] == .string("tabs.changed"), case .object(let payload)? = object["payload"],
           case .array(let values)? = payload["tabs"] {
            var projected: [Int64: [String: JSONValue]] = [:]
            for value in values {
                guard case .object(let tab) = value, case .int(let id)? = tab["tabId"], id >= 0,
                      case .int(let sequence)? = tab["userSequence"], sequence >= 0,
                      projected[id] == nil else { return }
                projected[id] = (ownTabs[id] ?? [:]).merging(tab) { _, new in new }
            }
            for id in ownTabs.keys where projected[id] == nil {
                endPageObservers(tabID: id, error: ChromeControlRuntimeError.extensionRejected(code: "tab_not_owned", message: "This tab is outside the NativeAgent group."))
                NotificationCenter.default.post(name: Notification.Name("NativeAgentChromeTabEnded"), object: nil,
                    userInfo: ["tabId": id, "closed": false])
            }
            ownTabs = projected
            return
        }
        guard case .string(let event)? = object["event"],
              case .object(let payload)? = object["payload"],
              case .int(let tabID)? = payload["tabId"] else { return }
        if event == "tab.yielded" || event == "tab.closed" {
            ownTabs.removeValue(forKey: tabID)
            NotificationCenter.default.post(name: Notification.Name("NativeAgentChromeTabEnded"), object: nil,
                userInfo: ["tabId": tabID, "closed": event == "tab.closed"])
            let reason: String = if case .string(let value)? = payload["reason"] { value } else { "tab_closed" }
            let message = switch reason {
            case "tab_closed": "The tab was closed."
            case "outside_group", "group_changed": "The tab left the NativeAgent group (\(reason))."
            default: "This tab is the person's own now (\(reason)); use another NativeAgent tab."
            }
            let error = ChromeControlRuntimeError.extensionRejected(code: "tab_not_owned", message: message)
            endPageObservers(tabID: tabID, error: error)
            for (id, row) in pending where row.tabID == tabID && row.expectedAction != .closeTab {
                pending.removeValue(forKey: id); row.timeout?.cancel()
                row.continuation?.resume(throwing: row.unconfirmedFailure(error))
            }
        } else if event == "page.changed" {
            guard let tab = ownTabs[tabID], payload["userSequence"] == tab["userSequence"],
                  case .int(let generation)? = payload["changeGeneration"], generation > (pageGenerations[tabID] ?? 0),
                  case .object(let snapshot)? = payload["snapshot"], snapshot["tabId"] == .int(tabID),
                  snapshot["userSequence"] == payload["userSequence"],
                  case .string? = snapshot["snapshotId"], case .array? = snapshot["nodes"],
                  case .string(let url)? = snapshot["url"], let host = URL(string: url)?.host?.lowercased() else { return }
            pageGenerations[tabID] = generation
            pageSnapshots[tabID] = .object(snapshot)
            for observer in pageObservers.values where observer.tabID == tabID {
                if observer.host == "*" || observer.host == host { observer.continuation.yield(.object(snapshot)) }
                else { observer.continuation.finish(throwing: ChromeControlRuntimeError.conversationContext("The Chrome page moved to another site.")) }
            }
        } else if event == "page.change_unavailable" {
            guard let tab = ownTabs[tabID], payload["userSequence"] == tab["userSequence"],
                  case .object(let failure)? = payload["error"], case .string(let code)? = failure["code"],
                  case .string(let message)? = failure["message"] else { return }
            onCaptureFailure(tabID, "\(code): \(message)", Date())
        }
    }

    /// Hand one frame to the serial write queue. The failure callback fires
    /// only when the write itself threw; a request already settled by timeout
    /// or cancellation no longer has a row and is left alone.
    private nonisolated func enqueueWrite(
        _ data: Data,
        dispatch: ChromeRequestDispatch? = nil,
        driver: MacDriverBinding? = nil,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        let framer = self.framer
        let socket = self.socket
        writeQueue.async {
            if let driver, driver.handedBack {
                onFailure(ChromeControlRuntimeError.conversationContext(MacAttentionSessionStore.driverRefusal))
                return
            }
            // The descriptor is taken here, on the queue, not when the write
            // was enqueued: after teardown there is none, and the frame is
            // dropped instead of written to a reused descriptor number.
            guard let handle = socket.writeFileHandle() else {
                onFailure(ChromeControlRuntimeError.disconnected)
                return
            }
            guard dispatch?.begin() != false else { return }
            do {
                try framer.writeMessage(data, to: handle)
            } catch {
                onFailure(error)
            }
        }
    }

    private func closeSocket() {
        let socket = self.socket
        socket.shutdown()
        if readTask == nil { socket.closeReadSide() }
        writeQueue.async { socket.closeWriteSide() }
    }

    private func failWrite(id: String, error: Error) {
        guard let row = pending.removeValue(forKey: id) else { return }
        row.timeout?.cancel()
        // FileHandle may report a write failure after a frame prefix or payload
        // reached the relay. For an effect, transport failure is therefore not
        // proof that Chrome did nothing and must not invite a blind retry.
        row.continuation?.resume(throwing: row.unconfirmedFailure(error))
    }

    private func timeoutRequest(_ id: String) {
        guard let row = pending.removeValue(forKey: id) else { return }
        row.timeout?.cancel()
        row.continuation?.resume(throwing: row.unconfirmedFailure(ChromeControlRuntimeError.requestTimedOut))
    }

    private func cancelPageAction(_ id: String) {
        let cancellation = JSONValue.object([
            "version": .int(1), "type": .string("event"), "event": .string("action.cancel"),
            "occurredAt": .string(ISO8601DateFormatter().string(from: Date())),
            "payload": .object(["requestId": .string(id)]),
        ])
        if let data = try? cancellation.serializedData(pretty: false) { enqueueWrite(data) { _ in } }
    }

    private func cancelRequest(_ id: String) {
        guard let row = pending.removeValue(forKey: id) else { return }
        row.timeout?.cancel()
        let started = row.dispatch.cancel()
        if started, row.expectedAction.rawValue.hasPrefix("page.") { cancelPageAction(id) }
        // Task cancellation remains cancellation, not proof that a dispatched
        // browser effect was rolled back or safe to repeat.
        if started, row.expectedAction.mayChangeExternalState {
            row.continuation?.resume(throwing: row.unconfirmedFailure(CancellationError()))
        } else {
            row.continuation?.resume(throwing: CancellationError())
        }
    }

    private func connectionEnded(error: Error) {
        guard !closed else { return }
        closed = true
        endPageObservers(error: error)
        ownTabs.removeAll()
        closeSocket()
        readTask?.cancel()
        readTask = nil
        driverTask?.cancel()
        driverTask = nil
        failPending(error)
        onDisconnect()
    }

    private func failPending(_ error: Error) {
        let rows = pending.values
        pending.removeAll()
        for row in rows {
            row.timeout?.cancel()
            row.continuation?.resume(throwing: row.unconfirmedFailure(error))
        }
    }
}

/// 2026-09-06: the control socket lives in a 0700 directory as a 0600 socket,
/// so only this Mac user can reach it — but every process running as that user
/// could, and acceptance authenticated nothing before handing the newcomer the
/// live channel. The app mints a per-launch secret, writes it
/// 0600 for the relay it registered, and requires it in the connection's first
/// frame. A caller that cannot present it is closed and never displaces the
/// channel Chrome is already using.
enum ChromeControlHandshake {
    static let tokenFilename = "chrome-control.token"
    /// 2026-09-06: a TOTAL deadline for the hello, measured on the wall clock
    /// across every read. It used to be an `SO_RCVTIMEO`, which bounds one
    /// `recv` — and the framer loops until the frame is complete, so a caller
    /// that dripped one byte before each timeout held the accept task, and with
    /// it every later connection, for as long as it liked.
    static let helloSeconds = 5

    static func tokenPath(forSocketPath socketPath: String) -> String {
        URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent()
            .appendingPathComponent(tokenFilename)
            .path
    }

    static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4)
            .map { _ in String(format: "%016lx", UInt64.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    static func writeToken(_ token: String, to path: String) throws {
        try Data(token.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// 2026-09-06: the 0600 token stops a stale or accidental caller, but any
    /// process running as this Mac user can read the file, so it cannot stop a
    /// same-UID takeover. A Unix socket has no peer credentials in the stream
    /// itself — but the kernel knows who dialed. `LOCAL_PEERPID` names the
    /// connecting process and `proc_pidpath` names its executable; the peer
    /// must be the relay binary this app registered. The token stays as the
    /// second factor. No peer pid means no proof, and we fail closed.
    static func peerProcessID(descriptor: Int32) -> pid_t? {
        var pid: pid_t = -1
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              pid > 0 else { return nil }
        return pid
    }

    /// The whole proof for one accepted connection, run on the accept task.
    ///
    /// `expecting` is a set of already symlink-resolved executable paths. An
    /// empty set means this launch registered no relay of its own (the
    /// hermetic/unbundled lane), and the token alone governs.
    ///
    /// Order matters. The peer's executable is settled first: it costs one
    /// getsockopt and needs no cooperation from the caller, so an impostor
    /// never gets to hold the accept task for the hello's whole budget.
    static func validateConnection(
        descriptor: Int32, expecting: Set<String>, token: String
    ) throws {
        guard !expecting.isEmpty else {
            _ = try readHello(descriptor: descriptor, token: token)
            return
        }
        guard let pid = peerProcessID(descriptor: descriptor),
              let peer = ChromeHostIdentity.executablePath(ofProcess: pid) else {
            nativeLog("[NativeAgent] Chrome control refused a connection with no readable peer pid.")
            throw ChromeControlRuntimeError.handshakeRejected("the relay's peer process identity could not be read.")
        }
        let resolved = URL(fileURLWithPath: peer).resolvingSymlinksInPath().path
        guard expecting.contains(resolved) else {
            nativeLog("[NativeAgent] Chrome control refused a connection from an unexpected peer executable.")
            throw ChromeControlRuntimeError.handshakeRejected("the peer executable is not the registered relay.")
        }
        // 2026-09-06: a path is replaceable. Require the running relay to carry
        // this app's designated signer constraint, including when its parent exited.
        guard ChromeSocketIdentity.peerIsTrusted(
            descriptor: descriptor, identifiers: ["NativeAgentChromeRelay"]
        ) else {
            nativeLog("[NativeAgent] Chrome control refused a relay with an unexpected code identity.")
            throw ChromeControlRuntimeError.handshakeRejected("the relay's code identity does not match NativeAgent.")
        }
        guard let parent = ChromeHostIdentity.parentProcessID(of: pid) else {
            nativeLog("[NativeAgent] Chrome control refused a relay whose parent could not be read.")
            throw ChromeControlRuntimeError.handshakeRejected("the relay's parent process could not be read.")
        }
        // 2026-09-06: being the right EXECUTABLE is not being the right
        // process. The relay is a native messaging host — Chrome launches it —
        // so a relay whose parent is not a browser was launched by something
        // that wants the channel, not by Chrome. The relay refuses to start in
        // that case; this is the app's own half, so the fence holds even
        // against a relay binary that has been swapped for one that does not.
        let parentIsBrowser = ChromeHostIdentity.isBrowserProcess(parent)
        // 2026-09-06: a live parent check is right only while the browser is
        // still alive. Chrome can quit or restart while the host it launched is
        // still pumping, and the relay is then reparented to launchd (pid 1) —
        // a legitimate connection that the check above refuses. That case falls
        // back to what the relay proved at launch, and nothing else does; it is
        // settled here, before the hello is read, so a caller that can never
        // pass holds the accept task no longer than it did before.
        guard parentIsBrowser || parent == 1 else {
            nativeLog("[NativeAgent] Chrome control refused a relay whose parent is not a browser.")
            throw ChromeControlRuntimeError.handshakeRejected("the relay was not launched by a signed browser.")
        }
        let hello = try readHello(descriptor: descriptor, token: token)
        if parentIsBrowser { return }
        // The fallback admits only a peer that is already this app's registered
        // relay AND whose running code matches this app's signer: that binary
        // refuses to start unless a signed browser launched it, so its account
        // of its own parent is worth something. A relay swapped for one that
        // reports whatever it likes fails the signature check.
        guard helloCarriesParentEvidence(hello) else {
            nativeLog("[NativeAgent] Chrome control refused a reparented relay with no launch-time parent evidence.")
            throw ChromeControlRuntimeError.handshakeRejected("the reparented relay has no valid launch-time browser evidence.")
        }
    }

    private static func helloCarriesParentEvidence(_ hello: [String: JSONValue]) -> Bool {
        var processID: Int?
        if case .int(let value)? = hello[ChromeHostIdentity.ParentEvidence.processIDField] {
            processID = Int(value)
        }
        var validatedAt: Double?
        switch hello[ChromeHostIdentity.ParentEvidence.validatedAtField] {
        case .double(let value): validatedAt = value
        case .int(let value): validatedAt = Double(value)
        default: break
        }
        var bundleIdentifier: String?
        if case .string(let value)? = hello[ChromeHostIdentity.ParentEvidence.bundleIDField] {
            bundleIdentifier = value
        }
        return ChromeHostIdentity.ParentEvidence.isWellFormed(
            bundleIdentifier: bundleIdentifier, processID: processID, validatedAt: validatedAt
        )
    }

    /// The app's half of the greeting, written on the accept task once the
    /// connection is proven and about to be installed.
    ///
    /// 2026-09-06: a refusal used to be indistinguishable from a clean
    /// disconnect — the app simply closed the socket — so a relay that read the
    /// token, then dialled an app that had relaunched in between, presented a
    /// secret the new listener never minted and reported nothing at all. An ack
    /// makes acceptance positively observable, and carrying the listener
    /// generation says WHICH listener accepted, so the far side can tell a
    /// reconnect from the connection it already had.
    static func helloAckFrame(generation: UInt64) -> Data? {
        guard let payload = try? JSONSerialization.data(
            withJSONObject: ["version": 1, "type": "hello_ack", "generation": String(generation)],
            options: [.sortedKeys]
        ) else { return nil }
        return try? NativeMessagingFramer().encode(payload)
    }

    /// Raw `send` for the same reason the hello read uses raw `recv`: this runs
    /// before the channel owns the descriptor, and a FileHandle write on a
    /// socket the peer has already dropped raises rather than returning an
    /// error. A failure here is not fatal — the connection is still proven, and
    /// a relay that never sees the ack redials.
    @discardableResult
    static func sendHelloAck(descriptor: Int32, generation: UInt64) -> Bool {
        guard let frame = helloAckFrame(generation: generation) else { return false }
        return frame.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let written = Darwin.send(descriptor, base.advanced(by: sent), raw.count - sent, 0)
                guard written > 0 else { return false }
                sent += written
            }
            return true
        }
    }

    /// Reads the connection's first frame on the accept task, off the runtime
    /// actor, using raw recv so a timed-out socket can never raise out of
    /// FileHandle. Anything but this launch's hello is a refusal; a hello that
    /// presents the secret is returned whole, because it also carries what the
    /// relay proved about its parent at launch.
    static func readHello(descriptor: Int32, token: String) throws -> [String: JSONValue] {
        let deadline = Date().addingTimeInterval(TimeInterval(helloSeconds))
        defer {
            var none = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(
                descriptor, SOL_SOCKET, SO_RCVTIMEO,
                &none, socklen_t(MemoryLayout<timeval>.size)
            )
        }
        let framer = NativeMessagingFramer()
        let hello: Data?
        var readFailure: String?
        do {
            hello = try framer.readMessage { count in
                // Each read gets only what is left of the whole hello's budget,
                // so a dripped byte cannot hold the accept queue indefinitely.
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0.001 else {
                    readFailure = "the relay greeting did not complete within the authentication deadline."
                    return Data()
                }
                var window = timeval(
                    tv_sec: Int(remaining),
                    tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000)
                )
                setsockopt(
                    descriptor, SOL_SOCKET, SO_RCVTIMEO,
                    &window, socklen_t(MemoryLayout<timeval>.size)
                )
                var buffer = [UInt8](repeating: 0, count: count)
                let received = buffer.withUnsafeMutableBytes { raw -> Int in
                    Darwin.recv(descriptor, raw.baseAddress, count, 0)
                }
                guard received > 0 else {
                    readFailure = received == 0 ? "the relay closed before completing its greeting."
                        : "the relay greeting socket read failed (errno \(errno))."
                    return Data()
                }
                return Data(buffer.prefix(received))
            }
        } catch {
            throw ChromeControlRuntimeError.handshakeRejected(readFailure ?? "the relay greeting could not be read: \(error.localizedDescription)")
        }
        guard let hello else {
            throw ChromeControlRuntimeError.handshakeRejected(readFailure ?? "the relay closed before sending its greeting.")
        }
        guard let value = try? JSONValue.parse(hello), case .object(let object) = value else {
            throw ChromeControlRuntimeError.handshakeRejected("the relay greeting is not a JSON object.")
        }
        guard case .int(1)? = object["version"],
              case .string("hello")? = object["type"]
        else { throw ChromeControlRuntimeError.handshakeRejected("the relay greeting has an unsupported protocol version or type.") }
        guard case .string(let presented)? = object["token"], !token.isEmpty, presented == token else {
            throw ChromeControlRuntimeError.handshakeRejected("the relay greeting does not carry this listener's credential.")
        }
        return object
    }
}

public enum ChromeControlConnectionState: Sendable, Equatable {
    case extensionNotLoaded, disconnected, connected

    public func status(enabled: Bool) -> String {
        guard enabled else { return "Chrome control is off" }
        switch self {
        case .extensionNotLoaded: return "On, but no Chrome extension connection has been confirmed yet — press Set up Chrome"
        case .disconnected: return "On, previously connected; Chrome is not connected right now"
        case .connected: return "Connected"
        }
    }
}

/// Chrome records the unpacked folder, rather than the native-host installer.
/// Read that exact manifest as well as the app's shipped manifest; never infer
/// a folder from a checkout name or substitute a version literal.
private struct ChromeExtensionFiles {
    let path: String
    let diskVersion: String
    let shippedVersion: String

    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), (0...65535).contains(number) else { return nil }
            result.append(number)
        }
        return result + Array(repeating: 0, count: 4 - result.count)
    }

    static func isOlder(_ version: String, than other: String) -> Bool {
        guard let left = components(version), let right = components(other) else { return false }
        return left.lexicographicallyPrecedes(right)
    }

    static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome extension files unavailable: invalid JSON object at \(url.path).")
        }
        return value
    }

    static func version(_ object: [String: Any], path: String) throws -> String {
        guard let value = object["version"] as? String, components(value) != nil else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome extension files unavailable: invalid manifest version at \(path).")
        }
        return value
    }

    static func read() throws -> Self {
        guard let resources = Bundle.main.resourceURL else {
            throw ChromeControlRuntimeError.connectionUnavailable("NativeAgent's shipped Chrome manifest is unavailable.")
        }
        let bundledURL = resources.appendingPathComponent("NativeAgentChrome/manifest.json")
        let bundled = try object(bundledURL)
        let shippedVersion = try version(bundled, path: bundledURL.path)
        guard let key = bundled["key"] as? String, let bytes = Data(base64Encoded: key) else {
            throw ChromeControlRuntimeError.connectionUnavailable("NativeAgent's shipped Chrome manifest has no valid extension identity key.")
        }
        // Chrome's extension id is the first 128 bits of the public key's SHA256,
        // encoded a-p. It is stable across the bundle and unpacked copies.
        let alphabet = Array("abcdefghijklmnop")
        let id = SHA256.hash(data: bytes).prefix(16).map {
            String(alphabet[Int($0 >> 4)]) + String(alphabet[Int($0 & 15)])
        }.joined()
        let root = InstallPaths.current.chromeManifest.deletingLastPathComponent().deletingLastPathComponent()
        let state = try object(root.appendingPathComponent("Local State"))
        guard let profile = state["profile"] as? [String: Any], let profiles = profile["info_cache"] as? [String: Any] else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome's profile inventory is unavailable at \(root.path).")
        }
        var paths = Set<String>()
        for name in profiles.keys.sorted() {
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                throw ChromeControlRuntimeError.connectionUnavailable("Chrome's profile inventory contains an invalid folder.")
            }
            let profileURL = root.appendingPathComponent(name, isDirectory: true)
            // These are Chrome's two preference stores, not alternate guesses.
            // Inspect both; contradictory paths are unavailable, never selected.
            for filename in ["Preferences", "Secure Preferences"] {
                let url = profileURL.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let prefs = try object(url)
                guard let extensions = prefs["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any],
                      let entry = settings[id] as? [String: Any] else { continue }
                guard let path = entry["path"] as? String, path.hasPrefix("/") else {
                    throw ChromeControlRuntimeError.connectionUnavailable("Chrome's registered extension folder is not an absolute unpacked path (\(url.path)).")
                }
                paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        guard paths.count == 1, let path = paths.first else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome's registered extension folder is \(paths.isEmpty ? "missing" : "ambiguous: " + paths.sorted().joined(separator: ", ")).")
        }
        let manifestURL = URL(fileURLWithPath: path).appendingPathComponent("manifest.json")
        let manifest = try object(manifestURL)
        guard manifest["key"] as? String == key else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome's extension manifest identity differs from NativeAgent's at \(path).")
        }
        return Self(path: path, diskVersion: try version(manifest, path: manifestURL.path), shippedVersion: shippedVersion)
    }
}

/// Historical observations only. Never used as connection or permission proof.
private struct ChromeConnectionFacts: Codable {
    var extensionReload: JSONValue?
    var extensionReloadAt: Date?
    var relayConnectedAt: Date?
    var extensionVersion: String?
    var extensionSeenAt: Date?
    var handshakeAt: Date?
    var handshakeResult: String?
    var handshakeReason: String?
    var extensionError: String?
    var extensionErrorAt: String?
}

private final class ChromeBrowserLaunchObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    @MainActor init(onLaunch: @escaping @Sendable (pid_t) -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.google.Chrome", !app.isTerminated else { return }
            onLaunch(app.processIdentifier)
        }
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(token) }
}

public actor ChromeControlRuntime {
    public typealias Authority = @Sendable () async -> Bool
    public enum ReloadSource: String, Sendable, Codable { case automatic, manual, verb }

    private let authority: Authority
    private let socketPath: String
    private let manageNativeHostRegistration: Bool
    private var listenerDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var channel: ChromeControlChannel?
    private var connectingChannel: ChromeControlChannel?
    private var extensionCanReload = false
    private var extensionHasTabProtocol = false
    private var readyChannel: ChromeControlChannel? { extensionHasTabProtocol ? channel : nil }
    private var extensionHasConnected: Bool
    private var extensionConnectedThisRun = false
    private let runtimeStartedAt = Date()
    private var listenerStartedAt: Date?
    private var listenerFailure: String?
    private var facts = ChromeConnectionFacts()
    private var factsStorageError: String?
    private var handshakeAt: Date?
    private let signatureFailureNote: @Sendable (String, String) async throws -> Void
    private var browserLaunchObserver: ChromeBrowserLaunchObserver?
    private var observingBrowserLaunches = false
    private var signatureFailureNoted = false
    private var signatureFailures: [pid_t: ChromeRelayRefusal] = [:]
    private var publishedConnectionState: ChromeControlConnectionState?
    private var captureErrors: [String: JSONValue] = [:]
    private var conversationTabs: [String: ChromeConversationTab] = [:]
    private let conversationTabsURL: URL
    private var rememberedTabIDs: [String: Int64] = [:]
    private var conversationTabsStorageError: String?
    private var groupTabs: [Int64: ChromeConversationTab] = [:]
    private var busyConversations: Set<String> = []
    private var connectionObservers: [UUID: AsyncStream<ChromeControlConnectionState>.Continuation] = [:]
    private var extensionFiles: ChromeExtensionFiles?
    private var extensionFilesError: String?
    private var connectedBrowserPID: pid_t?
    private var automaticReloadPairs: Set<String> = []
    fileprivate struct ExtensionReloadAttempt: Codable {
        let id: String
        let source: ReloadSource
        let before: String
        let shipped: String
        let path: String
        let browserPID: pid_t
        let browserBirthStamp: UInt64
        let startedAt: Date
        var phase = "sending"
        var after: String?
        var completedAt: Date?
        var reason: String?
        var pending: Bool { phase == "sending" || phase == "awaiting_reconnect" || phase == "awaiting_chrome_reload" }
        var receipt: JSONValue { .object([
            "id": .string(id), "action": .string("chrome.reload_extension"),
            "source": .string(source.rawValue),
            "front_app_changed": .bool(false), "focus_changed": .bool(false),
            "status": .string(phase), "before_version": .string(before),
            "after_version": after.map(JSONValue.string) ?? .null,
            "shipped_version": .string(shipped), "extension_path": .string(path),
            "started_at": ChromeControlRuntime.dateJSON(startedAt),
            "completed_at": ChromeControlRuntime.dateJSON(completedAt),
            "reason": reason.map(JSONValue.string) ?? .null,
            "provenance": .string(phase == "awaiting_chrome_reload"
                ? "raw view · accepted legacy Chrome greeting and updated registered manifest; no reload was dispatched and no page snapshot was read."
                : "raw view · Chrome native messaging reload transport and accepted reconnect version; no page snapshot was read."),
        ]) }
    }
    private var extensionReload: ExtensionReloadAttempt?
    private var reloadPreflightFailure: JSONValue?
    private var reloadWaiters: [UUID: CheckedContinuation<JSONValue, Error>] = [:]

    private var currentReloadReceipt: JSONValue {
        if extensionReload?.pending == true { return extensionReload!.receipt }
        let latest = reloadPreflightFailure ?? extensionReload?.receipt ?? facts.extensionReload
        if readyChannel != nil, let files = extensionFiles, facts.extensionVersion == files.shippedVersion {
            if case .object(let receipt)? = latest, receipt["status"] == .string("succeeded"),
               receipt["after_version"] == .string(files.shippedVersion) { return .object(receipt) }
            // A newer failed read/explicit preflight is still current. Only an
            // accepted greeting after the failure supersedes its receipt.
            if case .object(let receipt)? = latest, receipt["status"] == .string("failed"),
               let completed = facts.extensionReloadAt, let seen = facts.extensionSeenAt,
               completed >= seen {
                return .object(receipt)
            }
            return .object([
                "status": .string("matched"), "running_version": .string(files.shippedVersion),
                "shipped_version": .string(files.shippedVersion),
                "reason": .string("The accepted extension is running the shipped version."),
                "provenance": .string("raw view · accepted Chrome extension greeting and shipped manifest; previous reload attempts are last-seen history."),
            ])
        }
        return latest ?? .null
    }

    private func readExtensionFiles() {
        do {
            extensionFiles = try ChromeExtensionFiles.read()
            extensionFilesError = nil
        } catch {
            extensionFiles = nil
            extensionFilesError = "Chrome extension version check failed: \(error.localizedDescription)"
        }
    }

    /// The explicit reversible verb can retry a failed/stale automatic attempt.
    /// Completion follows accepted attach, never an elapsed reconnect timer.
    public func reloadExtension(source: ReloadSource = .manual) async throws -> JSONValue {
        guard await authority() else { throw ChromeControlRuntimeError.disabled }
        if extensionReload?.pending == true {
            let browsers = await Self.runningChromeProcesses()
            reconcileReloadBrowser(browsers)
        }
        if extensionReload?.pending != true {
            readExtensionFiles()
            do {
                guard let channel else { throw await connectionFailure() }
                try await beginExtensionReload(on: channel, source: source)
            } catch {
                return recordReloadPreflightFailure(error, source: source)
            }
        }
        if extensionReload?.phase == "awaiting_chrome_reload" { return extensionReload!.receipt }
        if extensionReload?.pending != true { return extensionReload!.receipt }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if extensionReload?.pending != true { continuation.resume(returning: extensionReload!.receipt) }
                else { reloadWaiters[waiter] = continuation }
            }
        } onCancel: {
            Task { await self.cancelReloadWaiter(waiter) }
        }
    }

    private func cancelReloadWaiter(_ id: UUID) {
        reloadWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func recordReloadPreflightFailure(_ error: Error, source: ReloadSource) -> JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string("chrome.reload_extension"), "status": .string("failed"),
            "source": .string(source.rawValue), "effects": .string("none"),
            "front_app_changed": .bool(false), "focus_changed": .bool(false),
            "dispatched": .bool(false), "before_version": facts.extensionVersion.map(JSONValue.string) ?? .null,
            "after_version": .null, "shipped_version": extensionFiles.map { .string($0.shippedVersion) } ?? .null,
            "extension_path": extensionFiles.map { .string($0.path) } ?? .null,
            "completed_at": Self.dateJSON(Date()),
            "reason": .string("Extension reload unavailable: \(error.localizedDescription). Call chrome.reload_extension after resolving this reason; no automatic retry."),
            "provenance": .string("raw view · Chrome reload preflight, native connection and registered unpacked manifest; no reload was dispatched and no page was read."),
        ]
        if case ChromeControlRuntimeError.extensionReconnecting(_, let retryAfter) = error,
           let instruction = (error as? ChromeControlRuntimeError)?.recoverySuggestion {
            fields["remedy"] = .object([
                "kind": .string("wait"), "instruction": .string(instruction),
                "retry_after": Self.dateJSON(retryAfter), "next_call": .null,
            ])
        }
        let receipt = JSONValue.object(fields)
        reloadPreflightFailure = receipt
        facts.extensionReload = receipt
        facts.extensionReloadAt = Date()
        saveConnectionFacts()
        return receipt
    }

    private func extensionReloadFailed(id: String, reason: String) {
        guard extensionReload?.id == id else { return }
        finishExtensionReload(phase: "failed", reason: "Extension reload failed: \(reason). Call chrome.reload_extension to try explicitly; no automatic retry.")
    }

    private func finishExtensionReload(phase: String, after: String? = nil, reason: String? = nil) {
        guard var attempt = extensionReload, attempt.pending else { return }
        attempt.phase = phase
        attempt.after = after
        attempt.reason = reason
        attempt.completedAt = Date()
        extensionReload = attempt
        facts.extensionReload = attempt.receipt
        facts.extensionReloadAt = attempt.completedAt
        saveConnectionFacts()
        let waiters = reloadWaiters.values
        reloadWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: attempt.receipt) }
    }

    private func beginExtensionReload(on connection: ChromeControlChannel, source: ReloadSource) async throws {
        guard let files = extensionFiles, let before = facts.extensionVersion,
              let pid = connectedBrowserPID, pid > 1,
              let birthStamp = ChromeHostIdentity.processBirthStamp(pid) else {
            throw ChromeControlRuntimeError.connectionUnavailable(extensionFilesError
                ?? "The accepted Chrome connection has no live browser process identity for an extension reload.")
        }
        let id = UUID().uuidString.lowercased()
        reloadPreflightFailure = nil
        extensionReload = ExtensionReloadAttempt(id: id, source: source, before: before, shipped: files.shippedVersion,
            path: files.path, browserPID: pid, browserBirthStamp: birthStamp, startedAt: Date())
        automaticReloadPairs.insert(files.shippedVersion + "/" + before)
        if !extensionCanReload {
            guard files.diskVersion == files.shippedVersion else {
                finishExtensionReload(phase: "failed", reason: "The registered extension folder at \(files.path) still contains \(files.diskVersion); update it to \(files.shippedVersion) before Chrome can reload it.")
                return
            }
            extensionReload?.phase = "awaiting_chrome_reload"
            extensionReload?.reason = "Open chrome://extensions in Google Chrome, find NativeAgent, and click Reload. The updated files are at \(files.path). Chrome control will be ready when extension \(files.shippedVersion) reconnects."
            facts.extensionReload = extensionReload?.receipt
            saveConnectionFacts()
            return
        }
        // A reload drops this connection before the extension reconnects. One
        // request deadline after dispatch with no reconnect, the wait ends.
        defer {
            if extensionReload?.id == id, extensionReload?.phase == "awaiting_reconnect" {
                Task { [weak self, requestTimeout = connection.requestTimeout] in
                    try? await Task.sleep(for: requestTimeout)
                    await self?.reconnectOverdue(id)
                }
            }
        }
        do {
            let response = try await connection.request(action: .reloadExtension, payload: ["reloadId": .string(id)])
            guard case .object(let envelope) = response, case .object(let result)? = envelope["result"],
                  result["reloadId"] == .string(id), result["beforeVersion"] == .string(before),
                  result["status"] == .string("acknowledged") else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            if extensionReload?.id == id, extensionReload?.pending == true {
                extensionReload?.phase = "awaiting_reconnect"
                extensionReload?.reason = "Reload acknowledged; awaiting the extension's accepted reconnect."
                facts.extensionReload = extensionReload?.receipt
                saveConnectionFacts()
            }
        } catch {
            if extensionReload?.id == id {
                if case ChromeControlRuntimeError.outcomeUnknown = error, extensionReload?.pending == true {
                    // A dispatched reload can still be progressing after its
                    // acknowledgement is lost or the caller cancels. Preserve
                    // the exact handoff until a factual reconnect/termination.
                    extensionReload?.phase = "awaiting_reconnect"
                    extensionReload?.reason = "Reload dispatch is unconfirmed: \(error.localizedDescription). Awaiting an accepted reconnect; no automatic retry."
                    // The pre-dispatch record already preserves this exact
                    // process and ID even if another storage write fails.
                    facts.extensionReload = extensionReload?.receipt
                    saveConnectionFacts()
                } else {
                    finishExtensionReload(phase: "failed", reason: "Extension reload failed: \(error.localizedDescription). Call chrome.reload_extension to try explicitly; no automatic retry.")
                }
            }
        }
    }

    private func reconnectOverdue(_ id: String) {
        guard extensionReload?.id == id, extensionReload?.phase == "awaiting_reconnect" else { return }
        finishExtensionReload(phase: "unconfirmed", reason: "The extension did not reconnect after the reload; its effect is unknown. Check chrome.status; no automatic retry.")
    }

    private var connectionState: ChromeControlConnectionState {
        readyChannel != nil ? .connected : (extensionHasConnected ? .disconnected : .extensionNotLoaded)
    }

    public func connectionStates() -> AsyncStream<ChromeControlConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChromeControlConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connectionObservers[id] = continuation
        continuation.yield(connectionState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeConnectionObserver(id) }
        }
        return stream
    }

    public func setupConnectionStatus() async -> (state: ChromeControlConnectionState, enabled: Bool, diagnostics: [String: JSONValue]) {
        let enabled = await transportAvailable()
        let browsers = await Self.runningChromeProcesses()
        readExtensionFiles()
        reconcileReloadBrowser(browsers)
        return (connectionState, enabled, connectionDiagnostics(browsers: browsers))
    }

    public func recordCaptureError(_ reason: String, tabID: Int64, at: Date = Date()) {
        captureErrors[String(tabID)] = .object([
            "error": .string(ContextSecretContentPolicy.redactedFragment(reason)), "at": Self.dateJSON(at),
            "provenance": .string("raw view · Chrome capture failure; no page news was produced"),
        ])
    }

    private func refreshGroupTabs() async {
        guard let channel = readyChannel else { return }
        let rows = await channel.tabs()
        groupTabs = rows.compactMapValues { row in
            guard case .int(let id)? = row["tabId"] else { return nil }
            return ChromeConversationTab(result: row, previous: groupTabs[id])
        }
        conversationTabs = rememberedTabIDs.compactMapValues { groupTabs[$0] }
    }

    private func rememberTab(_ id: Int64, session: String) {
        guard NativeAgentChatSessionID.isSafePathComponent(session) else { return }
        rememberedTabIDs[session] = id
        do {
            try FileManager.default.createDirectory(at: conversationTabsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(rememberedTabIDs), to: conversationTabsURL)
            conversationTabsStorageError = nil
        } catch { conversationTabsStorageError = "Chrome conversation tab IDs could not be saved: \(error.localizedDescription)" }
    }

    public func conversationTabStatus(_ verifiedSessionID: String?) async -> [String: JSONValue] {
        await refreshGroupTabs()
        let current = verifiedSessionID.flatMap { conversationTabs[$0]?.tabID }
        let tabs = groupTabs.keys.sorted().compactMap { id -> JSONValue? in
            guard let tab = groupTabs[id] else { return nil }
            return .object(["tab_id": .int(id), "title": tab.title.map(JSONValue.string) ?? .null,
                "url": tab.url.map(JSONValue.string) ?? .null, "current": .bool(id == current),
                "audible": tab.audible, "mutedInfo": tab.mutedInfo,
                "last_capture_error": captureErrors[String(id)] ?? .null])
        }
        var result: [String: JSONValue] = ["tabs": .array(tabs), "extension_connected": .bool(readyChannel != nil)]
        if let conversationTabsStorageError { result["tab_memory_error"] = .string(conversationTabsStorageError) }
        return result
    }

    private func reconcileReloadBrowser(_ browsers: [pid_t]) {
        if let attempt = extensionReload, attempt.pending,
           !browsers.contains(attempt.browserPID) || ChromeHostIdentity.processBirthStamp(attempt.browserPID) != attempt.browserBirthStamp {
            finishExtensionReload(phase: "failed", reason: "Chrome's browser process ended before the extension's reload could be verified. Call chrome.reload_extension after Chrome reconnects.")
        }
    }

    /// Inspect local owners; never launch Chrome, connect a host or change Trust.
    private func connectionDiagnostics(browsers: [pid_t]) -> [String: JSONValue] {
        let running = !browsers.isEmpty
        let refusal = relayRefusal()
        let currentRefusal = currentRefusal(refusal.record, browsers: browsers)
        let reload = currentReloadReceipt
        var diagnostics: [String: JSONValue] = [
            "app_listener_up": .bool(listenerDescriptor >= 0),
            "runtime_started_at": Self.dateJSON(runtimeStartedAt),
            "listener_started_at": Self.dateJSON(listenerStartedAt),
            "app_listener_error": listenerFailure.map(JSONValue.string) ?? .null,
            "chrome_running": .bool(running),
            "relay_last_connected_at": Self.dateJSON(facts.relayConnectedAt),
            "extension_version_last_seen": facts.extensionVersion.map(JSONValue.string) ?? .null,
            "extension_running_version": channel != nil ? facts.extensionVersion.map(JSONValue.string) ?? .null : .null,
            "extension_shipped_version": extensionFiles.map { .string($0.shippedVersion) } ?? .null,
            "extension_files_version": extensionFiles.map { .string($0.diskVersion) } ?? .null,
            "extension_path": extensionFiles.map { .string($0.path) } ?? .null,
            "extension_version_check_error": extensionFilesError.map(JSONValue.string) ?? .null,
            "extension_reload": reload,
            "extension_reload_last_seen": facts.extensionReload ?? .null,
            "extension_version_note": extensionVersionNote.map(JSONValue.string) ?? .null,
            "extension_last_seen_at": Self.dateJSON(facts.extensionSeenAt),
            "extension_connected_since_runtime_start": .bool(extensionConnectedThisRun),
            "relay_connected": .bool(channel != nil || connectingChannel != nil),
            "handshake_result": .string(channel != nil ? (extensionHasTabProtocol ? "accepted" : "extension_upgrade_required") : connectingChannel != nil ? "extension_attach_pending" : "not_connected"),
            "handshake_at": channel != nil || connectingChannel != nil ? Self.dateJSON(handshakeAt) : .null,
            "handshake_reason": .null,
            "last_handshake_result": facts.handshakeResult.map(JSONValue.string) ?? .null,
            "last_handshake_at": Self.dateJSON(facts.handshakeAt),
            "last_handshake_reason": facts.handshakeReason.map { .string("last seen handshake rejection: " + $0) } ?? .null,
            "diagnostic_storage_error": factsStorageError.map(JSONValue.string) ?? .null,
            "relay_refusal_storage_error": refusal.error.map(JSONValue.string) ?? .null,
            "relay_refusal_current": .bool(currentRefusal != nil),
            "relay_refusal_check": currentRefusal.map { .string($0.check) } ?? .null,
            "relay_refusal_os_status": currentRefusal?.osStatus.map { .int(Int64($0)) } ?? .null,
            "relay_refusal_reason": currentRefusal.map { .string($0.reason) } ?? .null,
            "last_relay_refusal_reason": refusal.record.map { .string("last seen relay refusal: " + $0.reason) } ?? .null,
            "last_relay_refusal_at": Self.dateJSON(refusal.record?.recordedAt),
            "last_extension_error": facts.extensionError.map { .string("last extension error: " + $0) } ?? .null,
            "last_extension_error_at": facts.extensionErrorAt.map(JSONValue.string) ?? .null,
            "down_side": readyChannel != nil ? .null : .string(downSide(chromeRunning: running, refusal: currentRefusal)),
            "connection_note": readyChannel != nil ? .string("The app accepted the relay and confirmed the extension's protocol greeting.")
                : .string(disconnectionReason(chromeRunning: running, refusal: currentRefusal)),
            "provenance": .string("raw view · Chrome native messaging transport, registered unpacked and bundled manifests, Chrome profile preferences, app listener, macOS running-application inventory and running-code signature validation; last-seen facts are historical observations."),
        ]
        if reload != .null, reload == facts.extensionReload {
            diagnostics.removeValue(forKey: "extension_reload_last_seen")
            diagnostics["extension_reload_is_current"] = .bool(true)
        }
        return diagnostics
    }

    private var extensionVersionNote: String? {
        guard let files = extensionFiles, let running = facts.extensionVersion, channel != nil else { return extensionFilesError }
        return "Chrome is running extension \(running) from \(files.path); NativeAgent ships \(files.shippedVersion)"
    }

    @MainActor private static func runningChromeProcesses() -> [pid_t] {
        // Exact Chrome bundle identity from macOS, never inferred from a socket.
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated }.map(\.processIdentifier)
    }

    private func relayRefusal() -> (record: ChromeRelayRefusal?, error: String?) {
        do { return (try ChromeRelayRefusal.read(socketPath: socketPath), nil) }
        catch { return (nil, "Chrome relay refusal could not be read: \(error.localizedDescription)") }
    }

    private func currentRefusal(_ record: ChromeRelayRefusal?, browsers: [pid_t]) -> ChromeRelayRefusal? {
        guard channel == nil, connectingChannel == nil else { return nil }
        let candidates = ([record].compactMap { $0 } + Array(signatureFailures.values)).filter {
            browsers.contains($0.browserPID) && $0.browserBirthStamp != nil
                && ChromeHostIdentity.processBirthStamp($0.browserPID) == $0.browserBirthStamp
                && $0.recordedAt > (facts.relayConnectedAt ?? .distantPast)
                && ($0.scope == .browser || $0.recordedAt >= (listenerStartedAt ?? runtimeStartedAt))
        }
        return candidates.max { $0.recordedAt < $1.recordedAt }
    }

    /// Register before the inventory read, so a Chrome launch cannot fall into
    /// a startup gap. Workspace events own later checks; there is no timer.
    public func observeBrowserLaunches() async {
        guard !observingBrowserLaunches else { return }
        observingBrowserLaunches = true
        browserLaunchObserver = await ChromeBrowserLaunchObserver { [weak self] pid in
            Task { await self?.checkBrowserSignature(pid) }
        }
        for pid in await Self.runningChromeProcesses() { await checkBrowserSignature(pid) }
    }

    private func checkBrowserSignature(_ pid: pid_t) async {
        // A launch event can arrive after that process exits. Recheck the live
        // inventory before treating a failed Security lookup as a Chrome fault.
        guard await Self.runningChromeProcesses().contains(pid),
              let birth = ChromeHostIdentity.processBirthStamp(pid) else { return }
        do {
            _ = try ChromeHostIdentity.checkedBrowserSigningIdentifier(forProcess: pid)
            signatureFailures.removeValue(forKey: pid)
        } catch let failure as ChromeHostIdentity.SigningFailure {
            guard ChromeHostIdentity.processBirthStamp(pid) == birth,
                  await Self.runningChromeProcesses().contains(pid) else { return }
            let refusal = ChromeRelayRefusal(scope: .browser, check: failure.check, osStatus: failure.status,
                                            reason: failure.localizedDescription, browserPID: pid)
            signatureFailures = signatureFailures.filter { ChromeHostIdentity.processBirthStamp($0.key) == $0.value.browserBirthStamp }
            signatureFailures[pid] = refusal
            guard !signatureFailureNoted else { return }
            signatureFailureNoted = true
            let message = "Chrome's running-browser signature check failed: \(failure.localizedDescription) The relay will refuse Chrome until this check is fixed. raw view · macOS running Chrome process and ChromeHostIdentity signature validation; no page was read."
            let id = "chrome-browser-signature-\(ProcessInfo.processInfo.operatingSystemVersionString)-\(failure.check)-\(failure.status)"
            do { try await signatureFailureNote(id, message) }
            catch { nativeLog("[NativeAgent] Chrome signature failure note could not be saved: %@; %@", error.localizedDescription, message) }
        } catch { nativeLog("[NativeAgent] Chrome browser signature check failed: %@", error.localizedDescription) }
    }

    private static func dateJSON(_ date: Date?) -> JSONValue {
        date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
    }

    private func downSide(chromeRunning: Bool, refusal: ChromeRelayRefusal?) -> String {
        if channel != nil, !extensionHasTabProtocol { return "extension_upgrade" }
        if listenerDescriptor < 0 { return "app_listener" }
        if !chromeRunning { return "chrome" }
        if connectingChannel != nil { return "extension_attach" }
        if refusal != nil { return "relay_refusal" }
        if extensionFiles == nil { return "extension_setup" }
        return "extension_link"
    }

    private func disconnectionReason(chromeRunning: Bool, refusal: ChromeRelayRefusal?) -> String {
        if channel != nil, !extensionHasTabProtocol {
            return extensionReload?.reason ?? extensionFilesError ?? "The connected Chrome extension needs the shipped tab protocol before Chrome control is ready."
        }
        if channel != nil { return "The Chrome extension reconnected while this request was being refused. Nothing was sent." }
        if listenerDescriptor < 0 {
            return "NativeAgent's Chrome listener is not running. " + (listenerFailure ?? "No app-side listener is available.")
        }
        if !chromeRunning { return "Chrome is not running." }
        if connectingChannel != nil { return "The app accepted the relay; the extension's attach greeting is still pending." }
        if let refusal { return "Chrome relay refused at \(refusal.check): \(refusal.reason)" }
        if extensionFiles == nil {
            return "The NativeAgent extension is not set up in Chrome. \(extensionFilesError ?? "") Call chrome.setup (Set up Chrome) to load it."
        }
        if !extensionConnectedThisRun {
            return ChromeControlRuntimeError.reconnectInstruction(startedAt: runtimeStartedAt,
                retryAfter: runtimeStartedAt.addingTimeInterval(30))
        }
        return "Chrome is running, but the extension's connection to NativeAgent ended. The app listener is up."
    }

    private func connectionFailure() async -> ChromeControlRuntimeError {
        let browsers = await Self.runningChromeProcesses()
        let refusal = currentRefusal(relayRefusal().record, browsers: browsers)
        // Only an extension Chrome has registered can be on its way back.
        readExtensionFiles()
        if channel == nil, listenerDescriptor >= 0, !browsers.isEmpty, extensionFiles != nil,
           connectingChannel == nil, refusal == nil, !extensionConnectedThisRun {
            return .extensionReconnecting(startedAt: runtimeStartedAt,
                retryAfter: runtimeStartedAt.addingTimeInterval(30))
        }
        return .connectionUnavailable(disconnectionReason(chromeRunning: !browsers.isEmpty,
                                    refusal: refusal))
    }

    private func recordHandshake(_ result: String, reason: String? = nil) {
        handshakeAt = Date()
        facts.handshakeAt = handshakeAt
        facts.handshakeResult = result
        facts.handshakeReason = reason
        saveConnectionFacts()
    }

    private func saveConnectionFacts() {
        do {
            let data = try JSONEncoder().encode(facts)
            try ChromeRelayRefusal.writePrivate(data, path: socketPath + ".connection-facts.json")
            factsStorageError = nil
        } catch {
            let message = "Chrome connection facts could not be saved: \(error.localizedDescription)"
            factsStorageError = message
            nativeLog("[NativeAgent] %@", message)
        }
    }

    private func removeConnectionObserver(_ id: UUID) {
        connectionObservers.removeValue(forKey: id)
    }

    private func publishConnectionState() {
        let state = connectionState
        BrowserConnectionMirror.set(connected: state == .connected)
        guard publishedConnectionState != state else { return }
        publishedConnectionState = state
        for observer in connectionObservers.values { observer.yield(state) }
    }

    private func connectionEnded(installation: UInt64) {
        guard installation == installationGeneration else { return }
        channel = nil
        connectingChannel = nil
        publishConnectionState()
    }
    /// 2026-09-06: which listener a descriptor was accepted under. An accept
    /// task outlives its listener while a handshake is still reading, and
    /// installing on presence alone let that stale connection displace the
    /// channel the CURRENT listener had already given Chrome.
    private var listenerGeneration: UInt64 = 0
    private var installationGeneration: UInt64 = 0
    private var policyGeneration: UInt64 = 0
    /// Descriptors accepted but not yet proven. Teardown has to be able to
    /// reach them: an in-handshake socket used to survive `stop()` entirely.
    private var handshakingDescriptors: [Int32: UInt64] = [:]
    /// 2026-09-06: the socket and token files THIS listener created. A second
    /// app launch replaces both; without an identity check the first launch's
    /// delayed teardown then deleted the newer launch's socket and secret and
    /// left Chrome talking to nothing.
    private var socketIdentity: FileIdentity?
    private var tokenIdentity: FileIdentity?

    public init(
        socketPath: String = ChromeControlRuntime.defaultSocketPath(),
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        // Chrome's native-host manifest is one file per Mac. A second install
        // of this app (a test copy beside the live one) must not take it over
        // on every launch: `defaults write <bundle id>
        // NativeAgentSecondaryInstall -bool YES` keeps that copy
        // from registering, so the relay stays with the install the person uses.
        manageNativeHostRegistration: Bool = !UserDefaults.standard.bool(forKey: "NativeAgentSecondaryInstall"),
        signatureFailureNote: @escaping @Sendable (String, String) async throws -> Void = { _, message in nativeLog("[NativeAgent] %@", message) },
        authority: @escaping Authority = {
            await SwiftNativeTrustCenter(dataRoot: PersistenceCore.defaultDataRoot())
                .chromeControlEnabledChecked(tool: ChromeControlInvocationContext.tool, origin: ChromeControlInvocationContext.origin)
        }
    ) {
        self.socketPath = socketPath
        self.conversationTabsURL = dataRoot.appendingPathComponent("chrome/conversation-tabs.json")
        self.manageNativeHostRegistration = manageNativeHostRegistration
        self.authority = authority
        self.signatureFailureNote = signatureFailureNote
        if FileManager.default.fileExists(atPath: conversationTabsURL.path) {
            do {
                let saved = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: conversationTabsURL))
                rememberedTabIDs = saved.filter { NativeAgentChatSessionID.isSafePathComponent($0.key) && $0.value >= 0 }
            } catch { conversationTabsStorageError = "Chrome conversation tab IDs could not be read: \(error.localizedDescription)" }
        }
        // Local evidence from an accepted connection, never the host manifest
        // or a synced tab group. Keep it across app restarts and permission changes.
        self.extensionHasConnected = (try? String(contentsOfFile: socketPath + ".extension-connected", encoding: .utf8)) == "connected\n"
        let factsURL = URL(fileURLWithPath: socketPath + ".connection-facts.json")
        if FileManager.default.fileExists(atPath: factsURL.path) {
            do { self.facts = try JSONDecoder().decode(ChromeConnectionFacts.self, from: Data(contentsOf: factsURL)) }
            catch { self.factsStorageError = "Chrome connection facts could not be read: \(error.localizedDescription)" }
        }
        let seenBefore = self.facts.extensionSeenAt != nil
        self.extensionHasConnected = self.extensionHasConnected || seenBefore
    }

    /// Listener availability is local app administration, not an agent effect.
    /// Every effect below still evaluates the concrete calling turn separately.
    private func transportAvailable() async -> Bool {
        let origin = SecurityOriginContext(surface: "chat", source: "chrome_transport", isRemote: false)
        return await ChromeControlInvocationContext.$origin.withValue(origin) {
            await authority()
        }
    }

    public func reconcilePolicy() async {
        policyGeneration &+= 1
        let generation = policyGeneration
        let enabled = await transportAvailable()
        guard generation == policyGeneration else { return }
        guard enabled else {
            await stopLocked()
            guard generation == policyGeneration else { return }
            if manageNativeHostRegistration { try? ChromeNativeHostRegistration.uninstall() }
            return
        }
        do {
            try startListenerIfNeeded()
            if manageNativeHostRegistration { try ChromeNativeHostRegistration.install() }
        } catch {
            listenerFailure = error.localizedDescription
            await stopLocked()
        }
    }

    public func conversationSnapshotView(_ verifiedSessionID: String?, tabID: Int64? = nil) -> [String: JSONValue]? {
        let tab = tabID.flatMap { groupTabs[$0] } ?? verifiedSessionID.flatMap { conversationTabs[$0] }
        return tab?.hasReadView == true ? tab?.readingView : nil
    }

    public func existingPageAddress(host: String, tabID: Int64? = nil) async throws -> [String: JSONValue] {
        guard await transportAvailable() else { throw ChromeControlRuntimeError.disabled }
        guard let channel = readyChannel else { throw await connectionFailure() }
        return try await channel.existingPageAddress(host: host, tabID: tabID)
    }

    public func pageChanges(host: String, tabID: Int64) async throws -> AsyncThrowingStream<JSONValue, Error> {
        guard await transportAvailable() else { throw ChromeControlRuntimeError.disabled }
        guard let channel = readyChannel else { throw await connectionFailure() }
        return try await channel.pageChanges(host: host, tabID: tabID)
    }

    public func performInConversation(
        _ effect: ChromeControlEffect, payload: [String: JSONValue], verifiedSessionID: String?
    ) async throws -> JSONValue {
        if channel != nil, readyChannel == nil { throw await connectionFailure() }
        let session = verifiedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session, !session.isEmpty {
            guard busyConversations.insert(session).inserted else {
                throw ChromeControlRuntimeError.conversationContext("Another Chrome action is still running in this conversation. Nothing was sent; wait for its result before continuing.")
            }
        }
        defer { if let session { busyConversations.remove(session) } }
        await refreshGroupTabs()
        var resolved = payload
        let explicitID: Int64? = if case .int(let id)? = payload["tabId"] { id } else { nil }
        let rememberedID = session.flatMap { rememberedTabIDs[$0] }
        let current = explicitID.flatMap { groupTabs[$0] }
            ?? (explicitID == nil ? session.flatMap { conversationTabs[$0] } : nil)
        if resolved["tabId"] == nil {
            if let rememberedID { resolved["tabId"] = .int(rememberedID) }
            else if let current { resolved["tabId"] = .int(current.tabID) }
        }
        if effect != .navigate, resolved["tabId"] == nil {
            throw ChromeControlRuntimeError.conversationContext("This conversation has no Chrome tab yet. browser.chrome_navigate{url} opens one; later calls reuse it. Nothing was sent.")
        }
        if resolved["expectedUserSequence"] == nil, let current, resolved["tabId"] == .int(current.tabID) { resolved["expectedUserSequence"] = current.userSequence }
        if effect == .snapshot, let current, resolved["tabId"] == .int(current.tabID) {
            for (key, value) in current.readingView where resolved[key] == nil { resolved[key] = value }
        }
        let (response, respondingChannel) = try await performOnChannel(effect, payload: resolved)
        if channel === respondingChannel, case .object(let envelope) = response, case .object(let result)? = envelope["result"] {
            if effect == .closeTab, result["tabClosed"] == .bool(true), case .int(let id)? = result["tabId"] {
                groupTabs.removeValue(forKey: id)
                conversationTabs = conversationTabs.filter { $0.value.tabID != id }
            } else if (effect != .navigate || result["outcome"] == .string("succeeded")), let tab = ChromeConversationTab(result: result, previous: current) {
                groupTabs[tab.tabID] = tab
                if let session, !session.isEmpty { conversationTabs[session] = tab; rememberTab(tab.tabID, session: session) }
            }
        }
        if effect == .media || effect == .closeTab, case .object(var envelope) = response,
           case .object(var result)? = envelope["result"] {
            result["tabSelection"] = .string(explicitID != nil ? "Explicit tab_id."
                : "Default tab: this conversation's remembered tab (tab_id omitted).")
            envelope["result"] = .object(result)
            return .object(envelope)
        }
        return response
    }

    func perform(_ effect: ChromeControlEffect, payload: [String: JSONValue]) async throws -> JSONValue {
        try await performOnChannel(effect, payload: payload).response
    }

    private func performOnChannel(
        _ effect: ChromeControlEffect, payload: [String: JSONValue]
    ) async throws -> (response: JSONValue, channel: ChromeControlChannel) {
        if MacDriverContext.binding == nil {
            let binding = await MacAttentionSessionStore.shared.bindDriver()
            return try await withTaskCancellationHandler {
                try await MacDriverContext.$binding.withValue(binding) {
                    try await performOnChannel(effect, payload: payload)
                }
            } onCancel: { binding.cancel() }
        }
        if effect.requiresEffectTimeAuthorization {
            guard await authority() else {
                throw ChromeControlRuntimeError.disabled
            }
        }
        if channel != nil, readyChannel == nil { throw await connectionFailure() }
        let previous = readyChannel
        do {
            guard let previous else { throw ChromeControlRuntimeError.disconnected }
            return (try await previous.request(action: effect, payload: payload), previous)
        } catch ChromeControlRuntimeError.disconnected {
            // Chrome owns host launch. Make its destination ready; the worker's
            // reconnect alarm repairs the link independently of this request.
            // Dispatched mutations become outcomeUnknown and never enter here.
            try Task.checkCancellation()
            guard await authority() else { throw ChromeControlRuntimeError.disabled }
            do {
                try startListenerIfNeeded()
                if manageNativeHostRegistration { try ChromeNativeHostRegistration.install() }
            } catch {
                listenerFailure = error.localizedDescription
                await stopLocked()
                throw await connectionFailure()
            }
            let next: ChromeControlChannel
            if let channel = readyChannel, channel !== previous {
                next = channel
            } else {
                // Right after NativeAgent starts, or while the extension's
                // greeting is in flight, the link is on its way: wait for it
                // rather than refuse the call.
                var waitUntil: Date? = connectingChannel != nil ? Date().addingTimeInterval(5) : nil
                if case .extensionReconnecting(_, let retryAfter) = await connectionFailure() {
                    waitUntil = retryAfter.addingTimeInterval(5)
                }
                guard let waitUntil, let reconnected = await connectedChannel(until: waitUntil),
                      reconnected !== previous else { throw await connectionFailure() }
                next = reconnected
            }
            try Task.checkCancellation()
            guard await authority() else {
                throw ChromeControlRuntimeError.disabled
            }
            return (try await next.request(action: effect, payload: payload), next)
        }
    }

    /// The channel once the connection state reports it, or nil at the deadline.
    private func connectedChannel(until deadline: Date) async -> ChromeControlChannel? {
        let states = connectionStates()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await state in states where state == .connected { return } }
            group.addTask { try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            await group.next()
            group.cancelAll()
        }
        return readyChannel
    }

    public func stop() async {
        policyGeneration &+= 1
        await stopLocked()
    }

    func installAcceptedDescriptorForTesting(_ descriptor: Int32) async {
        await installAcceptedDescriptor(descriptor, generation: listenerGeneration)
    }

    /// Registered before the handshake so `stopLocked` can reach the socket
    /// while it is still being read. False means this listener is already gone.
    private func beginHandshake(_ descriptor: Int32, generation: UInt64) -> Bool {
        guard generation == listenerGeneration else { return false }
        handshakingDescriptors[descriptor] = generation
        return true
    }

    private func listenerEnded(generation: UInt64, error: Int32) async {
        guard generation == listenerGeneration else { return }
        listenerFailure = "NativeAgent's Chrome listener stopped accepting connections (errno \(error))."
        await stopLocked()
    }

    private func finishHandshake(_ descriptor: Int32, generation: UInt64, rejection: String?) async {
        guard handshakingDescriptors[descriptor] == generation else { return }
        handshakingDescriptors.removeValue(forKey: descriptor)
        guard generation == listenerGeneration else {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            return
        }
        if let rejection {
            recordHandshake("rejected", reason: rejection)
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            return
        }
        // 2026-09-06: answer the greeting BEFORE the channel takes the
        // descriptor, so the ack is the first frame the relay reads on this
        // connection and nothing the channel sends can precede it.
        guard ChromeControlHandshake.sendHelloAck(descriptor: descriptor, generation: generation) else {
            recordHandshake("rejected", reason: "Chrome handshake rejected: the app could not acknowledge the relay greeting.")
            Darwin.close(descriptor)
            return
        }
        facts.relayConnectedAt = Date()
        recordHandshake("relay_accepted")
        await installAcceptedDescriptor(descriptor, generation: generation)
    }

    private func startListenerIfNeeded() throws {
        guard listenerDescriptor < 0 else { return }
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        guard Array(socketPath.utf8CString).count <= MemoryLayout<sockaddr_un>.size - 2 else {
            throw ChromeControlRuntimeError.socketPathTooLong
        }
        try unlinkSocketIfPresent(path: socketPath)
        // 2026-09-06: the secret must be readable BEFORE anything can connect,
        // so it is written before the socket exists at all.
        let token = ChromeControlHandshake.mintToken()
        try ChromeControlHandshake.writeToken(
            token,
            to: ChromeControlHandshake.tokenPath(forSocketPath: socketPath)
        )
        // Claimed the moment it is written, so a failure below still leaves
        // teardown able to remove the file this call created.
        tokenIdentity = FileIdentity(path: ChromeControlHandshake.tokenPath(forSocketPath: socketPath))
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
        do {
            try bindUnixSocket(descriptor: descriptor, path: socketPath)
            guard Darwin.listen(descriptor, 1) == 0 else {
                throw ChromeControlRuntimeError.socketFailure(errno)
            }
            chmod(socketPath, 0o600)
        } catch {
            Darwin.close(descriptor)
            try? unlinkSocketIfPresent(path: socketPath)
            throw error
        }
        listenerDescriptor = descriptor
        listenerStartedAt = Date()
        listenerFailure = nil
        socketIdentity = FileIdentity(path: socketPath)
        listenerGeneration &+= 1
        let generation = listenerGeneration
        let expectedPeers = expectedPeerExecutablePaths()
        let acceptQueue = DispatchQueue(label: "com.nativeagent.chromecontrol.accept", qos: .utility)
        acceptTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let (accepted, acceptError) = await offPool(acceptQueue) {
                    let accepted = Darwin.accept(descriptor, nil, nil)
                    return (accepted, accepted < 0 ? errno : 0)
                }
                if accepted < 0 {
                    if acceptError == EINTR { continue }
                    await self?.listenerEnded(generation: generation, error: acceptError)
                    break
                }
                guard let self else {
                    _ = Darwin.shutdown(accepted, SHUT_RDWR)
                    Darwin.close(accepted)
                    break
                }
                // 2026-09-06: hand the descriptor to the runtime BEFORE the
                // handshake reads it, so a `stop()` during the handshake can
                // shut it down instead of leaving it open forever.
                guard await self.beginHandshake(accepted, generation: generation) else {
                    _ = Darwin.shutdown(accepted, SHUT_RDWR)
                    Darwin.close(accepted)
                    continue
                }
                // 2026-09-06: authenticate here, on the accept task, so an
                // unproven caller is closed without ever reaching the runtime
                // — it cannot shut down the channel Chrome is using. The peer's
                // executable is checked first: it costs one getsockopt and
                // needs no cooperation from the caller.
                // The hello read blocks in `recv` for up to its whole budget.
                let rejection = await offPool(acceptQueue) { () -> String? in
                    do {
                        try ChromeControlHandshake.validateConnection(
                            descriptor: accepted, expecting: expectedPeers, token: token
                        )
                        return nil
                    } catch { return error.localizedDescription }
                }
                await self.finishHandshake(accepted, generation: generation, rejection: rejection)
            }
        }
    }

    /// The relay executable this app registered with Chrome, symlink-resolved.
    /// Empty when this launch registers none, which is the hermetic lane: the
    /// token then governs alone.
    private func expectedPeerExecutablePaths() -> Set<String> {
        guard manageNativeHostRegistration else { return [] }
        let relay = ChromeNativeHostRegistration.bundledRelayURL()
        guard FileManager.default.isExecutableFile(atPath: relay.path) else { return [] }
        return [relay.resolvingSymlinksInPath().path]
    }

    private func installAcceptedDescriptor(_ descriptor: Int32, generation: UInt64) async {
        guard generation == listenerGeneration,
              await transportAvailable(),
              listenerDescriptor >= 0 || !manageNativeHostRegistration,
              generation == listenerGeneration else {
            Darwin.close(descriptor)
            return
        }
        installationGeneration &+= 1
        let installation = installationGeneration
        let browserPID = ChromeControlHandshake.peerProcessID(descriptor: descriptor)
            .flatMap { ChromeHostIdentity.parentProcessID(of: $0) }
        let liveBrowserPID = browserPID.flatMap { $0 > 1 && ChromeHostIdentity.isBrowserProcess($0) ? $0 : nil }
        // Retire the old channel before shutdown suspends, so its late replies
        // cannot restore bookmarks while the replacement is being installed.
        let previous = channel
        let previousConnecting = connectingChannel
        channel = nil
        connectingChannel = nil
        publishConnectionState()
        if let previous { await previous.shutdown() }
        if let previousConnecting { await previousConnecting.shutdown() }
        // Shutdown suspends: a stop or a newer accepted connection retires
        // this installation before it can publish a channel.
        guard generation == listenerGeneration,
              installation == installationGeneration else {
            Darwin.close(descriptor)
            return
        }
        let next = ChromeControlChannel(descriptor: descriptor, onReloadFailure: { [weak self] id, reason in
            Task { await self?.extensionReloadFailed(id: id, reason: reason) }
        }, onCaptureFailure: { [weak self] tabID, reason, at in
            Task { await self?.recordCaptureError(reason, tabID: tabID, at: at) }
        }) { [weak self] in
            Task { await self?.connectionEnded(installation: installation) }
        }
        connectingChannel = next
        await next.start()
        do {
            // A proven relay alone says nothing about the extension's version
            // or readiness. The existing attach request gets those facts from
            // Chrome and also confirms readiness to the worker.
            let response = try await next.request(action: .attach, payload: [:])
            guard case .object(let envelope) = response, case .object(let result)? = envelope["result"],
                  result["hostId"] == .string("com.nativeagent.chrome"), result["protocolVersion"] == .int(1),
                  case .string(let version)? = result["extensionVersion"], !version.isEmpty,
                  version.utf8.count <= 128, ChromeExtensionFiles.components(version) != nil else {
                throw ChromeControlRuntimeError.handshakeRejected("the extension returned an invalid attach greeting.")
            }
            guard installation == installationGeneration, generation == listenerGeneration,
                  connectingChannel === next, await transportAvailable(),
                  installation == installationGeneration, generation == listenerGeneration,
                  connectingChannel === next else {
                if connectingChannel === next { connectingChannel = nil }
                await next.shutdown()
                return
            }
            // A legacy greeting is transport evidence, not tab readiness.
            let capabilities: [JSONValue] = if case .array(let list)? = result["capabilities"] { list } else { [] }
            extensionCanReload = capabilities.contains(.string("extension.reload"))
            extensionHasTabProtocol = if case .array? = result["tabs"] { capabilities.contains(.string("tab.close")) } else { false }
            let tabs: [JSONValue] = if case .array(let list)? = result["tabs"] { list } else { [] }
            var rebuilt: [Int64: ChromeConversationTab] = [:]
            for value in tabs {
                guard case .object(let row) = value, case .int(let id)? = row["tabId"], let tab = ChromeConversationTab(result: row, previous: groupTabs[id]), rebuilt[tab.tabID] == nil else {
                    throw ChromeControlRuntimeError.invalidResponse
                }
                rebuilt[tab.tabID] = tab
            }
            groupTabs = rebuilt
            conversationTabs = rememberedTabIDs.compactMapValues { rebuilt[$0] }
            if case .object(let error)? = result["lastExtensionError"],
               case .string(let message)? = error["message"], !message.isEmpty, message.utf8.count <= 4096 {
                facts.extensionError = message
                if case .string(let at)? = error["at"] { facts.extensionErrorAt = at }
            }
            facts.extensionVersion = version
            facts.extensionSeenAt = Date()
            recordHandshake("accepted")
        } catch {
            if installation == installationGeneration, generation == listenerGeneration {
                let reason = (error as? ChromeControlRuntimeError).map { failure in
                    if case .handshakeRejected = failure { return failure.localizedDescription }
                    return "Chrome handshake rejected: extension attach failed: \(failure.localizedDescription)"
                } ?? "Chrome handshake rejected: extension attach failed: \(error.localizedDescription)"
                recordHandshake("rejected", reason: reason)
                connectingChannel = nil

            }
            await next.shutdown()
            return
        }
        connectingChannel = nil
        channel = next
        connectedBrowserPID = liveBrowserPID
        extensionHasConnected = true
        extensionConnectedThisRun = true
        try? "connected\n".write(toFile: socketPath + ".extension-connected", atomically: true, encoding: .utf8)
        publishConnectionState()
        readExtensionFiles()
        if let attempt = extensionReload, attempt.pending, let version = facts.extensionVersion {
            if liveBrowserPID != attempt.browserPID || liveBrowserPID.flatMap({ ChromeHostIdentity.processBirthStamp($0) }) != attempt.browserBirthStamp {
                finishExtensionReload(phase: "failed", after: version, reason: "The reconnect came from a different Chrome process.")
            } else if attempt.phase == "awaiting_chrome_reload", version != attempt.shipped || !extensionHasTabProtocol {
                // The human Reload ask stays open until the shipped protocol greets.
            } else if ChromeExtensionFiles.isOlder(version, than: attempt.shipped) {
                finishExtensionReload(phase: "stale", after: version, reason: "reloaded, still \(version), extension files not updated (\(attempt.path))")
            } else {
                finishExtensionReload(phase: "succeeded", after: version, reason: "Reload verified by the extension's accepted reconnect and running version.")
            }
        }
        if extensionReload?.pending != true, let files = extensionFiles, let running = facts.extensionVersion,
           ChromeExtensionFiles.isOlder(running, than: files.shippedVersion) {
            let pair = files.shippedVersion + "/" + running
            if await transportAvailable(), channel === next, automaticReloadPairs.insert(pair).inserted {
                do { try await beginExtensionReload(on: next, source: .automatic) }
                catch { _ = recordReloadPreflightFailure(error, source: .automatic) }
            }
        }
    }

    private func stopLocked() async {
        let waiters = reloadWaiters.values
        reloadWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: ChromeControlRuntimeError.disconnected) }
        let existing = channel
        let existingConnecting = connectingChannel
        channel = nil
        connectingChannel = nil
        publishConnectionState()
        acceptTask?.cancel()
        acceptTask = nil
        // 2026-09-06: retire this listener BEFORE anything else — an accept
        // task still inside a handshake read then loses the right to install.
        listenerGeneration &+= 1
        // 2026-09-06: an in-handshake socket used to survive teardown entirely.
        // Shut it down rather than close it: the accept task is blocked in
        // `recv` on that descriptor and owns the close, so the number cannot be
        // recycled under a read still in flight.
        for descriptor in handshakingDescriptors.keys {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        if listenerDescriptor >= 0 {
            _ = Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
            Darwin.close(listenerDescriptor)
            listenerDescriptor = -1
        }
        // 2026-09-06: only unlink what THIS listener created. A second app
        // launch recreates both paths; the first launch's delayed teardown was
        // deleting the newer launch's live socket and secret.
        if let socketIdentity, socketIdentity == FileIdentity(path: socketPath) {
            try? unlinkSocketIfPresent(path: socketPath)
        }
        socketIdentity = nil
        // The secret dies with the listener that minted it.
        let tokenPath = ChromeControlHandshake.tokenPath(forSocketPath: socketPath)
        if let tokenIdentity, tokenIdentity == FileIdentity(path: tokenPath) {
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        tokenIdentity = nil
        // Retire all listener-owned state before yielding to channel cleanup.
        if let existing {
            await existing.shutdown()
        }
        if let existingConnecting {
            await existingConnecting.shutdown()
        }
    }

    public static func defaultSocketPath() -> String {
        InstallPaths.current.chromeSocket.path
    }
}

/// A conversation remembers its last tab; Chrome's group owns the authority.
struct ChromeConversationTab: Sendable {
    let tabID: Int64
    let userSequence: JSONValue
    let readingView: [String: JSONValue]
    let hasReadView: Bool
    let title: String?
    let url: String?
    let audible: JSONValue
    let mutedInfo: JSONValue

    init?(result: [String: JSONValue], previous: Self? = nil) {
        guard case .int(let id)? = result["tabId"], id >= 0,
              case .int(let sequence)? = result["userSequence"], sequence >= 0 else { return nil }
        let prior = previous?.tabID == id ? previous : nil
        tabID = id; userSequence = .int(sequence)
        func string(_ value: JSONValue?) -> String? { if case .string(let text)? = value { text } else { nil } }
        title = string(result["title"]) ?? prior?.title
        url = string(result["url"]) ?? prior?.url
        audible = result["audible"] ?? prior?.audible ?? .null
        mutedInfo = result["mutedInfo"] ?? prior?.mutedInfo ?? .null
        hasReadView = result["readingView"] != nil || result["reading"] != nil || prior?.hasReadView == true
        if case .object(let view)? = result["readingView"] { readingView = view }
        else if case .object(let view)? = result["reading"] {
            readingView = view.filter { ["scope", "maxNodes", "maxTextChars"].contains($0.key) }
        } else { readingView = prior?.readingView ?? ["scope": .string("page"), "maxNodes": .int(80), "maxTextChars": .int(12_000)] }
    }
}

/// 2026-09-06: which file a path named at one moment. A path is not an
/// identity when a second app launch can replace what sits there.
private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

private func bindUnixSocket(descriptor: Int32, path: String) throws {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8CString)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
        tuplePointer.withMemoryRebound(to: Int8.self, capacity: pathBytes.count) { pointer in
            for (index, byte) in pathBytes.enumerated() { pointer[index] = byte }
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
}

private func unlinkSocketIfPresent(path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        if errno == ENOENT { return }
        throw ChromeControlRuntimeError.socketFailure(errno)
    }
    guard (info.st_mode & S_IFMT) == S_IFSOCK else {
        throw ChromeControlRuntimeError.unsafeSocketPath
    }
    guard unlink(path) == 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
}

public enum ChromeNativeHostRegistration {
    static let hostID = "com.nativeagent.chrome"
    /// 2026-09-06: one spelling, shared with the relay — the relay checks the
    /// origin Chrome hands it in argv against the same value this writes into
    /// the manifest's `allowed_origins`, and a drift between them would make
    /// every legitimate launch look like an impersonation.
    static let extensionID = ChromeHostIdentity.extensionID

    /// The relay this app ships and registers. Also what the control socket
    /// requires its peer's executable to be (2026-09-06).
    static func bundledRelayURL() -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NativeAgentChromeRelay")
    }

    static func install(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        relayURL: URL? = nil,
        bundleIdentifier: String? = currentAppBundleIdentifier()
    ) throws {
        let relay = relayURL ?? bundledRelayURL()
        guard relay.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: relay.path) else {
            throw ChromeControlRuntimeError.relayUnavailable
        }
        let paths = InstallPaths(bundleIdentifier: bundleIdentifier, home: home)
        let manifest: [String: Any] = [
            "name": hostID,
            "description": "NativeAgent Chrome transport relay",
            "path": relay.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
            "nativeagent_bundle_id": paths.bundleIdentifier,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try update(paths: paths, relay: relay) { destination in
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    /// 2026-09-26: Chrome has one host for the extension. When another install
    /// registered it, the extension Chrome runs is that install's to refresh.
    public static func ownsOrUnclaimed() -> Bool {
        let paths = InstallPaths.current
        guard FileManager.default.fileExists(atPath: paths.chromeManifest.path) else { return true }
        guard let data = try? Data(contentsOf: paths.chromeManifest),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return paths.ownsChromeManifest(manifest, relay: bundledRelayURL())
    }

    static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          relayURL: URL? = nil, bundleIdentifier: String? = currentAppBundleIdentifier()) throws {
        let paths = InstallPaths(bundleIdentifier: bundleIdentifier, home: home)
        guard FileManager.default.fileExists(atPath: paths.chromeManifest.path) else { return }
        try update(paths: paths, relay: relayURL ?? bundledRelayURL()) { destination in
            try FileManager.default.removeItem(at: destination)
        }
    }

    private static func update(paths: InstallPaths, relay: URL, _ write: (URL) throws -> Void) throws {
        let directory = paths.chromeManifest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 2026-09-18: serialize the ownership read and replacement even on
        // first launch. Lock the directory so atomic manifest renames are safe.
        let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if FileManager.default.fileExists(atPath: paths.chromeManifest.path) {
            let data = try Data(contentsOf: paths.chromeManifest)
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  paths.ownsChromeManifest(manifest, relay: relay) else { return }
        }
        try write(paths.chromeManifest)
    }
}
