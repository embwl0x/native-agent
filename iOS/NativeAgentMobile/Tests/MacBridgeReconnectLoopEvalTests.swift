import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.macBridgeClient.reconnectLoop`.
///
/// A new connection attempt supersedes every earlier retry task. A stale task
/// must neither keep retrying nor clear the newer task's ownership.
@MainActor
final class MacBridgeReconnectLoopEvalTests: XCTestCase {
    func test_retryPolicyIsRapidBeforeItsBoundedBackoffThenSlower() {
        XCTAssertEqual(MacBridgeReconnectPolicy.delayNanoseconds(afterAttempt: 1), 500_000_000)
        XCTAssertEqual(MacBridgeReconnectPolicy.delayNanoseconds(afterAttempt: 59), 500_000_000)
        XCTAssertEqual(MacBridgeReconnectPolicy.delayNanoseconds(afterAttempt: 60), 5_000_000_000)
        XCTAssertEqual(MacBridgeReconnectPolicy.delayNanoseconds(afterAttempt: 120), 5_000_000_000)
    }

    func test_connectionAndDisconnectUseGenerationOwnedRetryTasks() throws {
        let source = try MobileEvalSources.mobileSource("MacBridgeClient.swift")
        let configure = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "configureICloud", keyword: "func", in: source)
        )
        let disconnect = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "disconnect", keyword: "func", in: source)
        )

        XCTAssertTrue(configure.contains("reconnectGeneration += 1"))
        XCTAssertTrue(configure.contains("let generation = reconnectGeneration"))
        XCTAssertTrue(configure.contains("while !Task.isCancelled, generation == self.reconnectGeneration"))
        XCTAssertTrue(configure.contains("self.reconnectTask = nil"))
        XCTAssertTrue(disconnect.contains("reconnectGeneration += 1"))
        XCTAssertTrue(disconnect.contains("reconnectTask?.cancel()"))
        XCTAssertTrue(disconnect.contains("reconnectTask = nil"))
    }
}
