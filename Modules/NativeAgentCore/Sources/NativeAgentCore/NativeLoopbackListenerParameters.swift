import Foundation
import NativeAgentShared
import Darwin
import Network
// Blueprint: | `NativeLoopbackListenerParameters.swift` | Fixed-port listeners and retained bounded diagnostics |

private let nativeLog = ModuleLog(category: "NativeAgentApp")

enum NativeLoopbackListenerParameters {
    static func tcp() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    static func makeListener(port: UInt16) throws -> NWListener {
        guard port != 0, let fixed = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        return try NWListener(using: tcp(), on: fixed)
    }

    static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(.EADDRINUSE) = error { return true }
        return false
    }

    static func isAddressInUse(_ error: Error) -> Bool {
        if let networkError = error as? NWError {
            return isAddressInUse(networkError)
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(POSIXErrorCode.EADDRINUSE.rawValue)
    }
}

/// Socket-lifecycle tissue shared by the three resident loopback adapters. It owns listener identity, cancellation and its port diagnostic. Tokens,
/// descriptors, request policy, effects, and verification remain with each bridge/browser owner. Each install listens on its own fixed port (InstallPaths
/// .loopbackPorts); a port another process holds is a failure naming that process, never a hop to another port.
public final class NativeLoopbackListener: @unchecked Sendable {
    private struct Callbacks: @unchecked Sendable {
        let ready: @Sendable (UInt16) -> Void
        let connection: @Sendable (NWConnection) -> Void
        let terminated: @Sendable () -> Void
    }

    private let port: UInt16
    private let label: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listener: NWListener?
    private var callbacks: Callbacks?
    private var generation: UInt64 = 0
    private var boundPort: UInt16?
    private var failure: String?
    // Kept through actual process exit, even after stop or a new bind attempt.
    private var diagnostic: ListeningProcessDiagnostic?

    public struct Health: Sendable {
        public let port: UInt16
        public let boundPort: UInt16?
        public let isActive: Bool
        public let failure: String?
    }

    public var health: Health {
        lock.lock(); defer { lock.unlock() }
        return Health(port: port, boundPort: boundPort, isActive: callbacks != nil, failure: failure)
    }

    public init(port: UInt16, label: String) {
        self.port = port
        self.label = label
        queue = DispatchQueue(label: "nativeagent.loopback.\(label)", qos: .userInitiated)
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return callbacks != nil
    }

    @discardableResult
    public func start(
        onReady: @escaping @Sendable (UInt16) -> Void,
        onConnection: @escaping @Sendable (NWConnection) -> Void,
        onTerminated: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        guard callbacks == nil else {
            lock.unlock()
            return false
        }
        generation &+= 1
        let attempt = generation
        boundPort = nil
        failure = nil
        callbacks = Callbacks(
            ready: onReady,
            connection: onConnection,
            terminated: onTerminated
        )
        let oldDiagnostic = diagnostic
        lock.unlock()
        oldDiagnostic?.cancel()
        queue.async { [weak self] in
            self?.install(generation: attempt)
        }
        return true
    }

    public func stop() {
        lock.lock()
        generation &+= 1
        let oldListener = listener
        listener = nil
        callbacks = nil
        boundPort = nil
        let oldDiagnostic = diagnostic
        lock.unlock()
        oldListener?.cancel()
        oldDiagnostic?.cancel()
    }

    deinit { stop() }

    private func install(generation attempt: UInt64) {
        guard lock.withLock({ generation == attempt && callbacks != nil }) else { return }
        let nextListener: NWListener
        do {
            nextListener = try NativeLoopbackListenerParameters.makeListener(port: port)
        } catch {
            fail(error, generation: attempt)
            return
        }

        let ident = ObjectIdentifier(nextListener)
        nextListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.ready(ident: ident, generation: attempt)
            case .failed(let error):
                self?.failed(ident: ident, generation: attempt, error: error)
            case .cancelled:
                self?.cancelled(ident: ident, generation: attempt)
            default:
                break
            }
        }
        nextListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, ident: ident, generation: attempt)
        }

        lock.lock()
        guard generation == attempt, callbacks != nil, listener == nil else {
            lock.unlock()
            nextListener.cancel()
            return
        }
        listener = nextListener
        lock.unlock()
        nextListener.start(queue: queue)
    }

    private func ready(ident: ObjectIdentifier, generation attempt: UInt64) {
        lock.lock()
        guard generation == attempt,
              let listener,
              ObjectIdentifier(listener) == ident,
              let bound = listener.port?.rawValue,
              bound == port else {
            lock.unlock()
            return
        }
        boundPort = bound
        let ready = callbacks?.ready
        lock.unlock()
        ready?(bound)
    }

    private func failed(ident: ObjectIdentifier, generation attempt: UInt64, error: NWError) {
        lock.lock()
        guard generation == attempt,
              let listener,
              ObjectIdentifier(listener) == ident else {
            lock.unlock()
            return
        }
        self.listener = nil
        lock.unlock()
        fail(error, generation: attempt)
    }

    private func fail(_ error: Error, generation attempt: UInt64) {
        guard NativeLoopbackListenerParameters.isAddressInUse(error) else {
            nativeLog("[\(label)] listener failed: \(error)")
            recordFailure("\(error)", generation: attempt)
            finish(generation: attempt)
            return
        }
        lock.lock()
        guard generation == attempt, callbacks != nil else { lock.unlock(); return }
        failure = "bind failed on port \(port): address in use; waiting on lsof for the listener's identity"
        let next: ListeningProcessDiagnostic?
        if diagnostic == nil {
            let id = UUID()
            next = ListeningProcessDiagnostic(id: id, port: port) { [weak self] outcome in
                self?.diagnosticFinished(id: id, generation: attempt, outcome: outcome)
            }
            diagnostic = next
        } else {
            // A cancelled diagnostic still owns its slot until actual exit.
            next = nil
        }
        lock.unlock()
        finish(generation: attempt)
        next?.start()
    }

    private func diagnosticFinished(id: UUID, generation attempt: UInt64, outcome: ListeningProcessDiagnostic.Outcome) {
        lock.lock()
        guard diagnostic?.id == id else { lock.unlock(); return }
        diagnostic = nil
        guard generation == attempt else { lock.unlock(); return }
        let detail: String
        switch outcome {
        case .holder(let holder): detail = "bind failed on port \(port): address in use by \(holder)"
        case .unavailable(let why): detail = "bind failed on port \(port): address in use; process diagnosis unavailable: \(why)"
        }
        failure = detail
        lock.unlock()
        nativeLog("[\(label)] \(detail); not listening")
    }

    private func recordFailure(_ detail: String, generation attempt: UInt64) {
        lock.lock()
        if generation == attempt { failure = detail }
        lock.unlock()
    }

    private func cancelled(ident: ObjectIdentifier, generation attempt: UInt64) {
        lock.lock()
        guard generation == attempt,
              let listener,
              ObjectIdentifier(listener) == ident else {
            lock.unlock()
            return
        }
        self.listener = nil
        lock.unlock()
        nativeLog("[\(label)] listener was cancelled")
        recordFailure("the listener was cancelled", generation: attempt)
        finish(generation: attempt)
    }

    private func accept(
        _ connection: NWConnection,
        ident: ObjectIdentifier,
        generation attempt: UInt64
    ) {
        lock.lock()
        guard generation == attempt,
              let listener,
              ObjectIdentifier(listener) == ident,
              let accept = callbacks?.connection else {
            lock.unlock()
            connection.cancel()
            return
        }
        lock.unlock()
        accept(connection)
    }

    private func finish(generation attempt: UInt64) {
        lock.lock()
        guard generation == attempt, callbacks != nil else {
            lock.unlock()
            return
        }
        listener = nil
        boundPort = nil
        let terminated = callbacks?.terminated
        callbacks = nil
        lock.unlock()
        terminated?()
    }

}

