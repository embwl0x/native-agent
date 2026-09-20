import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// 2026-07-31 — the lazy-load gate must FAIL CLOSED when the tool catalog
// cannot be enumerated.
//
// Before the fix, SwiftToolDispatcher.dispatch did:
//     if let names = try? await listAvailableTools() { allAvailable = Set(names) }
//     else { allAvailable = [] }
// and enforcement sat inside `if allAvailable.contains(tool)`. An empty
// substitute set therefore meant NOTHING was ever "in the catalog", so the
// not_loaded gate was skipped for every tool — a thrown enumeration opened
// the gate instead of closing it.

private func lgTempRoot(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-lazygate-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct LGCatalogFailure: Error {}

@Test func lazyGate_unloadedShellRemainsRetractedInSameTurn() async throws {
    let root = try lgTempRoot("unload-shell")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
    let session = "unload-shell"
    try await tools.activeToolsStore.addLoaded(sessionId: session, names: ["shell"])
    try await LLMCallContext.$turnActiveTools.withValue(["shell"]) {
        _ = try await tools.dispatch(tool: "tool_unload", input: [
            "session_id": .string(session), "names": .array([.string("shell")])
        ], surface: "chat")
        let result = try await SwiftToolDispatcher.$lazyGateCatalogOverrideForTests.withValue({ ["shell"] }) {
            try await tools.dispatch(tool: "shell", input: [
                "__session_id": .string(session), "command": .string("printf should-not-run")
            ], surface: "chat")
        }
        guard case .object(let object) = result else { Issue.record("Missing blocked result"); return }
        #expect(object["reason"] == .string("not_loaded"))
        #expect(await tools.activeToolsStore.turnUnloadedNames(sessionId: session).contains("shell"))
        #expect(!(await tools.activeToolsStore.load(sessionId: session)).activeTools.contains("shell"))
    }
}

/// A catalogued-but-unloaded name executes on its first call.
@Test func lazyGate_healthyCatalog_loadsAndRuns() async throws {
    let root = try lgTempRoot("healthy")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)

    let out = try await tools.dispatch(
        tool: "market_status",
        input: ["__session_id": .string("lg-healthy-\(UUID().uuidString)")],
        surface: "chat"
    )
    guard case .object(let obj) = out else {
        Issue.record("expected an envelope object, got \(out)")
        return
    }
    #expect(obj["reason"] == nil)
    #expect(obj["runtime"] == .string("swift-native"))
}

/// THE FIX: a thrown enumeration returns a failed `catalog_unavailable`
/// envelope. Under the old code this call fell through the gate entirely and
/// reached the dispatch switch.
@Test func lazyGate_thrownEnumeration_failsClosedWithCatalogUnavailable() async throws {
    let root = try lgTempRoot("throws")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
    let sessionId = "lg-throws-\(UUID().uuidString)"

    let out = try await SwiftToolDispatcher.$lazyGateCatalogOverrideForTests.withValue({
        throw LGCatalogFailure()
    }) {
        try await tools.dispatch(
            tool: "market_status",
            input: ["__session_id": .string(sessionId)],
            surface: "chat"
        )
    }

    guard case .object(let obj) = out else {
        Issue.record("expected a failed envelope object, got \(out)")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(obj["reason"] == .string("catalog_unavailable"))
    #expect(obj["tool"] == .string("market_status"))
    #expect(obj["session_id"] == .string(sessionId))
    #expect(obj["detail"] != nil, "catalog_unavailable must carry the underlying error detail")
}

/// The always-on core never consults the catalog, so a broken enumeration
/// must NOT take the hot core offline. `time_now` is in alwaysOnCoreNames.
@Test func lazyGate_thrownEnumeration_doesNotBreakAlwaysOnCore() async throws {
    let root = try lgTempRoot("alwayson")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)

    let out = try await SwiftToolDispatcher.$lazyGateCatalogOverrideForTests.withValue({
        throw LGCatalogFailure()
    }) {
        try await tools.dispatch(
            tool: "time_now",
            input: ["__session_id": .string("lg-core-\(UUID().uuidString)")],
            surface: "chat"
        )
    }
    guard case .object(let obj) = out else {
        Issue.record("expected time_now envelope, got \(out)")
        return
    }
    #expect(obj["reason"] != .string("catalog_unavailable"))
    #expect(obj["reason"] != .string("not_loaded"))
}

/// A missing or whitespace-only session id must fail before catalog lookup.
/// Otherwise any caller that forgets to propagate the current session receives
/// the full native lazy-tool catalog with no loaded-set discipline.
@Test(arguments: [
    [String: JSONValue](),
    ["__session_id": .string(" \n\t ")],
])
func lazyGate_missingOrEmptySession_failsClosed(input: [String: JSONValue]) async throws {
    let root = try lgTempRoot("nosession")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)

    // The catalog override must not be consulted: the missing-session gate
    // is the first failure and has no enumeration dependency.
    let out = try await SwiftToolDispatcher.$lazyGateCatalogOverrideForTests.withValue({
        throw LGCatalogFailure()
    }) {
        try await tools.dispatch(tool: "market_status", input: input, surface: "chat")
    }
    guard case .object(let obj) = out else {
        Issue.record("missing-session dispatch returned a non-object envelope")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(obj["reason"] == .string("missing_session_id"))
    #expect(obj["tool"] == .string("market_status"))
    #expect(obj["session_id"] == nil)
}
