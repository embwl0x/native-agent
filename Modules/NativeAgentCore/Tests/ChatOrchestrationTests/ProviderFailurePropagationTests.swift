import Foundation
import Testing
@testable import ChatOrchestration
import ProviderRouting
import PersistenceCore

@Suite struct ProviderFailurePropagationTests {
    @Test func causeAndWorkSurviveWrappersAndWireEncoding() throws {
        let cases: [(Error, ProviderFailure)] = [
            (LLMError.authRejected(provider: "fixture", detail: "insufficient_quota"), .rateLimited(retryAfter: 3600)),
            (ProviderFailure.http(status: 403, detail: "quota exceeded"), .rateLimited(retryAfter: 3600)),
            (ProviderFailure.http(status: 429), .rateLimited(retryAfter: nil)),
            (ProviderFailure.http(status: 401), .authExpired),
            (ProviderFailure.http(status: 404, detail: "model_not_found"), .modelUnavailable),
            (LLMError.modelUnavailable(provider: "fixture", model: "missing"), .modelUnavailable)
        ]
        for (error, cause) in cases {
            let before = try #require(ProviderFailure.report(error))
            #expect(before.cause == cause)
            #expect(before.work == .nothingRan)
            let partial = TurnEngineError.streamInterrupted(partial: "Started", underlying:
                ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: 1))
            let after = try #require(ProviderFailure.report(partial))
            #expect(after.cause == cause)
            #expect(after.work == .ranPartly)
            #expect(!ProviderRecoveryPolicy.permitsWholeTurnRetry(after))
            #expect(try JSONDecoder().decode(ProviderFailure.Report.self, from: JSONEncoder().encode(after)) == after)
            var tool: [String: JSONValue] = [:]
            SwiftToolDispatcher.peerFailure(after, into: &tool)
            #expect(tool["work"] == .string("ran partly"))
            #expect(tool["detail"] == .string(after.errorDescription!))
        }
        #expect(ProviderFailure.report(URLError(.timedOut))?.work == .outcomeUnknown)
        #expect(ProviderFailure.report(CancellationError()) == nil)
    }
}
