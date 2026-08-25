import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.autonomy.macOnlyNotice`.
///
/// This is the only visible ownership cue for a queue that the phone cannot
/// resolve. It must remain a rendered notice, not incidental footer prose.
final class AutonomyMacOnlyNoticeEvalTests: XCTestCase {
    func test_macOnlyAuthorityNoticeStatesTheUnavailableActions() {
        XCTAssertEqual(
            AutonomyMacOnlyNoticePresentation.message,
            "Applying training changes and approving learned behavior remain local-admin actions on the Mac."
        )
        XCTAssertEqual(AutonomyMacOnlyNoticePresentation.systemImage, "lock.circle")
    }

    func test_autonomyScreenRendersTheNamedAuthorityNotice() throws {
        let source = try MobileEvalSources.mobileSource("AutonomyView.swift")
        XCTAssertTrue(source.contains("Label(\n                    AutonomyMacOnlyNoticePresentation.message,"))
        XCTAssertTrue(source.contains("systemImage: AutonomyMacOnlyNoticePresentation.systemImage"))
    }
}
