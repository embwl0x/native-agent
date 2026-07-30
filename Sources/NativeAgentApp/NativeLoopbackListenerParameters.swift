import Foundation
import Darwin
import Network

/// Preferred ports stay stable for existing clients. When one is occupied,
/// resident loopback services walk the next few consecutive ports and finally
/// ask the OS for an ephemeral port. The selected port must be published by the
/// service's authenticated descriptor; callers must not guess it.
enum NativeLoopbackPortCandidate: Sendable, Equatable {
    case fixed(UInt16)
    case automatic

    var networkPort: NWEndpoint.Port {
        switch self {
        case .fixed(let port):
            return NWEndpoint.Port(rawValue: port) ?? .any
        case .automatic:
            return .any
        }
    }
}

struct NativeLoopbackPortPlan: Sendable, Equatable {
    static let defaultConsecutiveFallbacks = 15

    let candidates: [NativeLoopbackPortCandidate]

    init(
        preferredPort: UInt16,
        consecutiveFallbacks: Int = defaultConsecutiveFallbacks
    ) {
        let boundedFallbacks = max(0, consecutiveFallbacks)
        let upper = min(Int(UInt16.max), Int(preferredPort) + boundedFallbacks)
        var planned = (Int(preferredPort)...upper).map {
            NativeLoopbackPortCandidate.fixed(UInt16($0))
        }
        planned.append(.automatic)
        candidates = planned
    }

    subscript(index: Int) -> NativeLoopbackPortCandidate? {
        candidates.indices.contains(index) ? candidates[index] : nil
    }
}

enum NativeLoopbackListenerParameters {
    static func tcp() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    static func makeListener(candidate: NativeLoopbackPortCandidate) throws -> NWListener {
        try NWListener(using: tcp(), on: candidate.networkPort)
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

enum NativePrivateFile {
    /// Atomically replaces one private discovery/credential file with mode
    /// 0600 set at creation, so no chmod-after-write exposure window exists.
    @discardableResult
    static func write(_ data: Data, to destination: URL) -> Bool {
        let destinationPath = destination.path
        let temporaryPath = destinationPath + ".tmp"
        _ = temporaryPath.withCString { Darwin.unlink($0) }

        let descriptor = temporaryPath.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else { return false }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let wrote = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard wrote > 0 else { return false }
                offset += wrote
            }
            return true
        }
        Darwin.close(descriptor)
        guard wroteAll else {
            _ = temporaryPath.withCString { Darwin.unlink($0) }
            return false
        }
        let renamed = temporaryPath.withCString { source in
            destinationPath.withCString { Darwin.rename(source, $0) }
        }
        if renamed != 0 {
            _ = temporaryPath.withCString { Darwin.unlink($0) }
            return false
        }
        return true
    }
}

/// Socket-lifecycle tissue shared by the three resident loopback adapters.
/// It owns only listener identity, collision retry, and cancellation. Tokens,
/// descriptors, request policy, effects, and verification remain with each
/// bridge/browser owner.
final class NativeLoopbackPortFallbackListener: @unchecked Sendable {
    private struct Callbacks: @unchecked Sendable {
        let ready: @Sendable (UInt16) -> Void
        let connection: @Sendable (NWConnection) -> Void
        let terminated: @Sendable () -> Void
    }

    private let plan: NativeLoopbackPortPlan
    private let label: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listener: NWListener?
    private var callbacks: Callbacks?
    private var generation: UInt64 = 0

    init(preferredPort: UInt16, label: String) {
        plan = NativeLoopbackPortPlan(preferredPort: preferredPort)
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
        callbacks = Callbacks(
            ready: onReady,
            connection: onConnection,
            terminated: onTerminated
        )
        lock.unlock()
        queue.async { [weak self] in
            self?.install(candidateIndex: 0, generation: attempt)
        }
        return true
    }

    func stop() {
        lock.lock()
        generation &+= 1
        let oldListener = listener
        listener = nil
        callbacks = nil
        lock.unlock()
        oldListener?.cancel()
    }

    private func install(candidateIndex: Int, generation attempt: UInt64) {
        guard let candidate = plan[candidateIndex] else {
            finish(generation: attempt)
            return
        }

        let nextListener: NWListener
        do {
            nextListener = try NativeLoopbackListenerParameters.makeListener(candidate: candidate)
        } catch {
            if NativeLoopbackListenerParameters.isAddressInUse(error),
               plan[candidateIndex + 1] != nil {
                install(candidateIndex: candidateIndex + 1, generation: attempt)
            } else {
                NSLog("[\(label)] listener creation failed: \(error)")
                finish(generation: attempt)
            }
            return
        }

        let ident = ObjectIdentifier(nextListener)
        nextListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.ready(ident: ident, generation: attempt)
            case .failed(let error):
                self?.failed(
                    ident: ident,
                    candidateIndex: candidateIndex,
                    generation: attempt,
                    error: error
                )
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
              let port = listener.port?.rawValue,
              port != 0 else {
            lock.unlock()
            return
        }
        let ready = callbacks?.ready
        lock.unlock()
        ready?(port)
    }

    private func failed(
        ident: ObjectIdentifier,
        candidateIndex: Int,
        generation attempt: UInt64,
        error: NWError
    ) {
        lock.lock()
        guard generation == attempt,
              let listener,
              ObjectIdentifier(listener) == ident else {
            lock.unlock()
            return
        }
        self.listener = nil
        let shouldRetry = NativeLoopbackListenerParameters.isAddressInUse(error)
            && plan[candidateIndex + 1] != nil
        lock.unlock()

        if shouldRetry {
            install(candidateIndex: candidateIndex + 1, generation: attempt)
        } else {
            NSLog("[\(label)] listener failed: \(error)")
            finish(generation: attempt)
        }
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
        let terminated = callbacks?.terminated
        callbacks = nil
        lock.unlock()
        terminated?()
    }
}
