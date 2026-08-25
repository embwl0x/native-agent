import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.sync / ios.bridge.setup
final class ICloudBridgeSetupEvalTests: XCTestCase {
    func testSetupKeepsTheMainThreadOutOfUbiquityLookupAndPublishesRetryableFailure() throws {
        let source = try MobileEvalSources.mobileSource("iCloudBridge.swift")
        let setup = try XCTUnwrap(MobileEvalSources.blockBody(named: "setup", keyword: "func", in: source))
        let apply = try XCTUnwrap(MobileEvalSources.blockBody(named: "applyContainerResult", keyword: "private func", in: source))

        XCTAssertTrue(setup.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(setup.contains("await self?.applyContainerResult(containerURL, generation: generation)"))
        XCTAssertTrue(apply.contains("setupTask = nil"))
        XCTAssertTrue(apply.contains("available = false"))
        XCTAssertTrue(apply.contains("isSetUp = false"))
        XCTAssertTrue(apply.contains("iCloud unavailable"))
    }

    func testSetupShortCircuitsToTheCloudKitReadyStateWhenTransportIsAvailable() throws {
        let source = try MobileEvalSources.mobileSource("iCloudBridge.swift")
        let setup = try XCTUnwrap(MobileEvalSources.blockBody(named: "setup", keyword: "func", in: source))

        XCTAssertTrue(setup.contains("if deviceTransport != nil"))
        XCTAssertTrue(setup.contains("available = true"))
        XCTAssertTrue(setup.contains("syncStatus = \"CloudKit ready\""))
    }
}
