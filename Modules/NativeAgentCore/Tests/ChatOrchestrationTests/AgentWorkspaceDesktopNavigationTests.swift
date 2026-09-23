import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

private actor DesktopReader {
    var calls: [String] = []
    var inputs: [[String: JSONValue]] = []
    var missing = false
    func markMissing() { missing = true }
    func read(_ tool: String, _ input: [String: JSONValue]) throws -> JSONValue {
        calls.append(tool)
        inputs.append(input)
        if missing { throw CocoaError(.fileNoSuchFile) }
        return tool == "read_file" ? .string("Fresh current content") : .object(["status": .string("ok")])
    }
}

@Suite("Persistent workspace navigation")
struct AgentWorkspaceDesktopNavigationTests {
    @Test func independentBrowserPlacesRememberWithoutOverlappingActorStateAccess() async throws {
        let nav = AgentWorkspaceNavigation(), key = "browser-places"
        let operation = try await nav.begin(key: key)
        for index in 1...3 {
            let page = AgentWorkspaceLocation.record(tool: "browser.chrome_snapshot",
                input: ["lease_id": .string("lease-\(index)")], title: "Page \(index)")
            try await nav.navigate(page, key: key)
            await nav.rememberDocument(location: page, result: .object([
                "url": .string("https://example.com/\(index)"), "title": .string("Page \(index)")]), key: key)
        }
        let session = try #require(await nav.sessions[key])
        #expect(session.browserBookmarks.count == 3)
        #expect(session.places.count == 3)
        #expect(session.browserBookmarks["browser.chrome_snapshot:lease-1"] == .browserBookmark(url: "https://example.com/1", title: "Page 1"))
        await nav.end(key: key, operation: operation)
    }

