import Foundation
import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.settings.personality.traits`.
final class PersonalityTraitsEvalTests: XCTestCase {
    func test_traitValuesClampAndFlagOutOfRangeOrInvalidMacValues() {
        XCTAssertEqual(
            TraitValuePresentation.project(0.42),
            .init(normalizedValue: 0.42, wasClamped: false, percentageText: "42%", warningText: nil)
        )

        let belowRange = TraitValuePresentation.project(-0.25)
        XCTAssertEqual(belowRange.normalizedValue, 0)
        XCTAssertEqual(belowRange.percentageText, "0%")
        XCTAssertTrue(belowRange.wasClamped)
        XCTAssertTrue(belowRange.warningText?.contains("outside 0–100%") == true)

        let aboveRange = TraitValuePresentation.project(8)
        XCTAssertEqual(aboveRange.normalizedValue, 1)
        XCTAssertEqual(aboveRange.percentageText, "100%")
        XCTAssertTrue(aboveRange.wasClamped)

        let invalid = TraitValuePresentation.project(.nan)
        XCTAssertEqual(invalid.normalizedValue, 0)
        XCTAssertEqual(invalid.percentageText, "0%")
        XCTAssertTrue(invalid.wasClamped)
        XCTAssertTrue(invalid.warningText?.localizedCaseInsensitiveContains("invalid") == true)
    }

    func test_stalePersonalitySnapshotWarnsThatTraitsMayBeOutOfDate() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let state = PersonalitySnapshotPresentation.state(
            lastSyncedAt: now.addingTimeInterval(-31),
            now: now
        )

        XCTAssertTrue(PersonalitySnapshotPresentation.needsAttention(state))
        XCTAssertTrue(PersonalitySnapshotPresentation.detail(for: state)?.contains("out of date") == true)
    }

    func test_personalityScreenUsesClampedTraitProjectionAndSnapshotFreshness() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        XCTAssertTrue(source.contains("let projection = TraitValuePresentation.project(value)"))
        XCTAssertTrue(source.contains("ProgressView(value: projection.normalizedValue)"))
        XCTAssertTrue(source.contains("Text(\"Clamped\")"))
        XCTAssertTrue(source.contains("LabeledContent(\"Snapshot\")"))
        XCTAssertFalse(source.contains("ProgressView(value: value)"))
    }
}
