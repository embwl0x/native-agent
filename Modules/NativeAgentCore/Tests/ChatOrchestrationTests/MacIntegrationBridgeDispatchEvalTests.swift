import Foundation
import Testing
@testable import ChatOrchestration
import MacIntegration
import NativeAgentCore
import PersistenceCore

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger row: chat.tools.macIntegrationBridge
//
// This drives the real SwiftToolDispatcher switch and its injected
// MacIntegrationToolBridge. It proves the complete routing contract instead of
// merely observing that a bridge property is non-nil:
//   - permitted calls reach the selected bridge method,
//   - denied calls cannot reach that bridge,
//   - an allowed call without assembly returns bridge_not_wired, and
//   - a backend failure remains visible to the caller.
//
// The injected permission store is deliberately rooted in the fixture. The
// dispatcher must not let a non-live assembly consult the user's live Mac
// Integration authority store.
// ─────────────────────────────────────────────────────────────────────────────

private enum MacIntegrationBridgeProbeError: Error {
    case adverseBackendFailure
}

private actor MacIntegrationBridgeProbe: MacIntegrationToolBridge {
    private let fails: Bool
    private var calendarInputs = [[String: JSONValue]]()

    init(fails: Bool = false) {
        self.fails = fails
    }

    func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        calendarInputs.append(input)
        if fails { throw MacIntegrationBridgeProbeError.adverseBackendFailure }
        return .object([
            "status": .string("completed"),
            "route": .string("calendarListUpcoming"),
        ])
    }

    func calendarCallCount() -> Int { calendarInputs.count }

    // The probe only makes the route under test observable. Any other bridge
    // method fails so a future eval cannot silently reuse the wrong route.
    private func unsupportedMacIntegrationProbeRoute() throws -> JSONValue {
        throw MacIntegrationBridgeProbeError.adverseBackendFailure
    }

    func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func macNotify(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func mobileNotify(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func spotlightSearch(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func mailSearch(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func mailSend(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func messagesSend(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func notesSearch(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func notesCreate(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func musicControl(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func mailArchive(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func mailDelete(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func mailReply(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func notesUpdate(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue { try unsupportedMacIntegrationProbeRoute() }
}

private func macIntegrationBridgeEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-integration-bridge-eval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func macIntegrationBridgeEvalPermissions(
    root: URL,
    calendarRead: Bool
) async throws -> MacIntegrationPermissionStore {
    let store = MacIntegrationPermissionStore(dataRoot: root)
    try await store.set(
        integrationId: MacIntegrationID.calendar,
        read: calendarRead,
        write: false
    )
    return store
}

private func macIntegrationEvalString(_ value: JSONValue, key: String) -> String? {
    guard case .object(let object) = value,
          case .string(let string)? = object[key] else {
        return nil
    }
    return string
}

@Test func macIntegrationBridgeDispatch_routesAllowedCallsAndContainsBackendFailure() async throws {
    let root = try macIntegrationBridgeEvalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let permissions = try await macIntegrationBridgeEvalPermissions(root: root, calendarRead: true)
    let bridge = MacIntegrationBridgeProbe()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root,
        allowProcessGlobalTools: false,
        macIntegrationBridge: bridge,
        macIntegrationPermissionStore: permissions
    )

    let result = try await dispatcher.dispatch(
        tool: "mac_calendar_list_upcoming",
        input: ["day": .string("today")],
        surface: "chat"
    )
    #expect(macIntegrationEvalString(result, key: "status") == "completed")
    #expect(macIntegrationEvalString(result, key: "route") == "calendarListUpcoming")
    #expect(await bridge.calendarCallCount() == 1)

    let failingBridge = MacIntegrationBridgeProbe(fails: true)
    let failingDispatcher = SwiftToolDispatcher(
        dataRoot: root,
        allowProcessGlobalTools: false,
        macIntegrationBridge: failingBridge,
        macIntegrationPermissionStore: permissions
    )
    await #expect(throws: MacIntegrationBridgeProbeError.self) {
        _ = try await failingDispatcher.dispatch(
            tool: "mac_calendar_list_upcoming",
            input: [:],
            surface: "chat"
        )
    }
    #expect(await failingBridge.calendarCallCount() == 1)
}

@Test func macIntegrationBridgeDispatch_deniesBeforeBridgeAndReportsUnwiredAssembly() async throws {
    let root = try macIntegrationBridgeEvalRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let allowedPermissions = try await macIntegrationBridgeEvalPermissions(root: root, calendarRead: true)
    let unwired = SwiftToolDispatcher(
        dataRoot: root,
        allowProcessGlobalTools: false,
        macIntegrationPermissionStore: allowedPermissions
    )
    let unavailable = try await unwired.dispatch(
        tool: "mac_calendar_list_upcoming",
        input: [:],
        surface: "chat"
    )
    #expect(macIntegrationEvalString(unavailable, key: "status") == "failed")
    #expect(macIntegrationEvalString(unavailable, key: "reason") == "bridge_not_wired")

    let deniedPermissions = try await macIntegrationBridgeEvalPermissions(root: root, calendarRead: false)
    let bridge = MacIntegrationBridgeProbe()
    let deniedDispatcher = SwiftToolDispatcher(
        dataRoot: root,
        allowProcessGlobalTools: false,
        macIntegrationBridge: bridge,
        macIntegrationPermissionStore: deniedPermissions
    )
    let denied = try await deniedDispatcher.dispatch(
        tool: "mac_calendar_list_upcoming",
        input: [:],
        surface: "chat"
    )
    #expect(macIntegrationEvalString(denied, key: "status") == "denied")
    #expect(macIntegrationEvalString(denied, key: "reason") == "integration_permission_denied")
    #expect(await bridge.calendarCallCount() == 0)
}
