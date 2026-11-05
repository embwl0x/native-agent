import Foundation
import ChatTurnContracts
import ChatToolRuntime
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
// Blueprint: | `MacIntegrationDeliveryActions.swift` | Rooted integration execution with native evidence and shared notification delivery |

public struct MacIntegrationDeliveryActions: ChatMacIntegrationToolBridge, PureToolArgumentValidating {
    private struct Operation: Sendable {
        let turn: Turn
        let context: MacOperationContext
    }
    private var operation: Operation?
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

    public func serving(turn: Turn, context: MacOperationContext) -> any MacIntegrationToolBridge {
        var bridge = self
        bridge.operation = Operation(turn: turn, context: context)
        return bridge
    }

    private func held() throws -> Operation {
        guard let operation else {
            throw ToolFailureError("The Mac integration has no originating operation. Nothing ran.", effects: .none)
        }
        return operation
    }

    public func argumentRefusal(tool: String, input: [String: JSONValue], turn: Turn) async -> JSONValue? {
        await LocalPIMConnectorActions.argumentRefusal(tool: tool, input: input)
    }

    public func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarListUpcoming(input: input, handsBack: held().context.handsBack)
    }

    public func calendarCalendars(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarCalendars(input: input, handsBack: held().context.handsBack)
    }

    public func calendarFreeBusy(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarFreeBusy(input: input, handsBack: held().context.handsBack)
    }

    public func remindersQuery(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersQuery(input: input, handsBack: held().context.handsBack)
    }

    public func remindersRead(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersRead(input: input, handsBack: held().context.handsBack)
    }

    public func remindersLists(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersLists(input: input, handsBack: held().context.handsBack)
    }

    public func remindersUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersUpdate(input: input, handsBack: held().context.handsBack)
    }

    public func remindersListDueToday(input: [String: JSONValue], dataRoot: URL) async throws -> JSONValue {
        let operation = try held()
        return try await MacAssistantParts.dueReminders(input: input, dataRoot: dataRoot, turn: operation.turn, context: operation.context)
    }

    public func macNotify(input: [String: JSONValue]) async throws -> JSONValue {
        try await connectorActions().runMacNotify(input: input, toolName: "mac_notify", turn: held().turn)
    }

    public func mobileNotify(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let router = router()
        return try await AppToolExecutor.mobileNotify(input: input, surface: surface, toolName: "mobile_notify", turn: held().turn) { title, body, userInfo,
            turn in
            try await AppToolExecutor.defaultMobileNotificationSender(title: title, body: body, userInfo: userInfo, router: router, turn: turn)
        }
    }

    public func phoneRequest(input: [String: JSONValue]) async throws -> JSONValue {
        try await Self.phoneRequest(input: input, deviceSync: deviceSync(), context: held().context)
    }

    public func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsExecutor.search(input: input, context: held().context)
    }

    public func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsExecutor.createOrUpdate(input: input, context: held().context)
    }

    public func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailListRecent(input: input, context: held().context), integration:"mail",
            dataRoot:dataRoot)
    }

    public func mailAttachment(input: [String: JSONValue]) async throws -> (filename: String, data: Data) {
        try MacAppleScriptBridge.mailAttachment(input: input, context: held().context)
    }

    public func mailReadBatch(input: [String: JSONValue]) async throws -> JSONValue {
        let operation = try held()
        return await MacAssistantParts.recover(await MacAppleScriptBridge.mailBatch(input: input, effects: false, context: operation.context),
            integration:"mail", dataRoot:dataRoot)
    }

    public func mailTriageBatch(input: [String: JSONValue]) async throws -> JSONValue {
        let operation = try held()
        return await MacAssistantParts.recover(await MacAppleScriptBridge.mailBatch(input: input, effects: true, context: operation.context),
            integration:"mail", dataRoot:dataRoot)
    }

    public func mailSearch(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailSearch(input: input, context: held().context), integration:"mail", dataRoot:dataRoot)
    }

    public func mailSenders(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailSenders(input: input, context: held().context), integration:"mail",
            dataRoot:dataRoot)
    }

    public func mailSend(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailSend(input: input, context: held().context), integration:"mail", dataRoot:dataRoot)
    }

    public func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.messagesRecentThreads(input: input, context: held().context), integration:"messages",
            dataRoot:dataRoot)
    }

    public func messagesSend(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.messagesSend(input: input, context: held().context), integration:"messages",
            dataRoot:dataRoot)
    }

    public func notesSearch(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.notesSearch(input: input, context: held().context), integration:"notes",
            dataRoot:dataRoot)
    }

    public func notesCreate(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.notesCreate(input: input, context: held().context), integration:"notes",
            dataRoot:dataRoot)
    }

    public func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("now_playing", input: input, turn: held().turn)
    }

    public func musicControl(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("control", input: input, turn: held().turn)
    }

    public func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarCreateEvent(input: input, handsBack: held().context.handsBack)
    }

    public func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarModifyEvent(input: input, handsBack: held().context.handsBack)
    }

    public func calendarDeleteEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.calendarDeleteEvent(input: input, handsBack: held().context.handsBack)
    }

    public func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersCreate(input: input, handsBack: held().context.handsBack)
    }

    public func remindersListRename(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersListRename(input: input, handsBack: held().context.handsBack)
    }

    public func remindersListCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersListCreate(input: input, handsBack: held().context.handsBack)
    }

    public func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersComplete(input: input, handsBack: held().context.handsBack)
    }
    public func remindersDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersDelete(input: input, handsBack: held().context.handsBack)
    }


    public func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailMarkRead(input: input, context: held().context), integration:"mail",
            dataRoot:dataRoot)
    }

    public func mailArchive(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailArchive(input: input, context: held().context), integration:"mail",
            dataRoot:dataRoot)
    }

    public func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailDelete(input: input, context: held().context), integration:"mail", dataRoot:dataRoot)
    }

    public func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailReply(input: input, context: held().context), integration:"mail", dataRoot:dataRoot)
    }

    public func mailDraft(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.mailDraft(input: input, context: held().context), integration:"mail", dataRoot:dataRoot)
    }


    public func notesModify(input: [String: JSONValue], deleting: Bool) async throws -> JSONValue {
        await MacAssistantParts.recover(try await MacAppleScriptBridge.notesModify(input: input, deleting: deleting, context: held().context),
            integration:"notes", dataRoot:dataRoot)
    }


    public func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("search", input: input, turn: held().turn)
    }

    public func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("library", input: input, turn: held().turn)
    }

    public func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue {
        try await musicPart("playlists", input: input, turn: held().turn)
    }

    private func musicPart(_ operation: String, input: [String: JSONValue], turn: Turn) async throws -> JSONValue {
        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(
            envelope: TurnEnvelope.current(turn: turn, surface: "chat"), fileAccess: turn.fileAccess ?? "auto", turn: turn) { door in
            switch await Parts(root: dataRoot).call(id: operation == "control" ? "music" : "music-library", input: .object([
                "operation": .string(operation), "input": .object(input)
            ]), invocation: door.invocation, as: JSONValue.self) {
            case .success(let result): return result
            case .failure(let error): throw error
            }
        }
    }


    public func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsExecutor.delete(input: input, context: held().context)
    }


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
        // Remove routing context only; preserve unknown edit fields for canonical rejection.
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
        // Match filenames for `name:` searches so content hits cannot drown them.
        if let name = input["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            input["query"] = .string("kMDItemFSName == \"*\(name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: ""))*\"cd")
            input["name"] = nil; input["q"] = nil
        }
        return try await connectorActions().runMacSpotlightSearch(input: input, toolName: "mac_spotlight_search", turn: held().turn)
    }


    public static func phoneRequest(input: [String: JSONValue], deviceSync: DeviceSync,
                                    context: MacOperationContext) async throws -> JSONValue {
        guard let kindName = input["kind"]?.stringValue, let kind = PhoneRequest.Kind(rawValue: kindName), !kind.isSettings else {
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
        let reply = try await bridge.phoneRequests.request(request, deadline: context.deadline)
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
            let vision = LocalToolImage.showProducedImage(at: path, name: "phone-photo.jpg", sink: nil)
            output["attachments"] = .array([.object([
                "type": .string("image"), "mime": .string("image/jpeg"), "path": .string(path.path),
                "byteSize": .int(Int64(data.count)), "shownToModel": .bool(vision.shown), "visionNote": .string(vision.note)
            ])])
        }
        return .object(output)
    }

}

