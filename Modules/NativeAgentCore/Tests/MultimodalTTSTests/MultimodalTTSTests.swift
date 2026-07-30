import Foundation
import Testing
@testable import MultimodalTTS
import PersistenceCore

// MARK: - Trust-policy fixture

/// Builds a temp dataRoot with `<root>/trust/policy.json` setting
/// multimodalPolicy.tts_openai to `allowed`, so the synthesizer's daemon-parity
/// trust gate can be exercised both ways.
private func makeDataRoot(ttsAllowed: Bool) async throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ttsroot-\(UUID().uuidString)", isDirectory: true)
    let policyPath = root
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json")
    let policy: JSONValue = .object([
        "multimodalPolicy": .object(["tts_openai": .bool(ttsAllowed)])
    ])
    try await SwiftNativePersistenceCore().writeJSON(policy, to: policyPath)
    return root
}

/// Writes `<root>/providers/openai.json` with the given `api_key`, mirroring the
/// daemon's `provider_config_dir = self.root / "providers"` layout
///. Used to prove the synthesizer resolves the OpenAI
/// key from the DATA ROOT (REPO_PATH parity), not the process CWD.
private func writeProviderKey(_ root: URL, apiKey: String) throws {
    let providersDir = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
    let json = "{\"api_key\":\"\(apiKey)\"}"
    try json.data(using: .utf8)!.write(to: providersDir.appendingPathComponent("openai.json"))
}

// MARK: - URLProtocol stub

/// Captures the outbound request and returns a canned response, so we can
/// assert byte-for-byte parity with the daemon's _VisionClient.tts request
/// without hitting the network.
final class TTSStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedURL: URL?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedHeaders: [String: String] = [:]
    nonisolated(unsafe) static var capturedBody: [String: Any] = [:]
    nonisolated(unsafe) static var responseStatus: Int = 200
    nonisolated(unsafe) static var responseData: Data = Data([0x01, 0x02, 0x03])

    static func reset() {
        capturedURL = nil
        capturedMethod = nil
        capturedHeaders = [:]
        capturedBody = [:]
        responseStatus = 200
        responseData = Data([0x01, 0x02, 0x03])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        Self.capturedMethod = request.httpMethod
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        // URLSession moves the body into httpBodyStream for custom protocols.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            stream.close()
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.capturedBody = obj
            }
        } else if let body = request.httpBody,
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            Self.capturedBody = obj
        }

        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg"]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TTSStubURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Suite

// SERIALIZED: every test shares the TTSStubURLProtocol static capture/response
// state. swift-testing runs tests in PARALLEL by default, which lets concurrent
// tests clobber each other's captured request + reset the canned status. The
// .serialized trait forces one-at-a-time execution so the shared stub is sound.
@Suite(.serialized)
struct MultimodalTTSSuite {

@Test
func tts_request_matches_daemon_shape() async throws {
    TTSStubURLProtocol.reset()
    let root = try await makeDataRoot(ttsAllowed: true)
    let client = SwiftOpenAITTSClient(session: stubbedSession(), apiKeyOverride: "sk-test-123", dataRoot: root)
    let audio = try await client.synthesize(text: "hello world", voice: "alloy", format: "mp3")

    #expect(audio == Data([0x01, 0x02, 0x03]))
    #expect(TTSStubURLProtocol.capturedURL?.absoluteString == "https://api.openai.com/v1/audio/speech")
    #expect(TTSStubURLProtocol.capturedMethod == "POST")
    // Headers mirror the retired daemon.
    #expect(TTSStubURLProtocol.capturedHeaders["Authorization"] == "Bearer sk-test-123")
    #expect(TTSStubURLProtocol.capturedHeaders["Content-Type"] == "application/json")
    #expect(TTSStubURLProtocol.capturedHeaders["User-Agent"] == "NativeAgent/0.2.0")
    // Body mirrors the retired daemon.
    #expect(TTSStubURLProtocol.capturedBody["model"] as? String == "tts-1")
    #expect(TTSStubURLProtocol.capturedBody["input"] as? String == "hello world")
    #expect(TTSStubURLProtocol.capturedBody["voice"] as? String == "alloy")
    #expect(TTSStubURLProtocol.capturedBody["response_format"] as? String == "mp3")
}

@Test
func tts_truncates_input_to_4096_chars() async throws {
    TTSStubURLProtocol.reset()
    let root = try await makeDataRoot(ttsAllowed: true)
    let client = SwiftOpenAITTSClient(session: stubbedSession(), apiKeyOverride: "sk-test-123", dataRoot: root)
    let long = String(repeating: "a", count: 5000)
    _ = try await client.synthesize(text: long, voice: "nova", format: "opus")
    // the retired daemon input=text[:4096]
    #expect((TTSStubURLProtocol.capturedBody["input"] as? String)?.count == 4096)
    #expect(TTSStubURLProtocol.capturedBody["voice"] as? String == "nova")
    #expect(TTSStubURLProtocol.capturedBody["response_format"] as? String == "opus")
}

// MARK: - Error mapping (vs daemon "[tts_*]" strings)

@Test
func tts_empty_text_throws_before_network() async throws {
    TTSStubURLProtocol.reset()
    let root = try await makeDataRoot(ttsAllowed: true)
    let client = SwiftOpenAITTSClient(session: stubbedSession(), apiKeyOverride: "sk-test-123", dataRoot: root)
    await #expect(throws: MultimodalTTSError.emptyText) {
        _ = try await client.synthesize(text: "", voice: "alloy", format: "mp3")
    }
    // Must not have hit the network.
    #expect(TTSStubURLProtocol.capturedURL == nil)
}

