import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.desk.sections`.
///
/// DeskStatus is Mac-owned. Terminal statuses cross the mobile boundary by
/// carrying a closedAt stamp, so the iOS grouping cannot be a hand-maintained
/// copy of the Mac's terminal-status list.
final class DeskSectionsEvalTests: XCTestCase {
    func test_everyMacDeskStatusHasOneMobileSectionAndTerminalRowsUseTheirClosureStamp() throws {
        let macModels = try MobileEvalSources.repoFile(
            "Modules/NativeAgentCore/Sources/PersistenceCore/DeskModels.swift"
        )
        let macProjection = try MobileEvalSources.repoFile(
            "Sources/NativeAgentApp/MacSyncEngine+Snapshots.swift"
        )
        let statusBody = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "DeskStatus", keyword: "enum", in: macModels)
        )
        let statusLine = try XCTUnwrap(
            statusBody.split(separator: "\n").first {
                String($0).trimmingCharacters(in: .whitespaces).hasPrefix("case ")
            }
        )
        let statuses = String(statusLine)
            .trimmingCharacters(in: .whitespaces)
            .dropFirst("case ".count)
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let terminalBody = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "isTerminal", keyword: "var", in: statusBody)
        )
        let terminalStatuses = Set(MobileEvalSources.matches(#"\.([A-Za-z_][A-Za-z0-9_]*)"#, in: terminalBody))

        XCTAssertFalse(statuses.isEmpty)
        XCTAssertFalse(terminalStatuses.isEmpty)
        XCTAssertTrue(terminalStatuses.isSubset(of: Set(statuses)))
        XCTAssertTrue(
            macProjection.contains("closedAt: item.closedAt,"),
            "The Mac Desk projection must carry its terminal proof to the mobile snapshot."
        )

        for status in statuses {
            let isTerminal = terminalStatuses.contains(status)
            let section = MobileDeskSectionPresentation.section(
                requiresOwnerInput: true,
                closedAt: isTerminal ? "2026-08-24T12:00:00Z" : nil
            )
            XCTAssertEqual(section, isTerminal ? .history : .waitingOnYou, "unexpected section for Mac status \(status)")
        }

        XCTAssertEqual(
            MobileDeskSectionPresentation.section(requiresOwnerInput: false, closedAt: nil),
            .active
        )
        XCTAssertEqual(
            MobileDeskSectionPresentation.section(requiresOwnerInput: true, closedAt: "  "),
            .waitingOnYou
        )
    }

    func test_deskViewDelegatesEveryBucketToTheClosureBasedSectionProjection() throws {
        let source = try MobileEvalSources.mobileSource("DeskView.swift")
        XCTAssertFalse(source.contains("func isTerminal(_ status: String)"))
        XCTAssertEqual(
            MobileEvalSources.matches("(MobileDeskSectionPresentation\\.section\\(for: \\$0\\))", in: source).count,
            3
        )
    }
}
