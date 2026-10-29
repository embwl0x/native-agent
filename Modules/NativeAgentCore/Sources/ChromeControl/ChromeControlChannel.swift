import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import MacControl
// Blueprint: | `ChromeControlChannel.swift` | `ChromeControlChannel` actor, private socket/request ownership and shared offPool socket dispatch; ordered frames, cancellation/timeout settlement and unknown mutation outcomes; Chrome group tab authority, `ChromeConversationTab` values, snapshot/element/user-sequence safety, call-scoped pixels and bounded mutation-backed page change streams |

private final class ChromeSocketHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var shutDown = false
    /// The write queue owns a duplicate descriptor until its last frame settles.
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

/// Blocking socket calls run on a dedicated queue, outside the concurrency pool.
func offPool<T: Sendable>(_ queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
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
    /// Serial writes preserve frame order without blocking actor cancellation.
    private nonisolated let writeQueue = DispatchQueue(
        label: "com.nativeagent.chromecontrol.write"
    )
    let requestTimeout: Duration
    private let onReloadFailure: @Sendable (String, String) -> Void
    private var readTask: Task<Void, Never>?
    private var driverTask: Task<Void, Never>?
    private var actionDriver: MacDriverBinding?
    private var pending: [String: Pending] = [:]
    private var ownTabs: [Int64: ChromeConversationTab]
    private var pageSnapshots: [Int64: JSONValue] = [:]
    private var pageGenerations: [Int64: Int64] = [:]
    private let onCaptureFailure: @Sendable (Int64, String, Date) -> Void
    private let onTabReleased: @Sendable (JSONValue) async -> Void
    private struct PageObserver {
        let tabID: Int64
        let host: String
        let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    }
    private var pageObservers: [UUID: PageObserver] = [:]
    private var closed = false
    private let onDisconnect: @Sendable () -> Void

    init(descriptor: Int32, previousTabs: [Int64: ChromeConversationTab] = [:], requestTimeout: Duration = .seconds(30),
         onReloadFailure: @escaping @Sendable (String, String) -> Void = { _, _ in },
         onCaptureFailure: @escaping @Sendable (Int64, String, Date) -> Void = { _, _, _ in },
         onTabReleased: @escaping @Sendable (JSONValue) async -> Void = { _ in },
         onDisconnect: @escaping @Sendable () -> Void = {}) {
        socket = ChromeSocketHandle(descriptor: descriptor)
        ownTabs = previousTabs
        self.requestTimeout = requestTimeout
        self.onReloadFailure = onReloadFailure
        self.onCaptureFailure = onCaptureFailure
        self.onTabReleased = onTabReleased
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
                    let value: JSONValue = try autoreleasepool {
                        try JSONValue(fromFoundation: framer.validateJSONObject(data))
                    }
                    await self?.receive(value)
                }
                await self?.connectionEnded(error: ChromeControlRuntimeError.disconnected)
            } catch {
                await self?.connectionEnded(error: error)
            }
        }
    }

    func request(action: ChromeControlEffect, payload: [String: JSONValue]) async throws -> JSONValue {
        // Her tab group yields to explicit takeover, not the person's input.
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
        let yielded = pending.filter { $0.value.driver?.handedBack == true }
        for (id, row) in yielded {
            if row.dispatch.cancel() {
                cancelAction(id)
                continue // Receive merges the settled evidence into the yield.
            }
            pending.removeValue(forKey: id)
            row.timeout?.cancel()
            row.continuation?.resume(returning: Self.driverTakeoverResult(
                action: row.expectedAction, payload: row.targetReceipt, dispatched: false))
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

    func tabs() -> [Int64: ChromeConversationTab] { ownTabs }

    func existingPageAddress(host: String, tabID: Int64?) throws -> [String: JSONValue] {
        // Addressing comes from current ownership, not a previous capture.
        // The ensuing read proves which documents are actually readable.
        let matches = ownTabs.compactMap { id, tab -> (Int64, JSONValue)? in
            guard tabID == nil || tabID == id,
                  let url = tab.url,
                  (host == "*" || URL(string: url)?.host?.lowercased() == host.lowercased()) else { return nil }
            return (id, tab.userSequence)
        }
        guard matches.count == 1, let (id, sequence) = matches.first else {
            throw ChromeControlRuntimeError.conversationContext(matches.isEmpty
                ? "No owned Chrome tab is available for \(host)."
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

    private func receive(_ value: JSONValue) async {
        guard case .object(let object) = value,
              case .int(1)? = object["version"],
              case .string(let type)? = object["type"] else {
            connectionEnded(error: ChromeControlRuntimeError.invalidResponse)
            return
        }
        if type == "event" {
            await applyEvent(object)
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
                if row.expectedAction == .attach {
                    let tabs: [JSONValue] = if case .array(let values)? = result["tabs"] { values } else { [] }
                    guard let rebuilt = ChromeConversationTab.inventory(tabs, previous: ownTabs) else {
                        row.continuation?.resume(throwing: ChromeControlRuntimeError.invalidResponse)
                        connectionEnded(error: ChromeControlRuntimeError.invalidResponse)
                        return
                    }
                    ownTabs = rebuilt
                }
                if case .int(let tabID)? = result["tabId"] {
                    if row.expectedAction == .closeTab, result["tabClosed"] == .bool(true) {
                        ownTabs.removeValue(forKey: tabID)
                        endPageObservers(tabID: tabID, error: ChromeControlRuntimeError.conversationContext("The Chrome tab was closed."))
                    } else if (row.expectedAction == .navigate && result["outcome"] == .string("succeeded")) || ownTabs[tabID] != nil {
                        ownTabs[tabID] = ChromeConversationTab(result: result, previous: ownTabs[tabID])
                        if row.expectedAction == .snapshot {
                            if result["format"] == .string("jpeg") || result["nodes"] == nil { pageSnapshots.removeValue(forKey: tabID) }
                            else { pageSnapshots[tabID] = .object(result) }
                        }
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

    private func applyEvent(_ object: [String: JSONValue]) async {
        if object["event"] == .string("extension.reload_failed"),
           case .object(let payload)? = object["payload"],
           case .string(let id)? = payload["reloadId"], id.utf8.count <= 128,
           case .string(let reason)? = payload["reason"], reason.utf8.count <= 4096 {
            onReloadFailure(id, reason)
            return
        }
        if object["event"] == .string("tabs.changed"), case .object(let payload)? = object["payload"],
           case .array(let values)? = payload["tabs"] {
            guard let projected = ChromeConversationTab.inventory(values, previous: ownTabs) else { return }
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
            let reason: String = if case .string(let value)? = payload["reason"] { value }
                else { event == "tab.closed" ? "tab_closed" : "reason_unavailable" }
            let released = JSONValue.object(["tabId": .int(tabID), "reason": .string(reason),
                "at": object["occurredAt"] ?? .null, "url": payload["url"] ?? ownTabs[tabID]?.url.map(JSONValue.string) ?? .null])
            ownTabs.removeValue(forKey: tabID)
            NotificationCenter.default.post(name: Notification.Name("NativeAgentChromeTabEnded"), object: nil,
                userInfo: ["tabId": tabID, "closed": event == "tab.closed"])
            let message = switch reason {
            case "tab_active": "The person selected this tab, so it is theirs now (tab_active)."
            case "tab_missing": "No tab \(tabID) exists any more (tab_missing)."
            case "tab_closed": "The tab was closed."
            case "outside_group", "group_changed": "The tab left the NativeAgent group (\(reason))."
            default: "This tab is the person's own now (\(reason)); use another NativeAgent tab."
            }
            let error = ChromeControlRuntimeError.extensionRejected(code: "tab_not_owned", message: message)
            endPageObservers(tabID: tabID, error: error)
            // Every end of ownership is one yield (a close yields first, reason
            // tab_closed); the closing confirmation is not a second release.
            if event == "tab.yielded" { await onTabReleased(released) }
            let interrupted = pending.filter { $0.value.tabID == tabID && $0.value.expectedAction != .closeTab }
            for (id, row) in interrupted {
                if row.dispatch.cancel() {
                    cancelAction(id)
                    continue // Retain any partial page reply through settlement.
                }
                pending.removeValue(forKey: id); row.timeout?.cancel()
                row.continuation?.resume(throwing: row.unconfirmedFailure(error))
            }
        } else if event == "page.changed" {
            guard let tab = ownTabs[tabID], payload["userSequence"] == tab.userSequence,
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
            guard let tab = ownTabs[tabID], payload["userSequence"] == tab.userSequence,
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
        if row.dispatch.cancel() { cancelAction(id) }
        row.continuation?.resume(throwing: row.unconfirmedFailure(ChromeControlRuntimeError.requestTimedOut))
    }

    private func cancelAction(_ id: String) {
        let cancellation = JSONValue.object([
            "version": .int(1), "type": .string("event"), "event": .string("action.cancel"),
            "occurredAt": .string(ISO8601DateFormatter().string(from: Date())),
            "payload": .object(["requestId": .string(id)]),
        ])
        if let data = try? cancellation.serializedData(pretty: false) { enqueueWrite(data) { _ in } }
    }

    private func cancelRequest(_ id: String) {
        guard let row = pending[id] else { return }
        let started = row.dispatch.cancel()
        if started {
            cancelAction(id)
            // Keep the one waiter until Chrome settles the dispatched work,
            // including partial typing output. The existing deadline still
            // bounds a missing reply and reports its outcome as unknown.
            return
        }
        pending.removeValue(forKey: id)
        row.timeout?.cancel()
        row.continuation?.resume(throwing: CancellationError())
    }

    private func connectionEnded(error: Error) {
        guard !closed else { return }
        shutdown(error: error)
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

    static func inventory(_ values: [JSONValue], previous: [Int64: Self]) -> [Int64: Self]? {
        var tabs: [Int64: Self] = [:]
        for value in values {
            guard case .object(let fields) = value, case .int(let id)? = fields["tabId"],
                  fields["userSequence"] != nil,
                  let tab = Self(result: fields, previous: previous[id]), tabs[id] == nil else { return nil }
            tabs[id] = tab
        }
        return tabs
    }

    init?(result: [String: JSONValue], previous: Self? = nil) {
        guard case .int(let id)? = result["tabId"], id >= 0 else { return nil }
        let prior = previous?.tabID == id ? previous : nil
        guard case .int(let sequence)? = result["userSequence"] ?? prior?.userSequence, sequence >= 0 else { return nil }
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
