import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.knowledgegraph.emptyState.deadInstruction
final class KnowledgeGraphEmptyStateDeadInstructionEvalTests: XCTestCase {
    func testEmptyStatesNameTheMacPublisherAndDoNotImplyAnUnavailableIPhoneCreateAction() {
        XCTAssertTrue(KnowledgeGraphEmptyStatePresentation.unpublishedDescription.contains("read-only on iPhone"))
        XCTAssertTrue(KnowledgeGraphEmptyStatePresentation.unpublishedDescription.contains("Mac app"))

        XCTAssertTrue(KnowledgeGraphEmptyStatePresentation.emptyPublishedDescription.contains("read-only on iPhone"))
        XCTAssertTrue(KnowledgeGraphEmptyStatePresentation.emptyPublishedDescription.contains("Mac publishes entities"))
        XCTAssertTrue(KnowledgeGraphEmptyStatePresentation.emptyPublishedDescription.contains("pull to refresh"))
        XCTAssertFalse(KnowledgeGraphEmptyStatePresentation.emptyPublishedDescription.localizedCaseInsensitiveContains("add an entity"))
    }

    func testKnowledgeGraphUsesTheSafeEmptyStateCopyForBothPublicationStates() throws {
        let source = try MobileEvalSources.mobileSource("KnowledgeGraphView.swift")
        let graph = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "KnowledgeGraphView", keyword: "struct", in: source)
        )

        XCTAssertTrue(graph.contains("KnowledgeGraphEmptyStatePresentation.unpublishedDescription"))
        XCTAssertTrue(graph.contains("KnowledgeGraphEmptyStatePresentation.emptyPublishedDescription"))
        XCTAssertTrue(graph.contains(".refreshable { await store.refresh(client: bridgeClient) }"))
    }
}
