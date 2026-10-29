import Foundation
import ChatTurnContracts
import Connectors
import MacControl
import MacIntegration
import TriggerScheduler
import TrustCenter
import SchedulerExecution
import AttentionRouting
import DeviceSync
import Dispatcher
import PersistenceCore
import Privacy
import NativeAgentCore
import NativeAgentShared
import AppToolRuntime
import ToolExecution
// Blueprint: | `MacIntegrationDeliveryActions.swift` | Mac integration protocol execution, scheduler and Spotlight routing; due-reminders passes the requesting dispatcher's root to LocalPIMConnectorActions; Music calls the editable music part through L0, and Mail/Messages/Notes recovery words come from their parts while facts/evidence stay native; mobile notifications delegate to AppToolRuntime with the dispatcher surface; checked pairing and phone result routing; Mac notification receipts and MacControl adapter |

public struct MacIntegrationDeliveryActions: MacIntegrationToolBridge, PureToolArgumentValidating {
    private var dataRoot: URL { deviceSync().dataRoot }
    private let connectorActions: @Sendable () -> ConnectorActions
    private let router: @Sendable () -> AttentionRouter
    private let deviceSync: @Sendable () -> DeviceSync
    private let scheduler: @Sendable () -> SchedulerDueJobRunner

    public init(connectorActions: @escaping @Sendable () -> ConnectorActions,
                router: @escaping @Sendable () -> AttentionRouter, deviceSync: @escaping @Sendable () -> DeviceSync,
                scheduler: @escaping @Sendable () -> SchedulerDueJobRunner) {
        self.connectorActions = connectorActions
        self.router = router
        self.deviceSync = deviceSync
        self.scheduler = scheduler
    }

