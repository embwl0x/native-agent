import Foundation
import ChatOrchestration
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

public struct MacIntegrationDeliveryActions: MacIntegrationToolBridge, PureToolArgumentValidating {
    private let postMessage: @Sendable (String, String) async -> [String: JSONValue]
    private let router: @Sendable () -> AttentionRouter
    private let deviceSync: @Sendable () -> DeviceSync
    private let scheduler: @Sendable () -> SchedulerDueJobRunner

    public init(postMessage: @escaping @Sendable (String, String) async -> [String: JSONValue],
                router: @escaping @Sendable () -> AttentionRouter, deviceSync: @escaping @Sendable () -> DeviceSync,
                scheduler: @escaping @Sendable () -> SchedulerDueJobRunner) {
        self.postMessage = postMessage
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

    public func remindersUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersUpdate(input: input)
    }

    public func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue {
        try await LocalPIMConnectorActions.remindersListDueToday(input: input)
    }

    public func macNotify(input: [String: JSONValue]) async throws -> JSONValue {
        try await Self.macNotify(input: input, postMessage: postMessage)
    }

    public func mobileNotify(input: [String: JSONValue]) async throws -> JSONValue {
        try await Self.mobileNotify(input: input, router: router())
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
        try await MacAppleScriptBridge.mailListRecent(input: input)
    }

    public func mailAttachment(input: [String: JSONValue]) async throws -> (filename: String, data: Data) {
        try MacAppleScriptBridge.mailAttachment(input: input)
    }

    public func mailReadBatch(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAppleScriptBridge.mailBatch(input: input, effects: false)
    }

    public func mailTriageBatch(input: [String: JSONValue]) async throws -> JSONValue {
        await MacAppleScriptBridge.mailBatch(input: input, effects: true)
    }

