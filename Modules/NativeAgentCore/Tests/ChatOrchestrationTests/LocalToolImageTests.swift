import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration
@testable import Dispatcher
@testable import ProviderRouting

private struct ImageFileDispatcher: ToolDispatchClient {
    let root: URL
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        FileSystemActions.readFile(input, ConnectorActionContext(repoRoot: root.path))
    }
    func listAvailableTools() async throws -> [String] { ["read_file"] }
}

@Suite struct LocalToolImageTests {
    @Test func wholeConversationKeepsNewestPixelsAndAllReceipts() {
        var messages: [LLMMessage] = []
        for i in 0..<20 {
            messages.append(.init(role: .user, content: [.text("receipt-\(i)")]))
            messages.append(.init(role: .system, content: [.image(mediaType: "image/png",
                base64: Data(repeating: 0, count: 12).base64EncodedString(), name: "image-\(i)", byteSize: 12)],
                turnScopedClearAtNextUserMessage: true))
            LocalToolImage.boundConversation(&messages, maxImages: 3, maxBytes: 24)
        }
        let images = messages.flatMap(\.content).compactMap { block -> String? in
            if case .image(_, _, let name, _) = block { return name }; return nil
        }
        #expect(images == ["image-18", "image-19"])
        #expect(messages.count == 40)
        for i in 0..<20 { #expect(messages[i * 2].content == [.text("receipt-\(i)")]) }
        #expect(messages[1].turnScopedClearAtNextUserMessage)
        #expect(messages[1].content.contains { if case .text(let text) = $0 { return text.contains("no longer visible") }; return false })
        let bounded = messages
        LocalToolImage.boundConversation(&messages, maxImages: 3, maxBytes: 24)
        #expect(messages == bounded)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ctx = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let pixels = try #require(ctx.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent("a.png") as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination))
        return root
    }

    @Test func realFileReadCarriesPixelsAndKeepsReceiptsSmall() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let slots = await SwiftNativeTurnEngine.runIterationDispatchGroups(
            prepared: [.init(pairedId: "read-1", internalName: "read_file", dispatchInput: ["path": .string("a.png")])],
            modelId: "gpt-6-astra", surface: "studio_wander", tools: ImageFileDispatcher(root: root),
            progress: nil, onToolUse: { _ in }, onOutcome: { _, result, _ in
                #expect((try? result.serialize(pretty: false).count) ?? 9999 < 1000)
            })
        let slot = try #require(slots.first)
        #expect(!slot.isError)
        #expect(slot.images.count == 1)
        guard case .image(let mime, let base64, _, let bytes) = try #require(slot.images.first) else {
            Issue.record("No image block"); return
        }
        #expect(mime == "image/png")
        #expect(Data(base64Encoded: base64)?.count == bytes)
        #expect(CGImageSourceCreateWithData(try #require(Data(base64Encoded: base64)) as CFData, nil) != nil)
        let output = await SwiftNativeTurnEngine.makeSlotOutputs(prepared: slot.prepared,
            result: slot.result, isError: slot.isError)
        #expect(!(try output.record.result.serialize(pretty: false)).contains(base64))
        let messages = LocalToolImage.continuation([output.block] + slot.images)
        #expect(messages.count == 2)
        let body = OpenAIOAuthDirectAdapter(authPathOverride: root.appendingPathComponent("absent-auth.json"),
            telemetryDataRootOverride: root).buildResponsesBodyFromMessages(model: "gpt-6-astra",
            messages: messages, system: nil, tools: nil)
        let items = try #require(body["input"] as? [[String: Any]])
        #expect(items.first?["type"] as? String == "function_call_output")
        #expect(items.first?["call_id"] as? String == "read-1")
        let content = try #require(items.last?["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "input_image")
        #expect(content.first?["image_url"] as? String == "data:image/png;base64,\(base64)")
    }

    @Test func malformedAndNoModelReadsDoNotClaimPixels() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.png")
        #expect((try LocalToolImage.readAuthorizedFile(file)?.serialize(pretty: false))?.contains("failed") == true)
        try Data("not an image".utf8).write(to: file)
        let sink = LocalToolImage.Sink()
        let result = LocalToolImage.$sink.withValue(sink) { LocalToolImage.readAuthorizedFile(file) }
        #expect((try result?.serialize(pretty: false))?.contains("failed") == true)
        #expect(sink.finish(success: true).isEmpty)
    }

    @Test func fullMacDetachedConnectorPreservesImageSink() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = root.appendingPathComponent("trust")
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        let policy: JSONValue = .object([
            "permissionLevel": .string("full_mac_os"), "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "macControlPolicy": .object(["enabled": .bool(true), "file_ops_allowed": .bool(true)]),
        ])
        try policy.serializedData(pretty: false).write(to: trust.appendingPathComponent("policy.json"))
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let sink = LocalToolImage.Sink()
        let result = try await LocalToolImage.$sink.withValue(sink) {
            try await dispatcher.impl_full_mac_read_file(input: ["path": .string(root.appendingPathComponent("a.png").path)], surface: "app")
        }
        #expect((try result.serialize(pretty: false)).contains("image_pixels"))
        #expect(sink.finish(success: true).count == 1)
    }

    @Test func sandboxAndSymlinkDenialStayAheadOfImageRead() throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.png"),
            withDestinationURL: outside.appendingPathComponent("a.png"))
        let sink = LocalToolImage.Sink()
        let result = LocalToolImage.$sink.withValue(sink) {
            FileSystemActions.readFile(["path": .string("escape.png")], ConnectorActionContext(repoRoot: root.path))
        }
        #expect((try result.serialize(pretty: false)).contains("path_not_allowed"))
        #expect(sink.finish(success: true).isEmpty)
    }

    @Test func failedDispatchDiscardsPixelsAndClosedSinkRejectsLateWork() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalToolImage.Sink()
        _ = LocalToolImage.$sink.withValue(sink) { LocalToolImage.readAuthorizedFile(root.appendingPathComponent("a.png")) }
        #expect(sink.finish(success: false).isEmpty)
        let late = LocalToolImage.$sink.withValue(sink) { LocalToolImage.readAuthorizedFile(root.appendingPathComponent("a.png")) }
        #expect((try late?.serialize(pretty: false))?.contains("failed") == true)
        #expect(sink.finish(success: true).isEmpty)
    }

    @Test func ordinaryTextUnchangedAndImageIterationBounded() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("notes.txt")
        try Data("unchanged text".utf8).write(to: text)
        #expect(LocalToolImage.readAuthorizedFile(text) == nil)
        let slots = await SwiftNativeTurnEngine.runIterationDispatchGroups(
            prepared: (0..<6).map { .init(pairedId: "read-\($0)", internalName: "read_file", dispatchInput: ["path": .string("a.png")]) },
            modelId: "gpt-6-astra", surface: "studio_wander", tools: ImageFileDispatcher(root: root),
            progress: nil, onToolUse: { _ in }, onOutcome: { _, _, _ in })
        #expect(slots.flatMap(\.images).count == 4)
        #expect(slots.suffix(2).allSatisfy { $0.isError })
    }
}
