import Foundation
import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.sync / ios.app.launchArgs
final class AppLaunchArgsEvalTests: XCTestCase {
    func testPairingLaunchArgumentRequiresExactlyOneValidSecret() {
        let secret = Data(repeating: 0xA5, count: 32).base64EncodedString()
        XCTAssertEqual(NativeAgentLaunchArgumentPresentation.pairingSecret(from: ["app", "-pairingSecretBase64", secret]), Data(repeating: 0xA5, count: 32))
        XCTAssertNil(NativeAgentLaunchArgumentPresentation.pairingSecret(from: ["app", "-pairingSecretBase64", "bad"]))
    }

    func testLaunchHookGuardsReapplicationAndUsesTheValidatedSecret() throws {
        let source = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        let hook = try XCTUnwrap(MobileEvalSources.blockBody(named: "checkLaunchArgsForPairingSecret", keyword: "private func", in: source))
        XCTAssertTrue(hook.contains("!didApplyPairingSecretLaunchArgument"))
        XCTAssertTrue(hook.contains("NativeAgentLaunchArgumentPresentation.pairingSecret(from: args)"))
        XCTAssertTrue(hook.contains("data.count"))
    }
}