    private let scope = "verified-fixture-chat"
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let row)? = value { return row }; return [:]
    }
    private func action(_ view: JSONValue, _ label: String) throws -> JSONValue {
        let row = object(view)
        var buttons: [JSONValue] = []
        if case .array(let values)? = row["actions"] { buttons += values }
        if case .array(let items)? = row["items"] {
            for item in items { if case .array(let values)? = object(item)["actions"] { buttons += values } }
        }
        return try #require(object(buttons.first { object($0)["label"] == .string(label) })["action"])
    }
    private func file(_ root: URL) -> AgentWorkspaceLocation {
        .record(tool: "read_file", input: ["path": .string(root.appendingPathComponent("document.md").path)], title: "Selected document")
    }
    private func seed(_ root: URL, count: Int = 1) throws {
        let places = (0..<count).map { index in
            AgentWorkspaceLocation.record(tool: "read_file", input: ["path": .string(root.appendingPathComponent("\(index).md").path)], title: "Document \(index)")
        }
        try AgentWorkspaceDesktopStore(dataRoot: root, scope: scope).save(.init(current: file(root), places: places,
            workAnchor: .work("Original work"), workTopic: "Original work"))
    }
    private func call(_ input: [String: JSONValue], root: URL, nav: AgentWorkspaceNavigation,
                      reader: DesktopReader) async throws -> JSONValue {
        try await AgentWorkspace.dispatch(input: input, scope: scope, dataRoot: root, navigation: nav,
            perform: { tool, args in try await reader.read(tool, args) })
    }

    @Test func namedArrangementRestoresSelectionAndFreshEvidenceWithoutOldActions() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let reader = DesktopReader(), first = AgentWorkspaceNavigation(persistenceEnabled: true)
        let opened = try await call([:], root: root, nav: first, reader: reader)
        let oldAction = try action(opened, "Add to this file")
        let saved = try await call(["action": action(opened, "Keep this workspace as…"), "text": .string("Desktop research")], root: root, nav: first, reader: reader)
        #expect(object(object(saved)["desktop"])["name"] == .string("Desktop research"))
        let restarted = AgentWorkspaceNavigation(persistenceEnabled: true)
        let restored = try await call([:], root: root, nav: restarted, reader: reader)
        #expect(object(restored)["workspace"] == .string("Selected document"))
        #expect(object(restored)["content"] == .string("Fresh current content"))
        #expect(object(object(restored)["desktop"])["name"] == .string("Desktop research"))
        await #expect(throws: (any Error).self) {
            try await call(["action": oldAction, "text": .string("Do not replay")], root: root, nav: restarted, reader: reader)
        }
        #expect(await reader.calls == ["read_file", "read_file"])
    }

    @Test func namedSwitchingAndForgetOnlyChangeArrangement() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let reader = DesktopReader(), nav = AgentWorkspaceNavigation(persistenceEnabled: true)
        let opened = try await call([:], root: root, nav: nav, reader: reader)
        var saved = try await call(["action": action(opened, "Keep this workspace as…"), "text": .string("First")], root: root, nav: nav, reader: reader)
        let new = try await call(["action": action(saved, "Start a workspace named…"), "text": .string("Second")], root: root, nav: nav, reader: reader)
        #expect(object(object(new)["desktop"])["name"] == .string("Second"))
        saved = try await call(["action": action(new, "Saved workspaces")], root: root, nav: nav, reader: reader)
        let reopened = try await call(["action": action(saved, "Reopen workspace")], root: root, nav: nav, reader: reader)
        #expect(object(reopened)["workspace"] == .string("Selected document"))
        saved = try await call(["action": action(reopened, "Saved workspaces")], root: root, nav: nav, reader: reader)
        _ = try await call(["action": action(saved, "Forget saved arrangement")], root: root, nav: nav, reader: reader)
        let disk = try #require(try AgentWorkspaceDesktopStore(dataRoot: root, scope: scope).load())
        #expect(disk.saved.map(\.name) == ["Second"])
        #expect(await reader.calls == ["read_file", "read_file"])
    }

    @Test func missingReferenceStillShowsNavigationAndRemainsSaved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let reader = DesktopReader(); await reader.markMissing()
        let nav = AgentWorkspaceNavigation(persistenceEnabled: true)
        let view = try await call([:], root: root, nav: nav, reader: reader)
        #expect(object(view)["status"] == .string("unavailable"))
        _ = try action(view, "Saved workspaces")
        let disk = try #require(try AgentWorkspaceDesktopStore(dataRoot: root, scope: scope).load())
        #expect(disk.current == file(root))
    }

    @Test func olderGenericFileLabelsRenderRecognizableNamesOnRestore() throws {
        let location = AgentWorkspaceLocation.record(tool: "read_file", input: ["path": .string("/workspace/field-notes.md")], title: "Open file")
        #expect(location.title == "File: field-notes.md")
        #expect(AgentWorkspaceProjection.project(location: location, result: .string("Fresh evidence")).title == "File: field-notes.md")
        let folder = AgentWorkspaceLocation.record(tool: "list_dir", input: ["path": .string("/workspace/research")], title: "Open folder")
        #expect(folder.title == "Folder: research")
    }

    @Test func readingSavedWebsiteKeepsOnePlaceAcrossRestart() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://example.com/source"
        let bookmark = AgentWorkspaceLocation.browserBookmark(url: url, title: "Source")
        let source = AgentWorkspaceLocation.record(tool: "read_page", input: ["url": .string(url)], title: "Source")
        let store = AgentWorkspaceDesktopStore(dataRoot: root, scope: scope)
        // Include the duplicate produced by the previous runtime.
        try store.save(.init(current: bookmark, places: [bookmark, source]))
        let reader = DesktopReader(), nav = AgentWorkspaceNavigation(persistenceEnabled: true)
        let view = try await call([:], root: root, nav: nav, reader: reader)
        let read = try await call(["action": action(view, "Read current source")], root: root, nav: nav, reader: reader)
        #expect(object(object(read)["desktop"])["open_places"] == .array([.string("Source")]))
        let disk = try #require(try store.load())
        #expect(disk.places == [source])
        let restarted = AgentWorkspaceNavigation(persistenceEnabled: true)
        _ = try await call([:], root: root, nav: restarted, reader: reader)
        #expect(await reader.calls == ["read_page", "read_page"])
        #expect(try store.load()?.places == [source])
    }

    @Test func directAppendCarriesTargetAndPreservesTextWhitespace() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let reader = DesktopReader(), nav = AgentWorkspaceNavigation(persistenceEnabled: true)
        let view = try await call([:], root: root, nav: nav, reader: reader)
        let content = "\n  An indented addition.\n"
        _ = try await call(["action": action(view, "Add to this file"), "text": .string(content)], root: root, nav: nav, reader: reader)
        #expect(await reader.inputs[1] == ["path": .string(root.appendingPathComponent("document.md").path), "append": .bool(true), "content": .string(content)])
        #expect(await reader.calls == ["read_file", "write_file", "read_file"])
    }

    @Test func corruptStorageDoesNotHideSuccessfulOwnerReadOrOverwriteEvidence() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let store = AgentWorkspaceDesktopStore(dataRoot: root, scope: scope)
        let corrupt = Data("damaged saved arrangement".utf8)
        try corrupt.write(to: store.fileURL)
        let reader = DesktopReader(), nav = AgentWorkspaceNavigation(persistenceEnabled: true)
        let view = try await call(["query": .string("Original work")], root: root, nav: nav, reader: reader)
        #expect(object(view)["status"] == .string("ok"))
        #expect(object(object(view)["desktop"])["storage"] == .string("unavailable"))
        #expect(try Data(contentsOf: store.fileURL) == corrupt)
        #expect(await reader.calls == ["work_context"])
    }

    @Test func restorationReentersCurrentInnerGate() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let inner = MockToolDispatchClient(scripted: [
            "workspace": .object(["status": .string("prepared"), "execution": .string("requires_workspace_runtime")]),
            "read_file": .object(["status": .string("blocked"), "detail": .string("Current gate denied access")])])
        let client = CanonicalToolNameDispatcher(inner: inner, peerDataRoot: root, conversationScope: scope)
        let result = try await client.dispatch(tool: "workspace", input: [:], surface: "chat")
        #expect(object(result)["status"] == .string("blocked"))
        #expect(inner.dispatches.map(\.tool) == ["workspace", "read_file"])
        #expect(inner.dispatches.last?.input["__session_id"] == .string(scope))
    }

    @Test func restoredOpenPlacesBeyondFirstPageRemainSelectable() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root, count: 20)
        let reader = DesktopReader(), nav = AgentWorkspaceNavigation(persistenceEnabled: true)
        let opened = try await call([:], root: root, nav: nav, reader: reader)
        let places = try await call(["action": action(opened, "Open places")], root: root, nav: nav, reader: reader)
        let more = try await call(["action": action(places, "More items")], root: root, nav: nav, reader: reader)
        #expect(object(more)["page"] == .int(1))
        _ = try action(more, "Reopen")
        #expect(await reader.calls == ["read_file"])
    }
}
