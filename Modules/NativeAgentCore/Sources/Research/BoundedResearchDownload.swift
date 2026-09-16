import Foundation

/// A data-task delegate bounds retained bytes before appending. This avoids
/// URLSession.data buffering the entire remote response before a later clip.
final class BoundedResearchDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var continuation: CheckedContinuation<ResearchHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var finished = false
    private var response: HTTPURLResponse?
    private var body = Data()
    private var observedBytes = 0

    init(limit: Int) { self.limit = limit }

    func start(request: URLRequest, configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<ResearchHTTPResponse, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<ResearchHTTPResponse, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let session = self.session
        let task = self.task
        self.session = nil
        self.task = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    private func snapshot(truncated: Bool) -> ResearchHTTPResponse? {
        guard let response else { return nil }
        return ResearchHTTPResponse(status: response.statusCode, body: body,
            contentType: response.value(forHTTPHeaderField: "Content-Type"), finalURL: response.url,
            observedBytes: observedBytes, truncated: truncated)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(ResearchClientError.transport("non-HTTP response")))
            return
        }
        lock.lock()
        self.response = http
        let stopped = finished || cancelled
        lock.unlock()
        completionHandler(stopped ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        observedBytes += data.count
        let remaining = max(0, limit - body.count)
        body.append(contentsOf: data.prefix(remaining))
        let truncated = data.count > remaining
        let result = truncated ? snapshot(truncated: true) : nil
        lock.unlock()
        if let result { finish(.success(result)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result = snapshot(truncated: false)
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { finish(.failure(CancellationError())) }
        else if let error { finish(.failure(error)) }
        else if let result { finish(.success(result)) }
        else { finish(.failure(ResearchClientError.transport("missing HTTP response"))) }
    }
}
