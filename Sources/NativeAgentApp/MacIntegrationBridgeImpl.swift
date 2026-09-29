import AppToolRuntime
import Privacy
import Foundation
import AttentionRouting
import ChatOrchestration
import MacControl
import MacIntegration
import NativeAgentCore
import PersistenceCore
import TrustCenter
import DeviceSync
import NativeAgentShared
import Dispatcher
import TriggerScheduler

/// App-side implementation of the `MacIntegrationToolBridge` protocol declared
/// in ChatOrchestration. The chat tool dispatcher calls this whenever Agent
/// invokes one of the 5 Phase-1 macOS integration tools
/// (`mac_calendar_list_upcoming`, `mac_reminders_list_due_today`, `mac_notify`,
/// `mobile_notify`, `mac_spotlight_search`). Permission gating happens INSIDE
/// the dispatcher via `MacIntegrationPermissionStore.shared.allows(...)` —
/// this bridge assumes the gate already approved the call and just runs the
/// real backend.
///
/// The actual backends live in app code (`MacPIMConnectorActions` for EventKit,
/// `NativeAgentNotifications` for Mac local notifications, `MacSyncEngine` for
/// iOS push, the MacControl-spotlight dispatch path). ChatOrchestration (Core)
/// can't import them directly, so this bridge struct stitches them together
/// app-side and reaches the engine as a port (`NativeAgentEnginePorts`).
struct MacIntegrationBridgeImpl: MacIntegrationToolBridge, PureToolArgumentValidating {
    func argumentRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        await MacPIMConnectorActions.argumentRefusal(tool: tool, input: input)
    }

    func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.calendarListUpcoming(input: input)
    }

    func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.remindersListDueToday(input: input)
    }

    func macNotify(input: [String: JSONValue]) async throws -> JSONValue {
        // Mirror the shape NativeClient.runMacNotify uses so the chat-tool
        // path returns the same envelope the connector-action path does.
        let (title, message) = try NativeAgentNotificationDefaults.parseInput(input, toolName: "mac_notify")
        let result = await NativeAgentNotifications.postMessage(title: title, body: message)
        var obj = result.deliveryFields()
        obj.merge([
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    func mobileNotify(input: [String: JSONValue]) async throws -> JSONValue {
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
        let receipt = try await AttentionRouter.shared.route(
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
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    func phoneRequest(input: [String: JSONValue]) async throws -> JSONValue {
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
        let request = PhoneRequest(kind: kind, waitSeconds: wait)
        let bridge = await NativeAgentEngine.liveDeviceSync.bridge
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
            let root = NativeAgentEngine.liveDeviceSync.dataRoot.appendingPathComponent("generated/phone", isDirectory: true)
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

    // MARK: - Phase 2 (2026-06-07): Contacts + AppleScript bridges
    //
    // Permission gating is enforced in the Core dispatcher
    // (`dispatchMacIntegrationTool`) before any of these run — so each
    // delegate-only impl just forwards to the W1/W2 backends. The toggle
    // for each pair lives in the new Mac Integration tab; default
    // read=ON / write=OFF for the sensitive ids (the user's matrix).

    func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsAdapter.search(input: input)
    }

    func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsAdapter.createOrUpdate(input: input)
    }

    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailListRecent(input: input)
    }

    func mailSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailSearch(input: input)
    }

    func mailSend(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailSend(input: input)
    }

    func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.messagesRecentThreads(input: input)
    }

    func messagesSend(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.messagesSend(input: input)
    }

    func notesSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesSearch(input: input)
    }

    func notesCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesCreate(input: input)
    }

    func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicNowPlaying(input: input)
    }

    func musicControl(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicControl(input: input)
    }

    // MARK: - Phase 3 (2026-06-07): complete read+write coverage on every toggle
    //
    // the user asked for "complete complete" — every toggle in the Mac Integration
    // tab now has tools behind it. EventKit writes for calendar + reminders;
    // mail manage (mark/archive/delete/reply); notes update; music library
    // search; contacts delete; scheduler list+create. Sensitive writes stay
    // default-OFF; toggling Write ON in the tab unlocks the matching tools.

    // EventKit writes (W1)

    func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.calendarCreateEvent(input: input)
    }

    func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.calendarModifyEvent(input: input)
    }

    func calendarDeleteEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.calendarDeleteEvent(input: input)
    }

    func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.remindersCreate(input: input)
    }

    func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.remindersComplete(input: input)
    }
    func remindersDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.remindersDelete(input: input)
    }

    // Mail manage (W2)

    func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailMarkRead(input: input)
    }

    func mailArchive(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailArchive(input: input)
    }

    func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailDelete(input: input)
    }

    func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailReply(input: input)
    }

    // Notes update (W2)

    func notesUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesUpdate(input: input)
    }

    // Music library (W2)

    func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicSearchLibrary(input: input)
    }

    func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicListLibrary(input: input)
    }

    func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicListPlaylists(input: input)
    }

    // Contacts delete (inline)

    func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsAdapter.delete(input: input)
    }

    // Scheduler (delegates to the existing NativeClient SwiftNative path —
    // promoted from private to internal for this).

    func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue {
        try await NativeClient.runSchedulerListJobs()
    }

    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue {
        try await NativeClient.runSchedulerCreateJob(input: input)
    }

    func schedulerCancelJob(input: [String: JSONValue]) async throws -> JSONValue {
        try await schedulerJobWriter().cancelJob(jobId: schedulerJobID(input))
    }

    func schedulerSetJobEnabled(input: [String: JSONValue], enabled: Bool) async throws -> JSONValue {
        try await schedulerJobWriter().setJobEnabled(jobId: schedulerJobID(input), enabled: enabled)
    }

    func schedulerUpdateJob(input: [String: JSONValue]) async throws -> JSONValue {
        let id = schedulerJobID(input)
        // Routing context is not a job edit; keep unknown edit fields so the
        // canonical writer still rejects them.
        let changes = input.filter { !["job_id", "jobId", "id", "__session_id", "session_id"].contains($0.key) }
        return try await schedulerJobWriter().updateJob(jobId: id, changes: changes)
    }

    private func schedulerJobWriter() -> any SchedulerJobWriter {
        makeSchedulerJobWriter(connectorActionIDs: NativeClient.connectorActionIDSet())
    }

    private func schedulerJobID(_ input: [String: JSONValue]) -> String {
        (input["job_id"]?.stringValue ?? input["jobId"]?.stringValue ?? input["id"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Phase 1

    func spotlightSearch(input: [String: JSONValue]) async throws -> JSONValue {
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
        // matches NativeClient.runMacSpotlightSearch (~L8644). Bare
        // makeMacControl() disabled the policy preflight and was a security
        // regression vs the connector-action route.
        let auditPath = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("mac_control_audit.jsonl")
        let impl = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(),
            auditAppendPath: auditPath
        )
        let result = try await impl.dispatch(action: "spotlight", body: input)
        var obj: [String: JSONValue] = [
            "status": .string(result.ok ? "completed" : "failed"),
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
}

// MARK: - JSONValue convenience

private extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
