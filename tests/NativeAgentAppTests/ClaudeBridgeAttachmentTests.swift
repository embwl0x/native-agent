import ChatOrchestration
import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Claude bridge attachment responses")
struct ClaudeBridgeAttachmentTests {
    @Test("generated attachment metadata reaches the bridge without base64 payload")
    func generatedAttachmentMetadataIsReturned() throws {
        let attachment = ChatOrchestration.MultimodalAttachment(
            id: "generated-image-1",
            type: "image",
            base64: "large-private-payload",
            mime: "image/png",
            name: "image.png",
            byteSize: 42,
            path: "/tmp/data/generated_images/image.png"
        )

        let rows = ClaudeBridge.bridgeAttachmentPayload([attachment])
        let row = try #require(rows.first)

        #expect(rows.count == 1)
        #expect(row["id"] as? String == "generated-image-1")
        #expect(row["type"] as? String == "image")
        #expect(row["mime"] as? String == "image/png")
        #expect(row["name"] as? String == "image.png")
        #expect(row["byteSize"] as? Int == 42)
        #expect(row["path"] as? String == "/tmp/data/generated_images/image.png")
        #expect(row["base64"] == nil)
    }

    @Test("missing attachments return an empty bridge array")
    func missingAttachmentsAreEmpty() {
        #expect(ClaudeBridge.bridgeAttachmentPayload(nil).isEmpty)
    }
}