/// MacControl's words tell a matter pinned to the Mac; its OS receipt proves the banner.
public struct MacNotificationPosting: NotificationPosting {
    private let turn: Turn?
    private let deadline: ContinuousClock.Instant?

    public init(turn: Turn?, deadline: ContinuousClock.Instant?) {
        self.turn = turn
        self.deadline = deadline
    }
    public func postNotificationReceipt(
        title: String,
        message: String,
        soundName: String?
    ) async throws -> NotificationPostReceipt {
        let result = await NativeAgentNotifications.postMessage(
            title: title, body: message, soundName: soundName, router: NativeAgentEngine.live.ports.backgroundWork.attention,
            turn: turn, deadline: deadline)
        guard result.posted else {
            if case .unknown(_, let reason) = result.notificationOutcome {
                throw ToolFailureError("Mac notification outcome is unknown: " + reason, effects: .unknown,
                    owner: "experiences:" + result.identifier, code: "notification_unconfirmed",
                    instruction: "Wait for this matter's Mac receipt before asking for another banner.", recovery: .reconcile)
            }
            throw MacControlError.notificationFailed(result.error ?? result.delivery)
        }
        return NotificationPostReceipt(
            authorization: result.authorizationStatus == "provisional" ? .provisional : .authorized,
            requestIdentifier: result.identifier
        )
    }
}
