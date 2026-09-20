import Foundation
import Testing
@testable import ProviderRouting

@Suite struct ProviderFailureTests {
    @Test func routingFailuresAreNotWireFailures() {
        for error in [ProviderRoutingError.unavailable, .underlying("saved routing is malformed"), .configurationFailed("private")] {
            let normalized = ProviderFailure.normalize(error)
            #expect(ProviderFailure.classify(normalized) == .routingUnavailable)
            #expect(!ProviderRecoveryPolicy.isRecoverable(normalized))
            #expect(ProviderRecoveryPolicy.personMessage(normalized) == "Your model settings could not be loaded; check your model connection in Settings.")
        }
        #expect(ProviderFailure.classify(LLMError.notConfigured(provider: "private")) == .routingUnavailable)
    }

    @Test func overloadExhaustionCannotRestartOuterLadder() async {
        var calls = 0
        do {
            let _: String = try await ProviderRecoveryPolicy.retryOverload {
                calls += 1
                throw ProviderFailure.overloaded
            }
            Issue.record("Expected overload")
        } catch {
            #expect(calls == 10)
            #expect(ProviderFailure.classify(error) == .overloaded)
            #expect(!ProviderRecoveryPolicy.isRecoverable(ProviderFailure.normalize(error)))
            #expect(!ProviderRecoveryPolicy.permitsWholeTurnRetry(error))
        }
    }

