import Foundation
import Testing
@testable import NativeAgentApp

struct OAuthContinuationGateTests {
    @Test func cancellationBeforeRegistrationIsRemembered() async {
        let gate = OAuthContinuationGate()
        gate.resume(throwing: CancellationError())
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                gate.resume(returning: URL(string: "nativeagent://oauth/late")!)
            }
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func callbackWinsBeforeConcurrentCancellation() async throws {
        let gate = OAuthContinuationGate()
        let callback = URL(string: "nativeagent://oauth/complete")!
        let result = try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            gate.resume(returning: callback)
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { gate.resume(throwing: CancellationError()) }
                group.addTask { gate.resume(returning: callback) }
            }
        }
        #expect(result == callback)
    }
}
