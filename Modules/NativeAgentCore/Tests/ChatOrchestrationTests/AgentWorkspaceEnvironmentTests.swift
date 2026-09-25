import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

private actor EnvironmentOwner {
    struct Call: Sendable { let name: String; let args: [String: JSONValue] }
    var calls: [Call] = []
    var schemas: [LLMToolSchema]
    init(_ schemas: [LLMToolSchema]) { self.schemas = schemas }
    func catalog() -> [LLMToolSchema] { schemas }
    func replace(_ schemas: [LLMToolSchema]) { self.schemas = schemas }
    func perform(_ name: String, _ args: [String: JSONValue]) -> JSONValue {
        calls.append(.init(name: name, args: args))
        if name == "read_file" { return .string("A current file") }
        if name == "list_dir" {
            return .object(["ok": .bool(true), "status": .string("ok"), "path": .string("/workspace/chosen-folder"), "entries": .array([])])
        }
        return .object(["status": .string("ok")])
    }
}

@Suite("Agent workspace environment")
struct AgentWorkspaceEnvironmentTests {
    private static let root = URL(fileURLWithPath: "/tmp/workspace-environment-fixture")
    private static let write = schema("write_file", #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#)
    private static func schema(_ name: String, _ parameters: String = #"{"type":"object","properties":{}}"#) -> LLMToolSchema {
        .init(name: name, description: "Available fixture capability", parametersJSON: Data(parameters.utf8))
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
    private func call(_ input: [String: JSONValue], _ nav: AgentWorkspaceNavigation,
                      _ owner: EnvironmentOwner, scope: String = "fixture") async throws -> JSONValue {
        try await AgentWorkspace.dispatch(input: input, scope: scope, dataRoot: Self.root, navigation: nav,
            catalog: { await owner.catalog() }, perform: { name, args in await owner.perform(name, args) })
    }
    private func writeForm(_ nav: AgentWorkspaceNavigation, _ owner: EnvironmentOwner) async throws -> JSONValue {
        let home = try await call([:], nav, owner)
        let found = try await call(["action": action(home, "Find an action"), "text": .string("write_file")], nav, owner)
        return try await call(["action": action(found, "Open")], nav, owner)
    }
    private var writeFields: JSONValue { .array([
        .object(["field": .string("path"), "value": .string("draft.md")]),
        .object(["field": .string("content"), "value": .string("A current file")])]) }

    @Test func homeDoesNotReadOwnersAndOpeningAreaReadsOnlyItsOwner() async throws {
        let nav = AgentWorkspaceNavigation(), owner = EnvironmentOwner([Self.schema("list_skills")])
        let home = try await call([:], nav, owner)
        #expect(object(home)["total_items"] == .int(16))
        #expect(await owner.calls.isEmpty)
        _ = try await call(["action": action(home, "Open Skills")], nav, owner)
        #expect(await owner.calls.map(\.name) == ["list_skills"])
    }

    @Test func effectIsOnceAndReadbackCarriesTheExactFile() async throws {
        let nav = AgentWorkspaceNavigation(), owner = EnvironmentOwner([Self.write])
        let form = try await writeForm(nav, owner)
        let submit = try action(form, "Submit Write File")
        let result = try await call(["action": submit, "fields": writeFields], nav, owner)
        await #expect(throws: (any Error).self) { try await call(["action": submit, "fields": writeFields], nav, owner) }
        let refreshed = try await call([:], nav, owner)
        #expect(object(object(result)["content"])["content"] == .string("A current file"))
        #expect(object(refreshed)["content"] == .string("A current file"))
        #expect(await owner.calls.map(\.name) == ["write_file", "read_file", "read_file"])
        let opened = refreshed
        #expect(await owner.calls.last?.args["path"] == .string("draft.md"))
        let revise = try await call(["action": action(opened, "Revise this file")], nav, owner)
        #expect(object(object(revise)["content"])["selected_target"] == .object(["path": .string("draft.md")]))
        #expect(await owner.calls.map(\.name) == ["write_file", "read_file", "read_file"])
    }

    @Test func changedSchemaAndOtherSessionCannotSubmitForm() async throws {
        let nav = AgentWorkspaceNavigation(), owner = EnvironmentOwner([Self.write])
        let form = try await writeForm(nav, owner)
        let submit = try action(form, "Submit Write File")
        await #expect(throws: (any Error).self) {
            try await call(["action": submit, "fields": writeFields], nav, owner, scope: "different-chat")
        }
        await owner.replace([Self.schema("write_file")])
        let changed = try await call(["action": submit, "fields": writeFields], nav, owner)
        #expect(object(object(changed)["content"])["notice"] != nil)
        #expect(await owner.calls.isEmpty)
    }

    @Test func creationBindsDisplayedFolderBeforeContentAndOpenPlacesReadsAgain() async throws {
        let nav = AgentWorkspaceNavigation(), owner = EnvironmentOwner([Self.write, Self.schema("list_dir")])
        let home = try await call([:], nav, owner)
        let files = try await call(["action": action(home, "Open Files")], nav, owner)
        let form = try await call(["action": action(files, "Create a file named…"), "text": .string("draft.md")], nav, owner)
        #expect(object(object(form)["content"])["selected_target"] == .object(["path": .string("/workspace/chosen-folder/draft.md")]))
        let saved = try await call(["action": action(form, "Submit Create draft.md"), "text": .string("A current file")], nav, owner)
        #expect(await owner.calls.last?.args["path"] == .string("/workspace/chosen-folder/draft.md"))
        let opened = saved
        let places = try await call(["action": action(opened, "Open places")], nav, owner)
        // Only the file she wrote is a window; opening Files to look left none.
        #expect(object(places)["total_items"] == .int(1))
        guard case .array(let items)? = object(places)["items"] else { Issue.record("Missing places"); return }
        #expect(!items.contains { object($0)["title"] == .string("Files") })
        _ = try await call(["action": action(places, "Reopen")], nav, owner)
        #expect(await owner.calls.map(\.name) == ["list_dir", "write_file", "read_file", "read_file"])
        #expect(await owner.calls.last?.args["path"] == .string("/workspace/chosen-folder/draft.md"))
    }

    @Test func filenameCannotEscapeSelectedFolder() async throws {
        for filename in ["../escape.md", "/other/file.md", ".", "..", "nul\0.md"] {
            let nav = AgentWorkspaceNavigation(), owner = EnvironmentOwner([Self.write, Self.schema("list_dir")])
            let home = try await call([:], nav, owner)
            let files = try await call(["action": action(home, "Open Files")], nav, owner)
            await #expect(throws: (any Error).self) {
                try await call(["action": action(files, "Create a file named…"), "text": .string(filename)], nav, owner)
            }
            #expect(await owner.calls.map(\.name) == ["list_dir"])
        }
    }

