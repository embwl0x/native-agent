import Testing
@testable import NativeAgentApp

@Test
func memoryDeletionPreview_normalizesWhitespaceAndIdentifiesMemory() {
    let preview = MemoryDeletionPresentation.preview(for: "  prefers\ncareful   release reviews  ")

    #expect(preview == "prefers careful release reviews")
}

@Test
func memoryDeletionPreview_isBounded() {
    let preview = MemoryDeletionPresentation.preview(
        for: String(repeating: "a", count: 200),
        maxCharacters: 24
    )

    #expect(preview.count == 24)
    #expect(preview.hasSuffix("\u{2026}"))
    #expect(MemoryDeletionPresentation.preview(for: "   ", maxCharacters: 5).count == 5)
}
