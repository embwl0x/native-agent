import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore

// Wave-1 fence-A "provider honesty" fixes (A3.1–A3.6). These pin the new
// error-shape contracts a stranger's keys depend on: a rejected key reads as
// rejected (not "unconfigured"), a 429 carries the honored Retry-After, an
// empty turn is not a silent success, the codex CLI classifies its failures,
// and a single-provider fresh install adapts its seeds.

@Suite struct ProviderHonestyA3Tests {

    // MARK: A3.1 — authRejected rendering carries provider detail + actionable text

    @Test func authRejected_errorDescription_is_actionable_and_carries_detail() {
        let err = LLMError.authRejected(provider: "openai", detail: "Incorrect API key provided")
        let msg = try! #require(err.errorDescription)
        #expect(msg.contains("rejected the key/token"))
        #expect(msg.contains("reconnect or check billing"))
        #expect(msg.contains("Incorrect API key provided"))
        // It must NOT read like the misleading "not configured" message.
        #expect(!msg.contains("not configured"))
    }

    @Test func authRejected_without_detail_still_actionable() {
        let err = LLMError.authRejected(provider: "anthropic_oauth_direct", detail: nil)
        let msg = try! #require(err.errorDescription)
        #expect(msg.contains("anthropic_oauth_direct"))
        #expect(msg.contains("reconnect or check billing"))
    }

    @Test func providerErrorDetail_extracts_nested_openai_shape() {
        let data = Data(#"{"error":{"message":"Incorrect API key","type":"invalid_request_error"}}"#.utf8)
        #expect(providerErrorDetail(data) == "Incorrect API key")
    }

    @Test func providerErrorDetail_extracts_flat_and_falls_back_to_raw() {
        #expect(providerErrorDetail(Data(#"{"message":"nope"}"#.utf8)) == "nope")
        #expect(providerErrorDetail(Data(#"{"error":"bad key"}"#.utf8)) == "bad key")
        // Unparseable → bounded raw slice (not nil, not dropped).
        #expect(providerErrorDetail(Data("plain text boom".utf8)) == "plain text boom")
        #expect(providerErrorDetail(Data()) == nil)
    }

    // MARK: A3.4 — Retry-After: header parse, sentinel round-trip, ladder extraction

    @Test func parseRetryAfter_deltaSeconds() {
        let resp = HTTPURLResponse(
            url: URL(string: "https://x")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "45"])!
        #expect(parseRetryAfterSeconds(from: resp) == 45)
    }

    @Test func parseRetryAfter_httpDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = now.addingTimeInterval(90)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let resp = HTTPURLResponse(
            url: URL(string: "https://x")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": fmt.string(from: future)])!
        let secs = try! #require(parseRetryAfterSeconds(from: resp, now: now))
        #expect(secs >= 88 && secs <= 90)
    }

