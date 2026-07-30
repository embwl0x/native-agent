import Foundation
import Testing
import NativeAgentCore
@testable import ProviderRouting

// Dedicated URLProtocol stub for the api-key vision body tests so they NEVER
// share global mutable state with StubURLProtocol (LLMClientRealTests) — that
// shared static responder races across parallel suites. This stub captures the
// request body via an instance-free static guarded by the .serialized suite.
final class VisionStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var responseBody: Data = Data()
    static func reset() { lastBody = nil; responseBody = Data() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(); let n = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let r = stream.read(buf, maxLength: n); if r <= 0 { break }
                data.append(buf, count: r)
            }
            stream.close()
            VisionStubURLProtocol.lastBody = data
        } else {
            VisionStubURLProtocol.lastBody = request.httpBody
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: VisionStubURLProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func visionStubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [VisionStubURLProtocol.self]
    return URLSession(configuration: cfg)
}

@Suite(.serialized) struct ApiKeyVisionBodyTests {
    private static let b64 = "QUJDRA=="
    private func image() -> LLMContentBlock {
        .image(mediaType: "image/png", base64: Self.b64, name: "x.png", byteSize: 4)
    }

    @Test func anthropicApiKey_imageAndText_nativeImageBlock() async throws {
        VisionStubURLProtocol.reset()
        VisionStubURLProtocol.responseBody = #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!
        let adapter = AnthropicAdapter(session: visionStubSession(), apiKeyOverride: "k")
        _ = try await LLMCallContext.$reasoningEffort.withValue("max") {
            try await adapter.completeMessages(
                messages: [.userWithImages("look", images: [image()])],
                system: "sys", model: "claude-opus-4-8", tools: nil
            )
        }
        let body = try #require(VisionStubURLProtocol.lastBody)
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect((obj["output_config"] as? [String: String])?["effort"] == "max")
        let content = (obj["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        #expect(content[0]["type"] as? String == "image")
        let source = content[0]["source"] as! [String: Any]
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == Self.b64)
        #expect(content[1]["type"] as? String == "text")
        #expect(content[1]["text"] as? String == "look")
    }

    @Test func anthropicApiKey_textOnly_plainStringContent() async throws {
        VisionStubURLProtocol.reset()
        VisionStubURLProtocol.responseBody = #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!
        let adapter = AnthropicAdapter(session: visionStubSession(), apiKeyOverride: "k")
        _ = try await adapter.completeMessages(
            messages: [.user("hi")], system: nil, model: "claude-opus-4-8", tools: nil
        )
        let body = try #require(VisionStubURLProtocol.lastBody)
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = obj["messages"] as! [[String: Any]]
        #expect(messages[0]["content"] as? String == "USER: hi")
    }

    @Test func openAIApiKey_imageAndText_imageUrlPart() async throws {
        VisionStubURLProtocol.reset()
        VisionStubURLProtocol.responseBody = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
        let adapter = OpenAIAdapter(session: visionStubSession(), apiKeyOverride: "k")
        _ = try await LLMCallContext.$reasoningEffort.withValue("none") {
            try await LLMCallContext.$serviceTier.withValue("priority") {
                try await adapter.completeMessages(
                    messages: [.userWithImages("look", images: [image()])],
                    system: "sys", model: "gpt-5.6-terra", tools: nil
                )
            }
        }
        let body = try #require(VisionStubURLProtocol.lastBody)
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(obj["reasoning_effort"] as? String == "none")
        #expect(obj["service_tier"] as? String == "priority")
        let messages = obj["messages"] as! [[String: Any]]
        let user = messages.first { ($0["role"] as? String) == "user" }!
        let content = user["content"] as! [[String: Any]]
        #expect(content[0]["type"] as? String == "image_url")
        #expect((content[0]["image_url"] as! [String: Any])["url"] as? String == "data:image/png;base64,\(Self.b64)")
        #expect(content[1]["type"] as? String == "text")
        #expect(content[1]["text"] as? String == "look")
    }

    @Test func openAIApiKey_textOnly_plainStringContent() async throws {
        VisionStubURLProtocol.reset()
        VisionStubURLProtocol.responseBody = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
        let adapter = OpenAIAdapter(session: visionStubSession(), apiKeyOverride: "k")
        _ = try await adapter.completeMessages(
            messages: [.user("hi")], system: nil, model: "gpt-5.5", tools: nil
        )
        let body = try #require(VisionStubURLProtocol.lastBody)
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = obj["messages"] as! [[String: Any]]
        #expect(messages[0]["content"] as? String == "USER: hi")
    }
}
