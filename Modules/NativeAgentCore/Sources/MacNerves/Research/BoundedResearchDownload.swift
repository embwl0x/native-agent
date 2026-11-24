import Foundation
import Synchronization
import Darwin
import NativeAgentCore
import NativeAgentShared

// Blueprint: | `BoundedResearchDownload.swift` | `BoundedResearchDownload`: bound bytes before appending |

/// A data-task delegate bounds retained bytes before appending. This avoids URLSession.data buffering the entire remote response before a later clip.
final class BoundedResearchDownload: NSObject, URLSessionDataDelegate {
    private struct State {
        var limit: Int
        var continuation: CheckedContinuation<ResearchHTTPResponse, Error>?
        var session: URLSession?
        var task: URLSessionDataTask?
        var cancelled = false
        var finished = false
        var response: HTTPURLResponse?
        var body = Data()
        var observedBytes = 0

        func snapshot(truncated: Bool) -> ResearchHTTPResponse? {
            guard let response else { return nil }
            return ResearchHTTPResponse(status: response.statusCode, body: body,
                contentType: response.value(forHTTPHeaderField: "Content-Type"), finalURL: response.url,
                observedBytes: observedBytes, truncated: truncated)
        }
    }
    private let state: Mutex<State>
    private let pdfLimit: Int?
    private let publicOrigin: Bool

    init(limit: Int, pdfLimit: Int?, publicOrigin: Bool) {
        state = Mutex(State(limit: limit))
        self.pdfLimit = pdfLimit
        self.publicOrigin = publicOrigin
    }

    /// Stop releases the caller without awaiting synchronous DNS; its late result cannot replace cancellation.
    static func resolving<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let result = ContinuationOnce<Result<T, Error>>()
        let lookup = Task.detached {
            result.resume(Result {
                try Task.checkCancellation()
                let value = try work()
                try Task.checkCancellation()
                return value
            })
        }
        return try await withTaskCancellationHandler {
            let value = try await result.wait().get()
            try Task.checkCancellation()
            return value
        } onCancel: {
            result.resume(.failure(CancellationError())) { lookup.cancel() }
        }
    }

    static func publicAddress(_ url: URL) throws -> Bool {
        guard let host = url.host, !host.isEmpty else { throw ResearchClientError.transport("Missing host: \(url)") }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        let resolved = unsafe getaddrinfo(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), nil, &hints, &first)
        guard resolved == 0 else {
            let cause = "getaddrinfo EAI \(resolved): \(unsafe String(cString: gai_strerror(resolved)))"
            if resolved == EAI_NONAME { throw ResearchClientError.noSuchHost(host, resolverFailure: cause) }
            throw ResearchClientError.transport("DNS for \(host) failed: \(cause)")
        }
        guard let start = unsafe first else { throw ResearchClientError.transport("DNS for \(host) returned no addresses.") }
        defer { unsafe freeaddrinfo(start) }
        var cursor: UnsafeMutablePointer<addrinfo>? = unsafe start
        while let at = unsafe cursor {
            var bytes = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let named = unsafe getnameinfo(at.pointee.ai_addr, at.pointee.ai_addrlen, &bytes, socklen_t(bytes.count),
                                    nil, 0, NI_NUMERICHOST)
            guard named == 0 else {
                throw ResearchClientError.transport("Could not read resolved address for \(host): getnameinfo EAI \(named): \(unsafe String(cString: gai_strerror(named)))")
            }
            let numeric = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let address = String(numeric.prefix { $0 != "%" })
            if NetworkAddress.loopback(address) || NetworkAddress.privateNetwork(address) { return false }
            cursor = unsafe at.pointee.ai_next
        }
        return true
    }

    static func checkRedirect(_ url: URL, publicOrigin: Bool) throws {
        guard publicOrigin else { return }
        do {
            guard try publicAddress(url) else { throw ResearchClientError.transport("A public fetch cannot enter a local or private network.") }
        } catch { throw ResearchClientError.transport("Refused redirect to \(url): \(error.localizedDescription) Use a public URL.") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        do {
            guard let url = request.url else { throw ResearchClientError.transport("Redirect has no URL") }
            try Self.checkRedirect(url, publicOrigin: publicOrigin)
            completionHandler(request)
        } catch {
            finish(.failure(error))
            completionHandler(nil)
        }
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<ResearchHTTPResponse, Error>) {
        let task = state.withLock { state -> URLSessionDataTask? in
            guard !state.cancelled else { return nil }
            state.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            state.session = session
            state.task = task
            return task
        }
        if let task { task.resume() }
        else { continuation.resume(throwing: CancellationError()) }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<ResearchHTTPResponse, Error>) {
        let live = state.withLock { state -> (CheckedContinuation<ResearchHTTPResponse, Error>, URLSession?, URLSessionDataTask?)? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            state.finished = true
            state.continuation = nil
            return (continuation, state.session.take(), state.task.take())
        }
        guard let (continuation, session, task) = live else { return }
        task?.cancel()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(ResearchClientError.transport("non-HTTP response")))
            return
        }
        let stopped = state.withLock { state in
            state.response = http
            if let pdfLimit, http.mimeType?.lowercased() == "application/pdf" { state.limit = pdfLimit }
            return state.finished || state.cancelled
        }
        completionHandler(stopped ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let result = state.withLock { state -> ResearchHTTPResponse? in
            guard !state.finished else { return nil }
            state.observedBytes += data.count
            if let pdfLimit, state.body.count < 5 {
                var signature = state.body
                signature.append(contentsOf: data.prefix(5 - signature.count))
                if signature == Data("%PDF-".utf8) { state.limit = pdfLimit }
            }
            let remaining = max(0, state.limit - state.body.count)
            state.body.append(contentsOf: data.prefix(remaining))
            return data.count > remaining ? state.snapshot(truncated: true) : nil
        }
        if let result { finish(.success(result)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (result, wasCancelled) = state.withLock { ($0.snapshot(truncated: false), $0.cancelled) }
        if wasCancelled { finish(.failure(CancellationError())) }
        else if let error { finish(.failure(error)) }
        else if let result { finish(.success(result)) }
        else { finish(.failure(ResearchClientError.transport("missing HTTP response"))) }
    }
}
