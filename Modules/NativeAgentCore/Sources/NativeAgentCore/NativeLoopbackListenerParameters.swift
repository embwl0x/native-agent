import Foundation
import NativeAgentShared
import Darwin
import Network
// Blueprint: | `NativeLoopbackListenerParameters.swift` | Loopback listener construction, generation and rebind lifecycle; one retained, cancellable two-second port diagnostic, with admission held through process exit and stale generations excluded from publication |

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

/// Socket-lifecycle tissue shared by the three resident loopback adapters.
/// It owns listener identity, cancellation and its bounded port diagnostic. Tokens, descriptors,
/// request policy, effects, and verification remain with each bridge/browser
/// owner. Each install listens on its own fixed port (InstallPaths
/// .loopbackPorts); a port another process holds is a failure naming that
/// process, never a hop to another port.
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

    /// What Doctor shows: the install's fixed port, whether it is bound, and
    /// why the listener gave up, if it did.
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

    /// A taken port is said with its holder; any other error as it came.
    private func fail(_ error: Error, generation attempt: UInt64) {
        guard NativeLoopbackListenerParameters.isAddressInUse(error) else {
            nativeLog("[\(label)] listener failed: \(error)")
            recordFailure("\(error)", generation: attempt)
            finish(generation: attempt)
            return
        }
        lock.lock()
        guard generation == attempt, callbacks != nil else { lock.unlock(); return }
        failure = "port \(port) is held by another process"
        let next: ListeningProcessDiagnostic?
        if diagnostic == nil {
            let id = UUID()
            next = ListeningProcessDiagnostic(id: id, port: port) { [weak self] holder in
                self?.diagnosticFinished(id: id, generation: attempt, holder: holder)
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

    private func diagnosticFinished(id: UUID, generation attempt: UInt64, holder: String?) {
        lock.lock()
        guard diagnostic?.id == id else { lock.unlock(); return }
        diagnostic = nil
        guard generation == attempt else { lock.unlock(); return }
        let holder = holder ?? "a process lsof could not name"
        failure = "port \(port) is held by \(holder)"
        lock.unlock()
        nativeLog("[\(label)] port \(port) is held by \(holder); not listening")
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

/// One read-only `lsof`, stopped after two seconds or owner cancellation.
/// The listener retains admission until termination; no timeout joins a worker.
private final class ListeningProcessDiagnostic: @unchecked Sendable {
    let id: UUID
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private let completion: @Sendable (String?) -> Void
    private var drain: ProcessPipeDrain?
    private var deadline: DispatchSourceTimer?
    private var bytes = Data()
    private var cancelled = false
    private var finished = false
    private var launched = false

    init(id: UUID, port: UInt16, completion: @escaping @Sendable (String?) -> Void) {
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
                    self.bytes.append(chunk.prefix(max(0, 65_536 - self.bytes.count)))
                }
            }
            process.terminationHandler = { [self] _ in finish() }
            // Serialize launch with cancel so stop cannot miss an unlaunched PID.
            try process.run()
            launched = true
            try? pipe.fileHandleForWriting.close()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.setEventHandler { [weak self] in self?.cancel() }
            timer.schedule(deadline: .now() + 2)
            deadline = timer
            timer.resume()
            lock.unlock()
        } catch {
            lock.unlock()
            finish()
        }
    }

    func cancel() {
        lock.withLock {
            guard !finished else { return }
            cancelled = true
            deadline?.cancel()
            if launched, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let valid = launched && !cancelled && process.terminationStatus == 0
        let drain = self.drain
        self.drain = nil
        deadline?.cancel()
        deadline = nil
        process.terminationHandler = nil
        try? pipe.fileHandleForWriting.close()
        lock.unlock()
        // EOF is not awaited: the existing drain performs only bounded,
        // nonblocking reads, then closes even if a writer retained the pipe.
        drain?.stopAndWait()
        if drain == nil { try? pipe.fileHandleForReading.close() }
        let output = lock.withLock { String(decoding: bytes, as: UTF8.self) }
        var pid: String?
        var command: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
        }
        completion(valid ? pid.map { "\(command ?? "unknown") (pid \($0))" } : nil)
    }
}