// MARK: - Trust gate (daemon _multimodal_policy_check parity)

@Test
func tts_trust_denied_when_policy_off() async throws {
    TTSStubURLProtocol.reset()
    // Policy explicitly OFF — must deny before any key/network work.
    let root = try await makeDataRoot(ttsAllowed: false)
    let client = SwiftOpenAITTSClient(session: stubbedSession(), apiKeyOverride: "sk-test-123", dataRoot: root)
    await #expect(throws: MultimodalTTSError.trustDenied) {
        _ = try await client.synthesize(text: "hi", voice: "alloy", format: "mp3")
    }
    #expect(TTSStubURLProtocol.capturedURL == nil)
}

@Test
func tts_trust_denied_when_policy_file_missing() async throws {
    TTSStubURLProtocol.reset()
    // No policy.json at all -> daemon default `tts_openai: False` -> deny.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ttsroot-missing-\(UUID().uuidString)", isDirectory: true)
    let client = SwiftOpenAITTSClient(session: stubbedSession(), apiKeyOverride: "sk-test-123", dataRoot: root)
    await #expect(throws: MultimodalTTSError.trustDenied) {
        _ = try await client.synthesize(text: "hi", voice: "alloy", format: "mp3")
    }
    #expect(TTSStubURLProtocol.capturedURL == nil)
}

// MARK: - Unicode truncation parity (Python str[:4096] is by code point)

@Test
func tts_truncation_is_by_unicode_scalar() async throws {
    TTSStubURLProtocol.reset()
    let root = try await makeDataRoot(ttsAllowed: true)
    let client = SwiftOpenAITTSClient(session: stubbedSession(), apiKeyOverride: "sk-test-123", dataRoot: root)
    // 5000 code points, each a 1-scalar char beyond the BMP would still be ONE
    // scalar; use a combining sequence to prove we count scalars not graphemes.
    // "e" + U+0301 (combining acute) = 1 grapheme but 2 scalars. 3000 of them =
    // 6000 scalars -> truncated to 4096 scalars (Python text[:4096] semantics).
    let combining = String(repeating: "e\u{0301}", count: 3000) // 6000 scalars
    _ = try await client.synthesize(text: combining, voice: "alloy", format: "mp3")
    let sent = TTSStubURLProtocol.capturedBody["input"] as? String ?? ""
    #expect(sent.unicodeScalars.count == 4096)
    // A grapheme-based prefix(4096) would have sent 4096 graphemes = 8192
    // scalars, so this asserting 4096 scalars proves the scalar-view fix.
}

// MARK: - LocalizedError parity (daemon error strings)

@Test
func tts_errors_carry_daemon_equivalent_descriptions() {
    #expect(MultimodalTTSError.trustDenied.errorDescription?.hasPrefix("[trust_denied]") == true)
    #expect(MultimodalTTSError.notConfigured.errorDescription?.hasPrefix("[tts_unavailable]") == true)
    #expect(MultimodalTTSError.authRejected.errorDescription?.hasPrefix("[tts_auth_error]") == true)
    #expect(MultimodalTTSError.apiError(status: 503).errorDescription == "[tts_api_error] HTTP 503")
    #expect(MultimodalTTSError.transport(message: "boom").errorDescription == "[tts_error] boom")
    #expect(MultimodalTTSError.emptyText.errorDescription == "text is required")
}

