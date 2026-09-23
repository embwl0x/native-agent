import Foundation
import Testing
@testable import ChatOrchestration
import PersistenceCore

private func artifactMessage(_ id: String, role: String = "assistant", content: String,
                             metadata: [String: JSONValue] = [:]) -> ChatMessage {
    ChatMessage(role: role, content: content, timestamp: "2026-09-21T12:00:00Z", extras: .object([
        "id": .string(id), "metadata": .object(metadata),
    ]))
}

@Test func artifactContextKeepsVersionAndExactConversationWithoutInventingApproval() {
    let root = URL(fileURLWithPath: "/tmp/artifact-context-fixture/data")
    let messages = [
        artifactMessage("request", role: "user", content: "Make the silver orchard mockup"),
        artifactMessage("image", content: "Here is version two", metadata: ["attachments": .array([.object([
            "id": .string("image-v2"), "name": .string("approved.png"),
            "path": .string("/tmp/orchard.png"), "sha256": .string("recorded-sha"),
            "base64": .string("must-never-appear"),
        ])])]),
        artifactMessage("reaction", role: "user", content: "I like the older one better"),
    ]
    let found = ArtifactContextProjection.chatCandidates(messages, sessionID: "original-session",
        query: "silver orchard mockup User approved", sampled: false, dataRoot: root)
    #expect(found.count == 1)
    let value = ArtifactContextProjection.object(found.first?.value)
    #expect(value["recorded_sha256"] == .string("recorded-sha"))
    #expect(value["approval"] == .string("unresolved; no approval binding inferred"))
    #expect(value["current_availability"] == .string("not_checked"))
    let source = ArtifactContextProjection.object(value["source_message"])
    #expect(source["message_id"] == .string("image"))
    #expect(source["session_id"] == .string("original-session"))
    let rendered = (try? found.first?.value.serialize(pretty: false)) ?? ""
    #expect(rendered.contains("older one better"))
    #expect(!rendered.contains("must-never-appear"))
}

@Test func artifactContextDoesNotPromoteSensitiveOrSignedLocators() {
    let root = URL(fileURLWithPath: "/tmp/artifact-context-fixture/data")
    let messages = [artifactMessage("private", content: "orchard mockup", metadata: ["attachments": .array([
        .object(["id": .string("secret"), "path": .string(root.appendingPathComponent("providers/account.json").path)]),
        .object(["id": .string("signed"), "url": .string("https://example.com/mockup.png?token=secret")]),
        .object(["id": .string("bytes-only"), "name": .string("orchard.png"), "base64": .string("not-returned")]),
    ])])]
    let found = ArtifactContextProjection.chatCandidates(messages, sessionID: "safe", query: "orchard",
        sampled: false, dataRoot: root)
    #expect(found.count == 1)
    let value = ArtifactContextProjection.object(found.first?.value)
    #expect(value["attachment_id"] == .string("bytes-only"))
    #expect(value["recorded_locator"] == nil)
    #expect(value["open_current_file"] == nil)
}

@Test func artifactContextNeverCallsSampledRowsAdjacentOrUsesThemAsApproval() {
    let messages = [
        artifactMessage("unrelated", role: "user", content: "I approve this unrelated thing"),
        artifactMessage("artifact", content: "orchard", metadata: ["attachments": .array([.object([
            "id": .string("file"), "path": .string("/tmp/orchard.txt"),
        ])])]),
    ]
    let found = ArtifactContextProjection.chatCandidates(messages, sessionID: "sampled", query: "orchard",
        sampled: true, dataRoot: URL(fileURLWithPath: "/tmp/data"))
    let value = ArtifactContextProjection.object(found.first?.value)
    #expect(value["context_is_adjacent"] == .bool(false))
    if case .array(let context)? = value["conversation_context"] { #expect(context.count == 1) }
    else { Issue.record("Missing conversation context") }
    let rendered = (try? found.first?.value.serialize(pretty: false)) ?? ""
    #expect(!rendered.contains("unrelated thing"))
}

@Test func artifactContextExtractsRetainedToolArtifactAndKeepsRelativePathUnresolved() {
    let messages = [artifactMessage("receipt", role: "tool", content: "", metadata: [
        "toolName": .string("image_generate"),
        "resultSummary": .string(#"{"images":[{"path":"/tmp/orchard.png","filename":"orchard.png"}],"artifacts":[{"path":"docs/orchard.md"}]}"#),
    ])]
    let found = ArtifactContextProjection.chatCandidates(messages, sessionID: "images", query: "orchard",
        sampled: false, dataRoot: URL(fileURLWithPath: "/tmp/data"))
    #expect(found.count == 2)
    let relative = found.map { ArtifactContextProjection.object($0.value) }
        .first { $0["recorded_locator"] == .string("docs/orchard.md") }
    #expect(relative?["open_current_file"] == nil)
    #expect(relative?["locator_note"] != nil)
}
