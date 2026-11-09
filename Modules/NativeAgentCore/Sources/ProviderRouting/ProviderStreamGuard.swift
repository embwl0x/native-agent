import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Synchronization
// Blueprint: | `ProviderStreamGuard.swift` | Provider HTTP session and one stream lifetime; external envelope configuration |

public struct ProviderStreamGuardConfig: Sendable, Equatable {
    public var idleTimeout: TimeInterval
    public var wallTimeout: TimeInterval
    /// Configured timeouts are finite and capped at one day for safe nanosecond conversion.
    public static let maximumTimeout: TimeInterval = 86_400

    public init(
        idleTimeout: TimeInterval = 90,
        wallTimeout: TimeInterval = 600
    ) {
        self.idleTimeout = idleTimeout
        self.wallTimeout = wallTimeout
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderStreamGuardConfig {
        let defaults = ProviderStreamGuardConfig()
        return ProviderStreamGuardConfig(
            idleTimeout: seconds(
                from: environment,
                key: "NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC",
                absent: defaults.idleTimeout
            ),
            wallTimeout: seconds(
                from: environment,
                key: "NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT_SEC",
                absent: defaults.wallTimeout
            )
        )
    }

    private static func seconds(
        from environment: [String: String],
        key: String,
        absent: TimeInterval
    ) -> TimeInterval {
        guard let raw = environment[key] else { return absent }
        // Keep invalid configuration unavailable until validate(), rather than substituting a different deadline in this nonthrowing constructor.
        return TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
    }

    public func validate() throws {
        for (key, value) in [("NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC", idleTimeout),
                             ("NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT_SEC", wallTimeout)] {
            guard value.isFinite, (0...Self.maximumTimeout).contains(value) else {
                throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                    detail: """
                        Invalid \(key): supply finite seconds in 0...86400 (zero disables this deadline). Correct the environment setting and restart \
                        NativeAgent; no request was sent.
                        """)
            }
        }
    }
}


/// Request and resource completion belong to URLSession, without an application clock.
public enum ProviderHTTP {
    public static let session: URLSession = makeSession()

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        // NetworkSense owns reachability waits; URLSession must report a failed connection instead of holding an unsent task.
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }
}

/// Headers, body and terminal delivery share the URLSession task's delegate.
public struct ProviderHTTPBytes: AsyncSequence, Sendable {
    public typealias Element = UInt8
    public let task: URLSessionDataTask
    private let chunks: AsyncThrowingStream<Data, Error>
    private let cancelTransfer: @Sendable () -> Void

    fileprivate init(task: URLSessionDataTask, chunks: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void) {
        self.task = task
        self.chunks = chunks
        cancelTransfer = cancel
    }

    public func cancel() { cancelTransfer() }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks.makeAsyncIterator()) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var chunks: AsyncThrowingStream<Data, Error>.Iterator
        private var chunk: Data.Iterator?

        fileprivate init(chunks: AsyncThrowingStream<Data, Error>.Iterator) { self.chunks = chunks }

        public mutating func next() async throws -> UInt8? {
            try Task.checkCancellation()
            while true {
                if let byte = chunk?.next() { return byte }
                guard let data = try await chunks.next() else { return nil }
                chunk = data.makeIterator()
            }
        }
    }
}

