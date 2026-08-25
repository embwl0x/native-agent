import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.sync / ios.voiceOutput.enabled
final class VoiceOutputEnabledEvalTests: XCTestCase {
    func testVoiceOutputRequiresThePersistedEnablementGateBeforePlayback() throws {
        let source = try MobileEvalSources.mobileSource("VoiceOutputController.swift")
        let speak = try XCTUnwrap(MobileEvalSources.blockBody(named: "speak", keyword: "func", in: source))
        XCTAssertTrue(source.contains("@AppStorage(\"voiceOutputEnabled\") var enabled = true"))
        XCTAssertTrue(speak.contains("guard enabled, !text.isEmpty else { return }"))
    }
}
