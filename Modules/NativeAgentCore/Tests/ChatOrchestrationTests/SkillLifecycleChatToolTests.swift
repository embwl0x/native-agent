import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MemoryV2

@Suite("Skill lifecycle chat tools")
struct SkillLifecycleChatToolTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func lifecycleIsCompactAlwaysOnContract() throws {
        // The READ half stays on the always-on floor: she has to be able to see
        // what skills exist and open one without a load dance.
        for name in ["list_skills", "read_skill"] {
            #expect(SwiftToolDispatcher.alwaysOnCoreNames.contains(name))
        }
        // 2026-09-12: save_skill left the floor on 2026-09-11 (Agent's
        // working-set ruling — two real calls in eleven days). It stays in the
        // catalog and is one `tool_load` away, so the lifecycle is still whole.
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("save_skill"))
        for name in ["list_skills", "read_skill", "save_skill"] {
            #expect(SwiftToolDispatcher.builtInToolNames.contains(name))
        }
        // 2026-07-21 audit: a bare SwiftToolDispatcher() resolves shared
        // live-root stores even for a schema-only read — pin it to a temp root.
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let schemas = SwiftToolDispatcher(dataRoot: dataRoot).builtInToolSchemas(includeFullMacFileTools: false)
        let list = schemas.first { $0.name == "list_skills" }
        let read = schemas.first { $0.name == "read_skill" }
        let save = schemas.first { $0.name == "save_skill" }
        #expect(list?.description.contains("manifest") == true)
        #expect(read?.description.contains("Lazy-load") == true)
        #expect(save?.description.contains("reusable skill in Capabilities") == true)
        #expect(save?.description.contains("cannot grant tools") == true)
    }

    @Test func saveThenListAndLazyReadRoundTrip() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try MemoryStorage(
            inMemoryName: "skill-chat-\(UUID().uuidString)"
        )
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: MemoryStorageBridge(storage: storage)
        )
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot, memoryV2: memory)
        let saved = try await dispatcher.dispatch(
            tool: "save_skill",
            input: [
                "name": .string("Concise Handoff"),
                "description": .string("Keep routine handoffs concise and verified."),
                "triggers": .array([.string("handoff"), .string("wrap up")]),
                "content": .string("# Concise Handoff\n\nUse this when closing work: state the outcome, verification, and remaining risk.\n"),
            ],
            surface: "chat"
        )
        guard case .object(let receipt) = saved else {
            Issue.record("save_skill did not return a receipt"); return
        }
        #expect(receipt["status"] == .string("saved"))
        #expect(receipt["body_verified"] == .bool(true))
        #expect(receipt["recall_pointer"] == .string("reconciled"))
        #expect(receipt["authority"] == .string("guidance_only; TrustCenter, approvals, and effect-time validation remain authoritative"))
        let pointers = try await memory.listMemory(kind: "skill")
        #expect(pointers.map(\.id) == ["skill-pointer:concise-handoff"])
        let pointerReceipt = try JSONValue.parse(Data(
            contentsOf: dataRoot.appendingPathComponent("skills/.pointer_sync_receipt.json")
        ))
        guard case .object(let pointerReceiptObject) = pointerReceipt else {
            Issue.record("pointer receipt was not an object")
            return
        }
        #expect(pointerReceiptObject["status"] == .string("ok"))

        let listed = try await dispatcher.dispatch(tool: "list_skills", input: [:], surface: "chat")
        guard case .array(let rows) = listed else {
            Issue.record("list_skills did not return an array"); return
        }
        #expect(rows.contains { row in
            guard case .object(let object) = row else { return false }
            return object["name"] == .string("Concise Handoff")
        })

        let body = try await dispatcher.dispatch(
            tool: "read_skill",
            input: ["name": .string("Concise Handoff")],
            surface: "chat"
        )
        guard case .string(let text) = body else {
            Issue.record("read_skill did not return the body"); return
        }
        #expect(text.contains("state the outcome, verification, and remaining risk"))
    }

    @Test(arguments: ["Research / Notes", "Plan .. Review", ".Morning Plan", "Plan.md"])
    func registeredDisplayPunctuationResolvesOnlyToSafeCanonicalID(name: String) async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 8), storage: InMemoryMemoryStorage()
        )
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot, memoryV2: memory, allowProcessGlobalTools: false)
        let content = "# Procedure\n\nUse when organizing orchard notes. Keep the observation date with each note."
        let saved = try await dispatcher.dispatch(tool: "save_skill", input: [
            "name": .string(name), "description": .string("Organize dated orchard notes."),
            "content": .string(content),
        ], surface: "chat")
        guard case .object(let receipt) = saved, case .object(let skill)? = receipt["skill"],
              case .string(let id)? = skill["id"] else {
            Issue.record("missing saved canonical skill ID"); return
        }
        #expect(!id.contains("/") && !id.contains("..") && !id.hasPrefix("."))
        #expect(receipt["recall_pointer"] == .string("reconciled"))
        let listed = try await dispatcher.dispatch(tool: "list_skills", input: [:], surface: "chat")
        guard case .array(let rows) = listed else { Issue.record("missing skill list"); return }
        #expect(rows.contains { row in
            guard case .object(let object) = row else { return false }
            return object["id"] == .string(id) && object["name"] == .string(name)
        })
        let pointers = try await memory.listMemory(kind: "skill")
        #expect(pointers.contains { $0.id == "skill-pointer:\(id)" && $0.text.contains("read_skill(\"\(id)\")") })
        for handle in [name, id] {
            let body = try await dispatcher.dispatch(tool: "read_skill", input: ["name": .string(handle)], surface: "chat")
            #expect(body == .string(content))
        }
        for invalid in ["../\(id)", "unregistered/path", "unregistered..name", ".unregistered"] {
            await #expect(throws: AutonomyGateError.self) {
                _ = try await dispatcher.dispatch(tool: "read_skill", input: ["name": .string(invalid)], surface: "chat")
            }
        }
    }

    @Test func exactDisplayNameWinsBeforeLegacyMarkdownSuffixLookup() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let dispatcher = SwiftToolDispatcher(
            dataRoot: dataRoot,
            memoryV2: SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(dimensions: 8), storage: InMemoryMemoryStorage()),
            allowProcessGlobalTools: false
        )
        let bodies = [
            "Notes": "# Notes\n\nUse when collecting ordinary orchard observations.",
            "Notes.md": "# Markdown Notes\n\nUse when formatting orchard observations as Markdown.",
        ]
        for name in ["Notes", "Notes.md"] {
            let body = try #require(bodies[name])
            _ = try await dispatcher.dispatch(tool: "save_skill", input: [
                "name": .string(name), "description": .string("Record orchard observations."),
                "content": .string(body),
            ], surface: "chat")
        }
        for (handle, expectedName) in [
            ("Notes", "Notes"), ("Notes.md", "Notes.md"), ("notes-md", "Notes.md"),
            // No exact registered Notes.md.md name: retain suffix compatibility.
            ("Notes.md.md", "Notes.md"),
        ] {
            let result = try await dispatcher.dispatch(tool: "read_skill", input: ["name": .string(handle)], surface: "chat")
            let expectedBody = try #require(bodies[expectedName])
            #expect(result == .string(expectedBody))
        }
    }

    @Test func appOnlyCanonicalPersonaSkillIsListableAndReadable() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let personaRoot = dataRoot.appendingPathComponent("persona", isDirectory: true)
        let bodies = personaRoot.appendingPathComponent("skills/bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        try Data("# Installed identity\n".utf8)
            .write(to: personaRoot.appendingPathComponent("SOUL.md"))
        try Data(
            "# Canonical Curated\n\nUse this when an app-only install needs its curated procedure.\n".utf8
        ).write(to: bodies.appendingPathComponent("canonical-curated.md"))

        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot)
        let listed = try await dispatcher.dispatch(
            tool: "list_skills",
            input: [:],
            surface: "chat"
        )
        guard case .array(let rows) = listed else {
            Issue.record("list_skills did not return an array")
            return
        }
        #expect(rows.contains { row in
            guard case .object(let object) = row else { return false }
            return object["name"] == .string("canonical-curated")
                && object["source"] == .string("persona_body")
        })

        let read = try await dispatcher.dispatch(
            tool: "read_skill",
            input: ["name": .string("canonical-curated")],
            surface: "chat"
        )
        guard case .string(let body) = read else {
            Issue.record("read_skill did not return the canonical persona body")
            return
        }
        #expect(body.contains("app-only install needs its curated procedure"))
    }

    @Test func readOnlyBridgeCannotPersistSkills() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let gated = FileAccessGatedDispatcher(
            inner: SwiftToolDispatcher(dataRoot: dataRoot),
            fileAccess: "read_only"
        )
        await #expect(throws: AutonomyGateError.self) {
            _ = try await gated.dispatch(
                tool: "save_skill",
                input: [
                    "name": .string("Blocked"),
                    "description": .string("Must not persist."),
                    "content": .string("# Blocked\n\nUse this when the test should fail.\n"),
                ],
                surface: "codex-bridge"
            )
        }
    }

    @Test func lazyReadRejectsSymlinkEscapingCanonicalBodyRoot() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-skill-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("# Outside\n\nThis valid-looking body must remain outside the skill root.\n".utf8)
            .write(to: outside)
        let bodies = dataRoot.appendingPathComponent("skills/bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bodies.appendingPathComponent("outside.md"),
            withDestinationURL: outside
        )
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot)
        await #expect(throws: AutonomyGateError.self) {
            _ = try await dispatcher.dispatch(
                tool: "read_skill",
                input: ["name": .string("outside")],
                surface: "chat"
            )
        }
    }
}