/// Completion closes the body directly, including when a system cancellation arrives before headers.
private final class ProviderHTTPTransfer: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var header: CheckedContinuation<URLResponse, Error>?
        var response: Result<URLResponse, Error>?
        var finished = false
        var observedFirstBodyBytes = false
        var task: URLSessionDataTask?
        var path: Task<Void, Never>?
    }
    private let state: Mutex<State>
    private let body: AsyncThrowingStream<Data, Error>.Continuation
    private let call: LLMCall
    private let requestID: String

    init(task: URLSessionDataTask, body: AsyncThrowingStream<Data, Error>.Continuation, call: LLMCall, requestID: String) {
        state = Mutex(State(task: task))
        self.body = body
        self.call = call
        self.requestID = requestID
    }

    func open() async throws -> URLResponse {
        let paths = NetworkSense.changes
        let observer = Task { [weak self] in
            for await up in paths {
                if Task.isCancelled { return }
                if !up {
                    self?.finish(error: ProviderFailure.Diagnostic(cause: .offline,
                        detail: "This Mac's network path became unsatisfied while the model request was open."), cancel: true)
                    return
                }
            }
        }
        let ended = state.withLock {
            if $0.finished { return true }
            $0.path = observer
            return false
        }
        if ended { observer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> (Result<URLResponse, Error>?, URLSessionDataTask?) in
                    if let response = state.response { return (response, nil) }
                    state.header = continuation
                    return (nil, state.task)
                }
                if let response = ready.0 { continuation.resume(with: response) }
                else { ready.1?.resume() }
            }
        } onCancel: {
            self.finish(error: CancellationError(), cancel: true)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let accepted = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.response = .success(response)
            var fields: [String: JSONValue] = [:]
            if let http = response as? HTTPURLResponse { fields["statusCode"] = .int(Int64(http.statusCode)) }
            trace(kind: "provider.httpHeadersOpened", fields: fields)
            state.header?.resume(returning: response)
            state.header = nil
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock {
            guard !$0.finished else { return }
            if !$0.observedFirstBodyBytes, !data.isEmpty {
                $0.observedFirstBodyBytes = true
                trace(kind: "provider.httpFirstBodyBytes", fields: ["bodyChunkBytes": .int(Int64(data.count))])
            }
            body.yield(data)
        }
    }

    private func trace(kind: String, fields: [String: JSONValue]) {
        var payload = fields
        payload["request"] = .string(requestID)
        payload["conversationRequest"] = .bool(call.conversationRequest)
        if let admission = call.admission {
            payload["provider"] = .string(admission.provider)
            payload["model"] = .string(admission.model)
            if let effort = admission.reasoningEffort { payload["reasoningEffort"] = .string(effort) }
        }
        TurnTraceBus.fireFromContext(kind: kind, surface: call.surface, payload: .object(payload), turn: call.turn)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A system-cancelled task is a transport failure unless its caller requested Stop.
        finish(error: error, cancel: false)
    }

    func finish(error: Error?, cancel: Bool) {
        let owned = state.withLock { state -> (URLSessionDataTask?, Task<Void, Never>?, Error?)? in
            guard !state.finished else { return nil }
            state.finished = true
            var terminal = error
            if state.response == nil {
                let missing = error ?? ProviderFailure.Diagnostic(cause: .malformedResponse,
                    detail: "The provider's HTTP task completed without response headers.")
                terminal = missing
                state.response = .failure(missing)
                state.header?.resume(throwing: missing)
                state.header = nil
            }
            let owned = (state.task, state.path, terminal)
            state.task = nil
            state.path = nil
            return owned
        }
        guard let owned else { return }
        owned.1?.cancel()
        if cancel { owned.0?.cancel() }
        if let error = owned.2 { body.finish(throwing: error) }
        else { body.finish() }
        let status = owned.2 == nil ? "completed" : (owned.2 is CancellationError ? "cancelled" : "failed")
        var payload: [String: JSONValue] = ["request": .string(requestID), "status": .string(status)]
        if let error = owned.2 { payload["cause"] = .string(ProviderFailure.diagnosticDescription(error)) }
        TurnTraceBus.fireFromContext(kind: "provider.httpRequestEnded", surface: call.surface, payload: .object(payload), turn: call.turn)
    }
}

/// One wire send ends on task completion, network loss or cancellation.
public enum ProviderWire {
    public static func open(_ session: URLSession, _ request: URLRequest, call: LLMCall) async throws
        -> (ProviderHTTPBytes, URLResponse) {
        await waiting(on: "network path", detail: "Waiting for this Mac's network", call: call)
        try await NetworkSense.returns()
        try Task.checkCancellation()
        var request = request
        request.timeoutInterval = .infinity
        let requestID = UUID().uuidString.lowercased()
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        let task = session.dataTask(with: request)
        let transfer = ProviderHTTPTransfer(task: task, body: pair.continuation, call: call, requestID: requestID)
        task.delegate = transfer
        pair.continuation.onTermination = { [weak transfer] ending in
            if case .cancelled = ending { transfer?.finish(error: CancellationError(), cancel: true) }
        }
        call.lifetime.sending?()
        TurnTraceBus.fireFromContext(kind: "provider.httpRequestStarted", surface: call.surface,
            payload: .object(["request": .string(requestID), "requestBodyBytes": .int(Int64(request.httpBody?.count ?? 0))]), turn: call.turn)
        call.probeCredential?.sending(request)
        let label = call.admission.map { SwiftNativeProviderRouting.displayName(for: $0.provider) } ?? request.url?.host ?? "provider"
        await waiting(on: "provider response", detail: "Waiting on \(label)", call: call)
        let response = try await transfer.open()
        call.lifetime.response?(response)
        call.lifetime.activity?()
        return (ProviderHTTPBytes(task: task, chunks: pair.stream, cancel: {
            transfer.finish(error: CancellationError(), cancel: true)
        }), response)
    }

