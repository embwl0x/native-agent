import Foundation
import NativeAgentShared
import XCTest
@testable import NativeAgentMobile

/// Sweep 2026-09-01 item 36 — `ios.memory.search`.
///
/// Silent-failure class: UNREACHABLE DATA. iOS Memory was delete-only with no
/// `searchable` at all, so the only way to find one row among hundreds was to
/// scroll — and the one destructive action on the screen sat behind that
/// scroll. The fixing risk is the mirror image: a filtered-to-nothing list
/// that reads as "your memories failed to sync".
final class MemorySearchEvalTests: XCTestCase {

    /// `MemoryRecord`'s memberwise init is internal to NativeAgentShared, so
    /// the corpus is decoded from the same JSON shape the Mac publishes.
    private func memory(
        id: String,
        text: String,
        layer: String = "episodic",
        tags: [String]? = nil
    ) throws -> MemoryRecord {
        var object: [String: Any] = [
            "id": id,
            "layer": layer,
            "text": text,
            "importance": 0.5,
            "confidence": 0.5,
            "createdAt": "2026-09-01T00:00:00Z",
        ]
        if let tags { object["tags"] = tags }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MemoryRecord.self, from: data)
    }

    private func makeCorpus() throws -> [MemoryRecord] {
        [
            try memory(id: "a", text: "User prefers absolute paths in zsh"),
            try memory(id: "b", text: "Agent reads the worklog", layer: "semantic"),
            try memory(id: "c", text: "unrelated", tags: ["ZSH", "shell"]),
        ]
    }

    func test_searchMatchesTextLayerAndTagsCaseInsensitively() throws {
        let corpus = try makeCorpus()
        XCTAssertEqual(
            MemorySearchPresentation.filter(corpus, query: "zsh").map(\.id), ["a", "c"],
            "search must reach the tag index, not only the body text"
        )
        XCTAssertEqual(
            MemorySearchPresentation.filter(corpus, query: "SEMANTIC").map(\.id), ["b"],
            "layer is how the user actually slices this list"
        )
        XCTAssertEqual(MemorySearchPresentation.filter(corpus, query: "AbSoLuTe").map(\.id), ["a"])
    }

    /// An empty or whitespace query means "show everything", never "show
    /// nothing" — the failure mode where the list silently blanks on a
    /// stray space.
    func test_anEmptyQueryIsNoFilterRatherThanNoRows() throws {
        let corpus = try makeCorpus()
        XCTAssertEqual(MemorySearchPresentation.filter(corpus, query: "").count, 3)
        XCTAssertEqual(MemorySearchPresentation.filter(corpus, query: "   ").count, 3)
        XCTAssertEqual(MemorySearchPresentation.filter(corpus, query: "\n\t").count, 3)
    }

    /// The list is empty for two completely different reasons and must not
    /// blame the sync for the query.
    func test_aFilteredToNothingListIsNotReportedAsAFailedSync() {
        XCTAssertEqual(
            MemorySearchPresentation.emptyState(visibleCount: 0, syncedCount: 3, query: "nothing here"),
            .noMatches("nothing here")
        )
        XCTAssertEqual(
            MemorySearchPresentation.emptyState(visibleCount: 0, syncedCount: 0, query: ""),
            .noSyncedMemories
        )
        // Nothing synced AND a query typed: the honest answer is still that
        // there are no memories, not that the query missed.
        XCTAssertEqual(
            MemorySearchPresentation.emptyState(visibleCount: 0, syncedCount: 0, query: "zsh"),
            .noSyncedMemories
        )
        XCTAssertNil(
            MemorySearchPresentation.emptyState(visibleCount: 2, syncedCount: 3, query: "zsh"),
            "a non-empty result must render rows, not an empty state"
        )
    }

    /// The filter is LOCAL, over rows already synced. It must not have grown a
    /// remote call that would let the screen claim it searched the Mac.
    func test_searchStaysALocalFilterOverTheAlreadySyncedSnapshot() throws {
        let memoryView = try MobileEvalSources.mobileSource("MemoryView.swift")
        XCTAssertTrue(memoryView.contains(".searchable("), "the Memory screen must expose a search field")
        XCTAssertTrue(memoryView.contains("prompt: \"Search memories\""))

        guard let block = MobileEvalSources.blockBody(
            named: "MemorySearchPresentation", keyword: "enum", in: memoryView
        ) else {
            return XCTFail("could not locate MemorySearchPresentation")
        }
        for remote in ["iCloudSyncEngine", "await", "sendAction", "InboxAction"] {
            XCTAssertFalse(
                block.contains(remote),
                "memory search must stay a pure local filter; found \(remote)"
            )
        }
    }
}
