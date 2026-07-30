import Foundation

/// A configurable `URLProtocol` stub for tests that need to intercept
/// `URLSession` traffic and return canned responses.
///
/// Historically each test file hand-rolled its own near-identical `URLProtocol`
/// subclass (`MockURLProtocol` / `CmpMockURLProtocol` / `BackoffMockURLProtocol`
/// / `PhotoMockURLProtocol`, and ~14 more across the suite). They were kept as
/// SEPARATE classes on purpose: the handler lives in mutable `static` state, so
/// a shared class would clobber across concurrent/serialized suites. This base
/// preserves that isolation while removing the copy-paste — each concrete
/// SUBCLASS gets its OWN handler slot (keyed by the concrete metatype), so a
/// suite declares a one-line `final class FooStub: ConfigurableURLProtocolStub {}`
/// and calls `FooStub.makeSession { ... }` with no boilerplate.
open class ConfigurableURLProtocolStub: URLProtocol {
    public typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    // Per-concrete-class handler storage. `nonisolated(unsafe)` mirrors the
    // hand-rolled stubs' `nonisolated(unsafe) static var handler`; the NSLock
    // serializes the dictionary access the raw stubs never bothered to.
    nonisolated(unsafe) private static var handlers: [ObjectIdentifier: Handler] = [:]

    /// Install `handler` for THIS concrete stub class and return a `URLSession`
    /// wired to route through it. Call on the concrete subclass, e.g.
    /// `FooStub.makeSession { req in (response, data) }`.
    public static func makeSession(
        configuration: URLSessionConfiguration = .ephemeral,
        handler: @escaping Handler
    ) -> URLSession {
        setHandler(handler)
        let cfg = configuration
        cfg.protocolClasses = [self as AnyClass]
        return URLSession(configuration: cfg)
    }

    /// Install (or clear, with `nil`) the handler for this concrete stub class.
    public static func setHandler(_ handler: Handler?) {
        lock.lock(); defer { lock.unlock() }
        handlers[ObjectIdentifier(self)] = handler
    }

    private static func handler(for cls: AnyClass) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[ObjectIdentifier(cls)]
    }

    open override class func canInit(with request: URLRequest) -> Bool { true }

    open override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    open override func startLoading() {
        // `type(of: self)` is the dynamic (concrete) subclass, so each stub
        // reads back the handler its own suite installed.
        guard let handler = Self.handler(for: type(of: self)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    open override func stopLoading() {}
}

/// Drain a request body whether it arrived as `httpBody` or `httpBodyStream`.
/// `URLSession` moves bodies to a stream by the time a `URLProtocol` sees the
/// request, so `request.httpBody` is usually nil for POSTs — a test that wants
/// to assert on the sent payload must read the stream. Formerly copy-pasted as
/// `cmpRequestBody` in TelegramBotTests/CompletenessTests.
public func drainBodyStream(_ request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return Data()
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
        } else {
            break
        }
    }
    return data
}