    static func waiting(on reason: String, detail: String, call: LLMCall) async {
        let since = Date()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        await status(kind: "provider.waiting", detail: "\(detail) since \(clock.string(from: since))",
            facts: ["on": .string(reason), "since": .string(ISO8601DateFormatter().string(from: since))], call: call)
    }

    static func status(kind: String, detail: String, facts: [String: JSONValue], call: LLMCall) async {
        var payload = facts
        payload["detail"] = .string(detail)
        payload["cancel"] = .string("Stop")
        TurnTraceBus.fireFromContext(kind: kind, surface: call.surface, payload: .object(payload), turn: call.turn)
        await call.lifetime.status?(kind, detail)
    }

    static func validateChatCompletions(
        _ bytes: ProviderHTTPBytes, _ response: URLResponse,
        rejected: (Int) throws -> Void = { _ in }
    ) async throws {
        guard let response = response as? HTTPURLResponse else {
            throw ProviderFailure.Diagnostic(cause: .malformedResponse, detail: "Provider response was not HTTP.")
        }
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        let body = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096)
        try rejected(status)
        try throwIfChatCompletionsError(status: status, data: body, response: response)
    }
}

/// One turn's reconnect allowance and pending provider-prescribed wait survive every model round.
public final class ProviderRecovery: Sendable {
    public struct Stopped: Error, Sendable, LocalizedError, ProviderFailureWrapping {
        public let providerFailureCause: any Error
        let reconnectUsed: Bool
        public var errorDescription: String? {
            let reason = reconnectUsed ? "The provider request failed again; this turn stopped."
                : "The provider request cannot reconnect; this turn stopped."
            return reason + " " + ProviderFailure.diagnosticDescription(providerFailureCause)
        }
    }

    private struct Pending: Sendable {
        let cause: any Error
        let reconnect: ProviderRecoveryPolicy.Reconnect
    }
    private struct State {
        var reconnectUsed = false
        var pending: Pending?
        var waiting: Task<Result<Void, Error>, Never>?
        var stopped: Stopped?
    }
    private let state = Mutex(State())
    /// The provider whose calls this recovery serves: the first one to use it, the turn's own model.
    private let owner = Mutex<String?>(nil)
    public init() {}

    /// Whether a call on `provider` shares this recovery. A nested thought on another provider recovers on its own.
    fileprivate func serves(_ provider: String?) -> Bool {
        owner.withLock { owner in
            if owner == nil { owner = provider }
            return owner == provider
        }
    }

    public var stopped: Stopped? { state.withLock { $0.stopped } }

    fileprivate func completed(reconnecting: Bool) {
        guard reconnecting else { return }
        state.withLock {
            guard $0.reconnectUsed, $0.pending == nil, $0.waiting == nil, $0.stopped == nil else { return }
            $0.reconnectUsed = false
        }
    }

    fileprivate func failed(_ error: Error, admitted: Bool, retryAfter: Int?) -> Error {
        let normalized = ProviderFailure.normalize(error, admitted: admitted)
        if normalized is CancellationError || ProviderFailure.classify(normalized) == .outputLimit { return normalized }
        return state.withLock { state -> Error in
            if let stopped = state.stopped { return stopped }
            let failure: Error
            if let diagnostic = normalized as? ProviderFailure.Diagnostic {
                failure = ProviderFailure.Diagnostic(cause: diagnostic.cause, detail: diagnostic.detail,
                    deadlineExpired: diagnostic.deadlineExpired, admitted: diagnostic.admitted, repair: diagnostic.repair,
                    tries: state.reconnectUsed ? 2 : 1, retryAfter: diagnostic.retryAfter ?? retryAfter)
            } else { failure = normalized }
            let reconnect = ProviderRecoveryPolicy.reconnect(failure)
            if reconnect == nil, !ProviderRecoveryPolicy.isRecoverable(failure) { return failure }
            guard !state.reconnectUsed, let reconnect else {
                let stopped = Stopped(providerFailureCause: failure, reconnectUsed: state.reconnectUsed)
                state.stopped = stopped
                return stopped
            }
            state.pending = Pending(cause: failure, reconnect: reconnect)
            return failure
        }
    }

