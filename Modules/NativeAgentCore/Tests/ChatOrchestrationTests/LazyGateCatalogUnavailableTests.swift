import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore

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

/// CONTROL: with a healthy catalog the gate still returns not_loaded for a
/// catalogued-but-unloaded tool. Pins that the fix did not change the
/// happy path.
@Test func lazyGate_healthyCatalog_stillReturnsNotLoaded() async throws {
    let root = try lgTempRoot("healthy")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let out = try await tools.dispatch(
        tool: "market_status",
        input: ["__session_id": .string("lg-healthy-\(UUID().uuidString)")],
        surface: "chat"
    )
    guard case .object(let obj) = out else {
        Issue.record("expected an envelope object, got \(out)")
        return
    }
    #expect(obj["reason"] == .string("not_loaded"))
}

/// THE FIX: a thrown enumeration returns a failed `catalog_unavailable`
/// envelope. Under the old code this call fell through the gate entirely and
/// reached the dispatch switch.
@Test func lazyGate_thrownEnumeration_failsClosedWithCatalogUnavailable() async throws {
    let root = try lgTempRoot("throws")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
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
    let tools = SwiftToolDispatcher(dataRoot: root)

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

/// No session_id ⇒ non-chat surface ⇒ the gate is skipped entirely, so a
/// broken enumeration must not manufacture a catalog_unavailable there.
@Test func lazyGate_noSession_unaffectedByCatalogFailure() async throws {
    let root = try lgTempRoot("nosession")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    // No try? — a thrown dispatch on the no-session path must FAIL the test,
    // not silently pass it (gpt-5.5 wave review, 2026-07-31).
    let out = try await SwiftToolDispatcher.$lazyGateCatalogOverrideForTests.withValue({
        throw LGCatalogFailure()
    }) {
        try await tools.dispatch(tool: "market_status", input: [:], surface: "chat")
    }
    guard case .object(let obj) = out else {
        Issue.record("no-session dispatch returned a non-object envelope")
        return
    }
    #expect(obj["reason"] != .string("catalog_unavailable"))
}
