import Synchronization
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
public final class NativeLoopbackListener: Sendable {
    private struct Callbacks: Sendable {
        let ready: @Sendable (UInt16) -> Void
        let connection: @Sendable (NWConnection) -> Void
        let terminated: @Sendable () -> Void
    }

    private let port: UInt16
    private let label: String
    private let queue: DispatchQueue
    private struct State {
        var listener: NWListener?
        var callbacks: Callbacks?
        var generation: UInt64 = 0
        var boundPort: UInt16?
        var failure: String?
        var diagnostic: ListeningProcessDiagnostic?
    }
    private let state = Mutex(State())
    // Kept through actual process exit, even after stop or a new bind attempt.

    public struct Health: Sendable {
        public let port: UInt16
        public let boundPort: UInt16?
        public let isActive: Bool
        public let failure: String?
    }

    public var health: Health {
        state.withLock { Health(port: port, boundPort: $0.boundPort, isActive: $0.callbacks != nil, failure: $0.failure) }
    }

    public init(port: UInt16, label: String) {
        self.port = port
        self.label = label
        queue = DispatchQueue(label: "nativeagent.loopback.\(label)", qos: .userInitiated)
    }

    public var isActive: Bool {
        state.withLock { $0.callbacks != nil }
    }

    @discardableResult
    public func start(
        onReady: @escaping @Sendable (UInt16) -> Void,
        onConnection: @escaping @Sendable (NWConnection) -> Void,
        onTerminated: @escaping @Sendable () -> Void
    ) -> Bool {
        guard let (attempt, oldDiagnostic) = state.withLock({ state -> (UInt64, ListeningProcessDiagnostic?)? in
            guard state.callbacks == nil else { return nil }
            state.generation &+= 1
            state.boundPort = nil
            state.failure = nil
            state.callbacks = Callbacks(ready: onReady, connection: onConnection, terminated: onTerminated)
            return (state.generation, state.diagnostic)
        }) else { return false }
        oldDiagnostic?.cancel()
        queue.async { [weak self] in
            self?.install(generation: attempt)
        }
        return true
    }

    public func stop() {
        let (oldListener, oldDiagnostic) = state.withLock { state in
            state.generation &+= 1
            let old = state.listener
            state.listener = nil
            state.callbacks = nil
            state.boundPort = nil
            return (old, state.diagnostic)
        }
        oldListener?.cancel()
        oldDiagnostic?.cancel()
    }

    deinit { stop() }

    private func install(generation attempt: UInt64) {
        guard state.withLock({ $0.generation == attempt && $0.callbacks != nil }) else { return }
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

        let installed = state.withLock { state in
            guard state.generation == attempt, state.callbacks != nil, state.listener == nil else { return false }
            state.listener = nextListener
            return true
        }
        guard installed else { nextListener.cancel(); return }
        nextListener.start(queue: queue)
    }

    private func ready(ident: ObjectIdentifier, generation attempt: UInt64) {
        let ready = state.withLock { state -> (@Sendable (UInt16) -> Void)? in
            guard state.generation == attempt, let listener = state.listener,
                  ObjectIdentifier(listener) == ident, listener.port?.rawValue == port else { return nil }
            state.boundPort = port
            return state.callbacks?.ready
        }
        ready?(port)
    }