/// One read-only `lsof`, settled by process exit and pipe EOF or owner cancellation.
private final class ListeningProcessDiagnostic: @unchecked Sendable {
    enum Outcome: Sendable {
        case holder(String)
        case unavailable(String)
    }

    let id: UUID
    private let lock = NSLock()
    private let process = ManagedProcess()
    private let pipe = Pipe()
    private let completion: @Sendable (Outcome) -> Void
    private var drain: ProcessPipeDrain?
    private var bytes = Data()
    private var truncated = false
    private var failure: String?
    private var cancelled = false
    private var finished = false
    private var settling = false
    private var launched = false

    init(id: UUID, port: UInt16, completion: @escaping @Sendable (Outcome) -> Void) {
        self.id = id
        self.completion = completion
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nPb", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
    }

    func start() {
        lock.lock()
        guard !cancelled, !finished else { lock.unlock(); finish(); return }
        do {
            drain = try ProcessPipeDrain(handle: pipe.fileHandleForReading) { [weak self] chunk in
                self?.lock.withLock {
                    guard let self else { return }
                    let count = min(chunk.count, max(0, 65_536 - self.bytes.count))
                    self.bytes.append(chunk.prefix(count))
                    if count < chunk.count { self.truncated = true }
                }
            }
            process.terminationHandler = { [self] _ in finish() }
            // Serialize launch with cancel so stop cannot miss an unlaunched PID.
            try process.run()
            launched = true
            lock.unlock()
        } catch {
            failure = error.localizedDescription
            lock.unlock()
            finish()
        }
    }

    func cancel() {
        let stopping = lock.withLock { () -> (ProcessTreeSnapshot?, ProcessPipeDrain?) in
            guard !finished else { return (nil, nil) }
            cancelled = true
            return (launched ? process.groupSnapshot : nil, settling ? drain : nil)
        }
        if let snapshot = stopping.0 { ProcessTreeReaper.quiesceAndKill(snapshot) }
        stopping.1?.stop()
    }

    private func finish() {
        lock.lock()
        guard !finished, !settling else { lock.unlock(); return }
        settling = true
        let launched = self.launched
        let drain = self.drain
        process.terminationHandler = nil
        lock.unlock()
        if launched, process.terminationError == nil { drain?.waitForEOF() }
        else { drain?.stopAndWait() }
        let captured = lock.withLock {
            finished = true
            self.drain = nil
            return (bytes, truncated, failure, cancelled)
        }
        if let failure = captured.2 { completion(.unavailable(failure)); return }
        if let failure = process.terminationError { completion(.unavailable(failure)); return }
        guard !captured.3 else { completion(.unavailable("the listener owner cancelled diagnosis")); return }
        guard launched, process.terminationStatus == 0 else {
            completion(.unavailable("lsof exited with status \(process.terminationStatus)"))
            return
        }
        if let failure = drain?.captureFailure { completion(.unavailable(failure)); return }
        guard !captured.1 else { completion(.unavailable("lsof output exceeded its 65,536-byte diagnostic limit")); return }
        guard let output = String(data: captured.0, encoding: .utf8) else {
            completion(.unavailable("lsof output is not valid UTF-8"))
            return
        }
        var pid: String?
        var command: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
        }
        guard let pid, let command, !pid.isEmpty, !command.isEmpty else {
            completion(.unavailable("lsof returned no complete listener identity"))
            return
        }
        completion(.holder("\(command) (pid \(pid))"))
    }
}
