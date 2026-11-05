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

    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue
    func mailAttachment(input: [String: JSONValue]) async throws -> (filename: String, data: Data)
    func mailReadBatch(input: [String: JSONValue]) async throws -> JSONValue
    func mailTriageBatch(input: [String: JSONValue]) async throws -> JSONValue
    func mailSearch(input: [String: JSONValue]) async throws -> JSONValue
    func mailSenders(input: [String: JSONValue]) async throws -> JSONValue
    func mailSend(input: [String: JSONValue]) async throws -> JSONValue

    func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue
    func messagesSend(input: [String: JSONValue]) async throws -> JSONValue

    func notesSearch(input: [String: JSONValue]) async throws -> JSONValue
    func notesCreate(input: [String: JSONValue]) async throws -> JSONValue

    func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue
    func musicControl(input: [String: JSONValue]) async throws -> JSONValue

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

    func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue
    func mailArchive(input: [String: JSONValue]) async throws -> JSONValue
    func mailDelete(input: [String: JSONValue]) async throws -> JSONValue
    func mailReply(input: [String: JSONValue]) async throws -> JSONValue
    func mailDraft(input: [String: JSONValue]) async throws -> JSONValue

    func notesModify(input: [String: JSONValue], deleting: Bool) async throws -> JSONValue

    func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue
    func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue
    func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue

    func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue

    // Scheduler access has no read axis; listing jobs requires write permission.
    func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue
    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue
    func schedulerCancelJob(input: [String: JSONValue]) async throws -> JSONValue
    func schedulerSetJobEnabled(input: [String: JSONValue], enabled: Bool) async throws -> JSONValue
    func schedulerUpdateJob(input: [String: JSONValue]) async throws -> JSONValue
}
