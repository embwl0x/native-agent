import AppKit
import SwiftUI
import Testing
@testable import NativeAgentApp

@Suite("Full saved memory reading")
struct MemoryFullTextViewTests {
    @Test("memory timestamps describe saved or updated evidence, never unmeasured usage")
    func timestampMeaningAndUnavailableValuesAreHonest() {
        let created = "2026-08-01T12:00:00Z"
        let updated = "2026-08-20T12:00:00Z"
        #expect(MemoryRowTimestampPresentation.label(createdAt: created, updatedAt: updated).hasPrefix("updated "))
        #expect(MemoryRowTimestampPresentation.label(createdAt: created, updatedAt: nil).hasPrefix("saved "))
        #expect(MemoryRowTimestampPresentation.label(createdAt: created, updatedAt: " \n").hasPrefix("saved "))
        #expect(MemoryRowTimestampPresentation.label(createdAt: created, updatedAt: "broken") == "update time unavailable")
        #expect(MemoryRowTimestampPresentation.label(createdAt: "broken", updatedAt: nil) == "save time unavailable")
        #expect(MemoryRowTimestampPresentation.label(createdAt: "", updatedAt: nil) == "save time unavailable")
    }

    @MainActor
    @Test("long memory details mount in a bounded read-only sheet without changing text")
    func longMemoryHasABoundedFullTextSurface() throws {
        let text = (1...80).map { "Saved fact \($0): full source text remains available for review." }.joined(separator: "\n")
        let view = MemoryFullTextView(text: text)
        #expect(view.text == text)
        let host = NSHostingView(rootView: view)
        #expect(host.fittingSize == NSSize(width: 560, height: 420))
        let source = try AppSourceScraping.appSource("MemoryView.swift")
        #expect(source.contains("MemoryFullTextView(text: memory.text)"))
        #expect(source.contains(".accessibilityLabel(\"Read full memory\")"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains(".accessibilityIdentifier(\"memory.full-text.content\")"))
    }
}
