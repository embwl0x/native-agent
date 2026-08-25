import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.activity.navigationDestinations`.
///
/// The production contract drives every stack-owning destination, while the
/// source assertion covers the one destination whose view has no stack option.
final class ActivityNavigationDestinationsEvalTests: XCTestCase {
    func test_everyActivityDestinationIsSafeInsideTheActivityNavigationStack() throws {
        XCTAssertEqual(
            Set(ActivitySection.allCases),
            [.approvals, .inbox, .memoryProposals, .selfImprovement]
        )
        for section in ActivitySection.allCases {
            XCTAssertFalse(
                ActivityScreenPresentation.destinationEmbedsNavigationStack(for: section),
                "\(section.rawValue) would nest a NavigationStack under Activity"
            )
        }

        let activitySource = try MobileEvalSources.mobileSource("ActivityView.swift")
        for section in ["approvals", "inbox", "memoryProposals"] {
            XCTAssertTrue(
                activitySource.contains("destinationEmbedsNavigationStack(for: .\(section))"),
                "\(section) stopped using Activity's navigation-destination contract"
            )
        }

        let autonomySource = try MobileEvalSources.mobileSource("AutonomyView.swift")
        XCTAssertFalse(
            autonomySource.contains("NavigationStack"),
            "Self Improvement must remain stack-free when Activity pushes it"
        )
    }
}
