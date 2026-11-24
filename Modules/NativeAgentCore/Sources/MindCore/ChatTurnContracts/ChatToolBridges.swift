import NativeAgentCore
import PersistenceCore
import Foundation
// Blueprint: | `ChatToolBridges.swift` | `PureToolArgumentValidating`; `argumentRefusal`; Execution-parser preflight without I/O |

/// Use the execution parser without I/O or permission requests so preflight and execution return the same actionable error.
public protocol PureToolArgumentValidating: Sendable {
    func argumentRefusal(tool: String, input: [String: JSONValue], turn: Turn) async -> JSONValue?
}

// MARK: - MacIntegrationToolBridge
// Dispatch checks MacIntegrationPermissionStore before calling the app-injected bridge.
public protocol MacIntegrationToolBridge: Sendable {
    func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue
    func calendarCalendars(input: [String: JSONValue]) async throws -> JSONValue
    func calendarFreeBusy(input: [String: JSONValue]) async throws -> JSONValue
    func remindersQuery(input: [String: JSONValue]) async throws -> JSONValue
    func remindersRead(input: [String: JSONValue]) async throws -> JSONValue
    func remindersLists(input: [String: JSONValue]) async throws -> JSONValue
    func remindersUpdate(input: [String: JSONValue]) async throws -> JSONValue
    func remindersListDueToday(input: [String: JSONValue], dataRoot: URL) async throws -> JSONValue
    func macNotify(input: [String: JSONValue]) async throws -> JSONValue
    func mobileNotify(input: [String: JSONValue], surface: String) async throws -> JSONValue
    func phoneRequest(input: [String: JSONValue]) async throws -> JSONValue
    func spotlightSearch(input: [String: JSONValue]) async throws -> JSONValue

    func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue
    func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue


    // Sensitive writes default off in MacIntegrationPermissionStore.

    func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue
    func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue
    /// Exact occurrence and title/start preconditions prevent deleting a different event.
    func calendarDeleteEvent(input: [String: JSONValue]) async throws -> JSONValue
    func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue
    func remindersListRename(input: [String: JSONValue]) async throws -> JSONValue
    func remindersListCreate(input: [String: JSONValue]) async throws -> JSONValue
    func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue
    func remindersDelete(input: [String: JSONValue]) async throws -> JSONValue

    func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue

    // Scheduled reads have no read axis; listing them requires write permission.
    func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue
    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue
    func schedulerCancelJob(input: [String: JSONValue]) async throws -> JSONValue
}
