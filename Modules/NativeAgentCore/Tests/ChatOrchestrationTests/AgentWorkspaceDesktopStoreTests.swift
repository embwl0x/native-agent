import Foundation
import Darwin
import Testing
import PersistenceCore
@testable import ChatOrchestration

private func desktopRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-desktop-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func replaceDesktopBytes(_ data: Data, at url: URL) throws {
    try data.write(to: url)
    #expect(chmod(url.path, 0o600) == 0)
}

@Test func workspaceDesktopRestartRetainsExactTargetsAndNamedArrangement() throws {
    let root = try desktopRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let document = AgentWorkspaceLocation.record(tool: "read_file", input: ["path": .string("/workspace/notes.md")], title: "Notes")
    let conversation = AgentWorkspaceLocation.record(tool: "agent_read",
        input: ["agent": .string("claude:claude"), "conversation": .string("conversation-42")], title: "Claude")
    let anchor = AgentWorkspaceLocation.record(tool: "desk_read", input: ["handle": .string("desk:project")], title: "Project")
    let saved = AgentWorkspaceSavedDesktop(name: "Research desk", current: document, places: [document, conversation], workAnchor: anchor, workTopic: "Research")
    let state = AgentWorkspaceDesktopState(current: conversation, places: [document, conversation], workAnchor: anchor,
        workTopic: "Research", saved: [saved], selectedWorkspaceID: saved.id)
    try AgentWorkspaceDesktopStore(dataRoot: root, scope: "verified-chat").save(state)
    let restarted = try AgentWorkspaceDesktopStore(dataRoot: root, scope: "verified-chat").load()
    #expect(restarted == state)
    let attributes = try FileManager.default.attributesOfItem(atPath: AgentWorkspaceDesktopStore(dataRoot: root, scope: "verified-chat").fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func workspaceDesktopScopeIsBoundInNameAndPayload() throws {
    let root = try desktopRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let first = AgentWorkspaceDesktopStore(dataRoot: root, scope: "chat/../one")
    let second = AgentWorkspaceDesktopStore(dataRoot: root, scope: "another-chat")
    try first.save(.init(current: .work("First chat work")))
    #expect(first.fileURL != second.fileURL)
    #expect(try second.load() == nil)
    #expect(!first.fileURL.lastPathComponent.contains("chat"))
    try FileManager.default.copyItem(at: first.fileURL, to: second.fileURL)
    #expect(throws: (any Error).self) { try second.load() }
    let before = try Data(contentsOf: second.fileURL)
    #expect(throws: (any Error).self) { try second.save(.init()) }
    #expect(try Data(contentsOf: second.fileURL) == before)
}

@Test func workspaceDesktopSanitizesTransientAndUnsafeReferencesBeforeSave() throws {
    let root = try desktopRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkspaceDesktopStore(dataRoot: root, scope: "chat")
    let file = AgentWorkspaceLocation.record(tool: "read_file", input: ["path": .string("/workspace/note.md"),
        "version": .string(String(repeating: "a", count: 64)), "offset": .int(8192), "__session_id": .string("forged"), "content": .string("private loaded content")], title: "Note")
    let browser = AgentWorkspaceLocation.record(tool: "browser.chrome_snapshot", input: ["lease_id": .string("old-lease"), "snapshot_id": .string("old-snapshot")], title: "Browser")
    let effect = AgentWorkspaceLocation.record(tool: "mail_send", input: ["body": .string("do not replay")], title: "Send mail")
    let relative = AgentWorkspaceLocation.record(tool: "read_file", input: ["path": .string("relative.md")], title: "Relative")
    try store.save(.init(current: .receipt(tool: "mail_send", title: "Sent", value: .string("private receipt")),
        places: [file, browser, effect, relative]))
    let state = try #require(try store.load())
    #expect(state.current == .home)
    #expect(state.places == [.record(tool: "read_file", input: ["path": .string("/workspace/note.md"),
        "version": .string(String(repeating: "a", count: 64)), "offset": .int(8192)], title: "Note"), .area("browser")])
    let bytes = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
    for forbidden in ["private", "old-lease", "forged", "do not replay"] { #expect(!bytes.contains(forbidden)) }
}

@Test func workspaceDesktopBookmarkIsURLOnlyAndNeverALiveLease() throws {
    let bookmark = AgentWorkspaceLocation.browserBookmark(url: "https://example.com/research?q=one", title: "Research")
    #expect(AgentWorkspaceDesktopStore.durable(bookmark) == bookmark)
    #expect(AgentWorkspaceDesktopStore.durable(.browserBookmark(url: "file:///private/data", title: "Unsafe")) == nil)
    #expect(AgentWorkspaceDesktopStore.durable(.browserBookmark(url: "https://user:secret@example.com", title: "Credentials")) == nil)
    #expect(AgentWorkspaceDesktopStore.durable(.record(tool: "read_page", input: ["url": .string("javascript:alert(1)")], title: "Unsafe")) == nil)
}

