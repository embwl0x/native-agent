import Foundation
import XCTest
@testable import NativeAgentMobile

/// Sweep 2026-09-01 item 36 — `ios.macIntegration.projectionHonesty`.
///
/// Silent-failure class: FABRICATED AUTHORITY. When the Mac had never
/// published a permission projection, `load()` set `permissions = [:]` and
/// `projectionError = nil` — indistinguishable from a healthy sync. The view
/// then rendered all eleven `defaultValue(id:mode:)` rows as live, editable
/// toggles, so an unpaired phone showed a complete and entirely invented
/// policy for Calendar, Mail, Messages, Contacts and the rest, with nothing
/// anywhere saying it was a guess.
@MainActor
final class MacIntegrationProjectionHonestyEvalTests: XCTestCase {

    func test_aMacThatNeverPublishedIsAwaitingMacNotAHealthyDefaultMatrix() {
        let sync = MacIntegrationPermissionsSync(
            projectionLoader: { nil },
            observesExternalChanges: false
        )

        XCTAssertEqual(sync.projectionState, .awaitingMac)
        XCTAssertFalse(
            sync.hasMacProjection,
            "an absent projection must never be presented as the Mac's answer"
        )
        XCTAssertTrue(sync.permissions.isEmpty)
        XCTAssertNil(
            sync.projectionError,
            "never-published is not a malformed-projection error; it is its own state"
        )
    }

    func test_aReadableProjectionIsTheOnlyStateThatCountsAsMacAuthority() {
        let published = MacIntegrationPermissionsSync(
            projectionLoader: { ["calendar": ["read": true, "write": false]] },
            observesExternalChanges: false
        )
        XCTAssertEqual(published.projectionState, .published)
        XCTAssertTrue(published.hasMacProjection)
        XCTAssertTrue(published.get(id: "calendar", mode: "read"))

        let malformed = MacIntegrationPermissionsSync(
            projectionLoader: { ["calendar": "not a dictionary"] },
            observesExternalChanges: false
        )
        XCTAssertFalse(malformed.hasMacProjection)
        XCTAssertNotNil(malformed.projectionError)
        if case .malformed = malformed.projectionState {} else {
            XCTFail("an unreadable projection must be \\.malformed, got \(malformed.projectionState)")
        }
        XCTAssertFalse(
            malformed.get(id: "calendar", mode: "read"),
            "an unreadable authority projection must still fail closed"
        )
    }

    /// The defaults survive only as a labelled placeholder. The screen has to
    /// say where the numbers came from and must not let the user "change" a
    /// value the Mac never sent.
    func test_theDefaultsSurviveOnlyAsAnExplicitlyLabelledPlaceholder() throws {
        XCTAssertEqual(
            MacIntegrationProjectionPresentation.awaitingMacTitle,
            "Not yet received from the Mac"
        )
        XCTAssertTrue(
            MacIntegrationProjectionPresentation.awaitingMacDetail.contains("nothing below is confirmed policy"),
            "the awaiting-Mac copy must disclaim authority in words, not by omission"
        )
        XCTAssertTrue(
            MacIntegrationProjectionPresentation.placeholderRowNote.lowercased().contains("placeholder"),
            "each row must name itself a placeholder"
        )

        let view = try MobileEvalSources.mobileSource("MacIntegrationView.swift")
        XCTAssertTrue(
            view.contains("isPlaceholder: !sync.hasMacProjection"),
            "the rows must be driven by whether the Mac actually published"
        )
        XCTAssertTrue(
            view.contains("guard !isSaving, !isPlaceholder else { return }"),
            "a placeholder toggle must not be able to write policy"
        )
        for disabled in [
            ".disabled(!row.supportsRead || isSaving || isPlaceholder)",
            ".disabled(!row.supportsWrite || isSaving || isPlaceholder)",
        ] {
            XCTAssertTrue(view.contains(disabled), "missing placeholder gate: \(disabled)")
        }
    }
}
