import Foundation
import NativeAgentShared
import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.memory.deleteConfirmation`.
@MainActor
final class MemoryDeleteConfirmationEvalTests: XCTestCase {
    func test_confirmationIdentifiesTheOriginallySwipedMemory() throws {
        let swipedMemory = try makeMemory(id: "delete-target", text: "Delete this durable memory")
        let neighboringMemory = try makeMemory(id: "keep-neighbor", text: "Keep this other memory")

        let message = MemoryDeleteConfirmationPresentation.message(for: swipedMemory)

        XCTAssertTrue(message.contains(swipedMemory.text))
        XCTAssertFalse(message.contains(neighboringMemory.text))
    }

    func test_dialogActionReceivesItsItemInsteadOfRereadingOptionalSelectionState() throws {
        let source = try MobileEvalSources.mobileSource("MemoryView.swift")
        let listView = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "MemoryListView", keyword: "struct", in: source)
        )
        let dialog = try XCTUnwrap(
            listView.range(of: ".confirmationDialog(")
        )
        let dialogSource = String(listView[dialog.lowerBound...])

        // SwiftUI has no `confirmationDialog(item:)` overload. The shipping
        // pattern unwraps `pendingDeleteMemory` once in the actions builder and
        // the Delete button's action closure captures that unwrapped `memory`
        // value — the action never re-reads (or force-unwraps) the optional
        // selection state when it fires.
        XCTAssertTrue(dialogSource.contains("isPresented: isDeleteConfirmationPresented"))
        XCTAssertTrue(dialogSource.contains("if let memory = pendingDeleteMemory"))
        XCTAssertTrue(dialogSource.contains("store.deleteMemory(memory)"))
        XCTAssertFalse(dialogSource.contains("pendingDeleteMemory!"))
        XCTAssertFalse(dialogSource.contains("store.deleteMemory(pendingDeleteMemory"))
    }

    private func makeMemory(id: String, text: String) throws -> MemoryRecord {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "layer": "semantic",
            "text": text,
            "importance": 0.5,
            "confidence": 0.9,
            "createdAt": "2026-08-24T00:00:00Z",
        ])
        return try JSONDecoder().decode(MemoryRecord.self, from: data)
    }
}