    public func argumentRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        await LocalPIMConnectorActions.argumentRefusal(tool: tool, input: input)
    }

    public func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarListUpcoming(input: input)
    }

    public func calendarCalendars(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarCalendars(input: input)
    }

    public func calendarFreeBusy(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarFreeBusy(input: input)
    }

    public func remindersQuery(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersQuery(input: input)
    }

    public func remindersRead(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersRead(input: input)
    }

    public func remindersLists(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersLists(input: input)
    }

    public func remindersUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersUpdate(input: input)
    }

    public func remindersListDueToday(input: [String: JSONValue], dataRoot: URL) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersListDueToday(input: input, dataRoot: dataRoot)
    }

    public func macNotify(input: [String: JSONValue]) async throws -> JSONValue {
        try await connectorActions().runMacNotify(input: input, toolName: "mac_notify")
    }

    public func mobileNotify(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let router = router()
        return try await AppToolExecutor.mobileNotify(input: input, surface: surface, toolName: "mobile_notify") { title, body, userInfo in
            try await AppToolExecutor.defaultMobileNotificationSender(title: title, body: body, userInfo: userInfo, router: router)
        }
    }

    public func phoneRequest(input: [String: JSONValue]) async throws -> JSONValue {
        try await Self.phoneRequest(input: input, deviceSync: deviceSync())
    }

    public func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsExecutor.search(input: input)
    }

    public func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsExecutor.createOrUpdate(input: input)
    }

    public func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailListRecent(input: input), integration:"mail", dataRoot:dataRoot)
    }

    public func mailAttachment(input: [String: JSONValue]) async throws -> (filename: String, data: Data) {
        try MacAppleScriptBridge.mailAttachment(input: input)
    }

    public func mailReadBatch(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(await MacAppleScriptBridge.mailBatch(input: input, effects: false), integration:"mail", dataRoot:dataRoot)
    }

    public func mailTriageBatch(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(await MacAppleScriptBridge.mailBatch(input: input, effects: true), integration:"mail", dataRoot:dataRoot)
    }

    public func mailSearch(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailSearch(input: input), integration:"mail", dataRoot:dataRoot)
    }

    public func mailSenders(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailSenders(input: input), integration:"mail", dataRoot:dataRoot)
    }

    public func mailSend(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailSend(input: input), integration:"mail", dataRoot:dataRoot)
    }

    public func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.messagesRecentThreads(input: input), integration:"messages", dataRoot:dataRoot)
    }

    public func messagesSend(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.messagesSend(input: input), integration:"messages", dataRoot:dataRoot)
    }

    public func notesSearch(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.notesSearch(input: input), integration:"notes", dataRoot:dataRoot)
    }

    public func notesCreate(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.notesCreate(input: input), integration:"notes", dataRoot:dataRoot)
    }

    public func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("now_playing", input: input)
    }

    public func musicControl(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("control", input: input)
    }

    public func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarCreateEvent(input: input)
    }

    public func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarModifyEvent(input: input)
    }

    public func calendarDeleteEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarDeleteEvent(input: input)
    }

    public func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersCreate(input: input)
    }

    public func remindersListRename(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersListRename(input: input)
    }

    public func remindersListCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersListCreate(input: input)
    }

    public func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersComplete(input: input)
    }
    public func remindersDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersDelete(input: input)
    }

    // Mail manage (W2)

    public func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailMarkRead(input: input), integration:"mail", dataRoot:dataRoot)
    }

    public func mailArchive(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailArchive(input: input), integration:"mail", dataRoot:dataRoot)
    }

    public func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailDelete(input: input), integration:"mail", dataRoot:dataRoot)
    }

    public func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailReply(input: input), integration:"mail", dataRoot:dataRoot)
    }

    public func mailDraft(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailDraft(input: input), integration:"mail", dataRoot:dataRoot)
    }

    // Notes update (W2)

    public func notesModify(input: [String: JSONValue], deleting: Bool) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.notesModify(input: input, deleting: deleting), integration:"notes", dataRoot:dataRoot)
    }

    // Music library (W2)

    public func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("search", input: input)
    }

    public func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("library", input: input)
    }

    public func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("playlists", input: input)
    }

    private func musicPart(_ operation: String, input: [String: JSONValue]) async throws -> JSONValue {
        switch await Parts(root: dataRoot).call(id: operation == "control" ? "music" : "music-library", input: .object([
            "operation": .string(operation), "input": .object(input)
        ]), as: JSONValue.self) {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    // Contacts delete (inline)

    public func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsExecutor.delete(input: input)
    }

    // Scheduler (delegates to the connector-action scheduler path).

    public func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue {
        try await ConnectorActions.runSchedulerListJobs()
    }

    public func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue {
        try await scheduler().createIntegrationJob(input: input, writer: schedulerJobWriter()) {
            try await ConnectorActions.runSchedulerCreateJob(input: $0)
        }
    }

    public func schedulerCancelJob(input: [String: JSONValue]) async throws -> JSONValue {
        try await schedulerJobWriter().cancelJob(jobId: schedulerJobID(input))
    }

    public func schedulerSetJobEnabled(input: [String: JSONValue], enabled: Bool) async throws -> JSONValue {
        try await schedulerJobWriter().setJobEnabled(jobId: schedulerJobID(input), enabled: enabled)
    }

    public func schedulerUpdateJob(input: [String: JSONValue]) async throws -> JSONValue {
        let id = schedulerJobID(input)
        // Routing context is not a job edit; keep unknown edit fields so the
        // canonical writer still rejects them.
        let changes = input.filter { !["job_id", "jobId", "id", "__session_id", "session_id"].contains($0.key) }
        return try await schedulerJobWriter().updateJob(jobId: id, changes: changes)
    }

    private func schedulerJobWriter() -> SwiftNativeTriggerScheduler {
        makeSchedulerJobWriter()
    }

    private func schedulerJobID(_ input: [String: JSONValue]) -> String {
        (input["job_id"]?.stringValue ?? input["jobId"]?.stringValue ?? input["id"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func spotlightSearch(input rawInput: [String: JSONValue]) async throws -> JSONValue {
        var input = rawInput
        // name: filename contains, case-insensitive — content words drown filename hits.
        if let name = input["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            input["query"] = .string("kMDItemFSName == \"*\(name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: ""))*\"cd")
            input["name"] = nil; input["q"] = nil
        }
        return try await connectorActions().runMacSpotlightSearch(input: input, toolName: "mac_spotlight_search")
    }


    public static func phoneRequest(input: [String: JSONValue], deviceSync: DeviceSync) async throws -> JSONValue {
        guard let kindName = input["kind"]?.stringValue, let kind = PhoneRequest.Kind(rawValue: kindName) else {
            throw DeviceSyncError.underlying(message: "kind must be location.current, photo.pick, or photo.capture.")
        }
        if let params = input["params"], params != .null, params != .object([:]) {
            throw DeviceSyncError.underlying(message: "These phone requests take empty params.")
        }
        let wait: Int
        if let value = input["wait_seconds"], value != .null {
            guard case .int(let seconds) = value, (1...120).contains(seconds) else {
                throw DeviceSyncError.underlying(message: "wait_seconds must be 1–120.")
            }
            wait = Int(seconds)
        } else { wait = 60 }
        guard try PairedPhoneStore.pairedCountChecked(at: deviceSync.dataRoot.appendingPathComponent("paired_phones.json")) > 0 else {
            throw DeviceSyncError.underlying(message: "No paired phone. Pair an iPhone in NativeAgent before asking it for location or a photo.")
        }
        let request = PhoneRequest(kind: kind, waitSeconds: wait)
        let bridge = await deviceSync.bridge
        let reply = try await bridge.phoneRequests.request(request)
        let result = try JSONDecoder().decode(PhoneRequestResult.self, from: Data(reply.text.utf8))
        var output: [String: JSONValue] = [
            "request_id": .string(result.requestID), "status": .string(result.status.rawValue),
            "values": .object(result.values.mapValues { .string($0) })
        ]
        if let message = result.message { output["message"] = .string(message) }
        if result.status == .completed, kind == .pickPhoto || kind == .capturePhoto {
            guard let photo = reply.attachments?.first, reply.attachments?.count == 1,
                  photo.type == "image", photo.mime == "image/jpeg",
                  let data = Data(base64Encoded: photo.base64), data.count == photo.byteSize, data.count <= 450_000 else {
                throw DeviceSyncError.underlying(message: "The phone result had no valid photo attachment.")
            }
            let root = deviceSync.dataRoot.appendingPathComponent("generated/phone", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = root.appendingPathComponent("\(request.id).jpg")
            try data.write(to: path, options: .atomic)
            let vision = LocalToolImage.showProducedImage(at: path, name: "phone-photo.jpg")
            output["attachments"] = .array([.object([
                "type": .string("image"), "mime": .string("image/jpeg"), "path": .string(path.path),
                "byteSize": .int(Int64(data.count)), "shownToModel": .bool(vision.shown), "visionNote": .string(vision.note)
            ])])
        }
        return .object(output)
    }

}

/// MacControl's `notify` action posts through the app's one banner exit
/// instead of its own copy of the UserNotifications calls.
public struct MacNotificationPosting: NotificationPosting {
    public init() {}
    public func postNotificationReceipt(
        title: String,
        message: String,
        soundName: String?
    ) async throws -> NotificationPostReceipt {
        let result = await NativeAgentNotifications.postMessage(
            title: title, body: message, soundName: soundName)
        guard result.posted else {
            throw MacControlError.notificationFailed(result.error ?? result.delivery)
        }
        return NotificationPostReceipt(
            authorization: result.authorizationStatus == "provisional" ? .provisional : .authorized,
            requestIdentifier: result.identifier
        )
    }
}
