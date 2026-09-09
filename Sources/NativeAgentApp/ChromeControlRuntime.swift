import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import TrustCenter

enum ChromeControlRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case unavailable
    case disconnected
    case invalidResponse
    case requestTimedOut
    case extensionRejected(code: String, message: String)
    case outcomeUnknown(action: String, reason: String)
    /// The lease ended in Chrome and the extension SAID WHY. Sweep item 10a:
    /// `applyEvent` used to keep the lease id and drop `reason`, so "the user
    /// touched the page and I yielded" reached her as a bare `lease_not_found`
    /// from the next call, or as a timeout on the call already in flight.
    case leaseEnded(leaseID: String, event: String, reason: String)
    case socketFailure(Int32)
    case socketPathTooLong
    case relayUnavailable
    case unsafeSocketPath

    var errorDescription: String? {
        switch self {
        case .disabled: return "Chrome control is off in Trust Center."
        case .unavailable: return "Chrome control authority could not be verified."
        case .disconnected: return "Chrome is not connected to NativeAgent."
        case .invalidResponse: return "Chrome returned an invalid control response."
        case .requestTimedOut: return "Chrome did not answer before the control deadline."
        case .extensionRejected(let code, let message):
            return "Chrome refused the control request (\(code)): \(message)"
        case .outcomeUnknown(let action, let reason):
            return "Chrome did not confirm \(action) after dispatch. \(reason) The action may have completed; do not automatically repeat it. Observe the page before retrying."
        case .socketFailure(let code): return "Chrome control socket failed (errno \(code))."
        case .socketPathTooLong: return "Chrome control socket path is too long."
        case .relayUnavailable: return "The bundled NativeAgent Chrome relay is unavailable."
        case .unsafeSocketPath: return "Chrome control refused to replace a non-socket filesystem entry."
        case .leaseEnded(let leaseID, let event, let reason):
            return "\(ChromeLeaseEndReason.words(event: event, reason: reason)) The Chrome tab lease "
                + "\(leaseID) is gone, so nothing was sent. Acquire a fresh lease and take a new "
                + "snapshot before acting again — the old node ids are stale."
        }
    }
}

/// The extension's machine reason for a lease ending, said out loud. Anything
/// unrecognised is quoted rather than swallowed: an unknown reason is still
/// more than no reason.
enum ChromeLeaseEndReason {
    static func words(event: String, reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("user_") {
            return "The user touched the page, so Chrome yielded the tab back to them."
        }
        switch trimmed {
        case "tab_activated":
            return "The tab came to the foreground, so Chrome yielded it back to the user."
        case "tab_activated_during_navigation":
            return "The tab came to the foreground mid-navigation, so Chrome yielded it back "
                + "to the user."
        case "lease_expired", "expired":
            return "The tab lease expired before this call."
        case "host_released":
            return "The tab lease had already been released."
        case "":
            return event == "lease.yielded"
                ? "Chrome yielded the tab back and gave no reason."
                : "The tab lease ended and Chrome gave no reason."
        default:
            return event == "lease.yielded"
                ? "Chrome yielded the tab back (\(trimmed))."
                : "The tab lease ended (\(trimmed))."
        }
    }
}

enum ChromeControlEffect: String, Sendable, CaseIterable {
    case acquire = "lease.acquire"
    /// Sweep item 10c. `lease.renew` has existed in the extension since the
    /// lease manager shipped; with no Swift case there was no way to reach it,
    /// which put a hard 60-second ceiling on every Chrome task.
    case renew = "lease.renew"
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
    case release = "lease.release"

    var requiresEffectTimeAuthorization: Bool {
        switch self {
        case .acquire, .renew, .navigate, .snapshot, .click, .fill, .type, .select,
             .keypress, .setChecked, .doubleClick, .drag, .wait, .scroll: true
        case .release: false
        }
    }

    var mayChangeExternalState: Bool {
        switch self {
        case .snapshot, .wait: false
        // `renew` moves the lease's expiry inside Chrome. An unconfirmed renew
        // is therefore an unknown outcome like any other lease mutation, not a
        // free retry.
        case .acquire, .renew, .navigate, .click, .fill, .type, .select, .keypress,
             .setChecked, .doubleClick, .drag, .scroll, .release: true
        }
    }
}