    private func removeListener(ident: ObjectIdentifier, generation attempt: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == attempt, let listener = state.listener, ObjectIdentifier(listener) == ident else { return false }
            state.listener = nil
            return true
        }
    }

    private func failed(ident: ObjectIdentifier, generation attempt: UInt64, error: NWError) {
        guard removeListener(ident: ident, generation: attempt) else { return }
        fail(error, generation: attempt)
    }

    private func fail(_ error: Error, generation attempt: UInt64) {
        guard NativeLoopbackListenerParameters.isAddressInUse(error) else {
            nativeLog("[\(label)] listener failed: \(error)")
            recordFailure("\(error)", generation: attempt)
            finish(generation: attempt)
            return
        }
        var next: ListeningProcessDiagnostic?
        let active = state.withLock { state in
            guard state.generation == attempt, state.callbacks != nil else { return false }
            state.failure = "bind failed on port \(port): address in use; waiting on lsof for the listener's identity"
            if state.diagnostic == nil {
                let id = UUID()
                next = ListeningProcessDiagnostic(id: id, port: port) { [weak self] outcome in
                    self?.diagnosticFinished(id: id, generation: attempt, outcome: outcome)
                }
                state.diagnostic = next
            }
            return true
        }
        guard active else { return }
        finish(generation: attempt)
        next?.start()
    }

    private func diagnosticFinished(id: UUID, generation attempt: UInt64, outcome: ListeningProcessDiagnostic.Outcome) {
        let detail: String
        switch outcome {
        case .holder(let holder): detail = "bind failed on port \(port): address in use by \(holder)"
        case .unavailable(let why): detail = "bind failed on port \(port): address in use; process diagnosis unavailable: \(why)"
        }
        let current = state.withLock { state in
            guard state.diagnostic?.id == id else { return false }
            state.diagnostic = nil
            guard state.generation == attempt else { return false }
            state.failure = detail
            return true
        }
        guard current else { return }
        nativeLog("[\(label)] \(detail); not listening")
    }

    private func recordFailure(_ detail: String, generation attempt: UInt64) {
        state.withLock { if $0.generation == attempt { $0.failure = detail } }
    }

    private func cancelled(ident: ObjectIdentifier, generation attempt: UInt64) {
        guard removeListener(ident: ident, generation: attempt) else { return }
        nativeLog("[\(label)] listener was cancelled")
        recordFailure("the listener was cancelled", generation: attempt)
        finish(generation: attempt)
    }

    private func accept(
        _ connection: NWConnection,
        ident: ObjectIdentifier,
        generation attempt: UInt64
    ) {
        let accept = state.withLock { state -> (@Sendable (NWConnection) -> Void)? in
            guard state.generation == attempt, let listener = state.listener, ObjectIdentifier(listener) == ident else { return nil }
            return state.callbacks?.connection
        }
        guard let accept else { connection.cancel(); return }
        accept(connection)
    }

    private func finish(generation attempt: UInt64) {
        let terminated = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.generation == attempt, let callbacks = state.callbacks else { return nil }
            state.listener = nil
            state.boundPort = nil
            state.callbacks = nil
            return callbacks.terminated
        }
        terminated?()
    }

}

/// One read-only `lsof`, settled by process exit and pipe EOF or owner cancellation.
private final class ListeningProcessDiagnostic: Sendable {
    enum Outcome: Sendable {
        case holder(String)
        case unavailable(String)
    }

    let id: UUID
    private struct State {
        var drain: ProcessPipeDrain?
        var bytes = Data()
        var truncated = false
        var failure: String?
        var cancelled = false
        var finished = false
        var settling = false
        var launched = false
    }
    private let state = Mutex(State())
    private let process = ManagedProcess()
    private let pipe = Pipe()
    private let completion: @Sendable (Outcome) -> Void

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
        let started = state.withLock { state in
            guard !state.cancelled, !state.finished else { return false }
            do {
                state.drain = try ProcessPipeDrain(handle: pipe.fileHandleForReading) { [weak self] chunk in
                    self?.state.withLock { state in
                        let count = min(chunk.count, max(0, 65_536 - state.bytes.count))
                        state.bytes.append(chunk.prefix(count))
                        if count < chunk.count { state.truncated = true }
                    }
                }
                process.terminationHandler = { [self] _ in finish() }
                try process.run()
                state.launched = true
                return true
            } catch {
                state.failure = error.localizedDescription
                return false
            }
        }
        if !started { finish() }
    }

    func cancel() {
        let stopping = state.withLock { state -> (ProcessTreeSnapshot?, ProcessPipeDrain?) in
            guard !state.finished else { return (nil, nil) }
            state.cancelled = true
            return (state.launched ? process.groupSnapshot : nil, state.settling ? state.drain : nil)
        }
        if let snapshot = stopping.0 { ProcessTreeReaper.quiesceAndKill(snapshot) }
        stopping.1?.stop()
    }

    private func finish() {
        guard let (launched, drain) = state.withLock({ state -> (Bool, ProcessPipeDrain?)? in
            guard !state.finished, !state.settling else { return nil }
            state.settling = true
            process.terminationHandler = nil
            return (state.launched, state.drain)
        }) else { return }
        if launched, process.terminationError == nil { drain?.waitForEOF() }
        else { drain?.stopAndWait() }
        let captured = state.withLock { state in
            state.finished = true
            state.drain = nil
            return (state.bytes, state.truncated, state.failure, state.cancelled)
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
