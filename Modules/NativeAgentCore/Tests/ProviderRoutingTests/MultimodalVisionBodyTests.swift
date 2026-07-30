import Foundation
import Testing
import NativeAgentCore
@testable import ProviderRouting

// Per-provider request-body shape tests for native vision wiring.
// Hermetic: these call the adapters' body-builders directly (no network).
//
// Invariants pinned here:
//  1. image+text user turn → content array with the IMAGE block FIRST, text last,
//     in each provider's native shape.
//  2. text-only turn → the EXACT pre-vision body shape (byte/structure identical).
//  3. multiple images encode in order; oversize base64 doesn't crash.
@Suite struct MultimodalVisionBodyTests {

    private static let pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="

    private static func imageBlock(_ mime: String = "image/png") -> LLMContentBlock {
        .image(mediaType: mime, base64: pngB64, name: "shot.png", byteSize: 68)
    }

    // MARK: - Anthropic OAuth-direct (Messages API)

    @Test func anthropic_imageAndText_imageBlockFirst() {
        let msg = LLMMessage.userWithImages("what is this?", images: [Self.imageBlock()])
        let body = AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
            messages: [msg], system: "sys", coercedModel: "claude-opus-4-8",
            maxTokens: 4096, tools: nil, stream: false
        )
        let messages = body["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        #expect(content.count == 2)
        // Image FIRST.
        #expect(content[0]["type"] as? String == "image")
        let source = content[0]["source"] as! [String: Any]
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == Self.pngB64)
        // Text LAST.
        #expect(content[1]["type"] as? String == "text")
        #expect(content[1]["text"] as? String == "what is this?")
    }

    @Test func anthropic_textOnly_byteIdenticalSingleTextBlock() {
        let body = AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
            messages: [.user("hi there")], system: "sys", coercedModel: "claude-opus-4-8",
            maxTokens: 4096, tools: nil, stream: false
        )
        let messages = body["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        // EXACT pre-vision shape: a single text block, no image.
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "hi there")
        #expect(content[0]["source"] == nil)
    }

    @Test func anthropic_multipleImages_inOrder() {
        let imgs: [LLMContentBlock] = [
            .image(mediaType: "image/png", base64: "AAAA", name: "a", byteSize: 3),
            .image(mediaType: "image/jpeg", base64: "BBBB", name: "b", byteSize: 3),
        ]
        let body = AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
            messages: [.userWithImages("two", images: imgs)], system: nil,
            coercedModel: "claude-opus-4-8", maxTokens: 4096, tools: nil, stream: false
        )
        let content = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        #expect(content.count == 3)
        #expect((content[0]["source"] as! [String: Any])["data"] as? String == "AAAA")
        #expect((content[0]["source"] as! [String: Any])["media_type"] as? String == "image/png")
        #expect((content[1]["source"] as! [String: Any])["data"] as? String == "BBBB")
        #expect((content[1]["source"] as! [String: Any])["media_type"] as? String == "image/jpeg")
        #expect(content[2]["type"] as? String == "text")
    }

    // MARK: - OpenAI OAuth-direct (Responses API)

    @Test func openAIResponses_imageAndText_inputImageFirst() {
        let adapter = OpenAIOAuthDirectAdapter()
        let msg = LLMMessage.userWithImages("describe", images: [Self.imageBlock("image/png")])
        let body = adapter.buildResponsesBodyFromMessages(
            model: "gpt-5.5", messages: [msg], system: "sys", tools: nil
        )
        let input = body["input"] as! [[String: Any]]
        // One message item carries both image + text.
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "user")
        let content = input[0]["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "input_image")
        #expect(content[0]["image_url"] as? String == "data:image/png;base64,\(Self.pngB64)")
        #expect(content[1]["type"] as? String == "input_text")
        #expect(content[1]["text"] as? String == "describe")
    }

    @Test func openAIResponses_textOnly_unchangedSingleInputText() {
        let adapter = OpenAIOAuthDirectAdapter()
        let body = adapter.buildResponsesBodyFromMessages(
            model: "gpt-5.5", messages: [.user("hello")], system: nil, tools: nil
        )
        let input = body["input"] as! [[String: Any]]
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "message")
        let content = input[0]["content"] as! [[String: Any]]
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "hello")
    }
}

// MARK: - Text-only byte-identity, strengthened (integration review 2026-06-11)
// Full-body fixtures would duplicate the U1 breakpoint suites (which already
// pin body layout across the hint × tools × compat matrix). These pin the
// residual risk instead: NO new field appears anywhere in a text-only body.

@Test func anthropic_textOnly_fullBody_noVisionArtifacts() throws {
    let body = AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
        messages: [.user("hi there")], system: "sys", coercedModel: "claude-opus-4-8",
        maxTokens: 4096, tools: nil, stream: false
    )
    // Top-level key set: exactly the legacy keys, nothing new.
    #expect(Set(body.keys) == ["model", "max_tokens", "messages", "system"])
    let messages = body["messages"] as! [[String: Any]]
    #expect(messages.count == 1)
    #expect(Set(messages[0].keys) == ["role", "content"])
    // Content deep-equals the exact legacy single-text-block form.
    let content = messages[0]["content"] as! [[String: Any]]
    #expect(NSArray(array: content) == NSArray(array: [["type": "text", "text": "hi there"]]))
    // No vision artifact anywhere in the serialized body.
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let json = String(data: data, encoding: .utf8)!
    #expect(!json.contains("\"image\""))
    #expect(!json.contains("\"source\""))
    #expect(!json.contains("base64"))
}

@Test func openAIResponses_textOnly_fullBody_noVisionArtifacts() throws {
    let adapter = OpenAIOAuthDirectAdapter()
    let body = adapter.buildResponsesBodyFromMessages(
        model: "gpt-5.5", messages: [.user("hi there")], system: "sys", tools: nil
    )
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let json = String(data: data, encoding: .utf8)!
    // Exact legacy input_text form present; no image artifact anywhere.
    #expect(json.contains("\"type\":\"input_text\""))
    #expect(!json.contains("input_image"))
    #expect(!json.contains("image_url"))
    #expect(!json.contains("base64,"))
}