@Test func workspaceDesktopRestoresVersionedReadingPositionsAndViewPages() throws {
    let root = try desktopRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkspaceDesktopStore(dataRoot: root, scope: "reading")
    let hash = String(repeating: "b", count: 64)
    let memory = AgentWorkspaceLocation.record(tool: "recall_memory", input: ["memory_id": .string("memory-1"),
        "offset": .int(2000), "max_characters": .int(2000), "expected_content_sha256": .string(hash)], title: "Memory evidence")
    let page = AgentWorkspaceLocation.page(.work("project"), 2)
    try store.save(.init(current: memory, places: [memory, page]))
    #expect(try store.load()?.current == memory)
    #expect(try store.load()?.places == [memory, page])
    let unversioned = AgentWorkspaceLocation.record(tool: "recall_memory", input: ["memory_id": .string("memory-1"), "offset": .int(2000)], title: "Memory")
    #expect(AgentWorkspaceDesktopStore.durable(unversioned) == .record(tool: "recall_memory", input: ["memory_id": .string("memory-1")], title: "Memory"))
}

@Test func workspaceSelectedEvidenceRejectsChangesPastSharedExcerpt() throws {
    let prefix = String(repeating: "x", count: 12000)
    let file = AgentWorkspaceLocation.record(tool: "read_file", input: ["path": .string("/workspace/source")], title: "Source")
    let first = try #require(AgentWorkspaceDocument.evidence(location: file, value: .string(prefix + "one")))
    let second = try #require(AgentWorkspaceDocument.evidence(location: file, value: .string(prefix + "two")))
    #expect(first.text == second.text)
    #expect(first.fingerprint != second.fingerprint)
    let memory = AgentWorkspaceLocation.record(tool: "recall_memory", input: ["memory_id": .string("exact")], title: "Memory")
    #expect(AgentWorkspaceDocument.evidence(location: memory, value: .object(["status": .string("ok"), "id": .string("foreign"), "content": .string("text")])) == nil)
    #expect(AgentWorkspaceDocument.evidence(location: memory, value: .object(["status": .string("ok"), "id": .string("exact"), "content": .string("text")])) != nil)
}

@Test func workspaceDesktopCorruptionAndUnsafeStoredLocatorStayUntouched() throws {
    let root = try desktopRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkspaceDesktopStore(dataRoot: root, scope: "chat")
    try store.save(.init(current: .record(tool: "read_file", input: ["path": .string("/workspace/note")], title: "Note")))
    guard case .object(var wire) = try JSONValue.parse(Data(contentsOf: store.fileURL)),
          case .object(var current)? = wire["current"] else { Issue.record("Expected desktop object"); return }
    current["input"] = .object(["path": .string("/workspace/note"), "__session_id": .string("other-chat")])
    wire["current"] = .object(current)
    let unsafe = try JSONValue.object(wire).serializedData(pretty: false)
    for bytes in [unsafe, Data("{broken".utf8), Data(repeating: 0x20, count: 512 * 1024 + 1)] {
        try replaceDesktopBytes(bytes, at: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(.init()) }
        #expect(try Data(contentsOf: store.fileURL) == bytes)
    }
}

@Test func workspaceDesktopRejectsSymlinkAndNonregularStores() throws {
    let root = try desktopRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkspaceDesktopStore(dataRoot: root, scope: "chat")
    try store.save(.init())
    let outside = root.appendingPathComponent("outside")
    try Data("untouched".utf8).write(to: outside)
    try FileManager.default.removeItem(at: store.fileURL)
    try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: (any Error).self) { try store.save(.init()) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "untouched")
    try FileManager.default.removeItem(at: store.fileURL)
    #expect(mkfifo(store.fileURL.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: (any Error).self) { try store.save(.init()) }
}

@Test func workspaceDesktopBoundsPlacesAndRejectsDuplicateArrangementIDs() throws {
    let root = try desktopRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkspaceDesktopStore(dataRoot: root, scope: "chat")
    let saved = AgentWorkspaceSavedDesktop(name: String(repeating: "a", count: 200), workTopic: String(repeating: "b", count: 600))
    try store.save(.init(places: (0..<40).map { .work("Work \($0)") }, saved: [saved]))
    let state = try #require(try store.load())
    #expect(state.places.count == 24)
    #expect(state.places.first == .work("Work 16"))
    #expect(state.saved.first?.name.count == 120)
    #expect(state.saved.first?.workTopic?.count == 400)
    #expect(throws: (any Error).self) { try store.save(.init(saved: [saved, saved])) }
    #expect(throws: (any Error).self) { try store.save(.init(selectedWorkspaceID: UUID().uuidString)) }
    #expect(try store.load() == state)
}