    fileprivate func beforeRequest(_ call: LLMCall) async throws -> Bool {
        try Task.checkCancellation()
        if call.replyWork?.isStopped == true { throw CancellationError() }
        let gate = state.withLock { state -> Result<Task<Result<Void, Error>, Never>?, Error> in
            if let stopped = state.stopped { return .failure(stopped) }
            if let waiting = state.waiting { return .success(waiting) }
            guard let pending = state.pending else { return .success(nil) }
            state.pending = nil
            state.reconnectUsed = true
            let waiting = Task { await Self.wait(pending, call: call) }
            state.waiting = waiting
            return .success(waiting)
        }
        let waiting = try gate.get()
        if let waiting {
            call.replyWork?.own(waiting)
            let result = await withTaskCancellationHandler { await waiting.value } onCancel: { waiting.cancel() }
            try result.get()
            state.withLock { $0.waiting = nil }
        }
        try Task.checkCancellation()
        if call.replyWork?.isStopped == true { throw CancellationError() }
        if let stopped { throw stopped }
        return waiting != nil
    }

    private static func wait(_ pending: Pending, call: LLMCall) async -> Result<Void, Error> {
        do {
            try Task.checkCancellation()
            let label = call.admission.map { SwiftNativeProviderRouting.displayName(for: $0.provider) } ?? "Provider"
            let detail: String
            switch pending.reconnect {
            case .network: detail = "\(label) dropped the connection; reconnecting when this Mac's network is available"
            case .provider(let seconds?): detail = "\(label) refused the connection; reconnecting after its requested \(seconds) seconds"
            case .provider(nil): detail = "\(label) refused the connection; reconnecting"
            }
            await ProviderWire.status(kind: "provider.reconnecting", detail: detail,
                facts: ["cause": .string(ProviderFailure.diagnosticDescription(pending.cause)), "attempt": .int(2)], call: call)
            switch pending.reconnect {
            case .network:
                await ProviderWire.waiting(on: "network path", detail: detail, call: call)
                try await NetworkSense.returns()
            case .provider: break
            }
            if let seconds = pending.reconnect.retryAfter {
                await ProviderWire.waiting(on: "provider Retry-After",
                    detail: "\(label) requested \(seconds) seconds before reconnecting", call: call)
                try await Task.sleep(for: .seconds(max(0, seconds)))
            }
            try Task.checkCancellation()
            if call.replyWork?.isStopped == true { throw CancellationError() }
            return .success(())
        } catch { return .failure(error) }
    }
}

/// Failed requests and partial-output continuations pass through the same turn-owned reconnect gate.
public enum ProviderStreamGuard {
    public static func wrap(
        makeUpstream: @escaping @Sendable (LLMCall) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let provider = call.admission?.provider
            let recovery = call.turn?.providerRecovery.flatMap { $0.serves(provider) ? $0 : nil } ?? ProviderRecovery()
            let producer = Task {
                do {
                    while true {
                        let reconnecting = try await recovery.beforeRequest(call)
                        let admitted = Mutex(false)
                        let retryAfter = Mutex<Int?>(nil)
                        var wireCall = call
                        let upstreamAdmission = call.lifetime.admitted
                        wireCall.lifetime.admitted = {
                            admitted.withLock { $0 = true }
                            upstreamAdmission?()
                        }
                        let upstreamResponse = call.lifetime.response
                        wireCall.lifetime.response = { response in
                            retryAfter.withLock { $0 = parseRetryAfterSeconds(from: response) }
                            upstreamResponse?(response)
                        }
                        let held = wireCall
                        var producedOutput = false
                        do {
                            try Task.checkCancellation()
                            if held.replyWork?.isStopped == true { throw CancellationError() }
                            for try await event in makeUpstream(held) {
                                try Task.checkCancellation()
                                switch event {
                                case .textDelta(let text): if !text.isEmpty { producedOutput = true }
                                case .toolCall: producedOutput = true
                                case .keepAlive, .callInput, .toolBoundary, .replyTextSettled: break
                                }
                                continuation.yield(event)
                            }
                            try Task.checkCancellation()
                            if held.replyWork?.isStopped == true { throw CancellationError() }
                            recovery.completed(reconnecting: reconnecting)
                            continuation.finish()
                            return
                        } catch {
                            try Task.checkCancellation()
                            if held.replyWork?.isStopped == true { throw CancellationError() }
                            let failure = recovery.failed(error, admitted: admitted.withLock { $0 }, retryAfter: retryAfter.withLock { $0 })
                            if producedOutput || failure is ProviderRecovery.Stopped || failure is CancellationError
                                || ProviderRecoveryPolicy.reconnect(failure) == nil { throw failure }
                        }
                    }
                } catch { continuation.finish(throwing: error) }
            }
            call.replyWork?.own(producer, stop: {})
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