    @Test func parseRetryAfter_absent_or_clamped() {
        let none = HTTPURLResponse(
            url: URL(string: "https://x")!, statusCode: 429,
            httpVersion: nil, headerFields: [:])!
        #expect(parseRetryAfterSeconds(from: none) == nil)
        let huge = HTTPURLResponse(
            url: URL(string: "https://x")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "999999"])!
        #expect(parseRetryAfterSeconds(from: huge) == LLMError.retryAfterMaxSeconds)
    }

    @Test func rateLimited_embeds_sentinel_and_roundtrips() {
        let err = LLMError.rateLimited(message: "slow down", retryAfterSeconds: 30)
        let desc = try! #require(err.errorDescription)
        #expect(desc.contains("slow down"))
        #expect(desc.contains("[retry-after=30s]"))
        #expect(err.retryAfterSeconds == 30)
        // Still a .transient so every existing pattern-match keeps working.
        guard case .transient = err else {
            Issue.record("rateLimited must remain a .transient")
            return
        }
    }

    @Test func rateLimited_nil_or_zero_is_plain_transient() {
        let a = LLMError.rateLimited(message: "x", retryAfterSeconds: nil)
        let b = LLMError.rateLimited(message: "x", retryAfterSeconds: 0)
        #expect(a == .transient(message: "x"))
        #expect(b == .transient(message: "x"))
        #expect(a.retryAfterSeconds == nil)
    }

    @Test func retryAfterSeconds_fromDescription_extracts_from_wrapped_text() {
        // The surface ladders read the joined error TEXT, not the enum.
        let text = "llm: transient: slow down [retry-after=42s]"
        #expect(LLMError.retryAfterSeconds(fromDescription: text) == 42)
        #expect(LLMError.retryAfterSeconds(fromDescription: "no sentinel here") == nil)
    }

    // MARK: A3.2 — codex CLI failure classification

    @Test func codex_auth_failure_classifies_authRejected() {
        let err = CodexAdapter.classifyCodexFailure(
            exitCode: 1, stdout: "",
            stderr: "Error: Not logged in. Please run codex login to authenticate.")
        guard case .authRejected(let provider, let detail) = err else {
            Issue.record("expected .authRejected, got \(err)")
            return
        }
        #expect(provider == "codex")
        #expect(detail?.contains("logged in") == true)
    }

    @Test func codex_rate_limit_classifies_transient() {
        let err = CodexAdapter.classifyCodexFailure(
            exitCode: 1, stdout: "",
            stderr: "429 Too Many Requests: rate limit exceeded, try again later")
        guard case .transient(let msg) = err else {
            Issue.record("expected .transient, got \(err)")
            return
        }
        #expect(msg.contains("rate limit") || msg.contains("429"))
    }

    @Test func codex_unknown_failure_stays_underlying_with_bounded_tail() {
        let noisy = String(repeating: "x", count: 5000) + " FATAL boom at the end"
        let err = CodexAdapter.classifyCodexFailure(exitCode: 2, stdout: "", stderr: noisy)
        guard case .underlying(let msg) = err else {
            Issue.record("expected .underlying, got \(err)")
            return
        }
        #expect(msg.count <= 640, "stderr tail must be bounded")
        #expect(msg.contains("FATAL boom at the end"), "actionable tail preserved")
    }

    @Test func codex_complete_empty_output_throws_streamTruncated() async throws {
        let runner: CodexProcessRunner = { _ in
            CodexProcessResult(exitCode: 0, stdout: "   \n  ", stderr: "")
        }
        let adapter = CodexAdapter(runner: runner)
        do {
            _ = try await adapter.complete(prompt: "hi", system: nil, model: "codex-x")
            Issue.record("expected streamTruncated on empty exit-0 output")
        } catch let err as LLMError {
            guard case .streamTruncated = err else {
                Issue.record("expected .streamTruncated, got \(err)")
                return
            }
        }
    }

    @Test func codex_complete_nonempty_output_returns_it() async throws {
        let runner: CodexProcessRunner = { _ in
            CodexProcessResult(exitCode: 0, stdout: "real reply", stderr: "")
        }
        let adapter = CodexAdapter(runner: runner)
        let out = try await adapter.complete(prompt: "hi", system: nil, model: "codex-x")
        #expect(out == "real reply")
    }

    // MARK: A3.6 — fresh-install single-provider seed adaptation

    /// Build a router whose data root has ONLY the given api-key providers
    /// connected (empty surfaces / active), so `soleConnectedProviderFamily`
    /// resolves to exactly that family.
    private func routerConnecting(_ providerFiles: [String: String]) throws -> SwiftNativeProviderRouting {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a36-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let surfaces = providers.appendingPathComponent("surfaces.json")
        let active = providers.appendingPathComponent("active.json")
        try Data("{}".utf8).write(to: surfaces)
        try Data("{}".utf8).write(to: active)
        for (file, key) in providerFiles {
            let body = try JSONSerialization.data(withJSONObject: ["api_key": key])
            try body.write(to: providers.appendingPathComponent(file))
        }
        return SwiftNativeProviderRouting(
            dataRoot: root,
            surfacesPathOverride: surfaces,
            activeProviderPathOverride: active
        )
    }

    @Test func anthropicOnlyInstall_adapts_chat_seed_away_from_default_gpt() async throws {
        // PRIMARY_MODEL is a GPT id; an Anthropic-only stranger must NOT get a
        // chat surface pointed at OpenAI (the "not configured: openai" trap).
        #expect(PRIMARY_MODEL.hasPrefix("gpt"), "precondition: default seed is a GPT id")
        let router = try routerConnecting(["anthropic.json": "sk-ant-xxx"])
        let prefs = try await router.computeModelPreferences()
        let chat = try #require(prefs["chat"]?.model)
        #expect(chat.lowercased().contains("claude"),
                "chat seed should adapt to the sole connected (Anthropic) provider, got \(chat)")
        // Background surfaces (dream/rem/training) also adapt off their GPT seeds.
        #expect(prefs["dream"]?.model.lowercased().contains("claude") == true)
    }

    @Test func multipleProviders_leave_seeds_unadapted() async throws {
        // With two families connected we can't infer intent — the GPT default
        // seed stays (existing behavior; the picker/active hint disambiguates).
        let router = try routerConnecting([
            "anthropic.json": "sk-ant-xxx",
            "openai.json": "sk-oai-xxx",
        ])
        let prefs = try await router.computeModelPreferences()
        #expect(prefs["chat"]?.model == PRIMARY_MODEL)
    }

    @Test func soleConnectedProviderFamily_reflects_credentials() async throws {
        let anthropicOnly = try routerConnecting(["anthropic.json": "k"])
        #expect(await anthropicOnly.soleConnectedProviderFamily() == "anthropic")
        let openaiOnly = try routerConnecting(["openai.json": "k"])
        #expect(await openaiOnly.soleConnectedProviderFamily() == "openai")
        let none = try routerConnecting([:])
        #expect(await none.soleConnectedProviderFamily() == nil)
    }

    @Test func codex_stream_empty_content_throws_streamTruncated() async throws {
        // Streaming runner that finishes clean (exit 0) yielding only blanks.
        let streamingRunner: CodexStreamingProcessRunner = { _ in
            AsyncThrowingStream { cont in
                cont.yield("  ")
                cont.finish()
            }
        }
        let adapter = CodexAdapter(streamingRunner: streamingRunner)
        var thrown: Error?
        do {
            for try await _ in adapter.stream(prompt: "hi", system: nil, model: "codex-x") {}
        } catch { thrown = error }
        let err = try #require(thrown as? LLMError)
        guard case .streamTruncated = err else {
            Issue.record("expected .streamTruncated, got \(err)")
            return
        }
    }
}