    @Test func overloadBackoffPreservesExistingLadder() {
        #expect(ProviderRecoveryPolicy.maxAttemptsPerCall == 10)
        #expect((1...9).map { ProviderRecoveryPolicy.backoffSeconds(forRetry: $0) }
            == [1, 2, 4, 8, 15, 30, 30, 30, 30])
    }

    @Test func overloadAfterOutputDoesNotReplay() async {
        final class Count: @unchecked Sendable { var calls = 0 }
        let count = Count()
        var output = ""
        let stream = ProviderRecoveryPolicy.retryOverloadStream(hasOutput: { !$0.isEmpty }) {
            count.calls += 1
            return AsyncThrowingStream<String, Error> {
                $0.yield("partial")
                $0.finish(throwing: ProviderFailure.overloaded)
            }
        }
        do {
            for try await text in stream { output += text }
            Issue.record("Expected overload")
        } catch {
            #expect(count.calls == 1)
            #expect(output == "partial")
            #expect(!ProviderRecoveryPolicy.isRecoverable(error))
            #expect(!ProviderRecoveryPolicy.permitsWholeTurnRetry(error))
        }
    }

    @Test func statusSurvivesEmptyOrMisleadingBodies() throws {
        for (status, expected) in [(401, ProviderFailure.authExpired), (403, .authExpired),
                                   (413, .contextTooLong), (429, .rateLimited(retryAfter: 37)),
                                   (503, .overloaded), (408, .network)] {
            let response = try #require(HTTPURLResponse(url: URL(string: "https://fixture.invalid")!,
                statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "37"]))
            for body in ["", #"{"error":{"message":"records include status 500"}}"#] {
                do {
                    try throwIfChatCompletionsError(status: status, data: Data(body.utf8), response: response)
                    Issue.record("Expected HTTP failure")
                } catch {
                    #expect(ProviderFailure.classify(error) == expected)
                }
            }
        }
    }

    @Test func nonstandardQuotaResponseKeepsRecoveryAndRetryAfter() throws {
        let body = Data(#"{"error":{"message":"Usage limit for this billing cycle"}}"#.utf8)
        for status in [400, 403] {
            let response = try #require(HTTPURLResponse(url: URL(string: "https://fixture.invalid")!,
                statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "37"]))
            do {
                try throwIfChatCompletionsError(status: status, data: body, response: response)
                Issue.record("Expected quota failure")
            } catch {
                #expect(ProviderFailure.classify(error) == .rateLimited(retryAfter: 37))
                #expect(ProviderRecoveryPolicy.isRecoverable(error))
                #expect(ProviderRecoveryPolicy.retryDelaySeconds(forRetry: 1, error: error) == 37)
                #expect(ProviderRecoveryPolicy.personMessage(error) == ProviderFailure.rateLimited(retryAfter: 37).errorDescription)
            }
        }
        #expect(ProviderFailure.wire("HTTP 403: usage limit for this billing cycle") == .rateLimited(retryAfter: nil))
        #expect(ProviderFailure.http(status: 401, detail: "usage limit") == .authExpired)
        #expect(ProviderFailure.http(status: 503, detail: "usage limit") == .overloaded)
    }

    @Test func structuredCodeSurvivesVagueMessage() {
        let body = Data(#"{"error":{"code":"context_length_exceeded","message":"Request rejected"}}"#.utf8)
        #expect(ProviderFailure.http(status: 400, detail: ProviderFailure.wireDetail(body)) == .contextTooLong)
        #expect(ProviderFailure.wire(ProviderFailure.wireDetail([
            "type": "authentication_error", "message": "Request rejected"
        ])) == .authExpired)
        #expect(ProviderFailure.wire(ProviderFailure.wireDetail([
            "type": "overloaded_error", "message": "Request rejected"
        ])) == .overloaded)
    }

    @Test func stringErrorFieldsPreserveContextAndQuotaClassification() {
        for (body, expected) in [
            (#"{"error":"context_length_exceeded"}"#, ProviderFailure.contextTooLong),
            (#"{"error":"insufficient_quota"}"#, .rateLimited(retryAfter: nil)),
            (#"{"error":"invalid request"}"#, .refused),
        ] {
            do {
                try throwIfChatCompletionsError(status: 400, data: Data(body.utf8))
                Issue.record("Expected HTTP failure")
            } catch {
                #expect(ProviderFailure.classify(error) == expected)
            }
        }
    }

    @Test func contextAndRefusalDoNotEnterReconnectLadder() {
        struct UnrelatedError: LocalizedError {
            var errorDescription: String? { "unavailable records include HTTP 503" }
        }
        #expect(!ProviderRecoveryPolicy.isRecoverable(UnrelatedError()))
        #expect(ProviderFailure.http(status: 400, detail: "context_length_exceeded") == .contextTooLong)
        #expect(!ProviderRecoveryPolicy.isRecoverable(ProviderFailure.contextTooLong))
        #expect(!ProviderRecoveryPolicy.isRecoverable(ProviderFailure.refused))
        #expect(!ProviderRecoveryPolicy.isRecoverable(ProviderFailure.malformedResponse))
        #expect(!ProviderRecoveryPolicy.isRecoverable(CancellationError()))
        #expect(ProviderRecoveryPolicy.isRecoverable(URLError(.networkConnectionLost)))
    }

    @Test func retryAfterAndReplayVetoSurviveWrappers() {
        struct AfterEffects: ProviderFailureWrapping {
            let providerFailureCause: Error = LLMError.rateLimited(message: "private", retryAfterSeconds: 42)
            let permitsWholeTurnRetry = false
        }
        let error = AfterEffects()
        #expect(ProviderRecoveryPolicy.retryDelaySeconds(forRetry: 1, error: error) == 42)
        #expect(ProviderRecoveryPolicy.isRecoverable(error))
        #expect(!ProviderRecoveryPolicy.permitsWholeTurnRetry(error))
        #expect(ProviderRecoveryPolicy.personMessage(error) == ProviderFailure.rateLimited(retryAfter: 42).errorDescription)
    }

    @Test func terminalMessagesNeverExposeAdaptersOrWireDetails() {
        for error in [LLMError.authRejected(provider: "anthropic_oauth_direct", detail: "secret"),
                      .providerError(message: "OpenAI overloaded_error"),
                      .underlying(message: "xAI unreadable JSON"),
                      .modelUnavailable(provider: "openrouter", model: "secret"),
                      .notConfigured(provider: "codex")] {
            let message = ProviderRecoveryPolicy.personMessage(error) ?? ""
            #expect(!message.isEmpty)
            for token in ["anthropic", "openai", "xai", "openrouter", "codex", "secret", "oauth"] {
                #expect(!message.lowercased().contains(token))
            }
        }
    }

    @Test func backendCapacityFailureLeavesRetryToCaller() {
        #expect(ProviderFailure.classify(OpenAIOAuthDirectAdapter.classifiedBackendError("server_error")) == .overloaded)
        #expect(ProviderFailure.classify(OpenAIOAuthDirectAdapter.classifiedBackendError("rate_limit_exceeded")) == .rateLimited(retryAfter: nil))
    }
}