@Test
func tts_no_key_throws_notConfigured() async throws {
    TTSStubURLProtocol.reset()
    // Guard: only run the assertion if the ambient env has no OPENAI_API_KEY
    // (CI / the user's shell may export one). When set, the resolver legitimately
    // finds it and notConfigured would not be thrown — skip rather than flake.
    if (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty ?? true) {
        // Trust gate must be PERMISSIVE here so we reach the key check (the gate
        // runs first); the data root has no providers/openai.json so the
        // resolver returns nil -> notConfigured.
        let root = try await makeDataRoot(ttsAllowed: true)
        let client = SwiftOpenAITTSClient(session: stubbedSession(), dataRoot: root)
        await #expect(throws: MultimodalTTSError.notConfigured) {
            _ = try await client.synthesize(text: "hi", voice: "alloy", format: "mp3")
        }
        #expect(TTSStubURLProtocol.capturedURL == nil)
    }
}

// REPO_PATH PARITY (wave 36 W08 / §6.138): the synthesizer must resolve the
// OpenAI platform key from `<dataRoot>/providers/openai.json` — the SAME
// directory the daemon's _VisionClient reads (self.root / "providers") — and
// not from a CWD-relative `data/providers/openai.json`. An installed .app bundle
// runs with CWD `/`, so a CWD-relative resolve would miss the key entirely. Env
// guard mirrors the no-key test:
// a real ambient OPENAI_API_KEY would short-circuit precedence and mask the file
// path, so skip the assertion when one is present.
@Test
func tts_key_resolved_from_dataRoot_not_cwd() async throws {
    TTSStubURLProtocol.reset()
    if (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty ?? true) {
        // Key lives ONLY in the data root, not under the process CWD.
        let root = try await makeDataRoot(ttsAllowed: true)
        try writeProviderKey(root, apiKey: "sk-from-dataroot")

        // No apiKeyOverride: forces real LLMCredentialResolver(dataRoot:) path.
        let client = SwiftOpenAITTSClient(session: stubbedSession(), dataRoot: root)
        let audio = try await client.synthesize(text: "hi", voice: "alloy", format: "mp3")
        #expect(audio == Data([0x01, 0x02, 0x03]))
        // The Authorization header proves WHICH key was resolved.
        #expect(TTSStubURLProtocol.capturedHeaders["Authorization"] == "Bearer sk-from-dataroot")
    }
}

// Negative companion: when the dataRoot has no key, TTS must report
// notConfigured. The resolver's own tests pin the old CWD trap without mutating
// process CWD during the package-wide parallel run.
@Test
func tts_missing_dataRoot_key_throws_notConfigured() async throws {
    TTSStubURLProtocol.reset()
    if (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty ?? true) {
        // dataRoot has NO providers/openai.json -> resolver must return nil
        // -> notConfigured.
        let root = try await makeDataRoot(ttsAllowed: true)
        let client = SwiftOpenAITTSClient(session: stubbedSession(), dataRoot: root)
        await #expect(throws: MultimodalTTSError.notConfigured) {
            _ = try await client.synthesize(text: "hi", voice: "alloy", format: "mp3")
        }
        #expect(TTSStubURLProtocol.capturedURL == nil)
    }
}

@Test
func tts_401_maps_to_authRejected() async throws {
    TTSStubURLProtocol.reset()
    TTSStubURLProtocol.responseStatus = 401
    let root = try await makeDataRoot(ttsAllowed: true)
    let client = SwiftOpenAITTSClient(session: stubbedSession(), apiKeyOverride: "sk-bad", dataRoot: root)
    await #expect(throws: MultimodalTTSError.authRejected) {
        _ = try await client.synthesize(text: "hi", voice: "alloy", format: "mp3")
    }
}

@Test
func tts_500_maps_to_apiError() async throws {
    TTSStubURLProtocol.reset()
    TTSStubURLProtocol.responseStatus = 500
    let root = try await makeDataRoot(ttsAllowed: true)
    let client = SwiftOpenAITTSClient(session: stubbedSession(), apiKeyOverride: "sk-x", dataRoot: root)
    await #expect(throws: MultimodalTTSError.apiError(status: 500)) {
        _ = try await client.synthesize(text: "hi", voice: "alloy", format: "mp3")
    }
}

}
