import Foundation
import Testing
@testable import ChatOrchestration
import CognitiveSubstrate
import NativeAgentCore
@testable import PersistenceCore

// THE HELD TIER'S DOOR (item 7, 2026-09-02).
//
// `hold_view` is the one tool in this app that lets the agent make something
// durable about herself WITHOUT the owner signing it. That is the whole point
// of the tier — and it is also exactly why the seat has to be a fact rather
// than a claim. These tests pin the two ways it must fail closed:
//
//   1. THE SEAT. Every caller that is not her, inside her own live local turn,
//      is refused — the Claude bridge's tool runner, a bridge-steered chat
//      turn, a remote surface, an executor, a replay. The gate is imported from
//      the canon lane rather than reimplemented, so this suite is also the
//      regression that the import stayed an import.
//   2. THE MIND. A dispatcher with no live cognition runtime says so out loud
//      instead of pretending a view was held.
//
// Every refusal must be SPOKEN, because the model is the caller: a bare code
// teaches it nothing about why the door did not open, and it will simply try
// again.
@Suite("Standing view tools")
struct StandingViewToolsTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StandingViewTools-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// HER live turn: exactly what the chat tool loop binds around a dispatch,
    /// and nothing a caller could supply through tool input.
    private func inHerLiveTurn<T>(
        surface: String = "chat",
        turnID: String = "run_live_1",
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await ChatTurnRuntimeContext.$current.withValue(
            .init(model: "test-model", surface: surface, personaID: "agent", providerID: "test")
        ) {
            try await ChatToolSessionContext.$verifiedSessionId.withValue(turnID) {
                try await body()
            }
        }
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let obj) = value else {
            Issue.record("not an object: \(value)")
            throw CancellationError()
        }
        return obj
    }

    private func viewID() -> String { UUID().uuidString }

    // MARK: - the seat

    /// The bridge tool runner binds no turn context at all. It must not be able
    /// to hold a view in her name, and it must be told why.
    @Test("the bridge tool runner cannot hold a view")
    func bridgeToolRunIsRefused() async throws {
        let root = hermeticRoot()
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = await dispatcher.impl_hold_view(
            input: ["view_id": .string(viewID())],
            surface: "claude-bridge")
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["reason"] == .string(StudioCanonSeatGate.Refusal.notALiveTurn.rawValue))
        // Spoken, not just coded.
        if case .string(let spoken)? = obj["spoken"] {
            #expect(spoken.contains("hold_view"))
            #expect(spoken.count > 40, "a refusal the model can act on, not a code: \(spoken)")
        } else {
            Issue.record("refusal carried no spoken line")
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// The bridge's MESSAGE lane runs a real tool loop on `surface: "chat"`, so
    /// the surface string alone would let it through. Same discriminators the
    /// canon seat uses.
    @Test("a bridge-steered chat turn cannot hold a view")
    func bridgeMessageLaneIsRefused() async throws {
        let root = hermeticRoot()
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = await inHerLiveTurn {
            await ChatPersistenceContext.$originProvenance.withValue(
                ChatMessageOrigin(surface: "claude-bridge", agent: "claude")
            ) {
                await dispatcher.impl_hold_view(
                    input: ["view_id": .string(viewID())],
                    surface: "chat")
            }
        }
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["reason"] == .string(StudioCanonSeatGate.Refusal.bridgeLane.rawValue))
        try? FileManager.default.removeItem(at: root)
    }

    /// A conviction is not adopted from a phone.
    @Test("a remote surface cannot hold a view")
    func remoteSurfaceIsRefused() async throws {
        let root = hermeticRoot()
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = await inHerLiveTurn(surface: "telegram") {
            await dispatcher.impl_hold_view(
                input: ["view_id": .string(viewID())],
                surface: "telegram")
        }
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["reason"] == .string(StudioCanonSeatGate.Refusal.remoteSurface.rawValue))
        try? FileManager.default.removeItem(at: root)
    }

    /// `release_view` is seated identically — a lane that cannot hold a view
    /// cannot let one go either.
    @Test("release_view is seated exactly like hold_view")
    func releaseIsSeatedToo() async throws {
        let root = hermeticRoot()
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = await dispatcher.impl_release_view(
            input: ["view_id": .string(viewID())],
            surface: "claude-bridge")
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["reason"] == .string(StudioCanonSeatGate.Refusal.notALiveTurn.rawValue))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - the mind

    /// PAST the seat, with no live cognition runtime wired: say so, do not
    /// pretend. A hermetic dispatcher has no `providerLifecycleObserver`.
    @Test("no live mind is reported, never faked")
    func noLiveMindIsReported() async throws {
        let root = hermeticRoot()
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = await inHerLiveTurn {
            await dispatcher.impl_hold_view(
                input: ["view_id": .string(viewID())],
                surface: "chat")
        }
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["reason"] == .string("no_live_mind"))
        try? FileManager.default.removeItem(at: root)
    }

    /// A malformed id is a refusal, not a guess at which view she meant.
    @Test("a malformed view id is refused, not guessed")
    func malformedIDIsRefused() async throws {
        let root = hermeticRoot()
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        for bad in ["", "   ", "the phrasing one", "1234"] {
            let result = await inHerLiveTurn {
                await dispatcher.impl_hold_view(
                    input: ["view_id": .string(bad)],
                    surface: "chat")
            }
            let obj = try object(result)
            #expect(obj["status"] == .string("refused"))
            // Either the id never parsed, or we got as far as needing a mind —
            // both are refusals, and neither writes anything.
            #expect(obj["reason"] != .string("ok"))
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - the catalog wiring

    /// LAZY, and discoverable. Adopting a view is deliberate and rare, so it
    /// must not cost prompt bytes on every turn — but it has to be reachable
    /// through `tool_load`, or it may as well not exist.
    @Test("both verbs are catalog-visible and lazily loaded")
    func catalogWiringIsLazyAndDiscoverable() {
        for name in ["hold_view", "release_view"] {
            // `builtInToolNames` IS the catalog list; "lazily loaded" is
            // membership in it WITHOUT membership in `alwaysOnCoreNames`
            // (asserted directly below). There is no separate lazy list.
            #expect(SwiftToolDispatcher.builtInToolNames.contains(name),
                    "\(name) must be discoverable through the catalog")
            #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains(name),
                    "\(name) must not ride every turn's prompt")
        }
    }

    /// CLOSED SCHEMA. There is deliberately no `body` field: a view is FORMED
    /// by reflection and only HELD here, so this can never become a second door
    /// for minting a conviction out of a sentence typed mid-turn.
    @Test("hold_view cannot mint a view out of free text")
    func schemaIsClosedAndHasNoBodyField() throws {
        // The advertised schemas come off an INSTANCE, pointed at this test's
        // own data root; `requestedNames` is the filter. `parametersJSON` is
        // already-encoded `Data`, so decode before matching on it.
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let schemas = SwiftToolDispatcher(dataRoot: root)
            .builtInToolSchemas(requestedNames: ["hold_view", "release_view"])
        func parameters(_ schema: LLMToolSchema) -> String {
            String(decoding: schema.parametersJSON, as: UTF8.self)
        }
        let hold = try #require(schemas.first { $0.name == "hold_view" })
        #expect(parameters(hold).contains("view_id"))
        #expect(!parameters(hold).contains("\"body\""),
                "a body field would make this a second view-minting door")
        #expect(parameters(hold).contains("note"))
        let release = try #require(schemas.first { $0.name == "release_view" })
        #expect(parameters(release).contains("view_id"))
        #expect(!parameters(release).contains("\"body\""))
    }
}