    public func mailSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailSearch(input: input)
    }

    public func mailSenders(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailSenders(input: input)
    }

    public func mailSend(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailSend(input: input)
    }

    public func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.messagesRecentThreads(input: input)
    }

    public func messagesSend(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.messagesSend(input: input)
    }

    public func notesSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesSearch(input: input)
    }

    public func notesCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesCreate(input: input)
    }

    public func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicNowPlaying(input: input)
    }

    public func musicControl(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicControl(input: input)
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
        try await MacAppleScriptBridge.mailMarkRead(input: input)
    }

    public func mailArchive(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailArchive(input: input)
    }

    public func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailDelete(input: input)
    }

    public func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailReply(input: input)
    }

    public func mailDraft(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailDraft(input: input)
    }

    // Notes update (W2)

    public func notesModify(input: [String: JSONValue], deleting: Bool) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesModify(input: input, deleting: deleting)
    }

    // Music library (W2)

    public func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicSearchLibrary(input: input)
    }

    public func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicListLibrary(input: input)
    }

    public func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicListPlaylists(input: input)
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

    private func schedulerJobWriter() -> any SchedulerJobWriter {
        makeSchedulerJobWriter(connectorActionIDs: Set(connectorActionDescriptors().map(\.id)))
    }

    private func schedulerJobID(_ input: [String: JSONValue]) -> String {
        (input["job_id"]?.stringValue ?? input["jobId"]?.stringValue ?? input["id"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Phase 1

    public func spotlightSearch(input rawInput: [String: JSONValue]) async throws -> JSONValue {
        var input = rawInput
        // name: filename contains, case-insensitive — content words drown filename hits (10-08).
        if let name = input["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            input["query"] = .string("kMDItemFSName == \"*\(name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: ""))*\"cd")
            input["name"] = nil; input["q"] = nil
        }
        let query = (input["query"]?.stringValue ?? input["q"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NSError(domain: "NativeAgentMacIntegrationBridge", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "mac_spotlight_search requires query",
            ])
        }
        // Dispatch through MacControl's spotlight action (same path the
        // connector-action route uses). gpt-5.5 review BLOCKING fix: thread
        // the TrustCenter policy provider + audit path so the in-process
        // preflight runs and refusals get logged to the shared audit file —
        // matches ConnectorActions.runMacSpotlightSearch. Bare
        // makeMacControl() disabled the policy preflight and was a security
        // regression vs the connector-action route.
        let auditPath = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("mac_control_audit.jsonl")
        let impl = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(),
            auditAppendPath: auditPath
        )
        let result = try await impl.dispatch(action: "spotlight", body: input)
        let partial = if case .object(let output) = result.output, output["partial"] == .bool(true) { true } else { false }
        var obj: [String: JSONValue] = [
            "status": .string(!result.ok ? "failed" : partial ? "partial" : "completed"),
            "action": .string(result.action),
            "ok": .bool(result.ok),
            "durationMs": .int(Int64(result.durationMs)),
            "viaSwift": .bool(result.viaSwift),
            "output": result.output,
        ]
        if let error = result.error { obj["error"] = .string(error) }
        if let httpStatus = result.httpStatus { obj["httpStatus"] = .int(Int64(httpStatus)) }
        return NativeAppSecretRedactor.redactValue(.object(obj))
    }

    public static func macNotify(input: [String: JSONValue], postMessage: (String, String) async -> [String: JSONValue]) async throws -> JSONValue {
        // Mirror the shape ConnectorActions.runMacNotify uses so the chat-tool
        // path returns the same envelope the connector-action path does.
        let (title, message) = try NativeAgentNotificationDefaults.parseInput(input, toolName: "mac_notify")
        var obj = await postMessage(title, message)
        obj.merge([
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(String(NativeAppSecretRedactor.redactText(message).prefix(200))),
        ]) { _, new in new }
        return .object(obj)
    }

    public static func mobileNotify(input: [String: JSONValue], router: AttentionRouter) async throws -> JSONValue {
        let (title, message) = try NativeAgentNotificationDefaults.parseInput(input, toolName: "mobile_notify")
        let source = input["source"]?.stringValue ?? "chat_tool"
        // B5 review round 2 (MED): pass through the same routing params the
        // AppChatToolDispatcher shim preserves (screen/urgency, + surface when
        // the caller provides one) — the two paths reach the same backend and
        // must hand it the same envelope, or unwrapped workshop/tool-step
        // notifies render differently from wrapped-chat ones.
        let screen = input["screen"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urgency = input["urgency"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var userInfo: [String: String] = [
            "screen": (screen?.isEmpty == false ? screen! : "inbox"),
            "source": source,
            "urgency": (urgency?.isEmpty == false ? urgency! : "normal"),
        ]
        if let surface = input["surface"]?.stringValue, !surface.isEmpty {
            userInfo["surface"] = surface
        }
        // Item 26: one exit, through the router. Owner-waiting and PINNED to
        // the phone — `mobile_notify` names its channel, so it keeps delivering
        // a real APNS receipt. Payload unchanged.
        let receipt = try await router.route(
            eventId: "mobile_notify:\(AttentionRouter.stableDigest(title + "|" + message))",
            importance: .ownerWaiting,
            title: title,
            body: message,
            userInfo: userInfo,
            pinnedTo: .phone
        ).requireReceipt()
        var obj = receipt.deliveryFields()
        obj.merge([
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(String(NativeAppSecretRedactor.redactText(message).prefix(200))),
        ]) { _, new in new }
        return .object(obj)
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

// MARK: - JSONValue convenience

private extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// MacControl's `notify` action posts through the app's one banner exit
/// instead of its own copy of the UserNotifications calls.
public struct NativeAgentMacControlNotificationAdapter: NotificationCenterAdapter {
    public init() {}
    public func postNotification(title: String, message: String, soundName: String?) async throws {
        _ = try await postNotificationReceipt(title: title, message: message, soundName: soundName)
    }

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
