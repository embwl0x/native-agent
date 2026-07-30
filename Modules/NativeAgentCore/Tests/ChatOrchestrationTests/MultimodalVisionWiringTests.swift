import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration
@testable import ProviderRouting

// ChatOrchestration-layer tests for the native vision wiring:
//  - attachment → .image content-block conversion (image / non-image / empty).
//  - the default-flatten TRIPWIRE prepends an honest note for non-vision adapters.
//  - history persistence does NOT balloon (no base64 in the JSONL record).
@Suite struct MultimodalVisionWiringTests {

    private static let b64 = "QUJDRA=="

    // MARK: - Attachment → image block conversion

    @Test func imageAttachment_convertsToImageBlock() {
        let att = MultimodalAttachment(type: "image", base64: Self.b64, mime: "image/png", name: "p.png", byteSize: 4)
        let blocks = SwiftNativeChatOrchestrationClient.imageBlocksFromAttachments([att])
        #expect(blocks.count == 1)
        guard case let .image(mediaType, base64, name, byteSize) = blocks[0] else {
            Issue.record("expected .image block"); return
        }
        #expect(mediaType == "image/png")
        #expect(base64 == Self.b64)
        #expect(name == "p.png")
        #expect(byteSize == 4)
    }

    @Test func nonImageAttachment_skipped() {
        let att = MultimodalAttachment(type: "file", base64: Self.b64, mime: "application/pdf", name: "doc.pdf", byteSize: 4)
        #expect(SwiftNativeChatOrchestrationClient.imageBlocksFromAttachments([att]).isEmpty)
    }

    @Test func emptyBase64Image_skipped() {
        let att = MultimodalAttachment(type: "image", base64: "", mime: "image/png", name: "p.png", byteSize: 0)
        #expect(SwiftNativeChatOrchestrationClient.imageBlocksFromAttachments([att]).isEmpty)
    }

    @Test func noAttachments_emptyResult() {
        #expect(SwiftNativeChatOrchestrationClient.imageBlocksFromAttachments([]).isEmpty)
    }

    // MARK: - Tripwire (default-flatten, non-vision adapter)

    /// A non-vision LLMAdapter (only implements complete(prompt:)) routed through
    /// the default completeMessages flatten must prepend an honest "could not see
    /// the image" note and NEVER stringify base64.
    final class NonVisionAdapter: LLMAdapter, @unchecked Sendable {
        let providerId = "stub_nonvision"
        nonisolated(unsafe) var lastPrompt: String?
        func complete(prompt: String, system: String?, model: String) async throws -> String {
            lastPrompt = prompt
            return "ok"
        }
    }

    @Test func tripwire_prependsHonestNote_andDropsBase64() async throws {
        let adapter = NonVisionAdapter()
        let msg = LLMMessage.userWithImages(
            "what is this?",
            images: [.image(mediaType: "image/png", base64: Self.b64, name: "p.png", byteSize: 4)]
        )
        // Bind the hermetic trace root so the tripwire row lands in OUR tmp dir,
        // never the live default traces/events.jsonl (test-hermeticity nit
        // 2026-06-11). The override propagates into the adapter's internal
        // append via LLMCallContext.
        let tmpRoot = try Self.makeTraceTmpRoot("tripwire-note")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        try await LLMCallContext.$traceDataRootOverride.withValue(tmpRoot) {
            _ = try await adapter.completeMessages(messages: [msg], system: nil, model: "m", tools: nil)
        }
        let prompt = try #require(adapter.lastPrompt)
        #expect(prompt.contains("could not view the attached image"))
        #expect(prompt.contains("1 image(s)"))
        // The base64 bytes MUST NOT appear in the flattened prompt.
        #expect(!prompt.contains(Self.b64))
        // The user's actual text still rides along.
        #expect(prompt.contains("what is this?"))
    }

    /// The tripwire row lands in the bound hermetic root, carries the right
    /// shape, and the LIVE default traces/events.jsonl is NEVER touched.
    @Test func tripwire_writesTraceToOverrideRoot_notLiveDefault() async throws {
        let tmpRoot = try Self.makeTraceTmpRoot("tripwire-trace")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let tmpTraces = tmpRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")

        // Snapshot the LIVE default traces file so we can prove it's untouched.
        let liveTraces = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let liveBefore = (try? Data(contentsOf: liveTraces)) ?? Data()

        let adapter = NonVisionAdapter()
        let msg = LLMMessage.userWithImages(
            "describe",
            images: [.image(mediaType: "image/png", base64: Self.b64, name: "p.png", byteSize: 4)]
        )
        try await LLMCallContext.$traceDataRootOverride.withValue(tmpRoot) {
            _ = try await adapter.completeMessages(messages: [msg], system: nil, model: "m", tools: nil)
        }

        // 1. The row landed in OUR tmp root.
        let raw = try String(contentsOf: tmpTraces, encoding: .utf8)
        let lines = raw.split(separator: "\n").map(String.init)
        let row = try #require(
            lines.last.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        )
        #expect(row["kind"] as? String == "vision.attachment_unsupported")
        let payload = try #require(row["payload"] as? [String: Any])
        #expect(payload["provider"] as? String == "stub_nonvision")
        #expect(payload["model"] as? String == "m")
        #expect(payload["imageCount"] as? Int == 1)
        // Base64 bytes are NEVER stringified into the trace row.
        #expect(!raw.contains(Self.b64))

        // 2. The LIVE default traces file is byte-for-byte untouched.
        let liveAfter = (try? Data(contentsOf: liveTraces)) ?? Data()
        #expect(liveAfter == liveBefore)
    }

    private static func makeTraceTmpRoot(_ tag: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("na-vision-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // History no-balloon is pinned in ChatOrchestrationClientTests.swift
    // (chatClient_imageAttachment_* ) where the client test harness lives.
}
