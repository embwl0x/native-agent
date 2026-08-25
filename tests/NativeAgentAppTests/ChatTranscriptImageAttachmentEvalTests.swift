import AppKit
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.transcript.imageAttachment
//
// Exercises the production transcript attachment partition, local image
// reader/cache seam, and the exact states consumed by
// MessageLocalImageAttachmentView. A missing file must reach the visible
// unavailable state rather than disappearing after the loading placeholder.

private func writeTranscriptPNG(to url: URL) throws {
    let image = NSImage(size: NSSize(width: 9, height: 7))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 9, height: 7).fill()
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: url)
}

@MainActor
@Test("transcript image attachments render decoded files and explicitly surface unreadable files")
func chatTranscriptImageAttachmentRenderAndFailureState() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-transcript-image-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let validURL = root.appendingPathComponent("receipt.png")
    try writeTranscriptPNG(to: validURL)
    let valid = PersistedAttachment(
        id: "rendered",
        type: "image",
        mime: "image/png",
        name: "receipt.png",
        byteSize: 63,
        path: validURL.path
    )
    let missing = PersistedAttachment(
        id: "unavailable",
        type: "image",
        mime: "image/png",
        name: "lost-receipt.png",
        byteSize: 63,
        path: root.appendingPathComponent("missing.png").path
    )

    // Both rows take the inline image route. The unavailable case cannot be
    // diverted to a generic file chip and then disappear from the transcript.
    let partition = ChatAttachmentPresentation.partition([valid, missing])
    #expect(partition.localImages.map(\.id) == ["rendered", "unavailable"])
    #expect(partition.chips.isEmpty)

    #expect(
        ChatLocalImageAttachmentPresentation.state(
            path: valid.path,
            hasLoadedImage: false,
            loadFailed: false
        ) == .loading
    )
    let rendered = try #require(ChatLocalImageAttachmentLoader.load(at: validURL))
    #expect(rendered.size.width > 0 && rendered.size.height > 0)
    #expect(
        ChatLocalImageAttachmentPresentation.state(
            path: valid.path,
            hasLoadedImage: true,
            loadFailed: false
        ) == .loaded
    )

    let missingURL = URL(fileURLWithPath: try #require(missing.path))
    #expect(ChatLocalImageAttachmentLoader.load(at: missingURL) == nil)
    #expect(
        ChatLocalImageAttachmentPresentation.state(
            path: missing.path,
            hasLoadedImage: false,
            loadFailed: true
        ) == .unavailable
    )
    #expect(
        ChatLocalImageAttachmentPresentation.unavailableDetail(for: missing) == "lost-receipt.png"
    )
}