private final class ChromeSocketHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
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
        return descriptor >= 0
    }

    func fileHandle() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }

    /// The write side's own descriptor. Nil once the write queue has closed it.
    func writeFileHandle() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard writeDescriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: false)
    }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
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

actor ChromeControlChannel {
    private struct Pending {
        let expectedAction: ChromeControlEffect
        let leaseID: String?
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
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
    private let requestTimeout: Duration
    private var readTask: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var activeLeaseIDs: Set<String> = []
    /// leaseId -> (event, reason) for leases Chrome has ENDED, kept so the
    /// next call naming a dead lease gets the cause instead of a bare
    /// `lease_not_found` from the extension. Bounded.
    private var endedLeases: [String: (event: String, reason: String)] = [:]
    private var endedLeaseOrder: [String] = []
    private static let endedLeaseMemory = 16
    private var closed = false

    init(descriptor: Int32, requestTimeout: Duration = .seconds(30)) {
        socket = ChromeSocketHandle(descriptor: descriptor)
        self.requestTimeout = requestTimeout
    }

    func start() {
        guard readTask == nil, let handle = socket.fileHandle() else { return }
        let framer = self.framer
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                while let data = try framer.readMessage(from: handle) {
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
        guard !closed, socket.isOpen else {
            throw ChromeControlRuntimeError.disconnected
        }
        // ITEM 10a. This lease already ended and Chrome said why. Send nothing
        // and answer with the reason rather than letting the extension reply
        // `lease_not_found` and calling that the whole story.
        if let ended = leaseEndedError(forPayload: payload) { throw ended }
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
                    leaseID: { if case .string(let id)? = payload["leaseId"] { id } else { nil } }(),
                    continuation: continuation,
                    timeout: timeout,
                    dispatch: dispatch
                )
                enqueueWrite(data, dispatch: dispatch) { [weak self] error in
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

    func shutdown(releaseLeases: Bool, error: Error = ChromeControlRuntimeError.disabled) {
        guard !closed else { return }
        if releaseLeases {
            for leaseID in activeLeaseIDs.sorted() {
                sendLeaseRelease(leaseID)
            }
        }
        closed = true
        activeLeaseIDs.removeAll()
        closeSocket(drainingWrites: releaseLeases)
        readTask?.cancel()
        readTask = nil
        failPending(error)
    }

    func activeLeaseCount() -> Int { activeLeaseIDs.count }

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
            // cannot settle the wrong action or corrupt lease ownership.
            connectionEnded(error: ChromeControlRuntimeError.invalidResponse)
            return
        }
        pending.removeValue(forKey: id)
        row.timeout.cancel()
        if ok {
            if row.expectedAction == .acquire,
               case .object(let result)? = object["result"],
               case .string(let leaseID)? = result["leaseId"] {
                activeLeaseIDs.insert(leaseID)
            } else if row.expectedAction == .release,
                      case .object(let result)? = object["result"],
                      case .string(let leaseID)? = result["leaseId"] {
                activeLeaseIDs.remove(leaseID)
            }
            row.continuation.resume(returning: value)
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
            row.continuation.resume(throwing: ChromeControlRuntimeError.extensionRejected(
                code: code,
                message: message
            ))
        }
    }

    private func applyEvent(_ object: [String: JSONValue]) {
        guard case .string(let event)? = object["event"],
              case .object(let payload)? = object["payload"],
              case .string(let leaseID)? = payload["leaseId"] else { return }
        if event == "lease.granted" {
            activeLeaseIDs.insert(leaseID)
            endedLeases.removeValue(forKey: leaseID)
            endedLeaseOrder.removeAll { $0 == leaseID }
        } else if event == "lease.yielded" || event == "lease.released" {
            activeLeaseIDs.remove(leaseID)
            // ITEM 10a. The extension told us WHY. Keep it, and spend it: on
            // the call already in flight against this lease, and on the next
            // one that names it.
            let reason: String
            if case .string(let detail)? = payload["reason"] { reason = detail } else { reason = "" }
            noteLeaseEnded(leaseID, event: event, reason: reason)
            failPending(forLease: leaseID, error: ChromeControlRuntimeError.leaseEnded(
                leaseID: leaseID, event: event, reason: reason
            ))
        }
    }

    /// Bounded memory of why a lease ended, so the answer survives long enough
    /// to reach the next tool call without becoming an unbounded map.
    private func noteLeaseEnded(_ leaseID: String, event: String, reason: String) {
        if endedLeases[leaseID] == nil { endedLeaseOrder.append(leaseID) }
        endedLeases[leaseID] = (event, reason)
        while endedLeaseOrder.count > Self.endedLeaseMemory {
            let evicted = endedLeaseOrder.removeFirst()
            endedLeases.removeValue(forKey: evicted)
        }
    }

    private func leaseEndedError(forPayload payload: [String: JSONValue]) -> Error? {
        guard case .string(let leaseID)? = payload["leaseId"],
              !leaseID.isEmpty,
              let ended = endedLeases[leaseID] else { return nil }
        return ChromeControlRuntimeError.leaseEnded(
            leaseID: leaseID, event: ended.event, reason: ended.reason
        )
    }

    private func failPending(forLease leaseID: String, error: Error) {
        // Chrome emits the lease-ending event before answering lease.release.
        // Keep that request pending for its explicit success or refusal.
        let doomed = pending.filter {
            $0.value.leaseID == leaseID && $0.value.expectedAction != .release
        }.map(\.key)
        for id in doomed {
            guard let row = pending.removeValue(forKey: id) else { continue }
            row.timeout.cancel()
            // A yield does not undo what the page already did, so an effect
            // still reports its outcome as unknown — but now with the cause
            // named instead of a bare timeout.
            row.continuation.resume(throwing: row.unconfirmedFailure(error))
        }
    }

    /// Hand one frame to the serial write queue. The failure callback fires
    /// only when the write itself threw; a request already settled by timeout
    /// or cancellation no longer has a row and is left alone.
    private nonisolated func enqueueWrite(
        _ data: Data,
        dispatch: ChromeRequestDispatch? = nil,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        let framer = self.framer
        let socket = self.socket
        writeQueue.async {
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

    /// 2026-09-06: teardown used to close the socket the instant after
    /// queueing the lease releases, so those releases raced the close and
    /// mostly lost. Shutdown now waits for the queue to drain first. The wait
    /// is bounded: a Chrome that has stopped draining its end must not park
    /// this actor forever — the write queue exists to prevent exactly that.
    private nonisolated func closeSocket(drainingWrites: Bool) {
        if drainingWrites {
            let drained = DispatchSemaphore(value: 0)
            writeQueue.async { drained.signal() }
            _ = drained.wait(timeout: .now() + 5)
        }
        let socket = self.socket
        socket.close()
        writeQueue.async { socket.closeWriteSide() }
    }

    private func failWrite(id: String, error: Error) {
        guard let row = pending.removeValue(forKey: id) else { return }
        row.timeout.cancel()
        // FileHandle may report a write failure after a frame prefix or payload
        // reached the relay. For an effect, transport failure is therefore not
        // proof that Chrome did nothing and must not invite a blind retry.
        row.continuation.resume(throwing: row.unconfirmedFailure(error))
    }

    private func timeoutRequest(_ id: String) {
        guard let row = pending.removeValue(forKey: id) else { return }
        row.timeout.cancel()
        row.continuation.resume(throwing: row.unconfirmedFailure(ChromeControlRuntimeError.requestTimedOut))
    }

    private func cancelRequest(_ id: String) {
        guard let row = pending.removeValue(forKey: id) else { return }
        row.timeout.cancel()
        let started = row.dispatch.cancel()
        if started, row.expectedAction == .type, let leaseID = row.leaseID {
            // A delayed type action may be between characters. Revoking its
            // lease stops the content loop without closing the user's tab.
            sendLeaseRelease(leaseID)
        }
        // Task cancellation remains cancellation, not proof that a dispatched
        // browser effect was rolled back or safe to repeat.
        row.continuation.resume(throwing: CancellationError())
    }

    private func sendLeaseRelease(_ leaseID: String) {
        guard !closed, socket.isOpen else { return }
        let envelope = JSONValue.object([
            "version": .int(1),
            "type": .string("request"),
            "id": .string("cleanup-\(UUID().uuidString.lowercased())"),
            "action": .string(ChromeControlEffect.release.rawValue),
            "payload": .object([
                "leaseId": .string(leaseID),
                "closeCreatedTab": .bool(false),
            ]),
        ])
        if let data = try? envelope.serializedData(pretty: false) {
            // Off the actor for the same reason: a lease release is sent from
            // shutdown and from cancellation, and neither may be parked behind
            // a socket Chrome has stopped draining.
            enqueueWrite(data) { _ in }
        }
    }

    private func connectionEnded(error: Error) {
        guard !closed else { return }
        closed = true
        activeLeaseIDs.removeAll()
        closeSocket(drainingWrites: false)
        readTask?.cancel()
        readTask = nil
        failPending(error)
    }

    private func failPending(_ error: Error) {
        let rows = pending.values
        pending.removeAll()
        for row in rows {
            row.timeout.cancel()
            row.continuation.resume(throwing: row.unconfirmedFailure(error))
        }
    }
}

/// 2026-09-06: the control socket lives in a 0700 directory as a 0600 socket,
/// so only this Mac user can reach it — but every process running as that user
/// could, and acceptance authenticated nothing before handing the newcomer the
/// live channel (leases and all). The app mints a per-launch secret, writes it
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
    static func connectionIsProven(
        descriptor: Int32, expecting: Set<String>, token: String
    ) -> Bool {
        guard !expecting.isEmpty else { return readHello(descriptor: descriptor, token: token) != nil }
        guard let pid = peerProcessID(descriptor: descriptor),
              let peer = ChromeHostIdentity.executablePath(ofProcess: pid) else {
            NSLog("[NativeAgent] Chrome control refused a connection with no readable peer pid.")
            return false
        }
        let resolved = URL(fileURLWithPath: peer).resolvingSymlinksInPath().path
        guard expecting.contains(resolved) else {
            NSLog("[NativeAgent] Chrome control refused a connection from an unexpected peer executable.")
            return false
        }
        // 2026-09-06: a path is replaceable. Require the running relay to carry
        // this app's designated signer constraint, including in the orphan case.
        guard ChromeSocketIdentity.peerIsTrusted(
            descriptor: descriptor, identifiers: ["NativeAgentChromeRelay"]
        ) else {
            NSLog("[NativeAgent] Chrome control refused a relay with an unexpected code identity.")
            return false
        }
        guard let parent = ChromeHostIdentity.parentProcessID(of: pid) else {
            NSLog("[NativeAgent] Chrome control refused a relay whose parent could not be read.")
            return false
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
            NSLog("[NativeAgent] Chrome control refused a relay whose parent is not a browser.")
            return false
        }
        guard let hello = readHello(descriptor: descriptor, token: token) else { return false }
        if parentIsBrowser { return true }
        // The fallback admits only a peer that is already this app's registered
        // relay AND whose running code matches this app's signer: that binary
        // refuses to start unless a signed browser launched it, so its account
        // of its own parent is worth something. A relay swapped for one that
        // reports whatever it likes fails the signature check.
        guard helloCarriesParentEvidence(hello) else {
            NSLog("[NativeAgent] Chrome control refused a reparented relay with no launch-time parent evidence.")
            return false
        }
        return true
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
    static func readHello(descriptor: Int32, token: String) -> [String: JSONValue]? {
        let deadline = Date().addingTimeInterval(TimeInterval(helloSeconds))
        defer {
            var none = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(
                descriptor, SOL_SOCKET, SO_RCVTIMEO,
                &none, socklen_t(MemoryLayout<timeval>.size)
            )
        }
        let framer = NativeMessagingFramer()
        let hello = try? framer.readMessage { count in
            // Each read gets only what is left of the whole hello's budget, so
            // the loop above cannot be kept alive one byte at a time.
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.001 else { return Data() }
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
            guard received > 0 else { return Data() }
            return Data(buffer.prefix(received))
        }
        guard let hello,
              let value = try? JSONValue.parse(hello),
              case .object(let object) = value,
              case .int(1)? = object["version"],
              case .string("hello")? = object["type"],
              case .string(let presented)? = object["token"],
              !token.isEmpty, presented == token
        else { return nil }
        return object
    }
}

actor ChromeControlRuntime {
    static let shared = ChromeControlRuntime()

    typealias Authority = @Sendable () async -> Bool

    private let authority: Authority
    private let socketPath: String
    private let manageNativeHostRegistration: Bool
    private var listenerDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var channel: ChromeControlChannel?
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

    init(
        socketPath: String = ChromeControlRuntime.defaultSocketPath(),
        manageNativeHostRegistration: Bool = true,
        authority: @escaping Authority = {
            await SwiftNativeTrustCenter(dataRoot: NativeAgentPaths.dataRoot)
                .chromeControlEnabledChecked()
        }
    ) {
        self.socketPath = socketPath
        self.manageNativeHostRegistration = manageNativeHostRegistration
        self.authority = authority
    }

    func reconcilePolicy() async {
        policyGeneration &+= 1
        let generation = policyGeneration
        let enabled = await authority()
        guard generation == policyGeneration else { return }
        guard enabled else {
            await stopLocked(releaseLeases: true)
            guard generation == policyGeneration else { return }
            if manageNativeHostRegistration { try? ChromeNativeHostRegistration.uninstall() }
            return
        }
        do {
            try startListenerIfNeeded()
            if manageNativeHostRegistration { try ChromeNativeHostRegistration.install() }
        } catch {
            await stopLocked(releaseLeases: false)
        }
    }

    func perform(_ effect: ChromeControlEffect, payload: [String: JSONValue]) async throws -> JSONValue {
        if effect.requiresEffectTimeAuthorization {
            guard await authority() else {
                await stopLocked(releaseLeases: true)
                throw ChromeControlRuntimeError.disabled
            }
        }
        guard let channel else { throw ChromeControlRuntimeError.disconnected }
        return try await channel.request(action: effect, payload: payload)
    }

    func stop() async {
        policyGeneration &+= 1
        await stopLocked(releaseLeases: true)
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

    private func finishHandshake(_ descriptor: Int32, generation: UInt64, proven: Bool) async {
        guard handshakingDescriptors[descriptor] == generation else { return }
        handshakingDescriptors.removeValue(forKey: descriptor)
        guard proven, generation == listenerGeneration else {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            return
        }
        // 2026-09-06: answer the greeting BEFORE the channel takes the
        // descriptor, so the ack is the first frame the relay reads on this
        // connection and nothing the channel sends can precede it.
        ChromeControlHandshake.sendHelloAck(descriptor: descriptor, generation: generation)
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
        socketIdentity = FileIdentity(path: socketPath)
        listenerGeneration &+= 1
        let generation = listenerGeneration
        let expectedPeers = expectedPeerExecutablePaths()
        acceptTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let accepted = Darwin.accept(descriptor, nil, nil)
                if accepted < 0 { break }
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
                let proven = ChromeControlHandshake.connectionIsProven(
                    descriptor: accepted, expecting: expectedPeers, token: token
                )
                await self.finishHandshake(accepted, generation: generation, proven: proven)
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
              await authority(),
              listenerDescriptor >= 0 || !manageNativeHostRegistration,
              generation == listenerGeneration else {
            Darwin.close(descriptor)
            return
        }
        installationGeneration &+= 1
        let installation = installationGeneration
        if let channel { await channel.shutdown(releaseLeases: true) }
        // Shutdown suspends: a stop or a newer accepted connection retires
        // this installation before it can publish a channel.
        guard generation == listenerGeneration,
              installation == installationGeneration else {
            Darwin.close(descriptor)
            return
        }
        let next = ChromeControlChannel(descriptor: descriptor)
        channel = next
        await next.start()
    }

    private func stopLocked(releaseLeases: Bool) async {
        let existing = channel
        channel = nil
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
            await existing.shutdown(releaseLeases: releaseLeases)
        }
    }

    static func defaultSocketPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NativeAgent", isDirectory: true)
            .appendingPathComponent("chrome-control.sock")
            .path
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

enum ChromeNativeHostRegistration {
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
        relayURL: URL? = nil
    ) throws {
        let relay = relayURL ?? bundledRelayURL()
        guard relay.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: relay.path) else {
            throw ChromeControlRuntimeError.relayUnavailable
        }
        let directory = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": hostID,
            "description": "NativeAgent Chrome transport relay",
            "path": relay.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let destination = directory.appendingPathComponent("\(hostID).json")
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let destination = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(hostID).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }
}
