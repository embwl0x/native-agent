import Foundation
import Darwin
import Network

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
/// It owns only listener identity and cancellation. Tokens, descriptors,
/// request policy, effects, and verification remain with each bridge/browser
/// owner. Each install listens on its own fixed port (InstallPaths
/// .loopbackPorts); a port another process holds is a failure naming that
/// process, never a hop to another port.
final class NativeLoopbackListener: @unchecked Sendable {
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

    /// What Doctor shows: the install's fixed port, whether it is bound, and
    /// why the listener gave up, if it did.
    struct Health: Sendable {
        let port: UInt16
        let boundPort: UInt16?
        let isActive: Bool
        let failure: String?
    }

    var health: Health {
        lock.lock(); defer { lock.unlock() }
        return Health(port: port, boundPort: boundPort, isActive: callbacks != nil, failure: failure)
    }

    init(port: UInt16, label: String) {
        self.port = port
        self.label = label
        queue = DispatchQueue(label: "nativeagent.loopback.\(label)", qos: .userInitiated)
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return callbacks != nil
    }

    @discardableResult
    func start(
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
        lock.unlock()
        queue.async { [weak self] in
            self?.install(generation: attempt)
        }
        return true
    }

    func stop() {
        lock.lock()
        generation &+= 1
        let oldListener = listener
        listener = nil
        callbacks = nil
        boundPort = nil
        lock.unlock()
        oldListener?.cancel()
    }

    private func install(generation attempt: UInt64) {
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
        let port = port, label = label
        recordFailure("port \(port) is held by another process", generation: attempt)
        finish(generation: attempt)
        Task.detached(priority: .utility) { [weak self] in
            let holder = await Self.listeningProcess(on: port) ?? "a process lsof could not name"
            nativeLog("[\(label)] port \(port) is held by \(holder); not listening")
            self?.recordFailure("port \(port) is held by \(holder)", generation: attempt)
        }
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

    /// `lsof` for the process listening on a loopback port: "name (pid N)".
    static func listeningProcess(on port: UInt16) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nPb", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                var pid: String?
                var command: String?
                for line in output.split(separator: "\n") {
                    if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
                    if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
                }
                guard let pid else { return continuation.resume(returning: nil) }
                continuation.resume(returning: "\(command ?? "unknown") (pid \(pid))")
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