    @Test func openPlacesAreBoundedScopedAndNeverContainEffects() async throws {
        let nav = AgentWorkspaceNavigation(), key = "places-test"
        let operation = try await nav.begin(key: key)
        for index in 0..<28 {
            try await nav.navigate(.browserBookmark(url: "https://example.com/\(index)", title: "File \(index)"), key: key)
        }
        try await nav.navigate(.receipt(tool: "write_file", title: "Saved", value: .object(["status": .string("saved")])), key: key)
        let places = await nav.openPlaces(key: key)
        #expect(places.items.count == 24)
        #expect(places.items.first?.title == "File 27")
        #expect(await nav.openPlaces(key: "other-chat").items.isEmpty)
        await nav.end(key: key, operation: operation)
    }

    @Test func catalogPaginationKeepsAllActions() async throws {
        let nav = AgentWorkspaceNavigation()
        let owner = EnvironmentOwner((0..<35).map { Self.schema(String(format: "fixture_%02d", $0)) })
        let home = try await call([:], nav, owner)
        var page = try await call(["action": action(home, "Find an action"), "text": .string("fixture")], nav, owner)
        var titles: [JSONValue] = []
        for index in 0..<5 {
            guard case .array(let items)? = object(page)["items"] else { Issue.record("Missing items"); return }
            titles += items.compactMap { object($0)["title"] }
            #expect(object(page)["total_items"] == .int(35))
            if index < 4 { page = try await call(["action": action(page, "More items")], nav, owner) }
        }
        #expect(titles.count == 35)
        #expect(Set(titles.compactMap { if case .string(let text) = $0 { return text }; return nil }).count == 35)
        #expect(await owner.calls.isEmpty)
    }

    @Test func originalWorkSurvivesLongNavigation() async throws {
        let nav = AgentWorkspaceNavigation(), key = "anchor-test"
        let operation = try await nav.begin(key: key)
        let anchor = AgentWorkspaceLocation.record(tool: "desk_read", input: ["handle": .string("exact-work")], title: "Original work")
        try await nav.navigate(.work("original topic"), key: key)
        try await nav.navigate(anchor, key: key)
        for id in AgentWorkspaceEnvironment.destinations.map(\.id) { try await nav.navigate(.area(id), key: key) }
        #expect(await nav.returnToWork(key: key) == anchor)
        await nav.end(key: key, operation: operation)
    }

    @Test func webSearchIsPrivateSearchNotAChromeTab() async throws {
        let nav = AgentWorkspaceNavigation(), owner = EnvironmentOwner([Self.schema(AgentWorkspaceKnowledge.webSearchTool), Self.schema("browser.chrome_acquire")])
        let home = try await call([:], nav, owner)
        let research = try await call(["action": action(home, "Open Research")], nav, owner)
        let query = "a & b # unicode café"
        _ = try await call(["action": action(research, "Search the web"), "text": .string(query)], nav, owner)
        let calls = await owner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == AgentWorkspaceKnowledge.webSearchTool)
        #expect(calls.first?.args["query"] == .string(query))
        #expect(!calls.contains { $0.name == "browser.chrome_acquire" })
    }

    @Test func unfinishedDraftSurvivesDetourAndValidationButCannotReplayAfterSubmit() async throws {
        let nav = AgentWorkspaceNavigation(), owner = EnvironmentOwner([Self.write])
        let form = try await writeForm(nav, owner)
        let partial = try await call(["action": action(form, "Keep entered fields"), "fields": .array([
            .object(["field": .string("path"), "value": .string("draft.md")])])], nav, owner)
        let incomplete = try await call(["action": action(partial, "Submit Write File")], nav, owner)
        #expect(object(object(incomplete)["content"])["notice"] != nil)
        let home = try await call(["action": action(incomplete, "Workspace home")], nav, owner)
        let places = try await call(["action": action(home, "Open places")], nav, owner)
        let resumed = try await call(["action": action(places, "Reopen")], nav, owner)
        #expect(await owner.calls.isEmpty)
        let saved = try await call(["action": action(resumed, "Submit Write File"), "fields": .array([
            .object(["field": .string("content"), "value": .string("A current file")])])], nav, owner)
        let after = try await call(["action": action(saved, "Open places")], nav, owner)
        #expect(await owner.calls.filter { $0.name == "write_file" }.count == 1)
        #expect(!(try after.serialize(pretty: false)).contains("Unfinished draft"))
        let key = Self.root.path + "\u{0}fixture"
        let path = await nav.sessions[key]?.path ?? []
        #expect(!path.contains { if case .form = $0 { return true }; return false })
    }
}
