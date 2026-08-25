import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`.
///
/// Rows closed here:
///   * `ios.skills.store.refresh` — the snapshot decoder uses `try?` on nearly
///     every field, so a Mac-side shape change yields entries that decode
///     "successfully" while carrying nothing.
///   * `ios.skills.filterPicker` — the four filters match on the NORMALIZED
///     state string; a new Mac state normalises to something no filter names and
///     the skill becomes invisible outside "All".
///
/// Silent-failure class: SILENT ZERO. Both failures render a plausible, empty,
/// error-free screen.
final class SkillLifecycleDecodeEvalTests: XCTestCase {

    private func decode(_ json: String) throws -> SkillManifestEntry {
        try JSONDecoder().decode(SkillManifestEntry.self, from: Data(json.utf8))
    }

    private func decodeAll(_ json: String) throws -> [SkillManifestEntry] {
        try JSONDecoder().decode([SkillManifestEntry].self, from: Data(json.utf8))
    }

    // MARK: - ios.skills.store.refresh

    func test_nameIsTheOnlyRequiredFieldAndAMissingNameFailsLoudly() throws {
        let minimal = try decode(#"{"name": "vault-writer"}"#)
        XCTAssertEqual(minimal.name, "vault-writer")
        XCTAssertEqual(minimal.id, "vault-writer", "a snapshot row without an id must key off its name, not become id-less")

        // The one field with no sane fallback must still throw — a lenient
        // decoder here is what turns a shape change into a list of blank rows.
        XCTAssertThrowsError(try decode(#"{"id": "x", "state": "active"}"#))
    }

    func test_bothWireSpellingsOfTheSameFieldLandOnTheSameProperty() throws {
        XCTAssertEqual(try decode(#"{"name": "a", "use_count": 12}"#).use_count, 12)
        XCTAssertEqual(try decode(#"{"name": "a", "useCount": 12}"#).use_count, 12)
        XCTAssertEqual(try decode(#"{"name": "a", "state": "active"}"#).state, "active")
        XCTAssertEqual(try decode(#"{"name": "a", "status": "active"}"#).state, "active")
    }

    func test_aWrongTypedOptionalFieldIsDroppedRatherThanFailingTheWholeSnapshot() throws {
        // Documented tolerance: one bad field must not take out the catalog.
        // It must ALSO not be silently coerced into a plausible-looking value.
        let entry = try decode(#"{"name": "a", "use_count": "twelve", "triggers": "not-a-list"}"#)
        XCTAssertNil(entry.use_count)
        XCTAssertNil(entry.triggers)
        XCTAssertEqual(entry.name, "a")
    }

    func test_anArrayShapedSnapshotRoundTripsThroughEncodeAndDecode() throws {
        let original = try decodeAll("""
        [{"name": "a", "status": "enabled", "source": "learned", "use_count": 3},
         {"name": "b", "state": "quarantine", "version": "2"}]
        """)
        XCTAssertEqual(original.map(\.state), ["active", "quarantined"])

        // The store re-encodes entries into its own published list; a lossy
        // encode is how a skill loses its state between the snapshot and the row.
        let reencoded = try JSONDecoder().decode(
            [SkillManifestEntry].self, from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(reencoded.map(\.id), original.map(\.id))
        XCTAssertEqual(reencoded.map(\.state), original.map(\.state))
        XCTAssertEqual(reencoded.map(\.use_count), original.map(\.use_count))
    }

    // MARK: - ios.skills.filterPicker

    func test_everyMacStateSpellingNormalisesIntoTheBucketVocabularyTheFiltersUse() throws {
        // The filter enum is private to the view, so read its vocabulary from
        // the source rather than restating it here (a restated copy would drift
        // in lockstep with nothing).
        let source = try MobileEvalSources.mobileSource("SkillLifecycleView.swift")
        guard let body = MobileEvalSources.blockBody(named: "SkillFilter", keyword: "private enum", in: source) else {
            return XCTFail("could not locate `private enum SkillFilter` in SkillLifecycleView.swift")
        }
        let filterLabels = Set(
            MobileEvalSources.matches(#"case \w+\s*=\s*"([A-Za-z]+)""#, in: body).map { $0.lowercased() }
        )
        XCTAssertTrue(filterLabels.contains("all"), "parsed no filter vocabulary — parser drift, not app drift")

        let macSpellings = [
            "enabled", "active", "installed", "available", "proposal",
            "draft", "drafted", "disabled", "dormant", "quarantine", "quarantined",
        ]
        // Buckets that have NO filter of their own are reachable only under
        // "All". Today that is exactly `quarantined`; anything NEW joining this
        // set must be a deliberate decision, not a silent one.
        let knownFilterlessBuckets: Set<String> = ["quarantined"]

        var buckets: Set<String> = []
        for spelling in macSpellings {
            guard let state = try decode(#"{"name": "s", "state": "\#(spelling)"}"#).state else {
                return XCTFail("\(spelling) normalised to nil — the skill would carry no state at all")
            }
            buckets.insert(state)
        }

        let unreachable = buckets.subtracting(filterLabels).subtracting(knownFilterlessBuckets)
        XCTAssertTrue(
            unreachable.isEmpty,
            """
            \(unreachable.sorted()) normalise to a bucket no SkillFilter names, so skills in that
            state are invisible in every tab except All. Add a filter or add it to
            knownFilterlessBuckets deliberately.
            """
        )
    }

    func test_anUnrecognisedMacStateIsPreservedVerbatimNotErased() throws {
        // Preserving the raw string is what keeps the row visible under "All".
        // Erasing it to nil would drop the skill out of every state-aware view.
        let entry = try decode(#"{"name": "s", "state": "shadow_banned"}"#)
        XCTAssertEqual(entry.state, "shadow_banned")
        XCTAssertNil(try decode(#"{"name": "s"}"#).state)
    }
}
